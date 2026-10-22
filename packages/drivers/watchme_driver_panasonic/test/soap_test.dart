import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/src/constants.dart';
import 'package:watchme_driver_panasonic/src/keys.dart';
import 'package:watchme_driver_panasonic/src/soap.dart';

// Byte lengths below were captured from real traffic (research brief
// section 12.1); the prefix the driver uses (`u:`) is as long as the
// captures' `m:`.

const String _rendering = 'urn:schemas-upnp-org:service:RenderingControl:1';

void main() {
  group('request bodies', () {
    test('X_SendKey NRC_POWER-ONOFF is 315 bytes, on one line', () {
      final body = soapEnvelope(
        VieraUrn.nrc,
        'X_SendKey',
        '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>',
      );
      expect(utf8.encode(body), hasLength(315));
      expect(body, isNot(contains('\n')));
      expect(
        body,
        startsWith(
          '<?xml version="1.0" encoding="utf-8"?><s:Envelope '
          'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body><u:X_SendKey '
          'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">',
        ),
      );
    });

    test('GetMute and GetVolume are 324 and 328 bytes', () {
      const args = '<InstanceID>0</InstanceID><Channel>Master</Channel>';
      expect(
        utf8.encode(soapEnvelope(_rendering, 'GetMute', args)),
        hasLength(324),
      );
      expect(
        utf8.encode(soapEnvelope(_rendering, 'GetVolume', args)),
        hasLength(328),
      );
    });

    test('the header set of the field-proven clients, SOAPACTION quoted', () {
      expect(soapHeaders(VieraUrn.nrc, 'X_SendKey'), {
        'Accept': 'text/xml',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
        'SOAPACTION':
            '"urn:panasonic-com:service:p00NetworkControl:1#X_SendKey"',
        'Content-Type': 'text/xml; charset="utf-8"',
      });
    });

    test('encrypted command plaintext: eight-digit sequence, original '
        'order', () {
      expect(
        encryptedCommandPlaintext('12', 3, 'X_GetAppList', 'None'),
        '<X_SessionId>12</X_SessionId>'
        '<X_SequenceNumber>00000003</X_SequenceNumber>'
        '<X_OriginalCommand><u:X_GetAppList '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">None'
        '</u:X_GetAppList></X_OriginalCommand>',
      );
    });

    test('xmlEscape covers the five entities', () {
      expect(xmlEscape(r'''a&b<c>d"e'f'''), 'a&amp;b&lt;c&gt;d&quot;e&apos;f');
      expect(xmlUnescape('a&amp;b&lt;&#65;&#x42;&apos;'), "a&b<AB'");
    });
  });

  group('answers', () {
    const sendKeyAnswer =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        ' <s:Body>\n'
        '  <u:X_DisplayPinCodeResponse '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">\n'
        '   <X_ChallengeKey>A2ZrfRk5oJarHc6IHL5BpQ==</X_ChallengeKey>\n'
        '  </u:X_DisplayPinCodeResponse>\n'
        ' </s:Body>\n'
        '</s:Envelope>\n';

    test('xmlLeaf reads an out-argument from the 379-byte capture', () {
      expect(utf8.encode(sendKeyAnswer), hasLength(379));
      expect(
        xmlLeaf(sendKeyAnswer, 'X_ChallengeKey'),
        'A2ZrfRk5oJarHc6IHL5BpQ==',
      );
      expect(xmlLeaf(sendKeyAnswer, 'X_Missing'), isNull);
    });

    test('xmlLeaf takes fragments with several roots, any prefix, and '
        'decodes entities once', () {
      const fragment =
          '<u:X_GetAppListResponse xmlns:u="x"><X_AppList>'
          'vc_app&apos;Stop&apos;product_id=0010000200000001&apos;Netflix'
          '&apos;http://h/i&apos;Unknown&gt;</X_AppList>'
          '</u:X_GetAppListResponse>';
      expect(
        xmlLeaf(fragment, 'X_AppList'),
        "vc_app'Stop'product_id=0010000200000001'Netflix'http://h/i'Unknown>",
      );
      expect(xmlLeaf('<a>1</a><b>2</b>', 'b'), '2');
      // An undeclared prefix: the lenient fallback still finds it.
      expect(
        xmlLeaf('<v:X_AppInfo>vc_app:1:x</v:X_AppInfo>', 'X_AppInfo'),
        'vc_app:1:x',
      );
      expect(xmlLeaf('<q:X_AppInfo/>', 'X_AppInfo'), '');
    });

    test('xmlLeaf never throws on a malformed fragment with impossible '
        'character references', () {
      // Unparsable (an undeclared prefix, a dangling '<'), so the lenient
      // path decodes the references itself.
      expect(
        xmlLeaf('<v:X_AppInfo>a&#x110000;b</v:X_AppInfo><', 'X_AppInfo'),
        'a�b',
      );
      expect(
        xmlLeaf(
          '<v:X_AppInfo>&#99999999999999999999;</v:X_AppInfo><',
          'X_AppInfo',
        ),
        '�',
      );
      expect(xmlUnescape('&#x41;&#66;&amp;'), 'AB&');
    });

    test('parseSoapFault reads errorCode and errorDescription by local '
        'name, and copes with an empty body', () {
      const fault =
          '<?xml version="1.0"?>\n<s:Envelope xmlns:s="x"><s:Body><s:Fault>'
          '<faultcode>s:Client</faultcode><faultstring>UPnPError'
          '</faultstring><detail><UPnPError '
          'xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>600'
          '</errorCode><errorDescription>Invalid PIN Code</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';
      expect(parseSoapFault(fault), (
        code: 600,
        description: 'Invalid PIN Code',
      ));
      expect(parseSoapFault(''), (code: null, description: null));
      expect(parseSoapFault('Internal Server Error'), (
        code: null,
        description: null,
      ));
    });
  });

  group('what proves an answer', () {
    // The 301-byte X_SendKey answer of the brief, section 6.1.
    const sendKeyAnswer =
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        ' <s:Body>\n'
        '  <u:X_SendKeyResponse '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">'
        '</u:X_SendKeyResponse>\n'
        ' </s:Body>\n'
        '</s:Envelope>\n';

    test('a plain answer is a well-formed envelope with the response '
        'element in its Body, any prefix or none', () {
      expect(utf8.encode(sendKeyAnswer), hasLength(301));
      for (final body in [
        sendKeyAnswer,
        '<s:Envelope><s:Body><u:X_SendKeyResponse/></s:Body></s:Envelope>',
        '<Envelope><Header/><Body>\r\n<X_SendKeyResponse>\r\n'
            '</X_SendKeyResponse></Body></Envelope>\n',
      ]) {
        expect(isSoapAnswer(body, 'X_SendKey'), isTrue, reason: body);
      }
    });

    test('a plain answer is nothing the parser refuses, and nothing that '
        'merely mentions the response element', () {
      for (final body in [
        '<!-- diagnostic example: <X_SendKeyResponse/>',
        '<s:Envelope><s:Body><u:X_SendKeyResponse/>',
        '<s:Envelope><s:Body><u:X_SendKeyResponse/></s:Body></s:Envelope>'
            'trailing text',
        '<s:Envelope><s:Body><u:X_SendKeyResponse/></s:Body></s:Envelope>'
            '<![CDATA[x]]>',
        '<s:Envelope><s:Body><!-- <u:X_SendKeyResponse/> --></s:Body>'
            '</s:Envelope>',
        '<s:Envelope><s:Body><![CDATA[<u:X_SendKeyResponse/>]]></s:Body>'
            '</s:Envelope>',
        '<html><body><X_SendKeyResponse/></body></html>',
        '<html><body><br><X_SendKeyResponse/></body></html>',
        '<html><body>X_SendKeyResponse</body></html>',
        '<s:Envelope><s:Header><u:X_SendKeyResponse/></s:Header><s:Body/>'
            '</s:Envelope>',
        '<s:Envelope><s:Body><s:Fault><u:X_SendKeyResponse/></s:Fault>'
            '</s:Body></s:Envelope>',
        '<s:Envelope><s:Body><u:X_LaunchAppResponse/></s:Body></s:Envelope>',
        '<X_SendKeyResponse/>',
        '',
        'OK',
      ]) {
        expect(isSoapAnswer(body, 'X_SendKey'), isFalse, reason: body);
      }
    });

    test('out-arguments come from the response element, entities decoded '
        'once', () {
      final answer = soapAnswer(
        '<s:Envelope><s:Body><u:GetVolumeResponse><CurrentVolume>2&amp;0'
            '</CurrentVolume></u:GetVolumeResponse><CurrentMute>1</CurrentMute>'
            '</s:Body></s:Envelope>',
        'GetVolume',
      )!;
      expect(soapAnswerLeaf(answer, 'CurrentVolume'), '2&0');
      expect(soapAnswerLeaf(answer, 'CurrentMute'), isNull);
    });

    test('an encrypted acknowledgement: the documented wrappers, and '
        'nothing malformed or buried in other content', () {
      for (final fragment in [
        '<u:X_SendKeyResponse xmlns:u="x"></u:X_SendKeyResponse>',
        '<X_SendKeyResponse/>',
        '<X_OriginalResult><u:X_SendKeyResponse>'
            '</u:X_SendKeyResponse></X_OriginalResult>',
        '<X_SessionId>1</X_SessionId>\r\n<X_SequenceNumber>00000002'
            '</X_SequenceNumber>\r\n<X_OriginalResult><X_SendKeyResponse/>'
            '</X_OriginalResult>',
        '<?xml version="1.0"?><X_Data><X_SendKeyResponse/></X_Data>',
        '<s:Envelope><s:Body><u:X_SendKeyResponse/></s:Body></s:Envelope>',
      ]) {
        expect(
          isEncryptedAcknowledgement(fragment, 'X_SendKey'),
          isTrue,
          reason: fragment,
        );
      }
      for (final fragment in [
        '<!-- diagnostic example: <X_SendKeyResponse/>',
        '<X_OriginalResult><u:X_SendKeyResponse xmlns:u="x"/>',
        '<X_SendKeyResponse/><',
        '<html><body><X_SendKeyResponse/></body></html>',
        '<html><body><br><X_SendKeyResponse/></body></html>',
        '<![CDATA[<X_SendKeyResponse/>]]>',
        '</X_Data><X_SendKeyResponse/><X_Data>',
        '<X_LaunchAppResponse/>',
        'X_SendKeyResponse',
        '',
        // A Body that is not a top-level SOAP Envelope's (Codex round
        // three).
        '<html><diagnostic><Body><X_SendKeyResponse/></Body></diagnostic>'
            '</html>',
        '<X_Wrap><s:Envelope><s:Body><X_SendKeyResponse/></s:Body>'
            '</s:Envelope></X_Wrap>',
      ]) {
        expect(
          isEncryptedAcknowledgement(fragment, 'X_SendKey'),
          isFalse,
          reason: fragment,
        );
      }
    });

    test('well-formed means what XML 1.0 says, beyond what the parser '
        'checks', () {
      // Codex round three: the parser reads all of these.
      String answer(String inside, {String attributes = ''}) =>
          '<s:Envelope$attributes><s:Body><u:X_SendKeyResponse>$inside'
          '</u:X_SendKeyResponse></s:Body></s:Envelope>';
      for (final xml in [
        answer('&'),
        answer('a & b'),
        answer('&nbsp;'),
        answer('&#;'),
        answer('&amp'),
        answer('', attributes: ' a="1" a="2"'),
        '<!-- a -- b -->${answer('')}',
        '<!-- ends in a dash --->${answer('')}',
        answer('\u0001'),
        answer('\u001f'),
      ]) {
        expect(isSoapAnswer(xml, 'X_SendKey'), isFalse, reason: xml);
        expect(
          isEncryptedAcknowledgement(xml, 'X_SendKey'),
          isFalse,
          reason: xml,
        );
      }
      for (final xml in [
        answer('&amp; &lt; &gt; &quot; &apos; &#65; &#x41;'),
        answer('tab\tCR\rLF\n'),
        answer('<![CDATA[a & b -- c]]>'),
        '<!-- a & b - c -->${answer('')}',
        '<?pi a & b?>${answer('')}',
        answer('', attributes: ' a="1" b="2" x:a="3"'),
      ]) {
        expect(isSoapAnswer(xml, 'X_SendKey'), isTrue, reason: xml);
        expect(
          isEncryptedAcknowledgement(xml, 'X_SendKey'),
          isTrue,
          reason: xml,
        );
      }
    });

    test('an encrypted read: its leaf anywhere in a well-formed fragment, '
        'with or without a response element', () {
      for (final fragment in [
        '<X_AppInfo>vc_app:1:a</X_AppInfo>',
        '<v:X_AppInfo>vc_app:1:a</v:X_AppInfo>',
        '<X_SessionId>1</X_SessionId><X_OriginalResult><u:X_GetAppInfoResponse>'
            '<X_AppInfo>vc_app:1:a</X_AppInfo></u:X_GetAppInfoResponse>'
            '</X_OriginalResult>',
      ]) {
        expect(
          encryptedAnswerLeaf(fragment, 'X_AppInfo'),
          'vc_app:1:a',
          reason: fragment,
        );
      }
      expect(encryptedAnswerLeaf('<X_AppInfo/>', 'X_AppInfo'), '');
      for (final fragment in [
        '<X_AppInfo>vc_app:1:a',
        '<X_AppInfo>vc_app:1:a</X_AppInfo><',
        '<!-- <X_AppInfo>vc_app:1:a</X_AppInfo> -->',
        '<X_AppInfo><b>vc_app:1:a</b></X_AppInfo>',
        '<u:X_GetAppInfoResponse/>',
      ]) {
        expect(
          encryptedAnswerLeaf(fragment, 'X_AppInfo'),
          isNull,
          reason: fragment,
        );
      }
    });

    test('X_EncResult comes from a well-formed answer only, its wrapper '
        'unchecked', () {
      expect(encryptedResult('<X_EncResult>QUJD</X_EncResult>'), 'QUJD');
      expect(
        encryptedResult(
          '<s:Envelope><s:Body><u:X_EncryptedCommandResponse>'
          '<X_EncResult>QUJD</X_EncResult></u:X_EncryptedCommandResponse>'
          '</s:Body></s:Envelope>',
        ),
        'QUJD',
      );
      expect(
        encryptedResult(
          '<s:Envelope><s:Body><u:X_EncryptedCommandResponse>'
          '<X_EncResult>QUJD</X_EncResult>',
        ),
        isNull,
      );
      expect(encryptedResult('<root/>'), isNull);
    });
  });

  group('descriptions', () {
    // The element content of a real TX-49DX600EA description.
    const ddd = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:vli="urn:schemas-panasonic-com:vli" xmlns:viera="urn:schemas-panasonic-com:viera">
 <specVersion><major>1</major><minor>0</minor></specVersion>
 <device>
  <deviceType>urn:panasonic-com:device:p00RemoteController:1</deviceType>
  <friendlyName>49DX600_Series</friendlyName>
  <manufacturer>Panasonic</manufacturer>
  <modelName>Panasonic VIErA</modelName>
  <modelNumber>TX-49DX600EA</modelNumber>
  <UDN>uuid:4D454930-0200-1000-8001-A81374B30314</UDN>
  <viera:X_VERSION>NRC-3.00</viera:X_VERSION>
  <viera:X_NRC_ID>2824FF385E27</viera:X_NRC_ID>
  <viera:X_NRCCAP>VR_POWER,VR_DMR,VR_LAUNCH,VR_WOL</viera:X_NRCCAP>
  <serviceList><service><serviceType>urn:panasonic-com:service:p00NetworkControl:1</serviceType></service></serviceList>
 </device>
</root>''';

    test('reads identity, the NRC version and capabilities', () {
      final d = VieraDescription.parse(ddd);
      expect(d.isRemoteController, isTrue);
      expect(d.friendlyName, '49DX600_Series');
      expect(d.displayName, '49DX600 Series');
      expect(d.manufacturer, 'Panasonic');
      expect(d.modelName, 'Panasonic VIErA');
      expect(d.modelNumber, 'TX-49DX600EA');
      expect(d.stableId, 'uuid:4d454930-0200-1000-8001-a81374b30314');
      expect(d.nrcVersion, 'NRC-3.00');
      expect(d.nrcCapabilities, {'VR_POWER', 'VR_DMR', 'VR_LAUNCH', 'VR_WOL'});
    });

    test('MAC candidates come from the UDN tail and X_NRC_ID', () {
      final d = VieraDescription.parse(ddd);
      expect(d.udnMacCandidate, 'a8:13:74:b3:03:14');
      expect(d.nrcIdMacCandidate, '28:24:ff:38:5e:27');
    });

    test('a description of another device is not a remote controller', () {
      final d = VieraDescription.parse(
        '<root><device><deviceType>urn:schemas-upnp-org:device:'
        'MediaRenderer:1</deviceType></device></root>',
      );
      expect(d.isRemoteController, isFalse);
      expect(d.nrcCapabilities, isNull);
      expect(() => VieraDescription.parse('<nope'), throwsFormatException);
    });

    test('encryption is decided by X_GetEncryptSessionId', () {
      expect(isEncryptedService('<name>X_GetEncryptSessionId</name>'), isTrue);
      expect(isEncryptedService('<name>X_SendKey</name>'), isFalse);
    });
  });

  group('apps', () {
    test('parses the app list grammar, trimming line breaks', () {
      const list =
          "vc_app'Unknown'product_id=0387878700000102'Apps Market'"
          "http://10.0.0.5:55000/nrc/app_icon/0387878700000102'Unknown>\n"
          "vc_app'Stop'product_id=0010000200000001'Netflix'"
          "http://10.0.0.5:55000/nrc/app_icon/0010000200000001'Unknown>\n"
          "garbage>"
          "vc_app'Unknown'product_id=007777770018A002'Browser: Web'"
          "http://10.0.0.5:55000/nrc/app_icon/007777770018A002'Unknown>";
      final apps = parseVieraAppList(list);
      expect(apps.map((a) => (a.id, a.name)), [
        ('0387878700000102', 'Apps Market'),
        ('0010000200000001', 'Netflix'),
        ('007777770018A002', 'Browser: Web'),
      ]);
      expect(
        apps.first.icon.toString(),
        'http://10.0.0.5:55000/nrc/app_icon/0387878700000102',
      );
      expect(parseVieraAppList(''), isEmpty);
    });

    test('parses X_AppInfo; empty means nothing known', () {
      expect(
        parseVieraAppInfo('vc_app:7:product_id=0010000200000001:Netflix'),
        const AppInfo(id: '0010000200000001', name: 'Netflix'),
      );
      expect(
        parseVieraAppInfo('vc_app:1:product_id=1:A: B'),
        const AppInfo(id: '1', name: 'A: B'),
      );
      expect(parseVieraAppInfo(''), isNull);
    });
  });

  group('keys', () {
    test('every mapped key exists; unmappable ones are absent', () {
      expect(vieraKeyNames[RemoteKey.select], 'ENTER');
      expect(vieraKeyNames[RemoteKey.back], 'RETURN');
      expect(vieraKeyNames[RemoteKey.power], 'POWER');
      for (final k in [
        RemoteKey.search,
        RemoteKey.backspace,
        RemoteKey.playPause,
        RemoteKey.instantReplay,
        RemoteKey.inputAv1,
        RemoteKey.powerOn,
        RemoteKey.powerOff,
      ]) {
        expect(vieraKeyName(k), isNull, reason: k.name);
      }
    });

    test('guide and captions follow the market of the model number', () {
      expect(vieraKeyName(RemoteKey.guide, model: 'TX-55GZ1500'), 'EPG');
      expect(vieraKeyName(RemoteKey.guide, model: 'TC-50AS650U'), 'GUIDE');
      expect(vieraKeyName(RemoteKey.captions, model: 'TH-55GX740H'), 'STTL');
      expect(vieraKeyName(RemoteKey.captions, model: 'tc-p50st50'), 'CC');
      expect(vieraKeyName(RemoteKey.guide), 'EPG');
    });

    test('key events: click, hold and release', () {
      expect(vieraKeyEvent('UP', KeyAction.click), 'NRC_UP-ONOFF');
      expect(vieraKeyEvent('UP', KeyAction.down), 'NRC_UP-ON');
      expect(vieraKeyEvent('UP', KeyAction.up), 'NRC_UP-OFF');
      expect(vieraHoldableKeys, isNot(contains(RemoteKey.power)));
    });

    test('input ids', () {
      expect(vieraInputKey('HDMI2'), 'HDMI2');
      expect(vieraInputKey('tuner'), 'TV');
      expect(vieraInputKey('av1'), isNull);
    });
  });
}
