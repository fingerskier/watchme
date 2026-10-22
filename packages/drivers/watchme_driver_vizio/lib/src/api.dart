import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';

// Wire facts for the VIZIO SmartCast REST API, from the watchme VIZIO
// brief, which checked them against vizaio (MIT; client.py, _payloads.py,
// _keys.py, docs/protocol-notes.md), pyvizio (MIT), heathbar/
// vizio-smart-cast (MIT), the Home Assistant vizio integration
// (Apache-2.0) and exiva/Vizio_SmartCast_API (no licence: facts only).
// Written from those facts; no code copied.

/// SmartCast API paths.
abstract final class VizioPaths {
  static const String deviceInfo = '/state/device/deviceinfo';
  static const String powerMode = '/state/device/power_mode';
  static const String pairingStart = '/pairing/start';
  static const String pairingPair = '/pairing/pair';
  static const String pairingCancel = '/pairing/cancel';
  static const String keyCommand = '/key_command/';
  static const String appCurrent = '/app/current';
  static const String appLaunch = '/app/launch';

  /// The settings root of a TV. Sound bars use `audio_settings`, which this
  /// driver does not claim.
  static const String tvRoot = 'tv_settings';

  /// A leaf of the TV's dynamic settings tree, e.g. `audio/volume`.
  static String setting(String leaf) => '/menu_native/dynamic/$tvRoot/$leaf';

  static final String volume = setting('audio/volume');
  static final String mute = setting('audio/mute');
  static final String currentInput = setting('devices/current_input');
  static final String inputList = setting('devices/name_input');
}

/// Every `STATUS.RESULT` word the SmartCast API is known to send (the
/// official app's `ResponseResult` enum plus three seen on hardware). They
/// carry no secret, so redaction keeps them.
const Set<String> vizioResultWords = {
  'SUCCESS',
  'FAILURE',
  'URI_NOT_FOUND',
  'ABORTED',
  'BUSY',
  'BLOCKED',
  'REQUIRES_PAIRING',
  'REQUIRES_SYSTEM_PIN',
  'REQUIRES_NEW_SYSTEM_PIN',
  'PAIRING_DENIED',
  'CHALLENGE_INCORRECT',
  'VALUE_OUT_OF_RANGE',
  'MAX_CHALLENGES_EXCEEDED',
  'TOO_MANY_PAIRED_DEVICES',
  'INVALID_PARAMETER',
  'READ_ONLY_ERROR',
  'HASHVAL_ERROR',
  'PROXY_ERROR',
  'TYPE_ERROR',
};

/// One TV's SmartCast API on one port, bound to a TLS policy and, once
/// paired, the `AUTH` token.
final class VizioApi {
  VizioApi(
    Endpoint endpoint,
    this.network, {
    required this.port,
    required this.tls,
    this.token,
    this.readTimeout = const Duration(seconds: 6),
    this.writeTimeout = const Duration(seconds: 15),
  }) : endpoint = endpoint.withPorts({VizioPorts.api: port});

  /// The device, with [port] as its `api` port.
  final Endpoint endpoint;
  final NetworkStack network;
  final int port;
  final TlsPolicy tls;
  final String? token;

  /// Deadline of a `GET`.
  final Duration readTimeout;

  /// Deadline of a `PUT`. Slow TVs take a while to acknowledge a key.
  final Duration writeTimeout;

  /// The bearer values this API sends; they never appear in an error.
  List<String> get secrets => [?token];

  /// [error] with [secrets] and secret-bearing fields redacted.
  WatchmeError redact(WatchmeError error) => redactError(error, secrets);

  Uri uri(String path) =>
      endpoint.uri('https', VizioPorts.api, VizioPorts.apiDefault, path);

  Map<String, String> _headers({required bool body}) => {
    // vizaio and pyvizio send exactly this; the TV wants JSON bodies.
    if (body) 'Content-Type': 'application/json',
    // The literal header name `AUTH` (not Authorization, no scheme).
    'AUTH': ?token,
  };

  /// `GET path`. Throws [WatchmeError] for transport failures only.
  Future<VizioReply> get(String path, {Duration? timeout}) async =>
      VizioReply.parse(
        await network.http(
          HttpCall.get(
            uri(path),
            headers: _headers(body: false),
            timeout: timeout ?? readTimeout,
          ),
          tls: tls,
        ),
      );

  /// `PUT path` with a JSON [body]. Every write, key presses and pairing
  /// included, is a `PUT`.
  Future<VizioReply> put(String path, Object body, {Duration? timeout}) async =>
      VizioReply.parse(
        await network.http(
          HttpCall(
            'PUT',
            uri(path),
            headers: _headers(body: true),
            body: utf8.encode(jsonEncode(body)),
            timeout: timeout ?? writeTimeout,
          ),
          tls: tls,
        ),
      );
}

