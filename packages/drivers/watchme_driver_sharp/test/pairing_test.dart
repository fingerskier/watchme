@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_testkit/sharp_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/io_tcp_stack.dart';
import 'support/sim.dart';

void main() {
  final transports = IoTcpTransports();
  final driver = testDriver();

  PairingFlow start(SharpSimulator sim) =>
      driver.startPairing(sim.endpoint, transports, testContext)!;

  SharedSecretCredential credentialOf(List<PairingStep> steps) =>
      (steps.last as Paired).credential! as SharedSecretCredential;

  group('a TV without a login', () {
    test(
      'pairs at once with the "no login" credential, reading only',
      () async {
        final sim = await startSim(SharpSimulator(rspw: 2));
        final steps = await drive(start(sim), const []);
        expect(steps, [isPairedWith()]);
        final c = credentialOf(steps);
        expect(c.driverId, 'sharp.aquos');
        expect(c.deviceId, 'tv-1');
        expect(c.username, isNull);
        expect(c.secret, '');
        expect(isSharpNoLogin(c), isTrue);
        expect(writes(sim), isEmpty);
        expect(sim.lines.first, 'POWR?   ');
      },
    );
  });

  group('a TV with a login', () {
    late SharpSimulator sim;

    setUp(() async {
      sim = await startSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 2),
      );
    });

    test('asks for the login ID and the password, then checks them', () async {
      final steps = await drive(start(sim), ['admin', 'secret1']);
      expect(steps.whereType<EnterText>().toList(), const [
        EnterText('Login ID set on the TV'),
        EnterText('Password set on the TV', secret: true),
      ]);
      final c = credentialOf(steps);
      expect(c.username, 'admin');
      expect(c.secret, 'secret1');
      expect(sim.successfulLogins, 1);
      expect(writes(sim), isEmpty);
      for (final step in steps) {
        expect('${step.toJson()} $step', isNot(contains('secret1')));
      }
    });

    test('a wrong login is asked again', () async {
      final steps = await drive(start(sim), [
        'admin',
        'wrong',
        'admin',
        'secret1',
      ]);
      final labels = [for (final s in steps.whereType<EnterText>()) s.label];
      expect(labels, [
        'Login ID set on the TV',
        'Password set on the TV',
        'The login ID or password was wrong. Login ID set on the TV',
        'Password set on the TV',
      ]);
      expect(steps.last, isPairedWith());
      expect(sim.failedLogins, 1);
      expect(sim.successfulLogins, 1);
    });

    test('three wrong logins fail as unauthorized; no secret is shown, '
        'even one the TV echoes', () async {
      sim.mismatchText =
          '\r\nUser Name or Password mismatch (admin/hunter2)\r\n';
      final steps = await drive(start(sim), [
        'admin',
        'hunter2',
        'admin',
        'hunter2',
        'admin',
        'hunter2',
      ]);
      expect(sim.failedLogins, 3);
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.unauthorized);
      expect(failed.error.message, contains('Wrong login ID or password'));
      expect(
        failed.rawDeviceMessage,
        contains('User Name or Password mismatch'),
      );
      final shown = '${failed.toJson()} ${failed.error} ${failed.error.cause}';
      expect(shown, isNot(contains('hunter2')));
      expect(shown, isNot(contains('admin')));
    });

    test('a password that is a word the TV prints stays hidden', () async {
      sim.password = 'Password';
      final steps = await drive(start(sim), [
        'admin',
        'x',
        'admin',
        'x',
        'admin',
        'x',
      ]);
      final failed = steps.last as PairingFailed;
      expect(
        failed.rawDeviceMessage,
        contains('User Name or Password mismatch'),
      );
    });

    test('cancelling at a prompt fails as cancelled and closes the '
        'connection', () async {
      final steps = await drive(start(sim), ['admin']);
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.openConnections, 0);
      expect(sim.successfulLogins + sim.failedLogins, 0);
    });

    test('a value that does not fit is asked again', () async {
      final steps = await drive(start(sim), ['a' * 65, 'admin', 'secret1']);
      final texts = steps.whereType<EnterText>().toList();
      expect(texts[1].label, startsWith('At most 64 characters'));
      expect(steps.last, isPairedWith());
    });
  });

  test('the JP variant: OK after the login is dropped, and the session '
      'starts in step', () async {
    final sim = await startSim(
      SharpSimulator(
        loginId: 'admin',
        password: 'secret1',
        postLoginOk: true,
        rspw: 2,
      ),
    );
    final steps = await drive(start(sim), ['admin', 'secret1']);
    final session = await open(
      driver,
      sim,
      transports,
      credential: credentialOf(steps),
    );
    expect(session.state.power!.value, PowerMode.on);
    expect(await session.execute(const SetVolume(50)), isConfirmed);
    expect(sim.volume, 30);
  });

  test('the 2015 firmware shows the prompt but runs the login ID as a '
      'command: the password is never sent', () async {
    final sim = await startSim(
      SharpSimulator(
        profile: SharpSimProfile.us2015Limited,
        loginId: 'admin',
        password: 'secret1',
      ),
    );
    final steps = await drive(start(sim), ['admin', 'secret1']);
    expect(steps.last, isPairedWith());
    expect(sim.rawInput.join(), isNot(contains('secret1')));
  });

  test('the 2015 firmware paired with an empty login ID and password '
      'connects afterwards', () async {
    // The firmware shows the prompt without enforcing it, so a user who
    // never set a login leaves both fields empty.
    final sim = await startSim(
      SharpSimulator(
        profile: SharpSimProfile.us2015Limited,
        loginId: 'admin',
        password: 'secret1',
      ),
    );
    final steps = await drive(start(sim), ['', '']);
    expect(steps.last, isPairedWith());
    final session = await open(
      driver,
      sim,
      transports,
      credential: credentialOf(steps),
    );
    expect(session.profile, SharpProfile.us2015Limited);
    expect(await session.execute(const SetMute(null)), isConfirmed);
  });

  test('a TV whose only client slot is taken fails as unreachable, with '
      'nothing sent', () async {
    final sim = await startSim(SharpSimulator());
    final other = await Socket.connect(sim.host, sim.port);
    addTearDown(other.destroy);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final steps = await drive(start(sim), const []);
    expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unreachable));
    expect(sim.lines, isEmpty);
  });

  group('power-on over the network', () {
    test('a yes given after the TV cut the idle connection is written on a '
        'new one, logged in again', () async {
      final sim = await startSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 0),
      );
      final flow = start(sim);
      final texts = ['admin', 'secret1'];
      final steps = <PairingStep>[];
      await for (final step in flow.steps) {
        steps.add(step);
        if (step is EnterText) {
          flow.submit(texts.removeAt(0));
        } else if (step is ConfirmChange) {
          // The user takes longer than the TV's idle cut.
          await sim.dropConnections();
          await Future<void>.delayed(const Duration(milliseconds: 50));
          flow.submit(ConfirmChange.yes);
        }
      }
      expect(steps.last, isPairedWith());
      expect(writes(sim), ['RSPW2   ']);
      expect(sim.rspw, 2);
      expect(sim.commands.last.connection, 3, reason: 'a new connection');
      expect(sim.successfulLogins, 2);
    });

    test('asks before writing RSPW and writes it only on yes', () async {
      final sim = await startSim(SharpSimulator(rspw: 0));
      final steps = await drive(start(sim), [ConfirmChange.yes]);
      final confirm = steps.whereType<ConfirmChange>().single;
      expect(confirm.question, contains('turn this TV on over the network'));
      expect(confirm.detail, contains('just about the'));
      expect(confirm.detail, contains('Center Icon Illumination'));
      expect(steps.last, isPairedWith());
      expect(writes(sim), ['RSPW2   ']);
      expect(sim.rspw, 2);
    });

    test('writes nothing on no, or on any other answer', () async {
      for (final answer in [ConfirmChange.no, 'maybe', '']) {
        final sim = SharpSimulator(rspw: 1);
        await sim.start();
        final steps = await drive(start(sim), [answer]);
        expect(steps.last, isPairedWith(), reason: answer);
        expect(writes(sim), isEmpty, reason: answer);
        expect(sim.rspw, 1);
        await sim.stop();
      }
    });

    test('cancelling at the question writes nothing', () async {
      final sim = await startSim(SharpSimulator(rspw: 0));
      final steps = await drive(start(sim), const []);
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      expect(writes(sim), isEmpty);
    });

    test('no question when RSPW already accepts IP, or the TV is in '
        'standby', () async {
      for (final sim in [
        SharpSimulator(rspw: 2),
        SharpSimulator(rspw: 2, power: SharpSimPower.networkStandby),
      ]) {
        await sim.start();
        final steps = await drive(start(sim), const []);
        expect(steps.whereType<ConfirmChange>(), isEmpty);
        expect(steps.last, isPairedWith());
        await sim.stop();
      }
    });

    test('no question on models whose manual has no RSPW', () async {
      for (final profile in [SharpSimProfile.eu, SharpSimProfile.us4tb]) {
        final sim = SharpSimulator(profile: profile);
        await sim.start();
        final steps = await drive(start(sim), const []);
        expect(steps.whereType<ConfirmChange>(), isEmpty, reason: '$profile');
        expect(writes(sim), isEmpty, reason: '$profile');
        await sim.stop();
      }
    });

    test('Quick Start models get an instruction as well, unless the user '
        'declined power-on', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2014),
      );
      var steps = await drive(start(sim), [ConfirmChange.yes]);
      expect(steps.whereType<ConfirmChange>(), hasLength(1));
      expect(
        steps.whereType<Instruct>().single.text,
        contains('Quick Start Mode'),
      );
      expect(steps.last, isPairedWith());
      expect(writes(sim), ['RSPW2   ']);

      sim.rspw = 0;
      steps = await drive(start(sim), [ConfirmChange.no]);
      expect(steps.whereType<Instruct>(), isEmpty);

      final tb = SharpSimulator(profile: SharpSimProfile.us4tb);
      await tb.start();
      addTearDown(tb.stop);
      steps = await drive(start(tb), const []);
      expect(steps.whereType<ConfirmChange>(), isEmpty);
      expect(
        steps.whereType<Instruct>().single.text,
        contains('Quick Start Mode'),
      );
    });

    test('an unconfirmed write is reported, not retried, and pairing still '
        'succeeds', () async {
      final sim = await startSim(SharpSimulator(rspw: 0));
      sim.failNext('RSPW2', SharpSimFault.malformed);
      final steps = await drive(start(sim), [ConfirmChange.yes]);
      expect(
        steps.whereType<Instruct>().single.text,
        contains('did not confirm'),
      );
      expect(writes(sim), ['RSPW2   ']);
      expect(steps.last, isPairedWith());
    });
  });

  group('an unreachable port', () {
    test('says what to switch on, then tries again once', () async {
      final sim = await startSim(SharpSimulator(power: SharpSimPower.off));
      final flow = start(sim);
      final steps = <PairingStep>[];
      await for (final step in flow.steps) {
        steps.add(step);
        if (step is Instruct && step.requiresAck) {
          await sim.pressPowerButton();
          flow.submit('');
        } else if (step is ConfirmChange) {
          flow.submit(ConfirmChange.no);
        }
      }
      expect(steps.first, isA<Instruct>());
      expect((steps.first as Instruct).text, contains('IP Control'));
      expect(steps.last, isPairedWith());
    });

    test('fails as unreachable when the port stays closed', () async {
      final sim = await startSim(SharpSimulator(power: SharpSimPower.off));
      final steps = await drive(start(sim), const []);
      expect(steps.first, isA<Instruct>());
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.unreachable));
    });
  });

  test('fails cleanly without a network transport', () async {
    final flow = driver.startPairing(
      const Endpoint('127.0.0.1'),
      FakeTransports.offline(),
      testContext,
    )!;
    final steps = await drive(flow, const []);
    expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unsupported));
  });
}
