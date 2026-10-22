@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/io_http_stack.dart';

void main() {
  group('descriptor', () {
    const d = panasonicDescriptor;

    test('identity, port, backend and stability', () {
      expect(d.id, 'panasonic.viera');
      expect(PanasonicDriver().descriptor, same(d));
      expect(d.vendor, 'Panasonic');
      expect(d.ports, {'nrc': 55000});
      expect(d.stability, Stability.reverseEngineered);
      expect(d.requiresPairing, isFalse);
      expect(d.powerQuietPeriod, const Duration(seconds: 30));
      expect(d.backends.single.targets, {DriverTarget.native});
      expect(d.backends.single.requires, {
        TransportFeature.httpReadCrossOrigin,
        TransportFeature.customHeaders,
      });
      expect(DriverDescriptor.fromJson(d.toJson()), d);
    });

    test('provenance names the references and says nothing was copied', () {
      for (final ref in [
        'panasonic-viera (MIT)',
        'homebridge-vieramatic (Apache-2.0)',
        'Home Assistant',
        'FastyBird',
        'node-panasonic-viera (MIT)',
        'No code was copied',
      ]) {
        expect(d.provenance, contains(ref));
      }
    });

    test('the power ceiling is truthful: a toggle only, state inferred', () {
      final off = d.ceilingFor(Capability.powerOff);
      expect(off.level, Support.partial);
      expect(off.flags, contains(CapFlag.toggleOnly));
      final on = d.ceilingFor(Capability.powerOn);
      expect(
        on.flags,
        containsAll([
          CapFlag.toggleOnly,
          CapFlag.needsNetworkStandby,
          CapFlag.userSetupRequired,
        ]),
      );
      final state = d.ceilingFor(Capability.powerState);
      expect(state.level, Support.partial);
      expect(state.note, contains('Inferred only'));
    });

    test('every capability is listed once and marked undocumented', () {
      expect(
        d.ceiling.map((c) => c.capability).toSet(),
        Capability.values.toSet(),
      );
      expect(d.ceiling, hasLength(Capability.values.length));
      for (final c in d.ceiling) {
        expect(c.has(CapFlag.undocumented), isTrue, reason: c.capability.name);
      }
      expect(d.ceilingFor(Capability.volume).level, Support.yes);
      expect(d.ceilingFor(Capability.mute).level, Support.yes);
      expect(
        d.ceilingFor(Capability.volume).has(CapFlag.relativeOnly),
        isFalse,
      );
      for (final cap in [
        Capability.pointer,
        Capability.notificationToast,
        Capability.screenshot,
        Capability.castMediaUrl,
      ]) {
        expect(d.ceilingFor(cap).level, Support.no, reason: cap.name);
      }
    });

    test('user setup steps', () {
      expect(d.userSetup.map((s) => s.id), [
        'panasonic.tvRemote',
        'panasonic.sameSubnet',
        'panasonic.poweredOnByApps',
        'panasonic.wakeOnLan',
      ]);
      expect(d.userSetup.first.detail, contains('TV Remote App Settings'));
      expect(d.userSetup.first.detail, contains('VIERA Remote Settings'));
    });

    test('matchers take the NRC service, the NRC device, and VIERA '
        'renderers only', () {
      DiscoveryHit hit(String st, [Map<String, String> attrs = const {}]) =>
          DiscoveryHit(
            host: '10.0.0.5',
            provider: DiscoveryProviderId.ssdp,
            port: 55000,
            serviceType: st,
            attributes: attrs,
          );
      bool matched(DiscoveryHit h) => d.matchers.any((m) => m.matches(h));
      expect(
        matched(hit('urn:panasonic-com:service:p00NetworkControl:1')),
        isTrue,
      );
      expect(
        matched(hit('urn:panasonic-com:device:p00RemoteController:1')),
        isTrue,
      );
      const renderer = 'urn:schemas-upnp-org:device:MediaRenderer:1';
      expect(
        matched(
          hit(renderer, {
            DiscoveryAttr.manufacturer: 'Panasonic',
            DiscoveryAttr.modelName: 'Panasonic VIErA',
          }),
        ),
        isTrue,
      );
      expect(
        matched(
          hit(renderer, {
            DiscoveryAttr.manufacturer: 'Panasonic',
            DiscoveryAttr.modelName: 'Panasonic VIERA',
          }),
        ),
        isFalse,
      );
      expect(
        matched(
          hit(renderer, {
            DiscoveryAttr.manufacturer: 'Samsung',
            DiscoveryAttr.modelName: 'Panasonic VIErA',
          }),
        ),
        isFalse,
      );
      expect(d.matchers.every((m) => m.portName == 'nrc'), isTrue);
    });

    test('X_NRCCAP narrows the ceiling', () {
      final et60 = panasonicCapabilities(
        nrcCapabilities: PanasonicSimulator.et60NrcCapabilities
            .split(',')
            .toSet(),
      );
      expect(et60.supportFor(Capability.powerOn).level, Support.no);
      expect(et60.supportFor(Capability.powerOff).level, Support.partial);
      final noLaunch = panasonicCapabilities(nrcCapabilities: {'VR_POWER'});
      expect(noLaunch.supportFor(Capability.appLaunch).level, Support.partial);
      expect(noLaunch.supportFor(Capability.powerOn).level, Support.partial);
      final unknown = panasonicCapabilities();
      expect(unknown, panasonicCeiling);
      final pac = panasonicCapabilities(pac: true);
      expect(pac.supportFor(Capability.inputSwitch).note, contains('PAC'));
    });
  });

  group('probe', () {
    late PanasonicSimulator sim;
    final transports = IoHttpTransports();
    final driver = PanasonicDriver(pollInterval: null);

    Future<PanasonicSimulator> startSim(PanasonicSimulator s) async {
      await s.start();
      addTearDown(s.stop);
      return sim = s;
    }

    void expectPassive() {
      expect(sim.keyLog, isEmpty);
      expect(sim.pinDeviceNames, isEmpty);
      expect(sim.sessionsOpened, 0);
      expect(sim.effects, isEmpty);
      for (final r in sim.requests) {
        expect(
          r.method == 'GET' || r.action == 'GetVolume',
          isTrue,
          reason: '$r',
        );
      }
    }

    test(
      'a plain TV that is on: identity, no pairing, no power claim',
      () async {
        await startSim(PanasonicSimulator());
        final r = await driver.probe(sim.endpoint, transports);
        expect(r.matched, isTrue);
        expect(r.info!.name, '49DX600 Series');
        expect(r.info!.manufacturer, 'Panasonic');
        expect(r.info!.model, 'TX-49DX600EA');
        expect(r.info!.stableId, 'uuid:4d454931-0200-1090-8001-80c755b86c63');
        expect(r.info!.osVersion, isNull);
        // MAC candidates are kept apart until hardware confirms them.
        expect(r.info!.mac, isNull);
        expect(
          r.info!.extra,
          containsPair('udnMacCandidate', '80:c7:55:b8:6c:63'),
        );
        expect(
          r.info!.extra,
          containsPair('nrcIdMacCandidate', '28:24:ff:38:5e:27'),
        );
        expect(r.info!.extra, containsPair('nrcVersion', 'NRC-3.00'));
        expect(r.info!.extra, containsPair('encrypted', 'false'));
        expect(r.requiresPairing, isFalse);
        expect(r.endpoint!.attributes, {panasonicEncryptionAttr: 'none'});
        expect(r.endpoint!.ports, sim.endpoint.ports);
        // RenderingControl answering proves nothing about power.
        expect(r.power, isNull);
        expect(r.notes.single, contains('needs no pairing'));
        expect(
          r.capabilities,
          panasonicCapabilities(
            nrcCapabilities: PanasonicSimulator.defaultNrcCapabilities
                .split(',')
                .toSet(),
          ),
        );
        expectPassive();
        expect(sim.requests.map((q) => '${q.method} ${q.path}'), [
          'GET /nrc/ddd.xml',
          'GET /nrc/sdd_0.xml',
          'GET /pac/ddd.xml',
          'POST /dmr/control_0',
        ]);
      },
    );

    test('an encrypted TV needs pairing', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.requiresPairing, isTrue);
      expect(r.endpoint!.attributes[panasonicEncryptionAttr], 'aes');
      expect(r.notes.first, contains('pair with it'));
      expectPassive();
    });

    test('a PAC model that is on reports on, inferred', () async {
      await startSim(PanasonicSimulator(pac: true));
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.power!.value, PowerMode.on);
      expect(r.power!.confidence, Confidence.inferred);
      expect(r.power!.source, 'panasonic.viera');
      expect(r.info!.extra['pac'], 'true');
      expect(
        r.capabilities.supportFor(Capability.inputSwitch).note,
        contains('PAC'),
      );
      // PAC said on: no RenderingControl read was needed.
      expect(sim.requests.where((q) => q.method == 'POST'), isEmpty);
      expectPassive();
    });

    test('network standby: still matched; RenderingControl 400 is an '
        'inferred standby, never reported', () async {
      await startSim(
        PanasonicSimulator(power: PanasonicSimPower.networkStandby, pac: true),
      );
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.matched, isTrue);
      expect(r.power!.value, PowerMode.standby);
      expect(r.power!.confidence, Confidence.inferred);
      expect(r.notes.last, contains('standby'));
      expectPassive();
    });

    test('network standby on a set whose RenderingControl answers: no '
        'power claim, never "on"', () async {
      await startSim(
        PanasonicSimulator(
          power: PanasonicSimPower.networkStandby,
          dmrAnswersInStandby: true,
        ),
      );
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.matched, isTrue);
      expect(r.power, isNull);
    });

    test('standby without network: not matched, unreachable', () async {
      await startSim(PanasonicSimulator(power: PanasonicSimPower.standby));
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.matched, isFalse);
      expect(r.error!.code, WatchmeErrorCode.unreachable);
    });

    test('a client on another subnet learns why', () async {
      await startSim(PanasonicSimulator(allowedSubnet: '192.168.7.0/24'));
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.matched, isFalse);
      expect(r.error!.code, WatchmeErrorCode.rejected);
      expect(r.error!.message, contains('own subnet'));
      expect(r.error!.rawDeviceMessage, 'HTTP 403');
    });

    test(
      'a 2013 set without VR_POWER or VR_WOL cannot be switched on',
      () async {
        await startSim(
          PanasonicSimulator(
            nrcCapabilities: PanasonicSimulator.et60NrcCapabilities,
            modelNumber: 'ET60',
          ),
        );
        final r = await driver.probe(sim.endpoint, transports);
        expect(r.capabilities.supportFor(Capability.powerOn).level, Support.no);
        expect(r.info!.model, 'ET60');
      },
    );

    test('optional reads are skipped once the budget is spent', () async {
      await startSim(
        PanasonicSimulator(latency: const Duration(milliseconds: 250)),
      );
      final slow = PanasonicDriver(
        probeTimeout: const Duration(seconds: 2),
        probeBudget: const Duration(milliseconds: 600),
        pollInterval: null,
      );
      final r = await slow.probe(sim.endpoint, transports);
      expect(r.matched, isTrue);
      expect(sim.requests.map((q) => q.path), [
        '/nrc/ddd.xml',
        '/nrc/sdd_0.xml',
      ]);
    });

    test(
      'something that is not a VIERA does not match, without error',
      () async {
        final net = FakeNetworkStack()
          ..respond(
            'GET',
            '/nrc/ddd.xml',
            HttpResult.text(
              200,
              '<root><device><deviceType>urn:schemas-upnp-org:device:'
              'MediaServer:1</deviceType></device></root>',
            ),
          );
        final r = await driver.probe(
          const Endpoint('10.0.0.9'),
          FakeTransports(network: net),
        );
        expect(r.matched, isFalse);
        expect(r.error, isNull);
        final notFound = FakeNetworkStack(
          unmatchedHttp: UnmatchedHttp.notFound,
        );
        final r2 = await driver.probe(
          const Endpoint('10.0.0.9'),
          FakeTransports(network: notFound),
        );
        expect(r2.matched, isFalse);
        expect(r2.error, isNull);
        expect(net.httpCalls.single.uri.port, 55000);
      },
    );

    test('a TV whose service description fails is matched with pairing '
        'unknown and no endpoint attribute', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      sim.respondOnce('/nrc/sdd_0.xml', status: 500);
      final r = await driver.probe(sim.endpoint, transports);
      expect(r.matched, isTrue);
      expect(r.requiresPairing, isFalse);
      expect(r.endpoint, isNull);
      expect(r.notes.first, contains('not known yet'));
    });

    test('without a network stack the probe says so', () async {
      final r = await driver.probe(
        const Endpoint('10.0.0.9'),
        FakeTransports.offline(),
      );
      expect(r.error!.code, WatchmeErrorCode.unsupported);
    });
  });
}
