@TestOn('vm')
library;

import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_testkit/sharp_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/io_tcp_stack.dart';
import 'support/sim.dart';

void main() {
  group('descriptor', () {
    test('identifies the driver, its port and its backend', () {
      final d = SharpDriver().descriptor;
      expect(d.id, 'sharp.aquos');
      expect(d.vendor, 'Sharp');
      expect(d.ports, {'ipc': 10002});
      expect(d.requiresPairing, isFalse);
      expect(d.offersPairing, isTrue, reason: 'login and RSPW set-up');
      expect(d.stability, Stability.documented);
      expect(d.backends.single.requires, {TransportFeature.rawTcp});
      expect(d.backends.single.targets, {DriverTarget.native});
      expect(d.provenance, contains('No code was copied'));
      expect(d.provenance, contains('Hixie/dart-home-automation-tools (MIT)'));
      expect(d.userSetup.map((s) => s.id), [
        'sharp.ipControl',
        'sharp.login',
        'sharp.networkPowerOn',
      ]);
    });

    test('round-trips through JSON', () {
      expect(
        DriverDescriptor.fromJson(sharpDescriptor.toJson()),
        sharpDescriptor,
      );
    });

    test('matches the AquosIPC SSDP device type without taking its port', () {
      final matcher = sharpDescriptor.matchers.single;
      expect(matcher.portName, isNull);
      expect(
        matcher.matches(
          const DiscoveryHit(
            host: '192.168.1.20',
            provider: DiscoveryProviderId.ssdp,
            port: 12346,
            serviceType: 'urn:schemas-sharp-co-jp:device:AquosIPC:1',
          ),
        ),
        isTrue,
      );
      expect(
        matcher.matches(
          const DiscoveryHit(
            host: '192.168.1.20',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'urn:schemas-upnp-org:device:MediaRenderer:1',
          ),
        ),
        isFalse,
      );
    });

    test('the ceiling is truthful about power and text', () {
      final c = sharpDescriptor.ceiling;
      expect(c.supportFor(Capability.powerOff).level, Support.yes);
      expect(c.supportFor(Capability.powerOn).level, Support.partial);
      expect(
        c.supportFor(Capability.powerOn).flags,
        contains(CapFlag.needsNetworkStandby),
      );
      for (final cap in c) {
        expect(cap.has(CapFlag.toggleOnly), isFalse, reason: '$cap');
      }
      expect(c.supportFor(Capability.textInput).level, Support.no);
      expect(c.supportFor(Capability.nowPlaying).level, Support.no);
      expect(c.map((e) => e.capability).toSet(), Capability.values.toSet());
    });
  });

  group('probe', () {
    final transports = IoTcpTransports();
    final driver = testDriver();

    test(
      'a TV with login off: reads only, reports identity and power',
      () async {
        final sim = await startSim(SharpSimulator(modelReply: 'C6400UA'));
        final result = await driver.probe(sim.endpoint, transports);
        expect(result.matched, isTrue);
        expect(result.requiresPairing, isFalse);
        expect(result.info!.manufacturer, 'Sharp');
        expect(result.info!.name, 'Living Room AQUOS');
        expect(result.info!.model, 'C6400UA');
        expect(result.info!.osVersion, '222U1302091');
        expect(result.info!.extra, {
          'profile': 'us2011',
          'mnrd': 'C6400UA',
          'protocolVersion': '0100',
        });
        expect(result.power!.value, PowerMode.on);
        expect(result.power!.confidence, Confidence.reported);
        expect(
          result.capabilities.supportFor(Capability.powerState).level,
          Support.yes,
        );
        expect(sim.lines, [
          'POWR?   ',
          'MNRD1   ',
          'TVNM1   ',
          'SWVN1   ',
          'IPPV1   ',
        ]);
        expect(writes(sim), isEmpty);
      },
    );

    test('a TV that asks for a login: matched with nothing sent', () async {
      final sim = await startSim(
        SharpSimulator(loginId: 'admin', password: 'secret1'),
      );
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.requiresPairing, isTrue);
      expect(result.power, isNull);
      expect(result.notes.single, contains('login ID and password'));
      expect(sim.rawInput, ['']);
      expect(sim.failedLogins + sim.successfulLogins, 0);
    });

    test('a TV in network standby reads standby and stays asleep', () async {
      final sim = await startSim(
        SharpSimulator(power: SharpSimPower.networkStandby, rspw: 2),
      );
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.power!.value, PowerMode.standby);
      expect(result.power!.confidence, Confidence.reported);
      expect(sim.power, SharpSimPower.networkStandby);
      expect(writes(sim), isEmpty);
    });

    test('a closed port is unreachable, not "off"', () async {
      final sim = await startSim(SharpSimulator(power: SharpSimPower.off));
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isFalse);
      expect(result.error, isWatchmeError(WatchmeErrorCode.unreachable));
      expect(result.notes.single, contains('IP control may be off'));
    });

    test('the 2015 firmware: no power reading, write-only profile', () async {
      final sim = await startSim(
        SharpSimulator(profile: SharpSimProfile.us2015Limited),
      );
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.matched, isTrue);
      expect(result.power, isNull);
      expect(result.info!.extra['profile'], 'us2015limited');
      expect(
        result.capabilities.supportFor(Capability.powerState).level,
        Support.no,
      );
      expect(result.notes, contains(contains('refuses every query')));
    });

    test('an EU set answers IPPY1 after IPPV1 is refused', () async {
      final sim = await startSim(SharpSimulator(profile: SharpSimProfile.eu));
      final result = await driver.probe(sim.endpoint, transports);
      expect(result.info!.extra['profile'], 'eu');
      expect(result.info!.extra['protocolVersion'], '0100');
      expect(sim.lines, contains('IPPY1   '));
      expect(
        result.capabilities.supportFor(Capability.powerOn).level,
        Support.no,
      );
    });

    test('takes identity from discovery attributes and the profile from '
        'sharp.profile', () async {
      final sim = await startSim(SharpSimulator(modelReply: null));
      final endpoint = sim.endpoint.withAttributes({
        DiscoveryAttr.udn: 'uuid:e94ee5fe-0a78-11e1-b06a-34F62D350D0F',
        DiscoveryAttr.modelName: 'LC-70UD27U',
        SharpAttributes.profile: 'us2014',
      });
      final result = await driver.probe(endpoint, transports);
      expect(
        result.info!.stableId,
        'uuid:e94ee5fe-0a78-11e1-b06a-34f62d350d0f',
      );
      expect(result.info!.model, 'LC-70UD27U');
      expect(result.info!.mac, isNull, reason: 'a hint is not identity');
      expect(result.info!.extra['udnMacHint'], '34:f6:2d:35:0d:0f');
      expect(result.info!.extra['profile'], 'us2014');
    });

    test('a silent service on the port does not match', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() {
        for (final s in held) {
          s.destroy();
        }
      });
      final result = await driver.probe(
        Endpoint('127.0.0.1', ports: {'ipc': server.port}),
        transports,
      );
      expect(result.matched, isFalse);
      expect(result.error, isWatchmeError(WatchmeErrorCode.timeout));
    });

    test('another protocol greeting the connection does not match', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      server.listen((s) {
        s.write('SSH-2.0-OpenSSH_9.9\r\n');
        unawaited(s.flush());
      });
      final result = await driver.probe(
        Endpoint('127.0.0.1', ports: {'ipc': server.port}),
        transports,
      );
      expect(result.matched, isFalse);
      expect(result.error, isWatchmeError(WatchmeErrorCode.protocol));
    });

    test(
      'a TV whose only client slot is taken closes the probe at once',
      () async {
        final sim = await startSim(SharpSimulator());
        final other = await Socket.connect(sim.host, sim.port);
        addTearDown(other.destroy);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final result = await driver.probe(sim.endpoint, transports);
        expect(result.matched, isFalse);
        expect(result.error, isWatchmeError(WatchmeErrorCode.unreachable));
      },
    );

    test(
      'uses the endpoint port and fails cleanly without a network',
      () async {
        final sim = await startSim(SharpSimulator());
        final t = IoTcpTransports();
        await driver.probe(sim.endpoint, t);
        expect(t.network.connects, ['127.0.0.1:${sim.port}']);
        final offline = await driver.probe(
          sim.endpoint,
          FakeTransports.offline(),
        );
        expect(offline.matched, isFalse);
        expect(offline.error, isWatchmeError(WatchmeErrorCode.unsupported));
      },
    );
  });
}
