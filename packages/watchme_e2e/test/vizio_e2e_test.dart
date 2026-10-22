@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/vizio_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

/// The VIZIO SmartCast driver end to end: the real engine, the real
/// `dart:io` stack and the driver against the loopback simulator, with both
/// loopback guards on.
///
/// The drivers are the app's, all of them. A device record keeps one flat
/// port map, and these tests must name the simulator's ports, so every
/// other driver's port names point at closed loopback ports
/// ([portsWith]); VIZIO's names (`smartcast`, `smartcastLegacy`) are its
/// own, so no other driver's probe reaches the SmartCast API.
void main() {
  late VizioSimulator sim;
  late Directory dir;
  late E2eSystem system;
  late Map<String, int> ports;

  const keyPath = '/key_command/';

  /// Quick power settling, so a test can wait the quiet period out.
  const quickQuiet = EngineConfig(
    probeTimeout: Duration(seconds: 5),
    connectTimeout: Duration(seconds: 10),
    power: PowerConfig(
      broadcastAddress: '127.255.255.255',
      wakeTimeout: Duration(seconds: 3),
      wakePollInterval: Duration(milliseconds: 200),
      toggleQuietPeriod: Duration(milliseconds: 500),
    ),
  );

  Future<E2eSystem> startSystem({
    EngineConfig config = e2eConfig,
    WakeOnLanSender? wakeOnLan,
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
  }) => E2eSystem.start(
    dir,
    drivers: appDrivers(),
    config: config,
    wakeOnLan: wakeOnLan,
    discovery: discovery,
  );

  /// Closes the running system and starts another on the same state.
  Future<E2eSystem> restart({
    EngineConfig config = e2eConfig,
    WakeOnLanSender? wakeOnLan,
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
  }) async {
    await system.close();
    return system = await startSystem(
      config: config,
      wakeOnLan: wakeOnLan,
      discovery: discovery,
    );
  }

  Future<void> useSim(VizioSimulator next) async {
    sim = next;
    addTearDown(sim.close);
    ports = await portsWith({
      VizioPorts.smartcast: sim.apiPort,
      VizioPorts.smartcastLegacy: sim.legacyPort,
    });
  }

  setUp(() async {
    dir = await tempStateDir();
    await useSim(await VizioSimulator.start(pin: '4321'));
    system = await startSystem();
  });

  Future<DeviceView> addVizio([E2eSystem? on]) =>
      (on ?? system).engine.addManual('127.0.0.1', ports: ports);

  /// Pairs through the engine, answering the PIN the simulator shows.
  Future<List<PairingStep>> pair(String id, [E2eSystem? on]) {
    final flow = (on ?? system).engine.pair(id, vizioDriverId);
    return runPairing(flow.steps, flow.submit, () => sim.displayedPin!);
  }

  Future<String> addAndPair([E2eSystem? on]) async {
    final id = (await addVizio(on)).id;
    expect((await pair(id, on)).last, const Paired.redacted());
    return id;
  }

  DriverView driver([E2eSystem? on]) =>
      (on ?? system).engine.currentDevices.single.drivers.single;

  Iterable<VizioSimRequest> keyRequests() =>
      sim.requests.where((r) => r.path == keyPath);

  group('manual add', () {
    test('recognises the TV by its open device info, reads nothing else '
        'and asks for pairing', () async {
      // Every driver the app registers probes it, Fire TV (whose API port
      // is named `api`) included, and only VIZIO claims it.
      expect(
        system.engine.drivers.map((d) => d.id),
        containsAll(['roku.ecp', 'firetv.lightning', vizioDriverId]),
      );
      final view = await addVizio();
      expect(view.drivers.map((d) => d.driverId), [vizioDriverId]);
      expect(view.manufacturer, 'VIZIO');
      expect(view.model, 'V505-J09');
      expect(view.needsPairing, isTrue);
      // power_mode needs the token: before pairing the power is unknown,
      // never "off".
      expect(view.state.power, isNull);
      expect(sim.requests, isNotEmpty);
      for (final r in sim.requests) {
        expect('${r.method} ${r.path}', 'GET /state/device/deviceinfo');
        expect(r.header('auth'), isNull);
      }
      expect(sim.effects, isEmpty);
      final record = (await system.devices.get(view.id))!;
      expect(record.ports[VizioPorts.smartcast], sim.apiPort);
      expect(record.ports['api'], isNot(sim.apiPort));
    });

    test('before pairing, commands and the power key send nothing', () async {
      final id = (await addVizio()).id;
      sim.clearLog();
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.unauthorized),
      );
      // No power source knows the state, so the power key asks the user.
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(sim.keyPresses, isEmpty);
      expect(
        sim.requests.where((r) => r.path != '/state/device/deviceinfo'),
        isEmpty,
      );
    });

    test('a TV that does not answer is unreachable', () async {
      await sim.vanish();
      await expectLater(
        addVizio(),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('a TV found by mDNS is probed on its advertised port and keeps the '
        'MAC its TXT record names', () async {
      final provider = FakeDiscoveryProvider(
        DiscoveryProviderId.mdns,
        hits: [sim.mdnsHit],
      );
      final found = await restart(discovery: (_) => [provider]);
      await found.engine.discover(const Duration(milliseconds: 300));
      final view = found.engine.currentDevices.single;
      expect(view.drivers.map((d) => d.driverId), [vizioDriverId]);
      expect(view.name, isNotEmpty);
      final record = (await found.devices.get(view.id))!;
      expect(record.allMacs, contains(normalizeMac(sim.mac)));
      expect(record.ports[VizioPorts.smartcast], sim.apiPort);
      expect(provider.scans.single.serviceTypes, contains('_viziocast._tcp'));
    });
  });

  group('pairing through engine.pair', () {
    test('PIN pairing stores a pinned token in a 0600 file and shows it '
        'nowhere', () async {
      final id = (await addVizio()).id;
      final events = record(system.engine.events(id));
      final steps = await pair(id);
      expect(steps.first, isA<EnterCode>());
      expect(steps.last, const Paired.redacted());
      expect(sim.pairingNames, ['watchme']);

      final stored = await system.credentials.read(id, vizioDriverId);
      expect(stored, isA<TokenCredential>());
      final token = stored! as TokenCredential;
      expect(sim.validTokens, {token.token});
      expect(token.peerCertSha256, sim.certificateSha256);
      final file = File(E2eSystem.credentialsPath(dir));
      expect(file.statSync().mode & 0x1ff, 0x180, reason: 'mode 0600');

      final view = system.engine.currentDevices.single;
      expect(view.needsPairing, isFalse);
      expect(driver().paired, isTrue);
      expect(driver().connection, ConnectionState.connected);
      final shown = [
        jsonEncode(view.toJson()),
        for (final s in steps) jsonEncode(s.toJson()),
        for (final e in events) jsonEncode(e.toJson()),
      ].join('\n');
      expect(shown, isNot(contains(token.token)));
      // The session read the power state with the token.
      expect(view.state.power?.value, PowerMode.on);
      expect(view.state.power?.confidence, Confidence.reported);
    });

    test('a wrong PIN can be corrected', () async {
      final id = (await addVizio()).id;
      final flow = system.engine.pair(id, vizioDriverId);
      var attempts = 0;
      final steps = await runPairing(
        flow.steps,
        flow.submit,
        () => attempts++ == 0 ? '0000' : sim.displayedPin!,
      );
      final codes = steps.whereType<EnterCode>().toList();
      expect(codes, hasLength(2));
      expect(codes.last.label, startsWith('Wrong PIN'));
      expect(steps.last, const Paired.redacted());
    });

    test('three wrong PINs fail with the device text, store nothing and '
        'cancel on the TV', () async {
      final id = (await addVizio()).id;
      final flow = system.engine.pair(id, vizioDriverId);
      final steps = await runPairing(flow.steps, flow.submit, () => '0000');
      expect(
        steps.last,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: anyOf(
            contains('PAIRING_DENIED'),
            contains('MAX_CHALLENGES_EXCEEDED'),
          ),
        ),
      );
      expect(sim.validTokens, isEmpty);
      expect(await system.credentials.read(id, vizioDriverId), isNull);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
      expect(sim.cancelCount, 1);
    });

    test('cancelling at the PIN prompt cancels on the TV', () async {
      final id = (await addVizio()).id;
      final flow = system.engine.pair(id, vizioDriverId);
      final steps = await runScriptedPairing(
        flow.steps,
        flow.submit,
        flow.cancel,
        const [],
      );
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      await eventually(() => sim.cancelCount == 1);
      expect(sim.displayedPin, isNull);
      expect(sim.validTokens, isEmpty);
    });

    test('pairing again replaces the old token on the TV instead of adding '
        'one', () async {
      final id = await addAndPair();
      final first = sim.validTokens.single;
      expect((await pair(id)).last, const Paired.redacted());
      final second = sim.validTokens.single;
      expect(second, isNot(first), reason: 'the old token is revoked');
      expect(sim.pairedTokens.values.toSet(), hasLength(1));
      expect(
        ((await system.credentials.read(id, vizioDriverId))! as TokenCredential)
            .token,
        second,
      );
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
    });
  });

  group('commands after pairing', () {
    late String id;

    setUp(() async {
      id = await addAndPair();
      sim.clearLog();
    });

    test('keys reach the TV as discrete key codes', () async {
      for (final key in [
        RemoteKey.home,
        RemoteKey.up,
        RemoteKey.select,
        RemoteKey.back,
      ]) {
        expect(await system.engine.send(id, PressKey(key)), isConfirmed);
      }
      expect(sim.keyPresses, [(4, 3), (3, 8), (3, 2), (4, 0)]);
      for (final r in keyRequests()) {
        expect(r.header('auth'), sim.validTokens.single);
      }
    });

    test('volume and mute are set absolutely and read back', () async {
      final engine = system.engine;
      expect(await engine.send(id, const SetVolume(40)), isConfirmed);
      expect(sim.volume, 40);
      expect(await engine.send(id, const StepVolume(2)), isConfirmed);
      expect(sim.volume, 42);
      expect(await engine.send(id, const SetMute(true)), isConfirmed);
      expect(sim.muted, isTrue);
      // Changed on the TV itself: the next refresh reads it.
      sim
        ..volume = 17
        ..muted = false;
      await engine.refresh(id);
      final state = engine.currentDevices.single.state;
      expect(state.volume?.value, 17);
      expect(state.volume?.confidence, Confidence.reported);
      expect(state.muted?.value, isFalse);
    });

    test('inputs and apps switch the TV', () async {
      final engine = system.engine;
      expect(await engine.send(id, const SelectInput('hdmi2')), isConfirmed);
      expect(sim.currentInput, 'hdmi2');
      await eventually(
        () => engine.currentDevices.single.state.input?.value == 'hdmi2',
        reason: 'the session reports the input it selected',
      );

      final apps = await engine.send(id, const ListApps());
      final list = ((apps as Confirmed).payload! as AppListPayload).apps;
      expect(list.map((a) => a.id), containsAll(['netflix', 'youtube']));
      expect(await engine.send(id, const LaunchApp('netflix')), isConfirmed);
      expect(sim.currentApp?.name, 'Netflix');
      expect(
        await engine.send(id, const LaunchApp('3001')),
        isUnsupported(),
        reason: 'no raw app ids',
      );
    });

    test('a text run cut short after its first request is a partial '
        'delivery and is not retried', () async {
      final text = 'a' * 60;
      final gate = sim.holdNext('PUT', keyPath);
      final result = system.engine.send(id, TypeText(text));
      await gate.reached;
      // The second chunk of keys fails.
      sim.respondOnce('PUT', keyPath, 500, body: 'Unhandled Exception');
      gate.release();
      expect(await result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(keyRequests(), hasLength(2), reason: 'no retry');
      expect(sim.typedText, 'a' * 50);
    });
  });

  group('power', () {
    test('its own power report lets the power key turn the TV off and on '
        'with the discrete keys, never the toggle', () async {
      await restart(config: quickQuiet);
      final id = await addAndPair();
      sim.clearLog();
      final engine = system.engine;

      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isConfirmed,
      );
      expect(sim.keyPresses, [(11, 0)]);
      expect(sim.power, VizioSimPower.standby);

      // Within the quiet period the report may lag: the next press asks.
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(sim.keyPresses, [(11, 0)]);

      // After it, power_mode reads 0 (standby): the key turns it on.
      await Future<void>.delayed(quickQuiet.power.toggleQuietPeriod);
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isConfirmed,
      );
      expect(sim.keyPresses, [(11, 0), (11, 1)]);
      expect(sim.power, VizioSimPower.on);
      expect(sim.keyPresses, isNot(contains((11, 2))));
    });

    test('SetPower is discrete and the state is read back', () async {
      final id = await addAndPair();
      final engine = system.engine;
      expect(await engine.send(id, const SetPower(false)), isDelivered);
      expect(sim.power, VizioSimPower.standby);
      await engine.refresh(id);
      var power = engine.currentDevices.single.state.power;
      expect(power?.value, PowerMode.standby);
      expect(power?.confidence, Confidence.reported);

      expect(await engine.send(id, const SetPower(true)), isDelivered);
      expect(sim.power, VizioSimPower.on);
      await engine.refresh(id);
      power = engine.currentDevices.single.state.power;
      expect(power?.value, PowerMode.on);
      expect(power?.confidence, Confidence.reported);
      expect(sim.keyPresses, [(11, 0), (11, 1)]);
    });

    test('a TV in Eco mode that closed its port is unreachable, not off, '
        'and with no MAC nothing else is tried', () async {
      sim.ecoMode = true;
      final id = await addAndPair();
      final engine = system.engine;
      expect(await engine.send(id, const SetPower(false)), isDelivered);
      expect(sim.listening, isFalse);

      await engine.refresh(id);
      final view = engine.currentDevices.single;
      expect(view.state.power?.value, isNot(PowerMode.off));
      expect(view.state.power?.confidence, Confidence.stale);
      expect(driver().lastError?.code, WatchmeErrorCode.unreachable);

      // Added by IP: no MAC, so no Wake-on-LAN, and no toggle exists.
      sim.clearLog();
      expect(
        await engine.send(id, const SetPower(true)),
        isFailedWith(WatchmeErrorCode.unreachable),
      );
      expect(system.transports.datagramLog, isEmpty);
      expect(sim.power, VizioSimPower.off);
    });

    test('an Eco-mode TV found by mDNS is woken with Wake-on-LAN, then '
        'switched on with the discrete key, and confirmed by a fresh '
        'report', () async {
      sim.ecoMode = true;
      final wol = RecordingWakeOnLan(
        onWake: (_) => sim.wake(delay: const Duration(milliseconds: 300)),
      );
      final provider = FakeDiscoveryProvider(
        DiscoveryProviderId.mdns,
        hits: [sim.mdnsHit],
      );
      await restart(wakeOnLan: wol.send, discovery: (_) => [provider]);
      await system.engine.discover(const Duration(milliseconds: 300));
      final id = system.engine.currentDevices.single.id;
      expect((await pair(id)).last, const Paired.redacted());
      expect(await system.engine.send(id, const SetPower(false)), isDelivered);
      expect(sim.listening, isFalse);
      // Wait out the quiet period of the off.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      sim.clearLog();

      final on = await system.engine.send(id, const SetPower(true));
      expect(wol.sent, contains(normalizeMac(sim.mac)));
      expect(on, isConfirmed);
      expect(sim.power, VizioSimPower.on);
      expect(sim.keyPresses, isNot(contains((11, 2))));
    });
  });

  group('trust', () {
    test('a revoked token surfaces ReauthRequired and is not used again '
        'until the user pairs', () async {
      final id = await addAndPair();
      final events = record(system.engine.events(id));
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      sim.revokeTokens();
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);

      sim.clearLog();
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      expect(keyRequests(), isEmpty);

      expect((await pair(id)).last, const Paired.redacted());
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(system.engine.currentDevices.single.needsPairing, isFalse);
    });

    test('a changed certificate fails the pinned connection before the '
        'token is sent', () async {
      final id = await addAndPair();
      await system.close();
      await sim.restartWithCertificate(VizioSimulatorCertificate.alternate);
      sim.clearLog();

      final restarted = await startSystem();
      final result = await restarted.engine.send(
        id,
        const PressKey(RemoteKey.home),
      );
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.protocol,
          message: contains('does not match'),
        ),
      );
      expect(sim.requests, isEmpty, reason: 'TLS failed before any request');
      expect(driver(restarted).connection, ConnectionState.failed);
      expect(driver(restarted).needsPairing, isFalse);
    });

    test('a TV on the legacy port is remembered there, and connects go '
        'straight to it', () async {
      await useSim(
        await VizioSimulator.start(pin: '4321', servesLegacyPort: true),
      );
      final view = await addVizio();
      final record = (await system.devices.get(view.id))!;
      expect(record.ports[VizioPorts.smartcast], sim.legacyPort);
      expect((await pair(view.id)).last, const Paired.redacted());

      await system.close();
      final restarted = await startSystem();
      restarted.transports.httpLog.clear();
      expect(
        await restarted.engine.send(view.id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(restarted.transports.httpLog, isNotEmpty);
      for (final call in restarted.transports.httpLog) {
        expect(call, contains(':${sim.legacyPort}/'));
      }
    });
  });
}
