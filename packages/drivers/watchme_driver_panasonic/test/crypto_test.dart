import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_driver_panasonic/src/crypto.dart';
import 'package:watchme_driver_panasonic/src/soap.dart';

// Known-answer vectors from the research brief (section 12), computed by
// two independent scripts (one with a pure-Python AES checked against
// FIPS-197) and cross-checked against Content-Length values captured from
// real TVs.

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

final _clientHeader = List<int>.generate(12, (i) => i); // 00 01 .. 0b

void main() {
  group('pairing key derivation', () {
    test('from the public challenge in panasonic-viera #9', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      expect(_hex(keys.iv), '99441d4bbfd1c894ccb22a233f3f62d5');
      expect(_hex(keys.aesKey), 'b4e2bb666b372e40dcd54d332a9dc0c0');
      expect(
        _hex(keys.hmacKey),
        '0882c386781e183a640143337ce1ef70'
        'b8003e98640cc62ba0ee6f4e469a076b',
      );
    });

    test('from the real challenge in the 379-byte capture', () {
      final keys = VieraKeys.forPairing('A2ZrfRk5oJarHc6IHL5BpQ==');
      expect(_hex(keys.iv), '03666b7d1939a096ab1dce881cbe41a5');
      expect(_hex(keys.aesKey), '829499fc695fc6e67731e2545abe41e3');
      expect(
        _hex(keys.hmacKey),
        '7eb459a4101cbed280aa249c5f91ccf1'
        'ce36a4ba0c0e60c3444508e165ea24ea',
      );
    });

    test('rejects a challenge that is not 16 bytes of base64', () {
      expect(() => VieraKeys.forPairing('not base64!'), throwsFormatException);
      expect(() => VieraKeys.forPairing('AAAA'), throwsFormatException);
    });

    test('keys never print', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      expect(keys.toString(), 'VieraKeys(<redacted>)');
    });
  });

  group('X_AuthInfo', () {
    test('PIN 4410, zero-padded, client header 00..0b', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      final sealed = vieraSeal(
        keys,
        '<X_PinCode>4410</X_PinCode>',
        header: _clientHeader,
      );
      expect(
        sealed,
        '/Ird4/R7cLUCCJzX7SW4xOtGK6gDteDRWuZGkDVkauZYBdCW8DB3pDKk3jW1l7lz5DRW'
        'mqNPnXvwRYUN1bh0QWgSh1YBIWDiUVuCmEKHvAY=',
      );
      final raw = base64.decode(sealed);
      expect(
        _hex(raw.sublist(0, 48)),
        'fc8adde3f47b70b502089cd7ed25b8c4eb462ba803b5e0d15ae6469035646ae6'
        '5805d096f03077a432a4de35b597b973',
      );
      expect(
        _hex(raw.sublist(48)),
        'e434569aa34f9d7bf045850dd5b8744168128756012160e2515b82984287bc06',
      );
      // The whole X_RequestAuth body is 416 bytes.
      expect(
        utf8.encode(
          soapEnvelope(
            VieraUrnForTests.nrc,
            'X_RequestAuth',
            '<X_AuthInfo>$sealed</X_AuthInfo>',
          ),
        ),
        hasLength(416),
      );
    });

    test('PIN 4410 with the twelve ASCII "0" header of the original '
        'example', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      expect(
        vieraSeal(
          keys,
          '<X_PinCode>4410</X_PinCode>',
          header: List.filled(12, 0x30),
        ),
        '3HKEOEoo4TEABS+BMO/uU0FwuY4ig4G67tiXEUW6x6AR89AEyJEUDr+n9hKEIEXdTDV3'
        'CTcaGoD5QMuZ3x0vDs0Cans9+WHynb++GXcm7iw=',
      );
    });

    test('PIN 1234 with the real challenge', () {
      final keys = VieraKeys.forPairing('A2ZrfRk5oJarHc6IHL5BpQ==');
      expect(
        vieraSeal(keys, '<X_PinCode>1234</X_PinCode>', header: _clientHeader),
        'wHYpaFSegnzOoSrbLdmkiFQonBN7g5L6s/jyXJQVRlMGB0hIPJ4zrb9tV3t4XXutG3QV'
        'P2PPBRrxlYmNnUQ85uxs2mphnK+krUEGTEeWR6Y=',
      );
    });

    test('a random header changes the ciphertext but not the framing', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      final a = vieraSeal(keys, '<X_PinCode>4410</X_PinCode>');
      final b = vieraSeal(keys, '<X_PinCode>4410</X_PinCode>');
      expect(a, isNot(b));
      expect(base64.decode(a), hasLength(48 + 32));
      expect(vieraOpen(keys, a).text, '<X_PinCode>4410</X_PinCode>');
    });
  });

  group('X_AuthResult', () {
    test('decrypts the synthetic 216-character answer with a valid MAC', () {
      final keys = VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q==');
      const result =
          '9db0BYoNNVhsfzrXE2NFFGimVYPft3ZM0z8D0pTi9lva7Jf0vcwhXqYEw4RcihSK1fHy'
          'rcDnKH9/IdFSAq8l5qEoueq4QrDfuCqZ9rJYWRnx5qiUisL9fEoU7NnCq+IdekKUOBQ'
          'JFCRjy12VQVJAg3VKefTVGeVbC1eAGPTsT7U+N0u2Es4ZQtuKo5j/2K8lQnloxmIU0b'
          'Qe8jGdeN+lrQ==';
      expect(result, hasLength(216));
      final opened = vieraOpen(keys, result);
      expect(
        opened.text,
        '<X_ApplicationId>AQIDBAUGBwgJCg==</X_ApplicationId>\n'
        '<X_Keyword>ICEiIyQlJicoKSorLC0uLw==</X_Keyword>',
      );
      expect(opened.macOk, isTrue);
    });
  });

  group('session key derivation', () {
    test('keyword 20..2f', () {
      final keys = VieraKeys.forSession('ICEiIyQlJicoKSorLC0uLw==');
      expect(_hex(keys.iv), '202122232425262728292a2b2c2d2e2f');
      expect(_hex(keys.aesKey), '22232021262724252a2b28292e2f2c2d');
      expect(
        _hex(keys.hmacKey),
        '202122232425262728292a2b2c2d2e2f202122232425262728292a2b2c2d2e2f',
      );
    });

    test('a non-symmetric keyword catches a swapped half-word', () {
      final keys = VieraKeys.forSession('AAECAwQFBgcICQoLDA0ODw==');
      expect(_hex(keys.aesKey), '02030001060704050a0b08090e0f0c0d');
      final sealed = vieraSeal(
        keys,
        '<X_ApplicationId>AfJlsBxpemLTXw==</X_ApplicationId>',
        header: _clientHeader,
      );
      expect(
        sealed,
        'm0ndUXxSn26SDqV2jNd//hotKOewoJkAeOG31adsuEmxs0M+/8msGGgTVme79c3w6uw9'
        'PLxIt966s86+T5oQVsbVIncuDMqALeXmgpoprAl3jGlhiPmPKmjONqSXTrobCu86E8Mc'
        'fMuxM/pbXZzWmg==',
      );
      // A 16-character app id gives exactly the 525-byte body of the
      // captured X_GetEncryptSessionId request.
      expect(
        utf8.encode(
          soapEnvelope(
            VieraUrnForTests.nrc,
            'X_GetEncryptSessionId',
            '<X_ApplicationId>AfJlsBxpemLTXw==</X_ApplicationId>'
                '<X_EncInfo>$sealed</X_EncInfo>',
          ),
        ),
        hasLength(525),
      );
    });

    test('rejects a keyword that is not 16 bytes of base64', () {
      expect(() => VieraKeys.forSession('AQID'), throwsFormatException);
    });
  });

  group('X_GetEncryptSessionId', () {
    final keys = VieraKeys.forSession('ICEiIyQlJicoKSorLC0uLw==');

    test('X_EncInfo for app id AQIDBAUGBwgJCg==', () {
      expect(
        vieraSeal(
          keys,
          '<X_ApplicationId>AQIDBAUGBwgJCg==</X_ApplicationId>',
          header: _clientHeader,
        ),
        'L7TTRh53q8EVnN4LG7Z+rd7ov4lGaIA0cHQQVGBnLjdEXWI7hwuVgETPCvOdjqGq6vg2'
        'hiNtQhINZ1x4eG40LRVsmyOj+AUejYjPiAfSlwy45Isapm6BOJ/KASJ2af5hqp+bWSQ4'
        'jUkDOjK88wOabw==',
      );
    });

    test('X_EncResult decrypts to the session id', () {
      final opened = vieraOpen(
        keys,
        'e9KrOww/oBfi5qXPYI23+p07o49zVw7WuPEinNCV78AGgtkAwJUT7uCoLYpjxV9RTNtz'
        'zMYU/G8iFGCekoElzITADQC9uwMRkEWEoF+Rfe9mvoBOq+hhiGSJoYIwaf6I',
      );
      expect(opened.text, '<X_SessionId>12345</X_SessionId>');
      expect(opened.macOk, isTrue);
    });
  });

  group('X_EncryptedCommand', () {
    final keys = VieraKeys.forSession('ICEiIyQlJicoKSorLC0uLw==');
    const inner =
        '<X_SessionId>12345</X_SessionId>'
        '<X_SequenceNumber>00000002</X_SequenceNumber>'
        '<X_OriginalCommand><u:X_SendKey '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">'
        '<X_KeyEvent>NRC_VOLUP-ONOFF</X_KeyEvent></u:X_SendKey>'
        '</X_OriginalCommand>';
    const expected =
        'mw4yfYiEzlNHhak3rQJMEQrL33r4YmaasDVcucexRVE6f/1BupBp2IpZzCiGXxOd58GM'
        'NwFSdW5ry4G+k6QBYzKLbfyQgM6w6zK0dWGf+AZK/auSQA8Xf0nmVVrJLdtPMGgnvawS'
        'gYjiizc4lzzDNLAzorFZn47QvhOLj3+t4QaH9MWBr9EnQGlhmGq3+6qSBFNh4Ap8Hnx+'
        'DAiXwqqXr1fT8/X0XMwc6WKA6mKRDt5anEgEPwUiCwI6+rXnPaZlpfOFsB33SGuRoUPZ'
        '1ImQTxnR1KMi3yPLxDN9NpnpicdKaXSJ6RSaRe9dPXjv+/xXsZ9MXL2ItvkdFCqyt9vp'
        'Ylje+T7Fgl5f4tyhZ/MCi3kLE630zV5yhVLJN3/oI1Sd';

    test('NRC_VOLUP in session 12345, sequence 2 (1 pad byte)', () {
      expect(utf8.encode(inner), hasLength(239));
      expect(
        encryptedCommandPlaintext('12345', 2, 'X_SendKey', _volUpArgs),
        inner,
      );
      final sealed = vieraSeal(keys, inner, header: _clientHeader);
      expect(sealed, expected);
      expect(
        _hex(base64.decode(sealed).sublist(256)),
        '58def93ec5825e5fe2dca167f3028b790b13adf4cd5e728552c9377fe823549d',
      );
      expect(
        utf8.encode(
          soapEnvelope(
            VieraUrnForTests.nrc,
            'X_EncryptedCommand',
            '<X_ApplicationId>AQIDBAUGBwgJCg==</X_ApplicationId>'
                '<X_EncInfo>$sealed</X_EncInfo>',
          ),
        ),
        hasLength(751),
      );
    });

    const answer =
        '<u:X_SendKeyResponse '
        'xmlns:u="urn:panasonic-com:service:p00NetworkControl:1">'
        '</u:X_SendKeyResponse>';

    test('the synthetic answer decrypts with a valid MAC', () {
      final opened = vieraOpen(
        keys,
        'XEgAD1QIu7iP+uR7fSOpmcXWBR/ICaXUPx4tArhZNaDvoEo5cUdNOkjBqHucbbNHMQ1V'
        'rwuxRy0mxWaur5NjCQtHKNPkMuG9hUAHZ4rwb8QG78zLZdGBbMB0x9m8xdeIb7vetJLR'
        'P0Af18A2JkljydwrNlEZszPrPzFhKS4wkZxsbS/1QdZO7Prizm1naX11KCaeiFZeMTo2'
        'jMGimxtoLg==',
      );
      expect(opened.text, answer);
      expect(opened.macOk, isTrue);
    });

    test('a garbage length field (ffffffff) still decodes', () {
      final opened = vieraOpen(
        keys,
        '4PB/lqUYWBpaJ6OZFlqT1OvEU7UBL5VrucrEjYnBukqAcIiv5rOMlXCSR3pLOXOVnqSV'
        'OMELeh/r065kiqmyCMMlWlWwhMgG7AK+CB7GV35YzrXJnENpAPSiDpeOO/yMTPxCAQNC'
        'wG8mb0ktMu9BjsmAdEu55eFx3OU4ByqNKWqAKs9qFb1W0PfAlSNImiDcLOvUYIKxC2Qz'
        '4W7e9lUoVg==',
      );
      expect(opened.text, answer);
      expect(opened.macOk, isTrue);
    });

    test('an answer without the trailing HMAC still decodes', () {
      final opened = vieraOpen(
        keys,
        'XEgAD1QIu7iP+uR7fSOpmcXWBR/ICaXUPx4tArhZNaDvoEo5cUdNOkjBqHucbbNHMQ1V'
        'rwuxRy0mxWaur5NjCQtHKNPkMuG9hUAHZ4rwb8QG78zLZdGBbMB0x9m8xdeIb7vetJLR'
        'P0Af18A2JkljydwrNlEZszPrPzFhKS4wkZw=',
      );
      expect(opened.text, answer);
      expect(opened.macOk, isFalse);
    });
  });

  group('framing', () {
    final keys = VieraKeys.forSession('ICEiIyQlJicoKSorLC0uLw==');

    test('an aligned payload gets a whole block of zero padding', () {
      // 16 + 32 = 48 bytes: one more block, never zero pad bytes.
      final sealed = vieraSeal(keys, 'x' * 32, header: _clientHeader);
      expect(base64.decode(sealed), hasLength(64 + 32));
    });

    test('the length field is the UTF-8 byte length', () {
      final sealed = vieraSeal(keys, 'é€', header: _clientHeader);
      final raw = base64.decode(sealed);
      final plain = _decryptRaw(keys, raw.sublist(0, raw.length - 32));
      expect(_hex(plain.sublist(12, 16)), '00000005');
      expect(vieraOpen(keys, sealed).text, 'é€');
    });

    test('garbage is a FormatException, never a crash', () {
      expect(() => vieraOpen(keys, '%%%'), throwsFormatException);
      expect(
        () => vieraOpen(keys, base64.encode([1, 2, 3])),
        throwsFormatException,
      );
      // Decrypting with the wrong keys yields bytes that are not UTF-8 or
      // have no terminator.
      final other = VieraKeys.forSession('AAECAwQFBgcICQoLDA0ODw==');
      final sealed = vieraSeal(keys, '<X_SessionId>1</X_SessionId>');
      expect(() => vieraOpen(other, sealed), throwsFormatException);
    });
  });
}

const String _volUpArgs = '<X_KeyEvent>NRC_VOLUP-ONOFF</X_KeyEvent>';

Uint8List _decryptRaw(VieraKeys keys, List<int> raw) =>
    vieraDecryptBlocks(keys, raw);

/// Test alias for the NRC URN (keeps the vectors readable).
abstract final class VieraUrnForTests {
  static const String nrc = 'urn:panasonic-com:service:p00NetworkControl:1';
}
