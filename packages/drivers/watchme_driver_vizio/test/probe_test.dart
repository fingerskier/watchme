@TestOn('vm')
library;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';
import 'package:watchme_testkit/vizio_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';
import 'support/io_http_stack.dart';

/// A deviceinfo answer as a TV on firmware 4.x sends it.
HttpResult _deviceInfo({String root = 'tv_settings'}) => HttpResult.json(200, {
  'ITEMS': [
    {
      'CNAME': 'deviceinfo',
      'VALUE': {
        'SETTINGS_ROOT': root,
        'SYSTEM_INFO': {
          'MODEL_NAME': 'M65Q7-H1',
          'SERIAL_NUMBER': 'LTMABC123',
          'VERSION': '3.720.9.1-1',
        },
        'CAST_NAME': 'Den',
      },
    },
  ],
  'STATUS': {'RESULT': 'SUCCESS', 'DETAIL': 'Success'},
  'URI': '/state/device/deviceinfo',
});

void main() {
  group('against the simulator', () {
    late VizioSimulator sim;
    final transports = IoHttpTransports();
    final driver = testDriver();

    setUp(() async {
      sim = await VizioSimulator.start(seed: 3);
    });

    tearDown(() => sim.close());

    test(
      'matches by reading deviceinfo, with no token and nothing else',
      () async {
        final result = await driver.probe(sim.endpoint, transports);
        expect(result.matched, isTrue);
        expect(result.requiresPairing, isTrue);
        expect(result.capabilities, vizioDescriptor.ceiling);
        expect(result.endpoint, isNull);
        final info = result.info!;
        expect(info.manufacturer, 'VIZIO');
        expect(info.model, 'V505-J09');
        expect(info.name, 'Living Room TV');
        expect(info.stableId, 'vizio:serial:LWZSIM0000001');
        expect(info.osVersion, '3.720.9.1-1');
        expect(info.extra['apiPort'], '${sim.apiPort}');

        // Passive: one unauthenticated GET, no pairing prompt, no change.
        expect(lines(sim.requests), ['GET /state/device/deviceinfo']);
        expect(sim.requests.single.header('auth'), isNull);
        expect(sim.effects, isEmpty);
        expect(sim.displayedPin, isNull);
        expect(sim.power, VizioSimPower.on);
      },
    );

    test('reports no power: power_mode needs the token', () async {
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.power, isNull);
      expect(result.notes.join(' '), contains('needs pairing'));
      // In standby too: the probe cannot tell, so it says nothing.
      await sim.pressPowerOnRemote();
      expect((await driver.probe(sim.endpoint, transports)).power, isNull);
    });

    test('falls back to the legacy port and records it', () async {
      final legacy = await VizioSimulator.start(servesLegacyPort: true);
      addTearDown(legacy.close);
      final result = await driver.probe(legacy.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.endpoint?.ports['smartcast'], legacy.legacyPort);
      expect(result.info!.extra['apiPort'], '${legacy.legacyPort}');
      expect(
        transports.network.calls
            .map((c) => c.uri.port)
            .toList()
            .sublist(transports.network.calls.length - 2),
        [legacy.apiPort, legacy.legacyPort],
      );
    });

    test('a discovered TV is found on the port its TXT hsp names, which the '
        'probe records', () async {
      // As discovery hands it over: no port names, only the mDNS record.
      final result = await driver.probe(
        Endpoint('127.0.0.1', attributes: sim.mdnsHit.attributes),
        transports,
      );
      expect(result.matched, isTrue);
      expect(result.endpoint?.ports, {'smartcast': sim.apiPort});
      expect(result.info!.mac, 'f0:4f:e0:2d:6e:20');
      // The advertised port answered first: 7345 and 9000 were not tried.
      expect(transports.network.calls.last.uri.port, sim.apiPort);
      expect(lines(sim.requests), ['GET /state/device/deviceinfo']);
    });

    test('an Eco-off TV does not match, as unreachable', () async {
      final off = await VizioSimulator.start(power: VizioSimPower.off);
      addTearDown(off.close);
      final result = await driver.probe(off.endpoint, transports);
      expect(result.matched, isFalse);
      expect(result.error?.code, WatchmeErrorCode.unreachable);
      expect(result.error?.message, contains('Eco'));
      expect(off.requests, isEmpty);
    });

    test('a sound bar is not claimed', () async {
      sim.settingsRoot = 'audio_settings';
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isFalse);
      expect(result.error?.code, WatchmeErrorCode.unsupported);
    });

    test('a port that answers something else does not match', () async {
      sim.respondOnce(
        'GET',
        '/state/device/deviceinfo',
        200,
        json: {'hello': 'world'},
      );
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isFalse);
      expect(result.error, isNull);
      expect(result.notes.single, contains('not with VIZIO'));
    });

    test(
      'mDNS attributes give the MAC and the room name as a fallback',
      () async {
        sim.castName = '';
        final result = await driver.probe(
          sim.endpoint.withAttributes(sim.mdnsHit.attributes),
          transports,
        );
        expect(result.info!.mac, 'f0:4f:e0:2d:6e:20');
        expect(result.info!.name, 'Living Room');
      },
    );
  });

  group('with a scripted network', () {
    late FakeNetworkStack net;
    late FakeTransports transports;
    const host = '10.0.0.9';
    final driver = VizioDriver();

    setUp(() {
      net = FakeNetworkStack();
      transports = FakeTransports(network: net);
      net.serveTls(host, 7345, certificateSha256: fakeFingerprint('vizio'));
      net.serveTls(host, 9000, certificateSha256: fakeFingerprint('vizio'));
    });

    test('tries the default 7345 first and needs no refinement', () async {
      net.respond('GET', '/state/device/deviceinfo', _deviceInfo(), port: 7345);
      final result = await driver.probe(const Endpoint(host), transports);
      expect(result.matched, isTrue);
      expect(result.endpoint, isNull);
      expect(
        net.httpCalls.single.uri.toString(),
        'https://$host:7345/state/device/deviceinfo',
      );
      expect(net.httpLog.single.tls, const TlsPolicy.firstUse());
      expect(net.httpCalls.single.headers, isEmpty);
    });

    test('falls back to 9000 and records it as the smartcast port', () async {
      net.setUnreachable(host, port: 7345);
      net.respond('GET', '/state/device/deviceinfo', _deviceInfo(), port: 9000);
      final result = await driver.probe(const Endpoint(host), transports);
      expect(result.matched, isTrue);
      expect(result.endpoint, const Endpoint(host, ports: {'smartcast': 9000}));
      expect([for (final c in net.httpCalls) c.uri.port], [7345, 9000]);
    });

    test('a timeout on 7345 still tries 9000; neither answering is a '
        'timeout', () async {
      net.onHttp(
        'GET',
        '/state/device/deviceinfo',
        (_) => Future.delayed(const Duration(seconds: 5), _deviceInfo),
        port: 7345,
      );
      net.setUnreachable(host, port: 9000);
      final quick = VizioDriver(probeTimeout: const Duration(milliseconds: 50));
      final result = await quick.probe(const Endpoint(host), transports);
      expect(result.matched, isFalse);
      expect(result.error?.code, WatchmeErrorCode.timeout);
      expect(net.httpCalls, hasLength(2));
    });

    test('a refused destination stops the search', () async {
      net.onHttp(
        'GET',
        '/state/device/deviceinfo',
        (_) => throw const WatchmeError.destinationRefused('not on the LAN'),
      );
      final result = await driver.probe(const Endpoint(host), transports);
      expect(result.error?.code, WatchmeErrorCode.destinationRefused);
      expect(net.httpCalls, hasLength(1));
    });

    test('identity falls back to the TXT id, then the DIAL UDN', () async {
      net.respond(
        'GET',
        '/state/device/deviceinfo',
        HttpResult.json(200, {
          'ITEMS': [
            {
              'VALUE': {'SETTINGS_ROOT': 'tv_settings'},
            },
          ],
          'STATUS': {'RESULT': 'SUCCESS'},
        }),
      );
      final txt = await driver.probe(
        const Endpoint(
          host,
          attributes: {
            DiscoveryAttr.mdnsService: '_viziocast._tcp',
            'did': 'B691F911-0000-4000-8000-000000000001',
          },
        ),
        transports,
      );
      expect(
        txt.info!.stableId,
        'vizio:id:b691f911-0000-4000-8000-000000000001',
      );
      final dial = await driver.probe(
        const Endpoint(
          host,
          attributes: {
            DiscoveryAttr.udn: 'uuid:12345678-1234-1234-1234-123456789abc',
            DiscoveryAttr.friendlyName: 'Bedroom',
          },
        ),
        transports,
      );
      expect(dial.info!.stableId, 'uuid:12345678-1234-1234-1234-123456789abc');
      expect(dial.info!.name, 'Bedroom');
      // TXT keys of another service are not read as VIZIO's.
      final cast = await driver.probe(
        const Endpoint(
          host,
          attributes: {
            DiscoveryAttr.mdnsService: '_googlecast._tcp',
            'id': 'castid',
            'wifi': 'aabbccddeeff',
          },
        ),
        transports,
      );
      expect(cast.info!.stableId, isNull);
      expect(cast.info!.mac, isNull);
    });

    test('lower-case keys are understood', () async {
      net.respond(
        'GET',
        '/state/device/deviceinfo',
        HttpResult.json(200, {
          'items': [
            {
              'value': {
                'settings_root': 'tv_settings',
                'system_info': {'model_name': 'D24f-J09'},
              },
            },
          ],
          'status': {'result': 'success'},
        }),
      );
      final result = await driver.probe(const Endpoint(host), transports);
      expect(result.matched, isTrue);
      expect(result.info!.model, 'D24f-J09');
    });

    test('no network transport is unsupported', () async {
      final result = await driver.probe(
        const Endpoint(host),
        FakeTransports.offline(),
      );
      expect(result.error?.code, WatchmeErrorCode.unsupported);
    });
  });
}
