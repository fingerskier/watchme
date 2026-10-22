import 'dart:convert';

// Wire facts for Sharp AQUOS IP control, from the Sharp operation manuals
// (US 2010-2014 and 4T-B command tables, EU 2011-2013, JP LC-40W35) and
// the reader rules of the protocol brief. Written for watchme; no code
// copied.

/// The login prompt. The TV sends it with no line terminator, so a line
/// reader never sees it: the driver looks for it inside unterminated input.
const String sharpLoginPrompt = 'Login:';

/// The password prompt, sent as `\r\nPassword:` with no terminator.
const String sharpPasswordPrompt = 'Password:';

/// The text a US 2012-2013 TV sent for a wrong login (single source; the
/// bytes around it are unverified).
const String sharpLoginMismatch = 'User Name or Password mismatch';

/// The TV's own fixed texts. Redaction keeps them verbatim, so a secret
/// that happens to be one of their words is never revealed by a cut.
const List<String> sharpFixedTexts = [
  sharpLoginMismatch,
  sharpLoginPrompt,
  sharpPasswordPrompt,
];

/// The longest reply the driver accepts; a longer one is a protocol error.
const int sharpMaxReplyBytes = 256;

/// The reply to an executed command.
const String sharpOk = 'OK';

/// The reply to a command the TV could not execute: a communication
/// error, an unknown command, a value out of range, or one it cannot run
/// now (standby, booting).
const String sharpErr = 'ERR';

final RegExp _command = RegExp(r'^[A-Z0-9]{4}$');
final RegExp _parameter = RegExp(r'^[0-9x ?\-]{0,4}$');

/// One request: the 4-character [command], then [parameter] aligned left
/// and filled with blanks to 4 characters, then CR.
///
/// `sharpFrame('VOLM', '30')` is `VOLM30  \r`. The manuals forbid right
/// alignment, so the parameter is never padded on the left.
String sharpFrame(String command, [String parameter = '']) {
  if (!_command.hasMatch(command)) {
    throw ArgumentError.value(command, 'command', 'must be 4 of A-Z, 0-9');
  }
  if (!_parameter.hasMatch(parameter)) {
    throw ArgumentError.value(
      parameter,
      'parameter',
      'must be at most 4 of 0-9, x, blank, ? and -',
    );
  }
  return '$command${parameter.padRight(4)}\r';
}

/// A query: [command] with `?` and three blanks, e.g. `POWR?   \r`.
String sharpQuery(String command) => sharpFrame(command, '?');

/// Whether [text] holds a sign that the TV refused a login: the mismatch
/// text (in any case), or a new `Login:` prompt.
bool isSharpLoginRefusal(String text) =>
    text.toLowerCase().contains('mismatch') || text.contains(sharpLoginPrompt);

/// Bytes from the TV, split into replies by the reader rules.
///
/// * Leading CR and LF are skipped (some firmware frames a reply as
///   `\r<reply>\r`, and one JP firmware sends a reply's CR at the start of
///   the next one).
/// * A reply ends at CR or LF; empty lines are dropped.
/// * What follows the last terminator stays [pending] until more arrives.
final class SharpReplyBuffer {
  final List<int> _bytes = [];

  /// Appends bytes received from the TV.
  void add(List<int> chunk) => _bytes.addAll(chunk);

  /// Whether nothing is buffered.
  bool get isEmpty => _bytes.isEmpty;

  /// Whether something is buffered.
  bool get isNotEmpty => _bytes.isNotEmpty;

  /// Removes and returns the next complete reply, or `null` when no
  /// terminated reply is buffered.
  String? takeReply() {
    _skipTerminators();
    final end = _bytes.indexWhere(_isTerminator);
    if (end < 0) return null;
    final line = _decode(_bytes.sublist(0, end));
    _bytes.removeRange(0, end + 1);
    return line.trim();
  }

  /// Whether a terminated reply is buffered.
  bool get hasReply {
    var i = 0;
    while (i < _bytes.length && _isTerminator(_bytes[i])) {
      i++;
    }
    for (; i < _bytes.length; i++) {
      if (_isTerminator(_bytes[i])) return true;
    }
    return false;
  }

  /// The unterminated text after any leading CR and LF.
  String get pending {
    _skipTerminators();
    return _decode(_bytes);
  }

  /// Everything buffered, as text, including terminators.
  String get text => _decode(_bytes);

  /// Removes and returns everything buffered.
  String takeAll() {
    final all = _decode(_bytes);
    _bytes.clear();
    return all;
  }

  /// Drops everything buffered.
  void clear() => _bytes.clear();

  void _skipTerminators() {
    var i = 0;
    while (i < _bytes.length && _isTerminator(_bytes[i])) {
      i++;
    }
    if (i > 0) _bytes.removeRange(0, i);
  }

  static bool _isTerminator(int b) => b == 0x0d || b == 0x0a;

