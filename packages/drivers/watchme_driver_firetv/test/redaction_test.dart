import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/src/api.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

void main() {
  group('redactSecrets', () {
    test('keeps a body with nothing to redact verbatim', () {
      const body = '{ "description" : "authn error" }';
      expect(redactSecrets(body, secrets: ['tok-1']), body);
      expect(redactSecrets('', allValues: true), '');
      expect(redactSecrets('HTTP 500', secrets: ['tok-1']), 'HTTP 500');
    });

    test('removes token-bearing fields at any depth', () {
      expect(
        redactSecrets(
          '{"a":{"clientToken":"x1","X-Api-Key":"k","n":2},'
          '"list":[{"token":"y"}],"password":"p","description":"kept"}',
        ),
        '{"a":{"clientToken":"<redacted>","X-Api-Key":"<redacted>","n":2},'
        '"list":[{"token":"<redacted>"}],"password":"<redacted>",'
        '"description":"kept"}',
      );
      expect(
        redactSecrets('{"token":["a",{"v":"b"}],"access_token":""}'),
        '{"token":["<redacted>",{"v":"<redacted>"}],"access_token":""}',
      );
    });

    // Was `allStrings`, which kept numbers: a numeric token in
    // `description` stayed in the error (verifier follow-up to Codex
    // finding #8), so `"n":1` is now redacted too.
    test('allValues removes every string but "" and "OK", and every '
        'number', () {
      expect(
        redactSecrets(
          '{"description":"abc","ok":"OK","empty":"","n":1,"b":true,'
          '"z":null}',
          allValues: true,
        ),
        '{"description":"<redacted>","ok":"OK","empty":"",'
        '"n":"<redacted>","b":true,"z":null}',
      );
      expect(
        redactSecrets('{"description":987654321777}', allValues: true),
        '{"description":"<redacted>"}',
      );
      expect(
        redactSecrets('plain-token', allValues: true),
        '<redacted> (11 characters, not JSON)',
      );
    });

    test('keepProse keeps plain words and nothing token-shaped', () {
      expect(
        redactSecrets(
          '{"description":"PIN expired","other":"S3cr3tTok",'
          '"two":"abc def1","msg":"Bad arguments supplied. Please check."}',
          allValues: true,
          keepProse: true,
        ),
        '{"description":"PIN expired","other":"<redacted>",'
        '"two":"<redacted>","msg":"Bad arguments supplied. Please check."}',
      );
      expect(
        redactSecrets('PIN expired', allValues: true, keepProse: true),
        'PIN expired',
      );
      for (final token in ['S3cr3tTok', 'tok en\nx', 'abc\ndef', 'a  b']) {
        expect(
          redactSecrets(token, allValues: true, keepProse: true),
          startsWith('<redacted>'),
          reason: token,
        );
      }
    });

    test('a token-bearing field loses its numbers too', () {
      expect(
        redactSecrets('{"token":12345,"n":2}'),
        '{"token":"<redacted>","n":2}',
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

    group('removes a secret however the device escaped it', () {
      // Verifier follow-up to Codex finding #8: Android's org.json writes
      // `/` as `\/`, and a JSON decoder recovers the token from that.
      test('in a JSON body', () {
        expect(
          redactSecrets(r'{"e":"bad abc\/tok\/123"}', secrets: ['abc/tok/123']),
          '{"e":"bad <redacted>"}',
        );
        expect(
          redactSecrets(r'{"e":"bad \u0061bc-tok-1"}', secrets: ['abc-tok-1']),
          '{"e":"bad <redacted>"}',
        );
        expect(
          redactSecrets(
            r'{"e":"\u0074\u006F\u006B\u0031\u0032\u0033"}',
            secrets: ['tok123'],
          ),
          '{"e":"<redacted>"}',
        );
        expect(
          redactSecrets(r'{"abc\/t":1}', secrets: ['abc/t']),
          '{"<redacted>":1}',
        );
        expect(
          redactSecrets('{"code":987654}', secrets: ['987654']),
          '{"code":"<redacted>"}',
        );
      });

      test('in a JSON string inside a JSON string', () {
        final body = jsonEncode({
          'e': jsonEncode({'t': 'abc/tok/123'}).replaceAll('/', r'\/'),
        });
        final redacted = redactSecrets(body, secrets: ['abc/tok/123']);
        expect(redacted, isNot(contains('tok')));
        expect(redacted, contains(redactedText));
      });

      test('in text that is not JSON', () {
        expect(
          redactSecrets(
            r'token abc\/tok\/123 revoked',
            secrets: ['abc/tok/123'],
          ),
          'token <redacted> revoked',
        );
        expect(
          redactSecrets(r'<p>bad \u0061bc-tok-1</p>', secrets: ['abc-tok-1']),
          '<p>bad <redacted></p>',
        );
        expect(
          redactSecrets('token=tok%2B%2F%3D123', secrets: ['tok+/=123']),
          'token=<redacted>',
        );
        expect(
          redactSecrets(r'50% off, \/ and %2F', secrets: ['tok-1']),
          r'50% off, \/ and %2F',
          reason: 'text without a secret keeps its escapes',
        );
      });
    });
  });

  group('redactError', () {
    test('returns the same error when nothing changes', () {
      const error = WatchmeError.protocol('x', rawDeviceMessage: 'y');
      expect(redactError(error, ['tok-1']), same(error));
    });

    test('redacts message, raw text and causes', () {
      final error = WatchmeError.timeout(
        'msg tok-1',
        rawDeviceMessage: '{"token":"t"}',
        cause: WatchmeError.protocol(
          'inner',
          rawDeviceMessage: 'raw tok-1',
          cause: FormatException('bad', 'source tok-1'),
        ),
      );
      final redacted = redactError(error, ['tok-1']);
      expect(redacted.code, WatchmeErrorCode.timeout);
      expect(redacted.message, 'msg <redacted>');
      expect(redacted.rawDeviceMessage, '{"token":"<redacted>"}');
      final inner = redacted.cause! as WatchmeError;
      expect(inner.rawDeviceMessage, 'raw <redacted>');
      expect(inner.cause, isA<String>());
      expect('${inner.cause}', isNot(contains('tok-1')));
    });

    test('keeps a cause that holds no secret', () {
      final cause = StateError('nothing secret');
      final error = WatchmeError.internal('tok-1', cause: cause);
      expect(redactError(error, ['tok-1']).cause, same(cause));
    });
  });

  test('an error echoing the client token JSON-escaped loses it', () {
    final api = FireTvApi(
      const Endpoint('10.0.0.7'),
      _NoNetwork(),
      tls: TlsPolicy.platform,
      token: 'abc/tok/123',
    );
    final error = api.errorFor(
      HttpResult.text(500, r'{"e":"bad abc\/tok\/123"}'),
      'X',
    );
    expect(error.rawDeviceMessage, '{"e":"bad <redacted>"}');
  });

  test('FireTvApi knows its bearer values', () {
    final api = FireTvApi(
      const Endpoint('10.0.0.7'),
      _NoNetwork(),
      tls: TlsPolicy.platform,
      token: 'tok-1',
    );
    expect(api.secrets, ['0987654321', 'tok-1']);
    expect(
      api.errorFor(HttpResult.text(500, 'tok-1 0987654321'), 'X'),
      isWatchmeError(
        WatchmeErrorCode.protocol,
        rawDeviceMessage: '<redacted> <redacted>',
      ),
    );
  });
}

class _NoNetwork implements NetworkStack {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
