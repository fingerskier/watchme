import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:watchme_core/watchme_core.dart';

import 'connector.dart';
import 'destinations.dart';
import 'io_errors.dart';
import 'io_sockets.dart';
import 'tls_support.dart';

/// The `dart:io` [NetworkStack]: HTTP(S), WebSocket, TCP/TLS, UDP and
/// multicast for native platforms (Linux, macOS, Windows, Android, iOS).
///
/// LAN only: every unicast destination (HTTP, WebSocket, TCP, TLS and
/// unicast UDP, including a unicast "group" given to [multicastQuery]) must
/// be allowed by [destinationPolicy], which by default admits private
/// (RFC 1918), link-local and unique-local IPv6 addresses only. The stack
/// resolves a host name itself (with [lookup]), checks every address it
/// resolves to, refuses the name if any of them is refused, and connects to
/// the checked address, so DNS cannot answer differently between the check
/// and the connection. IP literals are parsed, never resolved, and are
/// judged by the parsed address, not the text. A refusal is a
/// [WatchmeErrorCode.destinationRefused] error raised before any packet is
/// sent. HTTP keeps the URI's host in the `Host` header, and TLS verifies
/// the certificate against (and sends as SNI) the host as named, not the
/// address connected to. Multicast groups and, with `broadcast: true`, the
/// limited broadcast address 255.255.255.255 are not unicast destinations
/// and are not subject to the policy.
///
/// TLS: every connection gets the caller's [TlsPolicy], checked against the
/// peer's leaf certificate right after the handshake and before any request
/// byte is sent (see `TlsPolicy.allows`). Pins are enforced even when the
/// chain is valid. Verification is never disabled globally.
///
/// HTTP: each call uses its own connection, so a pooled connection can never
/// carry one call's TLS decision into another and a device that drops
/// keep-alive connections cannot fail the next call. Only the caller's
/// headers plus `Host` and `Content-Length` are sent (no `User-Agent`,
/// `Accept-Encoding`, cookies or `Origin`), proxies are bypassed, and
/// redirects are returned rather than followed.
///
/// Errors follow the `NetworkStack` contract:
/// * [WatchmeErrorCode.unreachable]: refused, no route, DNS failure, or no
///   answer to the connection attempt within the deadline;
/// * [WatchmeErrorCode.timeout]: connected, but the reply did not arrive
///   within the deadline or the connection was lost (the request may have
///   been delivered);
/// * [WatchmeErrorCode.protocol]: TLS failure (including a pin mismatch),
///   malformed HTTP, a failed WebSocket handshake;
/// * [WatchmeErrorCode.destinationRefused]: the host, or an address it
///   resolved to, is outside [destinationPolicy]. Nothing was sent.
final class IoNetworkStack implements NetworkStack {
  /// Creates a stack.
  ///
  /// * [extraTrustedRootsPem]: CA certificates (PEM) trusted in addition to
  ///   the platform's, e.g. a hub's local CA or a test CA.
  /// * [usePlatformRoots]: load the OS trust store (default true).
  /// * [maxResponseBytes]: larger HTTP bodies fail with a protocol error.
  /// * [multicastHops]: IPv4 TTL for multicast queries (UPnP suggests 2).
  /// * [multicastInterfaces]: local IPv4 addresses to send each multicast
  ///   query from (one send per address); `null` lets the OS choose one.
  ///   See [privateIPv4Addresses] for a multi-homed hub.
  /// * [multicastAllowed]: whether multicast and broadcast may be used.
  ///   Defaults to false on iOS, where they need Apple's multicast
  ///   entitlement, and true elsewhere.
  /// * [destinationPolicy]: which unicast destinations may be contacted;
  ///   LAN-only by default. The in-process app allows loopback for its
  ///   simulators; a hub must not (see `DestinationPolicy.allowLoopback`).
  /// * [lookup]: resolves host names (default `InternetAddress.lookup`).
  ///   Every address it returns is checked against [destinationPolicy].
  IoNetworkStack({
    this.clock = const SystemClock(),
    List<int>? extraTrustedRootsPem,
    bool usePlatformRoots = true,
    this.maxResponseBytes = 64 * 1024 * 1024,
    this.multicastHops = 2,
    this.multicastInterfaces,
    bool? multicastAllowed,
    this.destinationPolicy = DestinationPolicy.lanOnly,
    HostLookup? lookup,
  }) : multicastAllowed = multicastAllowed ?? !Platform.isIOS,
       _connector = Connector(
         SecurityContexts(
           usePlatformRoots: usePlatformRoots,
           extraTrustedRootsPem: extraTrustedRootsPem,
         ),
         DestinationResolver(destinationPolicy, lookup: lookup),
       );

