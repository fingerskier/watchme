import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart' show sha256Hex;

/// Test-only HTTP(S) over `dart:io`, so the driver can be exercised against
/// the loopback VIZIO simulator. It follows the `NetworkStack` HTTP
/// contract (caller headers only, no redirects, TLS decided by
/// [TlsPolicy.allows], transport failures as [WatchmeError]): a refused
/// connection is `unreachable`, a connection that was made and then went
/// silent or dropped is `timeout`, a TLS failure (a pin mismatch) is
/// `protocol`. It is not the production stack, which lives in watchme_io.
/// Everything except [http] is unsupported.
class IoHttpOnlyStack implements NetworkStack {
  /// Every request, in order (method and URI only).
  final List<HttpCall> calls = [];

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) async {
    calls.add(call);
    // No trusted roots: every certificate goes through the policy.
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = call.timeout
      ..badCertificateCallback = (cert, _, _) =>
          tls.allows(peerSha256: sha256Hex(cert.der), platformTrusted: false);
    var connected = false;
    try {
      return await _send(client, call, () => connected = true).timeout(
        call.timeout,
        onTimeout: () => throw connected
            ? WatchmeError.timeout('No answer from ${call.uri}')
            : WatchmeError.unreachable('No connection to ${call.uri}'),
      );
    } on HandshakeException catch (e) {
      throw WatchmeError.protocol('TLS with ${call.uri} failed', cause: e);
    } on SocketException catch (e) {
      throw connected
          ? WatchmeError.timeout('Connection to ${call.uri} lost', cause: e)
          : WatchmeError.unreachable('Cannot reach ${call.uri}', cause: e);
    } on HttpException catch (e) {
      throw connected
          ? WatchmeError.timeout('Connection to ${call.uri} lost', cause: e)
          : WatchmeError.unreachable('Cannot reach ${call.uri}', cause: e);
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpResult> _send(
    HttpClient client,
    HttpCall call,
    void Function() onConnected,
  ) async {
    final request = await client.openUrl(call.method, call.uri);
    onConnected();
    request.followRedirects = false;
    request.headers
      ..removeAll(HttpHeaders.userAgentHeader)
      ..removeAll(HttpHeaders.acceptEncodingHeader);
    call.headers.forEach(request.headers.set);
    final body = call.body ?? const <int>[];
    request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final bytes = <int>[];
    await response.forEach(bytes.addAll);
    final headers = <String, String>{};
    response.headers.forEach((k, v) => headers[k] = v.join(', '));
    final cert = response.certificate;
    return HttpResult(
      response.statusCode,
      headers: headers,
      body: bytes,
      peerCertificateSha256: cert == null ? null : sha256Hex(cert.der),
    );
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
    TransportFeature.nonSimpleMethods,
    TransportFeature.tlsAcceptSelfSigned,
    TransportFeature.tlsPeerCertificate,
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
