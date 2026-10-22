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
          keep: fireTvKeptWords,
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

    // Codex re-review of finding #8: `keepProse` kept strings shaped like
    // words, but a token may be any printable text, spaces included, so
    // HTTP 403 {"description":"secret bearer words"} kept its token.
    test('allValues removes words too: a token may look like prose', () {
      expect(
        redactSecrets(
          '{"description":"secret bearer words","other":"S3cr3tTok",'
          '"msg":"Bad arguments supplied. Please check."}',
          allValues: true,
        ),
        '{"description":"<redacted>","other":"<redacted>",'
        '"msg":"<redacted>"}',
      );
      for (final text in [
        'PIN expired',
        'secret bearer words',
        'S3cr3tTok',
        'a  b',
      ]) {
        expect(
          redactSecrets(text, allValues: true),
          '<redacted> (${text.length} characters, not JSON)',
          reason: text,
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

      test('text around a secret keeps its escapes', () {
        expect(
          redactSecrets(
            r'a\/b abc\/tok\/123 %2F tok%2D1',
            secrets: ['abc/tok/123', 'tok-1'],
          ),
          r'a\/b <redacted> %2F <redacted>',
        );
      });
    });

    // Codex re-review of finding #8: secrets were replaced one after the
    // other, so the `X-Api-Key` value, a prefix of this token, was
    // replaced first and left `<redacted>-SecretSuffix`, from which the
    // public key rebuilds the token.
    group('removes overlapping secrets whole', () {
      const apiKey = '0987654321';
      const token = '$apiKey-SecretSuffix';

      for (final (name, text) in [
        ('the token alone', 'bad token $token'),
        ('the token as a suffix', 'bad token x$token'),
        ('the token as an infix', 'x${token}y and z${token}0987'),
        ('the API key alone elsewhere', 'key $apiKey, token $token'),
        ('the key right after the token', '$token$apiKey'),
        ('JSON-escaped', jsonEncode({'e': 'bad token $token'})),
        ('JSON \\u escapes', r'{"e":"bad 0987654321-SecretSuffix"}'),
        ('percent-encoded', 'token=0987654321%2DSecretSuffix'),
        ('percent-encoded twice', 'token=0987654321%252DSecretSuffix'),
        (
          'escaped JSON inside JSON',
          jsonEncode({
            'e': jsonEncode({'t': token}).replaceAll('-', r'-'),
          }),
        ),
        ('escaped, not JSON', r'<p>0987654321-SecretSuffix</p>'),
      ]) {
        test(name, () {
          final out = redactSecrets(text, secrets: [apiKey, token]);
          expectNoTokenFragment(out, token, public: apiKey);
          expect(out, contains(redactedText));
        });
      }

      test('either order of the secrets', () {
        for (final secrets in [
          [apiKey, token],
          [token, apiKey],
        ]) {
          expect(
            redactSecrets('a $token b $apiKey c', secrets: secrets),
            'a <redacted> b <redacted> c',
          );
        }
      });

      test('a secret inside the other, or overlapping its end', () {
        // A token inside the API key.
        expect(
          redactSecrets('k=$apiKey t=87654', secrets: [apiKey, '87654']),
          'k=<redacted> t=<redacted>',
        );
        // A token whose end overlaps the start of the API key.
        const before = 'SecretSuffix0987';
        final out = redactSecrets(
          'x ${before}654321 y',
          secrets: [apiKey, before],
        );
        expect(out, 'x <redacted> y');
        expectNoTokenFragment(out, before, public: apiKey);
      });

      test('overlapping occurrences of one secret', () {
        expect(redactSecrets('xababay', secrets: ['aba']), 'x<redacted>y');
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

/// Expects [text] to hold no run of more than 3 characters of [secret],
/// except runs of the [public] value (the `X-Api-Key`, which every
/// client sends).
void expectNoTokenFragment(String text, String secret, {String public = ''}) {
  for (var i = 0; i + 4 <= secret.length; i++) {
    final fragment = secret.substring(i, i + 4);
    if (public.contains(fragment)) continue;
    expect(text, isNot(contains(fragment)), reason: '"$fragment" in $text');
  }
}

class _NoNetwork implements NetworkStack {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
