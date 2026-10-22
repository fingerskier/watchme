import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  const token = 'Zm9v/YmFy+token==';

  group('redactSecrets', () {
    test('removes a secret in plain text and keeps the rest', () {
      expect(
        redactSecrets('refused AUTH $token today', secrets: [token]),
        'refused AUTH <redacted> today',
      );
    });

    test('removes JSON-escaped and percent-encoded forms', () {
      final escaped = jsonEncode({'x': 'a $token b'}).replaceAll('/', r'\/');
      expect(escaped, contains(r'\/'));
      expect(redactSecrets(escaped, secrets: [token]), isNot(contains('YmFy')));
      final percent = 'url=${Uri.encodeComponent(token)}&next=1';
      expect(redactSecrets(percent, secrets: [token]), 'url=<redacted>&next=1');
      final unicode = token.replaceAll('/', r'/');
      expect(redactSecrets('"$unicode"', secrets: [token]), '"<redacted>"');
    });

    test('a secret inside another leaves nothing of either', () {
      const outer = 'abcSECRETdef';
      const inner = 'SECRET';
      expect(
        redactSecrets('x $outer y', secrets: [inner, outer]),
        'x <redacted> y',
      );
    });

    test('secret fields are removed whatever their value', () {
      final text = jsonEncode({
        'AUTH': 'anything',
        'ITEM': {'AUTH_TOKEN': 'abc', 'PAIRING_REQ_TOKEN': 654321},
        'RESPONSE_VALUE': '1234',
        'STATUS': {'RESULT': 'FAILURE'},
      });
      final clean = jsonDecode(redactSecrets(text)) as Map<String, Object?>;
      expect(clean['AUTH'], redactedText);
      expect(clean['ITEM'], {
        'AUTH_TOKEN': redactedText,
        'PAIRING_REQ_TOKEN': redactedText,
      });
      expect(clean['RESPONSE_VALUE'], redactedText);
      expect(clean['STATUS'], {'RESULT': 'FAILURE'});
    });

    test('a body that needs no change is kept verbatim', () {
      const body = '{ "STATUS" : {"RESULT":"FAILURE"} }';
      expect(redactSecrets(body, secrets: [token]), body);
    });

    test('allValues removes every value but the kept words', () {
      final text = jsonEncode({
        'ITEM': {'X': 'words and spaces', 'N': 7},
        'STATUS': {'RESULT': 'PAIRING_DENIED', 'DETAIL': 'Denied'},
      });
      final clean = jsonDecode(
        redactSecrets(text, allValues: true, keep: const {'PAIRING_DENIED'}),
      ) as Map<String, Object?>;
      expect(clean['ITEM'], {'X': redactedText, 'N': redactedText});
      expect(clean['STATUS'], {
        'RESULT': 'PAIRING_DENIED',
        'DETAIL': redactedText,
      });
    });

    test('allValues removes a non-JSON body whole', () {
      expect(
        redactSecrets('plain $token', allValues: true),
        '<redacted> (23 characters, not JSON)',
      );
      expect(redactSecrets('', allValues: true), '');
    });

    test('a key holding a secret is scrubbed too', () {
      final text = jsonEncode({token: 1});
      expect(redactSecrets(text, secrets: [token]), isNot(contains('YmFy')));
    });

    test('blank secrets are ignored', () {
      expect(redactSecrets('a b', secrets: [' ', '']), 'a b');
    });
  });

  group('redactError', () {
    test('cleans the message, the raw text and the cause chain', () {
      final error = WatchmeError.rejected(
        'refused $token',
        rawDeviceMessage: '{"AUTH":"$token"}',
        cause: WatchmeError.protocol(
          'inner $token',
          cause: FormatException('bad $token'),
        ),
      );
      final clean = redactError(error, [token]);
      expect(clean.code, WatchmeErrorCode.rejected);
      expect(clean.message, 'refused <redacted>');
      expect(clean.rawDeviceMessage, '{"AUTH":"<redacted>"}');
      final inner = clean.cause! as WatchmeError;
      expect(inner.message, 'inner <redacted>');
      expect('${inner.cause}', isNot(contains(token)));
    });

    test('returns the same error when there is nothing to remove', () {
      const error = WatchmeError.timeout('slow');
      expect(identical(redactError(error, [token]), error), isTrue);
    });
  });
}