  /// Time source for deadlines and multicast windows.
  final Clock clock;

  /// Upper bound on an HTTP response body.
  final int maxResponseBytes;

  /// IPv4 multicast TTL.
  final int multicastHops;

  /// Local IPv4 addresses multicast queries are sent from; `null` for the
  /// OS default.
  final List<InternetAddress>? multicastInterfaces;

  /// Whether multicast and broadcast are permitted on this platform.
  final bool multicastAllowed;

  /// The unicast destinations this stack may contact.
  final DestinationPolicy destinationPolicy;

  /// Resolves host names; every address it returns is checked against
  /// [destinationPolicy] before it is used.
  HostLookup get lookup => _destinations.lookup;

  final Connector _connector;
  final Random _random = Random.secure();

  DestinationResolver get _destinations => _connector.destinations;

  /// What this stack can do: every network feature, minus multicast and
  /// broadcast when [multicastAllowed] is false.
  Set<TransportFeature> get features => {
    for (final feature in TransportFeature.allNetwork)
      if (multicastAllowed ||
          (feature != TransportFeature.multicast &&
              feature != TransportFeature.udpBroadcast))
        feature,
  };

  // ---------------------------------------------------------------- HTTP

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) async {
    final uri = call.uri;
    final secure = switch (uri.scheme) {
      'https' => true,
      'http' => false,
      _ => throw ArgumentError.value(uri, 'call.uri', 'not http or https'),
    };
    final target = '${uri.host}:${uri.port}';
    final attempt = ConnectAttempt();
    final client = _client(attempt, secure ? tls : null, identity);
    try {
      return await runWithin(clock, call.timeout, () async {
        final request = await client.openUrl(call.method, uri);
        _prepare(request, call.headers);
        final body = call.body;
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        } else if (const {'POST', 'PUT', 'PATCH'}.contains(call.method)) {
          request.contentLength = 0;
        }
        final response = await request.close();
        final limit = min(
          call.maxResponseBytes ?? maxResponseBytes,
          maxResponseBytes,
        );
        if (response.contentLength > limit) {
          throw WatchmeError.protocol(
            'Response from $target announces ${response.contentLength} '
            'bytes, more than the $limit allowed',
          );
        }
        final bytes = await _readBody(response, target, limit);
        final headers = <String, String>{};
        response.headers.forEach(
          (name, values) => headers[name] = values.join(', '),
        );
        return HttpResult(
          response.statusCode,
          headers: headers,
          body: bytes,
          peerCertificateSha256: attempt.peerSha256,
        );
      }, onTimeout: () => attempt.expired(target, call.timeout));
    } on Object catch (e) {
      throw ioError(e, target, connected: attempt.connected);
    } finally {
      attempt.cancel();
      client.close(force: true);
    }
  }

  HttpClient _client(
    ConnectAttempt attempt,
    TlsPolicy? tls,
    ClientIdentity? identity,
  ) => HttpClient()
    ..userAgent = null
    ..autoUncompress = false
    ..findProxy = ((_) => 'DIRECT')
    ..connectionFactory = (uri, _, _) async {
      final socket = _connector.connect(
        uriHost(uri),
        uri.port,
        attempt: attempt,
        tls: tls,
        identity: identity,
      );
      // A refused destination fails at once, possibly before HttpClient
      // listens to the task. It still receives the error; this only stops
      // the error from also being reported as unhandled.
      socket.ignore();
      return ConnectionTask.fromSocket(socket, attempt.cancel);
    };

  static void _prepare(HttpClientRequest request, Map<String, String> headers) {
    request
      ..followRedirects = false
      ..headers.removeAll(HttpHeaders.acceptEncodingHeader);
    for (final MapEntry(:key, :value) in headers.entries) {
      if (key.toLowerCase() == 'content-length') continue;
      request.headers.set(key, value, preserveHeaderCase: true);
    }
  }

  static Future<Uint8List> _readBody(
    Stream<List<int>> body,
    String target,
    int limit,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
      if (builder.length > limit) {
        throw WatchmeError.protocol(
          'Response from $target exceeds $limit bytes',
        );
      }
    }
    return builder.takeBytes();
  }

  // ------------------------------------------------------------- WebSocket

  /// Opens a WebSocket.
  ///
  /// Besides the caller's [headers], only the handshake headers RFC 6455
  /// requires are sent; no compression extension is offered. A refused
  /// upgrade fails with [WatchmeErrorCode.unauthorized] (HTTP 401) or
  /// [WatchmeErrorCode.rejected] (any other status), carrying the response
  /// body (or `HTTP <status>`) as the raw device message.
  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    final secure = switch (uri.scheme) {
      'wss' => true,
      'ws' => false,
      _ => throw ArgumentError.value(uri, 'uri', 'not ws or wss'),
    };
    final target = '${uri.host}:${uri.port}';
    final attempt = ConnectAttempt();
    final client = _client(attempt, secure ? tls : null, identity);
    var upgraded = false;
    try {
      final (socket, protocol) = await runWithin(clock, timeout, () async {
        final request = await client.openUrl(
          'GET',
          uri.replace(scheme: secure ? 'https' : 'http'),
        );
        _prepare(request, headers);
        final key = base64.encode([
          for (var i = 0; i < 16; i++) _random.nextInt(256),
        ]);
        request.headers
          ..set(HttpHeaders.connectionHeader, 'Upgrade')
          ..set(HttpHeaders.upgradeHeader, 'websocket')
          ..set('Sec-WebSocket-Key', key)
          ..set('Sec-WebSocket-Version', '13');
        if (protocols.isNotEmpty) {
          request.headers.set('Sec-WebSocket-Protocol', protocols.join(', '));
        }
        final response = await request.close();
        await _checkUpgrade(response, key, protocols, target);
        final protocol = response.headers.value('sec-websocket-protocol');
        final socket = await response.detachSocket();
        upgraded = true;
        return (socket, protocol);
      }, onTimeout: () => attempt.expired(target, timeout));
      final webSocket = WebSocket.fromUpgradedSocket(
        socket,
        protocol: protocol,
        serverSide: false,
        compression: CompressionOptions.compressionOff,
      );
      return IoMessageSocket(
        webSocket,
        target: target,
        protocol: protocol,
        peerCertificateSha256: attempt.peerSha256,
      );
    } on Object catch (e) {
      attempt.cancel();
      throw ioError(e, target, connected: attempt.connected);
    } finally {
      client.close(force: !upgraded);
    }
  }

  // Mirrors the client handshake checks of dart:io's WebSocket.connect
  // (Dart SDK, BSD-3-Clause), so that headers stay under our control.
  Future<void> _checkUpgrade(
    HttpClientResponse response,
    String key,
    List<String> protocols,
    String target,
  ) async {
    if (response.statusCode != HttpStatus.switchingProtocols) {
      final body = await _readBody(response, target, maxResponseBytes).then(
        (b) => utf8.decode(b, allowMalformed: true),
        onError: (Object _) => '',
      );
      final raw = body.isEmpty ? 'HTTP ${response.statusCode}' : body;
      final message =
          'WebSocket upgrade to $target refused: HTTP ${response.statusCode}';
      throw response.statusCode == HttpStatus.unauthorized
          ? WatchmeError.unauthorized(message, rawDeviceMessage: raw)
          : WatchmeError.rejected(message, rawDeviceMessage: raw);
    }
    final connection = response.headers[HttpHeaders.connectionHeader] ?? [];
    final upgrade = response.headers.value(HttpHeaders.upgradeHeader);
    if (!connection.any((v) => v.toLowerCase().contains('upgrade')) ||
        upgrade?.toLowerCase() != 'websocket') {
      throw WatchmeError.protocol('$target did not upgrade to WebSocket');
    }
    final expected = base64.encode(
      sha1.convert(utf8.encode('$key$_webSocketGuid')).bytes,
    );
    if (response.headers.value('sec-websocket-accept') != expected) {
      throw WatchmeError.protocol(
        '$target sent a wrong Sec-WebSocket-Accept header',
      );
    }
    final protocol = response.headers.value('sec-websocket-protocol');
    if (protocol != null && !protocols.contains(protocol)) {
      throw WatchmeError.protocol(
        '$target chose subprotocol "$protocol", which was not offered',
      );
    }
  }

  static const String _webSocketGuid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  // ------------------------------------------------------------------- TCP

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    if (identity != null && tls == null) {
      throw ArgumentError.value(identity, 'identity', 'requires tls');
    }
    final target = '$host:$port';
    final attempt = ConnectAttempt();
    try {
      final socket = await runWithin(
        clock,
        timeout,
        () => _connector.connect(
          host,
          port,
          attempt: attempt,
          tls: tls,
          identity: identity,
        ),
        onTimeout: () {
          attempt.cancel();
          return attempt.expired(target, timeout);
        },
      );
      return IoByteSocket(
        socket,
        target: target,
        peerCertificateSha256: attempt.peerSha256,
        peerCertificateDer: attempt.peerDer,
      );
    } on Object catch (e) {
      attempt.cancel();
      throw ioError(e, target, connected: attempt.connected);
    }
  }

  // ------------------------------------------------------------------- UDP

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) async {
    if (broadcast && !multicastAllowed) {
      throw const WatchmeError.unsupported(
        'UDP broadcast is not permitted on this platform',
      );
    }
    if (host == '255.255.255.255' && !broadcast) {
      throw const WatchmeError.protocol(
        'Sending to 255.255.255.255 needs broadcast: true',
      );
    }
    final target = '$host:$port';
    RawDatagramSocket? socket;
    try {
      // The policy governs unicast; the limited broadcast is allowed here,
      // and a subnet-directed broadcast is in a private range anyway.
      final address = (await _destinations.resolve(
        host,
        exempt: broadcast ? const {HostAddressClass.broadcast} : const {},
      )).first;
      socket = await RawDatagramSocket.bind(
        address.type == InternetAddressType.IPv6
            ? InternetAddress.anyIPv6
            : InternetAddress.anyIPv4,
        0,
      );
      socket.broadcastEnabled = broadcast;
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      // send() returns 0 when the socket buffer is momentarily full.
      for (var attempt = 0; ; attempt++) {
        if (socket.send(data, address, port) == data.length) break;
        if (attempt == 20) {
          throw WatchmeError.unreachable(
            'Could not send a datagram to $target',
          );
        }
        await clock.delay(const Duration(milliseconds: 5));
      }
    } on Object catch (e) {
      throw ioError(e, target, connected: false);
    } finally {
      socket?.close();
    }
  }

  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) {
    late final StreamController<Datagram> controller;
    RawDatagramSocket? socket;
    Timer? timer;
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      timer?.cancel();
      socket?.close();
      controller.close();
    }

    Future<void> start() async {
      if (!multicastAllowed) {
        throw const WatchmeError.unsupported(
          'Multicast is not permitted on this platform',
        );
      }
      // A multicast group is not a unicast destination; anything else
      // (a unicast "group", as tests use) is one and must pass the policy.
      final address = (await _destinations.resolve(
        group,
        exempt: const {HostAddressClass.multicast},
      )).first;
      final v6 = address.type == InternetAddressType.IPv6;
      final s = socket = await RawDatagramSocket.bind(
        v6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4,
        0,
      );
      if (finished) {
        s.close();
        return;
      }
      s
        ..multicastHops = multicastHops
        ..multicastLoopback = true;
      s.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          for (var d = s.receive(); d != null; d = s.receive()) {
            if (!finished) {
              controller.add(Datagram(d.address.address, d.port, d.data));
            }
          }
        },
        onError: (Object e) {
          if (!finished) {
            controller.addError(ioError(e, '$group:$port', connected: false));
          }
        },
        onDone: finish,
      );
      timer = clock.timer(window, finish);
      final payload = query is Uint8List ? query : Uint8List.fromList(query);
      final interfaces = v6 ? null : multicastInterfaces;
      if (interfaces == null || interfaces.isEmpty) {
        _sendOnce(s, payload, address, port);
      } else {
        // One interface that went away must not stop the others.
        Object? lastError;
        var sent = 0;
        for (final local in interfaces) {
          try {
            s.setRawOption(
              RawSocketOption(
                RawSocketOption.levelIPv4,
                RawSocketOption.IPv4MulticastInterface,
                Uint8List.fromList(local.rawAddress),
              ),
            );
            _sendOnce(s, payload, address, port);
            sent++;
          } on Object catch (e) {
            lastError = e;
          }
        }
        if (sent == 0) throw lastError!;
      }
    }

    controller = StreamController<Datagram>(
      onListen: () => start().catchError((Object e) {
        if (!finished) {
          controller.addError(ioError(e, '$group:$port', connected: false));
        }
        finish();
      }),
      onCancel: finish,
    );
    return controller.stream;
  }

  static void _sendOnce(
    RawDatagramSocket socket,
    Uint8List payload,
    InternetAddress address,
    int port,
  ) {
    if (socket.send(payload, address, port) != payload.length) {
      throw WatchmeError.unreachable(
        'Could not send a multicast query to ${address.address}:$port',
      );
    }
  }

  /// The private (RFC 1918) and link-local IPv4 addresses of this host's
  /// interfaces: a sensible [multicastInterfaces] value for a hub with
  /// several LAN interfaces. Shared-range (100.64.0.0/10, carrier-grade NAT
  /// and VPN overlays), public and loopback addresses are left out so
  /// queries are not sent beyond the LAN.
  static Future<List<InternetAddress>> privateIPv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    );
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          if (isPrivateLanAddress(address)) address,
    ];
  }
}

/// Whether [policy] allows a unicast connection to [address]. With the
/// default `DestinationPolicy.lanOnly` that means a private (RFC 1918),
/// link-local (IPv4 or IPv6) or unique-local IPv6 address, or an IPv4-mapped
/// form of one; loopback, the shared range 100.64.0.0/10, public, reserved,
/// multicast and broadcast addresses are not.
///
/// A thin wrapper over `DestinationPolicy.allows`, so the stack, discovery
/// and the engine can never disagree about what the LAN is.
bool isLanAddress(
  InternetAddress address, {
  DestinationPolicy policy = DestinationPolicy.lanOnly,
}) => policy.allows(address.address);

/// Whether [address] is private (RFC 1918), link-local or unique-local:
/// what `DestinationPolicy.lanOnly` allows, whatever policy a stack uses.
/// Loopback and the shared range 100.64.0.0/10 are excluded.
bool isPrivateLanAddress(InternetAddress address) =>
    DestinationPolicy.lanOnly.allows(address.address);
