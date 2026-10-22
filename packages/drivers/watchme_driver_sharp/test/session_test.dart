@TestOn('vm')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_testkit/sharp_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/io_tcp_stack.dart';
import 'support/sim.dart';
import 'support/timings.dart';

void main() {
  final transports = IoTcpTransports();
  final driver = testDriver();

  /// Runs [command] and returns its result and the lines it sent.
  Future<(CommandResult, List<String>)> run(
    SharpSession session,
    SharpSimulator sim,
    Command command,
  ) async {
    final before = sim.lines.length;
    final result = await session.execute(command);
    return (result, sim.lines.sublist(before));
  }

  /// Lets queued events and socket closes arrive.
  Future<void> settle([Duration wait = Duration.zero]) =>
      Future<void>.delayed(wait);

  List<DeviceEvent> record(SharpSession session) {
    final events = <DeviceEvent>[];
    final sub = session.events.listen(events.add);
    addTearDown(sub.cancel);
    return events;
  }

  group('connect', () {
    test(
      'reads model and state with queries only, whatever allowWake says',
      () async {
        final sim = await startSim(
          SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
        );
        final session = await driver.connect(
          sim.endpoint,
          transports,
          null,
          allowWake: false,
        ) as SharpSession;
        addTearDown(session.close);
        expect(session.state.power!.value, PowerMode.standby);
        expect(session.state.power!.confidence, Confidence.reported);
        expect(session.profile, SharpProfile.us2011);
        expect(session.model, 'C6400UA');
        expect(
          session.capabilities.supportFor(Capability.powerState).level,
          Support.yes,
        );
        expect(sim.power, SharpSimPower.networkStandby);
        expect(writes(sim), isEmpty);
        expect(sim.lines, ['POWR?   ', 'MNRD1   ']);
      },
    );

    test('on a TV that is on it also reads volume, mute and input', () async {
      final sim = await startSim(SharpSimulator(volume: 30, muted: true));
      final session = await open(driver, sim, transports);
      expect(session.state.volume!.value, 50);
      expect(session.state.volume!.confidence, Confidence.reported);
      expect(session.state.muted!.value, isTrue);
      expect(session.state.input!.value, 'hdmi1');
      expect(writes(sim), isEmpty);
    });

    test(
      'no credential and a login prompt: unauthorized, nothing sent',
      () async {
        final sim = await startSim(
          SharpSimulator(loginId: 'admin', password: 'secret1'),
        );
        await expectLater(
          driver.connect(sim.endpoint, transports, null),
          throwsWatchmeError(WatchmeErrorCode.unauthorized),
        );
        expect(sim.rawInput, ['']);
      },
    );

    test(
      'a "no login" credential and a prompt: the TV changed, pair again',
      () async {
        final sim = await startSim(
          SharpSimulator(loginId: 'admin', password: 'secret1'),
        );
        await expectLater(
          driver.connect(sim.endpoint, transports, noLogin),
          throwsWatchmeError(WatchmeErrorCode.reauthRequired),
        );
        expect(sim.rawInput, ['']);
      },
    );

    test('a refused stored login: reauthRequired, with the TV text and no '
        'secret', () async {
      final sim = await startSim(
        SharpSimulator(
          loginId: 'admin',
          password: 'secret1',
          mismatchText: '\r\nUser Name or Password mismatch (sekret)\r\n',
        ),
      );
      Object? error;
      try {
        await driver.connect(
          sim.endpoint,
          transports,
          login('admin', 'sekret'),
        );
      } on WatchmeError catch (e) {
        error = e;
      }
      final e = error! as WatchmeError;
      expect(e.code, WatchmeErrorCode.reauthRequired);
      expect(e.rawDeviceMessage, contains('User Name or Password mismatch'));
      expect('$e ${e.toJson()}', isNot(contains('sekret')));
    });

    test(
      'a stored login logs in; one the TV no longer asks for is fine',
      () async {
        final sim = await startSim(
          SharpSimulator(loginId: 'admin', password: 'secret1'),
        );
        final session = await open(
          driver,
          sim,
          transports,
          credential: login('admin', 'secret1'),
        );
        expect(session.state.power!.value, PowerMode.on);
        expect(sim.successfulLogins, 1);
        await session.close();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        sim
          ..loginId = ''
          ..password = '';
        await open(
          driver,
          sim,
          transports,
          credential: login('admin', 'secret1'),
        );
      },
    );

    test('a prompt the TV does not enforce is found out with POWR? before '
        'any credential: a login ID shaped like a command is never sent, '
        'on connect or on reconnect', () async {
      // This firmware runs what it is sent at the prompt as commands:
      // RCKY0012 is the POWER key, which wakes a TV in network standby.
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          loginId: 'RCKY0012',
          password: 'secret1',
          enforceLogin: false,
        ),
      );
      final session = await driver.connect(
        sim.endpoint,
        transports,
        login('RCKY0012', 'secret1'),
        allowWake: false,
      ) as SharpSession;
      addTearDown(session.close);
      await sim.dropConnections();
      await settle(const Duration(milliseconds: 30));
      await session.refresh();
      expect(sim.connectionsAccepted, 2);
      expect(sim.power, SharpSimPower.networkStandby);
      expect(writes(sim), isEmpty);
      expect(sim.rawInput.join(), isNot(contains('RCKY')));
      expect(sim.rawInput.join(), isNot(contains('secret1')));
      expect(session.state.power!.value, PowerMode.standby);
    });

    test('a TV that enforces its login takes the POWR? check for a login '
        'ID; the login then goes out on a new connection', () async {
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          loginId: 'RCKY0012',
          password: 'secret1',
        ),
      );
      final session = await open(
        driver,
        sim,
        transports,
        credential: login('RCKY0012', 'secret1'),
      );
      expect(sim.successfulLogins, 1);
      expect(sim.failedLogins, 0, reason: 'no password follows the check');
      expect(sim.rawInput.first, 'POWR?   \r');
      expect(sim.rawInput[1], startsWith('RCKY0012\rsecret1\r'));
      expect(sim.power, SharpSimPower.networkStandby);
      expect(session.state.power!.value, PowerMode.standby);
    });

    test('other credentials are refused', () async {
      final sim = await startSim(SharpSimulator());
      await expectLater(
        driver.connect(
          sim.endpoint,
          transports,
          TokenCredential(
            driverId: 'firetv.lightning',
            deviceId: 'tv-1',
            createdAt: DateTime.utc(2026),
            token: 't',
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.unauthorized),
      );
    });

    test('a closed port is unreachable; a TV that does not answer POWR? '
        'times out', () async {
      final off = await startSim(SharpSimulator(power: SharpSimPower.off));
      await expectLater(
        driver.connect(off.endpoint, transports, null),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      final sim = await startSim(SharpSimulator());
      sim.failNext('POWR?', SharpSimFault.silent);
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsWatchmeError(WatchmeErrorCode.timeout),
      );
    });

    test('a TV whose only client slot is taken fails as unreachable', () async {
      final sim = await startSim(SharpSimulator());
      await open(driver, sim, transports);
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      expect(sim.overflowClosed, 2);
    });

    test('endpoint attributes fix the profile and the volume scale', () async {
      final sim = await startSim(SharpSimulator(modelReply: null));
      final session = await open(
        driver,
        sim,
        transports,
        endpoint: sim.endpoint.withAttributes({
          SharpAttributes.profile: 'us2014',
          SharpAttributes.volumeMax: '60',
        }),
      );
      expect(session.profile, SharpProfile.us2014);
      expect(session.volumeMax, 60);
      expect(sim.lines, isNot(contains('MNRD1   ')));
    });
  });

  group('power', () {
    test('SetPower(true) from network standby sends POWR1 once; a boot that '
        'still reads 0 is not taken as standby', () async {
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          bootDuration: const Duration(milliseconds: 400),
        ),
      );
      final session = await open(driver, sim, transports);
      final (result, sent) = await run(session, sim, const SetPower(true));
      expect(result, isConfirmed);
      expect(sent, ['POWR1   ']);
      expect(session.state.power!.value, PowerMode.on);
      expect(session.state.power!.confidence, Confidence.inferred);
      await session.refresh();
      expect(sim.lines.last, 'POWR?   ');
      expect(session.state.power!.value, PowerMode.on);
      expect(session.state.power!.confidence, Confidence.inferred);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await session.refresh();
      expect(session.state.power!.value, PowerMode.on);
      expect(session.state.power!.confidence, Confidence.reported);
    });

    test('commands refused while the TV boots are sent again until it is '
        'up', () async {
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          bootDuration: const Duration(milliseconds: 300),
        ),
      );
      final session = await open(driver, sim, transports);
      expect(await session.execute(const SetPower(true)), isConfirmed);
      expect(await session.execute(const SetVolume(50)), isConfirmed);
      expect(sim.volume, 30);
      final attempts = sim.commands.where((c) => c.line == 'VOLM30  ');
      expect(attempts.length, greaterThan(1));
      expect(attempts.last.reply, 'OK');
      expect(attempts.where((c) => c.reply == 'OK'), hasLength(1));
    });

    test('SetPower(false) sends POWR0; a TV still reading on just after is '
        'not believed', () async {
      final sim = await startSim(SharpSimulator(rspw: 2));
      final session = await open(driver, sim, transports);
      final (result, sent) = await run(session, sim, const SetPower(false));
      expect(result, isConfirmed);
      expect(sent, ['POWR0   ']);
      expect(session.state.power!.value, PowerMode.standby);
      sim.power = SharpSimPower.on; // as if POWR? lagged behind
      await session.refresh();
      expect(session.state.power!.value, PowerMode.standby);
      expect(session.state.power!.confidence, Confidence.inferred);
      expect(sim.lines.last, 'POWR?   ', reason: 'no state reads after');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await session.refresh();
      expect(session.state.power!.value, PowerMode.on);
      expect(session.state.power!.confidence, Confidence.reported);
    });

    test(
      'a TV that stops listening in standby is lost, never reported off',
      () async {
        final sim = await startSim(
          SharpSimulator(standbyCloseDelay: const Duration(milliseconds: 20)),
        );
        final session = await open(driver, sim, transports);
        final events = record(session);
        expect(await session.execute(const SetPower(false)), isConfirmed);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
        await settle();
        expect(
          events.whereType<ConnectionChanged>().single.state,
          ConnectionState.disconnected,
        );
        expect(session.state.power!.confidence, Confidence.stale);
        expect(session.state.power!.value, isNot(PowerMode.off));
        final result = await session.execute(const SetPower(true));
        expect(result, isFailedWith(WatchmeErrorCode.unreachable));
      },
    );

    test('a POWR1 that times out is not sent again', () async {
      final sim = await startSim(
        SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
      );
      final session = await open(driver, sim, transports);
      sim.failNext('POWR1', SharpSimFault.silent);
      final (result, sent) = await run(session, sim, const SetPower(true));
      expect(result, isFailedWith(WatchmeErrorCode.timeout));
      expect(sent, ['POWR1   ']);
      expect(session.state.power!.confidence, Confidence.stale);
    });

    test('a POWR1 that timed out may still be booting the TV: a 0 read '
        'just after is not taken as standby', () async {
      final slow = testDriver(
        timings: fastWith(powerOnSettle: const Duration(seconds: 3)),
      );
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          bootDuration: const Duration(seconds: 4),
        ),
      );
      final session = await open(slow, sim, transports);
      sim.failNext('POWR1', SharpSimFault.silent);
      expect(
        await session.execute(const SetPower(true)),
        isFailedWith(WatchmeErrorCode.timeout),
      );
      expect(sim.power, SharpSimPower.booting, reason: 'it did act');
      await session.refresh();
      expect(sim.commands.last.line, 'POWR?   ');
      expect(sim.commands.last.reply, '0');
      expect(session.state.power!.confidence, isNot(Confidence.reported));
    });

    test('a POWR0 that timed out may be turning the TV off: a 1 read just '
        'after is not taken as on', () async {
      final slow = testDriver(
        timings: fastWith(powerOffSettle: const Duration(seconds: 3)),
      );
      final sim = await startSim(SharpSimulator(rspw: 2));
      final session = await open(slow, sim, transports);
      sim.failNext('POWR0', SharpSimFault.silent);
      expect(
        await session.execute(const SetPower(false)),
        isFailedWith(WatchmeErrorCode.timeout),
      );
      sim.power = SharpSimPower.on; // as if POWR? lagged behind
      await session.refresh();
      expect(sim.commands.last.reply, '1');
      expect(session.state.power!.confidence, isNot(Confidence.reported));
      expect(sim.lines.last, 'POWR?   ', reason: 'no state reads after');
    });

    test('EU sets have no power-on command', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final session = await open(driver, sim, transports);
      final (result, sent) = await run(session, sim, const SetPower(true));
      expect(result, isUnsupported(contains('no power-on')));
      expect(sent, isEmpty);
    });

    test('the power-on and power-off keys are the discrete commands', () async {
      final sim = await startSim(SharpSimulator(rspw: 2));
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const PressKey(RemoteKey.powerOff))).$2, [
        'POWR0   ',
      ]);
      expect((await run(session, sim, const PressKey(RemoteKey.powerOn))).$2, [
        'POWR1   ',
      ]);
    });

    test(
      'the POWER key toggle goes only to a TV that reads on right now',
      () async {
        final sim = await startSim(SharpSimulator(rspw: 2));
        final session = await open(driver, sim, transports);
        var (result, sent) = await run(
          session,
          sim,
          const PressKey(RemoteKey.power),
        );
        expect(result, isConfirmed);
        expect(sent, ['POWR?   ', 'RCKY12  ']);
        expect(session.state.power!.value, PowerMode.standby);
        // Within the settle window after the toggle: refused unread.
        (result, sent) = await run(
          session,
          sim,
          const PressKey(RemoteKey.power),
        );
        expect(result, isFailedWith(WatchmeErrorCode.rejected));
        expect(sent, isEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        // In standby: read, then refused; the key would wake the TV.
        (result, sent) = await run(
          session,
          sim,
          const PressKey(RemoteKey.power),
        );
        expect(
          result,
          isFailedWith(WatchmeErrorCode.rejected, message: contains('standby')),
        );
        expect(sent, ['POWR?   ']);
        expect(sim.power, SharpSimPower.networkStandby);
      },
    );

    test('nothing in a refresh or connect can wake the TV', () async {
      final sim = await startSim(
        SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
      );
      final session = await open(driver, sim, transports);
      for (var i = 0; i < 3; i++) {
        await session.refresh();
      }
      expect(sim.power, SharpSimPower.networkStandby);
      expect(writes(sim), isEmpty);
      expect(sim.lines.toSet(), {'POWR?   ', 'MNRD1   '});
    });
  });

  group('volume', () {
    test('SetVolume scales 0-100 to the 0-60 VOLM range', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      final (result, sent) = await run(session, sim, const SetVolume(50));
      expect(result, isConfirmed);
      expect(sent, ['VOLM30  ']);
      expect(session.state.volume!.value, 50);
      expect(session.state.volume!.confidence, Confidence.inferred);
      expect((await run(session, sim, const SetVolume(100))).$2, ['VOLM60  ']);
    });

    test('a 2014 set uses 0-100', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2014),
      );
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const SetVolume(50))).$2, ['VOLM50  ']);
    });

    test('an EU 2013 set (LE747E) uses 0-100', () async {
      final sim = await startSim(
        SharpSimulator(
          profile: SharpSimProfile.eu,
          modelReply: 'LE747E',
          volumeMax: 100,
          volume: 50,
        ),
      );
      final session = await open(driver, sim, transports);
      expect(session.profile, SharpProfile.eu);
      expect(session.volumeMax, 100);
      expect(session.state.volume!.value, 50);
      expect(session.state.volume!.confidence, Confidence.reported);
      expect((await run(session, sim, const SetVolume(30))).$2, ['VOLM30  ']);
      expect(sim.volume, 30);
    });

    test('an unknown model assumes 0-60 until it reads above 60', () async {
      final sim = await startSim(
        SharpSimulator(modelReply: 'MYSTERY', volumeMax: 100, volume: 80),
      );
      final session = await open(driver, sim, transports);
      expect(session.volumeMax, 100);
      expect(session.state.volume!.value, 80);
      expect(session.state.volume!.confidence, Confidence.reported);

      sim.volume = 40;
      final quiet = await startSim(
        SharpSimulator(modelReply: 'MYSTERY', volumeMax: 100, volume: 40),
      );
      final assumed = await open(driver, quiet, transports);
      final events = record(assumed);
      expect(assumed.volumeMax, 60);
      expect(assumed.state.volume!.confidence, Confidence.inferred);
      expect(
        assumed.capabilities.supportFor(Capability.volume).note,
        contains('assumed'),
      );
      quiet.volume = 75;
      await assumed.refresh();
      await settle();
      expect(assumed.volumeMax, 100);
      expect(assumed.state.volume!.value, 75);
      expect(events.whereType<CapabilitiesChanged>(), hasLength(1));
    });

    test('StepVolume is one read and one absolute write, clamped', () async {
      final sim = await startSim(SharpSimulator(volume: 58));
      final session = await open(driver, sim, transports);
      var (result, sent) = await run(session, sim, const StepVolume(5));
      expect(result, isConfirmed);
      expect(sent, ['VOLM?   ', 'VOLM60  ']);
      (result, sent) = await run(session, sim, const StepVolume(-10));
      expect(sent, ['VOLM?   ', 'VOLM50  ']);
      (result, sent) = await run(session, sim, const StepVolume(0));
      expect(sent, isEmpty);
      expect(
        await session.execute(const StepVolume(101)),
        isUnsupported(contains('At most')),
      );
    });

    test(
      'volume keys press VOL+/VOL-, or step the level on 2010 sets',
      () async {
        final sim = await startSim(SharpSimulator());
        final session = await open(driver, sim, transports);
        expect(
          (await run(session, sim, const PressKey(RemoteKey.volumeUp))).$2,
          ['RCKY33  '],
        );
        final old = await startSim(
          SharpSimulator(profile: SharpSimProfile.us2010),
        );
        final s2010 = await open(driver, old, transports);
        expect((await run(s2010, old, const PressKey(RemoteKey.volumeUp))).$2, [
          'VOLM?   ',
          'VOLM21  ',
        ]);
      },
    );

    test('the 2015 firmware steps with keys; a failure after the first is '
        'a partial delivery', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2015Limited),
      );
      final session = await open(driver, sim, transports);
      expect(session.profile, SharpProfile.us2015Limited);
      expect(
        await session.execute(const SetVolume(10)),
        isUnsupported(contains('StepVolume')),
      );
      var (result, sent) = await run(session, sim, const StepVolume(2));
      expect(result, isConfirmed);
      expect(sent, ['RCKY33  ', 'RCKY33  ']);
      sim.failNext('RCKY32', SharpSimFault.drop, skip: 1);
      (result, sent) = await run(session, sim, const StepVolume(-3));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        ((result as Failed).error.cause! as WatchmeError).code,
        WatchmeErrorCode.timeout,
      );
      expect(sent, ['RCKY32  ', 'RCKY32  '], reason: 'stops, never resends');
    });

    test('the TV refuses volume in standby', () async {
      final sim = await startSim(
        SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
      );
      final session = await open(driver, sim, transports);
      final result = await session.execute(const SetVolume(10));
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.rejected,
          message: contains('standby'),
          rawDeviceMessage: 'ERR',
        ),
      );
      final before = sim.lines.length;
      expect(
        await session.execute(const StepVolume(1)),
        isFailedWith(WatchmeErrorCode.rejected, message: contains('standby')),
      );
      expect(sim.lines.sublist(before), ['VOLM?   '], reason: 'no keys');
    });
  });

  group('mute', () {
    test('discrete MUTE1/MUTE2 and the MUTE0 toggle', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const SetMute(true))).$2, ['MUTE1   ']);
      expect(session.state.muted!.value, isTrue);
      expect((await run(session, sim, const SetMute(false))).$2, ['MUTE2   ']);
      expect((await run(session, sim, const SetMute(null))).$2, ['MUTE0   ']);
      expect(session.state.muted!.value, isTrue);
      expect(sim.muted, isTrue);
      expect((await run(session, sim, const PressKey(RemoteKey.mute))).$2, [
        'MUTE0   ',
      ]);
    });

    test('the 2015 firmware has only the toggle', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2015Limited),
      );
      final session = await open(driver, sim, transports);
      expect(
        await session.execute(const SetMute(true)),
        isUnsupported(contains('toggle')),
      );
      expect(await session.execute(const SetMute(null)), isConfirmed);
    });
  });

  group('keys', () {
    test('every mapped key sends its RCKY code on a 2014 set', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2014),
      );
      final session = await open(driver, sim, transports);
      for (final MapEntry(:key, :value) in sharpKeyCodes.entries) {
        if (const {
          RemoteKey.power,
          RemoteKey.mute,
          RemoteKey.channelUp,
          RemoteKey.channelDown,
          RemoteKey.record,
        }.contains(key)) {
          continue;
        }
        final (result, sent) = await run(session, sim, PressKey(key));
        expect(result, isConfirmed, reason: key.name);
        expect(sent, [
          sharpFrame('RCKY', '$value').trimRight().padRight(8),
        ], reason: key.name);
      }
      expect(
        await session.execute(const PressKey(RemoteKey.record)),
        isUnsupported(contains('no record')),
        reason: 'REC is not in the 2014 table',
      );
    });

    test('channel keys use CHUP/CHDW in the profile form', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect(
        (await run(session, sim, const PressKey(RemoteKey.channelUp))).$2,
        ['CHUP0   '],
      );
      final tb = await startSim(SharpSimulator(profile: SharpSimProfile.us4tb));
      final s4tb = await open(driver, tb, transports);
      expect((await run(s4tb, tb, const PressKey(RemoteKey.channelDown))).$2, [
        'CHDW    ',
      ]);
    });

    test('no hold, no unmapped keys, no keys on sets without RCKY', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect(
        await session.execute(const PressKey(RemoteKey.up, KeyAction.down)),
        isUnsupported(contains('press-and-hold')),
      );
      expect(
        await session.execute(const PressKey(RemoteKey.guide)),
        isUnsupported(contains('no guide key')),
      );
      final old = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2010),
      );
      final s2010 = await open(driver, old, transports);
      final (result, sent) = await run(
        s2010,
        old,
        const PressKey(RemoteKey.up),
      );
      expect(result, isUnsupported(contains('no up remote key')));
      expect(sent, isEmpty);
    });
  });

  group('inputs', () {
    test('switches by id and records the input', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const SelectInput('hdmi2'))).$2, [
        'IAVD2   ',
      ]);
      expect(session.state.input!.value, 'hdmi2');
      expect((await run(session, sim, const SelectInput('tuner'))).$2, [
        'ITVD0   ',
      ]);
      expect(
        (await run(session, sim, const PressKey(RemoteKey.inputHdmi3))).$2,
        ['IAVD3   '],
      );
      expect(
        await session.execute(const SelectInput('hdmi9')),
        isUnsupported(contains('hdmi1')),
      );
    });

    test('ERR for the input already in front is confirmed by reading it '
        'back, never by sending it again', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      final (result, sent) = await run(
        session,
        sim,
        const SelectInput('hdmi1'),
      );
      expect(result, isConfirmed);
      expect(sent, ['IAVD1   ', 'IAVD?   ']);
      expect(session.state.input!.confidence, Confidence.reported);
    });

    test('ERR with another input in front is a rejection', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2010),
      );
      final session = await open(driver, sim, transports);
      final result = await session.execute(const SelectInput('pc'));
      expect(result, isUnsupported(contains('hdmi1')), reason: 'no PC on 2010');
      sim.iavdErrWhenCurrent = true;
      sim.failNext('IAVD7', SharpSimFault.malformed);
      expect(
        await session.execute(const SelectInput('av2')),
        isFailedWith(WatchmeErrorCode.protocol, rawDeviceMessage: 'OKR'),
      );
    });

    test('EU numbering: HDMI at IAVD 4-7, the AV key is EXT1', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const SelectInput('hdmi2'))).$2, [
        'IAVD5   ',
      ]);
      expect((await run(session, sim, const PressKey(RemoteKey.inputAv1))).$2, [
        'IAVD1   ',
      ]);
      expect((await run(session, sim, const SelectInput('tv'))).$2, [
        'ITVD    ',
      ]);
    });
  });

  group('channels', () {
    test('direct tuning forms', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const TuneChannel('7.1'))).$2, [
        'DA2P0701',
      ]);
      expect(sim.channel, '7.1');
      expect((await run(session, sim, const TuneChannel('123.45'))).$2, [
        'DC2U123 ',
        'DC2L045 ',
      ]);
      expect(sim.channel, '123.45');
      expect(session.state.input!.value, 'tv');
      expect(
        await session.execute(const TuneChannel('5678')),
        isUnsupported(contains('5-digit')),
      );
    });

    test('a two-part channel that fails after its first part is a partial '
        'delivery', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      sim.failNext('DC2L', SharpSimFault.drop);
      final result = await session.execute(const TuneChannel('123.45'));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(result.partiallyDelivered, isTrue);
    });

    test('a refused second part is still a partial delivery', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      sim.failNext('DC2U', SharpSimFault.malformed);
      expect(
        await session.execute(const TuneChannel('123.45')),
        isFailedWith(WatchmeErrorCode.protocol),
        reason: 'nothing confirmed before the failure',
      );
    });

    test('EU sets tune digital channels with DTVD and use blank '
        'parameters', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const TuneChannel('101'))).$2, [
        'DTVD101 ',
      ]);
      expect(sim.channel, '101');
      expect(session.state.input!.value, 'dtv');
      expect(
        (await run(session, sim, const PressKey(RemoteKey.channelUp))).$2,
        ['CHUP    '],
      );
      expect(sim.channel, '102');
      expect((await run(session, sim, const SelectInput('hdmi1'))).$2, [
        'IAVD4   ',
      ]);
      expect((await run(session, sim, const SelectInput('dtv'))).$2, [
        'IDTV    ',
      ]);
      expect(sim.iavd, isNull);
      expect(
        await session.execute(const TuneChannel('7.1')),
        isUnsupported(contains('1-999')),
      );
    });

    test('JP sets have no direct tuning mapped', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.jp));
      final session = await open(driver, sim, transports);
      expect(
        await session.execute(const TuneChannel('7')),
        isUnsupported(contains('no direct tuning')),
      );
    });
  });

  group('apps and media', () {
    test(
      'Netflix is the only app; its key goes only to a TV that is on',
      () async {
        final sim = await startSim(SharpSimulator(rspw: 2));
        final session = await open(driver, sim, transports);
        expect(
          await session.execute(const ListApps()),
          isConfirmedWith(
            isA<AppListPayload>().having(
              (p) => p.apps.single.id,
              'id',
              'netflix',
            ),
          ),
        );
        var (result, sent) = await run(
          session,
          sim,
          const LaunchApp('netflix'),
        );
        expect(result, isConfirmed);
        expect(sent, ['POWR?   ', 'RCKY59  ']);
        expect(session.state.foregroundApp!.value.id, 'netflix');
        expect(
          await session.execute(const LaunchApp('youtube')),
          isUnsupported(contains('only Netflix')),
        );
        sim.power = SharpSimPower.networkStandby;
        (result, sent) = await run(session, sim, const LaunchApp('netflix'));
        expect(result, isFailedWith(WatchmeErrorCode.rejected));
        expect(sent, ['POWR?   ']);
        expect(sim.power, SharpSimPower.networkStandby);
      },
    );

    test('models without the NETFLIX key cannot open apps', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final session = await open(driver, sim, transports);
      expect(await session.execute(const ListApps()), isUnsupported());
      expect(
        await session.execute(const LaunchApp('netflix')),
        isUnsupported(),
      );
    });

    test('transport keys; no toggle and no seek', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      expect((await run(session, sim, const Media(MediaAction.pause))).$2, [
        'RCKY18  ',
      ]);
      expect(
        await session.execute(const Media(MediaAction.playPause)),
        isUnsupported(contains('no toggle')),
      );
      expect(
        await session.execute(const Media(MediaAction.seek)),
        isUnsupported(),
      );
    });

    test(
      'text, pointer, toasts, casting and screenshots are unsupported',
      () async {
        final sim = await startSim(SharpSimulator());
        final session = await open(driver, sim, transports);
        final before = sim.lines.length;
        for (final c in [
          const TypeText('hello'),
          const MovePointer(1, 1),
          const ShowToast('hi'),
          CastUrl(Uri.parse('http://192.168.1.2/a.mp4')),
          const TakeScreenshot(),
        ]) {
          expect(await session.execute(c), isUnsupported(), reason: c.type);
        }
        expect(sim.lines.length, before);
      },
    );
  });

  group('refresh', () {
    test(
      'reads power, volume, mute and input, and emits what changed',
      () async {
        final sim = await startSim(SharpSimulator());
        final session = await open(driver, sim, transports);
        final events = record(session);
        sim
          ..volume = 45
          ..muted = true
          ..iavd = 3;
        final state = await session.refresh();
        expect(state.volume!.value, 75);
        expect(state.muted!.value, isTrue);
        expect(state.input!.value, 'hdmi3');
        await settle();
        final changed = events.whereType<StateChanged>().single.state;
        expect(changed.power, isNull, reason: 'unchanged');
        expect(changed.volume!.value, 75);
        await session.refresh();
        await settle();
        expect(events.whereType<StateChanged>(), hasLength(1));
      },
    );

    test('the tuner in front makes the input stale', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      sim.iavd = null;
      await session.refresh();
      expect(session.state.input!.confidence, Confidence.stale);
    });

    test('in standby only POWR? is asked, even of a TV that would stay '
        'silent', () async {
      final sim = await startSim(
        SharpSimulator(
          power: SharpSimPower.networkStandby,
          rspw: 2,
          standbyQueries: SharpSimStandbyQueries.silent,
        ),
      );
      final session = await open(driver, sim, transports);
      await session.refresh();
      expect(sim.lines.where((l) => l == 'VOLM?   '), isEmpty);
    });
  });

  group('the connection', () {
    test('requests never overlap, and run in order', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      final before = sim.lines.length;
      final results = await Future.wait([
        session.execute(const SetVolume(10)),
        session.execute(const SetMute(true)),
        session.refresh(),
        session.execute(const SelectInput('hdmi2')),
        session.execute(const StepVolume(1)),
      ]);
      expect(results, hasLength(5));
      expect(sim.pipelined, 0);
      expect(sim.lines.sublist(before), [
        'VOLM6   ',
        'MUTE1   ',
        'POWR?   ',
        'VOLM?   ',
        'MUTE?   ',
        'IAVD?   ',
        'IAVD2   ',
        'VOLM?   ',
        'VOLM7   ',
      ]);
    });

    test('a connection the TV closed while idle is reopened quietly', () async {
      final sim = await startSim(
        SharpSimulator(loginId: 'admin', password: 'secret1'),
      );
      final session = await open(
        driver,
        sim,
        transports,
        credential: login('admin', 'secret1'),
      );
      final events = record(session);
      await sim.dropConnections();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(await session.execute(const SetVolume(20)), isConfirmed);
      await settle();
      // Each login is a check connection, then the login one.
      expect(sim.connectionsAccepted, 4);
      expect(sim.successfulLogins, 2);
      expect(events.whereType<ConnectionChanged>(), isEmpty);
    });

    test('a send that fails after handing its bytes over is never sent '
        'again: the TV may have acted', () async {
      final flaky = _SendFailingTransports();
      final sim = await startSim(SharpSimulator(rspw: 2));
      final session = await open(driver, sim, flaky);
      flaky.network.failAfterSending = 'RCKY33';
      var (result, sent) = await run(
        session,
        sim,
        const PressKey(RemoteKey.volumeUp),
      );
      expect(result, isFailedWith(WatchmeErrorCode.timeout));
      await settle(const Duration(milliseconds: 50));
      expect(sim.lines.where((l) => l == 'RCKY33  '), hasLength(1));
      expect(sim.volume, 21, reason: 'one step, not two');

      flaky.network.failAfterSending = 'RCKY12';
      (result, sent) = await run(session, sim, const PressKey(RemoteKey.power));
      expect(result, isFailedWith(WatchmeErrorCode.timeout));
      await settle(const Duration(milliseconds: 50));
      expect(sim.lines.where((l) => l == 'RCKY12  '), hasLength(1));
      expect(sim.power, isNot(SharpSimPower.on), reason: 'toggled once');

      flaky.network.failAfterSending = 'POWR1';
      (result, sent) = await run(session, sim, const SetPower(true));
      expect(result, isFailedWith(WatchmeErrorCode.timeout));
      await settle(const Duration(milliseconds: 50));
      expect(sim.lines.where((l) => l == 'POWR1   '), hasLength(1));
    });

    // Codex re-review of 7b4855f (Reqall 9526): the close a failed request
    // started was dropped, so the session's close returned, and the next
    // connection went out, while the old one still held the TV's only
    // client slot.
    group('a connection still closing after a send that failed holds the '
        'TV\'s only client slot', () {
      late _SendFailingTransports flaky;
      late SharpSimulator sim;
      late SharpSession session;
      late Completer<void> release;

      setUp(() async {
        flaky = _SendFailingTransports();
        sim = await startSim(SharpSimulator(rspw: 2));
        session = await open(driver, sim, flaky);
        release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        flaky.network
          ..failAfterSending = 'RCKY33'
          ..holdCloseUntil = release.future;
        expect(
          await session.execute(const PressKey(RemoteKey.volumeUp)),
          isFailedWith(WatchmeErrorCode.timeout),
        );
      });

      test('close() returns only once it has closed, so a pairing that '
          'follows gets the slot', () async {
        var closed = false;
        final closing = session.close().then((_) => closed = true);
        await settle(const Duration(milliseconds: 100));
        expect(closed, isFalse, reason: 'the connection is still closing');
        expect(sim.openConnections, 1);

        release.complete();
        await closing;
        expect(sim.overflowClosed, 0);
        final steps = await drive(
          driver.startPairing(sim.endpoint, flaky, testContext)!,
          const [],
        );
        expect(steps.last, isA<Paired>());
      });

      test('the next request connects only once it has closed', () async {
        unawaited(
          Future<void>.delayed(
            const Duration(milliseconds: 200),
            release.complete,
          ),
        );
        expect(await session.execute(const SetMute(true)), isConfirmed);
        expect(sim.overflowClosed, 0);
        expect(sim.muted, isTrue);
      });
    });

    test('close() during a reconnect returns once the connection being '
        'opened has closed again', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      await sim.dropConnections();
      await settle(const Duration(milliseconds: 30));
      final pending = session.execute(const SetMute(true));
      // Connected again, and listening for a login prompt (150 ms).
      await settle(const Duration(milliseconds: 60));
      expect(sim.openConnections, 1);
      await session.close();
      await settle(const Duration(milliseconds: 30));
      expect(sim.openConnections, 0);
      expect(await pending, isFailedWith(WatchmeErrorCode.cancelled));
      expect(sim.lines, isNot(contains('MUTE1   ')));
    });

    test('a timeout closes the connection, so a late reply is never taken '
        'for the next request', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      sim.failNext(
        'MUTE1',
        SharpSimFault.late,
        delay: const Duration(milliseconds: 800),
      );
      final result = await session.execute(const SetMute(true));
      expect(result, isFailedWith(WatchmeErrorCode.timeout));
      expect(sim.muted, isTrue, reason: 'it may have acted, and did');
      sim.volume = 12;
      final state = await session.refresh();
      expect(state.volume!.value, 20);
      expect(sim.connectionsAccepted, 2);
      expect(
        sim.lines.where((l) => l == 'MUTE1   '),
        hasLength(1),
        reason: 'never resent',
      );
    });

    test('a malformed or oversized reply is a protocol error, and the next '
        'request starts clean', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      sim.failNext('VOLM', SharpSimFault.malformed);
      expect(
        await session.execute(const SetVolume(10)),
        isFailedWith(WatchmeErrorCode.protocol, rawDeviceMessage: 'OKR'),
      );
      sim.failNext('MUTE', SharpSimFault.junk);
      expect(
        await session.execute(const SetMute(true)),
        isFailedWith(WatchmeErrorCode.protocol),
      );
      expect(await session.execute(const SetMute(false)), isConfirmed);
      expect(sim.muted, isFalse);
    });

    test('three timeouts in a row report the TV lost', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports);
      final events = record(session);
      for (var i = 0; i < 3; i++) {
        sim.failNext('POWR?', SharpSimFault.silent);
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.timeout),
        );
        await settle();
        expect(
          events.whereType<ConnectionChanged>(),
          i < 2 ? isEmpty : hasLength(1),
          reason: 'after ${i + 1}',
        );
      }
      expect(session.state.power!.confidence, Confidence.stale);
      await session.refresh();
      await settle();
      expect(
        events.whereType<ConnectionChanged>().last.state,
        ConnectionState.connected,
      );
    });

    test('quirky firmware: stray OK, missing CR, leading CR', () async {
      for (final sim in [
        SharpSimulator(strayOk: true),
        SharpSimulator(missingCrBug: true),
        SharpSimulator(leadingCr: true),
      ]) {
        await sim.start();
        final session = await driver.connect(
          sim.endpoint,
          transports,
          null,
        ) as SharpSession;
        expect(
          await session.execute(const PressKey(RemoteKey.channelUp)),
          isConfirmed,
        );
        sim.volume = 33;
        expect((await session.refresh()).volume!.value, 55);
        expect(await session.execute(const SetVolume(10)), isConfirmed);
        expect(await session.execute(const SetMute(true)), isConfirmed);
        expect((await session.refresh()).muted!.value, isTrue);
        expect(sim.volume, 6);
        await session.close();
        await sim.stop();
      }
    });

    test(
      'a login refused on reconnect: ReauthRequired, no secret anywhere',
      () async {
        final sim = await startSim(
          SharpSimulator(loginId: 'admin', password: 'secret1'),
        );
        final session = await open(
          driver,
          sim,
          transports,
          credential: login('admin', 'secret1'),
        );
        final events = record(session);
        sim
          ..password = 'changed'
          ..mismatchText = '\r\nUser Name or Password mismatch: secret1\r\n';
        await sim.dropConnections();
        await settle(const Duration(milliseconds: 30));
        final result = await session.execute(const SetVolume(10));
        await settle();
        expect(result, isFailedWith(WatchmeErrorCode.reauthRequired));
        expect(events.whereType<ReauthRequired>(), hasLength(1));
        expect(
          events.whereType<ConnectionChanged>().single.state,
          ConnectionState.failed,
        );
        final shown = [
          result.toJson(),
          '$result',
          for (final e in events) e.toJson(),
        ].join(' ');
        expect(shown, isNot(contains('secret1')));
        expect(shown, contains('User Name or Password mismatch'));
      },
    );

    test('a TV that starts asking for a login needs pairing again', () async {
      final sim = await startSim(SharpSimulator());
      final session = await open(driver, sim, transports, credential: noLogin);
      final events = record(session);
      sim
        ..loginId = 'admin'
        ..password = 'secret1';
      await sim.dropConnections();
      await settle(const Duration(milliseconds: 30));
      expect(
        await session.execute(const SetVolume(10)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await settle();
      expect(events.whereType<ReauthRequired>(), hasLength(1));
      expect(sim.rawInput.last, isEmpty, reason: 'nothing sent to the prompt');
    });

    test(
      'close stops a command before its next request: a partial delivery',
      () async {
        final sim = await startSim(
          SharpSimulator(profile: SharpSimProfile.us2015Limited),
        );
        final session = await open(driver, sim, transports);
        final gate = sim.holdNext('RCKY33', skip: 1);
        final pending = session.execute(const StepVolume(3));
        await gate.reached;
        await session.close();
        final result = await pending;
        expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(sim.lines.where((l) => l == 'RCKY33  '), hasLength(2));
        expect(
          await session.execute(const SetMute(null)),
          isFailedWith(WatchmeErrorCode.cancelled),
        );
      },
    );

    test('an idle connection is closed and reopened on demand', () async {
      final sim = await startSim(SharpSimulator());
      final idle = testDriver(
        timings: fastWith(idleClose: const Duration(milliseconds: 150)),
      );
      final session = await open(idle, sim, transports);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sim.openConnections, 0);
      expect(await session.execute(const SetVolume(10)), isConfirmed);
      expect(sim.connectionsAccepted, 2);
    });

    test('reconnects respect the gap a TV needs between connections', () async {
      final sim = await startSim(
        SharpSimulator(minReconnectGap: const Duration(milliseconds: 200)),
      );
      final patient = testDriver(
        timings: fastWith(reconnectGap: const Duration(milliseconds: 250)),
      );
      final session = await open(patient, sim, transports);
      await sim.dropConnections();
      await settle(const Duration(milliseconds: 30));
      expect(await session.execute(const SetVolume(10)), isConfirmed);
      expect(sim.quickRefusals, 0);
    });

    test('polls while listened to, and stops when nobody listens', () async {
      final sim = await startSim(SharpSimulator());
      final polling = testDriver(
        pollInterval: const Duration(milliseconds: 100),
      );
      final session = await open(polling, sim, transports);
      final sub = session.events.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await sub.cancel();
      final polled = sim.lines.where((l) => l == 'POWR?   ').length;
      expect(polled, greaterThanOrEqualTo(3));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(sim.lines.where((l) => l == 'POWR?   ').length, polled);
      expect(writes(sim), isEmpty);
    });
  });
}

