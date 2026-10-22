@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

/// The Panasonic VIERA driver end to end: the real engine, the real
/// `dart:io` stack and the app's drivers against the loopback simulator,
/// with both loopback guards on.
///
/// VIERA is the first driver whose only power route is a toggle
/// (`NRC_POWER`), so these tests are also the first end-to-end use of the
/// power orchestrator's toggle rules: the power key never guesses, a
/// toggle goes out only on the user's word (or two agreeing sources),
/// exactly once, and is never resent.
void main() {
  late PanasonicSimulator sim;
  late Directory dir;
  late E2eSystem system;
  late Map<String, int> ports;

  Future<E2eSystem> startSystem({
    EngineConfig config = e2eConfig,
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
  }) => E2eSystem.start(
    dir,
    drivers: appDrivers(),
    config: config,
    discovery: discovery,
  );

  /// Closes the running system and starts another on the same state.
  Future<E2eSystem> restart({
    EngineConfig config = e2eConfig,
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
  }) async {
    await system.close();
    return system = await startSystem(config: config, discovery: discovery);
  }

  Future<void> useSim(PanasonicSimulator next, {int? wolPort}) async {
    await next.start(wolPort: wolPort);
    addTearDown(next.stop);
    sim = next;
    ports = await portsWith({PanasonicPorts.nrc: sim.port});
  }

  setUp(() async {
    dir = await tempStateDir();
    await useSim(
      PanasonicSimulator(
        encrypted: true,
        pac: true,
        bootDelay: Duration.zero,
        wolIgnoredAfterOff: Duration.zero,
      ),
    );
    system = await startSystem();
  });

  Future<DeviceView> addViera() =>
      system.engine.addManual('127.0.0.1', ports: ports);

  /// Pairs through the engine, answering the PIN the simulator shows.
  Future<List<PairingStep>> pair(String id) {
    final flow = system.engine.pair(id, panasonicDriverId);
    return runPairing(flow.steps, flow.submit, () => sim.displayedPin!);
  }

  Future<String> addAndPair() async {
    final id = (await addViera()).id;
    expect((await pair(id)).last, const Paired.redacted());
    return id;
  }

  DriverView driver() => system.engine.currentDevices.single.drivers.single;

  Future<CommandResult> send(String id, Command command) =>
      system.engine.send(id, command);

  /// `X_SendKey` requests that carried the power key.
  int powerKeysSent() => sim.keyLog.where((k) => k == 'NRC_POWER-ONOFF').length;

  group('manual add', () {
    test('recognises an encrypted set without showing a PIN, and asks for '
        'pairing', () async {
      final view = await addViera();
      expect(view.drivers.map((d) => d.driverId), [panasonicDriverId]);
      expect(view.manufacturer, 'Panasonic');
      expect(view.needsPairing, isTrue);
      expect(driver().canPair, isTrue);
      expect(sim.displayedPin, isNull);
      expect(sim.pinDeviceNames, isEmpty);
      expect(sim.keyLog, isEmpty);
      expect(sim.effects, isEmpty);
      // A Pro AV model that answers is on, but that is only inferred.
      expect(view.state.power?.value, PowerMode.on);
      expect(view.state.power?.confidence, Confidence.inferred);
    });

    test('a plain set needs no pairing and takes commands at once', () async {
      await useSim(PanasonicSimulator(bootDelay: Duration.zero));
      final view = await addViera();
      expect(view.needsPairing, isFalse);
      expect(driver().canPair, isFalse);
      expect(
        await system.engine.pair(view.id, panasonicDriverId).steps.single,
        isPairingFailedWith(WatchmeErrorCode.unsupported),
      );
      expect(await send(view.id, const PressKey(RemoteKey.home)), isConfirmed);
      expect(sim.keyLog, ['NRC_HOME-ONOFF']);
      expect(
        sim.requests.map((r) => r.action),
        isNot(contains('X_EncryptedCommand')),
      );
    });

    test('a client on another subnet is told why', () async {
      await useSim(
        PanasonicSimulator(encrypted: true, allowedSubnet: '10.0.0.0/8'),
      );
      await expectLater(
        addViera(),
        throwsA(
          isA<WatchmeError>().having(
            (e) => '${e.message} ${e.cause}',
            'message and cause',
            contains('subnet'),
          ),
        ),
      );
      expect(sim.keyLog, isEmpty);
    });
  });

  group('pairing through engine.pair', () {
    test('PIN pairing stores the app id and key, and shows them '
        'nowhere', () async {
      final id = (await addViera()).id;
      final events = record(system.engine.events(id));
      final steps = await pair(id);
      expect(steps.map((s) => s.runtimeType), [Instruct, EnterCode, Paired]);
      expect(steps.last, const Paired.redacted());
      expect(sim.pinDeviceNames, ['watchme']);

      final stored = await system.credentials.read(id, panasonicDriverId);
      expect(stored, isA<SharedSecretCredential>());
      final credential = stored! as SharedSecretCredential;
      expect(sim.pairings, {credential.username!: credential.secret});
      final file = File(E2eSystem.credentialsPath(dir));
      expect(file.statSync().mode & 0x1ff, 0x180, reason: 'mode 0600');

      expect(driver().paired, isTrue);
      expect(driver().connection, ConnectionState.connected);
      final shown = [
        jsonEncode(system.engine.currentDevices.single.toJson()),
        for (final s in steps) jsonEncode(s.toJson()),
        for (final e in events) jsonEncode(e.toJson()),
      ].join('\n');
      expect(shown, isNot(contains(credential.secret)));
      expect(shown, isNot(contains(credential.username!)));
    });

    test('a wrong PIN shows a new one and asks again', () async {
      final id = (await addViera()).id;
      final flow = system.engine.pair(id, panasonicDriverId);
      var attempts = 0;
      final steps = await runPairing(
        flow.steps,
        flow.submit,
        () => attempts++ == 0
            ? (sim.displayedPin == '0000' ? '1111' : '0000')
            : sim.displayedPin!,
      );
      final codes = steps.whereType<EnterCode>().toList();
      expect(codes, hasLength(2));
      expect(codes.last.label, contains('Wrong PIN'));
      expect(sim.pinDeviceNames, hasLength(2));
      expect(steps.last, const Paired.redacted());
    });

    test('three wrong PINs fail as unauthorized and store nothing', () async {
      await useSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
      final id = (await addViera()).id;
      final flow = system.engine.pair(id, panasonicDriverId);
      final steps = await runPairing(flow.steps, flow.submit, () => '0000');
      expect(
        steps.last,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: contains('600'),
        ),
      );
      expect(sim.pairings, isEmpty);
      expect(await system.credentials.read(id, panasonicDriverId), isNull);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
    });
  });

  group('commands after pairing', () {
    late String id;

    setUp(() async {
      id = await addAndPair();
      sim.clearLog();
    });

    test('keys go out encrypted', () async {
      for (final key in [
        RemoteKey.up,
        RemoteKey.select,
        RemoteKey.back,
        RemoteKey.home,
      ]) {
        expect(await send(id, PressKey(key)), isConfirmed);
      }
      expect(sim.keyLog, [
        'NRC_UP-ONOFF',
        'NRC_ENTER-ONOFF',
        'NRC_RETURN-ONOFF',
        'NRC_HOME-ONOFF',
      ]);
      expect(
        sim.requests
            .where((r) => r.path == '/nrc/control_0')
            .map((r) => r.action)
            .toSet(),
        {'X_EncryptedCommand'},
      );
    });

    test('volume and mute go to RenderingControl and are read back', () async {
      expect(await send(id, const SetVolume(30)), isConfirmed);
      expect(sim.volume, 30);
      expect(await send(id, const StepVolume(-5)), isConfirmed);
      expect(sim.volume, 25);
      expect(await send(id, const SetMute(true)), isConfirmed);
      expect(sim.muted, isTrue);
      expect(sim.keyLog, isEmpty, reason: 'no volume keys');
      sim
        ..volume = 44
        ..muted = false;
      await system.engine.refresh(id);
      final state = system.engine.currentDevices.single.state;
      expect(state.volume?.value, 44);
      expect(state.volume?.confidence, Confidence.reported);
      expect(state.muted?.value, isFalse);
    });

    test('inputs and apps', () async {
      expect(await send(id, const SelectInput('hdmi2')), isConfirmed);
      expect(sim.input, 'H2');
      final listed = await send(id, const ListApps());
      final apps = ((listed as Confirmed).payload! as AppListPayload).apps;
      final netflix = apps.firstWhere((a) => a.name == 'Netflix');
      expect(await send(id, LaunchApp(netflix.id)), isConfirmed);
      expect(sim.foregroundAppId, netflix.id);
    });

    test('a channel cut short after its first digit is a partial delivery, '
        'not retried', () async {
      final gate = sim.holdNext('X_SendKey');
      final result = send(id, const TuneChannel('123'));
      await gate.reached;
      // The TV stops answering after the first digit took effect.
      sim.dropNext('X_SendKey', execute: false);
      gate.release();
      expect(await result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sim.keyLog, ['NRC_D1-ONOFF']);
    });

    test('a pairing deleted on the TV surfaces ReauthRequired', () async {
      final events = record(system.engine.events(id));
      sim
        ..forgetPairings()
        ..expireAllSessions();
      expect(
        await send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
      sim.clearLog();
      expect(
        await send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      expect(sim.requests, isEmpty, reason: 'not used until paired again');
      expect((await pair(id)).last, const Paired.redacted());
      expect(await send(id, const PressKey(RemoteKey.home)), isConfirmed);
    });
  });

  group('power, through a toggle-only driver', () {
    late String id;

    setUp(() async {
      id = await addAndPair();
      // Open the session; the TV is on.
      expect(await send(id, const PressKey(RemoteKey.home)), isConfirmed);
      sim.clearLog();
    });

    test('the power key never guesses: the only source infers the state, '
        'so it asks', () async {
      expect(
        await send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(
        await send(id, const SetPower(false)),
        isUnsupported(Unsupported.needsConfirmation),
        reason: 'one inferred source is not two agreeing ones',
      );
      expect(sim.powerToggles, 0);
      expect(powerKeysSent(), 0);
      expect(sim.power, PanasonicSimPower.on);
    });

    test("the user's answer sends exactly one toggle, on a fresh session, "
        'and a second one waits for the quiet period', () async {
      expect(
        await send(id, const SetPower(false, userConfirmed: true)),
        isConfirmed,
      );
      expect(sim.powerToggles, 1);
      expect(powerKeysSent(), 1);
      // A fresh session right before the toggle.
      final actions = sim.actions;
      expect(actions.sublist(actions.length - 2), [
        'X_GetEncryptSessionId',
        'X_SendKey',
      ]);
      expect(sim.power, PanasonicSimPower.networkStandby);

      expect(
        await send(id, const SetPower(true, userConfirmed: true)),
        isUnsupported(PowerOrchestrator.quietPeriodReason),
      );
      expect(sim.powerToggles, 1);
    });

    test('a refused toggle is not resent', () async {
      sim.respondOnce('X_SendKey', status: 500);
      final result = await send(id, const SetPower(false, userConfirmed: true));
      expect(result, isFailedWith(WatchmeErrorCode.rejected));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
      expect(sim.powerToggles, 0);
    });

    test('a toggle that may have reached the TV is not resent, and no '
        'other toggle follows it', () async {
      sim.dropNext('X_SendKey');
      final result = await send(id, const SetPower(false, userConfirmed: true));
      // A dropped answer may have been delivered: a timeout (or a
      // protocol error), never "unreachable".
      expect(
        result,
        isA<Failed>().having(
          (f) => f.error.code,
          'code',
          anyOf(WatchmeErrorCode.timeout, WatchmeErrorCode.protocol),
        ),
      );
      expect(sim.powerToggles, 1, reason: 'it acted');
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
      // It may have acted: the quiet period started.
      expect(
        await send(id, const SetPower(false, userConfirmed: true)),
        isUnsupported(PowerOrchestrator.quietPeriodReason),
      );
      expect(sim.powerToggles, 1);
    });

    test('an expired session is replaced before the toggle, which goes out '
        'once', () async {
      sim.expireAllSessions();
      expect(
        await send(id, const SetPower(false, userConfirmed: true)),
        isConfirmed,
      );
      expect(sim.powerToggles, 1);
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
    });
  });

  group('power state evidence', () {
    test("a set switched off with its own remote leaves no fresh 'on', so "
        'an unconfirmed off sends no toggle', () async {
      await useSim(
        PanasonicSimulator(
          pac: true,
          dmrAnswersInStandby: true,
          bootDelay: Duration.zero,
        ),
      );
      final id = (await addViera()).id;
      expect(await send(id, const PressKey(RemoteKey.home)), isConfirmed);
      await sim.pressPowerButton();
      expect(sim.power, PanasonicSimPower.networkStandby);
      sim.clearLog();
      expect(
        await send(id, const SetPower(false)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(sim.powerToggles, 0);
      final power = system.engine.currentDevices.single.state.power;
      expect(
        power?.value == PowerMode.on && power?.confidence != Confidence.stale,
        isFalse,
        reason: '$power',
      );
    });

    test('a refused volume read is only a guess at standby: the user who '
        'sees the TV on still gets the toggle', () async {
      await useSim(PanasonicSimulator(bootDelay: Duration.zero));
      final id = (await addViera()).id;
      // The TV is on, but RenderingControl refuses one read (as one field
      // report shows), which the driver takes as a hint of standby.
      sim.respondOnce('GetVolume', status: 400);
      expect(
        await send(id, const SetPower(false, userConfirmed: true)),
        isConfirmed,
      );
      expect(sim.powerToggles, 1);
      expect(sim.power, PanasonicSimPower.networkStandby);
    });
  });

  group('Wake-on-LAN', () {
    /// A plain Pro AV set, found by a discovery that knows its MAC, then
    /// switched off with its own remote while Powered On by Apps is off:
    /// its port closes, and only Wake-on-LAN can switch it on.
    Future<String> discoverThenSwitchOff({required Duration bootDelay}) async {
      await useSim(
        PanasonicSimulator(
          pac: true,
          poweredOnByApps: false,
          bootDelay: bootDelay,
          wolIgnoredAfterOff: Duration.zero,
        ),
        wolPort: 0,
      );
      final provider = FakeDiscoveryProvider(
        DiscoveryProviderId.ssdp,
        hits: [
          DiscoveryHit(
            host: '127.0.0.1',
            provider: DiscoveryProviderId.ssdp,
            port: sim.port,
            serviceType: VieraUrn.nrc,
            mac: sim.mac,
          ),
        ],
      );
      // Magic packets go to the simulator's UDP port on loopback.
      await restart(
        config: EngineConfig(
          probeTimeout: const Duration(seconds: 5),
          connectTimeout: const Duration(seconds: 10),
          power: PowerConfig(
            broadcastAddress: '127.255.255.255',
            wakeOnLanPorts: [sim.wolPort!],
            wakeTimeout: const Duration(seconds: 3),
            wakePollInterval: const Duration(milliseconds: 200),
          ),
        ),
        discovery: (_) => [provider],
      );
      await system.engine.discover(const Duration(milliseconds: 300));
      final view = system.engine.currentDevices.single;
      expect(view.drivers.map((d) => d.driverId), [panasonicDriverId]);
      final record = (await system.devices.get(view.id))!;
      expect(record.allMacs, contains(normalizeMac(sim.mac)));
      await sim.pressPowerButton();
      expect(sim.power, PanasonicSimPower.standby);
      sim.clearLog();
      return view.id;
    }

    test('switches the set on, and a fresh Pro AV answer confirms it; no '
        'toggle is sent', () async {
      final id = await discoverThenSwitchOff(bootDelay: Duration.zero);
      expect(await send(id, const SetPower(true)), isConfirmed);
      expect(sim.wakes, 1);
      expect(sim.power, PanasonicSimPower.on);
      expect(system.transports.datagramLog, isNotEmpty);
      expect(sim.powerToggles, 0);
      expect(powerKeysSent(), 0);
    });

    test('a set still booting when the wait ends is sent-unconfirmed, and '
        'no toggle follows', () async {
      final id = await discoverThenSwitchOff(
        bootDelay: const Duration(seconds: 10),
      );
      expect(await send(id, const SetPower(true)), isSentUnconfirmed);
      expect(sim.wakes, 1);
      expect(sim.powerToggles, 0);
      expect(powerKeysSent(), 0);
    });
  });
}
