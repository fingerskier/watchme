import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/src/redaction.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';

import 'support/fake_viera.dart';

/// Every form a secret might take in an error.
List<String> _forms(String secret) => [
  secret,
  Uri.encodeComponent(secret),
  secret.replaceAll('/', '&#x2F;').replaceAll('+', '&#43;'),
];

void _expectClean(String text, List<String> secrets) {
  for (final s in secrets) {
    for (final form in _forms(s)) {
      expect(text, isNot(contains(form)), reason: 'leaked $form in $text');
    }
  }
}

void main() {
  group('redactViera', () {
    test('replaces the content of every secret element, with any prefix', () {
      for (final name in vieraSecretElements) {
        expect(
          redactViera('<a><v:$name x="1">s3cr3t</v:$name></a>'),
          '<a><v:$name x="1"><redacted></v:$name></a>',
          reason: name,
        );
      }
      expect(redactViera('<X_PinCode></X_PinCode>'), '<X_PinCode></X_PinCode>');
    });

    test('finds secret elements whose markup is escaped', () {
      expect(
        redactViera('echo: &lt;X_PinCode&gt;4410&lt;/X_PinCode&gt; done'),
        'echo: &lt;X_PinCode&gt;<redacted>&lt;/X_PinCode&gt; done',
      );
    });

    test('strips known values verbatim, percent-encoded and as character '
        'references, keeping the other words', () {
      const key = 'ICEi/yQlJic+KSorLC0uLw==';
      final text =
          'bad key $key in ${Uri.encodeComponent(key)} and '
          '${key.replaceAll('/', '&#x2F;')} (errorCode 501)';
      final clean = redactViera(text, secrets: [key]);
      _expectClean(clean, [key]);
      expect(clean, contains('bad key <redacted> in <redacted> and'));
      expect(clean, contains('(errorCode 501)'));
    });

    test('a secret inside another leaves no fragment of either', () {
      const outer = 'AAAAinnerBBBB';
      const inner = 'inner';
      final clean = redactViera('x AAAAinnerBBBB y', secrets: [inner, outer]);
      expect(clean, 'x <redacted> y');
    });

    test('is idempotent and leaves text without secrets alone', () {
      const text = '<errorCode>401</errorCode> Invalid Action';
      expect(redactViera(text, secrets: ['zzz']), text);
      final once = redactViera('<X_EncInfo>abc</X_EncInfo>');
      expect(redactViera(once), once);
    });

    test('redactVieraError cleans message, raw text and causes', () {
      const secret = 'ICEiIyQlJicoKSorLC0uLw==';
      const error = WatchmeError.rejected(
        'refused $secret',
        rawDeviceMessage: '<X_Keyword>$secret</X_Keyword>',
        cause: WatchmeError.timeout('inner $secret'),
      );
      final clean = redactVieraError(error, [secret]);
      expect(clean.code, WatchmeErrorCode.rejected);
      expect(clean.message, 'refused <redacted>');
      expect(clean.rawDeviceMessage, '<X_Keyword><redacted></X_Keyword>');
      expect((clean.cause! as WatchmeError).message, 'inner <redacted>');
      const tidy = WatchmeError.rejected('nothing here');
      expect(identical(redactVieraError(tidy, [secret]), tidy), isTrue);
    });
  });

  group('the session never shows the app id or keyword', () {
    test('in a refusal that echoes them, in events, or in toString', () async {
      final tv = FakeViera();
      final echo = FakeViera.fault(
        501,
        'app $fakeAppId key $fakeKeyword '
        '${Uri.encodeComponent(fakeKeyword)}',
      );
      tv.handlers['X_SendKey'] = (_) => echo;
      final driver = PanasonicDriver(pollInterval: null);
      final session = await driver.connect(
        tv.endpoint,
        tv.transports,
        tv.credential,
      );
      final events = <DeviceEvent>[];
      session.events.listen(events.add);
      tv.innerActions.clear();
      final result = await session.execute(const PressKey(RemoteKey.home));
      final error = (result as Failed).error;
      expect(error.code, WatchmeErrorCode.rejected);
      // The refusal was retried once on a fresh session, then reported.
      expect(tv.innerActions, ['X_SendKey', 'X_SendKey']);
      expect(error.rawDeviceMessage, contains('<redacted>'));
      _expectClean(jsonEncode(result.toJson()), [fakeAppId, fakeKeyword]);
      _expectClean('$error ${error.cause}', [fakeAppId, fakeKeyword]);
      _expectClean(session.toString(), [fakeAppId, fakeKeyword]);
      await session.close();
      _expectClean(jsonEncode([for (final e in events) e.toJson()]), [
        fakeAppId,
        fakeKeyword,
      ]);
    });

    test('in a re-pair error whose body echoes the encrypted blobs', () async {
      final tv = FakeViera()..pacOn = true;
      tv.handlers['X_GetEncryptSessionId'] = (call) =>
          HttpResult.text(500, 'refused ${call.bodyText}');
      final driver = PanasonicDriver(pollInterval: null);
      await expectLater(
        driver.connect(tv.endpoint, tv.transports, tv.credential),
        throwsA(
          isA<WatchmeError>()
              .having((e) => e.code, 'code', WatchmeErrorCode.reauthRequired)
              .having(
                (e) => '${e.message} ${e.rawDeviceMessage}',
                'text',
                allOf(
                  isNot(contains(fakeAppId)),
                  contains('<X_EncInfo><redacted></X_EncInfo>'),
                ),
              ),
        ),
      );
    });
  });

  group('pairing never shows the PIN, the challenge or the new key', () {
    const challenge = 'mUQdS7/RyJTMsiojPz9i1Q==';

    FakeViera pairingTv() {
      final tv = FakeViera();
      tv.handlers['X_DisplayPinCode'] = (_) => FakeViera.answer(
        'X_DisplayPinCode',
        '<X_ChallengeKey>$challenge</X_ChallengeKey>',
      );
      return tv;
    }

    Future<List<PairingStep>> pair(FakeViera tv) async {
      final flow = PanasonicDriver().startPairing(
        tv.endpoint,
        tv.transports,
        const PairingContext(deviceId: 'tv'),
      )!;
      final steps = <PairingStep>[];
      await for (final step in flow.steps) {
        steps.add(step);
        if (step is EnterCode) flow.submit('4410');
      }
      return steps;
    }

    test('in wrong-PIN faults that echo the PIN and the challenge', () async {
      final tv = pairingTv();
      tv.handlers['X_RequestAuth'] = (call) =>
          FakeViera.fault(600, 'PIN 4410 for $challenge: ${call.bodyText}');
      final steps = await pair(tv);
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.unauthorized);
      expect(failed.error.message, 'Wrong PIN (3 attempts)');
      final text = jsonEncode([for (final s in steps) s.toJson()]);
      _expectClean(text, [challenge, '4410']);
      expect(text, contains('<X_AuthInfo><redacted></X_AuthInfo>'));
    });

    test('in a verification failure that echoes the new key', () async {
      final tv = pairingTv();
      final keys = VieraKeysForTest.pairing(challenge);
      tv.handlers['X_RequestAuth'] = (_) => FakeViera.answer(
        'X_RequestAuth',
        '<X_AuthResult>${keys.seal('<X_ApplicationId>$fakeAppId</X_ApplicationId>\n<X_Keyword>$fakeKeyword</X_Keyword>')}</X_AuthResult>',
      );
      tv.handlers['X_GetEncryptSessionId'] = (_) =>
          HttpResult.text(500, 'cannot use $fakeAppId / $fakeKeyword');
      final steps = await pair(tv);
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.protocol);
      _expectClean(jsonEncode([for (final s in steps) s.toJson()]), [
        challenge,
        fakeAppId,
        fakeKeyword,
      ]);
      _expectClean('${failed.error.cause}', [fakeAppId, fakeKeyword]);
    });

    test('Paired steps carry the credential only to the store', () async {
      final tv = pairingTv();
      final keys = VieraKeysForTest.pairing(challenge);
      tv.handlers['X_RequestAuth'] = (_) => FakeViera.answer(
        'X_RequestAuth',
        '<X_AuthResult>${keys.seal('<X_ApplicationId>$fakeAppId</X_ApplicationId>\n<X_Keyword>$fakeKeyword</X_Keyword>')}</X_AuthResult>',
      );
      final steps = await pair(tv);
      final paired = steps.last as Paired;
      final credential = paired.credential! as SharedSecretCredential;
      expect(credential.username, fakeAppId);
      expect(credential.secret, fakeKeyword);
      _expectClean(jsonEncode([for (final s in steps) s.toJson()]), [
        fakeAppId,
        fakeKeyword,
      ]);
      _expectClean(credential.toString(), [fakeAppId, fakeKeyword]);
    });
  });
}
