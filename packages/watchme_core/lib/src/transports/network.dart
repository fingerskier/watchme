import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../errors.dart';
import '../util/equality.dart';
import 'destination.dart';
import 'tls.dart';

/// IP networking as seen by drivers and discovery providers.
///
/// Implementations: `IoNetworkStack` (dart:io, in watchme_io), the fake in
/// watchme_testkit, and later a browser stack.
///
/// Error contract: transport-level failures throw [WatchmeError] with
/// [WatchmeErrorCode.unreachable] (refused, no route, DNS: nothing was
/// delivered, so a caller may safely retry or fall back),
/// [WatchmeErrorCode.destinationRefused] (the host, or an address it
/// resolved to, is outside the stack's `DestinationPolicy`: nothing was
/// sent), [WatchmeErrorCode.timeout] (connected but no answer in time, or
/// the connection was lost after it was made: the request may have been
/// delivered), or [WatchmeErrorCode.protocol] (TLS failure, including a pin
/// mismatch, or a malformed or oversized answer).
/// HTTP error statuses are *not* exceptions: [http] returns them as an
/// [HttpResult] and the driver decides what they mean.
///
/// These codes describe one call. A driver that makes several calls for one
/// command reports [WatchmeErrorCode.partiallyDelivered] once any of them
/// was delivered.
///
/// LAN-only: a native stack checks every unicast destination ([http],
/// [webSocket], [tcp], and [sendDatagram] without `broadcast`) against its
/// [DestinationPolicy], resolving host names itself and connecting to the
/// checked address. Multicast queries and broadcast datagrams on LAN
/// interfaces are allowed.
abstract interface class NetworkStack {
  /// Performs one HTTP(S) request.
  ///
  /// [tls] applies to `https` URIs; [identity] presents a client certificate.
  /// The stack sends exactly [HttpCall.headers] plus what HTTP requires
  /// (`Host` from the URI, `Content-Length`); it adds no `Origin` or cookies.
  /// Redirects are not followed.
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  });

  /// Opens a WebSocket (`ws` or `wss`).
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  });

  /// Opens a TCP connection, wrapped in TLS when [tls] is non-null.
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  });

  /// Sends one UDP datagram. With [broadcast] the socket is allowed to send
  /// to a broadcast address (Wake-on-LAN to 255.255.255.255).
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  });

  /// Sends [query] to the multicast [group]:[port] from an ephemeral socket
  /// and yields every datagram received on that socket until [window]
  /// elapses, then closes the stream. Used for SSDP M-SEARCH.
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  );
}

/// One HTTP request.
///
/// [toString] prints only the method and URI, never headers or body, because
/// they often carry tokens.
@immutable
final class HttpCall {
  /// Creates a request. [method] is upper-cased.
  HttpCall(
    String method,
    this.uri, {
    this.headers = const {},
    List<int>? body,
    this.timeout = defaultTimeout,
    this.maxResponseBytes,
  }) : method = method.toUpperCase(),
       body = body == null ? null : Uint8List.fromList(body);

  /// A `GET` request.
  HttpCall.get(
    Uri uri, {
    Map<String, String> headers = const {},
    Duration timeout = defaultTimeout,
    int? maxResponseBytes,
  }) : this(
         'GET',
         uri,
         headers: headers,
         timeout: timeout,
         maxResponseBytes: maxResponseBytes,
       );

  /// A `POST` request, with an optional raw body.
  HttpCall.post(
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    Duration timeout = defaultTimeout,
  }) : this('POST', uri, headers: headers, body: body, timeout: timeout);

  /// A request with a JSON body and `Content-Type: application/json;
  /// charset=utf-8` (unless [headers] sets one).
  HttpCall.json(
    String method,
    Uri uri,
    Object? json, {
    Map<String, String> headers = const {},
    Duration timeout = defaultTimeout,
  }) : this(
         method,
         uri,
         headers: _withContentType(headers, 'application/json; charset=utf-8'),
         body: utf8.encode(jsonEncode(json)),
         timeout: timeout,
       );

  /// A request with a text body and the given [contentType] (unless
  /// [headers] sets one).
  HttpCall.text(
    String method,
    Uri uri,
    String text, {
    String contentType = 'text/plain; charset=utf-8',
    Map<String, String> headers = const {},
    Duration timeout = defaultTimeout,
  }) : this(
         method,
         uri,
         headers: _withContentType(headers, contentType),
         body: utf8.encode(text),
         timeout: timeout,
       );

  /// Default timeout for requests and connection attempts.
  static const Duration defaultTimeout = Duration(seconds: 10);

  /// Upper-case HTTP method.
  final String method;

  /// Target URI. Drivers build it from an `Endpoint` so the host is an IP
  /// literal where the protocol requires one (Roku ECP).
  final Uri uri;

  /// Request headers, sent as given.
  final Map<String, String> headers;

  /// Request body, or `null` for none.
  final Uint8List? body;

  /// Overall deadline for connect, send and receive.
  final Duration timeout;

  /// The largest response body the caller accepts, or `null` for the
  /// stack's own limit. A larger body fails with [WatchmeErrorCode.protocol]
  /// as soon as the stack sees it is too large, before it is buffered
  /// (used for bodies whose sender is untrusted, such as UPnP descriptions
  /// fetched from a discovery reply).
  final int? maxResponseBytes;

  /// The body decoded as UTF-8, or `null` when there is none.
  String? get bodyText =>
      body == null ? null : utf8.decode(body!, allowMalformed: true);

  /// The header [name], matched case-insensitively.
  String? header(String name) => _lookup(headers, name);

  @override
  bool operator ==(Object other) =>
      other is HttpCall &&
      other.method == method &&
      other.uri == uri &&
      mapEquals(other.headers, headers) &&
      listEquals(other.body, body) &&
      other.timeout == timeout &&
      other.maxResponseBytes == maxResponseBytes;

  @override
  int get hashCode => Object.hash(
    method,
    uri,
    mapHash(headers),
    listHash(body),
    timeout,
    maxResponseBytes,
  );

  @override
  String toString() => 'HttpCall($method $uri)';
}

