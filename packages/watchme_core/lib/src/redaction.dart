import 'dart:convert';

import 'errors.dart';

/// What a redacted secret is replaced with.
const String redactedText = '<redacted>';

/// Whether the JSON field [name] holds a secret: any `...token` field
/// (`token`, `clientToken`, `X-Client-Token`, `AUTH_TOKEN`,
/// `PAIRING_REQ_TOKEN`), an `AUTH` header value, an API key, a PIN (also
/// as VIZIO's `RESPONSE_VALUE`), a secret or a password. Case, `-` and `_`
/// are ignored.
bool isSecretFieldName(String name) {
  final n = name.toLowerCase().replaceAll(RegExp('[-_]'), '');
  return n == 'auth' ||
      n.endsWith('token') ||
      n.endsWith('apikey') ||
      n == 'responsevalue' ||
      n == 'pin' ||
      n == 'secret' ||
      n == 'password';
}

/// [text] with secrets removed, for an error a user or a log may see. Each
/// removed value becomes [redactedText].
///
/// Drivers run every device answer and error through this (or
/// [redactError]) before it can reach a [WatchmeError], a log or the UI:
///
/// * In a JSON body, every string or number value of a secret field
///   ([isSecretFieldName]) is removed. With [allValues], every non-empty
///   string and every number is, whatever it looks like, except strings in
///   [keep] (status words that carry no secret and say what went wrong,
///   such as Fire TV's `OK` or VIZIO's `PAIRING_DENIED`): a pairing answer
///   may carry the new token in any field, and a token may be any printable
///   text. A JSON body that needed no change is kept verbatim.
/// * With [allValues], a non-empty body that is not JSON is removed whole.
/// * Every occurrence of a [secrets] value is removed: verbatim, trimmed,
///   JSON-escaped, and wherever JSON string escapes (`\/`, `\uXXXX`) or
///   percent-encoding (`%2F`) hide it, up to three levels deep. Occurrences
///   are all found in the original text, each mapped back to the span it
///   came from, before any is removed, and each run of overlapping or
///   touching spans goes as one: replacing one form after another would let
///   the first replacement cut a longer secret that contains it (an API key
///   at the start of a token, say), leaving the rest of it behind.
String redactSecrets(
  String text, {
  Iterable<String> secrets = const [],
  bool allValues = false,
  Set<String> keep = const {},
}) {
  final forms = _secretForms(secrets);
  if (text.trim().isEmpty) return _scrub(text, forms);
  Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    return allValues
        ? '$redactedText (${text.length} characters, not JSON)'
        : _scrub(text, forms);
  }
  var changed = false;
  Object? walk(Object? node, {required bool secret}) {
    switch (node) {
      case final String s when s.isNotEmpty && secret:
        changed = true;
        return redactedText;
      case final String s when s.isNotEmpty && allValues && !keep.contains(s):
        changed = true;
        return redactedText;
      case final String s:
        final clean = _scrub(s, forms);
        if (clean != s) changed = true;
        return clean;
      case final num n when secret || allValues || forms.contains('$n'):
        changed = true;
        return redactedText;
      case final Map<String, Object?> m:
        return {
          for (final MapEntry(:key, :value) in m.entries)
            _scrubKey(key, forms, () => changed = true): walk(
              value,
              secret: secret || isSecretFieldName(key),
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
  return _scrub(changed ? jsonEncode(redacted) : text, forms);
}

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

/// The forms of [secrets] searched for verbatim: each value, trimmed, and
/// JSON-escaped; blank forms dropped.
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

String _scrubKey(String key, Set<String> forms, void Function() changed) {
  final clean = _scrub(key, forms);
  if (clean != key) changed();
  return clean;
}

/// How many levels of escapes [_scrub] decodes.
const int _decodeDepth = 3;

/// [text] with every occurrence of every one of [forms] replaced by
/// [redactedText]: found in [text] as it is and decoded up to
/// [_decodeDepth] levels, each mapped back to the span of [text] it came
/// from, and every run of overlapping or touching spans replaced once.
String _scrub(String text, Set<String> forms) {
  if (forms.isEmpty || text.isEmpty) return text;
  final spans = <(int, int)>[];
  _Decoded? view = _Decoded(text);
  for (var depth = 0; view != null && depth <= _decodeDepth; depth++) {
    spans.addAll(view.find(forms));
    view = view.decoded();
  }
  if (spans.isEmpty) return text;
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  var kept = 0;
  var (start, end) = spans.first;
  void flush() {
    out
      ..write(text.substring(kept, start))
      ..write(redactedText);
    kept = end;
  }

  for (final (s, e) in spans.skip(1)) {
    if (s <= end) {
      if (e > end) end = e;
      continue;
    }
    flush();
    (start, end) = (s, e);
  }
  flush();
  return (out..write(text.substring(kept))).toString();
}

/// A text decoded from an original one, with the span of the original
/// that each of its UTF-16 code units came from.
final class _Decoded {
  /// The original text itself.
  _Decoded(this.text)
    : _from = List.generate(text.length, (i) => i),
      _to = List.generate(text.length, (i) => i + 1);

  _Decoded._(this.text, this._from, this._to);

  final String text;
  final List<int> _from;
  final List<int> _to;

  /// The original span behind each occurrence of each of [forms],
  /// overlapping occurrences included.
  Iterable<(int, int)> find(Set<String> forms) sync* {
    for (final form in forms) {
      if (form.isEmpty) continue;
      for (
        var at = text.indexOf(form);
        at >= 0;
        at = text.indexOf(form, at + 1)
      ) {
        yield (_from[at], _to[at + form.length - 1]);
      }
    }
  }

  /// This text with one level of JSON string escapes and percent-encoding
  /// decoded, or `null` when it has none. Each escape decodes to one code
  /// unit, which comes from the span of the whole escape.
  _Decoded? decoded() {
    final matches = _escape.allMatches(text).toList();
    if (matches.isEmpty) return null;
    final out = StringBuffer();
    final from = <int>[];
    final to = <int>[];
    var kept = 0;
    void copy(int a, int b) {
      out.write(text.substring(a, b));
      from.addAll(_from.getRange(a, b));
      to.addAll(_to.getRange(a, b));
    }

    for (final m in matches) {
      copy(kept, m.start);
      out.write(_unescape(m));
      from.add(_from[m.start]);
      to.add(_to[m.end - 1]);
      kept = m.end;
    }
    copy(kept, text.length);
    return _Decoded._(out.toString(), from, to);
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
