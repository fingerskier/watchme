@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

void main() {
  late RokuSimulator sim;
  late E2eSystem system;
  late Map<String, int> ports;

  setUp(() async {
    sim = RokuSimulator();
    await sim.start();
    addTearDown(sim.stop);
    system = await E2eSystem.start(await tempStateDir());
    // The Fire TV driver probes too; point it at refusals so the test does
    // not depend on what else runs on this machine.
    ports = {
      rokuEcpPortName: sim.port,
      'dial': await closedPort(),
      'api': await closedPort(),
    };
  });

  Future<DeviceView> addRoku() =>
      system.engine.addManual('127.0.0.1', ports: ports);

  group('manual add', () {
    test('registers the Roku with its device-info identity', () async {
      final view = await addRoku();
      expect(view.name, 'Simulated Roku TV');
      expect(view.manufacturer, 'TCL');
      expect(view.model, '5-Series');
      expect(view.host, '127.0.0.1');
      expect(view.drivers.map((d) => d.driverId), [rokuDriverId]);
      expect(view.needsPairing, isFalse);
      expect(view.supportOf(Capability.dpadNavigation).usable, isTrue);

      final record = (await system.devices.get(view.id))!;
      expect(record.stableId, 'roku:serial:X01900SIM001');
      expect(record.allMacs, containsAll(['02:00:5e:00:00:01']));
      expect(record.ports[rokuEcpPortName], sim.port);
      expect(system.engine.currentDevices.single.id, view.id);
    });

    test('every request carried an IP-literal Host header', () async {
      await addRoku();
      expect(sim.requests, isNotEmpty);
      for (final r in sim.requests) {
        expect(r.hostHeader, '127.0.0.1:${sim.port}');
        expect(r.status, 200, reason: '${r.method} ${r.path}');
      }
    });

    test('nothing answering is reported as unreachable', () async {
      await sim.stop();
      await expectLater(
        addRoku(),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('the device survives an engine restart', () async {
      final dir = await tempStateDir();
      final first = await E2eSystem.start(dir);
      final view = await first.engine.addManual('127.0.0.1', ports: ports);
      await first.close();

      final second = await E2eSystem.start(dir);
      final reloaded = second.engine.currentDevices.single;
      expect(reloaded.id, view.id);
      expect(reloaded.name, 'Simulated Roku TV');
      expect(
        await second.engine.send(view.id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.keyLog.last.key, 'Home');
    });
  });

  group('commands through engine.send', () {
    late String id;

    setUp(() async {
      id = (await addRoku()).id;
      sim.clearLogs();
    });

    test('keys reach the simulator in order', () async {
      for (final key in [
        RemoteKey.home,
        RemoteKey.down,
        RemoteKey.select,
        RemoteKey.back,
        RemoteKey.volumeUp,
      ]) {
        expect(await system.engine.send(id, PressKey(key)), isConfirmed);
      }
      expect(sim.keyLog, [
        const RokuSimKeyEvent(RokuSimKeyAction.press, 'Home'),
        const RokuSimKeyEvent(RokuSimKeyAction.press, 'Down'),
        const RokuSimKeyEvent(RokuSimKeyAction.press, 'Select'),
        const RokuSimKeyEvent(RokuSimKeyAction.press, 'Back'),
        const RokuSimKeyEvent(RokuSimKeyAction.press, 'VolumeUp'),
      ]);
    });

    test('holds become keydown and keyup', () async {
      await system.engine.send(
        id,
        const PressKey(RemoteKey.right, KeyAction.down),
      );
      await system.engine.send(
        id,
        const PressKey(RemoteKey.right, KeyAction.up),
      );
      expect(sim.keyLog, [
        const RokuSimKeyEvent(RokuSimKeyAction.down, 'Right'),
        const RokuSimKeyEvent(RokuSimKeyAction.up, 'Right'),
      ]);
    });

    test('text arrives exactly, including reserved and non-ASCII', () async {
      const text = 'a b/€+%😀';
      expect(await system.engine.send(id, const TypeText(text)), isConfirmed);
      expect(sim.typedText, text);
    });

    test('launch, with Roku deep-link parameters', () async {
      expect(
        await system.engine.send(
          id,
          const LaunchApp('12', params: {'contentId': '80057281'}),
        ),
        isConfirmed,
      );
      expect(sim.launches.single.appId, '12');
      expect(sim.launches.single.params, {'contentId': '80057281'});
      expect(sim.activeAppId, '12');
    });

    test('inputs and channels switch the TV', () async {
      expect(
        await system.engine.send(id, const SelectInput('hdmi2')),
        isConfirmed,
      );
      expect(sim.activeAppId, 'tvinput.hdmi2');
      expect(
        await system.engine.send(id, const TuneChannel('7.1')),
        isConfirmed,
      );
      expect(sim.launches.last.appId, 'tvinput.dtv');
      expect(sim.launches.last.params, {'ch': '7.1'});
    });

    test('the app list comes back as a payload', () async {
      final result = await system.engine.send(id, const ListApps());
      expect(result, isConfirmed);
      final apps = ((result as Confirmed).payload! as AppListPayload).apps;
      expect(apps.map((a) => a.name), containsAll(['Netflix', 'YouTube']));
      expect(
        apps.firstWhere((a) => a.id == 'tvinput.hdmi1').kind,
        AppKind.input,
      );
    });

    test('power off and on use the discrete keys', () async {
      expect(await system.engine.send(id, const SetPower(false)), isDelivered);
      expect(sim.powerMode, RokuSimPowerMode.ready);
      expect(await system.engine.send(id, const SetPower(true)), isDelivered);
      expect(sim.powerMode, RokuSimPowerMode.powerOn);
      expect(sim.keyLog.map((k) => k.key), ['PowerOff', 'PowerOn']);
    });

    test('refresh reads the foreground app into the device state', () async {
      // Without a session, refresh only probes passively (it must never
      // wake a device); the first command opens the session.
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      sim.setPlaying('837');
      await system.engine.refresh(id);
      final state = system.engine.currentDevices.single.state;
      expect(state.foregroundApp?.value.id, '837');
      expect(state.foregroundApp?.source, rokuDriverId);
      expect(state.nowPlaying?.value.state, PlaybackState.playing);
    });
  });

  group('Limited mode', () {
    test('manual add explains it and marks setup as required', () async {
      sim.controlMode = RokuControlMode.limited;
      final view = await addRoku();
      final driver = view.drivers.single;
      expect(driver.notes.join(' '), contains('Limited'));
      expect(
        driver.setup.map((s) => s.id),
        contains('roku.controlByMobileApps'),
      );
      expect(
        view
            .supportOf(Capability.dpadNavigation)
            .has(CapFlag.userSetupRequired),
        isTrue,
      );
    });

    test('a refused key is Failed(rejected) with the raw 403 body', () async {
      final view = await addRoku();
      sim.controlMode = RokuControlMode.limited;
      final events = record(system.engine.events(view.id));

      final result = await system.engine.send(
        view.id,
        const PressKey(RemoteKey.home),
      );
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.rejected,
          message: contains('Limited'),
          rawDeviceMessage: RokuSimulator.limitedModeBody,
        ),
      );
      expect(sim.keyLog, isEmpty);
      DeviceView current() => system.engine.currentDevices.single;
      expect(
        current().drivers.single.lastError?.rawDeviceMessage,
        RokuSimulator.limitedModeBody,
      );
      expect(
        current()
            .supportOf(Capability.dpadNavigation)
            .has(CapFlag.userSetupRequired),
        isTrue,
      );

      // While Limited, the router does not even try key routes. Switching
      // back to Enabled is noticed by the next refresh (or poll), which
      // reads a gated query again.
      expect(
        await system.engine.send(view.id, const PressKey(RemoteKey.home)),
        isUnsupported(),
      );
      sim.controlMode = RokuControlMode.enabled;
      await system.engine.refresh(view.id);
      await eventually(
        () => events.whereType<CapabilitiesChanged>().isNotEmpty,
        reason: 'CapabilitiesChanged after access returned',
      );
      expect(
        current()
            .supportOf(Capability.dpadNavigation)
            .has(CapFlag.userSetupRequired),
        isFalse,
      );
      expect(
        await system.engine.send(view.id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.keyLog.single.key, 'Home');
    });
  });

  group('Wake-on-LAN', () {
    test('a Roku TV in Limited standby that keeps answering is not reported '
        'as turned on', () async {
      final view = await addRoku();
      sim
        ..controlMode = RokuControlMode.limited
        ..powerMode = RokuSimPowerMode.ready
        ..standbyAcceptsPowerOn = false;
      await system.engine.refresh(view.id);
      // The magic packets go to loopback only (e2eConfig); device-info keeps
      // answering "Ready" throughout, which is not proof of a wake.
      expect(
        await system.engine.send(view.id, const SetPower(true)),
        isSentUnconfirmed,
      );
      expect(sim.powerMode, RokuSimPowerMode.ready);
      expect(
        system.engine.currentDevices.single.state.power?.value,
        PowerMode.standby,
      );
    });
  });

  group('SSDP discovery', () {
    test('finds the simulator through its unicast responder', () async {
      await sim.stop();
      sim = RokuSimulator();
      await sim.start(ssdp: true);
      addTearDown(sim.stop);

      final ssdp = await E2eSystem.start(
        await tempStateDir(),
        discovery: (network) => [
          SsdpDiscovery(
            network,
            group: '127.0.0.1',
            port: sim.ssdpPort!,
            // The simulator answers from loopback, which LAN-only refuses.
            destinationPolicy: e2ePolicy,
            mx: 1,
            attempts: 1,
          ),
        ],
      );
      await ssdp.engine.discover(const Duration(milliseconds: 800));

      expect(sim.ssdpReplies, greaterThan(0));
      final view = ssdp.engine.currentDevices.single;
      expect(view.name, 'Simulated Roku TV');
      expect(view.drivers.map((d) => d.driverId), [rokuDriverId]);
      final record = (await ssdp.devices.get(view.id))!;
      expect(record.ports[rokuEcpPortName], sim.port);
      expect(record.stableId, 'roku:serial:X01900SIM001');

      expect(
        await ssdp.engine.send(view.id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );

      // A second scan finds the same device instead of adding another.
      await ssdp.engine.discover(const Duration(milliseconds: 800));
      expect(ssdp.engine.currentDevices.map((d) => d.id), [view.id]);
    });
  });
}
