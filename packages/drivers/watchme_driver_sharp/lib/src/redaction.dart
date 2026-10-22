import 'package:watchme_core/watchme_core.dart';

import 'protocol.dart';

/// What a redacted secret is replaced with: watchme_core's [redactedText].
const String sharpRedacted = redactedText;

/// [text] with every occurrence of every one of [secrets] (verbatim, and
/// trimmed) replaced by [sharpRedacted].
///
/// Occurrences are found in the original text first, overlapping ones
/// included, and each run of overlapping or touching ones is replaced
/// once, so a secret inside another leaves nothing of either behind.
///
/// The TV's own fixed texts ([sharpFixedTexts]: `Login:`, `Password:`,
/// `User Name or Password mismatch`) are kept verbatim: an occurrence that
/// lies wholly inside one is not a leak, while cutting it would reveal
/// which of its words the secret is (a password `Password`, say).
String redactSharpSecrets(String text, Iterable<String> secrets) {
  final forms = <String>{
    for (final s in secrets) ...[s, s.trim()],
  }..removeWhere((f) => f.trim().isEmpty);
  if (forms.isEmpty || text.isEmpty) return text;
  final protected = <(int, int)>[
    for (final fixed in sharpFixedTexts)
      for (final at in _occurrences(text, fixed)) (at, at + fixed.length),
  ];
  final ranges = <(int, int)>[
    for (final form in forms)
      for (final at in _occurrences(text, form))
        if (!protected.any((p) => p.$1 <= at && at + form.length <= p.$2))
          (at, at + form.length),
  ];
  return _replaceRanges(text, ranges);
}

Iterable<int> _occurrences(String text, String form) sync* {
  for (var at = text.indexOf(form); at >= 0; at = text.indexOf(form, at + 1)) {
    yield at;
  }
}

/// [text] with each run of overlapping or touching [ranges] (start
/// inclusive, end exclusive) replaced by one [sharpRedacted].
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
      ..write(sharpRedacted);
    kept = end;
    (start, end) = (s, e);
  }
  return (out
        ..write(text.substring(kept, start))
        ..write(sharpRedacted)
        ..write(text.substring(end)))
      .toString();
}

/// [error] with [redactSharpSecrets] applied to its message, its raw
/// device message and its cause: a [WatchmeError] cause is redacted the
/// same way, and any other cause whose text holds a secret is replaced by
/// that text redacted. Returns [error] itself when nothing changed.
WatchmeError redactSharpError(WatchmeError error, Iterable<String> secrets) {
  final list = secrets.toList();
  if (list.every((s) => s.trim().isEmpty)) return error;
  final message = redactSharpSecrets(error.message, list);
  final rawText = error.rawDeviceMessage;
  final raw = rawText == null ? null : redactSharpSecrets(rawText, list);
  final Object? cause;
  switch (error.cause) {
    case final WatchmeError e:
      cause = redactSharpError(e, list);
    case null:
      cause = null;
    case final Object other:
      final text = other.toString();
      final clean = redactSharpSecrets(text, list);
      cause = clean == text ? other : clean;
  }
  if (message == error.message &&
      raw == rawText &&
      identical(cause, error.cause)) {
    return error;
  }
  return WatchmeError(error.code, message, rawDeviceMessage: raw, cause: cause);
}
