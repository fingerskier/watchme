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
      ssdpProvider.hits.add(ssdp('10.0.2.10', port: 51234));
      await h.engine.discover(const Duration(seconds: 3));

      expect(ssdpProvider.scans.single.window, const Duration(seconds: 3));
      expect(ssdpProvider.scans.single.serviceTypes, {'roku:ecp', dialSt});
      // The mDNS matcher has no provider, so mDNS is asked for its type.
      expect(mdnsProvider.scans.single.serviceTypes, {'_amzn-wplay._tcp'});

      final probe = roku.probes.single;
      expect(probe.host, '10.0.2.10');
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
        ssdp('10.0.2.50', st: 'urn:schemas-upnp-org:device:MediaServer:1'),
        ssdp(
          '10.0.2.51',
          st: dialSt,
          attributes: {DiscoveryAttr.manufacturer: 'Google'},
        ),
      ]);
      roku.onProbe = (_) => const ProbeResult.notMatched();
      ssdpProvider.hits.add(ssdp('10.0.2.52'));
      await h.engine.discover(const Duration(seconds: 1));
      expect(h.engine.currentDevices, isEmpty);
      expect(roku.probes.single.host, '10.0.2.52');
      expect(fire.probes, isEmpty);
    });

    test('merges SSDP and mDNS sightings of one device', () async {
      fire.onProbe = (ep) =>
          matched(name: 'Fire TV Stick', mac: macB, stableId: 'uuid:fire-1');
      ssdpProvider.hits.add(
        ssdp(
          '10.0.2.20',
          st: dialSt,
          port: 8009,
          usn: 'uuid:fire-1::$dialSt',
          attributes: {
            DiscoveryAttr.manufacturer: 'Amazon',
            DiscoveryAttr.modelName: 'AFTKA',
          },
        ),
      );
      mdnsProvider.hits.add(mdns('10.0.2.20', id: 'amzn-device-1'));
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
      ssdpProvider.hits.add(ssdp('10.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;

      ssdpProvider.hits
        ..clear()
        ..add(ssdp('10.0.2.77'));
      await h.engine.discover(const Duration(seconds: 1));

      final device = h.engine.currentDevices.single;
      expect(device.id, id);
      expect(device.host, '10.0.2.77');
      expect((await h.repository.get(id))!.host, '10.0.2.77');
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
        ssdpProvider.hits.add(hit('10.0.2.20'));
        await h.engine.discover(const Duration(seconds: 1));
        final first = h.engine.currentDevices.single;
        // The matcher recognised it, so the driver is attached with the error.
        expect(
          first.drivers.single.lastError?.code,
          WatchmeErrorCode.unreachable,
        );

        ssdpProvider.hits
          ..clear()
          ..add(hit('10.0.2.21'));
        await h.engine.discover(const Duration(seconds: 1));
        final second = h.engine.currentDevices.single;
        expect(second.id, first.id);
        expect(second.host, '10.0.2.21');
      },
    );

    test('merges by host when nothing better is known', () async {
      fire.onProbe = (_) => matched(name: 'Fire TV');
      ssdpProvider.hits.add(
        ssdp(
          '10.0.2.30',
          st: dialSt,
          attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
        ),
      );
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;

      ssdpProvider.hits.clear();
      mdnsProvider.hits.add(mdns('10.0.2.30'));
      await h.engine.discover(const Duration(seconds: 1));
      expect(h.engine.currentDevices.single.id, id);
    });

    test('a different MAC at a remembered address is a new device', () async {
      ssdpProvider.hits.add(ssdp('10.0.2.10'));
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
      ssdpProvider.hits.add(ssdp('10.0.2.10'));
      await h.engine.discover(const Duration(seconds: 1));
      final id = h.engine.currentDevices.single.id;
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.volumeUp)),
        isConfirmed,
      );
      final oldSession = roku.lastSession;

      ssdpProvider.hits
        ..clear()
        ..add(ssdp('10.0.2.11'));
      await h.engine.discover(const Duration(seconds: 1));
      await pump();
      expect(oldSession.closed, isTrue);

      await h.engine.send(id, const PressKey(RemoteKey.volumeUp));
      expect(roku.connects.map((c) => c.endpoint.host), [
        '10.0.2.10',
        '10.0.2.11',
      ]);
    });

    test('the device stream emits the current list, then changes', () async {
      final lists = <List<DeviceView>>[];
      final sub = h.engine.devices.listen(lists.add);
      await pump();
      ssdpProvider.hits.add(ssdp('10.0.2.10'));
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
      expect(engine.currentDevices.single.host, '10.0.2.99');
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
      // A simulator on loopback, which the app (not a hub) allows.
      final h = Harness(
        drivers: [roku, fire, dial],
        destinationPolicy: const DestinationPolicy(allowLoopback: true),
      );
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

    group('LAN-only', () {
      late FakeDriver roku;
      setUp(() {
        roku = FakeDriver(
          'roku.ecp',
          onProbe: (_) => matched(name: 'Roku', mac: macA),
        );
      });

      Future<void> expectRefused(Harness h, String host) async {
        await expectLater(
          h.engine.addManual(host),
          throwsWatchmeError(WatchmeErrorCode.destinationRefused),
          reason: host,
        );
      }

      test('refuses IP literals outside the policy before any driver '
          'runs', () async {
        // Codex finding #6: a public endpoint reached the drivers.
        final h = Harness(drivers: [roku]);
        addTearDown(h.close);
        for (final host in [
          '8.8.8.8', // public
          '100.64.0.1', // CGNAT / overlay VPN
          '100.127.255.254',
          '192.0.2.40', // documentation
          '127.0.0.1', // loopback, not allowed by default
          '::1',
          '::ffff:127.0.0.1',
          '::ffff:8.8.8.8', // IPv4-mapped public
          '2001:4860:4860::8888',
          '64:ff9b::808:808', // NAT64
          '0.0.0.0',
          '::',
          '224.0.0.251',
          'ff02::fb',
          '255.255.255.255',
        ]) {
          await expectRefused(h, host);
        }
        expect(roku.probes, isEmpty);
        expect(h.engine.currentDevices, isEmpty);
      });

      test('the refusal names the address and says why', () async {
        final h = Harness(drivers: [roku]);
        addTearDown(h.close);
        await expectLater(
          h.engine.addManual(' 100.64.1.2 '),
          throwsWatchmeError(
            WatchmeErrorCode.destinationRefused,
            message: allOf(contains('100.64.1.2'), contains('100.64.0.0/10')),
          ),
        );
      });

      test('refuses numeric shorthand a resolver would read as an '
          'address', () async {
        final h = Harness(
          drivers: [roku],
          destinationPolicy: const DestinationPolicy(allowLoopback: true),
        );
        addTearDown(h.close);
        for (final host in [
          '127.1',
          '0x7f.0.0.1',
          '2130706433',
          '010.0.0.1',
          '0x7f000001',
          '10.0.2.300',
        ]) {
          await expectRefused(h, host);
        }
        expect(roku.probes, isEmpty);
      });

      test('allows private, link-local and unique-local addresses', () async {
        final h = Harness(drivers: [roku]);
        addTearDown(h.close);
        for (final host in [
          '10.0.2.10',
          '172.16.5.4',
          '169.254.10.20',
          'fe80::1%eth0',
          'fd12:3456::7',
          '::ffff:10.0.2.11',
        ]) {
          await h.engine.addManual(host);
        }
        expect(roku.probes, hasLength(6));
      });

      test('allows loopback only when the policy does (simulators)', () async {
        final h = Harness(
          drivers: [roku],
          destinationPolicy: const DestinationPolicy(allowLoopback: true),
        );
        addTearDown(h.close);
        expect((await h.engine.addManual('127.0.0.1')).host, '127.0.0.1');
        await expectRefused(h, '8.8.8.8');
        expect(h.engine.destinationPolicy.allowLoopback, isTrue);
      });

      test('leaves host names to the network stack, and refuses '
          'junk', () async {
        final h = Harness(drivers: [roku]);
        addTearDown(h.close);
        await h.engine.addManual('living-room-tv.local');
        expect(roku.probes.single.host, 'living-room-tv.local');
        for (final junk in [
          'http://10.0.2.10',
          '10.0.2.10:8060',
          '[fe80::1]',
          'tv local',
          '-tv.local',
        ]) {
          await expectLater(
            h.engine.addManual(junk),
            throwsWatchmeError(WatchmeErrorCode.unsupported),
            reason: junk,
          );
        }
        expect(roku.probes, hasLength(1));
      });

      test('a host name the network stack refuses reports the refusal, '
          'not "no driver recognised"', () async {
        // Verifier follow-up to Codex finding #6: the refusal was buried as
        // the cause of an `unsupported` error, so the app gave the wrong
        // explanation and no off-LAN hint.
        const refusal = WatchmeError.destinationRefused(
          'Refused to contact public.example (8.8.8.8): it is a public '
          'internet address.',
        );
        final refusing = FakeDriver(
          'roku.ecp',
          onProbe: (_) => const ProbeResult.notMatched(error: refusal),
        );
        final noted = FakeDriver(
          'firetv.lightning',
          onProbe: (_) => const ProbeResult.notMatched(
            error: refusal,
            notes: ['No Fire TV advertisement'],
          ),
        );
        final silent = FakeDriver(
          'dial',
          onProbe: (_) =>
              const ProbeResult.notMatched(notes: ['No DIAL server']),
        );
        final h = Harness(drivers: [refusing, noted, silent]);
        addTearDown(h.close);
        await expectLater(
          h.engine.addManual('public.example'),
          throwsWatchmeError(
            WatchmeErrorCode.destinationRefused,
            message: contains('public.example (8.8.8.8)'),
          ),
        );
        expect(h.engine.currentDevices, isEmpty);
      });

      test('when nothing matches, a refusal from a driver that reached the '
          'device is the explanation, not another driver\'s silence', () async {
        final silent = FakeDriver(
          'roku.ecp',
          onProbe: (_) => const ProbeResult.notMatched(
            error: WatchmeError.unreachable('connection refused'),
          ),
        );
        final refused = FakeDriver(
          'panasonic.viera',
          onProbe: (_) => const ProbeResult.notMatched(
            error: WatchmeError.rejected(
              'Reading the NRC description: the TV accepts only clients on '
              'its own subnet',
              rawDeviceMessage: 'HTTP 403',
            ),
            notes: ['GET /nrc/ddd.xml answered HTTP 403.'],
          ),
        );
        final h = Harness(drivers: [silent, refused]);
        addTearDown(h.close);
        await expectLater(
          h.engine.addManual('10.0.2.77'),
          throwsA(
            allOf(
              isWatchmeError(
                WatchmeErrorCode.unsupported,
                message: allOf(
                  contains('own subnet'),
                  contains('answered HTTP 403'),
                ),
                rawDeviceMessage: 'HTTP 403',
              ),
              isA<WatchmeError>().having(
                (e) => (e.cause! as WatchmeError).code,
                'cause',
                WatchmeErrorCode.rejected,
              ),
            ),
          ),
        );
      });

      test('discovery hits from refused addresses are dropped, and cannot '
          'move a known device there', () async {
        final provider = FakeDiscoveryProvider(DiscoveryProviderId.ssdp);
        final rokuSsdp = FakeDriver(
          'roku.ecp',
          matchers: [rokuMatcher],
          onProbe: (_) => matched(name: 'Roku', mac: macA),
        );
        final h = Harness(drivers: [rokuSsdp], providers: [provider]);
        addTearDown(h.close);
        provider.hits.add(ssdp('10.0.2.10'));
        await h.engine.discover(const Duration(seconds: 1));
        final id = h.engine.currentDevices.single.id;

        provider.hits
          ..clear()
          ..addAll([ssdp('8.8.8.8'), ssdp('100.64.0.9'), ssdp('127.0.0.1')]);
        await h.engine.discover(const Duration(seconds: 1));
        expect(rokuSsdp.probes.map((p) => p.host), ['10.0.2.10']);
        expect(h.engine.currentDevices.single.id, id);
        expect(h.engine.currentDevices.single.host, '10.0.2.10');
      });
    });

    test('the same device added twice keeps one id', () async {
      final roku = FakeDriver(
        'roku.ecp',
        onProbe: (_) => matched(name: 'Roku', mac: macA),
      );
      final h = Harness(drivers: [roku]);
      addTearDown(h.close);
      final first = await h.add('10.0.2.10');
      final second = await h.add('10.0.2.12');
      expect(second, first);
      expect(h.engine.currentDevices.single.host, '10.0.2.12');
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
        h.engine.addManual('10.0.2.1'),
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
        h.engine.addManual('10.0.2.1'),
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
      final added = h.engine.addManual('10.0.2.1');
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
        h.engine.addManual('10.0.2.1'),
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
        host: '10.0.2.20',
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
    expect(view.host, '10.0.2.20');
    expect(view.drivers.single.paired, isTrue);
    expect(view.needsPairing, isFalse);
    // Identity is restored too: a sighting with the MAC merges into it.
    fire.onProbe = (_) => matched(mac: macB);
    expect(await h.add('10.0.2.99'), 'tv-1');
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
    controller.add(ssdp('10.0.2.99'));
    return controller.stream;
  }
}
