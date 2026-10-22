import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/sim.dart' show login;

// Scripted byte-level exchanges on the fake network with a fake clock, so
// the production timings (prompt waits, quiet windows, reply deadlines,
// idle close, reconnect spacing) are checked exactly and without waiting.

const String _host = '192.168.1.20';
const Endpoint _endpoint = Endpoint(_host);

void main() {
  late FakeNetworkStack net;
  late FakeTransports transports;
  late FakeClock clock;
  late List<FakeTcpPeer> peers;
  late SharpDriver driver;

  setUp(() {
    net = FakeNetworkStack();
    transports = FakeTransports(network: net);
    clock = FakeClock(DateTime.utc(2026, 10, 22, 12));
    peers = [];
    net.onTcp(_host, 10002, peers.add);
    driver = SharpDriver(clock: clock, pollInterval: null);
  });

  String sent(FakeTcpPeer peer) => latin1.decode(peer.receivedBytes);

  /// Waits for [peer] to have sent [line] last, then answers [reply].
  Future<void> answer(FakeTcpPeer peer, String line, String reply) async {
    await clock.flush();
    expect(sent(peer), endsWith(line));
    peer.send(latin1.encode(reply));
    await clock.flush();
  }

  /// Answers the reads a session makes when it connects to a TV that is
  /// on: power, model, volume, mute and input.
  Future<void> answerStart(FakeTcpPeer peer) async {
    await answer(peer, 'POWR?   \r', '1\r');
    await answer(peer, 'MNRD1   \r', 'C6400UA\r');
    await answer(peer, 'VOLM?   \r', '30\r');
    await answer(peer, 'MUTE?   \r', '2\r');
    await answer(peer, 'IAVD?   \r', '1\r');
  }

  test('login: each field goes out only after its prompt (section 12 '
      'bytes)', () async {
    final pending = driver.connect(
      _endpoint,
      transports,
      login('admin', 'secret1'),
    );
    await clock.flush();
    final tv = peers.single;
    expect(tv.port, 10002);
    expect(sent(tv), isEmpty);
    tv.send(ascii.encode('Login:'));
    await clock.flush();
    expect(sent(tv), 'admin\r');
    tv.send(ascii.encode('\r\nPassword:'));
    await clock.flush();
    expect(sent(tv), 'admin\rsecret1\r');
    tv.send(ascii.encode('\r\n'));
    await clock.flush();
    expect(sent(tv), 'admin\rsecret1\r', reason: 'waits for silence first');
    await clock.advance(const Duration(milliseconds: 200));
    await answerStart(tv);
    final session = await pending;
    expect(session.state.volume!.value, 50);
    await session.close();
  });

  test(
    'without a stored login, a second of silence means "no login"',
    () async {
      final pending = driver.connect(_endpoint, transports, null);
      await clock.flush();
      final tv = peers.single;
      await clock.advance(const Duration(milliseconds: 999));
      expect(sent(tv), isEmpty);
      await clock.advance(const Duration(milliseconds: 1));
      await answerStart(tv);
      await (await pending).close();
    },
  );

  test('the JP variant: CRLF and OK in two chunks are both dropped', () async {
    final pending = driver.connect(
      _endpoint,
      transports,
      login('admin', 'secret1'),
    );
    await clock.flush();
    final tv = peers.single;
    tv.send(ascii.encode('Login:'));
    await answer(tv, 'admin\r', '\r\nPassword:');
    await answer(tv, 'secret1\r', '\r\n');
    await clock.advance(const Duration(milliseconds: 150));
    tv.send(ascii.encode('OK\r'));
    await clock.advance(const Duration(milliseconds: 200));
    await answerStart(tv);
    await (await pending).close();
  });

  test('a wrong login answered by a new prompt is refused', () async {
    final pending = driver.connect(
      _endpoint,
      transports,
      login('admin', 'nope'),
    );
    final refused = expectLater(
      pending,
      throwsWatchmeError(
        WatchmeErrorCode.reauthRequired,
        rawDeviceMessage: '\r\nLogin:',
      ),
    );
    await clock.flush();
    final tv = peers.single;
    tv.send(ascii.encode('Login:'));
    await answer(tv, 'admin\r', '\r\nPassword:');
    await answer(tv, 'nope\r', '\r\nLogin:');
    await clock.advance(const Duration(milliseconds: 200));
    await refused;
    expect(tv.isClosed, isTrue);
  });

  group('device text is redacted before it is cut short, so no fragment '
      'of a secret survives', () {
    const password = 'hunter2hunter2';

    /// Logs in as `admin` with [password] up to the TV's answer.
    Future<FakeTcpPeer> loginUpToAnswer() async {
      await clock.flush();
      final tv = peers.single;
      tv.send(ascii.encode('Login:'));
      await answer(tv, 'admin\r', '\r\nPassword:');
      return tv;
    }

    test('a login answer that fits nothing', () async {
      Object? error;
      unawaited(
        driver
            .connect(_endpoint, transports, login('admin', password))
            .then<void>((_) {}, onError: (Object e) => error = e),
      );
      final tv = await loginUpToAnswer();
      // Longer than an error keeps, with the password across the cut.
      await answer(tv, '$password\r', '${'x' * 72}$password\r\n');
      await clock.advance(const Duration(milliseconds: 200));
      expect(error, isWatchmeError(WatchmeErrorCode.protocol));
      final e = error! as WatchmeError;
      expect('$e ${e.toJson()}', isNot(contains('hunter')));
    });

    test('an oversized reply to a command', () async {
      final pending = driver.connect(
        _endpoint,
        transports,
        login('admin', password),
      );
      final tv = await loginUpToAnswer();
      await answer(tv, '$password\r', '\r\n');
      await clock.advance(const Duration(milliseconds: 200));
      await answerStart(tv);
      final session = await pending;
      addTearDown(session.close);
      CommandResult? result;
      unawaited(session.execute(const SetMute(true)).then((r) => result = r));
      await answer(tv, 'MUTE1   \r', '${'x' * 72}$password${'y' * 200}\r');
      expect(result, isFailedWith(WatchmeErrorCode.protocol));
      expect('$result ${result!.toJson()}', isNot(contains('hunter')));
    });
  });

  group('a connected session', () {
    late SharpSession session;
    late FakeTcpPeer tv;

    setUp(() async {
      final pending = driver.connect(_endpoint, transports, null);
      await clock.flush();
      tv = peers.single;
      await clock.advance(const Duration(seconds: 1));
      await answerStart(tv);
      session = await pending as SharpSession;
      addTearDown(session.close);
    });

    Future<CommandResult> runUntil(Future<CommandResult> result) async {
      CommandResult? done;
      unawaited(result.then((r) => done = r));
      await clock.flush();
      return done ?? result;
    }

    test('an OK without CR is accepted after 300 ms of silence; its CR '
        'starts the next reply', () async {
      CommandResult? result;
      unawaited(session.execute(const SetVolume(50)).then((r) => result = r));
      await answer(tv, 'VOLM30  \r', 'OK');
      await clock.advance(const Duration(milliseconds: 299));
      expect(result, isNull);
      await clock.advance(const Duration(milliseconds: 2));
      expect(result, isConfirmed);
      CommandResult? next;
      unawaited(session.execute(const StepVolume(1)).then((r) => next = r));
      await answer(tv, 'VOLM?   \r', '\r30\r');
      await answer(tv, 'VOLM31  \r', 'OK\r');
      expect(next, isConfirmed);
    });

    test(
      'bytes that arrive between requests are dropped, never matched',
      () async {
        tv.send(ascii.encode('OK\rERR\r'));
        await clock.flush();
        CommandResult? result;
        unawaited(session.execute(const SetMute(true)).then((r) => result = r));
        await answer(tv, 'MUTE1   \r', 'OK\r');
        expect(result, isConfirmed);
        expect(session.discardedBytes, greaterThanOrEqualTo(7));
      },
    );

    test('POWR1 has 10 s to answer, other requests 4 s', () async {
      CommandResult? volume;
      unawaited(session.execute(const SetVolume(10)).then((r) => volume = r));
      await clock.advance(const Duration(milliseconds: 3999));
      expect(volume, isNull);
      await clock.advance(const Duration(milliseconds: 2));
      expect(volume, isFailedWith(WatchmeErrorCode.timeout));
      expect(tv.isClosed, isTrue, reason: 'reconnect after any timeout');

      CommandResult? power;
      unawaited(session.execute(const SetPower(true)).then((r) => power = r));
      await clock.advance(const Duration(milliseconds: 750));
      final second = peers.last;
      expect(peers, hasLength(2));
      await clock.advance(const Duration(seconds: 1));
      await answer(second, 'POWR1   \r', '');
      await clock.advance(const Duration(milliseconds: 9990));
      expect(power, isNull);
      await clock.advance(const Duration(milliseconds: 20));
      expect(power, isFailedWith(WatchmeErrorCode.timeout));
    });

    test(
      'a reply over 256 bytes, or a login prompt, breaks the framing',
      () async {
        var result = runUntil(session.execute(const SetMute(true)));
        await answer(tv, 'MUTE1   \r', '${'A' * 300}\r');
        expect(
          await result,
          isFailedWith(WatchmeErrorCode.protocol, message: contains('256')),
        );
        expect(tv.isClosed, isTrue);

        result = runUntil(session.execute(const SetMute(false)));
        await clock.advance(const Duration(milliseconds: 750));
        final second = peers.last;
        await clock.advance(const Duration(seconds: 1));
        await answer(second, 'MUTE2   \r', 'Login:');
        expect(
          await result,
          isFailedWith(WatchmeErrorCode.protocol, message: contains('login')),
        );
      },
    );

    test('closes the connection after 60 s idle, and waits 750 ms before '
        'the next', () async {
      await clock.advance(const Duration(seconds: 60));
      expect(tv.isClosed, isTrue);
      CommandResult? result;
      unawaited(session.execute(const SetMute(true)).then((r) => result = r));
      await clock.advance(const Duration(milliseconds: 749));
      expect(peers, hasLength(1));
      await clock.advance(const Duration(milliseconds: 2));
      expect(peers, hasLength(2));
      await clock.advance(const Duration(seconds: 1));
      await answer(peers.last, 'MUTE1   \r', 'OK\r');
      expect(result, isConfirmed);
    });

    test('POWR? 0 within 30 s of POWR1 is still "starting"', () async {
      CommandResult? result;
      unawaited(session.execute(const SetPower(true)).then((r) => result = r));
      await answer(tv, 'POWR1   \r', 'OK\r');
      expect(result, isConfirmed);
      var refreshed = session.refresh();
      await answer(tv, 'POWR?   \r', '0\r');
      expect((await refreshed).power!.confidence, Confidence.inferred);
      expect((await refreshed).power!.value, PowerMode.on);
      await clock.advance(const Duration(seconds: 30));
      refreshed = session.refresh();
      await clock.advance(const Duration(milliseconds: 750));
      await clock.advance(const Duration(seconds: 1));
      await answer(peers.last, 'POWR?   \r', '0\r');
      expect((await refreshed).power!.value, PowerMode.standby);
      expect((await refreshed).power!.confidence, Confidence.reported);
    });
  });
}
