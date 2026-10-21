import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart';

import 'fingerprints.dart';

/// Handles one fake HTTP request. Return a response, or throw a
/// [WatchmeError] to simulate a transport failure.
typedef FakeHttpHandler = FutureOr<HttpResult> Function(HttpCall call);

/// What [FakeNetworkStack.http] does with a request no route matches.
enum UnmatchedHttp {
  /// Throw [WatchmeErrorCode.unreachable], as if nothing listened.
  unreachable,

  /// Answer `404 Not Found`.
  notFound,
}

/// A registered HTTP route. Later registrations take precedence, so a test
/// can override a default route.
final class FakeHttpRoute {
  FakeHttpRoute._(this._test, this._handler, this.times, this.description);

  final bool Function(HttpCall call) _test;
  final FakeHttpHandler _handler;

  /// How many requests the route may answer; `null` is unlimited.
  final int? times;

  /// For diagnostics.
  final String description;

  /// How many requests the route has answered.
  int get hits => _hits;
  int _hits = 0;

  /// Whether the route has answered [times] requests.
  bool get exhausted => times != null && _hits >= times!;

  bool _accepts(HttpCall call) => !exhausted && _test(call);

  @override
  String toString() => 'FakeHttpRoute($description, hits: $hits)';
}

/// One request seen by [FakeNetworkStack.http], with its outcome.
final class RecordedHttpCall {
  RecordedHttpCall._(this.call, this.tls, this.identity);

  /// The request.
  final HttpCall call;

  /// The TLS policy the caller passed.
  final TlsPolicy tls;

  /// The client identity the caller passed.
  final ClientIdentity? identity;

  /// The response, when the call succeeded.
  HttpResult? get result => _result;
  HttpResult? _result;

  /// The thrown error, when the call failed.
  Object? get error => _error;
  Object? _error;

  /// Whether no route matched.
  bool get unmatched => _unmatched;
  bool _unmatched = false;

  @override
  String toString() => 'RecordedHttpCall(${call.method} ${call.uri})';
}

/// A UDP datagram sent through [FakeNetworkStack.sendDatagram].
final class SentDatagram {
  SentDatagram._(this.host, this.port, List<int> bytes, this.broadcast)
    : bytes = Uint8List.fromList(bytes);

  /// Destination address.
  final String host;

  /// Destination port.
  final int port;

  /// Payload.
  final Uint8List bytes;

  /// Whether broadcast was enabled.
  final bool broadcast;

  @override
  String toString() => 'SentDatagram($host:$port, ${bytes.length} bytes)';
}

/// One [FakeNetworkStack.multicastQuery] call.
final class RecordedMulticastQuery {
  RecordedMulticastQuery._(this.group, this.port, List<int> query, this.window)
    : query = Uint8List.fromList(query);

  /// Multicast group.
  final String group;

  /// Port.
  final int port;

  /// Query payload.
  final Uint8List query;

  /// Requested listening window.
  final Duration window;

  /// The query decoded as UTF-8.
  String get text => utf8.decode(query, allowMalformed: true);
}

/// Answers a multicast query with datagrams (e.g. SSDP M-SEARCH responses).
typedef FakeMulticastResponder = FutureOr<Iterable<Datagram>> Function(
  Uint8List query,
);

