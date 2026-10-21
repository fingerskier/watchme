import 'dart:io' hide Datagram;

import 'package:multicast_dns/multicast_dns.dart' show RawDatagramSocketFactory;
import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';

import '../support/fake_mdns_responder.dart';
import '../support/policies.dart';

void main() {
  group('parseMdnsTxt', () {
    test('keeps keys verbatim, first wins, bare keys are empty', () {
      expect(
        parseMdnsTxt(
          'amzn.dmgr=aaa\nn=Den Fire TV\nflag\nn=second\n=x\nurl=a=b\n',
        ),
        {'amzn.dmgr': 'aaa', 'n': 'Den Fire TV', 'flag': '', 'url': 'a=b'},
      );
      expect(parseMdnsTxt(''), isEmpty);
    });
  });

  group('mdnsHit', () {
    test('builds a hit from resolved records', () {
      final hit = mdnsHit(
        serviceType: '_amzn-wplay._tcp.local.',
        instance: 'Den Fire TV._amzn-wplay._tcp.local',
        host: '10.0.0.7',
        port: 55442,
        target: 'fire-tv.local',
        txt: {'amzn.dmgr': 'x', 'n': 'Den'},
      );
      expect(hit.provider, 'mdns');
      expect(hit.serviceType, '_amzn-wplay._tcp');
      // WhisperPlay's `n` TXT entry is the user's name for the device.
      expect(hit.name, 'Den');
      expect(hit.port, 55442);
      expect(hit.attributes, {
        'amzn.dmgr': 'x',
        'n': 'Den',
        DiscoveryAttr.mdnsInstance: 'Den Fire TV',
        DiscoveryAttr.mdnsTarget: 'fire-tv.local',
        DiscoveryAttr.mdnsService: '_amzn-wplay._tcp',
      });
      expect(
        const DiscoveryMatcher(serviceType: '_amzn-wplay._tcp').matches(hit),
        isTrue,
      );
    });

    test('names WhisperPlay records by their n TXT entry', () {
      final hit = mdnsHit(
        serviceType: '_amzn-wplay._tcp',
        instance:
            'amzn.dmgr:0123456789ABCDEF0123456789ABCDEF:abcdef:1._amzn-wplay.'
            '_tcp.local',
        host: '10.0.0.7',
        port: 40000,
        target: '10-0-0-7.local',
        txt: {'n': 'Den Fire TV', 'u': '0123456789ABCDEF0123456789ABCDEF'},
      );
      expect(hit.name, 'Den Fire TV');
      expect(
        hit.attributes[DiscoveryAttr.mdnsInstance],
        startsWith('amzn.dmgr:'),
      );
      final other = mdnsHit(
        serviceType: '_viziocast._tcp',
        instance: 'Kitchen._viziocast._tcp.local',
        host: '10.0.0.8',
        port: 7345,
        target: 'kitchen.local',
        txt: {'n': 'not a name here'},
      );
      expect(other.name, 'Kitchen');
    });

    test('uses the Cast friendly name and the AirPlay MAC', () {
      final cast = mdnsHit(
        serviceType: '_googlecast._tcp',
        instance: 'Chromecast-abc123._googlecast._tcp.local',
        host: '10.0.0.9',
        port: 8009,
        target: 'abc123.local',
        txt: {'fn': 'Kitchen TV', 'id': 'abc123'},
      );
      expect(cast.name, 'Kitchen TV');
      expect(cast.mac, isNull);
      final airplay = mdnsHit(
        serviceType: '_airplay._tcp',
        instance: 'Living Room._airplay._tcp.local',
        host: '10.0.0.10',
        port: 7000,
        target: 'living-room.local',
        txt: {'deviceid': 'AA:BB:CC:00:11:22', 'model': 'AppleTV14,1'},
      );
      expect(airplay.mac, 'aa:bb:cc:00:11:22');
    });
  });

  group('MdnsDiscovery on loopback', () {
    late NetworkInterface lo;
    final group = InternetAddress('239.255.77.4');
    const fireTv = FakeMdnsService(
      type: '_amzn-wplay._tcp',
      instance: 'Den Fire TV',
      target: 'fire-tv-abc.local',
      port: 55442,
      ipv4: '127.0.0.1',
      txt: ['amzn.dmgr=amzn.dmgr:abc', 'n=Den Fire TV'],
    );
    const cast = FakeMdnsService(
      type: '_googlecast._tcp',
      instance: 'Chromecast-123',
      target: 'cc-123.local',
      port: 8009,
      ipv4: '127.0.0.1',
      txt: ['fn=Kitchen TV', 'id=123'],
    );

    setUpAll(() async {
      lo = (await NetworkInterface.list(includeLoopback: true))
          .firstWhere((i) => i.addresses.any((a) => a.isLoopback));
    });

    // The responder is on loopback, so its datagrams come from 127.0.0.1:
    // these tests opt into loopback unless they say otherwise.
    MdnsDiscovery provider(
      int port, {
      List<String>? types,
      DestinationPolicy policy = loopbackAllowed,
      RawDatagramSocketFactory socketFactory = loopbackSocketFactory,
    }) => MdnsDiscovery(
      serviceTypes: types ?? MdnsDiscovery.defaultServiceTypes,
      port: port,
      group: group,
      interfaces: (_) async => [lo],
      socketFactory: socketFactory,
      resolveTimeout: const Duration(milliseconds: 500),
      destinationPolicy: policy,
    );

    for (final additionals in [true, false]) {
      test(
        'resolves PTR, SRV, TXT and A '
        '(${additionals ? 'from additionals' : 'by separate queries'})',
        () async {
          final responder = await FakeMdnsResponder.start(
            group: group,
            loopback: lo,
            services: [fireTv, cast],
            additionals: additionals,
          );
          if (responder == null) {
            markTestSkipped('cannot join a multicast group on loopback');
            return;
          }
          addTearDown(responder.close);
          final hits = await provider(responder.port)
              .scan(const Duration(milliseconds: 700))
              .toList();
          hits.sort((a, b) => a.serviceType!.compareTo(b.serviceType!));
          expect(hits, hasLength(2));
          final wplay = hits.firstWhere(
            (h) => h.serviceType == '_amzn-wplay._tcp',
          );
          expect(wplay.host, '127.0.0.1');
          expect(wplay.port, 55442);
          expect(wplay.name, 'Den Fire TV');
          expect(wplay.attributes, containsPair('amzn.dmgr', 'amzn.dmgr:abc'));
          expect(
            wplay.attributes,
            containsPair(DiscoveryAttr.mdnsTarget, 'fire-tv-abc.local'),
          );
          final chromecast = hits.firstWhere(
            (h) => h.serviceType == '_googlecast._tcp',
          );
          expect(chromecast.name, 'Kitchen TV');
          expect(chromecast.port, 8009);
          if (!additionals) {
            expect(
              responder.questions,
              contains('33 Den Fire TV._amzn-wplay._tcp.local'),
            );
            expect(responder.questions, contains('1 fire-tv-abc.local'));
          }
        },
      );
    }

    test('browses only the DNS-SD types it is given', () async {
      final responder = await FakeMdnsResponder.start(
        group: group,
        loopback: lo,
        services: [fireTv, cast],
      );
      if (responder == null) {
        markTestSkipped('cannot join a multicast group on loopback');
        return;
      }
      addTearDown(responder.close);
      final hits = await provider(responder.port)
          .scan(
            const Duration(milliseconds: 500),
            serviceTypes: {'_googlecast._tcp.local.', 'roku:ecp'},
          )
          .toList();
      expect(hits.single.serviceType, '_googlecast._tcp');
      expect(responder.questions.where((q) => q.startsWith('12 ')), [
        '12 _googlecast._tcp.local',
      ]);
    });

    test('drops records that point outside the LAN or at loopback', () async {
      const internet = FakeMdnsService(
        type: '_googlecast._tcp',
        instance: 'Spoofed',
        target: 'spoofed.local',
        port: 8009,
        ipv4: '203.0.113.9',
        txt: ['fn=Spoofed TV'],
      );
      const shared = FakeMdnsService(
        type: '_googlecast._tcp',
        instance: 'Overlay',
        target: 'overlay.local',
        port: 8009,
        ipv4: '100.64.1.2',
        txt: ['fn=Overlay TV'],
      );
      const lan = FakeMdnsService(
        type: '_googlecast._tcp',
        instance: 'Lounge',
        target: 'lounge.local',
        port: 8009,
        ipv4: '192.168.40.12',
        txt: ['fn=Lounge TV'],
      );
      final responder = await FakeMdnsResponder.start(
        group: group,
        loopback: lo,
        services: [internet, shared, lan, cast],
      );
      if (responder == null) {
        markTestSkipped('cannot join a multicast group on loopback');
        return;
      }
      addTearDown(responder.close);
      // The responder acts as a LAN host, so its records are heard and
      // judged one by one under the default LAN-only policy.
      final hits = await provider(
        responder.port,
        types: ['_googlecast._tcp'],
        policy: DestinationPolicy.lanOnly,
        socketFactory: spoofedSenderSocketFactory(
          InternetAddress('192.168.40.1'),
        ),
      ).scan(const Duration(milliseconds: 700)).toList();
      // The internet, shared-range (CGNAT / VPN overlay) and loopback
      // (cast) addresses are all dropped.
      expect(hits.map((h) => h.host), ['192.168.40.12']);
    });

    test('drops every datagram from a sender outside the policy', () async {
      const lan = FakeMdnsService(
        type: '_googlecast._tcp',
        instance: 'Lounge',
        target: 'lounge.local',
        port: 8009,
        ipv4: '192.168.40.12',
        txt: ['fn=Lounge TV'],
      );
      final responder = await FakeMdnsResponder.start(
        group: group,
        loopback: lo,
        services: [lan],
      );
      if (responder == null) {
        markTestSkipped('cannot join a multicast group on loopback');
        return;
      }
      addTearDown(responder.close);
      Future<List<DiscoveryHit>> scanFrom(
        String? sender, {
        DestinationPolicy policy = DestinationPolicy.lanOnly,
      }) => provider(
        responder.port,
        types: ['_googlecast._tcp'],
        policy: policy,
        socketFactory: sender == null
            ? loopbackSocketFactory
            : spoofedSenderSocketFactory(InternetAddress(sender)),
      ).scan(const Duration(milliseconds: 500)).toList();

      // A LAN sender is heard...
      expect((await scanFrom('192.168.40.12')).map((h) => h.host), [
        '192.168.40.12',
      ]);
      // ...but the same records from the shared range, the internet or a
      // reserved block never reach the client, whatever address they name.
      for (final sender in ['100.64.0.9', '8.8.8.8', '203.0.113.5']) {
        expect(await scanFrom(sender), isEmpty, reason: sender);
      }
      // Loopback is heard only when the policy says so.
      expect(await scanFrom(null), isEmpty);
      expect(
        (await scanFrom(null, policy: loopbackAllowed)).map((h) => h.host),
        ['192.168.40.12'],
      );
    });

    test(
      'a scan naming no DNS-SD type finds nothing and opens no socket',
      () async {
        expect(
          await provider(1)
              .scan(Duration.zero, serviceTypes: {'roku:ecp'})
              .toList(),
          isEmpty,
        );
      },
    );

    test('a socket that cannot be opened fails the scan', () async {
      final failing = MdnsDiscovery(
        socketFactory: (
          host,
          port, {
          reuseAddress = true,
          reusePort = false,
          ttl = 1,
        }) => throw const SocketException('bind refused'),
      );
      await expectLater(
        failing.scan(const Duration(milliseconds: 100)).toList(),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unreachable,
          ),
        ),
      );
    });
  });
}
