// A strict check that a TV's answer is one well-formed XML 1.0 document
// (https://www.w3.org/TR/xml/, sections 2 and 3), written for watchme. The
// xml package's parser is lenient: it reads unquoted and valueless
// attributes, `<` in an attribute value, `]]>` in text, references to
// characters XML forbids and undefined entities. An answer like that is
// not XML, so it must not pass as a TV's acknowledgement.
//
// A TV sends no document type declaration, so one is refused, and only the
// five predefined entities exist.

/// Whether [xml] is one well-formed XML 1.0 document with no document type
/// declaration. A leading byte order mark is allowed.
bool isWellFormedXml(String xml) {
  try {
    _XmlChecker(xml)._document();
    return true;
  } on _Malformed {
    return false;
  }
}

/// Where the content after the XML declaration at [start] of [xml]
/// begins: [start] itself when there is no declaration there, `null` when
/// there is one and it breaks the XML 1.0 grammar. For answers checked
/// after their declaration is removed, such as the decrypted fragments of
/// encrypted commands.
int? xmlDeclarationEnd(String xml, int start) {
  final checker = _XmlChecker(xml).._i = start;
  if (!checker._atDeclaration) return start;
  try {
    checker._xmlDeclaration();
    return checker._i;
  } on _Malformed {
    return null;
  }
}

final class _Malformed implements Exception {
  const _Malformed();
}

final RegExp _versionNumber = RegExp(r'^1\.[0-9]+$');
final RegExp _encodingName = RegExp(r'^[A-Za-z][A-Za-z0-9._-]*$');
final RegExp _standalone = RegExp(r'^(yes|no)$');

const Set<String> _predefinedEntities = {'amp', 'lt', 'gt', 'quot', 'apos'};

final class _XmlChecker {
  _XmlChecker(this._s);

  final String _s;
  int _i = 0;

  Never _bad() => throw const _Malformed();

  bool _at(String text) => _s.startsWith(text, _i);

  /// document ::= prolog element Misc*, with no doctypedecl.
  void _document() {
    for (final c in _s.runes) {
      if (!_isChar(c)) _bad();
    }
    if (_at('\uFEFF')) _i++;
    if (_atDeclaration) _xmlDeclaration();
    _misc();
    if (!_at('<') || _at('<!')) _bad();
    _element();
    _misc();
    if (_i != _s.length) _bad();
  }

  /// An XMLDecl starts here: only at the very start of a document, and
  /// `<?xml` without a space after it is a processing instruction whose
  /// target XML reserves.
  bool get _atDeclaration => _at('<?xml') && _isSpaceAt(_i + 5);

  /// XMLDecl ::= '<?xml' VersionInfo EncodingDecl? SDDecl? S? '?>', with
  /// VersionNum ::= '1.' [0-9]+, EncName ::= [A-Za-z] ([A-Za-z0-9._] |
  /// '-')* and standalone 'yes' or 'no', in that order, each once.
  void _xmlDeclaration() {
    _i += 5;
    _skipSpace();
    _expect('version');
    _pseudoAttributeValue(_versionNumber);
    var spaced = _skipSpace();
    if (spaced && _at('encoding')) {
      _i += 8;
      _pseudoAttributeValue(_encodingName);
      spaced = _skipSpace();
    }
    if (spaced && _at('standalone')) {
      _i += 10;
      _pseudoAttributeValue(_standalone);
      _skipSpace();
    }
    _expect('?>');
  }

  /// Eq, then a quoted value matching [grammar].
  void _pseudoAttributeValue(RegExp grammar) {
    _skipSpace();
    _expect('=');
    _skipSpace();
    if (_i >= _s.length) _bad();
    final quote = _s[_i];
    if (quote != '"' && quote != "'") _bad();
    final end = _s.indexOf(quote, _i + 1);
    if (end < 0 || !grammar.hasMatch(_s.substring(_i + 1, end))) _bad();
    _i = end + 1;
  }

  /// Misc ::= Comment | PI | S
  void _misc() {
    while (_i < _s.length) {
      if (_at('<!--')) {
        _comment();
      } else if (_at('<?')) {
        _processingInstruction();
      } else if (_isSpaceAt(_i)) {
        _i++;
      } else {
        return;
      }
    }
  }

  /// element and its content, without recursion: an answer nested very
  /// deep must not exhaust the stack.
  void _element() {
    final open = <String>[];
    final root = _startTag();
    if (root == null) return;
    open.add(root);
    while (open.isNotEmpty) {
      _charData();
      if (_i >= _s.length) _bad();
      if (_at('</')) {
        _i += 2;
        final name = _name();
        _skipSpace();
        _expect('>');
        if (open.removeLast() != name) _bad();
      } else if (_at('<!--')) {
        _comment();
      } else if (_at('<![CDATA[')) {
        _i += 9;
        _skipPast(']]>');
      } else if (_at('<?')) {
        _processingInstruction();
      } else if (_at('&')) {
        _reference();
      } else {
        final name = _startTag();
        if (name != null) open.add(name);
      }
    }
  }

  /// STag or EmptyElemTag. Returns the element's name, or `null` for an
  /// empty-element tag, which has no content to close.
  String? _startTag() {
    _expect('<');
    final name = _name();
    final attributes = <String>{};
    while (true) {
      final spaced = _skipSpace();
      if (_at('/>')) {
        _i += 2;
        return null;
      }
      if (_at('>')) {
        _i++;
        return name;
      }
      // Attributes are separated from the name and from each other.
      if (!spaced) _bad();
      if (!attributes.add(_name())) _bad();
      _skipSpace();
      _expect('=');
      _skipSpace();
      _attributeValue();
    }
  }