/// A scripted [NetworkStack] for driver, discovery and engine tests. Pure
/// Dart: no sockets are opened.
///
/// ```dart
/// final net = FakeNetworkStack();
/// net.onHttp('GET', '/query/device-info',
///     (call) => HttpResult.text(200, deviceInfoXml), port: 8060);
/// net.onHttp('POST', RegExp(r'^/keypress/'), (_) => HttpResult(200));
/// net.serveTls('10.0.0.5', 8080, certificateSha256: fakeFingerprint('tv'));
/// net.onWebSocket('10.0.0.5', 3000, (peer) {
///   peer.received.listen((msg) => peer.send('{"type":"registered"}'));
/// });
/// net.onMulticast('239.255.255.250', 1900, (query) => [
///   Datagram('10.0.0.5', 1900, utf8.encode(ssdpResponse)),
/// ]);
/// // ... exercise the driver ...
/// expect(net.callsTo('POST', '/keypress/Home'), hasLength(1));
/// expect(net.sentDatagrams.single.bytes, magicPacket(mac));
/// ```
///
/// Behaviour mirrors the real stack's contract (`NetworkStack` docs):
/// * Requests to a host or port marked with [setUnreachable], and requests
///   no route answers (by default, see [unmatchedHttp]), throw
///   [WatchmeErrorCode.unreachable].
/// * A handler slower than [HttpCall.timeout] yields
///   [WatchmeErrorCode.timeout].
/// * A body larger than [HttpCall.maxResponseBytes] yields
///   [WatchmeErrorCode.protocol].
/// * `https`, `wss` and TLS TCP connections are checked against the
///   caller's [TlsPolicy] using the certificate registered with [serveTls]
///   (or a platform-trusted certificate whose fingerprint is
///   `fakeFingerprint('host:port')`); a rejection throws
///   [WatchmeErrorCode.protocol]. Results carry `peerCertificateSha256`.
/// * Operations whose [TransportFeature] is missing from [features] throw
///   [WatchmeErrorCode.unsupported].
class FakeNetworkStack implements NetworkStack {
  /// Creates a fake stack offering [features] (default: every network
  /// feature, like `dart:io`).
  FakeNetworkStack({
    Set<TransportFeature>? features,
    this.unmatchedHttp = UnmatchedHttp.unreachable,
  }) : features = {...(features ?? TransportFeature.allNetwork)};

  /// Features this stack offers. Mutable, so a test can take one away.
  final Set<TransportFeature> features;

  /// What to do with unmatched HTTP requests.
  UnmatchedHttp unmatchedHttp;

  final List<FakeHttpRoute> _routes = [];
  final List<RecordedHttpCall> _httpLog = [];
  final Set<String> _unreachable = {};
  final Map<String, _TlsServer> _tls = {};
  final Map<String, void Function(FakeWebSocketPeer)> _wsHandlers = {};
  final List<FakeWebSocketPeer> _wsPeers = [];
  final Map<String, void Function(FakeTcpPeer)> _tcpHandlers = {};
  final List<FakeTcpPeer> _tcpPeers = [];
  final List<SentDatagram> _datagrams = [];
  final Map<String, List<FakeMulticastResponder>> _multicast = {};
  final List<RecordedMulticastQuery> _multicastQueries = [];

  // ---------------------------------------------------------------- HTTP

  /// Answers requests whose method equals [method] (`*` for any) and whose
  /// URI path matches [path] (a [String] for equality, a [RegExp] for
  /// `hasMatch`), optionally only on [host] and [port] (the URI's effective
  /// port). With [times], the route answers that many requests only.
  FakeHttpRoute onHttp(
    String method,
    Pattern path,
    FakeHttpHandler handler, {
    String? host,
    int? port,
    int? times,
  }) {
    final m = method.toUpperCase();
    bool test(HttpCall call) =>
        (m == '*' || call.method == m) &&
        (host == null || call.uri.host == host) &&
        (port == null || call.uri.port == port) &&
        switch (path) {
          final String p => call.uri.path == p,
          final RegExp r => r.hasMatch(call.uri.path),
          _ => path.allMatches(call.uri.path).isNotEmpty,
        };
    final where = [?host, ?port?.toString()].join(':');
    return _addRoute(
      FakeHttpRoute._(
        test,
        handler,
        times,
        '$m $path${where.isEmpty ? '' : ' @$where'}',
      ),
    );
  }

