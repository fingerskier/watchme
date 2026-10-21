import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import '../support/policies.dart';
import '../support/tls_fixtures.dart';

void main() {
  final loopback = InternetAddress.loopbackIPv4;

  group('HTTPS trust', () {
    late HttpServer selfSigned;
    late HttpServer caSigned;
    late int selfSignedHits;
    late int caSignedHits;
    final selfSignedSha = TlsFixtures.fingerprint(TlsFixtures.selfSignedPem);
    final caSignedSha = TlsFixtures.fingerprint(TlsFixtures.serverPem);

    setUp(() async {
      selfSignedHits = 0;
      caSignedHits = 0;
      selfSigned = await HttpServer.bindSecure(
        loopback,
        0,
        TlsFixtures.serverContext(
          TlsFixtures.selfSignedPem,
          TlsFixtures.selfSignedKey,
        ),
      );
      selfSigned.listen((request) {
        selfSignedHits++;
        request.response
          ..write('self-signed')
          ..close();
      });
      caSigned = await HttpServer.bindSecure(
        loopback,
        0,
        TlsFixtures.serverContext(TlsFixtures.serverPem, TlsFixtures.serverKey),
      );
      caSigned.listen((request) {
        caSignedHits++;
        request.response
          ..write('ca-signed')
          ..close();
      });
    });

    tearDown(() async {
      await selfSigned.close(force: true);
      await caSigned.close(force: true);
    });

    Uri selfSignedUri() => Uri.parse('https://127.0.0.1:${selfSigned.port}/');
    Uri caSignedUri() => Uri.parse('https://127.0.0.1:${caSigned.port}/');

    // A stack that trusts the test CA, standing in for a platform root.
    IoNetworkStack trustingCa() => IoNetworkStack(
      destinationPolicy: loopbackAllowed,
      extraTrustedRootsPem: utf8.encode(TlsFixtures.caPem),
    );

    test('the default policy rejects a self-signed certificate', () async {
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .http(HttpCall.get(selfSignedUri())),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      expect(selfSignedHits, 0);
    });

    test('allowSelfSigned accepts it and reports the fingerprint', () async {
      final result = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(
            HttpCall.get(selfSignedUri()),
            tls: const TlsPolicy(allowSelfSigned: true),
          );
      expect(result.status, 200);
      expect(result.text, 'self-signed');
      expect(result.peerCertificateSha256, selfSignedSha);
    });

    test('a matching pin accepts a self-signed certificate', () async {
      final result = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(
            HttpCall.get(selfSignedUri()),
            tls: TlsPolicy.pinned([selfSignedSha.toUpperCase()]),
          );
      expect(result.text, 'self-signed');
      expect(result.peerCertificateSha256, selfSignedSha);
    });

    test('a pin mismatch fails with protocol before any request', () async {
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed).http(
          HttpCall.get(selfSignedUri()),
          tls: TlsPolicy.pinned([fakeFingerprint('another TV')]),
        ),
        throwsWatchmeError(
          WatchmeErrorCode.protocol,
          message: contains('does not match the pin'),
        ),
      );
      expect(selfSignedHits, 0);
    });

    test('trust-on-first-use accepts and reports the fingerprint', () async {
      final result = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(HttpCall.get(selfSignedUri()), tls: const TlsPolicy.firstUse());
      expect(result.peerCertificateSha256, selfSignedSha);

      // The recorded fingerprint then pins the next connection.
      final pinned = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(
            HttpCall.get(selfSignedUri()),
            tls: TlsPolicy.pinned([result.peerCertificateSha256!]),
          );
      expect(pinned.status, 200);
    });

    test('a trusted chain passes platform verification', () async {
      final result = await trustingCa().http(HttpCall.get(caSignedUri()));
      expect(result.text, 'ca-signed');
      expect(result.peerCertificateSha256, caSignedSha);
    });

    test('pins are enforced even when the chain is trusted', () async {
      await expectLater(
        trustingCa().http(
          HttpCall.get(caSignedUri()),
          tls: TlsPolicy.pinned([selfSignedSha]),
        ),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      expect(caSignedHits, 0);
      final ok = await trustingCa().http(
        HttpCall.get(caSignedUri()),
        tls: TlsPolicy.pinned([caSignedSha]),
      );
      expect(ok.status, 200);
    });

    test('an untrusted CA is rejected by the default policy', () async {
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .http(HttpCall.get(caSignedUri())),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('a client identity is presented for mutual TLS', () async {
      final mtls = await HttpServer.bindSecure(
        loopback,
        0,
        TlsFixtures.serverContext(TlsFixtures.serverPem, TlsFixtures.serverKey)
          ..setTrustedCertificatesBytes(utf8.encode(TlsFixtures.caPem)),
        requestClientCertificate: true,
      );
      addTearDown(() => mtls.close(force: true));
      mtls.listen((request) {
        request.response
          ..write(request.certificate?.subject ?? 'anonymous')
          ..close();
      });
      final uri = Uri.parse('https://127.0.0.1:${mtls.port}/');
      final identity = ClientIdentity.pem(
        certificateChain: TlsFixtures.clientPem,
        privateKey: TlsFixtures.clientKey,
      );
      final withIdentity = await trustingCa().http(
        HttpCall.get(uri),
        identity: identity,
      );
      expect(withIdentity.text, contains('watchme test client'));
      final without = await trustingCa().http(HttpCall.get(uri));
      expect(without.text, 'anonymous');
    });
  });

  group('HTTP', () {
    test(
      'sends only the caller headers plus Host and Content-Length',
      () async {
        final server = await ServerSocket.bind(loopback, 0);
        addTearDown(server.close);
        final requests = <String>[];
        server.listen((socket) {
          final buffer = StringBuffer();
          socket.listen((data) {
            buffer.write(latin1.decode(data));
            final text = buffer.toString();
            final end = text.indexOf('\r\n\r\n');
            if (end < 0) return;
            final head = text.substring(0, end);
            final length = RegExp(
              r'content-length: (\d+)',
              caseSensitive: false,
            ).firstMatch(head);
            if (text.length - end - 4 < int.parse(length?.group(1) ?? '0')) {
              return;
            }
            requests.add(text);
            socket
              ..write('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok')
              ..close();
          });
        });
        final stack = IoNetworkStack(destinationPolicy: loopbackAllowed);
        final base = 'http://127.0.0.1:${server.port}';

        final post = await stack.http(
          HttpCall.post(
            Uri.parse('$base/keypress/Home'),
            headers: {'X-Api-Key': '0987654321', 'X-Client-Token': 'secret'},
          ),
        );
        expect(post.text, 'ok');
        final postLines = requests.single.split('\r\n');
        expect(postLines.first, 'POST /keypress/Home HTTP/1.1');
        final postHeaders = postLines
            .skip(1)
            .where((l) => l.isNotEmpty)
            .toList();
        expect(
          postHeaders,
          unorderedEquals([
            'X-Api-Key: 0987654321',
            'X-Client-Token: secret',
            'host: 127.0.0.1:${server.port}',
            'content-length: 0',
          ]),
        );

        await stack.http(
          HttpCall.json('POST', Uri.parse('$base/pin'), {'pin': '1234'}),
        );
        expect(requests.last, endsWith('{"pin":"1234"}'));
        expect(
          requests.last,
          contains('Content-Type: application/json; charset=utf-8'),
        );

        await stack.http(HttpCall.get(Uri.parse('$base/query/device-info')));
        final getHeaders = requests.last
            .split('\r\n')
            .skip(1)
            .where((l) => l.isNotEmpty)
            .map((l) => l.split(':').first.toLowerCase());
        expect(getHeaders, everyElement(isIn(['host', 'content-length'])));
      },
    );

    test('returns error statuses, headers and bodies as results', () async {
      final server = await HttpServer.bind(loopback, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..statusCode = 403
          ..headers.add('X-Roku-Reserved', 'a')
          ..headers.add('X-Roku-Reserved', 'b')
          ..write('ECP command not allowed in Limited mode.')
          ..close();
      });
      final result = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(
            HttpCall.post(
              Uri.parse('http://127.0.0.1:${server.port}/keypress/Up'),
            ),
          );
      expect(result.status, 403);
      expect(result.ok, isFalse);
      expect(result.text, 'ECP command not allowed in Limited mode.');
      expect(result.header('x-roku-reserved'), 'a, b');
      expect(result.peerCertificateSha256, isNull);
    });

    test('does not follow redirects', () async {
      final server = await HttpServer.bind(loopback, 0);
      addTearDown(() => server.close(force: true));
      var hits = 0;
      server.listen((request) {
        hits++;
        request.response
          ..statusCode = 302
          ..headers.set('Location', '/elsewhere')
          ..close();
      });
      final result = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(HttpCall.get(Uri.parse('http://127.0.0.1:${server.port}/')));
      expect(result.status, 302);
      expect(result.header('location'), '/elsewhere');
      expect(hits, 1);
    });

    test('a refused connection is unreachable', () async {
      final port = await _closedPort();
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .http(HttpCall.get(Uri.parse('http://127.0.0.1:$port/'))),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('a peer that accepts but never answers times out', () async {
      final server = await ServerSocket.bind(loopback, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await server.close();
      });
      final stopwatch = Stopwatch()..start();
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed).http(
          HttpCall.get(
            Uri.parse('http://127.0.0.1:${server.port}/'),
            timeout: const Duration(milliseconds: 300),
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.timeout),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('a TLS handshake that never completes times out', () async {
      final server = await ServerSocket.bind(loopback, 0);
      final held = <Socket>[];
      server.listen(held.add);
      addTearDown(() async {
        for (final s in held) {
          s.destroy();
        }
        await server.close();
      });
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed).http(
          HttpCall.get(
            Uri.parse('https://127.0.0.1:${server.port}/'),
            timeout: const Duration(milliseconds: 300),
          ),
          tls: const TlsPolicy.firstUse(),
        ),
        throwsWatchmeError(WatchmeErrorCode.timeout),
      );
    });

    test('an oversized body fails with protocol', () async {
      final server = await HttpServer.bind(loopback, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        request.response
          ..write('x' * 2048)
          ..close();
      });
      await expectLater(
        IoNetworkStack(
          destinationPolicy: loopbackAllowed,
          maxResponseBytes: 1024,
        ).http(HttpCall.get(Uri.parse('http://127.0.0.1:${server.port}/'))),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test('a per-call limit below the stack limit applies', () async {
      final server = await HttpServer.bind(loopback, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) {
        // Chunked: no Content-Length, so the limit is enforced while reading.
        request.response
          ..write('x' * 4096)
          ..close();
      });
      final uri = Uri.parse('http://127.0.0.1:${server.port}/');
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .http(HttpCall.get(uri, maxResponseBytes: 1024)),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      final ok = await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .http(HttpCall.get(uri, maxResponseBytes: 8192));
      expect(ok.body, hasLength(4096));
    });

    test('an announced oversized body fails before it arrives', () async {
      final server = await ServerSocket.bind(loopback, 0);
      addTearDown(server.close);
      final open = <Socket>[];
      addTearDown(() {
        for (final s in open) {
          s.destroy();
        }
      });
      server.listen((socket) {
        open.add(socket);
        socket.listen((_) {
          // Announce 2 MiB, send a few bytes and keep the connection open.
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Length: ${2 * 1024 * 1024}\r\n\r\nxx',
          );
        });
      });
      final watch = Stopwatch()..start();
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed).http(
          HttpCall.get(
            Uri.parse('http://127.0.0.1:${server.port}/'),
            maxResponseBytes: 512 * 1024,
            timeout: const Duration(seconds: 5),
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    });

    test('a connection closed mid-response is a protocol error', () async {
      final server = await ServerSocket.bind(loopback, 0);
      addTearDown(server.close);
      server.listen((socket) {
        socket.listen((_) {
          socket
            ..write('HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial')
            ..close();
        });
      });
      await expectLater(
        IoNetworkStack(destinationPolicy: loopbackAllowed)
            .http(HttpCall.get(Uri.parse('http://127.0.0.1:${server.port}/'))),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });
  });
}

Future<int> _closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}
