import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';

// Wire facts for the Fire TV mobile-remote API, checked against
// LibreControl/fire-tv (MIT; docs/protocol.md, src/FireTvDevice.ts,
// src/transport/http.ts) and hms-homelab/hms-firetv (MIT;
// src/clients/LightningClient.cpp, src/services/AppSyncService.cpp, README
// "Fire TV protocol"). Written from those facts; no code copied.

/// Remote-API paths.
abstract final class FireTvPaths {
  static const String dialApp = '/apps/FireTVRemote';
  static const String pinDisplay = '/v1/FireTV/pin/display';
  static const String pinVerify = '/v1/FireTV/pin/verify';
  static const String status = '/v1/FireTV/status';
  static const String action = '/v1/FireTV';
  static const String media = '/v1/media';
  static const String keyboard = '/v1/FireTV/keyboard';
  static const String apps = '/v1/FireTV/appsV2';
  static const String appLaunchPrefix = '/v1/FireTV/app/';
}

/// One device's remote API (HTTPS) and DIAL wake (HTTP), bound to a TLS
/// policy and optionally a client token.
final class FireTvApi {
  FireTvApi(this.endpoint, this.network, {required this.tls, this.token});

  final Endpoint endpoint;
  final NetworkStack network;
  final TlsPolicy tls;
  final String? token;

  /// The bearer values this API sends: the `X-Api-Key` value and, once
  /// paired, the client token. They never appear in an error.
  List<String> get secrets => [fireTvApiKey, ?token];

  /// [error] with [secrets] and token-bearing fields redacted (see
  /// [redactError]).
  WatchmeError redact(WatchmeError error) => redactError(error, secrets);

  /// [apiError] for a non-2xx answer to an authenticated call, redacted.
  WatchmeError errorFor(HttpResult result, String what) =>
      redact(apiError(result, what));

  /// DIAL answers 201 Created; hms-firetv also accepts 200 and 204.
  static const Set<int> wakeStatuses = {200, 201, 204};

  static const Duration wakeTimeout = Duration(seconds: 5);

  Uri get wakeUri => endpoint.uri(
    'http',
    FireTvPorts.dial,
    FireTvPorts.dialDefault,
    FireTvPaths.dialApp,
  );

  /// Starts the remote service through DIAL, waking a sleeping device:
  /// `Content-Type: text/plain` and no body.
  Future<HttpResult> wake() => network.http(
    HttpCall.post(
      wakeUri,
      headers: const {'Content-Type': 'text/plain'},
      timeout: wakeTimeout,
    ),
  );

  /// Reads the DIAL application status of the remote service. A DIAL `GET`
  /// on an application URL (the "application information" request) only
  /// reports its state and never starts the application, so it is safe in
  /// a passive probe.
  Future<HttpResult> dialStatus({Duration timeout = wakeTimeout}) =>
      network.http(HttpCall.get(wakeUri, timeout: timeout));

  Map<String, String> get _headers => {
    'X-Api-Key': fireTvApiKey,
    // LibreControl sends it on every call; the media scan fails without it.
    'Content-Type': 'application/json; charset=utf-8',
    'X-Client-Token': ?token,
  };

  Uri _uri(String path, String? action, [Map<String, String>? query]) =>
      endpoint.uri(
        'https',
        FireTvPorts.api,
        FireTvPorts.apiDefault,
        path,
        action == null && query == null ? null : {'action': ?action, ...?query},
      );

  Future<HttpResult> get(
    String path, {
    Duration timeout = HttpCall.defaultTimeout,
  }) => network.http(
    HttpCall.get(_uri(path, null), headers: _headers, timeout: timeout),
    tls: tls,
  );

  /// POSTs to [path] with `?action=` [action] and any extra [query]
  /// parameters. Without [json] the request has no body at all: key presses
  /// with any body, even `{}`, fail on the device.
  Future<HttpResult> post(
    String path, {
    String? action,
    Map<String, String>? query,
    Object? json,
    Duration timeout = HttpCall.defaultTimeout,
  }) => network.http(
    HttpCall.post(
      _uri(path, action, query),
      headers: _headers,
      body: json == null ? null : utf8.encode(jsonEncode(json)),
      timeout: timeout,
    ),
    tls: tls,
  );
}

/// Whether [result] is a DIAL status document for the `FireTVRemote`
/// application, which only Fire TV devices register.
bool isFireTvRemoteDialStatus(HttpResult result) =>
    result.status == 200 &&
    RegExp(r'<name>\s*FireTVRemote\s*</name>').hasMatch(result.text);

/// Whether [result] means the client token was refused (revoked or reset).
bool isAuthFailure(HttpResult result) =>
    result.status == 401 || result.status == 403;

