import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';

// The TV side of the VIERA NRC encryption, written from the byte-level
// description in the watchme research brief (section 5.1). It is kept apart
// from the driver's implementation, and uses a different HMAC library, so
// that the two check each other. No code was copied from any client.

const List<int> _pairingMask = [
  0x15, 0xc9, 0x5a, 0xc2, 0xb0, 0x8a, 0xa7, 0xeb, //
  0x4e, 0x22, 0x8f, 0x81, 0x1e, 0x34, 0xd0, 0x4f,
  0xa5, 0x4b, 0xa7, 0xdc, 0xac, 0x98, 0x79, 0xfa,
  0x8a, 0xcd, 0xa3, 0xfc, 0x24, 0x4f, 0x38, 0x54,
];

/// One key set as the simulated TV derives it.
final class PanasonicSimKeys {
  PanasonicSimKeys._(this.aesKey, this.iv, this.hmacKey);

  /// Keys from the 16 challenge bytes the TV sends with the PIN.
  factory PanasonicSimKeys.pairing(List<int> challenge) {
    final iv = Uint8List.fromList(challenge);
    final key = Uint8List(16);
    for (var i = 0; i < 16; i += 4) {
      for (var j = 0; j < 4; j++) {
        key[i + j] = (~iv[i + 3 - j]) & 0xff;
      }
    }
    final mac = Uint8List(32);
    for (var i = 0; i < 32; i += 4) {
      mac[i] = _pairingMask[i] ^ iv[(i + 2) % 16];
      mac[i + 1] = _pairingMask[i + 1] ^ iv[(i + 3) % 16];
      mac[i + 2] = _pairingMask[i + 2] ^ iv[i % 16];
      mac[i + 3] = _pairingMask[i + 3] ^ iv[(i + 1) % 16];
    }
    return PanasonicSimKeys._(key, iv, mac);
  }

  /// Keys from the 16 keyword bytes issued at pairing.
  factory PanasonicSimKeys.session(List<int> keyword) {
    final iv = Uint8List.fromList(keyword);
    final key = Uint8List.fromList([
      for (var i = 0; i < 16; i += 4) ...[
        iv[i + 2],
        iv[i + 3],
        iv[i],
        iv[i + 1],
      ],
    ]);
    return PanasonicSimKeys._(key, iv, Uint8List.fromList([...iv, ...iv]));
  }

  final Uint8List aesKey;
  final Uint8List iv;
  final Uint8List hmacKey;

  Uint8List mac(List<int> data) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, hmacKey).convert(data).bytes,
  );

  Uint8List cbc(List<int> data, {required bool encrypt}) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(encrypt, ParametersWithIV(KeyParameter(aesKey), iv));
    final input = Uint8List.fromList(data);
    final out = Uint8List(input.length);
    for (var o = 0; o < input.length; o += 16) {
      cipher.processBlock(input, o, out, o);
    }
    return out;
  }

  @override
  String toString() => 'PanasonicSimKeys(<test keys>)';
}

/// Why the simulated TV refused a client's encrypted payload.
enum PanasonicSimCryptoFailure {
  /// Not base64.
  notBase64,

  /// Shorter than one block plus the MAC, or not whole blocks.
  badLength,

  /// The trailing HMAC does not verify.
  badMac,

  /// The length field points past the data, or (strict) leaves no pad
  /// byte.
  badLengthField,

  /// The payload is not UTF-8.
  notUtf8,
}

/// The outcome of opening a client payload.
typedef PanasonicSimOpened = ({
  String? payload,
  PanasonicSimCryptoFailure? failure,
});

/// Opens a client payload (`X_AuthInfo`, `X_EncInfo`), checking in the
/// order the brief gives: length, HMAC, then the length field, which is
/// how the TV finds the payload (never by scanning for a zero byte: PKCS#7
/// padding is accepted too). With [strictPadding] a payload with no pad
/// byte at all is refused.
PanasonicSimOpened panasonicSimOpen(
  PanasonicSimKeys keys,
  String text, {
  required bool strictPadding,
}) {
  final Uint8List raw;
  try {
    raw = base64.decode(text.trim());
  } on FormatException {
    return (payload: null, failure: PanasonicSimCryptoFailure.notBase64);
  }
  if (raw.length < 48 || (raw.length - 32) % 16 != 0) {
    return (payload: null, failure: PanasonicSimCryptoFailure.badLength);
  }
  final cipherText = raw.sublist(0, raw.length - 32);
  final tag = raw.sublist(raw.length - 32);
  final expected = keys.mac(cipherText);
  var diff = 0;
  for (var i = 0; i < 32; i++) {
    diff |= expected[i] ^ tag[i];
  }
  if (diff != 0) {
    return (payload: null, failure: PanasonicSimCryptoFailure.badMac);
  }
  final plain = keys.cbc(cipherText, encrypt: false);
  final n = ByteData.sublistView(plain).getUint32(12);
  final end = 16 + n;
  if (end > plain.length || (strictPadding && end >= plain.length)) {
    return (payload: null, failure: PanasonicSimCryptoFailure.badLengthField);
  }
  try {
    return (payload: utf8.decode(plain.sublist(16, end)), failure: null);
  } on FormatException {
    return (payload: null, failure: PanasonicSimCryptoFailure.notUtf8);
  }
}

/// Seals an answer the way the TV does: a random 12-byte header, a
/// meaningless length field (real TVs never send a valid one), the payload,
/// at least one zero byte of padding (never PKCS#7: clients cut at the
/// first zero byte), and, with [withMac], the trailing HMAC.
String panasonicSimSeal(
  PanasonicSimKeys keys,
  String payload,
  Random random, {
  bool withMac = true,
}) {
  final data = utf8.encode(payload);
  final used = 16 + data.length;
  final plain = Uint8List(used + 16 - used % 16);
  for (var i = 0; i < 16; i++) {
    plain[i] = random.nextInt(256);
  }
  plain.setRange(16, used, data);
  final cipherText = keys.cbc(plain, encrypt: true);
  return base64.encode([...cipherText, if (withMac) ...keys.mac(cipherText)]);
}

/// Seals a client payload, for tests that play the client: zero padding
/// by default, PKCS#7 with [pkcs7], or no pad byte at all with [noPad] when
/// the payload is already aligned (FHEM's zero-padding mode).
String panasonicSimClientSeal(
  PanasonicSimKeys keys,
  String payload, {
  List<int> header = const [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
  bool pkcs7 = false,
  bool noPad = false,
}) {
  final data = utf8.encode(payload);
  final used = 16 + data.length;
  var pad = 16 - used % 16;
  if (noPad && pad == 16) pad = 0;
  final plain = Uint8List(used + pad)
    ..setRange(0, 12, header)
    ..setRange(16, used, data);
  ByteData.sublistView(plain).setUint32(12, data.length);
  if (pkcs7) plain.fillRange(used, used + pad, pad);
  final cipherText = keys.cbc(plain, encrypt: true);
  return base64.encode([...cipherText, ...keys.mac(cipherText)]);
}