  /// Answers requests for which [predicate] is true.
  FakeHttpRoute onHttpWhere(
    bool Function(HttpCall call) predicate,
    FakeHttpHandler handler, {
    int? times,
    String description = 'predicate',
  }) => _addRoute(FakeHttpRoute._(predicate, handler, times, description));

  /// Answers [method] [path] with a fixed [result] (see [onHttp]).
  FakeHttpRoute respond(
    String method,
    Pattern path,
    HttpResult result, {
    String? host,
    int? port,
    int? times,
  }) =>
      onHttp(method, path, (_) => result, host: host, port: port, times: times);

  /// Removes [route].
  void removeRoute(FakeHttpRoute route) => _routes.remove(route);

  FakeHttpRoute _addRoute(FakeHttpRoute route) {
    _routes.insert(0, route);
    return route;
  }

  /// Every HTTP request so far, in order, with outcomes.
  List<RecordedHttpCall> get httpLog => List.unmodifiable(_httpLog);

  /// Every HTTP request so far, in order.
  List<HttpCall> get httpCalls => [for (final r in _httpLog) r.call];

  /// Requests with [method] (`*` for any) whose path matches [path].
  List<HttpCall> callsTo(String method, Pattern path) {
    final m = method.toUpperCase();
    return [
      for (final call in httpCalls)
        if ((m == '*' || call.method == m) &&
            switch (path) {
              final String p => call.uri.path == p,
              _ => path.allMatches(call.uri.path).isNotEmpty,
            })
          call,
    ];
  }

