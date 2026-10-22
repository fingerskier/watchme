import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';
import 'crypto.dart';
import 'redaction.dart';
import 'soap.dart';

/// A SOAP service on the TV: its control path and URN.
enum VieraService {
  /// The network remote control (keys, apps, text, pairing).
  nrc(VieraPaths.nrcControl, VieraUrn.nrc),

  /// UPnP RenderingControl on the MediaRenderer (volume and mute). Always
  /// plain, and works without pairing.
  dmr(VieraPaths.dmrControl, VieraUrn.renderingControl),

  /// Pro AV control, on some models only. Always plain.
  pac(VieraPaths.pacControl, VieraUrn.pac);

  const VieraService(this.path, this.urn);

  /// Control URL path.
  final String path;

  /// Service type, used in `SOAPACTION` and `xmlns:u`.
  final String urn;
}

/// The largest description document accepted (descriptions are fetched
/// before the device is known to be a VIERA, so they are untrusted).
const int vieraMaxDescriptionBytes = 64 * 1024;

/// The largest SOAP answer accepted (app lists are the biggest).
const int vieraMaxAnswerBytes = 512 * 1024;

/// HTTP access to one TV's UPnP server on the [PanasonicPorts.nrc] port.
///
/// The TV closes the connection after every answer, so every call is one
/// request on its own connection. Requests carry exactly the headers the
/// field-proven clients send ([soapHeaders]) plus what the stack adds
/// (`Host`, `Content-Length`).
final class VieraClient {
  /// Creates a client for [endpoint].
  VieraClient(
    this.endpoint,
    this.network, {
    this.timeout = const Duration(seconds: 5),
  });

  /// The TV.
  final Endpoint endpoint;

  /// The network stack.
  final NetworkStack network;

  /// Default per-request deadline.
  final Duration timeout;

  /// The port in use.
  int get port => endpoint.port(PanasonicPorts.nrc, PanasonicPorts.nrcDefault);

  /// The URI of [path] on the TV.
  Uri uri(String path) =>
      endpoint.uri('http', PanasonicPorts.nrc, PanasonicPorts.nrcDefault, path);

  /// `GET path`, capped at [vieraMaxDescriptionBytes]. Throws
  /// [WatchmeError] for transport failures only.
  Future<HttpResult> get(String path, {Duration? timeout}) => network.http(
    HttpCall.get(
      uri(path),
      timeout: timeout ?? this.timeout,
      maxResponseBytes: vieraMaxDescriptionBytes,
    ),
  );

  /// One SOAP call of [action] on [service] with the escaped argument
  /// elements [args]. Throws [WatchmeError] for transport failures only;
  /// any HTTP status is returned.
  Future<HttpResult> soap(
    VieraService service,
    String action,
    String args, {
    Duration? timeout,
  }) => network.http(
    HttpCall(
      'POST',
      uri(service.path),
      headers: soapHeaders(service.urn, action),
      body: utf8.encode(soapEnvelope(service.urn, action, args)),
      timeout: timeout ?? this.timeout,
      maxResponseBytes: vieraMaxAnswerBytes,
    ),
  );
}

/// The message for the TV's HTTP 403, which it sends to every client on
/// another subnet (verified with curl from two VLANs; Panasonic's own app
/// fails the same way).
const String vieraSubnetRefusal =
    'the TV refused the request (HTTP 403): Panasonic TVs accept control '
    'only from clients on their own subnet, so run watchme on the same '
    'network as the TV (not another subnet or VLAN); also check that Menu > '
    'Network > TV Remote App Settings > TV Remote is On';

/// The error for a non-200 answer [result] to [what] (e.g. `X_SendKey`),
/// keeping the TV's body, redacted with [secrets], as the raw device
/// message.
///
/// * 400: refused; DMR and PAC answer it while the TV is in standby.
/// * 403: the subnet rule ([vieraSubnetRefusal]). Never a pairing problem.
/// * 404: not available on this TV.
/// * 500: a UPnP fault. Error 401 ("Invalid Action") means the TV lacks
///   the action, except for a [plainNrc] `X_SendKey` (every set has it):
///   then the TV now wants encrypted commands, and so a pairing.
WatchmeError vieraHttpError(
  HttpResult result,
  String what, {
  Iterable<String> secrets = const [],
  bool plainNrc = false,
}) {
  final raw = result.body.isEmpty
      ? 'HTTP ${result.status}'
      : redactViera(result.text, secrets: secrets);
  final s = result.status;
  switch (s) {
    case 400:
      return WatchmeError.rejected(
        '$what: the TV refused the request (HTTP 400); it may be in '
        'standby',
        rawDeviceMessage: raw,
      );
    case 403:
      return WatchmeError.rejected(
        '$what: $vieraSubnetRefusal',
        rawDeviceMessage: raw,
      );
    case 404:
      return WatchmeError.unsupported(
        '$what: not available on this TV (HTTP 404)',
        rawDeviceMessage: raw,
      );
    case 500:
      final fault = parseSoapFault(result.text);
      final code = fault.code;
      if (code == 401 && plainNrc && what == 'X_SendKey') {
        return WatchmeError.unauthorized(
          '$what: the TV wants encrypted commands (UPnP error 401); pair '
          'with it',
          rawDeviceMessage: raw,
        );
      }
      if (code == 401) {
        return WatchmeError.unsupported(
          '$what: this TV does not have that action (UPnP error 401)',
          rawDeviceMessage: raw,
        );
      }
      return WatchmeError.rejected(
        code == null
            ? '$what: the TV refused the request (HTTP 500)'
            : '$what: the TV refused the request (UPnP error $code)',
        rawDeviceMessage: raw,
      );
    default:
      return WatchmeError.protocol(
        '$what: unexpected answer from the TV (HTTP $s)',
        rawDeviceMessage: raw,
      );
  }
}

/// The `X_ApplicationId` / `X_EncInfo` arguments that open an encrypted
/// session for [appId] (`X_GetEncryptSessionId`).
String vieraSessionRequestArgs(String appId, VieraKeys keys) =>
    '<X_ApplicationId>${xmlEscape(appId)}</X_ApplicationId>'
    '<X_EncInfo>${vieraSeal(keys, '<X_ApplicationId>${xmlEscape(appId)}'
    '</X_ApplicationId>')}</X_EncInfo>';

/// The session id in a 200 answer [body] to `X_GetEncryptSessionId`, or
/// `null` when it carries none that [keys] decrypt: the stored keyword no
/// longer matches the TV's.
String? vieraSessionIdFrom(String body, VieraKeys keys) {
  final blob = xmlLeaf(body, 'X_EncResult');
  if (blob == null) return null;
  final String text;
  try {
    text = vieraOpen(keys, blob).text;
  } on FormatException {
    return null;
  }
  final id = xmlLeaf(text, 'X_SessionId')?.trim();
  return id != null && RegExp(r'^\d{1,18}$').hasMatch(id) ? id : null;
}
