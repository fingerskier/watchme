import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

/// Test-only plain HTTP over `dart:io`, so the driver can be exercised
/// against the loopback Panasonic simulator. It follows the `NetworkStack`
/// HTTP contract (caller headers only, with their case; no `User-Agent` or
/// `Accept-Encoding`; transport failures as [WatchmeError]: `unreachable`
/// before a connection was made, `timeout` after, since the request may
/// have been delivered) but is not the production stack, which lives in
/// watchme_io. Everything except [http] is unsupported.
class IoHttpOnlyStack implements NetworkStack {
  /// Every request sent, in order.
  final List<HttpCall> calls = [];

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) async {
    calls.add(call);
    var connected = false;
    final client = HttpClient()
      ..userAgent = null
      ..autoUncompress = false
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (uri, _, _) async {
        final task = await Socket.startConnect(uri.host, uri.port);
        return ConnectionTask.fromSocket(
          task.socket.then((socket) {
            connected = true;
            return socket;
          }),
          task.cancel,
        );
      };
    WatchmeError lost(Object e) => connected
        ? WatchmeError.timeout('Connection to ${call.uri} lost', cause: e)
        : WatchmeError.unreachable('Cannot reach ${call.uri}', cause: e);
    try {
      return await _send(client, call).timeout(call.timeout);
    } on TimeoutException catch (e) {
      throw lost(e);
    } on SocketException catch (e) {
      throw lost(e);
    } on HttpException catch (e) {
      throw lost(e);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpResult> _send(HttpClient client, HttpCall call) async {
    final request = await client.openUrl(call.method, call.uri);
    request.followRedirects = false;
    request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
    call.headers.forEach(
      (name, value) =>
          request.headers.set(name, value, preserveHeaderCase: true),
    );
    final body = call.body ?? const <int>[];
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final bytes = <int>[];
    await response.forEach(bytes.addAll);
    final limit = call.maxResponseBytes;
    if (limit != null && bytes.length > limit) {
      throw WatchmeError.protocol('Response exceeds $limit bytes');
    }
    final headers = <String, String>{};
    response.headers.forEach((k, v) => headers[k] = v.join(', '));
    return HttpResult(response.statusCode, headers: headers, body: bytes);
  }

  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) => throw const WatchmeError.unsupported('test stack: HTTP only');

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) => throw const WatchmeError.unsupported('test stack: HTTP only');

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) => throw const WatchmeError.unsupported('test stack: HTTP only');

  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) => throw const WatchmeError.unsupported('test stack: HTTP only');
}

/// A [Transports] bundle around [IoHttpOnlyStack].
class IoHttpTransports implements Transports {
  @override
  final IoHttpOnlyStack network = IoHttpOnlyStack();

  @override
  Set<TransportFeature> get features => const {
    TransportFeature.httpReadCrossOrigin,
    TransportFeature.customHeaders,
  };

  @override
  SerialPortProvider? get serial => null;

  @override
  BleCentral? get ble => null;

  @override
  HidPeripheral? get hid => null;

  @override
  IrEmitter? get ir => null;

  @override
  ProcessRunner? get process => null;
}