  /// Requests no route matched.
  List<HttpCall> get unmatchedCalls => [
    for (final r in _httpLog)
      if (r.unmatched) r.call,
  ];

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) async {
    final record = RecordedHttpCall._(call, tls, identity);
    _httpLog.add(record);
    try {
      _require(TransportFeature.httpReadCrossOrigin, 'reading HTTP responses');
      if (call.headers.isNotEmpty) {
        _require(TransportFeature.customHeaders, 'custom headers');
      }
      if (!const {'GET', 'POST', 'HEAD'}.contains(call.method)) {
        _require(TransportFeature.nonSimpleMethods, 'HTTP ${call.method}');
      }
      final host = call.uri.host;
      final port = call.uri.port;
      _checkReachable(host, port);
      final secure = call.uri.scheme == 'https';
      final peerSha = secure ? _handshake(host, port, tls, identity) : null;
      final route = _routes.where((r) => r._accepts(call)).firstOrNull;
      if (route == null) {
        record._unmatched = true;
        if (unmatchedHttp == UnmatchedHttp.notFound) {
          return record._result = HttpResult(
            404,
            peerCertificateSha256: peerSha,
          );
        }
        throw WatchmeError.unreachable(
          'No fake HTTP route for ${call.method} ${call.uri}',
        );
      }
      route._hits++;
      final result = await Future.sync(() => route._handler(call)).timeout(
        call.timeout,
        onTimeout: () => throw WatchmeError.timeout(
          'No answer from ${call.uri} within ${call.timeout}',
        ),
      );
      final limit = call.maxResponseBytes;
      if (limit != null && result.body.length > limit) {
        throw WatchmeError.protocol(
          'Response from ${call.uri} exceeds $limit bytes',
        );
      }
      return record._result = peerSha == null
          ? result
          : HttpResult(
              result.status,
              headers: result.headers,
              body: result.body,
              peerCertificateSha256: peerSha,
            );
    } catch (e) {
      record._error = e;
      rethrow;
    }
  }

  // ---------------------------------------------------------- reachability

  /// Makes every connection to [host] (or only to [port] on it) fail with
  /// [WatchmeErrorCode.unreachable], e.g. Fire TV's port 8080 while asleep.
  void setUnreachable(String host, {int? port}) =>
      _unreachable.add(_key(host, port));

  /// Undoes [setUnreachable] for the same [host] and [port].
  void setReachable(String host, {int? port}) =>
      _unreachable.remove(_key(host, port));

  void _checkReachable(String host, int port) {
    if (_unreachable.contains(_key(host, null)) ||
        _unreachable.contains(_key(host, port))) {
      throw WatchmeError.unreachable('Connection refused: $host:$port');
    }
  }

  // ------------------------------------------------------------------- TLS

  /// Declares the certificate served on [host]:[port] for `https`, `wss`
  /// and TLS TCP. [platformTrusted] says whether it chains to a trusted
  /// root (self-signed TV certificates do not).
  void serveTls(
    String host,
    int port, {
    required String certificateSha256,
    bool platformTrusted = false,
    List<int>? certificateDer,
  }) {
    _tls[_key(host, port)] = _TlsServer(
      normalizeFingerprint(certificateSha256),
      platformTrusted,
      certificateDer == null ? null : Uint8List.fromList(certificateDer),
    );
  }

  _TlsServer _tlsServer(String host, int port) =>
      _tls[_key(host, port)] ??
      _TlsServer(fakeFingerprint('$host:$port'), true, null);

  String _handshake(
    String host,
    int port,
    TlsPolicy tls,
    ClientIdentity? identity,
  ) {
    if (tls.allowSelfSigned || tls.trustOnFirstUse || tls.pins.isNotEmpty) {
      _require(TransportFeature.tlsAcceptSelfSigned, 'custom TLS trust');
    }
    if (identity != null) {
      _require(TransportFeature.tlsClientCertificate, 'client certificates');
    }
    final server = _tlsServer(host, port);
    if (!tls.allows(
      peerSha256: server.sha256,
      platformTrusted: server.platformTrusted,
    )) {
      throw WatchmeError.protocol(
        tls.pins.isEmpty
            ? 'TLS: certificate of $host:$port is not trusted'
            : 'TLS: certificate of $host:$port does not match the pin',
      );
    }
    return server.sha256;
  }

  // ------------------------------------------------------------- WebSocket

  /// Accepts WebSocket connections to [host]:[port] (any path unless [path]
  /// is given) and hands the server side to [onConnect], which runs before
  /// `webSocket()` returns so it can subscribe to
  /// [FakeWebSocketPeer.received] in time.
  void onWebSocket(
    String host,
    int port,
    void Function(FakeWebSocketPeer peer) onConnect, {
    String? path,
  }) => _wsHandlers[_key(host, port, path)] = onConnect;

  /// Every WebSocket connection so far, server side.
  List<FakeWebSocketPeer> get webSocketPeers => List.unmodifiable(_wsPeers);

  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    _require(TransportFeature.webSocket, 'WebSockets');
    if (headers.isNotEmpty) {
      _require(TransportFeature.webSocketHeaders, 'WebSocket headers');
    }
    _checkReachable(uri.host, uri.port);
    final peerSha = uri.scheme == 'wss'
        ? _handshake(uri.host, uri.port, tls, identity)
        : null;
    final handler =
        _wsHandlers[_key(uri.host, uri.port, uri.path)] ??
        _wsHandlers[_key(uri.host, uri.port)];
    if (handler == null) {
      throw WatchmeError.unreachable('No fake WebSocket server at $uri');
    }
    final peer = FakeWebSocketPeer._(uri, headers, protocols, tls, peerSha);
    _wsPeers.add(peer);
    handler(peer);
    return peer._client;
  }

  // ------------------------------------------------------------------- TCP

  /// Accepts TCP connections to [host]:[port] and hands the server side to
  /// [onConnect] (which runs before `tcp()` returns).
  void onTcp(
    String host,
    int port,
    void Function(FakeTcpPeer peer) onConnect,
  ) => _tcpHandlers[_key(host, port)] = onConnect;

  /// Every TCP connection so far, server side.
  List<FakeTcpPeer> get tcpPeers => List.unmodifiable(_tcpPeers);

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    _require(TransportFeature.rawTcp, 'raw TCP');
    _checkReachable(host, port);
    String? peerSha;
    Uint8List? peerDer;
    if (tls != null) {
      peerSha = _handshake(host, port, tls, identity);
      peerDer = _tlsServer(host, port).der;
    }
    final handler = _tcpHandlers[_key(host, port)];
    if (handler == null) {
      throw WatchmeError.unreachable('Connection refused: $host:$port');
    }
    final peer = FakeTcpPeer._(host, port, tls, identity, peerSha, peerDer);
    _tcpPeers.add(peer);
    handler(peer);
    return peer._client;
  }

  // ------------------------------------------------------------------- UDP

  /// Every datagram sent so far.
  List<SentDatagram> get sentDatagrams => List.unmodifiable(_datagrams);

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) async {
    _require(
      broadcast ? TransportFeature.udpBroadcast : TransportFeature.udpUnicast,
      broadcast ? 'UDP broadcast' : 'UDP',
    );
    if (host == '255.255.255.255' && !broadcast) {
      throw const WatchmeError.protocol(
        'Sending to 255.255.255.255 needs broadcast: true',
      );
    }
    _datagrams.add(SentDatagram._(host, port, bytes, broadcast));
  }

  /// Answers multicast queries to [group]:[port]. Several responders may be
  /// registered; their datagrams are concatenated.
  void onMulticast(String group, int port, FakeMulticastResponder responder) =>
      (_multicast[_key(group, port)] ??= []).add(responder);

  /// Every multicast query so far.
  List<RecordedMulticastQuery> get multicastQueries =>
      List.unmodifiable(_multicastQueries);

  /// Yields the responders' datagrams and closes as soon as they are
  /// delivered, without waiting for [window] (tests stay fast).
  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) async* {
    _require(TransportFeature.multicast, 'multicast');
    final record = RecordedMulticastQuery._(group, port, query, window);
    _multicastQueries.add(record);
    for (final responder in [...?_multicast[_key(group, port)]]) {
      yield* Stream.fromIterable(await responder(record.query));
    }
  }

  // --------------------------------------------------------------- helpers

  void _require(TransportFeature feature, String what) {
    if (!features.contains(feature)) {
      throw WatchmeError.unsupported('Transport lacks ${feature.name} ($what)');
    }
  }

  static String _key(String host, int? port, [String? path]) =>
      '${host.toLowerCase()}|${port ?? '*'}|${path ?? '*'}';
}

