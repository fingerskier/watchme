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
/// say) instead. Connecting and pairing use [afterWake] instead, which
/// reports such a wake as a partial delivery.
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

/// The error of [what] (connecting, or pairing up to showing the PIN),
/// which failed with [error] after sending a DIAL wake that ended with
/// [wake]: `null` when the DIAL server acknowledged it.
///
/// A wake that may have reached the device (acknowledged, or failed
/// without proving it did nothing: [wakeMayHaveActed]) may have woken it,
/// and the TV with it over HDMI-CEC, whatever failed next: the API port
/// staying closed, a status read, a refused token. The result is then
/// [WatchmeErrorCode.partiallyDelivered] with [error] as its cause, so the
/// engine neither falls back to another route nor toggles the power, which
/// could turn the TV off again. A wake that did nothing only adds its
/// explanation ([withWakeContext]).
WatchmeError afterWake(String what, WatchmeError error, WatchmeError? wake) {
  if (error.code == WatchmeErrorCode.partiallyDelivered) return error;
  if (wake != null && !wakeMayHaveActed(wake)) {
    return withWakeContext(error, wake);
  }
  final sent = wake == null
      ? 'the Fire TV acknowledged the DIAL wake'
      : 'the DIAL wake may have reached the Fire TV (${wake.message})';
  return WatchmeError.partiallyDelivered(
    '$what failed after $sent, so it may be on: ${error.message}',
    rawDeviceMessage: error.rawDeviceMessage ?? wake?.rawDeviceMessage,
    cause: error,
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
///   value except `"OK"`, and every number, is, whatever it looks like: a
///   PIN-verify answer carries the new token in `description`, a token may
///   be any printable text (words and spaces included), and an unexpected
///   answer may carry it anywhere. A JSON body that needed no change is
///   kept verbatim.
/// * With [allValues], a non-empty body that is not JSON is removed whole.
/// * Every occurrence of a [secrets] value is removed: verbatim, trimmed,
///   JSON-escaped, and inside JSON strings, whatever escapes the device
///   used (`\/`, `\uXXXX`). The text is also searched after decoding JSON
///   string escapes and percent-encoding, and the escaped text such an
///   occurrence came from is removed. Occurrences are all found in the
///   same text before any is removed, and each run of overlapping ones is
///   removed whole, so a secret inside another (the `X-Api-Key` value at
///   the start of a token, say) leaves nothing of either behind.
String redactSecrets(
  String text, {
  Iterable<String> secrets = const [],
  bool allValues = false,
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
    if (allValues) {
      return '$redactedText (${text.length} characters, not JSON)';
    }
    return _scrub(text, known);
  }
  var changed = false;
  Object? walk(Object? node, {required bool secret}) {
    switch (node) {
      case final String s
          when s.isNotEmpty && (secret || (allValues && s != 'OK')):
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
  return _scrub(changed ? jsonEncode(redacted) : text, known);
}

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

/// How many levels of escapes [_scrub] decodes.
const int _decodeDepth = 3;

/// [text] with every occurrence of every one of [forms] replaced by
/// [redactedText], atomically.
///
/// Occurrences are searched for in [text] as it is and decoded once or
/// more ([_decodeDepth] levels of JSON string escapes and percent-encoding),
/// overlapping ones included, and each is mapped back to the range of
/// [text] it came from. Only then is anything replaced: each run of
/// overlapping or touching ranges becomes one [redactedText]. Replacing one
/// form after another would instead let the first replacement cut a longer
/// secret that contains it, leaving the rest of that secret behind.
String _scrub(String text, Set<String> forms) {
  if (forms.isEmpty || text.isEmpty) return text;
  final ranges = <(int, int)>[];
  _View? view = _View(text);
  for (var depth = 0; view != null && depth <= _decodeDepth; depth++) {
    ranges.addAll(view.find(forms));
    view = view.decoded();
  }
  return _replaceRanges(text, ranges);
}

/// [text] with each run of overlapping or touching [ranges] (start
/// inclusive, end exclusive) replaced by one [redactedText].
String _replaceRanges(String text, List<(int, int)> ranges) {
  if (ranges.isEmpty) return text;
  ranges.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  var kept = 0;
  var (start, end) = ranges.first;
  for (final (s, e) in ranges.skip(1)) {
    if (s <= end) {
      if (e > end) end = e;
      continue;
    }
    out
      ..write(text.substring(kept, start))
      ..write(redactedText);
    kept = end;
    (start, end) = (s, e);
  }
  return (out
        ..write(text.substring(kept, start))
        ..write(redactedText)
        ..write(text.substring(end)))
      .toString();
}

/// A text decoded from an original one, with the range of the original
/// each of its UTF-16 code units came from.
final class _View {
  /// The original text itself.
  _View(this.text)
    : _starts = List.generate(text.length, (i) => i),
      _ends = List.generate(text.length, (i) => i + 1);

  _View._(this.text, this._starts, this._ends);

  final String text;
  final List<int> _starts;
  final List<int> _ends;

  /// The range of the original text behind each occurrence of each of
  /// [forms] in [text], overlapping occurrences included.
  Iterable<(int, int)> find(Set<String> forms) sync* {
    for (final form in forms) {
      if (form.isEmpty) continue;
      for (
        var at = text.indexOf(form);
        at >= 0;
        at = text.indexOf(form, at + 1)
      ) {
        yield (_starts[at], _ends[at + form.length - 1]);
      }
    }
  }

  /// This text with one level of JSON string escapes (`\/`, `\uXXXX`,
  /// `\n`, ...) and percent-encoding (`%2F`) decoded, or `null` when it has
  /// none. Each escape decodes to one code unit, which comes from the
  /// original range of the whole escape.
  _View? decoded() {
    final matches = _escape.allMatches(text).toList();
    if (matches.isEmpty) return null;
    final out = StringBuffer();
    final starts = <int>[];
    final ends = <int>[];
    var kept = 0;
    void copy(int from, int to) {
      out.write(text.substring(from, to));
      starts.addAll(_starts.getRange(from, to));
      ends.addAll(_ends.getRange(from, to));
    }

    for (final m in matches) {
      copy(kept, m.start);
      out.write(_unescape(m));
      starts.add(_starts[m.start]);
      ends.add(_ends[m.end - 1]);
      kept = m.end;
    }
    copy(kept, text.length);
    return _View._(out.toString(), starts, ends);
  }
}

final RegExp _escape = RegExp(
  r'\\(?:u([0-9a-fA-F]{4})|(["\\/bfnrt]))|%([0-9a-fA-F]{2})',
);

/// The one code unit an [_escape] match stands for.
String _unescape(Match m) => switch ((m[1] ?? m[3], m[2])) {
  (final String hex, _) => String.fromCharCode(int.parse(hex, radix: 16)),
  (_, 'b') => '\b',
  (_, 'f') => '\f',
  (_, 'n') => '\n',
  (_, 'r') => '\r',
  (_, 't') => '\t',
  (_, final c) => c!,
};

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
