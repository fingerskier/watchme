import 'package:watchme_core/watchme_core.dart';

import 'ecp_xml.dart';

/// The `Endpoint` port name of ECP.
const String rokuEcpPortName = 'ecp';

/// The ECP port Roku devices listen on.
const int rokuEcpDefaultPort = 8060;

/// Low-level ECP HTTP access to one device.
///
/// Every request carries an explicit `Host: <ip>:<port>` header (when the
/// transports allow custom headers): Roku firmware since about 2023 answers
/// 403 when `Host` is a name, and the explicit header keeps that rule
/// visible and testable instead of relying on the stack's default.
final class EcpClient {
  /// Creates a client for [endpoint] over [transports].
  ///
  /// Throws [WatchmeErrorCode.unsupported] when there is no network.
  EcpClient(
    this.endpoint,
    Transports transports, {
    this.timeout = const Duration(seconds: 5),
  }) : _net = transports.requireNetwork(),
       _sendHost = transports.features.contains(TransportFeature.customHeaders);

  /// The device.
  final Endpoint endpoint;

  /// Per-request deadline.
  final Duration timeout;

  final NetworkStack _net;
  final bool _sendHost;

  /// Whether [endpoint] is addressed by an IP literal, as ECP requires.
  bool get hostIsIpLiteral => isIpLiteral(endpoint.host);

  /// The ECP base URI (`http://<host>:<port>/`).
  Uri get baseUri => uri('/');

  /// The ECP URI for [path] (already percent-encoded where needed) and
  /// [query].
  Uri uri(String path, [Map<String, String>? query]) =>
      endpoint.uri('http', rokuEcpPortName, rokuEcpDefaultPort, path, query);

  /// `GET path`. Throws [WatchmeError] for transport failures only; any
  /// HTTP status is returned.
  Future<HttpResult> get(String path) => _send('GET', path, null);

  /// `POST path?query` with an empty body. Throws like [get].
  Future<HttpResult> post(String path, {Map<String, String>? query}) =>
      _send('POST', path, query);

  Future<HttpResult> _send(
    String method,
    String path,
    Map<String, String>? query,
  ) {
    final target = uri(path, query);
    return _net.http(
      HttpCall(
        method,
        target,
        headers: _sendHost ? {'Host': hostHeader(target)} : const {},
        // ECP expects `Content-Length: 0` on commands (curl -d '').
        body: method == 'POST' ? const <int>[] : null,
        timeout: timeout,
      ),
    );
  }

  /// The error for a non-2xx [result] of a request described by [what]
  /// (e.g. `keypress/Home`). The device's body is kept as the raw message.
  WatchmeError errorFor(HttpResult result, String what) {
    final refusal = rokuRefusal(result);
    if (refusal == RokuEcpAccess.limited) {
      return result.toError(
        WatchmeErrorCode.rejected,
        'Roku refused $what: Control by mobile apps is set to Limited',
      );
    }
    if (refusal != null) {
      return result.toError(
        WatchmeErrorCode.rejected,
        'Roku refused $what: Control by mobile apps does not allow it',
      );
    }
    return switch (result.status) {
      403 when !hostIsIpLiteral => result.toError(
        WatchmeErrorCode.rejected,
        'Roku refused $what because it was addressed by the name '
        '"${endpoint.host}"; ECP accepts only IP addresses',
      ),
      403 => result.toError(
        WatchmeErrorCode.rejected,
        'Roku refused $what (HTTP 403)',
      ),
      404 => result.toError(
        WatchmeErrorCode.rejected,
        'Roku does not know $what (HTTP 404)',
      ),
      _ => result.toError(
        WatchmeErrorCode.protocol,
        'Unexpected HTTP ${result.status} from Roku for $what',
      ),
    };
  }
}

/// The access level a refusal reveals: [RokuEcpAccess.limited] for HTTP
/// 403 `ECP command not allowed in Limited mode.`, [RokuEcpAccess.disabled]
/// for another `ECP command not allowed` body, and `null` for anything else
/// (including a 403 caused by a host name or standby).
RokuEcpAccess? rokuRefusal(HttpResult result) {
  if (result.ok) return null;
  final body = result.text.toLowerCase();
  if (!body.contains('ecp command not allowed')) return null;
  return body.contains('limited mode')
      ? RokuEcpAccess.limited
      : RokuEcpAccess.disabled;
}

/// The `Host` header value for [uri]: `host:port`, IPv6 bracketed.
String hostHeader(Uri uri) => uri.host.contains(':')
    ? '[${uri.host}]:${uri.port}'
    : '${uri.host}:${uri.port}';

/// Whether [host] is an IPv4 or IPv6 literal (brackets allowed).
bool isIpLiteral(String host) {
  var h = host.trim();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  try {
    if (h.contains(':')) {
      Uri.parseIPv6Address(h.split('%').first);
    } else {
      if (!RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(h)) return false;
      Uri.parseIPv4Address(h);
    }
    return true;
  } on FormatException {
    return false;
  }
}
