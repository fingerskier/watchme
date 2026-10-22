@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';
import 'package:xml/xml.dart';

/// A parsed raw HTTP answer.
typedef _Answer = ({
  String statusLine,
  List<(String, String)> headers,
  String body,
  String raw,
});

const String _nrc = '/nrc/control_0';
const String _dmr = '/dmr/control_0';
const String _pac = '/pac/control_0';

/// The standard request body (one line, `u:` prefix).
String _envelope(String urn, String action, String args, {String p = 'u'}) =>
    '<?xml version="1.0" encoding="utf-8"?><s:Envelope '
    'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
    '<$p:$action xmlns:$p="$urn">$args</$p:$action></s:Body></s:Envelope>';

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  late PanasonicSimulator sim;

  Future<PanasonicSimulator> startSim(
    PanasonicSimulator s, {
    int? wolPort,
  }) async {
    await s.start(wolPort: wolPort);
    addTearDown(s.stop);
    return sim = s;
  }

  /// Sends [method] [path] over a raw socket and reads until the simulator
  /// closes the connection.
  Future<_Answer> raw(
    String method,
    String path, {
    List<(String, String)> headers = const [],
    String body = '',
    bool hostHeader = true,
  }) async {
    final socket = await Socket.connect(sim.host, sim.port);
    final bytes = utf8.encode(body);
    final head = StringBuffer('$method $path HTTP/1.1\r\n');
    if (hostHeader) head.write('Host: ${sim.host}:${sim.port}\r\n');
    for (final (n, v) in headers) {
      head.write('$n: $v\r\n');
    }
    if (body.isNotEmpty || method == 'POST') {
      head.write('Content-Length: ${bytes.length}\r\n');
    }
    head.write('\r\n');
    socket.add([...utf8.encode(head.toString()), ...bytes]);
    final out = await socket
        .fold<List<int>>([], (a, c) => a..addAll(c))
        .timeout(const Duration(seconds: 10));
    socket.destroy();
    final text = utf8.decode(out);
    final split = text.indexOf('\r\n\r\n');
    final lines = text.substring(0, split).split('\r\n');
    return (
      statusLine: lines.first,
      headers: [
        for (final l in lines.skip(1))
          (
            l.substring(0, l.indexOf(':')),
            l.substring(l.indexOf(':') + 1).trimLeft(),
          ),
      ],
      body: text.substring(split + 4),
      raw: text,
    );
  }

  Future<_Answer> soap(
    String path,
    String urn,
    String action,
    String args, {
    String prefix = 'u',
  }) => raw(
    'POST',
    path,
    headers: [
      ('Accept', 'text/xml'),
      ('Cache-Control', 'no-cache'),
      ('Pragma', 'no-cache'),
      ('SOAPACTION', '"$urn#$action"'),
      ('Content-Type', 'text/xml; charset="utf-8"'),
    ],
    body: _envelope(urn, action, args, p: prefix),
  );

  Future<_Answer> nrc(String action, [String args = '']) =>
      soap(_nrc, panasonicSimNrcUrn, action, args);

  Future<_Answer> dmr(String action, [String args = '']) => soap(
    _dmr,
    panasonicSimRenderingControlUrn,
    action,
    '<InstanceID>0</InstanceID><Channel>Master</Channel>$args',
  );

  String? leaf(String xml, String name) {
    final doc = XmlDocument.parse(xml.trim());
    return doc.descendantElements
        .where((e) => e.name.local == name)
        .firstOrNull
        ?.innerText;
  }

  List<String> names(_Answer a) => [for (final h in a.headers) h.$1];

  group('lifecycle and documents', () {
    test('listens on a random loopback port and stops', () async {
      await startSim(PanasonicSimulator());
      expect(sim.isRunning, isTrue);
      expect(sim.host, '127.0.0.1');
      expect(sim.endpoint.ports, {'nrc': sim.port});
      await sim.stop();
      expect(sim.isRunning, isFalse);
      await expectLater(
        Socket.connect('127.0.0.1', sim.port),
        throwsA(isA<SocketException>()),
      );
    });

    test('the NRC description has the description header set (no EXT) '
        'and the real element content', () async {
      await startSim(PanasonicSimulator(mac: 'a8:13:74:b3:03:14'));
      final a = await raw('GET', '/nrc/ddd.xml');
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(names(a), [
        'CONTENT-LENGTH',
        'Content-Type',
        'SERVER',
        'CONNECTION',
      ]);
      expect(a.headers[1].$2, 'text/xml; charset="utf-8"');
      expect(a.headers[2].$2, panasonicSimServer);
      expect(int.parse(a.headers.first.$2), utf8.encode(a.body).length);
      expect(
        leaf(a.body, 'deviceType'),
        'urn:panasonic-com:device:p00RemoteController:1',
      );
      expect(leaf(a.body, 'modelName'), 'Panasonic VIErA');
      expect(leaf(a.body, 'modelNumber'), 'TX-49DX600EA');
      expect(leaf(a.body, 'UDN'), 'uuid:4D454931-0200-1090-8001-A81374B30314');
      expect(leaf(a.body, 'X_NRCCAP'), contains('VR_POWER'));
      expect(sim.nrcUdn, leaf(a.body, 'UDN'));
    });

    test('the service description lists the encryption actions only when '
        'encrypted, and never X_GetAppList', () async {
      await startSim(PanasonicSimulator());
      final plain = (await raw('GET', '/nrc/sdd_0.xml')).body;
      expect(plain, isNot(contains('X_GetEncryptSessionId')));
      expect(plain, contains('<name>X_SendKey</name>'));
      expect(plain, contains('<name>X_ScreenState</name>'));
      expect(plain, isNot(contains('X_GetAppList')));
      sim.encrypted = true;
      final enc = (await raw('GET', '/nrc/sdd_0.xml')).body;
      for (final a in [
        'X_DisplayPinCode',
        'X_RequestAuth',
        'X_GetEncryptSessionId',
        'X_EncryptedCommand',
      ]) {
        expect(enc, contains('<name>$a</name>'));
      }
      expect(enc, isNot(contains('X_GetAppList')));
    });

    test('unknown paths are a bare 404', () async {
      await startSim(PanasonicSimulator());
      final a = await raw('GET', '/nope');
      expect(a.raw, 'HTTP/1.1 404 Not Found\r\nCONNECTION: close\r\n\r\n');
    });

    test('the MediaRenderer description names Panasonic VIErA', () async {
      await startSim(PanasonicSimulator());
      final a = await raw('GET', '/dmr/ddd.xml');
      expect(leaf(a.body, 'manufacturer'), 'Panasonic');
      expect(leaf(a.body, 'modelName'), 'Panasonic VIErA');
      expect(a.body, contains('<controlURL>/dmr/control_0</controlURL>'));
    });
  });

  group('SOAP answers', () {
    test('X_SendKey: the exact header set, in order, and the 301-byte '
        'layout', () async {
      await startSim(PanasonicSimulator());
      final a = await nrc(
        'X_SendKey',
        '<X_KeyEvent>NRC_HDMI1-ONOFF</X_KeyEvent>',
      );
      expect(
        a.raw,
        startsWith(
          'HTTP/1.1 200 OK\r\nCONTENT-LENGTH: 301\r\n'
          'Content-Type: text/xml; charset="utf-8"\r\nEXT: \r\n'
          'SERVER: Panasonic-VIErA/1, UPnP/1.0, Panasonic MIL DLNA SERVER\r\n'
          'CONNECTION: close\r\n\r\n',
        ),
      );
      expect(
        a.body,
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
        ' <s:Body>\n'
        '  <u:X_SendKeyResponse '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">'
        '</u:X_SendKeyResponse>\n'
        ' </s:Body>\n'
        '</s:Envelope>\n',
      );
      expect(utf8.encode(a.body), hasLength(301));
      expect(sim.input, 'H1');
      expect(sim.keyLog, ['NRC_HDMI1-ONOFF']);
    });

    test('X_DisplayPinCode answers in exactly 379 bytes', () async {
      await startSim(PanasonicSimulator(encrypted: true, seed: 1));
      final a = await nrc(
        'X_DisplayPinCode',
        '<X_DeviceName>watchme</X_DeviceName>',
      );
      expect(a.headers.first, ('CONTENT-LENGTH', '379'));
      expect(base64.decode(leaf(a.body, 'X_ChallengeKey')!), hasLength(16));
      expect(sim.displayedPin, matches(RegExp(r'^\d{4}$')));
      expect(sim.pinDeviceNames, ['watchme']);
      final next = sim.onPinDisplayed.first;
      await nrc('X_DisplayPinCode', '<X_DeviceName>again</X_DeviceName>');
      expect(await next, sim.displayedPin);
    });

    test('out-arguments go on their own lines (GetVolume)', () async {
      await startSim(PanasonicSimulator());
      final a = await dmr('GetVolume');
      expect(
        a.body,
        contains(
          '\n  <u:GetVolumeResponse '
          'xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1">\n'
          '   <CurrentVolume>20</CurrentVolume>\n'
          '  </u:GetVolumeResponse>\n',
        ),
      );
    });

    test('faults are UPnP faults with the SOAP header set', () async {
      await startSim(PanasonicSimulator());
      final a = await dmr('SetVolume', '<DesiredVolume>101</DesiredVolume>');
      expect(a.statusLine, 'HTTP/1.1 500 Internal Server Error');
      expect(names(a), [
        'CONTENT-LENGTH',
        'Content-Type',
        'EXT',
        'SERVER',
        'CONNECTION',
      ]);
      expect(a.body, contains('<errorCode>601</errorCode>'));
      expect(sim.volume, 20);
    });

    test('a client on another subnet gets a bare 403', () async {
      await startSim(PanasonicSimulator(allowedSubnet: '192.168.1.0/24'));
      for (final path in ['/nrc/ddd.xml', _nrc, _dmr]) {
        final a = await raw('POST', path, body: 'x');
        expect(a.raw, 'HTTP/1.1 403 Forbidden\r\nCONNECTION: close\r\n\r\n');
      }
      final send = await nrc(
        'X_SendKey',
        '<X_KeyEvent>NRC_MUTE-ONOFF</X_KeyEvent>',
      );
      expect(send.statusLine, 'HTTP/1.1 403 Forbidden');
      expect(sim.muted, isFalse);
      sim.allowedSubnet = '127.0.0.0/8';
      expect((await raw('GET', '/nrc/ddd.xml')).statusLine, 'HTTP/1.1 200 OK');
    });

    test('TV Remote off refuses control with 403', () async {
      await startSim(PanasonicSimulator(tvRemote: false));
      expect((await nrc('X_SendKey')).statusLine, 'HTTP/1.1 403 Forbidden');
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 200 OK');
    });
  });

  group('lenient request parsing', () {
    test("curl's form: no XML declaration, Accept */*, a User-Agent, "
        'SOAPAction, an unquoted charset', () async {
      await startSim(PanasonicSimulator());
      final body = _envelope(
        panasonicSimNrcUrn,
        'X_SendKey',
        '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>',
        p: 'm',
      ).replaceFirst('<?xml version="1.0" encoding="utf-8"?>', '');
      expect(utf8.encode(body), hasLength(277));
      final a = await raw(
        'POST',
        _nrc,
        headers: [
          ('User-Agent', 'curl/7.77.0'),
          ('Accept', '*/*'),
          ('Content-Type', 'text/xml; charset=utf-8'),
          ('SOAPAction', '"$panasonicSimNrcUrn#X_SendKey"'),
        ],
        body: body,
      );
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(a.headers.first, ('CONTENT-LENGTH', '301'));
      expect(sim.powerToggles, 1);
    });

    test("urllib's form: Soapaction, Content-type, lower-case host, CRLF "
        'between elements, the m: prefix', () async {
      await startSim(PanasonicSimulator());
      final a = await raw(
        'POST',
        _nrc,
        hostHeader: false,
        headers: [
          ('host', '${sim.host}:${sim.port}'),
          ('Content-type', 'text/xml; charset=utf-8'),
          ('Soapaction', '"$panasonicSimNrcUrn#X_SendKey"'),
          ('User-agent', 'Python-urllib/3.12'),
          ('Accept-Encoding', 'identity'),
          ('Connection', 'close'),
        ],
        body:
            '<?xml version="1.0" encoding="utf-8"?>\r\n<s:Envelope '
            'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\r\n'
            '<s:Body>\r\n<m:X_SendKey xmlns:m="$panasonicSimNrcUrn">\r\n'
            '<X_KeyEvent>NRC_MUTE-ONOFF</X_KeyEvent>\r\n</m:X_SendKey>\r\n'
            '</s:Body>\r\n</s:Envelope>',
      );
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(sim.muted, isTrue);
    });

    test('X_GetAppList takes None, empty or whitespace content', () async {
      await startSim(PanasonicSimulator());
      for (final content in ['None', '', '  \r\n ']) {
        final a = await soap(_nrc, panasonicSimNrcUrn, 'X_GetAppList', content);
        expect(a.statusLine, 'HTTP/1.1 200 OK', reason: content);
        expect(a.body, contains('vc_app&apos;Stop&apos;product_id='));
        expect(a.body, contains('&apos;Unknown&gt;'));
      }
    });

    test('a SOAPACTION naming another action, or a malformed body, is a '
        'bare 400', () async {
      await startSim(PanasonicSimulator());
      final wrong = await raw(
        'POST',
        _nrc,
        headers: [('SOAPACTION', '"$panasonicSimNrcUrn#X_GetAppList"')],
        body: _envelope(panasonicSimNrcUrn, 'X_SendKey', ''),
      );
      expect(
        wrong.raw,
        'HTTP/1.1 400 Bad Request\r\nCONNECTION: close\r\n\r\n',
      );
      final garbage = await raw('POST', _nrc, body: '<not xml');
      expect(garbage.statusLine, 'HTTP/1.1 400 Bad Request');
    });

    test('unknown key names are answered 200 and do nothing', () async {
      await startSim(PanasonicSimulator());
      final a = await nrc(
        'X_SendKey',
        '<X_KeyEvent>NRC_NOPE-ONOFF</X_KeyEvent>',
      );
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(sim.keyLog, ['NRC_NOPE-ONOFF']);
    });

    test('unknown actions are fault 401', () async {
      await startSim(PanasonicSimulator());
      final a = await nrc('X_Bogus');
      expect(a.body, contains('<errorCode>401</errorCode>'));
    });
  });

  group('encryption', () {
    test('the simulator derives the brief\'s pairing keys and opens its '
        'X_AuthInfo vectors, zero-padded and PKCS#7', () {
      final keys = PanasonicSimKeys.pairing(
        base64.decode('mUQdS7/RyJTMsiojPz9i1Q=='),
      );
      expect(_hex(keys.aesKey), 'b4e2bb666b372e40dcd54d332a9dc0c0');
      expect(
        _hex(keys.hmacKey),
        '0882c386781e183a640143337ce1ef70b8003e98640cc62ba0ee6f4e469a076b',
      );
      const zero =
          '/Ird4/R7cLUCCJzX7SW4xOtGK6gDteDRWuZGkDVkauZYBdCW8DB3pDKk3jW1l7lz5DRW'
          'mqNPnXvwRYUN1bh0QWgSh1YBIWDiUVuCmEKHvAY=';
      const pkcs7 =
          '/Ird4/R7cLUCCJzX7SW4xOtGK6gDteDRWuZGkDVkauYTosj3j/eyHa9cih8PPzUSdnYW'
          'zi56EIEOpdOiOjeQDjiA/yOtvNZy49IbgY6u6Z4=';
      for (final blob in [zero, pkcs7]) {
        final opened = panasonicSimOpen(keys, blob, strictPadding: true);
        expect(opened.payload, '<X_PinCode>4410</X_PinCode>');
      }
      expect(panasonicSimClientSeal(keys, '<X_PinCode>4410</X_PinCode>'), zero);
      expect(
        panasonicSimClientSeal(
          keys,
          '<X_PinCode>4410</X_PinCode>',
          pkcs7: true,
        ),
        pkcs7,
      );
    });

    test('session keys match the non-symmetric vector', () {
      final keys = PanasonicSimKeys.session(
        base64.decode('AAECAwQFBgcICQoLDA0ODw=='),
      );
      expect(_hex(keys.aesKey), '02030001060704050a0b08090e0f0c0d');
    });

    test('client payloads are checked: length, HMAC, then the length '
        'field; zero pad bytes only when not strict', () {
      final keys = PanasonicSimKeys.session(List.generate(16, (i) => i));
      final good = panasonicSimClientSeal(keys, 'x' * 20);
      expect(
        panasonicSimOpen(keys, good, strictPadding: true).payload,
        'x' * 20,
      );
      final tampered = base64.decode(good)..[3] ^= 1;
      expect(
        panasonicSimOpen(
          keys,
          base64.encode(tampered),
          strictPadding: true,
        ).failure,
        PanasonicSimCryptoFailure.badMac,
      );
      expect(
        panasonicSimOpen(
          keys,
          base64.encode([1, 2, 3]),
          strictPadding: true,
        ).failure,
        PanasonicSimCryptoFailure.badLength,
      );
      expect(
        panasonicSimOpen(keys, '%%', strictPadding: true).failure,
        PanasonicSimCryptoFailure.notBase64,
      );
      final aligned = panasonicSimClientSeal(keys, 'y' * 32, noPad: true);
      expect(
        panasonicSimOpen(keys, aligned, strictPadding: true).failure,
        PanasonicSimCryptoFailure.badLengthField,
      );
      expect(
        panasonicSimOpen(keys, aligned, strictPadding: false).payload,
        'y' * 32,
      );
    });

    test('answers are zero-padded, carry a trailing HMAC and a length '
        'field that is not the payload length', () {
      final keys = PanasonicSimKeys.session(List.generate(16, (i) => i));
      final sealed = base64.decode(
        panasonicSimSeal(keys, '<X_SessionId>7</X_SessionId>', _FixedRandom()),
      );
      final ct = sealed.sublist(0, sealed.length - 32);
      expect(sealed.sublist(sealed.length - 32), keys.mac(ct));
      final plain = keys.cbc(ct, encrypt: false);
      final n = ByteData.sublistView(plain).getUint32(12);
      expect(n, isNot(28));
      expect(
        utf8.decode(plain.sublist(16, 16 + 28)),
        '<X_SessionId>7</X_SessionId>',
      );
      expect(plain.sublist(16 + 28), everyElement(0));
      expect(plain.length - 16 - 28, greaterThanOrEqualTo(1));
    });
  });

  group('pairing', () {
    late Uint8List challenge;

    Future<_Answer> showPin() async {
      final a = await nrc(
        'X_DisplayPinCode',
        '<X_DeviceName>watchme &amp; co</X_DeviceName>',
      );
      challenge = base64.decode(leaf(a.body, 'X_ChallengeKey')!);
      return a;
    }

    Future<_Answer> auth(String pin, {bool pkcs7 = false}) => nrc(
      'X_RequestAuth',
      '<X_AuthInfo>${panasonicSimClientSeal(PanasonicSimKeys.pairing(challenge), '<X_PinCode>$pin</X_PinCode>', pkcs7: pkcs7)}</X_AuthInfo>',
    );

    test('the right PIN yields an app id and keyword sealed with the '
        'pairing keys, zero-padded with a trailing HMAC', () async {
      await startSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
      await showPin();
      expect(sim.pinDeviceNames, ['watchme & co']);
      final a = await auth('4410', pkcs7: true);
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      final blob = base64.decode(leaf(a.body, 'X_AuthResult')!);
      final keys = PanasonicSimKeys.pairing(challenge);
      final ct = blob.sublist(0, blob.length - 32);
      expect(blob.sublist(blob.length - 32), keys.mac(ct));
      final plain = keys.cbc(ct, encrypt: false);
      final text = utf8.decode(plain.sublist(16, plain.indexOf(0, 16)));
      final m = RegExp(
        r'^<X_ApplicationId>(.+)</X_ApplicationId>\n<X_Keyword>(.+)</X_Keyword>$',
      ).firstMatch(text)!;
      expect(base64.decode(m[1]!), hasLength(10));
      expect(base64.decode(m[2]!), hasLength(16));
      expect(sim.pairings, {m[1]!: m[2]!});
      expect(sim.displayedPin, isNull);
    });

    test('a wrong PIN is fault 600 and withdraws the PIN', () async {
      await startSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
      await showPin();
      final wrong = await auth('1111');
      expect(wrong.body, contains('<errorCode>600</errorCode>'));
      expect(sim.displayedPin, isNull);
      final late = await auth('4410');
      expect(late.body, contains('<errorCode>600</errorCode>'));
      expect(sim.pairings, isEmpty);
    });

    test('an expired PIN is fault 600', () async {
      await startSim(
        PanasonicSimulator(
          encrypted: true,
          fixedPin: '4410',
          pinTimeout: const Duration(milliseconds: 50),
        ),
      );
      await showPin();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect((await auth('4410')).body, contains('<errorCode>600</errorCode>'));
      expect(sim.effects, contains('pin:expired'));
    });

    test('a lockout refuses new PINs for a while', () async {
      await startSim(
        PanasonicSimulator(encrypted: true, fixedPin: '4410', maxWrongPins: 2),
      );
      await showPin();
      await auth('0000');
      await showPin();
      await auth('0000');
      final locked = await nrc(
        'X_DisplayPinCode',
        '<X_DeviceName>x</X_DeviceName>',
      );
      expect(locked.statusLine, startsWith('HTTP/1.1 500'));
      expect(locked.body, contains('Too many'));
    });

    test('a tampered X_AuthInfo is refused without using up the PIN', () async {
      await startSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
      await showPin();
      final a = await nrc('X_RequestAuth', '<X_AuthInfo>AAAA</X_AuthInfo>');
      expect(a.body, contains('<errorCode>402</errorCode>'));
      expect(sim.displayedPin, '4410');
    });

    test('no PIN is shown while the TV is not on', () async {
      await startSim(
        PanasonicSimulator(
          encrypted: true,
          power: PanasonicSimPower.networkStandby,
        ),
      );
      final a = await nrc('X_DisplayPinCode', '<X_DeviceName>x</X_DeviceName>');
      expect(a.statusLine, startsWith('HTTP/1.1 500'));
      expect(sim.displayedPin, isNull);
    });

    test('plain NRC actions on an encrypted TV are fault 401, the literal '
        'FHEM checks for', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final a = await nrc(
        'X_SendKey',
        '<X_KeyEvent>NRC_INFO-ONOFF</X_KeyEvent>',
      );
      expect(a.statusLine, 'HTTP/1.1 500 Internal Server Error');
      expect(a.body, contains('<errorCode>401</errorCode>'));
      expect(sim.keyLog, isEmpty);
    });

    test('plain TVs do not know the pairing actions', () async {
      await startSim(PanasonicSimulator());
      final a = await nrc('X_DisplayPinCode', '<X_DeviceName>x</X_DeviceName>');
      expect(a.body, contains('<errorCode>401</errorCode>'));
    });
  });

  group('encrypted sessions', () {
    const appId = 'AQIDBAUGBwgJCg==';
    const keyword = 'ICEiIyQlJicoKSorLC0uLw==';
    final keys = PanasonicSimKeys.session(base64.decode(keyword));

    Future<String> openSession({String id = appId, PanasonicSimKeys? k}) async {
      final a = await nrc(
        'X_GetEncryptSessionId',
        '<X_ApplicationId>$id</X_ApplicationId><X_EncInfo>'
            '${panasonicSimClientSeal(k ?? keys, '<X_ApplicationId>$id</X_ApplicationId>')}'
            '</X_EncInfo>',
      );
      expect(a.statusLine, 'HTTP/1.1 200 OK', reason: a.body);
      final blob = base64.decode(leaf(a.body, 'X_EncResult')!);
      final plain = (k ?? keys).cbc(
        blob.sublist(0, blob.length - 32),
        encrypt: false,
      );
      final text = utf8.decode(plain.sublist(16, plain.indexOf(0, 16)));
      return RegExp(r'<X_SessionId>(\d+)</X_SessionId>').firstMatch(text)![1]!;
    }

    Future<_Answer> command(
      String sid,
      int seq,
      String action,
      String args, {
      String? inner,
      String id = appId,
    }) {
      final payload =
          inner ??
          '<X_SessionId>$sid</X_SessionId><X_SequenceNumber>'
              '${seq.toString().padLeft(8, '0')}</X_SequenceNumber>'
              '<X_OriginalCommand><u:$action xmlns:u="$panasonicSimNrcUrn">'
              '$args</u:$action></X_OriginalCommand>';
      return nrc(
        'X_EncryptedCommand',
        '<X_ApplicationId>$id</X_ApplicationId><X_EncInfo>'
            '${panasonicSimClientSeal(keys, payload)}</X_EncInfo>',
      );
    }

    String decrypt(_Answer a, {bool mac = true}) {
      final blob = base64.decode(leaf(a.body, 'X_EncResult')!);
      final ct = mac ? blob.sublist(0, blob.length - 32) : blob;
      if (mac) expect(blob.sublist(blob.length - 32), keys.mac(ct));
      final plain = keys.cbc(ct, encrypt: false);
      return utf8.decode(plain.sublist(16, plain.indexOf(0, 16)));
    }

    setUp(() async {
      await startSim(PanasonicSimulator(encrypted: true, seed: 3));
      sim.addPairing(appId, keyword);
    });

    test('a session starts at sequence 0, so 1, 2 and 3 are all accepted '
        'as first numbers', () async {
      for (final first in [1, 2, 3]) {
        final sid = await openSession();
        expect(sim.lastSequence(sid), 0);
        final a = await command(
          sid,
          first,
          'X_SendKey',
          '<X_KeyEvent>NRC_VOLUP-ONOFF</X_KeyEvent>',
        );
        expect(a.statusLine, 'HTTP/1.1 200 OK');
        expect(
          decrypt(a),
          '<u:X_SendKeyResponse xmlns:u="$panasonicSimNrcUrn">'
          '</u:X_SendKeyResponse>',
        );
      }
      expect(sim.volume, 23);
      expect(sim.sessionsOpened, 3);
    });

    test('a replayed sequence number is refused when strict, accepted '
        'otherwise', () async {
      final sid = await openSession();
      final args = '<X_KeyEvent>NRC_MUTE-ONOFF</X_KeyEvent>';
      expect(
        (await command(sid, 5, 'X_SendKey', args)).statusLine,
        endsWith('OK'),
      );
      final replay = await command(sid, 5, 'X_SendKey', args);
      expect(replay.statusLine, startsWith('HTTP/1.1 500'));
      expect(sim.muted, isTrue);
      sim.seqCheck = PanasonicSimSeqCheck.none;
      expect(
        (await command(sid, 5, 'X_SendKey', args)).statusLine,
        endsWith('OK'),
      );
      expect(sim.muted, isFalse);
    });

    test('inner elements in any order, with CRLF around them', () async {
      final sid = await openSession();
      final a = await command(
        sid,
        0,
        '',
        '',
        inner:
            '\r\n<X_OriginalCommand>\r\n<u:X_GetAppInfo '
            'xmlns:u="$panasonicSimNrcUrn"><u:X_InfoType></u:X_InfoType>'
            '</u:X_GetAppInfo>\r\n</X_OriginalCommand>\r\n'
            '<X_SequenceNumber>00000004</X_SequenceNumber>\r\n'
            '<X_SessionId>$sid</X_SessionId>\r\n',
      );
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(decrypt(a), contains('<X_AppInfo></X_AppInfo>'));
    });

    test('the app list comes back with its entities still escaped', () async {
      final sid = await openSession();
      final a = await command(sid, 2, 'X_GetAppList', 'None');
      expect(decrypt(a), contains('vc_app&apos;Unknown&apos;product_id='));
    });

    test(
      'an unknown session is a 500 with the configured reason phrase',
      () async {
        sim.sessionErrorReason = 'No such session';
        final a = await command('999', 2, 'X_SendKey', '');
        expect(a.statusLine, 'HTTP/1.1 500 No such session');
        sim.sessionErrorEmptyBody = true;
        final empty = await command('999', 3, 'X_SendKey', '');
        expect(empty.body, isEmpty);
        expect(empty.headers.first, ('CONTENT-LENGTH', '0'));
      },
    );

    test('a power change drops every session', () async {
      final sid = await openSession();
      await sim.pressPowerButton();
      expect(sim.power, PanasonicSimPower.networkStandby);
      expect(sim.sessionIds, isEmpty);
      final a = await command(sid, 2, 'X_SendKey', '');
      expect(a.statusLine, startsWith('HTTP/1.1 500'));
    });

    test('expireAllSessions and sessionTtl end sessions', () async {
      final sid = await openSession();
      sim.expireAllSessions();
      expect(
        (await command(sid, 2, 'X_SendKey', '')).statusLine,
        startsWith('HTTP/1.1 500'),
      );
      sim.sessionTtl = Duration.zero;
      final again = await openSession();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(
        (await command(again, 2, 'X_SendKey', '')).statusLine,
        startsWith('HTTP/1.1 500'),
      );
    });

    test('a deleted pairing refuses the session', () async {
      sim.forgetPairings();
      final a = await nrc(
        'X_GetEncryptSessionId',
        '<X_ApplicationId>$appId</X_ApplicationId><X_EncInfo>'
            '${panasonicSimClientSeal(keys, '<X_ApplicationId>$appId</X_ApplicationId>')}'
            '</X_EncInfo>',
      );
      expect(a.body, contains('<errorCode>401</errorCode>'));
    });

    test('an aligned X_EncInfo with no pad byte is refused only when '
        'strict', () async {
      const id = 'abcdefghijklm'; // 16 + 35 + 13 = 64: aligned.
      sim.addPairing(id, keyword);
      String encInfo() => panasonicSimClientSeal(
        keys,
        '<X_ApplicationId>$id</X_ApplicationId>',
        noPad: true,
      );
      final strict = await nrc(
        'X_GetEncryptSessionId',
        '<X_ApplicationId>$id</X_ApplicationId><X_EncInfo>${encInfo()}</X_EncInfo>',
      );
      expect(strict.body, contains('<errorCode>402</errorCode>'));
      sim.strictClientPadding = false;
      final lenient = await nrc(
        'X_GetEncryptSessionId',
        '<X_ApplicationId>$id</X_ApplicationId><X_EncInfo>${encInfo()}</X_EncInfo>',
      );
      expect(lenient.statusLine, 'HTTP/1.1 200 OK');
    });

    test(
      'answer variants: X_OriginalResult wrapper, no trailing HMAC',
      () async {
        sim.wrapEncryptedAnswers = true;
        final sid = await openSession();
        expect(
          decrypt(await command(sid, 2, 'X_GetVectorInfo', 'None')),
          startsWith('<X_OriginalResult><u:X_GetVectorInfoResponse'),
        );
        sim.encryptedAnswerMac = false;
        final a = await command(sid, 3, 'X_GetVectorInfo', 'None');
        expect(base64.decode(leaf(a.body, 'X_EncResult')!).length % 32, 16);
        expect(
          decrypt(a, mac: false),
          contains('<X_PortNumber>55000</X_PortNumber>'),
        );
      },
    );

    test('RenderingControl stays plain on an encrypted TV', () async {
      final a = await dmr('SetVolume', '<DesiredVolume>33</DesiredVolume>');
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(sim.volume, 33);
    });
  });

  group('power', () {
    test('the power key goes to network standby, where descriptions still '
        'answer, RenderingControl and PAC answer 400, the app list is empty '
        'and other keys do nothing', () async {
      await startSim(PanasonicSimulator(pac: true, bootDelay: Duration.zero));
      expect((await raw('GET', '/pac/ddd.xml')).statusLine, 'HTTP/1.1 200 OK');
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      await Future<void>.delayed(Duration.zero);
      expect(sim.power, PanasonicSimPower.networkStandby);
      expect(sim.screenState, 'off');
      expect((await raw('GET', '/nrc/ddd.xml')).statusLine, 'HTTP/1.1 200 OK');
      expect(
        (await dmr('GetVolume')).raw,
        'HTTP/1.1 400 Bad Request\r\nCONNECTION: close\r\n\r\n',
      );
      expect(
        (await raw('GET', '/pac/ddd.xml')).raw,
        'HTTP/1.1 400 Bad Request\r\nCONNECTION: close\r\n\r\n',
      );
      expect(
        (await nrc('X_GetAppList', 'None')).body,
        contains('<X_AppList></X_AppList>'),
      );
      await nrc('X_SendKey', '<X_KeyEvent>NRC_MUTE-ONOFF</X_KeyEvent>');
      expect(sim.muted, isFalse);
      sim.dmrAnswersInStandby = true;
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 200 OK');
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      await Future<void>.delayed(Duration.zero);
      expect(sim.power, PanasonicSimPower.on);
      expect(sim.powerToggles, 2);
    });

    test('without network standby the port closes', () async {
      await startSim(PanasonicSimulator(poweredOnByApps: false));
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sim.power, PanasonicSimPower.standby);
      await expectLater(
        Socket.connect(sim.host, sim.port),
        throwsA(isA<SocketException>()),
      );
    });

    test('without network standby the port closes only after '
        'nicSleepDelay', () async {
      await startSim(
        PanasonicSimulator(
          poweredOnByApps: false,
          nicSleepDelay: const Duration(milliseconds: 200),
        ),
      );
      await sim.pressPowerButton();
      expect(sim.power, PanasonicSimPower.standby);
      // The NIC is still up for a moment: descriptions answer, the screen
      // is off.
      expect((await raw('GET', '/nrc/ddd.xml')).statusLine, 'HTTP/1.1 200 OK');
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 400 Bad Request');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await expectLater(
        Socket.connect(sim.host, sim.port),
        throwsA(isA<SocketException>()),
      );
    });

    test('a TV that refuses connections while booting listens again once '
        'booted', () async {
      await startSim(
        PanasonicSimulator(
          power: PanasonicSimPower.networkStandby,
          bootDelay: const Duration(milliseconds: 200),
          bootRefusesConnections: true,
        ),
      );
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sim.booting, isTrue);
      await expectLater(
        Socket.connect(sim.host, sim.port),
        throwsA(isA<SocketException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sim.booting, isFalse);
      expect(sim.screenState, 'on');
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 200 OK');
    });

    test('booting answers 400 to RenderingControl and swallows keys, then '
        'turns on', () async {
      await startSim(
        PanasonicSimulator(
          power: PanasonicSimPower.networkStandby,
          bootDelay: const Duration(milliseconds: 200),
        ),
      );
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sim.booting, isTrue);
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 400 Bad Request');
      await nrc('X_SendKey', '<X_KeyEvent>NRC_POWER-ONOFF</X_KeyEvent>');
      expect(sim.powerToggles, 1);
      expect(sim.effects, contains('swallowed:POWER'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(sim.booting, isFalse);
      expect(sim.screenState, 'on');
      expect((await dmr('GetVolume')).statusLine, 'HTTP/1.1 200 OK');
    });

    test('Wake-on-LAN is ignored right after switching off, then wakes the '
        'TV; a packet for another MAC does nothing', () async {
      await startSim(
        PanasonicSimulator(
          bootDelay: Duration.zero,
          poweredOnByApps: false,
          wolIgnoredAfterOff: const Duration(milliseconds: 100),
        ),
        wolPort: 0,
      );
      await sim.pressPowerButton();
      expect(sim.receiveWakeOnLan(), isFalse);
      expect(sim.effects, contains('wol:ignored'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final udp = await RawDatagramSocket.bind('127.0.0.1', 0);
      addTearDown(udp.close);
      List<int> packet(List<int> mac) => [
        ...List.filled(6, 0xff),
        for (var i = 0; i < 16; i++) ...mac,
      ];
      udp.send(
        packet([1, 2, 3, 4, 5, 6]),
        InternetAddress.loopbackIPv4,
        sim.wolPort!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.power, PanasonicSimPower.standby);
      udp.send(
        packet([0x80, 0xc7, 0x55, 0xb8, 0x6c, 0x63]),
        InternetAddress.loopbackIPv4,
        sim.wolPort!,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sim.power, PanasonicSimPower.on);
      expect(sim.wakes, 1);
      expect((await raw('GET', '/nrc/ddd.xml')).statusLine, 'HTTP/1.1 200 OK');
    });

    test(
      'an unplugged TV refuses connections and ignores Wake-on-LAN',
      () async {
        await startSim(PanasonicSimulator(wolIgnoredAfterOff: Duration.zero));
        await sim.setPower(PanasonicSimPower.unplugged);
        expect(sim.receiveWakeOnLan(), isFalse);
        await expectLater(
          Socket.connect(sim.host, sim.port),
          throwsA(isA<SocketException>()),
        );
      },
    );
  });

  group('RenderingControl and PAC', () {
    test('volume and mute', () async {
      await startSim(PanasonicSimulator());
      await dmr('SetVolume', '<DesiredVolume>30</DesiredVolume>');
      await dmr('SetMute', '<DesiredMute>1</DesiredMute>');
      expect(leaf((await dmr('GetVolume')).body, 'CurrentVolume'), '30');
      expect(leaf((await dmr('GetMute')).body, 'CurrentMute'), '1');
      expect(sim.effects, ['volume:30', 'mute:true']);
    });

    test('PAC lists inputs, reads and selects the current one', () async {
      await startSim(PanasonicSimulator(pac: true));
      Future<_Answer> pac(String action, String args) =>
          soap(_pac, panasonicSimPacUrn, action, args);
      expect(
        leaf(
          (await pac(
            'X_SendInquiryCmd',
            '<X_InquiryCmdType>PAC_QIL</X_InquiryCmdType>',
          )).body,
          'X_InquiryCmdResult',
        ),
        'QIL:TV[TV],H1[HDMI1],H2[HDMI2],H3[HDMI3],H4[HDMI4]',
      );
      await pac('X_SendCtrlCmd', '<X_CtrlCmd>PAC_IMS:H2</X_CtrlCmd>');
      expect(
        leaf(
          (await pac(
            'X_SendInquiryCmd',
            '<X_InquiryCmdType>PAC_QMI</X_InquiryCmdType>',
          )).body,
          'X_InquiryCmdResult',
        ),
        'QMI:H2',
      );
    });

    test('without PAC, /pac answers 400', () async {
      await startSim(PanasonicSimulator());
      expect(
        (await raw('GET', '/pac/ddd.xml')).statusLine,
        'HTTP/1.1 400 Bad Request',
      );
    });
  });

  group('apps', () {
    test('launch by product id and read the foreground app', () async {
      await startSim(PanasonicSimulator());
      await nrc(
        'X_LaunchApp',
        '<X_AppType>vc_app</X_AppType>'
            '<X_LaunchKeyword>product_id=0010000200000001</X_LaunchKeyword>',
      );
      expect(sim.foregroundAppId, '0010000200000001');
      final info = await soap(
        _nrc,
        panasonicSimNrcUrn,
        'X_GetAppInfo',
        '<u:X_InfoType></u:X_InfoType>',
      );
      expect(
        leaf(info.body, 'X_AppInfo'),
        'vc_app:1:product_id=0010000200000001:Netflix',
      );
      final unknown = await nrc(
        'X_LaunchApp',
        '<X_AppType>vc_app</X_AppType>'
            '<X_LaunchKeyword>product_id=9999999999999999</X_LaunchKeyword>',
      );
      expect(unknown.statusLine, startsWith('HTTP/1.1 500'));
    });
  });

  group('GENA', () {
    late HttpServer listener;
    late List<(HttpHeaders, String)> received;

    setUp(() async {
      received = [];
      listener = await HttpServer.bind('127.0.0.1', 0);
      addTearDown(() => listener.close(force: true));
      listener.listen((request) async {
        received.add((request.headers, await utf8.decodeStream(request)));
        request.response
          ..statusCode = 200
          ..contentLength = 0;
        await request.response.close();
      });
    });

    Future<_Answer> subscribe() => raw(
      'SUBSCRIBE',
      '/nrc/event_0',
      headers: [
        ('CALLBACK', '<http://127.0.0.1:${listener.port}/notify>'),
        ('NT', 'upnp:event'),
        ('TIMEOUT', 'Second-10'),
      ],
    );

    test('a subscription gets the NRC UDN as SID, 300 s, and an initial '
        'NOTIFY with all four variables; a change carries one', () async {
      await startSim(PanasonicSimulator(bootDelay: Duration.zero));
      final first = sim.onNotify.first;
      final a = await subscribe();
      expect(a.statusLine, 'HTTP/1.1 200 OK');
      expect(
        a.headers,
        containsAll([('SID', sim.nrcUdn), ('TIMEOUT', 'Second-300')]),
      );
      final initial = await first;
      expect(initial.status, 200);
      expect(initial.seq, 0);
      final (headers, body) = received.single;
      expect(headers.value('nt'), 'upnp:event');
      expect(headers.value('nts'), 'upnp:propchange');
      expect(headers.value('sid'), sim.nrcUdn);
      expect(headers.value('seq'), '0');
      for (final v in [
        '<X_InputMode>rc-mode</X_InputMode>',
        '<X_KeyboardType>default</X_KeyboardType>',
        '<X_ScreenState>on</X_ScreenState>',
        '<X_AppInfo></X_AppInfo>',
      ]) {
        expect(body, contains(v));
      }
      final change = sim.onNotify.first;
      await sim.pressPowerButton();
      final off = await change;
      expect(off.seq, 1);
      expect(
        off.body,
        endsWith(
          '<e:property><X_ScreenState>off</X_ScreenState></e:property>'
          '</e:propertyset>',
        ),
      );
      expect('<e:property>'.allMatches(off.body), hasLength(1));
    });

    test('renewal, unknown SIDs and unsubscribe', () async {
      await startSim(PanasonicSimulator());
      await subscribe();
      final renew = await raw(
        'SUBSCRIBE',
        '/nrc/event_0',
        headers: [('SID', sim.nrcUdn), ('TIMEOUT', 'Second-300')],
      );
      expect(renew.statusLine, 'HTTP/1.1 200 OK');
      final unknown = await raw(
        'SUBSCRIBE',
        '/nrc/event_0',
        headers: [('SID', 'uuid:nope')],
      );
      expect(unknown.statusLine, 'HTTP/1.1 412 Precondition Failed');
      final bye = await raw(
        'UNSUBSCRIBE',
        '/nrc/event_0',
        headers: [('SID', sim.nrcUdn)],
      );
      expect(bye.statusLine, 'HTTP/1.1 200 OK');
      expect(sim.subscriptionIds, isEmpty);
    });

    test('a forced 400, a firewalled callback, and body variants', () async {
      await startSim(PanasonicSimulator(subscribeStatus: 400));
      expect(
        (await subscribe()).raw,
        'HTTP/1.1 400 Bad Request\r\nCONNECTION: close\r\n\r\n',
      );
      sim
        ..subscribeStatus = null
        ..notifyEnabled = false;
      await subscribe();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.notifies, isEmpty);
      sim
        ..notifyEnabled = true
        ..notifyAppendsNul = true
        ..notifyOmitsScreenState = true
        ..randomSids = true;
      final next = sim.onNotify.first;
      await subscribe();
      final n = await next;
      expect(n.body, endsWith('\u0000'));
      expect(n.body, isNot(contains('X_ScreenState')));
      expect(n.sid, isNot(sim.nrcUdn));
      sim
        ..notifyAppendsNul = false
        ..notifyOmitsScreenState = false
        ..screenStateNone = true;
      final none = sim.onNotify.first;
      await subscribe();
      expect(
        (await none).body,
        contains('<X_ScreenState>none</X_ScreenState>'),
      );
    });
  });

  group('test controls', () {
    test('respondOnce replaces one answer without effect', () async {
      await startSim(PanasonicSimulator());
      sim.respondOnce('SetVolume', status: 500, body: 'boom');
      final a = await dmr('SetVolume', '<DesiredVolume>50</DesiredVolume>');
      expect(a.statusLine, 'HTTP/1.1 500 Internal Server Error');
      expect(a.body, 'boom');
      expect(sim.volume, 20);
      expect(
        (await dmr(
          'SetVolume',
          '<DesiredVolume>50</DesiredVolume>',
        )).statusLine,
        endsWith('OK'),
      );
    });

    test(
      'dropNext closes the connection unanswered, after acting or not',
      () async {
        await startSim(PanasonicSimulator());
        sim.dropNext('X_SendKey');
        final socket = await Socket.connect(sim.host, sim.port);
        final body = utf8.encode(
          _envelope(
            panasonicSimNrcUrn,
            'X_SendKey',
            '<X_KeyEvent>NRC_MUTE-ONOFF</X_KeyEvent>',
          ),
        );
        socket.add([
          ...utf8.encode(
            'POST $_nrc HTTP/1.1\r\nContent-Length: ${body.length}\r\n\r\n',
          ),
          ...body,
        ]);
        final out = await socket.fold<List<int>>([], (a, c) => a..addAll(c));
        socket.destroy();
        expect(out, isEmpty);
        expect(sim.muted, isTrue);
        sim.dropNext('SetVolume', execute: false);
        await expectLater(
          dmr('SetVolume', '<DesiredVolume>9</DesiredVolume>'),
          throwsA(anything),
        );
        expect(sim.volume, 20);
      },
    );

    test('holdNext acts at once and answers on release', () async {
      await startSim(PanasonicSimulator());
      final gate = sim.holdNext('SetMute');
      final pending = dmr('SetMute', '<DesiredMute>1</DesiredMute>');
      await gate.reached;
      expect(sim.muted, isTrue);
      gate.release();
      expect((await pending).statusLine, 'HTTP/1.1 200 OK');
    });
  });
}

/// A "random" source with a fixed sequence, for layout checks.
class _FixedRandom implements Random {
  int _n = 0x40;

  @override
  int nextInt(int max) => (_n++) % max;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
