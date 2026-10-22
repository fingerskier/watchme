import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';

void main() {
  group('redactSharpSecrets', () {
    test('keeps text with nothing to redact verbatim', () {
      expect(redactSharpSecrets('ERR', ['admin', 'secret1']), 'ERR');
      expect(redactSharpSecrets('anything', const []), 'anything');
    });

    test('removes every occurrence, verbatim and trimmed', () {
      expect(
        redactSharpSecrets('bad admin/secret1 then secret1', [
          'admin',
          'secret1',
        ]),
        'bad <redacted>/<redacted> then <redacted>',
      );
      expect(
        redactSharpSecrets('[pw]', [' pw ']),
        '[<redacted>]',
        reason: 'a secret with blanks around it is also found trimmed',
      );
    });

    test('a secret inside another leaves nothing of either', () {
      for (final secrets in [
        ['abcdef', 'cde'],
        ['cde', 'abcdef'],
      ]) {
        expect(redactSharpSecrets('x abcdef y', secrets), 'x <redacted> y');
      }
      expect(redactSharpSecrets('abcd', ['abc', 'bcd']), '<redacted>');
      expect(redactSharpSecrets('aaaa', ['aa']), '<redacted>');
    });

    test('keeps the TV\'s own texts whole, so a common-word password is '
        'not revealed by a cut', () {
      const text = '\r\nUser Name or Password mismatch\r\nLogin:';
      expect(redactSharpSecrets(text, ['Password', 'Name']), text);
      expect(
        redactSharpSecrets('Password: Password', ['Password']),
        'Password: <redacted>',
      );
    });

    test('a secret straddling a TV text is still removed', () {
      expect(redactSharpSecrets('zLogin:', ['zLog']), '<redacted>in:');
    });

    test('blank secrets are ignored', () {
      expect(redactSharpSecrets('a b', ['', ' ']), 'a b');
    });
  });

  group('redactSharpError', () {
    test('returns the same error when nothing changes', () {
      const e = WatchmeError.rejected(
        'The TV refused volume',
        rawDeviceMessage: 'ERR',
      );
      expect(identical(redactSharpError(e, ['secret1']), e), isTrue);
    });

    test('redacts message, raw text and causes', () {
      final e = WatchmeError.reauthRequired(
        'refused admin',
        rawDeviceMessage: 'mismatch for admin/secret1',
        cause: WatchmeError.protocol(
          'inner secret1',
          cause: Exception('secret1'),
        ),
      );
      final r = redactSharpError(e, ['admin', 'secret1']);
      expect(r.code, WatchmeErrorCode.reauthRequired);
      expect(r.message, 'refused <redacted>');
      expect(r.rawDeviceMessage, 'mismatch for <redacted>/<redacted>');
      final cause = r.cause! as WatchmeError;
      expect(cause.message, 'inner <redacted>');
      expect('${cause.cause}', isNot(contains('secret1')));
      expect('$r', isNot(contains('secret1')));
    });
  });
}