  static String _decode(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
}

/// Splits [text] into the replies it holds and what is still pending, by
/// the rules of [SharpReplyBuffer]. For tests and tools.
({List<String> replies, String pending}) parseSharpReplies(String text) {
  final buffer = SharpReplyBuffer()..add(utf8.encode(text));
  final replies = <String>[];
  for (var r = buffer.takeReply(); r != null; r = buffer.takeReply()) {
    replies.add(r);
  }
  return (replies: replies, pending: buffer.pending);
}

/// One request a command is made of: a command and its parameter.
typedef SharpRequest = ({String command, String parameter});

final RegExp _digits = RegExp(r'^\d+$');

/// The requests that tune a US set to [channel], or `null` when the text
/// is not a channel the US command set can reach (the result is then
/// `Unsupported`).
///
/// * `7`, `135`: analogue, `DCCH` 1-135.
/// * `7.1`, `45.3`: digital air two-part, `DA2P` with a 2-digit major
///   (1-99) and a 2-digit minor (0-99): `DA2P0701`.
/// * `123.45`, `1.100`: digital cable two-part, `DC2U` (major 1-999) then
///   `DC2L` (minor 0-999, three digits): two requests, so a failure after
///   the first is a partial delivery.
/// * `05678`, `12345`: digital cable one-part, always five digits: `DC10`
///   below 10000, `DC11` (value - 10000) up to 16383.
/// * A bare 4-digit number is ambiguous between the forms and is refused.
List<SharpRequest>? sharpUsTuneRequests(String channel) {
  final ch = channel.trim();
  final dot = ch.indexOf('.');
  if (dot >= 0) {
    final majorText = ch.substring(0, dot);
    final minorText = ch.substring(dot + 1);
    if (!_digits.hasMatch(majorText) || !_digits.hasMatch(minorText)) {
      return null;
    }
    if (majorText.length > 3 || minorText.length > 3) return null;
    final major = int.parse(majorText);
    final minor = int.parse(minorText);
    if (major >= 1 && major <= 99 && minor <= 99 && minorText.length <= 2) {
      return [
        (
          command: 'DA2P',
          parameter:
              '${major.toString().padLeft(2, '0')}'
              '${minor.toString().padLeft(2, '0')}',
        ),
      ];
    }
    if (major >= 1 && major <= 999 && minor <= 999) {
      return [
        (command: 'DC2U', parameter: '$major'),
        (command: 'DC2L', parameter: minor.toString().padLeft(3, '0')),
      ];
    }
    return null;
  }
  if (!_digits.hasMatch(ch)) return null;
  if (ch.length <= 3) {
    final n = int.parse(ch);
    return n >= 1 && n <= 135 ? [(command: 'DCCH', parameter: '$n')] : null;
  }
  if (ch.length == 5) {
    final n = int.parse(ch);
    if (n < 10000) {
      return [(command: 'DC10', parameter: n.toString().padLeft(4, '0'))];
    }
    if (n <= 16383) {
      return [
        (command: 'DC11', parameter: (n - 10000).toString().padLeft(4, '0')),
      ];
    }
  }
  return null;
}

/// The request that tunes an EU set to digital channel [channel]
/// (`DTVD` 1-999), or `null`.
List<SharpRequest>? sharpEuTuneRequests(String channel) {
  final ch = channel.trim();
  if (!_digits.hasMatch(ch) || ch.length > 3) return null;
  final n = int.parse(ch);
  return n >= 1 && n <= 999 ? [(command: 'DTVD', parameter: '$n')] : null;
}

/// The MAC address a UPnP UDN carries in its node field, when the UDN is
/// a version-1 UUID and the node starts with a Sharp OUI; otherwise
/// `null`.
///
/// A hint for Wake-on-LAN only, never identity: hardware has not
/// confirmed that the node is the active interface's MAC.
String? sharpMacHintFromUdn(String? udn) {
  if (udn == null) return null;
  final match = RegExp(
    r'([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})',
    caseSensitive: false,
  ).firstMatch(udn);
  if (match == null) return null;
  if (match.group(3)![0] != '1') return null;
  final node = match.group(5)!.toLowerCase();
  final mac = [for (var i = 0; i < 12; i += 2) node.substring(i, i + 2)]
      .join(':');
  return sharpOuis.contains(mac.substring(0, 8)) ? mac : null;
}

/// OUIs registered to SHARP Corporation (Wireshark `manuf`). 7a:35:ea has
/// the locally-administered bit set, so it is kept but unlikely on a TV.
const Set<String> sharpOuis = {
  '00:17:5c', '00:1c:ee', '00:22:f3', '08:00:1f', '14:50:51', //
  '24:26:42', '24:31:84', '28:84:fa', '34:5a:06', '34:f6:2d',
  '68:79:ed', '78:1c:5a', '80:38:96', '8c:52:19', '90:e4:b0',
  '9c:c7:d1', 'a0:dd:e5', 'ac:a8:8e', 'bc:b1:81', 'f0:9f:fc',
  '7a:35:ea',
};
