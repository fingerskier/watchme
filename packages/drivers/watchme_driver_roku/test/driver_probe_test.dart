import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fixtures.dart';

void main() {
  const driver = RokuDriver();

  group('descriptor', () {
    test('identity, ports, no pairing, documented', () {
      final d = driver.descriptor;
      expect(d.id, 'roku.ecp');
      expect(RokuDriver.id, 'roku.ecp');
      expect(d.ports, {'ecp': 8060});
      expect(d.requiresPairing, isFalse);
      expect(d.stability, Stability.documented);
      expect(d.userSetup.first.id, 'roku.controlByMobileApps');
      expect(d.userSetup.first.detail, contains('Advanced system settings'));
      expect(d.backends.single.requires, {
        TransportFeature.httpReadCrossOrigin,
      });
      // The descriptor survives the hub's JSON round trip.
      expect(DriverDescriptor.fromJson(d.toJson()), d);
    });

    test('matches SSDP roku:ecp by ST and by USN', () {
      bool matches(DiscoveryHit hit) =>
          driver.descriptor.matchers.any((m) => m.matches(hit));
      expect(
        matches(
          const DiscoveryHit(
            host: '192.0.2.10',
            provider: DiscoveryProviderId.ssdp,
            port: 8060,
            serviceType: 'roku:ecp',
          ),
        ),
        isTrue,
      );
      expect(
        matches(
          const DiscoveryHit(
            host: '192.0.2.10',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'upnp:rootdevice',
            attributes: {DiscoveryAttr.usn: 'uuid:roku:ecp:X01900ABCDEF'},
          ),
        ),
        isTrue,
      );
      expect(
        matches(
          const DiscoveryHit(
            host: '192.0.2.11',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'urn:dial-multiscreen-org:service:dial:1',
            attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
          ),
        ),
        isFalse,
      );
      expect(
        driver.descriptor.matchers.every((m) => m.portName == 'ecp'),
        isTrue,
      );
    });

    test('startPairing returns null', () {
      expect(
        driver.startPairing(
          const Endpoint('192.0.2.10'),
          FakeTransports(),
          const PairingContext(deviceId: 'd1'),
        ),
        isNull,
      );
    });
  });

  group('probe', () {
    test('Enabled Roku TV', () async {
      final roku = FakeRoku();
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(r.requiresPairing, isFalse);
      expect(r.info!.stableId, 'roku:serial:X01900ABCDEF');
      expect(r.info!.name, "Mom & Dad's TV");
      expect(r.notes, isEmpty);
      expect(
        r.capabilities.supportFor(Capability.dpadNavigation),
        const CapabilitySupport.yes(Capability.dpadNavigation),
      );
      expect(
        r.capabilities.supportFor(Capability.inputSwitch).level,
        Support.yes,
      );
    });

    test('is passive: only GETs, with an explicit IP Host header', () async {
      final roku = FakeRoku();
      await driver.probe(roku.endpoint, roku.transports);
      expect(roku.log, ['GET /query/device-info', 'GET /query/media-player']);
      for (final call in roku.net.httpCalls) {
        expect(call.header('Host'), '192.0.2.10:8060');
      }
    });

    test('stays within the engine probe timeout', () async {
      final roku = FakeRoku();
      await driver.probe(roku.endpoint, roku.transports);
      final timeouts = [for (final c in roku.net.httpCalls) c.timeout];
      expect(timeouts, [driver.requestTimeout, RokuDriver.accessCheckTimeout]);
      final worstCase = timeouts.reduce((a, b) => a + b);
      // EngineConfig.probeTimeout defaults to 8 s (the engine is not a
      // dependency of the driver).
      expect(
        worstCase,
        lessThan(const Duration(seconds: 8)),
        reason: 'a slow but present Roku must not read as "nothing answered"',
      );
    });

    test('reports the power mode device-info shows', () async {
      final awake = FakeRoku();
      final on = await driver.probe(awake.endpoint, awake.transports);
      expect(on.power?.value, PowerMode.on);
      expect(on.power?.confidence, Confidence.reported);
      expect(on.power?.source, 'roku.ecp');

      final ready = FakeRoku(deviceInfo: tvDeviceInfoIn('Ready'));
      final standby = await driver.probe(ready.endpoint, ready.transports);
      expect(
        standby.power?.value,
        PowerMode.standby,
        reason: 'answering in standby is not being on',
      );
    });

    test('uses the endpoint port', () async {
      final roku = FakeRoku(host: '127.0.0.1', port: 51234);
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(roku.net.httpCalls.first.uri.port, 51234);
      expect(roku.net.httpCalls.first.header('Host'), '127.0.0.1:51234');
    });

    test('brackets an IPv6 Host header', () async {
      final roku = FakeRoku(host: '::1', port: 51234);
      await driver.probe(roku.endpoint, roku.transports);
      expect(roku.net.httpCalls.first.header('Host'), '[::1]:51234');
    });

    test('Limited mode is a setup note, not a failure', () async {
      final roku = FakeRoku()..limited = true;
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(r.notes.single, contains('Limited'));
      expect(r.notes.single, contains('Control by mobile apps'));
      final keys = r.capabilities.supportFor(Capability.dpadNavigation);
      expect(keys.level, Support.no);
      expect(keys.has(CapFlag.userSetupRequired), isTrue);
      expect(r.capabilities.supportFor(Capability.powerState).usable, isTrue);
    });

    test('trusts ecp-setting-mode without touching a gated endpoint', () async {
      final roku = FakeRoku(
        deviceInfo: tclTvDeviceInfo.replaceFirst(
          '<power-mode>',
          '<ecp-setting-mode>limited</ecp-setting-mode><power-mode>',
        ),
      );
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.notes.single, contains('Limited'));
      expect(roku.log, ['GET /query/device-info']);
    });

    test('standby: matched, access unknown, no gated request', () async {
      final roku = FakeRoku(deviceInfo: tvDeviceInfoIn('Ready'));
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(roku.log, ['GET /query/device-info']);
      expect(r.notes.single, contains('standby'));
      expect(
        r.capabilities
            .supportFor(Capability.dpadNavigation)
            .has(CapFlag.userSetupRequired),
        isTrue,
      );
    });

    test('a player has no inputs or tuner', () async {
      final roku = FakeRoku(deviceInfo: expressPlayerDeviceInfo);
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(
        r.capabilities.supportFor(Capability.inputSwitch).level,
        Support.no,
      );
      expect(r.capabilities.supportFor(Capability.channel).level, Support.no);
    });

    test('device-info refused: matched from discovery facts', () async {
      final t = FakeTransports();
      t.net.respond(
        'GET',
        '/query/device-info',
        HttpResult.text(403, 'ECP command not allowed.'),
      );
      final r = await driver.probe(
        const Endpoint(
          '192.0.2.10',
          attributes: {
            DiscoveryAttr.usn: 'uuid:roku:ecp:X01900ABCDEF',
            DiscoveryAttr.friendlyName: 'Den TV',
          },
        ),
        t,
      );
      expect(r.matched, isTrue);
      expect(r.info!.stableId, 'roku:serial:X01900ABCDEF');
      expect(r.info!.name, 'Den TV');
      expect(r.notes.single, contains('ECP command not allowed.'));
      expect(r.capabilities.where((c) => c.usable), isEmpty);
    });

    test('unreachable and timeout are notMatched with the error', () async {
      final t = FakeTransports();
      t.net.setUnreachable('192.0.2.99');
      final r = await driver.probe(const Endpoint('192.0.2.99'), t);
      expect(r.matched, isFalse);
      expect(r.error, isWatchmeError(WatchmeErrorCode.unreachable));

      final slow = FakeTransports();
      slow.net.onHttp(
        'GET',
        '/query/device-info',
        (_) =>
            Future.delayed(const Duration(seconds: 1), () => HttpResult(200)),
      );
      final r2 = await const RokuDriver(
        requestTimeout: Duration(milliseconds: 20),
      ).probe(const Endpoint('192.0.2.10'), slow);
      expect(r2.matched, isFalse);
      expect(r2.error, isWatchmeError(WatchmeErrorCode.timeout));
    });

    test('a web server that is not a Roku is notMatched', () async {
      final t = FakeTransports();
      t.net.respond(
        'GET',
        '/query/device-info',
        HttpResult.text(200, '<html><body>router</body></html>'),
      );
      final r = await driver.probe(const Endpoint('192.0.2.1'), t);
      expect(r.matched, isFalse);
      expect(
        r.error,
        isWatchmeError(
          WatchmeErrorCode.protocol,
          rawDeviceMessage: contains('router'),
        ),
      );

      final t404 = FakeTransports(
        network: FakeNetworkStack(unmatchedHttp: UnmatchedHttp.notFound),
      );
      final r404 = await driver.probe(const Endpoint('192.0.2.1'), t404);
      expect(r404.matched, isFalse);
      expect(r404.error, isWatchmeError(WatchmeErrorCode.rejected));
    });

    test('a host name gets a note, and its 403 says why', () async {
      final ok = FakeRoku(host: 'roku.example');
      final matched = await driver.probe(ok.endpoint, ok.transports);
      expect(matched.matched, isTrue);
      expect(matched.notes.first, contains('IP address'));

      final t = FakeTransports();
      t.net.respond('GET', '/query/device-info', HttpResult(403));
      final refused = await driver.probe(const Endpoint('roku.example'), t);
      expect(refused.matched, isFalse);
      expect(
        refused.error,
        isWatchmeError(
          WatchmeErrorCode.rejected,
          message: contains('IP addresses'),
          rawDeviceMessage: 'HTTP 403',
        ),
      );
    });

    test('no network transport', () async {
      final r = await driver.probe(
        const Endpoint('192.0.2.10'),
        FakeTransports.offline(),
      );
      expect(r.matched, isFalse);
      expect(r.error, isWatchmeError(WatchmeErrorCode.unsupported));
    });

    test('omits the Host header where custom headers are impossible', () async {
      final roku = FakeRoku(
        transports: FakeTransports(
          network: FakeNetworkStack(
            features: {...TransportFeature.allNetwork}
              ..remove(TransportFeature.customHeaders),
          ),
        ),
      );
      final r = await driver.probe(roku.endpoint, roku.transports);
      expect(r.matched, isTrue);
      expect(roku.net.httpCalls.first.headers, isEmpty);
    });
  });

  group('connect', () {
    test('opens a session with state and capabilities', () async {
      final roku = FakeRoku();
      final session = await driver.connect(
        roku.endpoint,
        roku.transports,
        null,
      );
      addTearDown(session.close);
      expect(session.driverId, 'roku.ecp');
      expect(session.state.power!.value, PowerMode.on);
      expect(session.state.power!.confidence, Confidence.reported);
      expect(session.state.foregroundApp!.value.id, '12');
      expect(session.state.input!.value, rokuAppsInputId);
      expect(session.state.nowPlaying!.value.state, PlaybackState.playing);
      expect(session.state.connections, {
        'roku.ecp': ConnectionState.connected,
      });
      expect(
        session.capabilities.supportFor(Capability.dpadNavigation).level,
        Support.yes,
      );
      expect((session as RokuSession).access, RokuEcpAccess.enabled);
    });

    test('throws the device error when device-info is refused', () async {
      final t = FakeTransports();
      t.net.respond(
        'GET',
        '/query/device-info',
        HttpResult.text(403, 'ECP command not allowed.'),
      );
      await expectLater(
        driver.connect(const Endpoint('192.0.2.10'), t, null),
        throwsWatchmeError(
          WatchmeErrorCode.rejected,
          rawDeviceMessage: 'ECP command not allowed.',
        ),
      );
    });

    test('throws unreachable when nothing answers', () async {
      final t = FakeTransports()..net.setUnreachable('192.0.2.10');
      await expectLater(
        driver.connect(const Endpoint('192.0.2.10'), t, null),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });
  });
}