/// An HTTP response. Any status is a result; only transport failures throw.
@immutable
final class HttpResult {
  /// Creates a response. Header names are lower-cased; repeated headers are
  /// joined with `, `.
  HttpResult(
    this.status, {
    Map<String, String> headers = const {},
    List<int> body = const [],
    this.peerCertificateSha256,
  }) : headers = {
         for (final MapEntry(:key, :value) in headers.entries)
           key.toLowerCase(): value,
       },
       body = Uint8List.fromList(body);

  /// A response with a text body.
  HttpResult.text(
    int status,
    String text, {
    String contentType = 'text/plain; charset=utf-8',
    Map<String, String> headers = const {},
    String? peerCertificateSha256,
  }) : this(
         status,
         headers: _withContentType(headers, contentType),
         body: utf8.encode(text),
         peerCertificateSha256: peerCertificateSha256,
       );

  /// A response with a JSON body.
  HttpResult.json(
    int status,
    Object? json, {
    Map<String, String> headers = const {},
    String? peerCertificateSha256,
  }) : this.text(
         status,
         jsonEncode(json),
         contentType: 'application/json; charset=utf-8',
         headers: headers,
         peerCertificateSha256: peerCertificateSha256,
       );

  /// HTTP status code.
  final int status;

  /// Response headers with lower-case names.
  final Map<String, String> headers;

  /// Raw body bytes.
  final Uint8List body;

  /// SHA-256 of the peer's leaf certificate (lower-case hex) for HTTPS
  /// responses; `null` for plain HTTP. Drivers record it for
  /// trust-on-first-use pinning.
  final String? peerCertificateSha256;

  /// Whether [status] is 2xx.
  bool get ok => status >= 200 && status < 300;

  /// The body decoded as UTF-8 (malformed bytes are replaced).
  String get text => utf8.decode(body, allowMalformed: true);

  /// The header [name], matched case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// The body parsed as JSON.
  ///
  /// Throws [WatchmeError] ([WatchmeErrorCode.protocol]) with the body as
  /// raw device message when it is not JSON.
  Object? json() {
    try {
      return jsonDecode(text);
    } on FormatException catch (e) {
      throw WatchmeError.protocol(
        'Expected a JSON body (HTTP $status)',
        rawDeviceMessage: text,
        cause: e,
      );
    }
  }

  /// The body parsed as a JSON object; throws like [json] otherwise.
  Map<String, Object?> jsonObject() => switch (json()) {
    final Map<Object?, Object?> m => m.cast<String, Object?>(),
    _ => throw WatchmeError.protocol(
      'Expected a JSON object (HTTP $status)',
      rawDeviceMessage: text,
    ),
  };

  /// A [WatchmeError] with [code] and [message] carrying this response's
  /// body (or `HTTP <status>` when empty) as the raw device message.
  WatchmeError toError(WatchmeErrorCode code, String message) => WatchmeError(
    code,
    message,
    rawDeviceMessage: body.isEmpty ? 'HTTP $status' : text,
  );

  @override
  bool operator ==(Object other) =>
      other is HttpResult &&
      other.status == status &&
      mapEquals(other.headers, headers) &&
      listEquals(other.body, body) &&
      other.peerCertificateSha256 == peerCertificateSha256;

  @override
  int get hashCode => Object.hash(
    status,
    mapHash(headers),
    listHash(body),
    peerCertificateSha256,
  );

  @override
  String toString() => 'HttpResult($status, ${body.length} bytes)';
}

