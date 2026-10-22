import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

void main() {
  late FakeNetworkStack net;
  setUp(() => net = FakeNetworkStack());

  group('http', () {
    test('routes by method, path, host and port, and records calls', () async {
      net.onHttp(
        'GET',
        '/query/device-info',
        (_) => HttpResult.text(200, '<device-info/>'),
        port: 51234,
      );
      net.respond('POST', RegExp(r'^/keypress/'), HttpResult(200));

      final info = await net.http(
        HttpCall.get(Uri.parse('http://127.0.0.1:51234/query/device-info')),
      );
      expect(info.text, '<device-info/>');
      final key = await net.http(
        HttpCall.post(Uri.parse('http://127.0.0.1:8060/keypress/Home')),
      );
      expect(key.status, 200);

      expect(net.httpCalls, hasLength(2));
      expect(net.callsTo('POST', '/keypress/Home'), hasLength(1));
      expect(net.callsTo('*', RegExp('keypress')), hasLength(1));
      expect(net.httpLog.first.result, info);
    });

    test('later routes override earlier ones; times limits a route', () async {
      final uri = Uri.parse('http://10.0.0.1/x');
      net.respond('GET', '/x', HttpResult(200));
      final once = net.respond('GET', '/x', HttpResult(403), times: 1);
      expect((await net.http(HttpCall.get(uri))).status, 403);
      expect((await net.http(HttpCall.get(uri))).status, 200);
      expect(once.hits, 1);
      expect(once.exhausted, isTrue);
    });

    test('port matches the effective port of the URI', () async {
      net.respond('GET', '/', HttpResult(204), port: 80);
      expect(
        (await net.http(HttpCall.get(Uri.parse('http://10.0.0.1/')))).status,
        204,
      );
    });

    test('onHttpWhere matches on anything', () async {
      net.onHttpWhere(
        (call) => call.uri.queryParameters['contentId'] == '42',
        (call) => HttpResult(200),
      );
      final r = await net.http(
        HttpCall.post(Uri.parse('http://10.0.0.1/launch/12?contentId=42')),
      );
      expect(r.status, 200);
    });

    test('unmatched requests are unreachable by default, or 404', () async {
      final call = HttpCall.get(Uri.parse('http://10.0.0.1/nothing'));
      await expectLater(
        net.http(call),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      expect(net.unmatchedCalls, [call]);
      expect(net.httpLog.single.error, isA<WatchmeError>());
      net.unmatchedHttp = UnmatchedHttp.notFound;
      expect((await net.http(call)).status, 404);
    });

    test('handlers can throw transport errors', () async {
      net.onHttp('*', '/', (_) => throw const WatchmeError.timeout('slow'));
      await expectLater(
        net.http(HttpCall.get(Uri.parse('http://10.0.0.1/'))),
        throwsWatchmeError(WatchmeErrorCode.timeout),
      );
    });

    test('a handler slower than the call timeout times out', () async {
      final never = Completer<HttpResult>();
      net.onHttp('GET', '/', (_) => never.future);
      await expectLater(
        net.http(
          HttpCall.get(
            Uri.parse('http://10.0.0.1/'),
            timeout: const Duration(milliseconds: 10),
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.timeout),
      );
    });

    test('setUnreachable refuses a host or a single port', () async {
      net.respond('*', RegExp('.*'), HttpResult(201));
      net.setUnreachable('10.0.0.7', port: 8080);
      await expectLater(
        net.http(HttpCall.get(Uri.parse('https://10.0.0.7:8080/v1'))),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      final dial = await net.http(
        HttpCall.post(Uri.parse('http://10.0.0.7:8009/apps/FireTVRemote')),
      );
      expect(dial.status, 201);
      net.setReachable('10.0.0.7', port: 8080);
      expect(
        (await net.http(HttpCall.get(Uri.parse('https://10.0.0.7:8080/v1'))))
            .status,
        201,
      );
    });
  });

  group('TLS', () {
    final cert = fakeFingerprint('fire tv');
    final uri = Uri.parse('https://10.0.0.7:8080/v1/FireTV');

    setUp(() {
      net.serveTls('10.0.0.7', 8080, certificateSha256: cert);
      net.respond('GET', '/v1/FireTV', HttpResult(200));
    });

    test('self-signed certificate rejected by the platform policy', () async {
      await expectLater(
        net.http(HttpCall.get(uri)),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('first use accepts and reports the fingerprint', () async {
      final r = await net.http(
        HttpCall.get(uri),
        tls: const TlsPolicy.firstUse(),
      );
      expect(r.peerCertificateSha256, cert);
    });

    test('pins are enforced', () async {
      final ok = await net.http(
        HttpCall.get(uri),
        tls: TlsPolicy.pinned([cert]),
      );
      expect(ok.status, 200);
      await expectLater(
        net.http(
          HttpCall.get(uri),
          tls: TlsPolicy.pinned([fakeFingerprint('impostor')]),
        ),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('unregistered https peers are platform-trusted', () async {
      net.respond('GET', '/', HttpResult(200));
      final r = await net.http(HttpCall.get(Uri.parse('https://10.0.0.9/')));
      expect(r.peerCertificateSha256, fakeFingerprint('10.0.0.9:443'));
    });
  });

  group('WebSocket', () {
    test('scripted peer exchanges messages both ways', () async {
      net.onWebSocket('10.0.0.3', 3000, (peer) {
        peer.received.listen((m) {
          if (m == 'hello') peer.send('{"type":"registered"}');
          if (m is Uint8List) peer.send([...m.reversed]);
        });
      });

      final socket = await net.webSocket(
        Uri.parse('ws://10.0.0.3:3000/'),
        headers: const {'Origin': 'null'},
      );
      final received = <Object>[];
      final sub = socket.messages.listen(received.add);
      socket.send('hello');
      socket.send([1, 2, 3]);
      await pumpEventQueue();
      expect(received, [
        '{"type":"registered"}',
        Uint8List.fromList([3, 2, 1]),
      ]);

      final peer = net.webSocketPeers.single;
      expect(peer.headers, {'Origin': 'null'});
      expect(peer.receivedLog, [
        'hello',
        Uint8List.fromList([1, 2, 3]),
      ]);

      await peer.close(1000, 'bye');
      await socket.done;
      expect(socket.closeCode, 1000);
      expect(peer.isClosed, isTrue);
      await sub.cancel();
      expect(() => socket.send('late'), throwsStateError);
    });

    test('wss checks TLS and path-specific servers win', () async {
      net.serveTls('10.0.0.3', 3001, certificateSha256: fakeFingerprint('lg'));
      var generic = 0;
      var specific = 0;
      net.onWebSocket('10.0.0.3', 3001, (_) => generic++);
      net.onWebSocket('10.0.0.3', 3001, (_) => specific++, path: '/pointer');
      await expectLater(
        net.webSocket(Uri.parse('wss://10.0.0.3:3001/')),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      final s = await net.webSocket(
        Uri.parse('wss://10.0.0.3:3001/pointer'),
        tls: const TlsPolicy(allowSelfSigned: true),
      );
      expect(s.peerCertificateSha256, fakeFingerprint('lg'));
      expect((specific, generic), (1, 0));
      await s.close();
    });

    test('no server means unreachable', () async {
      await expectLater(
        net.webSocket(Uri.parse('ws://10.0.0.3:3000/')),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });
  });

  group('TCP', () {
    test('scripted byte peer with TLS details', () async {
      net.serveTls(
        '10.0.0.4',
        6467,
        certificateSha256: fakeFingerprint('atv'),
        certificateDer: [0x30, 0x82],
      );
      net.onTcp('10.0.0.4', 6467, (peer) {
        peer.received.listen((chunk) => peer.send([chunk.length]));
      });
      final socket = await net.tcp(
        '10.0.0.4',
        6467,
        tls: const TlsPolicy.firstUse(),
      );
      expect(socket.peerCertificateSha256, fakeFingerprint('atv'));
      expect(socket.peerCertificateDer, [0x30, 0x82]);
      final replies = <List<int>>[];
      socket.input.listen(replies.add);
      socket.send([9, 9, 9]);
      await socket.flush();
      await pumpEventQueue();
      expect(replies, [
        [3],
      ]);
      expect(net.tcpPeers.single.receivedBytes, [9, 9, 9]);
      await socket.close();
      expect(net.tcpPeers.single.isClosed, isTrue);
    });

    test('closed port is unreachable', () async {
      await expectLater(
        net.tcp('10.0.0.4', 5555),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });
  });

  group('UDP', () {
    test('datagrams are captured; broadcast must be enabled', () async {
      final packet = magicPacket('aa:bb:cc:dd:ee:ff');
      await net.sendDatagram('255.255.255.255', 9, packet, broadcast: true);
      await net.sendDatagram('192.0.2.10', 9, packet);
      expect(net.sentDatagrams, hasLength(2));
      expect(net.sentDatagrams.first.bytes, packet);
      expect(net.sentDatagrams.first.broadcast, isTrue);
      await expectLater(
        net.sendDatagram('255.255.255.255', 9, packet),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('multicast queries get scripted replies', () async {
      net.onMulticast('239.255.255.250', 1900, (query) {
        final text = utf8.decode(query);
        if (!text.contains('ST: roku:ecp')) return const [];
        return [
          Datagram(
            '192.0.2.10',
            1900,
            utf8.encode('HTTP/1.1 200 OK\r\nST: roku:ecp\r\n\r\n'),
          ),
        ];
      });
      final replies = await net
          .multicastQuery(
            '239.255.255.250',
            1900,
            utf8.encode('M-SEARCH * HTTP/1.1\r\nST: roku:ecp\r\n\r\n'),
            const Duration(seconds: 3),
          )
          .toList();
      expect(replies.single.host, '192.0.2.10');
      expect(net.multicastQueries.single.text, contains('M-SEARCH'));
      expect(net.multicastQueries.single.window, const Duration(seconds: 3));
    });
  });

  group('features', () {
    test('missing features make operations unsupported', () async {
      final browserish = FakeNetworkStack(
        features: {TransportFeature.httpReadCrossOrigin},
      );
      await expectLater(
        browserish.tcp('10.0.0.1', 1),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
      await expectLater(
        browserish.sendDatagram('10.0.0.1', 9, [0]),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
      await expectLater(
        browserish
            .multicastQuery('239.255.255.250', 1900, [], Duration.zero)
            .toList(),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
      await expectLater(
        browserish.http(
          HttpCall.get(
            Uri.parse('http://10.0.0.1/'),
            headers: const {'X-Api-Key': 'k'},
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
    });
  });
}
