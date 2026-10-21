import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import '../support/ssdp_samples.dart';

const dialSt = 'urn:dial-multiscreen-org:service:dial:1';

void main() {
  group('SsdpMessage', () {
    test('parses a Roku search response with its extra headers', () {
      final m = SsdpMessage.tryParse(rokuResponse())!;
      expect(m.kind, SsdpMessageKind.searchResponse);
      expect(m.serviceType, 'roku:ecp');
      expect(m.usn, 'uuid:roku:ecp:YN00AB123456');
      expect(m.uuid, 'uuid:roku:ecp:YN00AB123456');
      expect(m.locationUri, Uri.parse('http://10.0.0.20:8060/'));
      expect(m.header('DEVICE-GROUP.ROKU.COM'), '46F5CCE2472F2B14D77');
      expect(m.header('server'), 'Roku/14.1.4 UPnP/1.0 Roku/14.1.4');
      expect(m.headers['ext'], '');
      expect(m.wakeupMac, 'd8:31:34:aa:bb:cc');
    });

    test('takes the uuid of a DIAL USN', () {
      final m = SsdpMessage.tryParse(fireTvDialResponse())!;
      expect(m.serviceType, dialSt);
      expect(m.uuid, fireTvUdn);
      expect(m.wakeupMac, isNull);
    });

    test('parses NOTIFY alive and byebye, with bare LF line endings', () {
      final alive = SsdpMessage.tryParse(rokuNotifyAlive)!;
      expect(alive.kind, SsdpMessageKind.notify);
      expect(alive.serviceType, 'roku:ecp');
      expect(alive.nts, 'ssdp:alive');
      expect(alive.isByeBye, isFalse);
      final bye = SsdpMessage.tryParse(rokuNotifyByeBye())!;
      expect(bye.isByeBye, isTrue);
      expect(bye.location, isNull);
    });

    test('recognises other control points searching', () {
      final m = SsdpMessage.tryParseBytes(buildMSearch('roku:ecp'))!;
      expect(m.kind, SsdpMessageKind.search);
      expect(m.header('st'), 'roku:ecp');
    });

    test('rejects what is not SSDP', () {
      for (final junk in [
        '',
        '\r\n\r\n',
        'GARBAGE',
        'HTTP/1.1 404 Not Found\r\nST: x\r\n\r\n',
        'GET / HTTP/1.1\r\n\r\n',
      ]) {
        expect(SsdpMessage.tryParse(junk), isNull, reason: junk);
      }
      expect(SsdpMessage.tryParseBytes([0xff, 0x00, 0xfe, 0x80]), isNull);
    });

    test('tolerates malformed header lines and odd values', () {
      final m = SsdpMessage.tryParse(
        'HTTP/1.1 200 OK\r\n'
        'no colon here\r\n'
        ': no name\r\n'
        'bad name: x\r\n'
        '  sT  :   roku:ecp  \r\n'
        'st: second value ignored\r\n'
        'LOCATION: ftp://10.0.0.1/\r\n'
        'USN:\r\n'
        'WAKEUP: Timeout=10;MAC=not-a-mac\r\n'
        '\r\n'
        'body: after the blank line\r\n',
      )!;
      expect(m.serviceType, 'roku:ecp');
      expect(m.headers.keys, isNot(contains('body')));
      expect(m.headers.keys, isNot(contains('bad name')));
      expect(m.location, 'ftp://10.0.0.1/');
      expect(m.locationUri, isNull);
      expect(m.usn, isNull);
      expect(m.uuid, isNull);
      expect(m.wakeupMac, isNull);
    });

    test('buildMSearch writes a standard request', () {
      expect(
        utf8.decode(buildMSearch(dialSt, mx: 3)),
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 3\r\n'
        'ST: $dialSt\r\n'
        '\r\n',
      );
    });
  });

  group('UpnpDescription', () {
    test('reads the root device fields', () {
      final d = UpnpDescription.tryParse(rokuDescription)!;
      expect(d.friendlyName, 'Living Room Roku');
      expect(d.manufacturer, 'Roku');
      expect(d.modelName, 'Roku Ultra');
      expect(d.serialNumber, 'YN00AB123456');
      expect(d.udn, 'uuid:29600009-5406-1005-8080-d83134aabbcc');
      expect(d.fields[DiscoveryAttr.modelNumber], '4850X');
      expect(
        d.fields[DiscoveryAttr.deviceType],
        'urn:roku-com:device:player:1-0',
      );
      expect(d.fields.keys, isNot(contains('modelDescription')));
    });

    test('matches elements by local name under a prefixed namespace', () {
      final d = UpnpDescription.tryParse(fireTvDescription)!;
      expect(d.manufacturer, 'Amazon');
      expect(d.modelName, 'AFTKA');
    });

    test('returns null for malformed or device-less XML', () {
      expect(UpnpDescription.tryParse('<root><device>'), isNull);
      expect(UpnpDescription.tryParse('not xml at all'), isNull);
      expect(UpnpDescription.tryParse('<root><x/></root>'), isNull);
    });
  });

  group('helpers', () {
    test('tell DNS-SD types from SSDP targets', () {
      expect(isDnsSdServiceType('_amzn-wplay._tcp'), isTrue);
      expect(isDnsSdServiceType('_googlecast._tcp.local.'), isTrue);
      expect(isSsdpSearchTarget('_googlecast._tcp'), isFalse);
      expect(isSsdpSearchTarget('roku:ecp'), isTrue);
      expect(isSsdpSearchTarget(dialSt), isTrue);
      expect(isSsdpSearchTarget('  '), isFalse);
    });

    test('ssdpPlacement trusts only the sender or LAN locations', () {
      expect(ssdpPlacement('10.0.0.7', Uri.parse('http://10.0.0.7:60000/d')), (
        host: '10.0.0.7',
        port: 60000,
        fetchable: true,
      ));
      expect(ssdpPlacement('10.0.0.7', Uri.parse('http://10.0.0.8:8060/')), (
        host: '10.0.0.8',
        port: 8060,
        fetchable: true,
      ));
      expect(ssdpPlacement('10.0.0.7', Uri.parse('http://203.0.113.9/evil')), (
        host: '10.0.0.7',
        port: null,
        fetchable: false,
      ));
      expect(ssdpPlacement('10.0.0.7', Uri.parse('http://tv.example/')), (
        host: '10.0.0.7',
        port: null,
        fetchable: false,
      ));
      expect(ssdpPlacement('10.0.0.7', null), (
        host: '10.0.0.7',
        port: null,
        fetchable: false,
      ));
    });

    test('ssdpPlacement refuses loopback and shared-range third parties', () {
      const untrusted = (host: '10.0.0.7', port: null, fetchable: false);
      // A LAN host must not point watchme at this host's own services...
      expect(
        ssdpPlacement('10.0.0.7', Uri.parse('http://127.0.0.1:631/x')),
        untrusted,
      );
      expect(
        ssdpPlacement('10.0.0.7', Uri.parse('http://[::1]:631/x')),
        untrusted,
      );
      // ...or into the CGNAT / overlay-VPN range.
      expect(
        ssdpPlacement('10.0.0.7', Uri.parse('http://100.100.1.2:80/x')),
        untrusted,
      );
      // A link-local address on the LAN is fine.
      expect(
        ssdpPlacement('10.0.0.7', Uri.parse('http://169.254.3.4:49152/d')),
        (host: '169.254.3.4', port: 49152, fetchable: true),
      );
      // A loopback simulator may name loopback.
      expect(ssdpPlacement('127.0.0.1', Uri.parse('http://127.0.0.2:8060/')), (
        host: '127.0.0.2',
        port: 8060,
        fetchable: true,
      ));
      // A device naming its own shared-range address is still itself.
      expect(
        ssdpPlacement('100.100.1.2', Uri.parse('http://100.100.1.2:80/x')),
        (host: '100.100.1.2', port: 80, fetchable: true),
      );
    });

    test('isPrivateLanAddress', () {
      for (final lan in [
        '10.1.2.3',
        '172.16.0.1',
        '192.168.1.7',
        '169.254.10.10',
        'fe80::1',
        'fd12:3456::1',
      ]) {
        expect(isPrivateLanAddress(InternetAddress(lan)), isTrue, reason: lan);
      }
      for (final other in [
        '127.0.0.1',
        '::1',
        '100.64.0.1',
        '8.8.8.8',
        '2001:db8::1',
      ]) {
        expect(
          isPrivateLanAddress(InternetAddress(other)),
          isFalse,
          reason: other,
        );
      }
    });

    test('isLanAddress', () {
      for (final lan in [
        '10.1.2.3',
        '172.16.0.1',
        '172.31.255.255',
        '192.168.1.7',
        '100.64.0.1',
        '169.254.10.10',
        '127.0.0.1',
        '::1',
        'fe80::1',
        'fd12:3456::1',
      ]) {
        expect(isLanAddress(InternetAddress(lan)), isTrue, reason: lan);
      }
      for (final wan in ['8.8.8.8', '172.32.0.1', '192.0.2.1', '2001:db8::1']) {
        expect(isLanAddress(InternetAddress(wan)), isFalse, reason: wan);
      }
    });
  });

  group('SsdpDiscovery on a fake network', () {
    late FakeNetworkStack net;

    setUp(() {
      net = FakeNetworkStack();
      net.onMulticast(ssdpGroup, ssdpPort, (query) {
        final st = SsdpMessage.tryParseBytes(query)!.header('st');
        Datagram d(String host, String text) =>
            Datagram(host, ssdpPort, utf8.encode(text));
        return switch (st) {
          'roku:ecp' => [d('10.0.0.20', rokuResponse())],
          dialSt => [d('10.0.0.7', fireTvDialResponse())],
          'ssdp:all' => [
            d('10.0.0.7', fireTvRootResponse()),
            d('10.0.0.7', fireTvDialResponse()),
            d('10.0.0.20', rokuResponse()),
            d('10.0.0.30', 'GARBAGE'),
            d('10.0.0.31', utf8.decode(buildMSearch('ssdp:all'))),
            d('10.0.0.20', rokuNotifyByeBye()),
          ],
          _ => <Datagram>[],
        };
      });
      net.respond(
        'GET',
        '/',
        HttpResult.text(200, rokuDescription, contentType: 'text/xml'),
        host: '10.0.0.20',
        port: 8060,
      );
      net.respond(
        'GET',
        '/upnp/dev/7c2a6a2e/desc',
        HttpResult.text(
          200,
          fireTvDescription,
          contentType: 'text/xml',
          headers: {'Application-URL': 'http://10.0.0.7:8009/apps/'},
        ),
        host: '10.0.0.7',
        port: 60000,
      );
    });

    SsdpDiscovery provider({int attempts = 2}) =>
        SsdpDiscovery(net, attempts: attempts, resendDelay: Duration.zero);

    test(
      'finds Roku and a Fire TV, enriched from their descriptions',
      () async {
        final hits = await provider().scan(const Duration(seconds: 3)).toList();
        final roku = hits.singleWhere((h) => h.serviceType == 'roku:ecp');
        expect(roku.host, '10.0.0.20');
        expect(roku.port, 8060);
        expect(roku.provider, 'ssdp');
        expect(roku.name, 'Living Room Roku');
        expect(roku.stableId, 'uuid:roku:ecp:YN00AB123456');
        expect(roku.mac, 'd8:31:34:aa:bb:cc');
        expect(
          roku.attributes,
          containsPair('device-group.roku.com', '46F5CCE2472F2B14D77'),
        );
        expect(
          roku.attributes,
          containsPair(DiscoveryAttr.serialNumber, 'YN00AB123456'),
        );
        expect(roku.attributes, containsPair(DiscoveryAttr.st, 'roku:ecp'));

        final dial = hits.singleWhere((h) => h.serviceType == dialSt);
        expect(dial.host, '10.0.0.7');
        expect(dial.port, 60000);
        expect(dial.name, 'Den Fire TV');
        expect(dial.stableId, fireTvUdn);
        expect(
          dial.attributes,
          containsPair(DiscoveryAttr.manufacturer, 'Amazon'),
        );
        expect(dial.attributes, containsPair(DiscoveryAttr.modelName, 'AFTKA'));
        expect(
          dial.attributes,
          containsPair(
            DiscoveryAttr.applicationUrl,
            'http://10.0.0.7:8009/apps/',
          ),
        );
        // The Fire TV matcher from the architecture overview recognises it.
        const fireTvMatcher = DiscoveryMatcher(
          provider: DiscoveryProviderId.ssdp,
          serviceType: dialSt,
          attributes: [
            AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Amazon'),
            AttributeMatch.prefix(DiscoveryAttr.modelName, 'AFT'),
          ],
        );
        expect(fireTvMatcher.matches(dial), isTrue);
        expect(fireTvMatcher.matches(roku), isFalse);

        // One hit per USN: the root device, its DIAL service and Roku.
        expect(hits, hasLength(3));
        expect(
          hits.map((h) => h.attributes[DiscoveryAttr.usn]).toSet(),
          hasLength(3),
        );
        // One description fetch per LOCATION, shared by both Fire TV USNs.
        expect(net.callsTo('GET', '/upnp/dev/7c2a6a2e/desc'), hasLength(1));
        expect(net.callsTo('GET', '/'), hasLength(1));
        // Every target was searched twice.
        expect(net.multicastQueries, hasLength(6));
      },
    );

    test('searches only the SSDP types it is given', () async {
      final hits = await provider(attempts: 1)
          .scan(
            const Duration(seconds: 3),
            serviceTypes: {'roku:ecp', '_amzn-wplay._tcp'},
          )
          .toList();
      expect(
        net.multicastQueries.map(
          (q) => SsdpMessage.tryParse(q.text)!.header('st'),
        ),
        ['roku:ecp'],
      );
      expect(hits.single.serviceType, 'roku:ecp');
      expect(
        await provider()
            .scan(Duration.zero, serviceTypes: {'_googlecast._tcp'})
            .toList(),
        isEmpty,
      );
    });

    test('never fetches a LOCATION outside the LAN', () async {
      net = FakeNetworkStack()
        ..onMulticast(
          ssdpGroup,
          ssdpPort,
          (_) => [
            Datagram(
              '10.0.0.7',
              ssdpPort,
              utf8.encode(fireTvDialResponse(locationHost: '203.0.113.9')),
            ),
          ],
        );
      final hit = await provider(attempts: 1)
          .scan(const Duration(seconds: 1))
          .single;
      expect(hit.host, '10.0.0.7');
      expect(hit.port, isNull);
      expect(hit.name, isNull);
      expect(net.httpCalls, isEmpty);
    });

    test('refuses an oversized description without buffering it', () async {
      net.respond(
        'GET',
        '/upnp/dev/7c2a6a2e/desc',
        HttpResult.text(200, 'x' * (2 * 1024 * 1024), contentType: 'text/xml'),
        host: '10.0.0.7',
        port: 60000,
      );
      final hits = await provider(attempts: 1)
          .scan(const Duration(seconds: 1), serviceTypes: {dialSt})
          .toList();
      expect(hits.single.host, '10.0.0.7');
      expect(hits.single.name, isNull);
      final fetch = net.httpLog.single;
      expect(fetch.call.maxResponseBytes, SsdpDiscovery.maxDescriptionBytes);
      expect(
        fetch.error,
        isA<WatchmeError>().having(
          (e) => e.code,
          'code',
          WatchmeErrorCode.protocol,
        ),
      );
    });

    test('caps description fetches per sender and per scan', () async {
      net = FakeNetworkStack()
        ..onMulticast(
          ssdpGroup,
          ssdpPort,
          (_) => [
            // One noisy host announcing 10 devices, each with its own
            // description URL.
            for (var i = 0; i < 10; i++)
              Datagram(
                '10.0.0.50',
                ssdpPort,
                utf8.encode(
                  crlf('''
HTTP/1.1 200 OK
LOCATION: http://10.0.0.50:5000/dev$i.xml
ST: upnp:rootdevice
USN: uuid:noisy-$i::upnp:rootdevice

'''),
                ),
              ),
          ],
        )
        ..onHttp(
          'GET',
          RegExp(r'^/dev\d+\.xml$'),
          (_) => HttpResult.text(200, fireTvDescription),
        );
      final hits = await SsdpDiscovery(
        net,
        attempts: 1,
        maxDescriptionFetchesPerSender: 3,
      ).scan(const Duration(seconds: 1)).toList();
      expect(hits, hasLength(10));
      expect(net.httpCalls, hasLength(3));
      expect(hits.where((h) => h.name != null), hasLength(3));
    });

    test(
      'still reports a device whose description cannot be fetched',
      () async {
        net.setUnreachable('10.0.0.20', port: 8060);
        final hits = await provider(attempts: 1)
            .scan(const Duration(seconds: 1), serviceTypes: {'roku:ecp'})
            .toList();
        expect(hits.single.port, 8060);
        expect(hits.single.name, isNull);
        expect(
          hits.single.attributes.keys,
          isNot(contains(DiscoveryAttr.manufacturer)),
        );
      },
    );

    test('works without description fetches', () async {
      final hits = await SsdpDiscovery(
        net,
        attempts: 1,
        fetchDescriptions: false,
      ).scan(const Duration(seconds: 1)).toList();
      expect(hits, hasLength(3));
      expect(net.httpCalls, isEmpty);
    });

    test('reports an error when no query can be sent', () async {
      net.features.remove(TransportFeature.multicast);
      final events = <Object>[];
      await provider()
          .scan(const Duration(seconds: 1))
          .handleError(events.add)
          .drain<void>();
      expect(
        events.single,
        isA<WatchmeError>().having(
          (e) => e.code,
          'code',
          WatchmeErrorCode.unsupported,
        ),
      );
    });
  });

  group('SsdpDiscovery on loopback sockets', () {
    late HttpServer descriptions;
    late RawDatagramSocket responder;
    late List<String> searchTargets;

    Future<void> startResponder(InternetAddress bindTo) async {
      searchTargets = [];
      descriptions = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      descriptions.listen((request) {
        request.response
          ..headers.contentType = ContentType('text', 'xml')
          ..headers.set('Application-URL', 'http://127.0.0.1:8009/apps/')
          ..write(fireTvDescription)
          ..close();
      });
      responder = await RawDatagramSocket.bind(bindTo, 0);
      responder.listen((event) {
        final d = responder.receive();
        if (d == null) return;
        final search = SsdpMessage.tryParseBytes(d.data);
        if (search?.kind != SsdpMessageKind.search) return;
        searchTargets.add(search!.header('st')!);
        responder.send(
          utf8.encode(
            fireTvDialResponse(
              locationHost: '127.0.0.1',
            ).replaceAll('127.0.0.1:60000', '127.0.0.1:${descriptions.port}'),
          ),
          d.address,
          d.port,
        );
      });
    }

    tearDown(() async {
      responder.close();
      await descriptions.close(force: true);
    });

    test(
      'a unicast loopback "group" round-trips through IoNetworkStack',
      () async {
        await startResponder(InternetAddress.loopbackIPv4);
        final hits =
            await SsdpDiscovery(
                  IoNetworkStack(),
                  group: '127.0.0.1',
                  port: responder.port,
                  attempts: 1,
                )
                .scan(const Duration(milliseconds: 600), serviceTypes: {dialSt})
                .toList();
        expect(searchTargets, [dialSt]);
        final hit = hits.single;
        expect(hit.host, '127.0.0.1');
        expect(hit.port, descriptions.port);
        expect(
          hit.attributes,
          containsPair(DiscoveryAttr.manufacturer, 'Amazon'),
        );
        expect(
          hit.attributes,
          containsPair(
            DiscoveryAttr.applicationUrl,
            'http://127.0.0.1:8009/apps/',
          ),
        );
      },
    );

    test('real multicast M-SEARCH confined to loopback', () async {
      await startResponder(InternetAddress.anyIPv4);
      final group = InternetAddress('239.255.77.2');
      final lo = (await NetworkInterface.list(includeLoopback: true))
          .firstWhere((i) => i.addresses.any((a) => a.isLoopback));
      try {
        responder.joinMulticast(group, lo);
      } on SocketException catch (e) {
        markTestSkipped('cannot join a multicast group on loopback: $e');
        return;
      }
      final hits = await SsdpDiscovery(
        IoNetworkStack(
          multicastInterfaces: [InternetAddress.loopbackIPv4],
          multicastHops: 0,
        ),
        group: group.address,
        port: responder.port,
        attempts: 2,
        resendDelay: const Duration(milliseconds: 50),
      ).scan(const Duration(milliseconds: 600)).toList();
      expect(searchTargets.toSet(), SsdpDiscovery.defaultSearchTargets.toSet());
      expect(
        hits.single.attributes,
        containsPair(DiscoveryAttr.modelName, 'AFTKA'),
      );
    });
  });
}