/// A message-oriented socket (WebSocket).
///
/// Transport errors after connection are delivered on [messages] as
/// [WatchmeError]s.
abstract interface class MessageSocket {
  /// Incoming messages: a [String] per text frame, a [Uint8List] per binary
  /// frame. Single-subscription; closes when the socket closes.
  Stream<Object> get messages;

  /// Sends a text frame ([String]) or a binary frame (`List<int>`). Throws
  /// [ArgumentError] for anything else.
  void send(Object message);

  /// Closes the socket with an optional close [code] and [reason].
  Future<void> close([int? code, String? reason]);

  /// Completes when the socket is closed by either side.
  Future<void> get done;

  /// The close code received or sent, once closed.
  int? get closeCode;

  /// The close reason received or sent, once closed.
  String? get closeReason;

  /// The negotiated subprotocol, if any.
  String? get protocol;

  /// SHA-256 of the peer's leaf certificate for `wss`, else `null`.
  String? get peerCertificateSha256;
}

/// A byte-stream socket: TCP, TLS over TCP, or a serial port.
///
/// Transport errors after connection are delivered on [input] as
/// [WatchmeError]s.
abstract interface class ByteSocket {
  /// Incoming bytes in arbitrary chunks. Single-subscription; closes when the
  /// connection closes.
  Stream<Uint8List> get input;

  /// Queues [bytes] for sending.
  void send(List<int> bytes);

  /// Completes when queued bytes have been handed to the OS.
  Future<void> flush();

  /// Closes the connection.
  Future<void> close();

  /// Completes when the connection is closed by either side.
  Future<void> get done;

  /// SHA-256 of the peer's leaf certificate when TLS is used, else `null`.
  String? get peerCertificateSha256;

  /// The peer's DER-encoded leaf certificate when TLS is used, else `null`.
  /// Android TV pairing hashes values taken from it.
  Uint8List? get peerCertificateDer;
}

/// How a [ClientIdentity]'s bytes are encoded.
enum IdentityEncoding {
  /// PEM text.
  pem,

  /// Binary DER.
  der,
}

/// A client certificate chain and its private key, for mutual TLS.
///
/// [toString] never prints key material.
@immutable
final class ClientIdentity {
  /// Creates an identity from raw bytes in [encoding].
  ClientIdentity({
    required List<int> certificateChain,
    required List<int> privateKey,
    this.encoding = IdentityEncoding.pem,
    this.password,
  }) : certificateChain = Uint8List.fromList(certificateChain),
       privateKey = Uint8List.fromList(privateKey);

  /// Creates an identity from PEM text.
  ClientIdentity.pem({
    required String certificateChain,
    required String privateKey,
    String? password,
  }) : this(
         certificateChain: utf8.encode(certificateChain),
         privateKey: utf8.encode(privateKey),
         password: password,
       );

  /// Certificate chain, leaf first.
  final Uint8List certificateChain;

  /// Private key for the leaf.
  final Uint8List privateKey;

  /// Encoding of both byte fields.
  final IdentityEncoding encoding;

  /// Password for an encrypted private key, if any.
  final String? password;

  @override
  bool operator ==(Object other) =>
      other is ClientIdentity &&
      other.encoding == encoding &&
      other.password == password &&
      listEquals(other.certificateChain, certificateChain) &&
      listEquals(other.privateKey, privateKey);

  @override
  int get hashCode => Object.hash(
    encoding,
    password,
    listHash(certificateChain),
    listHash(privateKey),
  );

  @override
  String toString() => 'ClientIdentity(${encoding.name})';
}

/// A received UDP datagram.
///
/// Note: `dart:io` also declares a `Datagram`; code importing both should
/// prefix or hide one.
@immutable
final class Datagram {
  /// Creates a datagram from [host]:[port] carrying [data].
  Datagram(this.host, this.port, List<int> data)
    : data = Uint8List.fromList(data);

  /// Sender address.
  final String host;

  /// Sender port.
  final int port;

  /// Payload.
  final Uint8List data;

  /// The payload decoded as UTF-8 (malformed bytes are replaced).
  String get text => utf8.decode(data, allowMalformed: true);

  @override
  bool operator ==(Object other) =>
      other is Datagram &&
      other.host == host &&
      other.port == port &&
      listEquals(other.data, data);

  @override
  int get hashCode => Object.hash(host, port, listHash(data));

  @override
  String toString() => 'Datagram($host:$port, ${data.length} bytes)';
}

String? _lookup(Map<String, String> headers, String name) {
  final lower = name.toLowerCase();
  for (final MapEntry(:key, :value) in headers.entries) {
    if (key.toLowerCase() == lower) return value;
  }
  return null;
}

Map<String, String> _withContentType(
  Map<String, String> headers,
  String contentType,
) => _lookup(headers, 'content-type') != null
    ? headers
    : {...headers, 'Content-Type': contentType};
