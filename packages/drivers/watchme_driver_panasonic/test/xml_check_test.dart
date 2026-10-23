import 'package:test/test.dart';
import 'package:watchme_driver_panasonic/src/xml_check.dart';

void main() {
  group('isWellFormedXml', () {
    test('accepts the shapes a VIERA sends and what XML allows', () {
      for (final xml in [
        '<a/>',
        '<a></a>',
        '﻿<a/>',
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
