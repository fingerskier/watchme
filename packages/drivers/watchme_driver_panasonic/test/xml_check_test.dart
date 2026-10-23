import 'package:test/test.dart';
import 'package:watchme_driver_panasonic/src/xml_check.dart';

void main() {
  group('isWellFormedXml', () {
    test('accepts the shapes a VIERA sends and what XML allows', () {
      for (final xml in [
        '<a/>',
        '<a></a>',
        '\uFEFF<a/>',
        '<?xml version="1.0" encoding="utf-8"?>\n<s:Envelope '
            'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:X_SendKeyResponse xmlns:u="urn:x"/></s:Body>'
            '</s:Envelope>\n',
        "<X_AppList>vc_app&apos;Stop&apos;product_id=0387878700000032"
            "&apos;Netflix&apos;</X_AppList>",
        '<a b="1" c=\'2\' d = "3"/>',
        '<a b="&amp;&lt;&gt;&quot;&apos;&#65;&#x41;&#x10FFFF;&#0065;"/>',
        '<a>&#9;&#10;&#13;&#x20;&#xD7FF;&#xE000;&#xFFFD;&#x10000;</a>',
        '<a>text ] ]] > tab\tCR\rLF\n</a>',
        '<a><![CDATA[a & b < c -- d ]]]></a>',
        '<!-- before --><a><!-- in - side --></a><!-- after -->',
        '<?pi a & b?><a><?other?></a>',
        '<a><b/><c>x</c><d e="f"/></a>',
        '<ü:é ö="1">日本 😀</ü:é>',
        '<a b="1" x:b="2"/>',
      ]) {
        expect(isWellFormedXml(xml), isTrue, reason: xml);
      }
    });

    test('refuses what XML 1.0 does not allow, though a lenient parser '
        'reads it', () {
      for (final xml in [
        '',
        'text',
        '<a>',
        '<a></b>',
        '<a/><b/>',
        '<a/>trailing',
        'leading<a/>',
        '<a>&</a>',
        '<a>a & b</a>',
        '<a>&nbsp;</a>',
        '<a>&amp</a>',
        '<a>&#;</a>',
        '<a>&#x;</a>',
        '<a>&#X41;</a>',
        '<a>&#0;</a>',
        '<a>&#x1F;</a>',
        '<a>&#xD800;</a>',
        '<a>&#xFFFE;</a>',
        '<a>&#x110000;</a>',
        '<a>&#99999999999999999999;</a>',
        '<a>]]></a>',
        '<a>\u0001</a>',
        '<a>\uD800</a>',
        '<a>￿</a>',
        '<a b=value/>',
        '<a b/>',
        '<a b="<"/>',
        '<a b="&"/>',
        '<a b="1"c="2"/>',
        '<a b="1" b="2"/>',
        '<a b="1/>',
        '<!-- a -- b --><a/>',
        '<!-- ends in a dash ---><a/>',
        '<!-- unterminated <a/>',
        '<a><![CDATA[ unterminated </a>',
        '<![CDATA[x]]><a/>',
        '<?xml version="1.0"?><?xml version="1.0"?><a/>',
        ' <?xml version="1.0"?><a/>',
        '<a><?xml x?></a>',
        '<?pi<a/>',
        '<!DOCTYPE a><a/>',
        '<1a/>',
        '<a></a >x',
        '< a/>',
      ]) {
        expect(isWellFormedXml(xml), isFalse, reason: xml);
      }
    });

    test('an XML declaration follows the XML 1.0 grammar', () {
      // Codex round five: the declaration was skipped unchecked.
      for (final declaration in [
        '<?xml version="1.0"?>',
        "<?xml version='1.0'?>",
        '<?xml version="1.1" ?>',
        '<?xml version = "1.0" encoding = "utf-8"?>',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>',
        '<?xml version="1.0" standalone="no"?>',
        '<?xml\tversion="1.0"\nencoding="ISO-8859-1"?>',
      ]) {
        expect(
          isWellFormedXml('$declaration<a/>'),
          isTrue,
          reason: declaration,
        );
        expect(
          xmlDeclarationEnd('$declaration<a/>', 0),
          declaration.length,
          reason: declaration,
        );
      }
      for (final declaration in [
        '<?xml ?>',
        '<?xml version="1.0" foo="bar"?>',
        '<?xml encoding="utf-8" version="1.0"?>',
        '<?xml version="1.0" standalone="maybe"?>',
        '<?xml version="1.0" encoding="8utf"?>',
        '<?xml version="banana"?>',
        '<?xml version="1.0" version="1.0"?>',
        '<?xml version="1."?>',
        '<?xml version="2.0"?>',
        '<?xml version=1.0?>',
        '<?xml version="1.0\'?>',
        '<?xml version="1.0"encoding="utf-8"?>',
        '<?xml version="1.0" standalone="yes" encoding="utf-8"?>',
        '<?xml version="1.0"',
      ]) {
        expect(
          isWellFormedXml('$declaration<a/>'),
          isFalse,
          reason: declaration,
        );
        expect(
          xmlDeclarationEnd('$declaration<a/>', 0),
          isNull,
          reason: declaration,
        );
      }
      // No declaration: the content starts where it was asked about.
      expect(xmlDeclarationEnd('  <a/>', 2), 2);
      expect(xmlDeclarationEnd('<?xml-stylesheet x?><a/>', 0), 0);
      expect(xmlDeclarationEnd('<a/>', 4), 4);
      expect(() => xmlDeclarationEnd('<a/>', -1), throwsRangeError);
      expect(() => xmlDeclarationEnd('<a/>', 5), throwsRangeError);
    });

    test('a deeply nested answer is checked without exhausting the stack', () {
      const depth = 200000;
      final xml = '${'<a>' * depth}${'</a>' * depth}';
      expect(isWellFormedXml(xml), isTrue);
      expect(
        isWellFormedXml('${'<a>' * depth}${'</a>' * (depth - 1)}'),
        isFalse,
      );
    });
  });
}