/// Maps a non-2xx remote-API answer to an error that keeps the body.
WatchmeError apiError(HttpResult result, String what) {
  final s = result.status;
  return switch (s) {
    401 || 403 => result.toError(
      WatchmeErrorCode.reauthRequired,
      '$what: the Fire TV refused the client token (HTTP $s); pair again',
    ),
    404 => result.toError(
      WatchmeErrorCode.unsupported,
      '$what: not available on this Fire TV (HTTP 404)',
    ),
    >= 400 && < 500 => result.toError(
      WatchmeErrorCode.rejected,
      '$what: the Fire TV refused the request (HTTP $s)',
    ),
    _ => result.toError(
      WatchmeErrorCode.protocol,
      '$what: unexpected answer from the Fire TV (HTTP $s)',
    ),
  };
}

/// Maps a failed DIAL wake to an error that keeps the body.
WatchmeError wakeError(HttpResult result) => result.status == 404
    ? result.toError(
        WatchmeErrorCode.unsupported,
        'The DIAL server has no FireTVRemote app (HTTP 404)',
      )
    : result.toError(
        WatchmeErrorCode.rejected,
        'The DIAL wake was refused (HTTP ${result.status})',
      );

/// Sends a DIAL wake and returns the failure, or `null` on success. Never
/// throws: callers decide whether a failed wake matters (the API may
/// already be listening).
Future<WatchmeError?> tryWake(FireTvApi api) async {
  try {
    final result = await api.wake();
    return FireTvApi.wakeStatuses.contains(result.status)
        ? null
        : wakeError(result);
  } on WatchmeError catch (e) {
    return e;
  }
}

/// Runs [call] until the remote API accepts connections or [timeout]
/// passes. A Fire TV starts listening on its API port a moment after the
/// DIAL wake, so `unreachable` (the connection was refused or never made,
/// so nothing was delivered) is retried every [interval]; any other failure
/// is final.
///
/// [call] gets the time it may take: the time left before the deadline, at
/// most [maxAttempt] and at least [minAttempt]. A host that never answers
/// therefore costs about [timeout] in all instead of one full request
/// timeout per attempt, which keeps a driver's connect inside the engine's
/// own deadline. With [cancelled], polling stops with
/// [WatchmeErrorCode.cancelled] as soon as it returns true.
Future<T> untilListening<T>(
  Future<T> Function(Duration attemptTimeout) call, {
  required Clock clock,
  required Duration timeout,
  required Duration interval,
  Duration maxAttempt = HttpCall.defaultTimeout,
  Duration minAttempt = const Duration(seconds: 1),
  bool Function()? cancelled,
}) async {
  final deadline = clock.now().add(timeout);
  void checkCancelled() {
    if (cancelled?.call() ?? false) {
      throw const WatchmeError.cancelled('Cancelled while the Fire TV woke');
    }
  }

  while (true) {
    checkCancelled();
    final left = deadline.difference(clock.now());
    final budget = left > maxAttempt
        ? maxAttempt
        : left < minAttempt
        ? minAttempt
        : left;
    try {
      return await call(budget);
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.unreachable ||
          !clock.now().isBefore(deadline)) {
        rethrow;
      }
    }
    checkCancelled();
    await clock.delay(interval);
  }
}

/// Failure codes that prove a DIAL wake reached nothing or was turned
/// down, so it cannot have woken the device.
const Set<WatchmeErrorCode> _wakeDidNothing = {
  WatchmeErrorCode.unreachable,
  WatchmeErrorCode.destinationRefused,
  WatchmeErrorCode.rejected,
  WatchmeErrorCode.unsupported,
  WatchmeErrorCode.unauthorized,
  WatchmeErrorCode.reauthRequired,
  WatchmeErrorCode.cancelled,
};

/// Whether a failed DIAL wake may still have reached the device and woken
/// it (and the TV with it, over HDMI-CEC): it timed out after connecting,
/// or the answer was garbled. Only a wake that reached nothing or was
/// refused is known to have done nothing.
bool wakeMayHaveActed(WatchmeError wake) =>
    !_wakeDidNothing.contains(wake.code);

/// Adds a failed wake's explanation to [error] (from a later API call).
///
/// [error] is usually `unreachable`: the API port stayed closed. When the
/// wake itself may have taken effect ([wakeMayHaveActed]), that is no
/// longer true of the whole operation, since `unreachable` means nothing
/// reached the device: the result takes the wake's code (a timeout,
/// say) instead.
WatchmeError withWakeContext(WatchmeError error, WatchmeError? wake) {
  if (wake == null) return error;
  final uncertain =
      error.code == WatchmeErrorCode.unreachable && wakeMayHaveActed(wake);
  return WatchmeError(
    uncertain ? wake.code : error.code,
    uncertain
        ? '${error.message} (the DIAL wake may have reached the device: '
              '${wake.message})'
        : '${error.message} (the DIAL wake failed too: ${wake.message})',
    rawDeviceMessage: error.rawDeviceMessage ?? wake.rawDeviceMessage,
    cause: error.cause ?? error,
  );
}

