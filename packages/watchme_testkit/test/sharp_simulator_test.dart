@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:watchme_testkit/sharp_simulator.dart';

/// A raw TCP client that records everything the simulator sends.
final class _Client {
  _Client._(this.socket) {
    socket.listen(
      (data) {
        _received.write(latin1.decode(data));
        _notify();
      },
      onDone: () {
        closed = true;
        _notify();
      },
      onError: (Object _) {
        closed = true;
        _notify();
      },
    );
  }

  static Future<_Client> connect(SharpSimulator sim) async =>
      _Client._(await Socket.connect(sim.host, sim.port));

  final Socket socket;
  final StringBuffer _received = StringBuffer();
  final List<Completer<void>> _waiters = [];
  bool closed = false;
  int _taken = 0;

  /// Everything received so far.
  String get received => _received.toString();

  /// What arrived since the last [take].
  String get fresh => received.substring(_taken);

  void _notify() {
    for (final w in [..._waiters]) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  void send(String text) => socket.add(latin1.encode(text));

  /// Waits until [test] holds on what arrived since the last [take], or
  /// [timeout] passes; returns that text and marks it taken.
  Future<String> take(
    bool Function(String fresh) test, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!test(fresh) && !closed) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) break;
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
    }
    final text = fresh;
    _taken = received.length;
    return text;
  }

  /// Sends [line] with CR and returns the next reply (up to its CR).
  Future<String> command(String line) async {
    send('$line\r');
    return take((t) => t.endsWith('\r'));
  }

  /// Waits [wait] and returns what arrived meanwhile.
  Future<String> quiet([
    Duration wait = const Duration(milliseconds: 150),
  ]) async {
    await Future<void>.delayed(wait);
    return take((_) => true, timeout: Duration.zero);
  }

  /// Waits until the simulator closes the connection.
  Future<bool> waitClosed([
    Duration timeout = const Duration(seconds: 2),
  ]) async {
    await take((_) => closed, timeout: timeout);
    return closed;
  }

  Future<void> close() async => socket.destroy();
}

Future<bool> _refuses(SharpSimulator sim) async {
  try {
    final s = await Socket.connect(sim.host, sim.port);
    s.destroy();
    return false;
  } on SocketException {
    return true;
  }
}