/// [IoTcpTransports] whose sockets fail a send after handing its bytes to
/// the connection, as a socket may when it breaks mid-write: the bytes may
/// well have reached the TV.
final class _SendFailingTransports extends IoTcpTransports {
  final _SendFailingStack _network = _SendFailingStack();

  @override
  _SendFailingStack get network => _network;
}

final class _SendFailingStack extends IoTcpOnlyStack {
  /// The next send that starts with this text goes out, then throws.
  String? failAfterSending;

  /// When set as that send fails, its socket's close waits for it before
  /// closing anything, as a close that waits for the TV can: until then
  /// the connection holds the TV's client slot.
  Future<void>? holdCloseUntil;

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async => _SendFailingSocket(
    await super.tcp(host, port, tls: tls, timeout: timeout),
    this,
  );
}

final class _SendFailingSocket implements ByteSocket {
  _SendFailingSocket(this._inner, this._stack);

  final ByteSocket _inner;
  final _SendFailingStack _stack;
  Future<void>? _holdClose;

  @override
  void send(List<int> bytes) {
    _inner.send(bytes);
    final fail = _stack.failAfterSending;
    if (fail != null && String.fromCharCodes(bytes).startsWith(fail)) {
      _stack.failAfterSending = null;
      _holdClose = _stack.holdCloseUntil;
      throw StateError('send failed after queueing');
    }
  }

  @override
  Stream<Uint8List> get input => _inner.input;

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() async {
    final hold = _holdClose;
    if (hold != null) await hold;
    await _inner.close();
  }

  @override
  Future<void> get done => _inner.done;

  @override
  String? get peerCertificateSha256 => _inner.peerCertificateSha256;

  @override
  Uint8List? get peerCertificateDer => _inner.peerCertificateDer;
}