/// The `description` string of a JSON object body, or `null`.
String? description(HttpResult result) {
  try {
    return switch (result.json()) {
      {'description': final String d} => d,
      _ => null,
    };
  } on WatchmeError {
    return null;
  }
}

/// A token is printable ASCII (LibreControl rejects anything else).
bool isPrintableToken(String token) =>
    RegExp(r'^[\x20-\x7e]+$').hasMatch(token);

/// What a redacted secret is replaced with.
const String redactedText = '<redacted>';

/// Whether the JSON field [name] holds a bearer secret: any `...token`
/// field (`token`, `clientToken`, `X-Client-Token`), an API key, a secret
/// or a password. Case, `-` and `_` are ignored.
bool isTokenField(String name) {
  final n = name.toLowerCase().replaceAll(RegExp('[-_]'), '');
  return n.endsWith('token') ||
      n.endsWith('apikey') ||
      n == 'secret' ||
      n == 'password';
}

/// [text] with bearer secrets removed, for an error a user or a log may
/// see. Each removed value becomes [redactedText].
///
/// * In a JSON body, every string or number value of a token-bearing field
///   ([isTokenField]) is removed. With [allValues], every non-empty string
///   value except `"OK"`, and every number, is: a PIN-verify answer carries
///   the new token in `description`, and an unexpected answer may carry it
///   anywhere. [keepProse] then keeps strings that are plainly words
///   ([isProse], e.g. "PIN expired"). A JSON body that needed no change is
///   kept verbatim.
/// * With [allValues], a non-empty body that is not JSON is removed whole,
///   unless [keepProse] is set and it is plainly words.
/// * Every occurrence of a [secrets] value is removed: verbatim, trimmed,
///   JSON-escaped, and inside JSON strings, whatever escapes the device
///   used (`\/`, `\uXXXX`). Text that is not JSON is also searched after
///   decoding JSON string escapes and percent-encoding, and is shown
///   decoded where a secret was found that way.
String redactSecrets(
  String text, {
  Iterable<String> secrets = const [],
  bool allValues = false,
  bool keepProse = false,
}) {
  final known = _secretForms(secrets);
  if (text.trim().isEmpty) return _scrub(text, known);
  Object? json;
  var isJson = true;
  try {
    json = jsonDecode(text);
  } on FormatException {
    isJson = false;
  }
  if (!isJson) {
    if (allValues && !(keepProse && isProse(text.trim()))) {
      return '$redactedText (${text.length} characters, not JSON)';
    }
    return _scrub(text, known);
  }
  var changed = false;
  Object? walk(Object? node, {required bool secret}) {
    switch (node) {
      case final String s
          when s.isNotEmpty &&
              (secret ||
                  (allValues && s != 'OK' && !(keepProse && isProse(s)))):
        changed = true;
        return redactedText;
      case final String s:
        final clean = _scrub(s, known);
        if (clean != s) changed = true;
        return clean;
      case final num n when secret || allValues || known.contains('$n'):
        changed = true;
        return redactedText;
      case final Map<String, Object?> m:
        return {
          for (final MapEntry(:key, :value) in m.entries)
            _scrubKey(key, known, () => changed = true): walk(
              value,
              secret: secret || isTokenField(key),
            ),
        };
      case final List<Object?> l:
        return [for (final v in l) walk(v, secret: secret)];
      default:
        return node;
    }
  }

  final redacted = walk(json, secret: false);
  // Whatever the walk missed (a secret spanning JSON syntax) still goes.
  return _replaceForms(changed ? jsonEncode(redacted) : text, known);
}

/// Whether [text] is plainly words: two or more runs of letters, each
/// optionally ending in punctuation, separated by single spaces ("PIN
/// expired", "Bad arguments supplied."). Tokens have digits, symbols or no
/// spaces, so a token is never prose.
bool isProse(String text) => _prose.hasMatch(text);

final RegExp _prose = RegExp(r"^[A-Za-z]+[.,:;!?']?(?: [A-Za-z]+[.,:;!?']?)+$");

/// The forms of [secrets] searched for verbatim: each value, trimmed, and
/// JSON-escaped.
Set<String> _secretForms(Iterable<String> secrets) {
  final forms = <String>{};
  for (final secret in secrets) {
    final escaped = jsonEncode(secret);
    forms.addAll([
      secret,
      secret.trim(),
      escaped.substring(1, escaped.length - 1),
    ]);
  }
  return forms..removeWhere((f) => f.trim().isEmpty);
}

String _scrubKey(String key, Set<String> secrets, void Function() changed) {
  final clean = _scrub(key, secrets);
  if (clean != key) changed();
  return clean;
}