void main() {
  late SharpSimulator sim;

  Future<SharpSimulator> startSim([SharpSimulator? s]) async {
    sim = s ?? SharpSimulator();
    await sim.start();
    addTearDown(sim.stop);
    return sim;
  }

  Future<_Client> client() async {
    final c = await _Client.connect(sim);
    addTearDown(c.close);
    return c;
  }

  group('lifecycle', () {
    test('listens on a random loopback port and stops', () async {
      await startSim();
      expect(sim.isRunning, isTrue);
      expect(sim.isListening, isTrue);
      expect(sim.host, '127.0.0.1');
      expect(sim.endpoint.port('ipc', 10002), sim.port);
      await sim.stop();
      expect(sim.isRunning, isFalse);
      expect(await _refuses(sim), isTrue);
    });

    test(
      'a TV that starts off refuses connections until its power button',
      () async {
        await startSim(SharpSimulator(power: SharpSimPower.off));
        expect(await _refuses(sim), isTrue);
        await sim.pressPowerButton();
        expect(sim.power, SharpSimPower.booting);
        final c = await client();
        expect(await c.command('POWR?   '), '0\r');
      },
    );
  });

  group('framing', () {
    test('login disabled: sends nothing until the first command', () async {
      await startSim();
      final c = await client();
      expect(await c.quiet(), isEmpty);
      expect(await c.command('POWR?   '), '1\r');
    });

    test('replies OK, ERR or a value, one per command', () async {
      await startSim();
      final c = await client();
      expect(await c.command('VOLM30  '), 'OK\r');
      expect(sim.volume, 30);
      expect(await c.command('VOLM?   '), '30\r');
      expect(await c.command('VOLM????'), '30\r');
      expect(await c.command('VOLM0012'), 'OK\r', reason: 'zero-padded');
      expect(sim.volume, 12);
      expect(await c.command('VOLM61  '), 'ERR\r', reason: 'above 0-60');
      expect(await c.command('XXXX0   '), 'ERR\r');
      expect(sim.lines.first, 'VOLM30  ');
    });

    test('lines that are not 8 characters answer ERR, as do lower case and '
        'space-padded numbers', () async {
      await startSim();
      final c = await client();
      expect(await c.command('admin'), 'ERR\r');
      expect(await c.command(''), 'ERR\r');
      expect(await c.command('volm?   '), 'ERR\r');
      expect(await c.command('RCKY  12'), 'ERR\r');
      sim
        ..strictCase = false
        ..acceptRightAligned = true;
      expect(await c.command('volm?   '), '20\r');
      expect(await c.command('RCKY  33'), 'OK\r');
      expect(sim.volume, 21);
    });

    test('CRLF ends one command; a bare LF ends one too', () async {
      await startSim();
      final c = await client();
      c.send('POWR?   \r\n');
      expect(await c.take((t) => t.endsWith('\r')), '1\r');
      c.send('MUTE?   \n');
      expect(await c.take((t) => t.endsWith('\r')), '2\r');
      expect(await c.quiet(), isEmpty);
      expect(sim.lines, ['POWR?   ', 'MUTE?   ']);
    });

    test('several commands in one chunk are answered in order and counted '
        'as pipelined', () async {
      await startSim();
      final c = await client();
      c.send('POWR?   \rVOLM?   \rMUTE?   \r');
      expect(await c.take((t) => '\r'.allMatches(t).length >= 3), '1\r20\r2\r');
      expect(sim.pipelined, 2);
    });

    test('argument-less commands take 0 on US sets and blanks on EU and '
        '4T-B sets, each accepting the other by default', () async {
      await startSim();
      var c = await client();
      expect(await c.command('CHUP0   '), 'OK\r');
      expect(await c.command('CHUP    '), 'OK\r');
      sim.acceptBlankForX = false;
      expect(await c.command('CHUP    '), 'ERR\r');
      await sim.stop();

      await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      c = await client();
      expect(await c.command('ITVD    '), 'OK\r');
      sim.acceptZeroForBlank = false;
      expect(await c.command('ITVD0   '), 'ERR\r');
      expect(await c.command('IDTV    '), 'OK\r');
    });
  });

  group('login', () {
    test('Login: has no terminator; success is a bare CRLF', () async {
      await startSim(SharpSimulator(loginId: 'admin', password: 'secret1'));
      final c = await client();
      expect(await c.take((t) => t.contains('Login:')), 'Login:');
      c.send('admin\r');
      expect(await c.take((t) => t.contains('Password:')), '\r\nPassword:');
      c.send('secret1\r');
      expect(await c.take((t) => t.isNotEmpty), '\r\n');
      expect(await c.quiet(), isEmpty);
      expect(await c.command('POWR?   '), '1\r');
      expect(sim.successfulLogins, 1);
      expect(sim.rawInput.single, 'admin\rsecret1\rPOWR?   \r');
    });

    test(
      'a wrong login gets the mismatch text and the connection closes',
      () async {
        await startSim(SharpSimulator(loginId: 'admin', password: 'secret1'));
        final c = await client();
        await c.take((t) => t.contains('Login:'));
        c.send('admin\rwrong\r');
        final text = await c.take((t) => t.contains('mismatch'));
        expect(text, contains('User Name or Password mismatch'));
        expect(await c.waitClosed(), isTrue);
        expect(sim.failedLogins, 1);
        expect(sim.commands, isEmpty);
      },
    );

    test('the re-prompt variant sends Login: again', () async {
      await startSim(
        SharpSimulator(
          loginId: 'admin',
          password: 'secret1',
          loginFailure: SharpSimLoginFailure.reprompt,
        ),
      );
      final c = await client();
      await c.take((t) => t.contains('Login:'));
      c.send('admin\rwrong\r');
      expect(
        await c.take((t) => t.endsWith('Login:')),
        '\r\nPassword:\r\nUser Name or Password mismatch\r\nLogin:',
      );
      c.send('admin\rsecret1\r');
      expect(await c.take((t) => t.endsWith('\r\n')), '\r\nPassword:\r\n');
      expect(await c.command('MUTE?   '), '2\r');
    });

    test('type-ahead credentials are answered in order', () async {
      await startSim(SharpSimulator(loginId: 'admin', password: 'secret1'));
      final c = await client();
      c.send('admin\rsecret1\rPOWR?   \r');
      expect(
        await c.take((t) => t.endsWith('1\r')),
        'Login:\r\nPassword:\r\n1\r',
      );
      expect(sim.pipelined, 0, reason: 'login lines are not commands');
    });

    test('commands sent before the login are taken as the login', () async {
      await startSim(SharpSimulator(loginId: 'admin', password: 'secret1'));
      final c = await client();
      await c.take((t) => t.contains('Login:'));
      c.send('POWR0   \r');
      expect(await c.take((t) => t.contains('Password:')), '\r\nPassword:');
      expect(sim.power, SharpSimPower.on);
      expect(sim.commands, isEmpty);
    });

    test('runs the login on every connection', () async {
      await startSim(SharpSimulator(loginId: 'admin', password: 'secret1'));
      for (var i = 0; i < 2; i++) {
        final c = await client();
        c.send('admin\rsecret1\r');
        await c.take((t) => t.endsWith('\r\n'));
        expect(await c.command('POWR?   '), '1\r');
        await c.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(sim.successfulLogins, 2);
    });

    test('postLoginOk sends OK as a second chunk', () async {
      await startSim(
        SharpSimulator(
          loginId: 'admin',
          password: 'secret1',
          postLoginOk: true,
        ),
      );
      final c = await client();
      c.send('admin\rsecret1\r');
      await c.take((t) => t.endsWith('\r\n'));
      expect(await c.take((t) => t.isNotEmpty), 'OK\r');
    });

    test(
      'the 2015 firmware shows the prompt but does not enforce it',
      () async {
        await startSim(
          SharpSimulator(
            profile: SharpSimProfile.us2015Limited,
            loginId: 'admin',
            password: 'secret1',
          ),
        );
        final c = await client();
        await c.take((t) => t.contains('Login:'));
        expect(await c.command('admin'), 'ERR\r');
        expect(await c.command('POWR1   '), 'OK\r');
      },
    );
  });

  group('quirks', () {
    test('missingCrBug sends the CR at the start of the next reply', () async {
      await startSim(SharpSimulator(missingCrBug: true));
      final c = await client();
      c.send('VOLM10  \r');
      expect(await c.quiet(), 'OK');
      expect(await c.command('VOLM?   '), '\r10\r');
    });

    test('leadingCr frames replies as CR reply CR', () async {
      await startSim(SharpSimulator(leadingCr: true));
      final c = await client();
      expect(await c.command('POWR?   '), '\r1\r');
    });

    test('strayOk puts an OK before the next query value', () async {
      await startSim(SharpSimulator(strayOk: true));
      final c = await client();
      expect(await c.command('CHUP0   '), 'OK\r');
      c.send('IAVD?   \r');
      expect(await c.take((t) => '\r'.allMatches(t).length >= 2), 'OK\rERR\r');
      expect(await c.command('POWR?   '), '1\r');
    });
  });

  group('power', () {
    test('POWR0 without network standby answers OK, then drops connections '
        'and refuses new ones', () async {
      await startSim(
        SharpSimulator(standbyCloseDelay: const Duration(milliseconds: 50)),
      );
      final c = await client();
      expect(await c.command('POWR0   '), 'OK\r');
      expect(await c.waitClosed(), isTrue);
      expect(sim.power, SharpSimPower.off);
      expect(await _refuses(sim), isTrue);
    });

    test('with RSPW 2 a US 2011 set keeps listening in standby', () async {
      await startSim(SharpSimulator(rspw: 2));
      final c = await client();
      expect(await c.command('POWR0   '), 'OK\r');
      expect(sim.power, SharpSimPower.networkStandby);
      expect(await c.command('POWR?   '), '0\r');
      expect(await c.command('RSPW?   '), '2\r');
      expect(await c.command('MNRD1   '), 'C6400UA\r');
      expect(await c.command('VOLM?   '), 'ERR\r');
      expect(await c.command('VOLM10  '), 'ERR\r');
      expect(await c.command('RSPW0   '), 'ERR\r', reason: 'set only while on');
    });

    test(
      'silent standby queries keep the connection and answer nothing',
      () async {
        await startSim(
          SharpSimulator(
            power: SharpSimPower.networkStandby,
            rspw: 2,
            standbyQueries: SharpSimStandbyQueries.silent,
          ),
        );
        final c = await client();
        c.send('VOLM?   \r');
        expect(await c.quiet(), isEmpty);
        expect(await c.command('POWR?   '), '0\r');
      },
    );

    test('POWR1 boots: POWR? reads 0 for half the boot, then 1', () async {
      await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          bootDuration: const Duration(milliseconds: 400),
        ),
      );
      final c = await client();
      expect(await c.command('POWR1   '), 'OK\r');
      expect(sim.power, SharpSimPower.booting);
      expect(await c.command('POWR?   '), '0\r');
      expect(await c.command('VOLM?   '), 'ERR\r');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(await c.command('POWR?   '), '1\r');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(sim.power, SharpSimPower.on);
      expect(await c.command('VOLM?   '), '20\r');
    });

    test('the POWER and NETFLIX keys wake a TV in network standby', () async {
      await startSim(
        SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
      );
      final c = await client();
      expect(await c.command('RCKY59  '), 'OK\r');
      expect(sim.power, SharpSimPower.booting);
      expect(sim.foregroundApp, 'netflix');
      await sim.stop();

      await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          keyWakes: false,
        ),
      );
      final d = await client();
      expect(await d.command('RCKY12  '), 'ERR\r');
      expect(sim.power, SharpSimPower.networkStandby);
    });

    test('RCKY12 while on is a toggle to standby', () async {
      await startSim(SharpSimulator(rspw: 2));
      final c = await client();
      expect(await c.command('RCKY12  '), 'OK\r');
      await Future<void>.delayed(Duration.zero);
      expect(sim.power, SharpSimPower.networkStandby);
    });

    test('EU sets refuse POWR1 and have no RSPW', () async {
      await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final c = await client();
      expect(await c.command('POWR1   '), 'ERR\r');
      expect(await c.command('RSPW?   '), 'ERR\r');
      expect(await c.command('IPPV1   '), 'ERR\r');
      expect(await c.command('IPPY1   '), '0100\r');
    });

    test('Quick Start gives network standby on 2014 sets, for a limited '
        'window when set', () async {
      await startSim(
        SharpSimulator(
          profile: SharpSimProfile.us2014,
          quickStart: true,
          quickStartWindow: const Duration(milliseconds: 150),
          standbyCloseDelay: const Duration(milliseconds: 10),
        ),
      );
      final c = await client();
      expect(await c.command('POWR0   '), 'OK\r');
      expect(sim.power, SharpSimPower.networkStandby);
      expect(await c.waitClosed(const Duration(seconds: 1)), isTrue);
      expect(sim.power, SharpSimPower.off);
      expect(await _refuses(sim), isTrue);
    });
  });

  group('state commands', () {
    test('mute: toggle, discrete and query', () async {
      await startSim();
      final c = await client();
      expect(await c.command('MUTE1   '), 'OK\r');
      expect(await c.command('MUTE?   '), '1\r');
      expect(await c.command('MUTE0   '), 'OK\r');
      expect(sim.muted, isFalse);
      expect(await c.command('MUTE?   '), '2\r');
    });

    test('inputs: the current one answers ERR; the tuner reads ERR', () async {
      await startSim();
      final c = await client();
      expect(await c.command('IAVD?   '), '1\r');
      expect(await c.command('IAVD1   '), 'ERR\r');
      expect(await c.command('IAVD2   '), 'OK\r');
      expect(await c.command('IAVD9   '), 'ERR\r');
      expect(await c.command('ITVD0   '), 'OK\r');
      expect(sim.iavd, isNull);
      expect(await c.command('IAVD?   '), 'ERR\r');
      expect(await c.command('IDIN50  '), 'OK\r');
      expect(sim.iavd, 1);
    });

    test('4T-B inputs count from 0 = TV', () async {
      await startSim(SharpSimulator(profile: SharpSimProfile.us4tb));
      final c = await client();
      expect(await c.command('IAVD0   '), 'OK\r');
      expect(await c.command('IAVD?   '), '0\r');
      expect(await c.command('IAVD6   '), 'ERR\r');
    });

    test(
      'channels: analogue, two-part air and cable, one-part cable',
      () async {
        await startSim();
        final c = await client();
        expect(await c.command('DCCH7   '), 'OK\r');
        expect(sim.channel, '7');
        expect(await c.command('DA2P0701'), 'OK\r');
        expect(sim.channel, '7.1');
        expect(await c.command('DC2L045 '), 'ERR\r', reason: 'needs DC2U');
        expect(await c.command('DC2U123 '), 'OK\r');
        expect(await c.command('DC2L045 '), 'OK\r');
        expect(sim.channel, '123.45');
        expect(await c.command('DC112345'), 'OK\r');
        expect(sim.channel, '12345');
        expect(await c.command('DCCH136 '), 'ERR\r');
      },
    );

    test('ITGD cycles the inputs and the tuner; EU sets tune with DTVD and '
        'switch to DTV with IDTV', () async {
      await startSim(SharpSimulator(input: 7));
      final c = await client();
      expect(await c.command('ITGD0   '), 'OK\r');
      expect(sim.iavd, 8);
      expect(await c.command('ITGD0   '), 'OK\r');
      expect(sim.iavd, isNull, reason: 'after the last input, the tuner');
      expect(await c.command('ITGD0   '), 'OK\r');
      expect(sim.iavd, 1);
      await sim.stop();
      await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final d = await client();
      expect(await d.command('DTVD101 '), 'OK\r');
      expect(sim.channel, '101');
      expect(sim.iavd, isNull);
      expect(await d.command('IAVD4   '), 'OK\r');
      expect(await d.command('IDTV    '), 'OK\r');
      expect(sim.iavd, isNull);
      expect(await d.command('DTVD0   '), 'ERR\r');
      expect(await d.command('DA2P0701'), 'ERR\r', reason: 'a US command');
      expect(await d.command('DCCH100 '), 'ERR\r', reason: 'EU DCCH is 1-99');
    });

    test('options: a volume change may unmute; IAVD for the current input '
        'may be accepted', () async {
      await startSim(
        SharpSimulator(
          muted: true,
          volumeUnmutes: true,
          iavdErrWhenCurrent: false,
        ),
      );
      final c = await client();
      expect(await c.command('VOLM30  '), 'OK\r');
      expect(sim.muted, isFalse);
      expect(await c.command('IAVD1   '), 'OK\r');
      expect(sim.iavd, 1);
    });

    test('remote keys: volume, mute and unknown codes', () async {
      await startSim();
      final c = await client();
      expect(await c.command('RCKY33  '), 'OK\r');
      expect(sim.volume, 21);
      expect(await c.command('RCKY31  '), 'OK\r');
      expect(sim.muted, isTrue);
      expect(await c.command('RCKY37  '), 'ERR\r');
      await sim.stop();
      await startSim(SharpSimulator(profile: SharpSimProfile.us2010));
      final d = await client();
      expect(await d.command('RCKY33  '), 'ERR\r');
    });

    test('information commands', () async {
      await startSim(SharpSimulator(modelReply: 'C6400UA'));
      final c = await client();
      expect(await c.command('TVNM1   '), 'Living Room AQUOS\r');
      expect(await c.command('MNRD1   '), 'C6400UA\r');
      expect(await c.command('SWVN1   '), '222U1302091\r');
      expect(await c.command('IPPV1   '), '0100\r');
    });

    test('the 2015 firmware refuses queries and absolute commands', () async {
      await startSim(SharpSimulator(profile: SharpSimProfile.us2015Limited));
      final c = await client();
      for (final q in ['POWR?   ', 'MUTE?   ', 'VOLM?   ', 'IAVD?   ']) {
        expect(await c.command(q), 'ERR\r', reason: q);
      }
      for (final w in ['SWVN1   ', 'MNRD1   ', 'MUTE1   ', 'VOLM1   ']) {
        expect(await c.command(w), 'ERR\r', reason: w);
      }
      for (final w in ['MUTE0   ', 'RCKY33  ', 'RCKY39  ', 'POWR1   ']) {
        expect(await c.command(w), 'OK\r', reason: w);
      }
    });
  });

  group('connections', () {
    test('beyond maxClients a connection is accepted and closed', () async {
      await startSim();
      final a = await client();
      expect(await a.command('POWR?   '), '1\r');
      final b = await client();
      expect(await b.waitClosed(), isTrue);
      expect(sim.overflowClosed, 1);
      expect(await a.command('POWR?   '), '1\r');
    });

    test('in refuse mode the port closes while the limit is reached', () async {
      await startSim(SharpSimulator(overflow: SharpSimOverflow.refuse));
      final a = await client();
      expect(await a.command('POWR?   '), '1\r');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await _refuses(sim), isTrue);
      await a.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final b = await client();
      expect(await b.command('POWR?   '), '1\r');
    });

    test('a reconnect sooner than minReconnectGap is closed at once', () async {
      await startSim(
        SharpSimulator(minReconnectGap: const Duration(milliseconds: 300)),
      );
      final a = await client();
      expect(await a.command('POWR?   '), '1\r');
      await a.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final b = await client();
      expect(await b.waitClosed(), isTrue);
      expect(sim.quickRefusals, 1);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      final c = await client();
      expect(await c.command('POWR?   '), '1\r');
    });

    test('an idle connection is closed after idleTimeout', () async {
      await startSim(
        SharpSimulator(idleTimeout: const Duration(milliseconds: 100)),
      );
      final c = await client();
      expect(await c.waitClosed(), isTrue);
    });

    test(
      'dropConnections closes with a FIN; unplug refuses until plugIn',
      () async {
        await startSim();
        final c = await client();
        await sim.dropConnections();
        expect(await c.waitClosed(), isTrue);
        await sim.unplug();
        expect(await _refuses(sim), isTrue);
        await sim.plugIn();
        final d = await client();
        expect(await d.command('POWR?   '), '1\r');
      },
    );
  });

  group('faults', () {
    test('drop acts, then closes without a reply', () async {
      await startSim();
      sim.failNext('VOLM', SharpSimFault.drop);
      final c = await client();
      c.send('VOLM40  \r');
      expect(await c.waitClosed(), isTrue);
      expect(c.received, isEmpty);
      expect(sim.volume, 40);
      expect(sim.commands.single.fault, SharpSimFault.drop);
    });

    test('silent, malformed, junk and late replies', () async {
      await startSim();
      final c = await client();
      sim.failNext('MUTE?', SharpSimFault.silent);
      c.send('MUTE?   \r');
      expect(await c.quiet(), isEmpty);
      sim.failNext('MUTE?', SharpSimFault.malformed);
      expect(await c.command('MUTE?   '), 'OKR\r');
      sim.failNext('MUTE?', SharpSimFault.junk);
      c.send('MUTE?   \r');
      expect(await c.take((t) => t.length >= 300), 'Z' * 300);
      sim.failNext(
        'POWR?',
        SharpSimFault.late,
        delay: const Duration(milliseconds: 200),
      );
      c.send('POWR?   \r');
      expect(await c.quiet(const Duration(milliseconds: 100)), isEmpty);
      expect(await c.take((t) => t.endsWith('\r')), '1\r');
    });

    test('skip lets matching lines through before the fault or hold', () async {
      await startSim();
      final c = await client();
      sim.failNext('RCKY33', SharpSimFault.silent, skip: 1);
      expect(await c.command('RCKY33  '), 'OK\r');
      c.send('RCKY33  \r');
      expect(await c.quiet(), isEmpty);
      final gate = sim.holdNext('MUTE', skip: 1);
      expect(await c.command('MUTE1   '), 'OK\r');
      c.send('MUTE2   \r');
      await gate.reached;
      expect(await c.quiet(), isEmpty);
      gate.release();
      expect(await c.take((t) => t.endsWith('\r')), 'OK\r');
    });

    test('holdNext acts at once and holds the reply', () async {
      await startSim();
      final gate = sim.holdNext('VOLM');
      final c = await client();
      c.send('VOLM15  \r');
      await gate.reached;
      expect(sim.volume, 15);
      expect(await c.quiet(), isEmpty);
      gate.release();
      expect(await c.take((t) => t.endsWith('\r')), 'OK\r');
    });
  });
}
