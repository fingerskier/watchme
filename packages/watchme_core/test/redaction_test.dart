import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

// The shared redactor every driver runs device text through. The Fire TV
// and VIZIO driver suites test it again with their own protocols' bodies.
void main() {
  group('isSecretFieldName', () {
    test('knows tokens, auth values, keys, PINs and passwords', () {
      for (final name in [
        'token',
        'clientToken',
        'X-Client-Token',
        'AUTH_TOKEN',
        'PAIRING_REQ_TOKEN',
        'AUTH',
        'X-Api-Key',
        'RESPONSE_VALUE',
        'pin',
        'secret',
        'Password',
      ]) {
        expect(isSecretFieldName(name), isTrue, reason: name);
      }
      for (final name in ['description', 'STATUS', 'RESULT', 'name', 'n']) {
        expect(isSecretFieldName(name), isFalse, reason: name);
      }
    });
  });

  group('redactSecrets', () {
    test('keeps text with nothing to redact verbatim', () {
      const body = '{ "description" : "authn error" }';
      expect(redactSecrets(body, secrets: ['tok-1']), body);
      expect(redactSecrets('', allValues: true), '');
      expect(redactSecrets('HTTP 500', secrets: ['tok-1']), 'HTTP 500');
    });

    test('removes secret fields at any depth, numbers included', () {
      final clean = jsonDecode(
        redactSecrets(
          '{"a":{"AUTH_TOKEN":"x1","AUTH":"k","n":2},'
          '"list":[{"token":12345}],"RESPONSE_VALUE":"1234",'
          '"description":"kept"}',
        ),
      ) as Map<String, Object?>;
      expect(clean['a'], {
        'AUTH_TOKEN': redactedText,
        'AUTH': redactedText,
        'n': 2,
      });
      expect(clean['list'], [
        {'token': redactedText},
      ]);
      expect(clean['RESPONSE_VALUE'], redactedText);
      expect(clean['description'], 'kept');
    });

    test('allValues removes every value except the kept words', () {
      expect(
        redactSecrets(
          '{"description":"secret bearer words","ok":"OK","empty":"",'
          '"n":1,"b":true,"z":null}',
          allValues: true,
          keep: const {'OK'},
        ),
        '{"description":"<redacted>","ok":"OK","empty":"",'
        '"n":"<redacted>","b":true,"z":null}',
      );
      expect(
        redactSecrets('{"r":"OK"}', allValues: true),
        '{"r":"<redacted>"}',
        reason: 'nothing is kept unless named',
      );
      expect(
        redactSecrets('plain-token', allValues: true),
        '<redacted> (11 characters, not JSON)',
      );
    });

    test('removes a secret verbatim, trimmed or JSON-escaped', () {
      const secret = 'tok\n"x';
      expect(
        redactSecrets(
          'raw tok\n"x, trimmed tok\n"x!, escaped "tok\\n\\"x"',
          secrets: [secret],
        ),
        'raw <redacted>, trimmed <redacted>!, escaped "<redacted>"',
      );
      expect(
        redactSecrets('abc tok-1 def', secrets: ['  tok-1  ']),
        'abc <redacted> def',
      );
      expect(redactSecrets('kept', secrets: ['', ' ']), 'kept');
    });

    test('removes a secret however the device escaped it', () {
      expect(
        redactSecrets(r'{"e":"bad abc\/tok\/123"}', secrets: ['abc/tok/123']),
        '{"e":"bad <redacted>"}',
      );
      expect(
        redactSecrets(r'<p>bad abc-tok-1</p>', secrets: ['abc-tok-1']),
        '<p>bad <redacted></p>',
      );
      expect(
        redactSecrets('token=tok%2B%2F%3D123', secrets: ['tok+/=123']),
        'token=<redacted>',
      );
      // Percent-encoded twice: %252F decodes to %2F, then to /.
      expect(
        redactSecrets('u=abc%252Ftok', secrets: ['abc/tok']),
        'u=<redacted>',
      );
      expect(
        redactSecrets(r'50% off, \/ and %2F', secrets: ['tok-1']),
        r'50% off, \/ and %2F',
      );
    });

    test('a secret inside another leaves nothing of either behind', () {
      const outer = 'KEY123-and-the-rest-of-the-token';
      const inner = 'KEY123';
      expect(
        redactSecrets('x $outer y $inner z', secrets: [inner, outer]),
        'x <redacted> y <redacted> z',
      );
    });
  });

  group('redactError', () {
    const token = 'Zm9v/YmFy+token==';

    test('redacts the message, the raw text and every cause', () {
      final error = WatchmeError.reauthRequired(
        'refused $token',
        rawDeviceMessage: '{"AUTH":"$token","STATUS":"x"}',
        cause: WatchmeError.protocol(
          'inner $token',
          cause: StateError('state $token'),
        ),
      );
      final clean = redactError(error, [token]);
      final shown = [
        clean.message,
        clean.rawDeviceMessage,
        '${clean.cause}',
        '$clean',
        jsonEncode(clean.toJson()),
      ].join('\n');
      expect(shown, isNot(contains(token)));
      expect(shown, isNot(contains('YmFy')));
      expect(clean.code, WatchmeErrorCode.reauthRequired);
      expect(clean.message, 'refused <redacted>');
      expect(
        (clean.cause! as WatchmeError).cause,
        'Bad state: state <redacted>',
      );
    });

    test('returns the error itself when nothing changed', () {
      const error = WatchmeError.rejected('no', rawDeviceMessage: 'plain');
      expect(identical(redactError(error, [token]), error), isTrue);
    });
  });
}
