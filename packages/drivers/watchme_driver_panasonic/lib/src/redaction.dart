import 'package:watchme_core/watchme_core.dart';

// Secrets become watchme_core's [redactedText].

/// Elements whose text is a secret or decrypts to one: the pairing
/// credential (`X_ApplicationId`, `X_Keyword`), what derives or carries it
/// (`X_ChallengeKey`, `X_PinCode`, the encrypted blobs) and the session's
/// own numbers. Their content never reaches an error.
const Set<String> vieraSecretElements = {
  'X_ApplicationId',
  'X_Keyword',
  'X_ChallengeKey',
  'X_PinCode',
  'X_AuthInfo',
  'X_AuthResult',
  'X_EncInfo',
  'X_EncResult',
  'X_SessionId',
  'X_SequenceNumber',
};

/// [text] with every secret removed, for an error a user or a log may see.
///
/// * The content of every [vieraSecretElements] element is replaced, with
///   any namespace prefix and also where the markup itself is escaped
///   (`&lt;X_PinCode&gt;...`).
/// * Every occurrence of every [secrets] value (the app id, the keyword,
///   the challenge, the PIN) is replaced, verbatim, trimmed, and wherever
///   XML character references or percent-encoding (`%2F` for a base64 `/`)
///   hide it.
///
/// Every span is found in the original text first (decoded views map each
/// character back to where it came from), and each run of overlapping or
/// touching spans is replaced once, so no fragment of a secret survives a
/// secret that contains another.
String redactViera(String text, {Iterable<String> secrets = const []}) {
  if (text.isEmpty) return text;
  final forms = <String>{
    for (final s in secrets) ...[s, s.trim()],
  }..removeWhere((f) => f.trim().isEmpty);
  final ranges = <(int, int)>[];
  _View? view = _View(text);
  for (var depth = 0; view != null && depth <= _decodeDepth; depth++) {
    ranges
      ..addAll(view.find(forms))
      ..addAll(view.secretElementContents());
    view = view.decoded();
  }
  return _replaceRanges(text, ranges);
}

/// [error] with [redactViera] applied to its message, its raw device
/// message and its cause: a [WatchmeError] cause is redacted the same way,
/// and any other cause whose text changes is replaced by that text,
/// redacted. Returns [error] itself when nothing changed.
WatchmeError redactVieraError(WatchmeError error, Iterable<String> secrets) {
  final message = redactViera(error.message, secrets: secrets);
  final rawText = error.rawDeviceMessage;
  final raw = rawText == null ? null : redactViera(rawText, secrets: secrets);
  final Object? cause;
  switch (error.cause) {
    case final WatchmeError e:
      cause = redactVieraError(e, secrets);
    case null:
      cause = null;
    case final Object other:
      final text = other.toString();
      final clean = redactViera(text, secrets: secrets);
      cause = clean == text ? other : clean;
  }
  if (message == error.message &&
      raw == rawText &&
      identical(cause, error.cause)) {
    return error;
  }
  return WatchmeError(error.code, message, rawDeviceMessage: raw, cause: cause);
}

/// How many levels of escaping are decoded (`&amp;lt;` takes two).
const int _decodeDepth = 3;

final RegExp _secretElement = RegExp(
  '<(?:[A-Za-z_][\\w.-]*:)?(${vieraSecretElements.join('|')})'
  '(?:\\s[^>]*)?>(.*?)</(?:[A-Za-z_][\\w.-]*:)?\\1\\s*>',
  dotAll: true,
);

final RegExp _escape = RegExp(
  r'&(#x[0-9a-fA-F]{1,6}|#[0-9]{1,7}|amp|lt|gt|quot|apos);|%([0-9a-fA-F]{2})',
);

/// [text] with each run of overlapping or touching [ranges] (start
/// inclusive, end exclusive) replaced by one [redactedText].
String _replaceRanges(String text, List<(int, int)> ranges) {
  final spans = ranges.where((r) => r.$2 > r.$1).toList();
  if (spans.isEmpty) return text;
  spans.sort((a, b) => a.$1.compareTo(b.$1));
  final out = StringBuffer();
  var kept = 0;
  var (start, end) = spans.first;
  for (final (s, e) in spans.skip(1)) {
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
  _View(this.text)
    : _starts = List.generate(text.length, (i) => i),
      _ends = List.generate(text.length, (i) => i + 1);

  _View._(this.text, this._starts, this._ends);

  final String text;
  final List<int> _starts;
  final List<int> _ends;

  (int, int) _original(int start, int end) => (_starts[start], _ends[end - 1]);

  /// The original range behind each occurrence of each of [forms],
  /// overlapping occurrences included.
  Iterable<(int, int)> find(Set<String> forms) sync* {
    for (final form in forms) {
      for (
        var at = text.indexOf(form);
        at >= 0;
        at = text.indexOf(form, at + 1)
      ) {
        yield _original(at, at + form.length);
      }
    }
  }

  /// The original range behind the content of each secret element.
  Iterable<(int, int)> secretElementContents() sync* {
    for (final m in _secretElement.allMatches(text)) {
      final content = m.group(2)!;
      if (content.isEmpty) continue;
      final start = m.start + m.group(0)!.indexOf('>') + 1;
      yield _original(start, start + content.length);
    }
  }

  /// This text with one level of XML character references and
  /// percent-encoding decoded, or `null` when it has none. Each escape
  /// decodes to the code units of one character, which all come from the
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
      final decoded = _unescape(m);
      out.write(decoded);
      for (var i = 0; i < decoded.length; i++) {
        starts.add(_starts[m.start]);
        ends.add(_ends[m.end - 1]);
      }
      kept = m.end;
    }
    copy(kept, text.length);
    return _View._(out.toString(), starts, ends);
  }
}

String _unescape(Match m) {
  final percent = m.group(2);
  if (percent != null) {
    return String.fromCharCode(int.parse(percent, radix: 16));
  }
  final ref = m.group(1)!;
  if (ref.startsWith('#')) {
    final code = ref.startsWith('#x')
        ? int.parse(ref.substring(2), radix: 16)
        : int.parse(ref.substring(1));
    return code > 0x10ffff ? '�' : String.fromCharCode(code);
  }
  return switch (ref) {
    'amp' => '&',
    'lt' => '<',
    'gt' => '>',
    'quot' => '"',
    _ => "'",
  };
}