/// A SmartCast answer: the HTTP result and its JSON object body with every
/// key lower-cased (the TV spells them either way: `STATUS` and `status`).
final class VizioReply {
  VizioReply._(this.http, this.body);

  /// Decodes [http]; [body] is `null` when it is not a JSON object.
  factory VizioReply.parse(HttpResult http) {
    Map<String, Object?>? body;
    try {
      if (lowerKeys(jsonDecode(http.text)) case final Map<String, Object?> m) {
        body = m;
      }
    } on FormatException {
      body = null;
    }
    return VizioReply._(http, body);
  }

  final HttpResult http;
  final Map<String, Object?>? body;

  int get status => http.status;
  String get text => http.text;

  /// `STATUS.RESULT`, upper-cased, or `null` when there is none.
  String? get result => switch (body?['status']) {
    {'result': final String r} => r.toUpperCase(),
    _ => null,
  };

  /// Whether this is HTTP 2xx with `STATUS.RESULT` `SUCCESS`.
  bool get success => http.ok && result == 'SUCCESS';

  /// Whether the TV refused the request for lack of a valid token: a raw
  /// HTTP 401 or 403, or a `REQUIRES_PAIRING` or `PAIRING_DENIED` envelope
  /// (brief §8: either on a call that carries the token means it was
  /// revoked). Only meaningful for calls that send the token; pairing,
  /// where `PAIRING_DENIED` is a wrong PIN, never asks.
  bool get authRefused =>
      status == 401 ||
      status == 403 ||
      result == 'REQUIRES_PAIRING' ||
      (http.ok && result == 'PAIRING_DENIED');

  /// `ITEMS`, as maps.
  List<Map<String, Object?>> get items => switch (body?['items']) {
    final List<Object?> l => [
      for (final i in l)
        if (i is Map<String, Object?>) i,
    ],
    _ => const [],
  };

  /// `ITEM`, or `null`.
  Map<String, Object?>? get item => switch (body?['item']) {
    final Map<String, Object?> m => m,
    _ => null,
  };

  /// The first item of `ITEMS` (or `ITEM`) whose `CNAME` is [cname], or the
  /// first one at all when [cname] is `null`.
  Map<String, Object?>? itemNamed([String? cname]) {
    for (final i in [...items, ?item]) {
      if (cname == null || i['cname'] == cname) return i;
    }
    return null;
  }
}

/// [json] with every map key lower-cased, recursively.
Object? lowerKeys(Object? json) => switch (json) {
  final Map<Object?, Object?> m => <String, Object?>{
    for (final MapEntry(:key, :value) in m.entries)
      '$key'.toLowerCase(): lowerKeys(value),
  },
  final List<Object?> l => [for (final v in l) lowerKeys(v)],
  _ => json,
};

/// Where a SmartCast error happened, which changes what some results mean.
enum VizioContext {
  /// `/pairing/*`, before there is a token.
  pairing,

  /// Any call with a token.
  session,
}