final class _TlsServer {
  const _TlsServer(this.sha256, this.platformTrusted, this.der);

  final String sha256;
  final bool platformTrusted;
  final Uint8List? der;
}

Object _normaliseMessage(Object message) => switch (message) {
  String() => message,
  Uint8List() => message,
  List<int>() => Uint8List.fromList(message),
  _ => throw ArgumentError.value(message, 'message', 'String or List<int>'),
};

/// The server side of a fake WebSocket connection.
final class FakeWebSocketPeer {
  FakeWebSocketPeer._(
    this.uri,
    this.headers,
    this.protocols,
    this.tls,
    String? peerSha,
  ) {
    _client = _FakeMessageSocket(this, peerSha);
  }

  /// The URI the client connected to.
  final Uri uri;

  /// Handshake headers the client sent.
  final Map<String, String> headers;

  /// Subprotocols the client offered.
  final List<String> protocols;

  /// The client's TLS policy.
  final TlsPolicy tls;

  late final _FakeMessageSocket _client;
  final StreamController<Object> _received = StreamController.broadcast(
    sync: true,
  );
  final List<Object> _receivedLog = [];

  /// Messages from the client: [String] or [Uint8List]. Broadcast.
  Stream<Object> get received => _received.stream;

  /// Every message the client sent, in order.
  List<Object> get receivedLog => List.unmodifiable(_receivedLog);

  /// Whether either side closed.
  bool get isClosed => _client._closed;

  /// The client's close code, if the client closed.
  int? get clientCloseCode =>
      _client._closedByClient ? _client.closeCode : null;

