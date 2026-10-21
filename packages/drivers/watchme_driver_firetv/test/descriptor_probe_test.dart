import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fake_firetv.dart';

void main() {
  group('descriptor', () {
    test('identifies the driver and its ports', () {
      final d = FireTvDriver().descriptor;
      expect(d.id, 'firetv.lightning');
      expect(d.vendor, 'Amazon');
      expect(d.stability, Stability.reverseEngineered);
      expect(d.requiresPairing, isTrue);
      expect(d.ports, {'dial': 8009, 'api': 8080});
      expect(d.provenance, contains('LibreControl/fire-tv (MIT)'));
      expect(d.provenance, contains('hms-homelab/hms-firetv (MIT)'));
    });

    test('marks every capability undocumented and lists all of them', () {
      final ceiling = fireTvDescriptor.ceiling;
      expect(
        ceiling.map((c) => c.capability).toSet(),
        Capability.values.toSet(),
      );
      for (final c in ceiling) {
        expect(c.has(CapFlag.undocumented), isTrue, reason: '$c');
      }
      expect(
        fireTvDescriptor.ceilingFor(Capability.volume).flags,
        contains(CapFlag.relativeOnly),
      );
      expect(
        fireTvDescriptor.ceilingFor(Capability.powerOn).flags,
        contains(CapFlag.needsNetworkStandby),
      );
      expect(
        fireTvDescriptor.ceilingFor(Capability.textInput).flags,
        contains(CapFlag.needsKeyboardOpen),
      );
      expect(
        fireTvDescriptor.ceilingFor(Capability.castMediaUrl).usable,
        false,
      );
    });

    test('round-trips through JSON', () {
      expect(
        DriverDescriptor.fromJson(fireTvDescriptor.toJson()),
        fireTvDescriptor,
      );
    });

    bool matches(DiscoveryHit hit) =>
        fireTvDescriptor.matchers.any((m) => m.matches(hit));

    test('matches WhisperPlay records carrying amzn.dmgr', () {
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.7',
            provider: 'mdns',
            serviceType: '_amzn-wplay._tcp.local.',
            attributes: {DiscoveryAttr.mdnsInstance: 'amzn.dmgr:ABC123:x:1'},
          ),
        ),
        isTrue,
      );
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.8',
            provider: 'mdns',
            serviceType: '_amzn-wplay._tcp',
            attributes: {DiscoveryAttr.mdnsInstance: 'Echo Show'},
          ),
        ),
        isFalse,
      );
    });

    test('matches _amzn-fireTv._tcp and fills the api port', () {
      const hit = DiscoveryHit(
        host: '10.0.0.7',
        provider: 'bonjour',
        port: 8080,
        serviceType: '_amzn-fireTv._tcp.local.',
      );
      final m = fireTvDescriptor.matchers.firstWhere((m) => m.matches(hit));
      expect(m.portName, FireTvPorts.api);
    });

    test('matches Amazon AFT* DIAL devices over SSDP only', () {
      DiscoveryHit dial(String manufacturer, String model) => DiscoveryHit(
        host: '10.0.0.7',
        provider: DiscoveryProviderId.ssdp,
        serviceType: 'urn:dial-multiscreen-org:service:dial:1',
        attributes: {
          DiscoveryAttr.manufacturer: manufacturer,
          DiscoveryAttr.modelName: model,
        },
      );
      expect(matches(dial('Amazon', 'AFTMA08C15')), isTrue);
      expect(matches(dial('amazon', 'AFTKA')), isTrue);
      expect(matches(dial('Amazon', 'Echo')), isFalse);
      expect(matches(dial('Roku', 'AFT')), isFalse);
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.9',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'roku:ecp',
          ),
        ),
        isFalse,
      );
    });
  });

  group('probe', () {
    late FakeNetworkStack net;
    late FakeTransports transports;
    late FakeFireTv tv;
    final driver = FireTvDriver();

    setUp(() {
      net = FakeNetworkStack();
      transports = FakeTransports(network: net);
      tv = FakeFireTv(net);
    });

    void expectPassive() {
      for (final call in net.httpCalls) {
        // GETs only: a DIAL status read is passive, a DIAL POST would wake.
        expect(call.method, 'GET', reason: '$call');
        expect(call.header('X-Client-Token'), isNull);
      }
      expect(tv.wakes, 0);
    }

    test(
      'a sleeping stick found over SSDP matches without waking it',
      () async {
        final ep = tv.endpoint.withAttributes({
          DiscoveryAttr.manufacturer: 'Amazon',
          DiscoveryAttr.modelName: 'AFTMA08C15',
          DiscoveryAttr.friendlyName: "Utkarsh's Fire TV Stick",
          DiscoveryAttr.udn: 'uuid:8338A484-3A63-3E89-8D0D-8642EE85F305',
        });
        final result = await driver.probe(ep, transports);
        expect(result.matched, isTrue);
        expect(result.requiresPairing, isTrue);
        expect(result.info!.manufacturer, 'Amazon');
        expect(result.info!.model, 'AFTMA08C15');
        expect(result.info!.name, "Utkarsh's Fire TV Stick");
        expect(
          result.info!.stableId,
          'uuid:8338a484-3a63-3e89-8d0d-8642ee85f305',
        );
        expect(result.capabilities, fireTvDescriptor.ceiling);
        expect(result.notes.single, contains('asleep'));
        // The advertisement only names it; the DIAL server's answer shows
        // it is there.
        expect(net.httpCalls.map((c) => c.uri.path), [
          '/v1/FireTV/status',
          '/apps/FireTVRemote',
        ]);
        expect(result.power?.value, PowerMode.standby);
        expect(result.power?.confidence, Confidence.inferred);
        expectPassive();
      },
    );

    test(
      'an advertised Fire TV that answers nothing is unreachable, not matched',
      () async {
        net.setUnreachable(tv.host);
        final result = await driver.probe(
          tv.endpoint.withAttributes({
            DiscoveryAttr.manufacturer: 'Amazon',
            DiscoveryAttr.modelName: 'AFTKA',
            DiscoveryAttr.usn: 'uuid:8338a484-3a63-3e89-8d0d-8642ee85f305',
          }),
          transports,
        );
        expect(result.matched, isFalse);
        expect(result.error?.code, WatchmeErrorCode.unreachable);
        expect(result.notes.single, contains('Neither'));
        expectPassive();
      },
    );

    test('an advertised Fire TV whose DIAL server answers at all matches', () {
      // hms-firetv also counts 404 from the DIAL app URL as "there".
      net.respond(
        'GET',
        '/apps/FireTVRemote',
        HttpResult(404),
        host: tv.host,
        port: tv.dialPort,
      );
      return driver
          .probe(
            tv.endpoint.withAttributes({
              DiscoveryAttr.manufacturer: 'Amazon',
              DiscoveryAttr.modelName: 'AFTKA',
            }),
            transports,
          )
          .then((result) {
            expect(result.matched, isTrue);
            expect(result.power?.value, PowerMode.standby);
          });
    });

    test('an awake device with no advertisement matches on its 401', () async {
      tv.wakeUp();
      final result = await driver.probe(tv.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.notes.single, contains('answered'));
      expect(result.power?.value, PowerMode.on);
      final probeCall = net.httpLog.single;
      expect(probeCall.tls.trustOnFirstUse, isTrue);
      expect(probeCall.call.header('X-Api-Key'), '0987654321');
      expectPassive();
    });

    test('a sleeping stick added by address matches on its DIAL app', () async {
      net.respond(
        'GET',
        '/apps/FireTVRemote',
        HttpResult.text(
          200,
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<service xmlns="urn:dial-multiscreen-org:schemas:dial">'
          '<name>FireTVRemote</name><state>stopped</state></service>',
          contentType: 'text/xml',
        ),
        host: tv.host,
        port: tv.dialPort,
      );
      final result = await driver.probe(tv.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.notes.single, contains('asleep'));
      expect(net.httpCalls.map((c) => c.uri.path), [
        '/v1/FireTV/status',
        '/apps/FireTVRemote',
      ]);
      expectPassive();
    });

    test('a DIAL server without FireTVRemote does not match', () async {
      net.respond(
        'GET',
        '/apps/FireTVRemote',
        HttpResult(404),
        host: tv.host,
        port: tv.dialPort,
      );
      final result = await driver.probe(tv.endpoint, transports);
      expect(result.matched, isFalse);
      // Something answered, so this is "not a Fire TV", not a failure.
      expect(result.error, isNull);
      expectPassive();
    });

    test('reads osVersion when the status call is answered', () async {
      net.respond(
        'GET',
        '/v1/FireTV/status',
        HttpResult.json(200, {
          'osVersion': 'fire-os-7',
          'platformType': 'android',
          'turnstileVersion': '1',
        }),
        host: '10.0.0.20',
      );
      final result = await driver.probe(
        const Endpoint('10.0.0.20'),
        transports,
      );
      expect(result.matched, isTrue);
      expect(result.info!.osVersion, 'fire-os-7');
      expect(result.info!.extra, {
        'platformType': 'android',
        'turnstileVersion': '1',
      });
    });

    test('a silent host without Fire TV attributes does not match', () async {
      final result = await driver.probe(
        const Endpoint('10.0.0.99'),
        transports,
      );
      expect(result.matched, isFalse);
      expect(result.error?.code, WatchmeErrorCode.unreachable);
      expect(net.httpCalls.every((c) => c.method == 'GET'), isTrue);
    });

    test('some other HTTPS service on 8080 does not match', () async {
      net.respond(
        'GET',
        '/v1/FireTV/status',
        HttpResult(404),
        host: '10.0.0.30',
      );
      final result = await driver.probe(
        const Endpoint('10.0.0.30'),
        transports,
      );
      expect(result.matched, isFalse);
    });

    test('recognises WhisperPlay instance names in attributes', () async {
      final result = await driver.probe(
        tv.endpoint.withAttributes({
          DiscoveryAttr.mdnsInstance: 'amzn.dmgr:XYZ:1',
        }),
        transports,
      );
      expect(result.matched, isTrue);
      expect(result.info!.name, isNull);
      expectPassive();
    });

    test('recognises a _amzn-fireTv._tcp mDNS hit by its service', () async {
      final result = await driver.probe(
        tv.endpoint.withAttributes({
          DiscoveryAttr.mdnsService: '_amzn-firetv._tcp',
          DiscoveryAttr.mdnsInstance: 'Den',
        }),
        transports,
      );
      expect(result.matched, isTrue);
      expect(result.info!.name, 'Den');
      expectPassive();

      final echo = await driver.probe(
        const Endpoint('10.0.0.98').withAttributes({
          DiscoveryAttr.mdnsService: '_amzn-wplay._tcp',
          DiscoveryAttr.mdnsInstance: 'Kitchen Echo',
        }),
        transports,
      );
      expect(echo.matched, isFalse, reason: 'WhisperPlay alone is not enough');
    });

    test('names a WhisperPlay hit from its TXT entries', () async {
      final result = await driver.probe(
        tv.endpoint.withAttributes({
          DiscoveryAttr.mdnsService: '_amzn-wplay._tcp',
          DiscoveryAttr.mdnsInstance:
              'amzn.dmgr:0123456789ABCDEF0123456789ABCDEF:abcdef:1',
          'n': 'Den Fire TV',
          'u': '0123456789ABCDEF0123456789ABCDEF',
        }),
        transports,
      );
      expect(result.matched, isTrue);
      expect(result.info!.name, 'Den Fire TV');
      expect(
        result.info!.stableId,
        'amzn.dmgr:0123456789abcdef0123456789abcdef',
      );
      expectPassive();
    });

    test('takes the DIAL port from a same-host Application-URL', () async {
      net.respond(
        'GET',
        '/apps/FireTVRemote',
        HttpResult(200),
        host: tv.host,
        port: 60001,
      );
      final result = await driver.probe(
        tv.endpoint.withAttributes({
          DiscoveryAttr.manufacturer: 'Amazon',
          DiscoveryAttr.modelName: 'AFTKA',
          DiscoveryAttr.applicationUrl: 'http://10.0.0.7:60001/apps/',
        }),
        transports,
      );
      expect(result.endpoint!.port(FireTvPorts.dial, 8009), 60001);
      expect(net.httpCalls.last.uri.port, 60001, reason: 'DIAL asked there');

      final foreign = await driver.probe(
        tv.endpoint.withAttributes({
          DiscoveryAttr.manufacturer: 'Amazon',
          DiscoveryAttr.modelName: 'AFTKA',
          DiscoveryAttr.applicationUrl: 'http://10.0.0.66:60001/apps/',
        }),
        transports,
      );
      expect(foreign.endpoint, isNull);
    });

    test('uses the endpoint api port', () async {
      final custom = FakeFireTv(net, host: '10.0.0.40', apiPort: 18080)
        ..wakeUp();
      final result = await driver.probe(
        Endpoint('10.0.0.40', ports: {FireTvPorts.api: 18080}),
        transports,
      );
      expect(result.matched, isTrue);
      expect(net.httpCalls.last.uri.port, custom.apiPort);
    });

    test('without a network transport it does not match', () async {
      final result = await driver.probe(tv.endpoint, FakeTransports.offline());
      expect(result.matched, isFalse);
      expect(result.error?.code, WatchmeErrorCode.unsupported);
    });
  });
}
