import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  group('normalizeMac', () {
    test('accepts common separators and case', () {
      for (final input in [
        'AA:BB:CC:DD:EE:FF',
        'aa-bb-cc-dd-ee-ff',
        'aabb.ccdd.eeff',
        'AABBCCDDEEFF',
        ' aa:bb:cc:dd:ee:ff ',
      ]) {
        expect(normalizeMac(input), 'aa:bb:cc:dd:ee:ff', reason: input);
      }
    });

    test('rejects invalid input', () {
      for (final input in [
        '',
        'aa:bb:cc:dd:ee',
        'gg:bb:cc:dd:ee:ff',
        'aa:bb:cc:dd:ee:ff:00',
      ]) {
        expect(() => normalizeMac(input), throwsFormatException, reason: input);
        expect(tryNormalizeMac(input), isNull, reason: input);
      }
    });
  });

  test('macBytes', () {
    expect(macBytes('01-02-03-0a-0b-ff'), [1, 2, 3, 10, 11, 255]);
  });

  group('magicPacket', () {
    test('is 6 x 0xFF then 16 x the MAC', () {
      final packet = magicPacket('01:23:45:67:89:AB');
      expect(packet, hasLength(102));
      expect(packet.sublist(0, 6), List.filled(6, 0xff));
      const mac = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab];
      for (var i = 0; i < 16; i++) {
        expect(packet.sublist(6 + i * 6, 12 + i * 6), mac, reason: 'copy $i');
      }
    });

    test('is the same for every MAC spelling', () {
      expect(magicPacket('01-23-45-67-89-ab'), magicPacket('012345.6789ab'));
    });

    test('throws for an invalid MAC', () {
      expect(() => magicPacket('nope'), throwsFormatException);
    });
  });

  test('the conventional WoL port is 9', () {
    expect(wakeOnLanPort, 9);
  });
}
