import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const dialSt = 'urn:dial-multiscreen-org:service:dial:1';
const macA = 'aa:aa:aa:00:00:01';
const macB = 'bb:bb:bb:00:00:02';

const rokuMatcher = DiscoveryMatcher(
  provider: DiscoveryProviderId.ssdp,
  serviceType: 'roku:ecp',
  portName: 'ecp',
);
const fireDialMatcher = DiscoveryMatcher(
  provider: DiscoveryProviderId.ssdp,
  serviceType: dialSt,
  attributes: [AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Amazon')],
  portName: 'dial',
);
const fireMdnsMatcher = DiscoveryMatcher(serviceType: '_amzn-wplay._tcp');

const volume = CapabilitySupport.yes(
  Capability.volume,
  flags: {CapFlag.relativeOnly},
);

DiscoveryHit ssdp(
  String host, {
  String st = 'roku:ecp',
  int? port = 8060,
  String? usn,
  Map<String, String> attributes = const {},
}) => DiscoveryHit(
  host: host,
  provider: DiscoveryProviderId.ssdp,
  port: port,
  serviceType: st,
  stableId: usn,
  attributes: attributes,
);

DiscoveryHit mdns(String host, {String? id}) => DiscoveryHit(
  host: host,
  provider: DiscoveryProviderId.mdns,
  serviceType: '_amzn-wplay._tcp.local.',
  name: 'Living Room Fire TV',
  stableId: id,
);

void main() {
  group('discovery', () {
    late FakeDiscoveryProvider ssdpProvider;
    late FakeDiscoveryProvider mdnsProvider;
    late FakeDriver roku;
    late FakeDriver fire;
    late Harness h;

    setUp(() {
      ssdpProvider = FakeDiscoveryProvider(DiscoveryProviderId.ssdp);
      mdnsProvider = FakeDiscoveryProvider(DiscoveryProviderId.mdns);
      roku = FakeDriver(
        'roku.ecp',
        ceiling: [volume],
        matchers: [rokuMatcher],
        onProbe: (ep) => matched(
          name: 'Bedroom Roku',
          mac: macA,
          stableId: 'roku:serial:X004',
          manufacturer: 'Roku',
          capabilities: [volume],
        ),
      );
      fire = FakeDriver(
        'firetv.lightning',
        matchers: [fireDialMatcher, fireMdnsMatcher],
      );
      h = Harness(
        drivers: [roku, fire],
        providers: [ssdpProvider, mdnsProvider],
      );
    });
    tearDown(() => h.close());

    test('asks each provider only for the service types drivers match, and '
        'probes with the advertised port', () async {
      ssdpProvider.hits.add(ssdp('192.0.2.10', port: 51234));
      await h.engine.discover(const Duration(seconds: 3));

      expect(ssdpProvider.scans.single.window, const Duration(seconds: 3));
      expect(ssdpProvider.scans.single.serviceTypes, {'roku:ecp', dialSt});
      // The mDNS matcher has no provider, so mDNS is asked for its type.
      expect(mdnsProvider.scans.single.serviceTypes, {'_amzn-wplay._tcp'});

      final probe = roku.probes.single;
      expect(probe.host, '192.0.2.10');
      expect(probe.port('ecp', 8060), 51234);
      expect(fire.probes, isEmpty);

      final device = h.engine.currentDevices.single;
      expect(device.name, 'Bedroom Roku');
      expect(device.manufacturer, 'Roku');
      expect(device.drivers.single.driverId, 'roku.ecp');
      expect(device.supportOf(Capability.volume), volume);
      final record = (await h.repository.all()).single;
      expect(record.mac, macA);
      expect(record.stableId, 'roku:serial:X004');
      expect(record.ports, {'ecp': 51234});
      expect(record.driverIds, ['roku.ecp']);
    });

    test('skips providers no driver could match', () async {
      final bonjour = FakeDiscoveryProvider(DiscoveryProviderId.bonjour);
      final engine = Engine(
        drivers: [roku],
        transports: FakeTransports(),
        discoveryProviders: [bonjour],
        clock: FakeClock(),
      );
      await engine.discover(const Duration(seconds: 1));
      expect(bonjour.scans, isEmpty);
      await engine.close();
    });

    test('ignores hits no driver recognises or whose probe says no', () async {
      ssdpProvider.hits.addAll([
        ssdp('192.0.2.50', st: 'urn:schemas-upnp-org:device:MediaServer:1'),
        ssdp(
          '192.0.2.51',
          st: dialSt,
          attributes: {DiscoveryAttr.manufacturer: 'Google'},
        ),
      ]);
      roku.onProbe = (_) => const ProbeResult.notMatched();
      ssdpProvider.hits.add(ssdp('192.0.2.52'));
      await h.engine.discover(const Duration(seconds: 1));
      expect(h.engine.currentDevices, isEmpty);
      expect(roku.probes.single.host, '192.0.2.52');
      expect(fire.probes, isEmpty);
    });

    test('merges SSDP and mDNS sightings of one device', () async {
      fire.onProbe = (ep) =>
          matched(name: 'Fire TV Stick', mac: macB, stableId: 'uuid:fire-1');
      ssdpProvider.hits.add(
        ssdp(
          '192.0.2.20',
          st: dialSt,
          port: 8009,
          usn: 'uuid:fire-1::$dialSt',
          attributes: {
            DiscoveryAttr.manufacturer: 'Amazon',
            DiscoveryAttr.modelName: 'AFTKA',
          },
        ),
      );
      mdnsProvider.hits.add(mdns('192.0.2.20', id: 'amzn-device-1'));
      await h.engine.discover(const Duration(seconds: 1));

      final device = h.engine.currentDevices.single;
      expect(device.drivers.map((d) => d.driverId), ['firetv.lightning']);
      expect(device.model, 'AFTKA');
      // Both hits fed one probe, with the DIAL port and the attributes.
      final probe = fire.probes.single;
      expect(probe.port('dial', 1), 8009);
      expect(probe.attributes[DiscoveryAttr.manufacturer], 'Amazon');
    });

    test('keeps identity across an IP change (MAC)', () async {
      ssdpProvider.hits.add(ssdp('192.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;

      ssdpProvider.hits
        ..clear()
        ..add(ssdp('192.0.2.77'));
      await h.engine.discover(const Duration(seconds: 1));

      final device = h.engine.currentDevices.single;
      expect(device.id, id);
      expect(device.host, '192.0.2.77');
      expect((await h.repository.get(id))!.host, '192.0.2.77');
    });

    test(
      'keeps identity across an IP change (USN) while probes fail',
      () async {
        fire.onProbe = (_) => const ProbeResult.notMatched(
          error: WatchmeError.unreachable('asleep'),
        );
        DiscoveryHit hit(String host) => ssdp(
          host,
          st: dialSt,
          port: 8009,
          usn: 'uuid:fire-1::$dialSt',
          attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
        );
        ssdpProvider.hits.add(hit('192.0.2.20'));
        await h.engine.discover(const Duration(seconds: 1));
        final first = h.engine.currentDevices.single;
        // The matcher recognised it, so the driver is attached with the error.
        expect(
          first.drivers.single.lastError?.code,
          WatchmeErrorCode.unreachable,
        );

        ssdpProvider.hits
          ..clear()
          ..add(hit('192.0.2.21'));
        await h.engine.discover(const Duration(seconds: 1));
        final second = h.engine.currentDevices.single;
        expect(second.id, first.id);
        expect(second.host, '192.0.2.21');
      },
    );

    test('merges by host when nothing better is known', () async {
      fire.onProbe = (_) => matched(name: 'Fire TV');
      ssdpProvider.hits.add(
        ssdp(
          '192.0.2.30',
          st: dialSt,
          attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
        ),
      );
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;

      ssdpProvider.hits.clear();
      mdnsProvider.hits.add(mdns('192.0.2.30'));
      await h.engine.discover(const Duration(seconds: 1));
      expect(h.engine.currentDevices.single.id, id);
    });

    test('a different MAC at a remembered address is a new device', () async {
      ssdpProvider.hits.add(ssdp('192.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      roku.onProbe = (_) =>
          matched(name: 'Other Roku', mac: macB, stableId: 'roku:serial:Y');
      await h.engine.discover(const Duration(seconds: 1));
      expect(h.engine.currentDevices.map((d) => d.name), [
        'Bedroom Roku',
        'Other Roku',
      ]);
    });

    test('an IP change drops the session; the next command reconnects at '
        'the new address', () async {
      ssdpProvider.hits.add(ssdp('192.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.volumeUp)),
        isConfirmed,
      );
      final oldSession = roku.lastSession;

      ssdpProvider.hits
        ..clear()
        ..add(ssdp('192.0.2.11'));
      await h.engine.discover(const Duration(seconds: 1));
      await pump();
      expect(oldSession.closed, isTrue);

      await h.engine.send(id, const PressKey(RemoteKey.volumeUp));
      expect(roku.connects.map((c) => c.endpoint.host), [
        '192.0.2.10',
        '192.0.2.11',
      ]);
    });

    test('the device stream emits the current list, then changes', () async {
      final lists = <List<DeviceView>>[];
      final sub = h.engine.devices.listen(lists.add);
      await pump();
      ssdpProvider.hits.add(ssdp('192.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      await pump();
      expect(lists.first, isEmpty);
      expect(lists.last.single.name, 'Bedroom Roku');
      await sub.cancel();
    });

    test('a provider that never closes is cut off after the window', () async {
      final stuck = _NeverEndingProvider();
      final engine = Engine(
        drivers: [roku],
        transports: FakeTransports(),
        discoveryProviders: [stuck],
        clock: h.clock,
        config: const EngineConfig(discoveryGrace: Duration(seconds: 1)),
      );
      var done = false;
      final run = engine.discover(const Duration(seconds: 2)).then((_) {
        done = true;
      });
      await h.clock.advance(const Duration(seconds: 2));
      expect(done, isFalse);
      await h.clock.advance(const Duration(seconds: 1));
      await run;
      expect(engine.currentDevices.single.host, '192.0.2.99');
      await engine.close();
    });
  });

  group('addManual', () {
    test('registers one device with every driver that matched', () async {
      final roku = FakeDriver(
        'roku.ecp',
        onProbe: (_) => matched(name: 'TCL Roku TV', mac: macA),
      );
      final dial = FakeDriver('dial', onProbe: (_) => matched(mac: macA));
      final fire = FakeDriver('firetv.lightning');
      final h = Harness(drivers: [roku, fire, dial]);
      addTearDown(h.close);

      final view = await h.engine.addManual('127.0.0.1', ports: {'ecp': 40001});
      expect(view.name, 'TCL Roku TV');
      expect(view.drivers.map((d) => d.driverId), ['roku.ecp', 'dial']);
      for (final d in [roku, fire, dial]) {
        expect(d.probes.single.port('ecp', 8060), 40001);
      }
      final record = (await h.repository.get(view.id))!;
      expect(record.ports, {'ecp': 40001});
      expect(record.driverIds, ['roku.ecp', 'dial']);
    });

    test('the same device added twice keeps one id', () async {
      final roku = FakeDriver(
        'roku.ecp',
        onProbe: (_) => matched(name: 'Roku', mac: macA),
      );
      final h = Harness(drivers: [roku]);
      addTearDown(h.close);
      final first = await h.add('192.0.2.10');
      final second = await h.add('192.0.2.12');
      expect(second, first);
      expect(h.engine.currentDevices.single.host, '192.0.2.12');
    });

    test('throws when nothing matches', () async {
      final h = Harness(
        drivers: [
          FakeDriver('a', onProbe: (_) => const ProbeResult.notMatched()),
          FakeDriver(
            'b',
            onProbe: (_) => const ProbeResult.notMatched(
              error: WatchmeError.rejected('nope', rawDeviceMessage: 'raw'),
            ),
          ),
        ],
      );
      addTearDown(h.close);
      await expectLater(
        h.engine.addManual('192.0.2.1'),
        throwsWatchmeError(
          WatchmeErrorCode.unsupported,
          rawDeviceMessage: 'raw',
        ),
      );
      expect(h.engine.currentDevices, isEmpty);
    });

    test('says unreachable when no driver got an answer', () async {
      final h = Harness(
        drivers: [
          FakeDriver(
            'a',
            onProbe: (_) => const ProbeResult.notMatched(
              error: WatchmeError.unreachable('refused'),
            ),
          ),
        ],
      );
      addTearDown(h.close);
      await expectLater(
        h.engine.addManual('192.0.2.1'),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('a hung probe times out without blocking the others', () async {
      final hung = FakeDriver(
        'hung',
        onProbe: (_) => Completer<ProbeResult>().future,
      );
      final roku = FakeDriver('roku.ecp', onProbe: (_) => matched(name: 'R'));
      final h = Harness(
        drivers: [hung, roku],
        config: const EngineConfig(probeTimeout: Duration(seconds: 5)),
      );
      addTearDown(h.close);
      final added = h.engine.addManual('192.0.2.1');
      await h.clock.advance(const Duration(seconds: 5));
      final view = await added;
      expect(view.drivers.map((d) => d.driverId), ['roku.ecp']);
    });

    test('drivers whose transports are missing are not used', () async {
      final ble = FakeDriver(
        'ble.only',
        backends: const [
          DriverBackend(
            id: 'ble',
            requires: {TransportFeature.bleCentral},
            targets: {DriverTarget.native},
          ),
        ],
        onProbe: (_) => matched(),
      );
      final h = Harness(drivers: [ble]);
      addTearDown(h.close);
      expect(h.engine.drivers, isEmpty);
      await expectLater(
        h.engine.addManual('192.0.2.1'),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
      expect(ble.probes, isEmpty);
    });
  });

  test('start() restores persisted devices and pairing flags', () async {
    final fire = FakeDriver('firetv.lightning', requiresPairing: true);
    final repo = MemoryDeviceRepository([
      DeviceRecord(
        id: 'tv-1',
        name: 'Fire TV',
        host: '192.0.2.20',
        mac: macB,
        ports: const {'dial': 8009},
        driverIds: const ['firetv.lightning', 'not.installed'],
        lastSeen: DateTime.utc(2026, 10, 1),
      ),
    ]);
    final h = Harness(
      drivers: [fire],
      repository: repo,
      credentials: MemoryCredentialStore([token('tv-1', 'firetv.lightning')]),
    );
    addTearDown(h.close);
    await h.engine.start();
    final view = h.view('tv-1');
    expect(view.host, '192.0.2.20');
    expect(view.drivers.single.paired, isTrue);
    expect(view.needsPairing, isFalse);
    // Identity is restored too: a sighting with the MAC merges into it.
    fire.onProbe = (_) => matched(mac: macB);
    expect(await h.add('192.0.2.99'), 'tv-1');
    expect((await repo.get('tv-1'))!.driverIds, [
      'firetv.lightning',
      'not.installed',
    ]);
  });
}

class _NeverEndingProvider implements DiscoveryProvider {
  @override
  String get id => DiscoveryProviderId.ssdp;

  @override
  Set<TransportFeature> get requires => const {};

  @override
  Stream<DiscoveryHit> scan(
    Duration window, {
    Set<String> serviceTypes = const {},
  }) {
    final controller = StreamController<DiscoveryHit>();
    controller.add(ssdp('192.0.2.99'));
    return controller.stream;
  }
}