/// The error for a SmartCast [reply] that is not a success, with the
/// device's body as raw device message (redacted by the caller, or with
/// [shown] when given). [what] names the request in watchme's words.
///
/// The mapping (brief §5, §8):
/// * Raw HTTP 401 or 403, and `REQUIRES_PAIRING`: the token was refused,
///   [WatchmeErrorCode.reauthRequired] in a session (re-pairing with the
///   same `DEVICE_ID` elsewhere, or a factory reset). During pairing, which
///   sends no token, a raw 401 or 403 is a refusal
///   ([WatchmeErrorCode.rejected]) and `REQUIRES_PAIRING`
///   [WatchmeErrorCode.unauthorized] (brief §5).
/// * `PAIRING_DENIED` (wrong PIN), `VALUE_OUT_OF_RANGE` (malformed PIN),
///   `CHALLENGE_INCORRECT` (stale challenge) and `MAX_CHALLENGES_EXCEEDED`
///   (lockout) during pairing: [WatchmeErrorCode.unauthorized].
///   `PAIRING_DENIED` on a control call means the token was refused.
/// * `ABORTED` during pairing: [WatchmeErrorCode.cancelled].
/// * `URI_NOT_FOUND` (HTTP 200, not 404): not on this firmware,
///   [WatchmeErrorCode.unsupported].
/// * `FAILURE`, `BLOCKED`, `BUSY`, `TOO_MANY_PAIRED_DEVICES`,
///   `REQUIRES_SYSTEM_PIN`, `REQUIRES_NEW_SYSTEM_PIN`, `HASHVAL_ERROR`,
///   `READ_ONLY_ERROR` and `VALUE_OUT_OF_RANGE` on a setting: the TV
///   declined, [WatchmeErrorCode.rejected]. Nothing changed.
/// * `INVALID_PARAMETER`, `PROXY_ERROR`, `TYPE_ERROR`: the TV could not use
///   watchme's request, [WatchmeErrorCode.protocol]. Nothing changed.
/// * HTTP 500 (lighttpd "Unhandled Exception"), any other status, a body
///   without `STATUS.RESULT`, or an unknown result:
///   [WatchmeErrorCode.protocol].
WatchmeError vizioError(
  VizioReply reply,
  String what, {
  required VizioContext context,
  String? shown,
}) {
  final raw = shown ?? (reply.text.isEmpty ? 'HTTP ${reply.status}' : null);
  WatchmeError error(WatchmeErrorCode code, String message) =>
      WatchmeError(code, message, rawDeviceMessage: raw ?? reply.text);
  final pairing = context == VizioContext.pairing;
  final s = reply.status;
  if (s == 401 || s == 403) {
    return pairing
        ? error(
            WatchmeErrorCode.rejected,
            '$what: the TV refused the request (HTTP $s)',
          )
        : error(
            WatchmeErrorCode.reauthRequired,
            '$what: the TV refused the pairing token (HTTP $s); pair again',
          );
  }
  if (!reply.http.ok) {
    return s == 404
        ? error(
            WatchmeErrorCode.unsupported,
            '$what: not available on this TV (HTTP 404)',
          )
        : error(
            WatchmeErrorCode.protocol,
            '$what: unexpected answer from the TV (HTTP $s)',
          );
  }
  final result = reply.result;
  if (result == null) {
    return error(
      WatchmeErrorCode.protocol,
      '$what: the TV answered without a SmartCast status',
    );
  }
  String says(String meaning) => '$what: $meaning ($result)';
  return switch (result) {
    'REQUIRES_PAIRING' when pairing => error(
      WatchmeErrorCode.unauthorized,
      says('the TV asks for pairing during pairing'),
    ),
    'REQUIRES_PAIRING' || 'PAIRING_DENIED' when !pairing => error(
      WatchmeErrorCode.reauthRequired,
      says('the TV refused the pairing token; pair again'),
    ),
    'PAIRING_DENIED' => error(
      WatchmeErrorCode.unauthorized,
      says('the PIN was wrong'),
    ),
    'VALUE_OUT_OF_RANGE' when pairing => error(
      WatchmeErrorCode.unauthorized,
      says('the TV did not accept the PIN'),
    ),
    'CHALLENGE_INCORRECT' when pairing => error(
      WatchmeErrorCode.unauthorized,
      says(
        'the PIN is no longer on the TV (it expired or was dismissed); '
        'start pairing again',
      ),
    ),
    'MAX_CHALLENGES_EXCEEDED' when pairing => error(
      WatchmeErrorCode.unauthorized,
      says('too many wrong PINs; the TV stopped this pairing, start again'),
    ),
    'ABORTED' when pairing => error(
      WatchmeErrorCode.cancelled,
      says('the pairing was aborted on the TV'),
    ),
    'TOO_MANY_PAIRED_DEVICES' => error(
      WatchmeErrorCode.rejected,
      says(
        'the TV has paired too many devices; remove one in its mobile '
        'device settings, then try again',
      ),
    ),
    'BLOCKED' => error(
      WatchmeErrorCode.rejected,
      says(
        pairing
            ? 'another pairing is in progress on the TV (a PIN is on '
                  'screen); wait for it to close, then try again'
            : 'the TV is busy',
      ),
    ),
    'BUSY' => error(WatchmeErrorCode.rejected, says('the TV is busy')),
    'REQUIRES_SYSTEM_PIN' || 'REQUIRES_NEW_SYSTEM_PIN' => error(
      WatchmeErrorCode.rejected,
      says('the TV wants its parental or system PIN'),
    ),
    'URI_NOT_FOUND' => error(
      WatchmeErrorCode.unsupported,
      says('not available on this firmware'),
    ),
    'HASHVAL_ERROR' => error(
      WatchmeErrorCode.rejected,
      says('the setting changed meanwhile'),
    ),
    'READ_ONLY_ERROR' => error(
      WatchmeErrorCode.rejected,
      says('the setting is read-only'),
    ),
    'VALUE_OUT_OF_RANGE' => error(
      WatchmeErrorCode.rejected,
      says('the value is out of range'),
    ),
    'FAILURE' => error(WatchmeErrorCode.rejected, says('the TV refused')),
    'INVALID_PARAMETER' || 'PROXY_ERROR' || 'TYPE_ERROR' => error(
      WatchmeErrorCode.protocol,
      says('the TV could not use the request'),
    ),
    _ => error(WatchmeErrorCode.protocol, says('unexpected SmartCast status')),
  };
}