  /// AttValue: quoted, with no `<` and every `&` a reference.
  void _attributeValue() {
    if (_i >= _s.length) _bad();
    final quote = _s[_i];
    if (quote != '"' && quote != "'") _bad();
    _i++;
    while (true) {
      if (_i >= _s.length) _bad();
      final c = _s[_i];
      if (c == quote) {
        _i++;
        return;
      }
      if (c == '<') _bad();
      if (c == '&') {
        _reference();
      } else {
        _i++;
      }
    }
  }

  /// CharData: text up to the next `<` or `&`, which may not hold `]]>`.
  void _charData() {
    while (_i < _s.length) {
      final c = _s[_i];
      if (c == '<' || c == '&') return;
      if (_at(']]>')) _bad();
      _i++;
    }
  }

  /// Reference: one of the predefined entities, or a character reference
  /// to a character XML allows.
  void _reference() {
    _expect('&');
    if (_at('#x')) {
      _i += 2;
      _characterReference(16, RegExp('[0-9a-fA-F]'));
    } else if (_at('#')) {
      _i++;
      _characterReference(10, RegExp('[0-9]'));
    } else {
      if (!_predefinedEntities.contains(_name())) _bad();
      _expect(';');
    }
  }

  void _characterReference(int radix, RegExp digit) {
    final start = _i;
    while (_i < _s.length && digit.hasMatch(_s[_i])) {
      _i++;
    }
    final digits = _s.substring(start, _i).replaceFirst(RegExp('^0+'), '');
    _expect(';');
    if (_i - 1 == start) _bad(); // no digits at all
    // 0x10FFFF has 6 hex digits and 7 decimal ones: anything longer is out
    // of range, and must not overflow the parse.
    if (digits.length > (radix == 16 ? 6 : 7)) _bad();
    final value = digits.isEmpty ? 0 : int.parse(digits, radix: radix);
    if (!_isChar(value)) _bad();
  }

  /// Comment: no `--` inside, and not ending in `-`.
  void _comment() {
    _i += 4;
    final end = _s.indexOf('-->', _i);
    if (end < 0) _bad();
    final body = _s.substring(_i, end);
    if (body.contains('--') || body.endsWith('-')) _bad();
    _i = end + 3;
  }

  /// PI: a target that is not `xml` in any case, then space before any
  /// content.
  void _processingInstruction() {
    _i += 2;
    if (_name().toLowerCase() == 'xml') _bad();
    if (_at('?>')) {
      _i += 2;
      return;
    }
    if (!_isSpaceAt(_i)) _bad();
    _skipPast('?>');
  }

  String _name() {
    final start = _i;
    if (_i >= _s.length || !_isNameStart(_runeAt())) _bad();
    _advanceRune();
    while (_i < _s.length && _isNameChar(_runeAt())) {
      _advanceRune();
    }
    return _s.substring(start, _i);
  }

  int _runeAt() {
    final c = _s.codeUnitAt(_i);
    if (c >= 0xD800 && c <= 0xDBFF && _i + 1 < _s.length) {
      final low = _s.codeUnitAt(_i + 1);
      return 0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00);
    }
    return c;
  }

  void _advanceRune() => _i += _runeAt() > 0xFFFF ? 2 : 1;

  bool _skipSpace() {
    final start = _i;
    while (_isSpaceAt(_i)) {
      _i++;
    }
    return _i > start;
  }

  void _skipPast(String text) {
    final end = _s.indexOf(text, _i);
    if (end < 0) _bad();
    _i = end + text.length;
  }

  void _expect(String text) {
    if (!_at(text)) _bad();
    _i += text.length;
  }

  bool _isSpaceAt(int i) {
    if (i >= _s.length) return false;
    final c = _s.codeUnitAt(i);
    return c == 0x20 || c == 0x9 || c == 0xD || c == 0xA;
  }

  /// Char ::= #x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] |
  /// [#x10000-#x10FFFF]
  static bool _isChar(int c) =>
      c == 0x9 ||
      c == 0xA ||
      c == 0xD ||
      (c >= 0x20 && c <= 0xD7FF) ||
      (c >= 0xE000 && c <= 0xFFFD) ||
      (c >= 0x10000 && c <= 0x10FFFF);

  static bool _isNameStart(int c) =>
      c == 0x3A || // :
      (c >= 0x41 && c <= 0x5A) || // A-Z
      c == 0x5F || // _
      (c >= 0x61 && c <= 0x7A) || // a-z
      (c >= 0xC0 && c <= 0xD6) ||
      (c >= 0xD8 && c <= 0xF6) ||
      (c >= 0xF8 && c <= 0x2FF) ||
      (c >= 0x370 && c <= 0x37D) ||
      (c >= 0x37F && c <= 0x1FFF) ||
      (c >= 0x200C && c <= 0x200D) ||
      (c >= 0x2070 && c <= 0x218F) ||
      (c >= 0x2C00 && c <= 0x2FEF) ||
      (c >= 0x3001 && c <= 0xD7FF) ||
      (c >= 0xF900 && c <= 0xFDCF) ||
      (c >= 0xFDF0 && c <= 0xFFFD) ||
      (c >= 0x10000 && c <= 0xEFFFF);

  static bool _isNameChar(int c) =>
      _isNameStart(c) ||
      c == 0x2D || // -
      c == 0x2E || // .
      (c >= 0x30 && c <= 0x39) || // 0-9
      c == 0xB7 ||
      (c >= 0x300 && c <= 0x36F) ||
      (c >= 0x203F && c <= 0x2040);
}