  /// Sends [message] ([String] or `List<int>`) to the client.
  void send(Object message) {
    if (isClosed) throw StateError('WebSocket is closed');
    _client._incoming.add(_normaliseMessage(message));
  }

  /// Delivers [error] on the client's message stream.
  void addError(WatchmeError error) => _client._incoming.addError(error);

  /// Closes the connection from the server side.
  Future<void> close([int? code, String? reason]) =>
      _client._shutdown(code, reason, byClient: false);
}

final class _FakeMessageSocket implements MessageSocket {
  _FakeMessageSocket(this._peer, this.peerCertificateSha256);

  final FakeWebSocketPeer _peer;
  final StreamController<Object> _incoming = StreamController();
  final Completer<void> _done = Completer();
  bool _closed = false;
  bool _closedByClient = false;

  @override
  final String? peerCertificateSha256;

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  String? get protocol => _peer.protocols.firstOrNull;

  @override
  Stream<Object> get messages => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(Object message) {
    if (_closed) throw StateError('WebSocket is closed');
    final m = _normaliseMessage(message);
    _peer._receivedLog.add(m);
    _peer._received.add(m);
  }

  @override
  Future<void> close([int? code, String? reason]) =>
      _shutdown(code, reason, byClient: true);

  Future<void> _shutdown(
    int? code,
    String? reason, {
    required bool byClient,
  }) async {
    if (_closed) return;
    _closed = true;
    _closedByClient = byClient;
    closeCode = code;
    closeReason = reason;
    unawaited(_incoming.close());
    unawaited(_peer._received.close());
    _done.complete();
  }
}

/// The server side of a fake TCP connection.
final class FakeTcpPeer {
  FakeTcpPeer._(
    this.host,
    this.port,
    this.tls,
    this.identity,
    String? peerSha,
    Uint8List? peerDer,
  ) {
    _client = _FakeByteSocket(this, peerSha, peerDer);
  }

  /// Host the client connected to.
  final String host;

  /// Port the client connected to.
  final int port;

  /// The client's TLS policy, or `null` for plain TCP.
  final TlsPolicy? tls;

  /// The client's identity, if any.
  final ClientIdentity? identity;

  late final _FakeByteSocket _client;
  final StreamController<Uint8List> _received = StreamController.broadcast(
    sync: true,
  );
  final BytesBuilder _receivedBytes = BytesBuilder();

  /// Byte chunks from the client. Broadcast.
  Stream<Uint8List> get received => _received.stream;

  /// Every byte the client sent, concatenated.
  Uint8List get receivedBytes => _receivedBytes.toBytes();

  /// Whether either side closed.
  bool get isClosed => _client._closed;

  /// Sends [bytes] to the client.
  void send(List<int> bytes) {
    if (isClosed) throw StateError('Socket is closed');
    _client._incoming.add(Uint8List.fromList(bytes));
  }

  /// Delivers [error] on the client's input stream.
  void addError(WatchmeError error) => _client._incoming.addError(error);

  /// Closes the connection from the server side.
  Future<void> close() => _client.close();
}

final class _FakeByteSocket implements ByteSocket {
  _FakeByteSocket(
    this._peer,
    this.peerCertificateSha256,
    this.peerCertificateDer,
  );

  final FakeTcpPeer _peer;
  final StreamController<Uint8List> _incoming = StreamController();
  final Completer<void> _done = Completer();
  bool _closed = false;

  @override
  final String? peerCertificateSha256;

  @override
  final Uint8List? peerCertificateDer;

  @override
  Stream<Uint8List> get input => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  void send(List<int> bytes) {
    if (_closed) throw StateError('Socket is closed');
    final chunk = Uint8List.fromList(bytes);
    _peer._receivedBytes.add(chunk);
    _peer._received.add(chunk);
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    unawaited(_incoming.close());
    unawaited(_peer._received.close());
    _done.complete();
  }
}