/// What `GET /state/device/deviceinfo` (no token needed) says about a TV.
final class VizioDeviceInfo {
  const VizioDeviceInfo({
    this.settingsRoot,
    this.modelName,
    this.serialNumber,
    this.version,
    this.chipset,
    this.deviceType,
    this.apiVersion,
    this.castName,
  });

  /// Parses a deviceinfo answer, or returns `null` when it is not one:
  /// `SUCCESS` with an item whose `VALUE` holds `SETTINGS_ROOT` or
  /// `SYSTEM_INFO`. Field placement varies, so `SYSTEM_INFO` fields are also
  /// looked up directly in `VALUE`.
  static VizioDeviceInfo? parse(VizioReply reply) {
    if (!reply.success) return null;
    final value = switch (reply.itemNamed()?['value']) {
      final Map<String, Object?> v => v,
      _ => null,
    };
    if (value == null) return null;
    final system = switch (value['system_info']) {
      final Map<String, Object?> s => s,
      _ => const <String, Object?>{},
    };
    String? str(String key) => switch (system[key] ?? value[key]) {
      final String s when s.trim().isNotEmpty => s.trim(),
      final num n => '$n',
      _ => null,
    };
    final root = str('settings_root');
    if (root == null && value['system_info'] == null) return null;
    return VizioDeviceInfo(
      settingsRoot: root?.toLowerCase(),
      modelName: str('model_name'),
      serialNumber: str('serial_number'),
      version: str('version'),
      chipset: str('chipset'),
      deviceType: str('device_type'),
      apiVersion: str('api_version'),
      castName: str('cast_name'),
    );
  }

  final String? settingsRoot;
  final String? modelName;
  final String? serialNumber;
  final String? version;
  final String? chipset;
  final String? deviceType;
  final String? apiVersion;
  final String? castName;

  /// A sound bar or speaker (`audio_settings`), which this driver does not
  /// claim: its auth model and volume scale are not settled in the
  /// references.
  bool get isAudio => settingsRoot == 'audio_settings';
}

/// The ports to try for [endpoint], in order, without repeats: [first]
/// (the port remembered from pairing, or the TXT `hsp` hint of a
/// `_viziocast._tcp` advertisement) unless the endpoint names its `api`
/// port explicitly, then the `api` port (7345), then the `legacy` port
/// (9000).
List<int> vizioPortCandidates(Endpoint endpoint, {int? first}) => {
  if (!endpoint.ports.containsKey(VizioPorts.api)) ...[
    ?first,
    ?advertisedRestPort(endpoint.attributes),
  ],
  endpoint.port(VizioPorts.api, VizioPorts.apiDefault),
  endpoint.port(VizioPorts.legacy, VizioPorts.legacyDefault),
}.toList();

/// Whether [attrs] come from a `_viziocast._tcp` mDNS record, whose TXT
/// keys (`name`, `id`, `did`, `hsp`, `wifi`) may then be read. Other
/// services on the same TV (Chromecast built-in) use the same key names
/// for other things.
bool isVizioCastRecord(Map<String, String> attrs) =>
    normalizeServiceType(attrs[DiscoveryAttr.mdnsService] ?? '') ==
    '_viziocast._tcp';

/// The REST port a `_viziocast._tcp` record advertises in TXT `hsp`, if
/// valid. `hp` (the internal loopback twin, 7346) is never used.
int? advertisedRestPort(Map<String, String> attrs) {
  if (!isVizioCastRecord(attrs)) return null;
  final port = int.tryParse(attrs['hsp'] ?? '');
  return port != null && port > 0 && port < 65536 ? port : null;
}

/// The power `GET /state/device/power_mode` reports: `VALUE` 1 is on, 0 is
/// Quick Start standby. `null` for any other answer.
PowerMode? parsePowerMode(VizioReply reply) {
  if (!reply.success) return null;
  return switch (reply.itemNamed('power_mode')?['value'] ??
      reply.itemNamed()?['value']) {
    1 || '1' => PowerMode.on,
    0 || '0' => PowerMode.standby,
    _ => null,
  };
}

/// The `VALUE` and `HASHVAL` of a settings leaf answer, or `null`.
({Object? value, int hash})? parseLeaf(VizioReply reply, String cname) {
  if (!reply.success) return null;
  final item = reply.itemNamed(cname) ?? reply.itemNamed();
  return switch (item?['hashval']) {
    final int hash => (value: item!['value'], hash: hash),
    _ => null,
  };
}