/// [text] with every form of [secrets] replaced. When the text, decoded
/// once or more ([_decodeEscapes]), holds a secret its raw form hides, the
/// decoded text is returned with the secret replaced.
String _scrub(String text, Set<String> secrets) {
  if (secrets.isEmpty) return text;
  var current = _replaceForms(text, secrets);
  var view = current;
  for (var depth = 0; depth < 3; depth++) {
    final decoded = _decodeEscapes(view);
    if (decoded == view) break;
    view = decoded;
    if (secrets.any(view.contains)) {
      view = current = _replaceForms(view, secrets);
    }
  }
  return current;
}

String _replaceForms(String text, Set<String> secrets) {
  var out = text;
  for (final form in secrets) {
    out = out.replaceAll(form, redactedText);
  }
  return out;
}

final RegExp _escape = RegExp(
  r'\\(?:u([0-9a-fA-F]{4})|(["\\/bfnrt]))|%([0-9a-fA-F]{2})',
);

/// [text] with JSON string escapes (`\/`, `\uXXXX`, `\n`, ...) and
/// percent-encoding (`%2F`) decoded, one level.
String _decodeEscapes(String text) => text.replaceAllMapped(
  _escape,
  (m) => switch ((m[1] ?? m[3], m[2])) {
    (final String hex, _) => String.fromCharCode(int.parse(hex, radix: 16)),
    (_, 'b') => '\b',
    (_, 'f') => '\f',
    (_, 'n') => '\n',
    (_, 'r') => '\r',
    (_, 't') => '\t',
    (_, final c) => c!,
  },
);

/// [error] with [redactSecrets] applied to its message and raw device
/// message, and to its cause: a [WatchmeError] cause is redacted the same
/// way, and any other cause whose text holds a secret is replaced by that
/// text redacted. Returns [error] itself when nothing changed.
WatchmeError redactError(WatchmeError error, Iterable<String> secrets) {
  final message = redactSecrets(error.message, secrets: secrets);
  final rawText = error.rawDeviceMessage;
  final raw = rawText == null ? null : redactSecrets(rawText, secrets: secrets);
  final Object? cause;
  switch (error.cause) {
    case final WatchmeError e:
      cause = redactError(e, secrets);
    case null:
      cause = null;
    case final Object other:
      final text = other.toString();
      final clean = redactSecrets(text, secrets: secrets);
      cause = clean == text ? other : clean;
  }
  if (message == error.message &&
      raw == rawText &&
      identical(cause, error.cause)) {
    return error;
  }
  return WatchmeError(error.code, message, rawDeviceMessage: raw, cause: cause);
}

/// Facts from `GET /v1/FireTV/status`; every field is optional because only
/// LibreControl has documented the shape.
typedef FireTvStatus = ({
  String? osVersion,
  String? platformType,
  String? turnstileVersion,
});

/// Parses a status body, or returns `null` when it is not the expected JSON
/// object.
FireTvStatus? parseStatus(HttpResult result) {
  final Map<String, Object?> m;
  try {
    m = result.jsonObject();
  } on WatchmeError {
    return null;
  }
  String? str(String key) => switch (m[key]) {
    final String v => v,
    _ => null,
  };
  final status = (
    osVersion: str('osVersion'),
    platformType: str('platformType'),
    turnstileVersion: str('turnstileVersion'),
  );
  return status == (osVersion: null, platformType: null, turnstileVersion: null)
      ? null
      : status;
}

/// Parses `GET /v1/FireTV/appsV2`: a bare array of `{appId, name,
/// tvIconArt, isShortcutApp, isInstalled}`, tolerating an object wrapper.
/// Shortcut tiles and uninstalled entries cannot be launched and are
/// skipped (as hms-firetv's AppSyncService does).
List<AppInfo> parseApps(HttpResult result) {
  final body = result.json();
  final list = switch (body) {
    final List<Object?> l => l,
    {'apps': final List<Object?> l} => l,
    {'appsV2': final List<Object?> l} => l,
    {'result': final List<Object?> l} => l,
    _ => throw WatchmeError.protocol(
      'The Fire TV app list is not a JSON array',
      rawDeviceMessage: result.text,
    ),
  };
  return [
    for (final item in list)
      if (item case {'appId': final String id} when id.isNotEmpty)
        if (item['isShortcutApp'] != true && item['isInstalled'] != false)
          AppInfo(
            id: id,
            name: switch (item['name']) {
              final String n when n.isNotEmpty => n,
              _ => id,
            },
            icon: switch (item['tvIconArt']) {
              final String url when url.isNotEmpty => Uri.tryParse(url),
              _ => null,
            },
          ),
  ];
}

/// Android package names: what `POST /v1/FireTV/app/<package>` takes.
final RegExp androidPackage = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
);
