import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/src/network/destinations.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import '../support/policies.dart';
import '../support/tls_fixtures.dart';

// Tests that name anything but loopback run under [recordingConnects]:
// every TCP connect the stack attempts is recorded and fails as refused,
// so even a regression that lets a refused destination through cannot put
// a packet on the network.

/// A unique-local address no device uses: the "allowed LAN address" of
/// tests whose connect is always blocked.
const ula = 'fd7a:11e5:9a3c::50';

void main() {
  late List<Object?> attempts;

  setUp(() => attempts = []);

  Future<T> recordingConnects<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(
        body,
        socketStartConnect:
            (host, port, {sourceAddress, sourcePort = 0}) async {
              attempts.add(host);
              throw SocketException('connect blocked by the test', port: port);
            },
      );

  Matcher refused([Object? message]) =>
      throwsWatchmeError(WatchmeErrorCode.destinationRefused, message: message);

  group('IoNetworkStack refuses non-LAN destinations', () {
    const nonLan = [
      '8.8.8.8', // public
      '2001:4860:4860::8888', // public IPv6
      '64:ff9b::808:808', // NAT64 to a public IPv4 host
      '100.64.0.1', // shared range: CGNAT, VPN overlays
      '203.0.113.9', // documentation
      '0.0.0.0', // reaches this host on Linux and macOS
      '127.0.0.1', // loopback, not allowed by default
      '::1',
      '::ffff:127.0.0.1',
      '224.0.0.251', // multicast is not a unicast destination
      '255.255.255.255',
    ];

    test('IP literals over HTTP, WebSocket, TCP and TLS', () async {
      final stack = IoNetworkStack();
      for (final address in nonLan) {
        Uri uri(String scheme) =>
            Uri(scheme: scheme, host: address, port: 8060, path: '/');
        await recordingConnects(() async {
          await expectLater(
            stack.http(HttpCall.get(uri('http'))),
            refused(contains(address)),
            reason: address,
          );
          await expectLater(
            stack.http(
              HttpCall.get(uri('https')),
              tls: const TlsPolicy.firstUse(),
            ),
            refused(),
            reason: address,
          );
          await expectLater(
            stack.webSocket(uri('ws')),
            refused(),
            reason: address,
          );
          await expectLater(stack.tcp(address, 8060), refused());
          await expectLater(
            stack.tcp(address, 8060, tls: const TlsPolicy.firstUse()),
            refused(),
            reason: address,
          );
        });
      }
      expect(attempts, isEmpty);
    });

    test('unicast UDP', () async {
      final stack = IoNetworkStack();
      // Only addresses that cannot reach another machine, so that even a
      // regression sends nothing anywhere that matters.
      for (final address in ['203.0.113.9', '100.64.0.1', '0.0.0.0', '::1']) {
        await expectLater(
          stack.sendDatagram(address, 9, [0]),
          refused(),
          reason: address,
        );
        // broadcast: true exempts the broadcast address, nothing else.
        await expectLater(
          stack.sendDatagram(address, 9, [0], broadcast: true),
          refused(),
          reason: address,
        );
      }
    });

    test('loopback UDP is refused unless allowed', () async {
      final listener = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(listener.close);
      final received = <Uint8List>[];
      listener.listen((_) {
        final d = listener.receive();
        if (d != null) received.add(d.data);
      });
      await expectLater(
        IoNetworkStack().sendDatagram('127.0.0.1', listener.port, [1]),
        refused(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
      await IoNetworkStack(destinationPolicy: loopbackAllowed)
          .sendDatagram('127.0.0.1', listener.port, [2]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, [
        [2],
      ]);
    });

    test('a unicast multicastQuery "group"', () async {
      final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(responder.close);
      var queries = 0;
      responder.listen((_) {
        if (responder.receive() != null) queries++;
      });
      await expectLater(
        IoNetworkStack().multicastQuery('127.0.0.1', responder.port, [
          0,
        ], const Duration(milliseconds: 100)).toList(),
        refused(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(queries, 0);
    });
  });

  group('IoNetworkStack resolves names itself', () {
    late List<String> lookups;
    late Map<String, List<List<String>>> answers;

    // Each lookup of a name takes its next answer (the last one repeats),
    // so a test can make DNS change its mind.
    IoNetworkStack stack({
      DestinationPolicy policy = DestinationPolicy.lanOnly,
    }) => IoNetworkStack(
      destinationPolicy: policy,
      lookup: (host) async {
        lookups.add(host);
        final queue = answers[host];
        if (queue == null) throw SocketException('Failed host lookup');
        final answer = queue.length > 1 ? queue.removeAt(0) : queue.first;
        return [for (final a in answer) InternetAddress(a)];
      },
    );

    setUp(() {
      lookups = [];
      answers = {};
    });

    test('and refuses one that resolves to a non-LAN address', () async {
      answers = {
        'tv.test': [
          ['8.8.8.8'],
        ],
        'overlay.test': [
          ['100.100.1.2'],
        ],
        'self.test': [
          ['127.0.0.1'],
        ],
        // What getaddrinfo makes of a shorthand literal: judged by the
        // address it resolves to, not by its text.
        '127.1': [
          ['127.0.0.1'],
        ],
      };
      final s = stack();
      await recordingConnects(() async {
        await expectLater(
          s.http(HttpCall.get(Uri.parse('http://tv.test:8060/'))),
          refused(contains('tv.test (8.8.8.8)')),
        );
        await expectLater(
          s.webSocket(Uri.parse('ws://overlay.test:8002/')),
          refused(contains('overlay.test (100.100.1.2)')),
        );
        await expectLater(s.tcp('self.test', 6466), refused());
        await expectLater(
          s.tcp('127.1', 6466),
          refused(contains('127.1 (127.0.0.1)')),
        );
        await expectLater(s.sendDatagram('tv.test', 9, [0]), refused());
      });
      expect(attempts, isEmpty);
      expect(lookups, [
        'tv.test',
        'overlay.test',
        'self.test',
        '127.1',
        'tv.test',
      ]);
    });

    // Documented choice: a mixed answer is refused as a whole rather than
    // narrowed to its LAN addresses, because a name answering with both is
    // how DNS rebinding starts.
    test(
      'and refuses one whose answer mixes LAN and non-LAN addresses',
      () async {
        answers = {
          'mixed.test': [
            [ula, '8.8.8.8'],
          ],
          'mixed6.test': [
            ['10.0.0.50', '100.64.0.1'],
          ],
        };
        final s = stack();
        await recordingConnects(() async {
          await expectLater(
            s.http(HttpCall.get(Uri.parse('http://mixed.test:8060/'))),
            refused(contains('mixed.test (8.8.8.8)')),
          );
          await expectLater(s.tcp('mixed6.test', 8060), refused());
        });
        expect(attempts, isEmpty);
      },
    );

    test(
      'and connects to the checked address, so DNS cannot rebind it',
      () async {
        answers = {
          'tv.test': [
            [ula],
            ['8.8.8.8'],
          ],
        };
        final s = stack();
        await recordingConnects(() async {
          // The connect is blocked by the test, hence unreachable.
          await expectLater(
            s.http(HttpCall.get(Uri.parse('http://tv.test:8060/'))),
            throwsWatchmeError(WatchmeErrorCode.unreachable),
          );
          // The next call resolves afresh, and the new answer is refused.
          await expectLater(
            s.http(HttpCall.get(Uri.parse('http://tv.test:8060/'))),
            refused(contains('tv.test (8.8.8.8)')),
          );
        });
        expect(lookups, ['tv.test', 'tv.test']);
        // One connect, to the address that was checked, never to the name.
        expect(attempts, [InternetAddress(ula)]);
      },
    );

    test('and keeps the Host header and TLS name of the URI', () async {
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => plain.close(force: true));
      final hosts = <String?>[];
      plain.listen((request) {
        hosts.add(request.headers.value(HttpHeaders.hostHeader));
        request.response.close();
      });
      // Its certificate names 127.0.0.1 and localhost, not tv.test.
      final secure = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        TlsFixtures.serverContext(TlsFixtures.serverPem, TlsFixtures.serverKey),
      );
      addTearDown(() => secure.close(force: true));
      var secureHits = 0;
      secure.listen((request) {
        secureHits++;
        request.response.close();
      });
      answers = {
        'tv.test': [
          ['127.0.0.1'],
        ],
        'localhost': [
          ['127.0.0.1'],
        ],
      };
      final s = IoNetworkStack(
        destinationPolicy: loopbackAllowed,
        extraTrustedRootsPem: utf8.encode(TlsFixtures.caPem),
        lookup: stack().lookup,
      );
      // Both names resolve to loopback only, so these connects are real.
      final ok = await s.http(
        HttpCall.get(Uri.parse('http://tv.test:${plain.port}/')),
      );
      expect(ok.status, 200);
      expect(hosts, ['tv.test:${plain.port}']);

      // Verified against the name, so tv.test fails although the address
      // it resolved to is in the certificate...
      await expectLater(
        s.http(HttpCall.get(Uri.parse('https://tv.test:${secure.port}/'))),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      expect(secureHits, 0);
      // ...and localhost, which the certificate names, passes.
      final viaName = await s.http(
        HttpCall.get(Uri.parse('https://localhost:${secure.port}/')),
      );
      expect(viaName.status, 200);
      expect(secureHits, 1);
    });

    test('and tries each checked address in turn', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) => request.response.close());
      // Nothing listens on ::1 at that port, so the stack moves on.
      answers = {
        'dual.test': [
          ['::1', '127.0.0.1'],
        ],
      };
      final s = stack(policy: loopbackAllowed);
      final result = await s.http(
        HttpCall.get(Uri.parse('http://dual.test:${server.port}/')),
      );
      expect(result.status, 200);
      expect(lookups, ['dual.test']);
    });
  });

  group('loopback', () {
    late HttpServer server;
    late int hits;

    setUp(() async {
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        hits++;
        request.response
          ..write('ok')
          ..close();
      });
    });

    tearDown(() => server.close(force: true));

    test('is refused by default, by address and by name', () async {
      final stack = IoNetworkStack();
      for (final host in ['127.0.0.1', '[::ffff:127.0.0.1]', 'localhost']) {
        await recordingConnects(() async {
          await expectLater(
            stack.http(HttpCall.get(Uri.parse('http://$host:${server.port}/'))),
            refused(),
            reason: host,
          );
        });
      }
      await recordingConnects(() async {
        await expectLater(stack.tcp('localhost', server.port), refused());
        await expectLater(
          stack.webSocket(Uri.parse('ws://127.0.0.1:${server.port}/')),
          refused(),
        );
      });
      expect(attempts, isEmpty);
      expect(hits, 0);
    });

    test('is reached once allowLoopback is set', () async {
      final stack = IoNetworkStack(destinationPolicy: loopbackAllowed);
      for (final host in ['127.0.0.1', 'localhost']) {
        final result = await stack.http(
          HttpCall.get(Uri.parse('http://$host:${server.port}/')),
        );
        expect(result.text, 'ok', reason: host);
      }
      final socket = await stack.tcp('localhost', server.port);
      await socket.close();
      expect(hits, 2);
    });
  });

  group('DestinationResolver', () {
    late String lo;

    setUpAll(() async {
      lo = (await NetworkInterface.list(includeLoopback: true))
          .firstWhere((i) => i.addresses.any((a) => a.isLoopback))
          .name;
    });

    final resolver = DestinationResolver(
      DestinationPolicy.lanOnly,
      lookup: (host) async => fail('looked up $host'),
    );

    test('keeps an IPv6 zone id for the connection', () async {
      final [scoped] = await resolver.resolve('fe80::1%$lo');
      expect(scoped.address, 'fe80::1%$lo');
      expect(await resolver.resolve('[fe80::1%$lo]'), [scoped]);
      expect(uriHost(Uri.parse('http://[fe80::1%25$lo]:80/')), 'fe80::1%$lo');
      expect(tlsServerName('[fe80::1%$lo]'), 'fe80::1');
      expect(tlsServerName('tv.local'), 'tv.local');
    });

    test('and through the stack, connects with the zone', () async {
      await recordingConnects(() async {
        await expectLater(
          IoNetworkStack().http(
            HttpCall.get(Uri.parse('http://[fe80::1%25$lo]:8080/')),
          ),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
      });
      expect(attempts.map((a) => (a! as InternetAddress).address), [
        'fe80::1%$lo',
      ]);
    });

    test('refuses misplaced zone ids and unknown interfaces', () async {
      await expectLater(resolver.resolve('10.0.0.1%$lo'), refused());
      await expectLater(resolver.resolve('tv.local%$lo'), refused());
      await expectLater(
        resolver.resolve('fe80::1%nosuchif0'),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('exempts only the classes it is told to', () async {
      await expectLater(resolver.resolve('255.255.255.255'), refused());
      expect(
        await resolver.resolve(
          '255.255.255.255',
          exempt: const {HostAddressClass.broadcast},
        ),
        [InternetAddress('255.255.255.255')],
      );
      await expectLater(resolver.resolve('239.255.255.250'), refused());
      expect(
        await resolver.resolve(
          '239.255.255.250',
          exempt: const {HostAddressClass.multicast},
        ),
        [InternetAddress('239.255.255.250')],
      );
      await expectLater(
        resolver.resolve('8.8.8.8', exempt: const {HostAddressClass.broadcast}),
        refused(),
      );
      expect(await resolver.resolve('10.0.0.50'), [
        InternetAddress('10.0.0.50'),
      ]);
    });
  });
}
