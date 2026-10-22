import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import '../support/policies.dart';
import '../support/tls_fixtures.dart';

void main() {
  final loopback = InternetAddress.loopbackIPv4;
  final selfSignedSha = TlsFixtures.fingerprint(TlsFixtures.selfSignedPem);

  group('WebSocket', () {
    late HttpServer plain;
    late HttpServer secure;
    late List<HttpHeaders> handshakes;

    Future<void> serveEcho(HttpServer server) async {
      server.listen((request) async {
        if (request.uri.path == '/forbidden') {
          request.response
            ..statusCode = 403
            ..write('{"error":"blacklisted certificate"}')
            ..close();
          return;
        }
        handshakes.add(request.headers);
        final socket = await WebSocketTransformer.upgrade(
          request,
          protocolSelector: (offered) => offered.first,
        );
        socket.listen((message) {
          if (message == 'close') {
            socket.close(4001, 'bye');
          } else {
            socket.add(message);
          }
        });
      });
    }

    setUp(() async {
      handshakes = [];
      plain = await HttpServer.bind(loopback, 0);
      secure = await HttpServer.bindSecure(
        loopback,
        0,
        TlsFixtures.serverContext(
          TlsFixtures.selfSignedPem,
          TlsFixtures.selfSignedKey,
        ),
      );
      await serveEcho(plain);
      await serveEcho(secure);
    });

    tearDown(() async {
      await plain.close(force: true);
      await secure.close(force: true);
    });

    test('echoes text and binary frames over ws', () async {
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .webSocket(
            Uri.parse('ws://127.0.0.1:${plain.port}/ws'),
            protocols: ['ecp-2', 'other'],
            headers: {'Origin': 'http://watchme.test', 'X-Custom': 'yes'},
          );
      final messages = StreamIterator(socket.messages);
      socket.send('hello');
      expect(await messages.moveNext(), isTrue);
      expect(messages.current, 'hello');
      socket.send([1, 2, 3]);
      expect(await messages.moveNext(), isTrue);
      expect(
        messages.current,
        isA<Uint8List>().having((b) => b, 'bytes', [1, 2, 3]),
      );
      expect(socket.protocol, 'ecp-2');
      expect(socket.peerCertificateSha256, isNull);

      final headers = handshakes.single;
      expect(headers.value('origin'), 'http://watchme.test');
      expect(headers.value('x-custom'), 'yes');
      expect(headers.value('user-agent'), isNull);
      expect(headers.value('sec-websocket-extensions'), isNull);

      await socket.close(1000, 'done');
      await socket.done;
      expect(socket.closeCode, 1000);
    });

    test('reports the server close code and reason', () async {
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .webSocket(Uri.parse('ws://127.0.0.1:${plain.port}/'));
      final received = socket.messages.toList();
      socket.send('close');
      expect(await received, isEmpty);
      await socket.done;
      expect(socket.closeCode, 4001);
      expect(socket.closeReason, 'bye');
    });

    test('echoes over wss with a self-signed certificate', () async {
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .webSocket(
            Uri.parse('wss://127.0.0.1:${secure.port}/'),
            tls: const TlsPolicy.firstUse(),
          );
      expect(socket.peerCertificateSha256, selfSignedSha);
      final reply = socket.messages.first;
      socket.send('over tls');
      expect(await reply, 'over tls');
      await socket.close();
    });

    test(
      'wss is refused under the default policy and on a wrong pin',
      () async {
        final uri = Uri.parse('wss://127.0.0.1:${secure.port}/');
        await expectLater(
          IoNetworkStack(destinationPolicy: loopbackAllowed).webSocket(uri),
          throwsWatchmeError(WatchmeErrorCode.protocol),
        );
        await expectLater(
          IoNetworkStack(destinationPolicy: loopbackAllowed)
              .webSocket(uri, tls: TlsPolicy.pinned([fakeFingerprint('x')])),
          throwsWatchmeError(WatchmeErrorCode.protocol),
        );
        expect(handshakes, isEmpty);
      },
    );

    test('a refused upgrade carries the device body', () async {
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .webSocket(Uri.parse('ws://127.0.0.1:${plain.port}/forbidden')),
        throwsWatchmeError(
          WatchmeErrorCode.rejected,
          rawDeviceMessage: '{"error":"blacklisted certificate"}',
        ),
      );
    });

    test('a closed port is unreachable', () async {
      final port = await _closedPort();
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .webSocket(Uri.parse('ws://127.0.0.1:$port/')),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });
  });

  group('TCP', () {
    test('plain TCP round-trips bytes', () async {
      final server = await ServerSocket.bind(loopback, 0);
      addTearDown(server.close);
      server.listen((s) => s.listen(s.add, onDone: s.close));
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .tcp('127.0.0.1', server.port);
      final input = StreamIterator(socket.input);
      socket.send([0x08, 0x02, 0x10, 0xc8, 0x01]);
      await socket.flush();
      expect(await input.moveNext(), isTrue);
      expect(input.current, [0x08, 0x02, 0x10, 0xc8, 0x01]);
      expect(socket.peerCertificateSha256, isNull);
      expect(socket.peerCertificateDer, isNull);
      await socket.close();
      await socket.done;
    });

    test('TLS with a client identity exposes the peer certificate', () async {
      final server = await SecureServerSocket.bind(
        loopback,
        0,
        TlsFixtures.serverContext(
          TlsFixtures.selfSignedPem,
          TlsFixtures.selfSignedKey,
        )..setTrustedCertificatesBytes(utf8.encode(TlsFixtures.caPem)),
        requestClientCertificate: true,
        requireClientCertificate: true,
      );
      addTearDown(server.close);
      server.listen((s) {
        s.write(s.peerCertificate?.subject ?? 'anonymous');
        s.close();
      });
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .tcp(
            '127.0.0.1',
            server.port,
            tls: TlsPolicy.pinned([selfSignedSha]),
            identity: ClientIdentity.pem(
              certificateChain: TlsFixtures.clientPem,
              privateKey: TlsFixtures.clientKey,
            ),
          );
      final text = await utf8.decodeStream(socket.input);
      expect(text, contains('watchme test client'));
      expect(socket.peerCertificateSha256, selfSignedSha);
      expect(
        socket.peerCertificateDer,
        TlsFixtures.der(TlsFixtures.selfSignedPem),
      );
      await socket.done;
    });

    test('a DER client identity works like PEM', () async {
      final server = await SecureServerSocket.bind(
        loopback,
        0,
        TlsFixtures.serverContext(
          TlsFixtures.selfSignedPem,
          TlsFixtures.selfSignedKey,
        )..setTrustedCertificatesBytes(utf8.encode(TlsFixtures.caPem)),
        requestClientCertificate: true,
        requireClientCertificate: true,
      );
      addTearDown(server.close);
      server.listen((s) {
        s.write(s.peerCertificate?.subject ?? 'anonymous');
        s.close();
      });
      final key = TlsFixtures.clientKey
          .split('\n')
          .where((l) => l.isNotEmpty && !l.startsWith('-----'))
          .join();
      final socket = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .tcp(
            '127.0.0.1',
            server.port,
            tls: const TlsPolicy(allowSelfSigned: true),
            identity: ClientIdentity(
              certificateChain: TlsFixtures.der(TlsFixtures.clientPem),
              privateKey: base64.decode(key),
              encoding: IdentityEncoding.der,
            ),
          );
      expect(await utf8.decodeStream(socket.input), contains('test client'));
    });

    test('a pin mismatch on TLS TCP is a protocol error', () async {
      final server = await SecureServerSocket.bind(
        loopback,
        0,
        TlsFixtures.serverContext(
          TlsFixtures.selfSignedPem,
          TlsFixtures.selfSignedKey,
        ),
      );
      addTearDown(server.close);
      server.listen((s) => s.close());
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed).tcp(
          '127.0.0.1',
          server.port,
          tls: TlsPolicy.pinned([fakeFingerprint('nope')]),
        ),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('a refused connection is unreachable', () async {
      final port = await _closedPort();
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .tcp('127.0.0.1', port),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });
  });

  group('UDP', () {
    test('sendDatagram reaches a loopback listener', () async {
      final listener = await RawDatagramSocket.bind(loopback, 0);
      addTearDown(listener.close);
      final received = Completer<Uint8List>();
      listener.listen((event) {
        final d = listener.receive();
        if (d != null && !received.isCompleted) received.complete(d.data);
      });
      await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .sendDatagram('127.0.0.1', listener.port, [1, 2, 3]);
      expect(await received.future.timeout(const Duration(seconds: 2)), [
        1,
        2,
        3,
      ]);
    });

    test('limited broadcast without broadcast: true is refused', () async {
      await expectLater(
        IoNetworkStack().sendDatagram('255.255.255.255', 9, [0]),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('broadcast is unsupported where multicast is not allowed', () async {
      final stack = IoNetworkStack(multicastAllowed: false);
      expect(stack.features, isNot(contains(TransportFeature.multicast)));
      expect(stack.features, isNot(contains(TransportFeature.udpBroadcast)));
      await expectLater(
        stack.sendDatagram('255.255.255.255', 9, [0], broadcast: true),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
      await expectLater(
        stack.multicastQuery('239.255.255.250', 1900, [
          0,
        ], Duration.zero).toList(),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
    });

    test('multicastQuery collects replies on its socket until the window '
        'ends', () async {
      // A unicast "group" on loopback exercises the reply collection
      // without putting a multicast packet on any network.
      final responder = await RawDatagramSocket.bind(loopback, 0);
      addTearDown(responder.close);
      final queries = <String>[];
      responder.listen((event) {
        final d = responder.receive();
        if (d == null) return;
        queries.add(utf8.decode(d.data));
        responder
          ..send(utf8.encode('reply 1'), d.address, d.port)
          ..send(utf8.encode('reply 2'), d.address, d.port);
      });
      final stopwatch = Stopwatch()..start();
      final replies = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .multicastQuery(
            '127.0.0.1',
            responder.port,
            utf8.encode('M-SEARCH'),
            const Duration(milliseconds: 400),
          )
          .toList();
      expect(stopwatch.elapsed, greaterThanOrEqualTo(_ms(390)));
      expect(queries, ['M-SEARCH']);
      expect(replies.map((d) => d.text), ['reply 1', 'reply 2']);
      expect(replies.first.host, '127.0.0.1');
      expect(replies.first.port, responder.port);
    });

    test('multicastQuery over real multicast confined to loopback', () async {
      final lo = await _loopbackInterface();
      final group = InternetAddress('239.255.77.1');
      final responder = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      addTearDown(responder.close);
      try {
        responder.joinMulticast(group, lo);
      } on SocketException catch (e) {
        markTestSkipped('cannot join a multicast group on loopback: $e');
        return;
      }
      responder.listen((event) {
        final d = responder.receive();
        if (d == null) return;
        responder.send(utf8.encode('pong'), d.address, d.port);
      });
      final replies = await _loopbackOnlyStack()
          .multicastQuery(
            group.address,
            responder.port,
            utf8.encode('ping'),
            const Duration(milliseconds: 500),
          )
          .toList();
      expect(replies.map((d) => d.text), ['pong']);
    });

    test('a multicast interface that fails does not stop the others', () async {
      final lo = await _loopbackInterface();
      final group = InternetAddress('239.255.77.5');
      final responder = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
      );
      addTearDown(responder.close);
      try {
        responder.joinMulticast(group, lo);
      } on SocketException catch (e) {
        markTestSkipped('cannot join a multicast group on loopback: $e');
        return;
      }
      responder.listen((event) {
        final d = responder.receive();
        if (d != null) responder.send(utf8.encode('pong'), d.address, d.port);
      });
      // 192.0.2.1 (TEST-NET-1) is not a local address, so selecting it as
      // the multicast interface fails before anything is sent.
      final stack = IoNetworkStack(
        multicastInterfaces: [
          InternetAddress('192.0.2.1'),
          InternetAddress.loopbackIPv4,
        ],
        multicastHops: 0,
      );
      final replies = await stack
          .multicastQuery(
            group.address,
            responder.port,
            utf8.encode('ping'),
            const Duration(milliseconds: 400),
          )
          .toList();
      expect(replies.map((d) => d.text), ['pong']);

      await expectLater(
        IoNetworkStack(
          multicastInterfaces: [InternetAddress('192.0.2.1')],
          multicastHops: 0,
        ).multicastQuery(group.address, responder.port, [
          0,
        ], Duration.zero).toList(),
        throwsA(isA<WatchmeError>()),
      );
    });
  });
}

/// A stack whose multicast leaves only through loopback, with TTL 0 as a
/// second guard: nothing reaches a real network.
IoNetworkStack _loopbackOnlyStack() => IoNetworkStack(
  multicastInterfaces: [InternetAddress.loopbackIPv4],
  multicastHops: 0,
);

Future<NetworkInterface> _loopbackInterface() async =>
    (await NetworkInterface.list(includeLoopback: true))
        .firstWhere((i) => i.addresses.any((a) => a.isLoopback));

Duration _ms(int ms) => Duration(milliseconds: ms);

Future<int> _closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
