import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

// The NRC encryption scheme of 2018+ VIERA sets: AES-128-CBC with a fixed
// IV and HMAC-SHA-256 over the ciphertext, keyed from the pairing challenge
// or the stored keyword. Written from the byte-level description in the
// watchme research brief, which cross-checked panasonic-viera (MIT),
// homebridge-vieramatic (Apache-2.0), FastyBird's Viera connector
// (Apache-2.0) and two further clients, and was verified with two
// independent re-implementations against real `Content-Length` values. No
// code was copied.
//
// It is obfuscation rather than security: the challenge travels in plain
// text, so anyone who records the pairing can derive every key.

/// The 32-byte mask the pairing HMAC key is derived with (from the TV
/// vendor's `libtvconnect.so`, as published by the client libraries).
const List<int> _pairingHmacMask = [
  0x15, 0xc9, 0x5a, 0xc2, 0xb0, 0x8a, 0xa7, 0xeb, //
  0x4e, 0x22, 0x8f, 0x81, 0x1e, 0x34, 0xd0, 0x4f,
  0xa5, 0x4b, 0xa7, 0xdc, 0xac, 0x98, 0x79, 0xfa,
  0x8a, 0xcd, 0xa3, 0xfc, 0x24, 0x4f, 0x38, 0x54,
];

/// Length of the random header in front of every encrypted payload.
const int _headerLength = 12;

/// Length of the trailing HMAC-SHA-256.
const int _macLength = 32;

/// One key set: the AES-128 key, the CBC IV (fixed for the life of the
/// credential) and the HMAC-SHA-256 key.
///
/// [toString] never prints key material.
final class VieraKeys {
  VieraKeys._(this.aesKey, this.iv, this.hmacKey);

  /// The pairing keys derived from the `X_ChallengeKey` that
  /// `X_DisplayPinCode` returned (base64 of 16 bytes).
  ///
  /// Throws [FormatException] when [challenge] is not base64 of 16 bytes.
  factory VieraKeys.forPairing(String challenge) {
    final iv = _decode16(challenge, 'X_ChallengeKey');
    final key = Uint8List(16);
    for (var i = 0; i < 16; i += 4) {
      key[i] = ~iv[i + 3] & 0xff;
      key[i + 1] = ~iv[i + 2] & 0xff;
      key[i + 2] = ~iv[i + 1] & 0xff;
      key[i + 3] = ~iv[i] & 0xff;
    }
    final hmacKey = Uint8List(32);
    for (var i = 0; i < 32; i += 4) {
      hmacKey[i] = _pairingHmacMask[i] ^ iv[(i + 2) & 15];
      hmacKey[i + 1] = _pairingHmacMask[i + 1] ^ iv[(i + 3) & 15];
      hmacKey[i + 2] = _pairingHmacMask[i + 2] ^ iv[i & 15];
      hmacKey[i + 3] = _pairingHmacMask[i + 3] ^ iv[(i + 1) & 15];
    }
    return VieraKeys._(key, iv, hmacKey);
  }

  /// The session keys derived from the stored `X_Keyword` (base64 of 16
  /// bytes): the IV is the keyword, the AES key swaps the 16-bit halves of
  /// each 32-bit word, and the HMAC key is the keyword twice.
  ///
  /// Throws [FormatException] when [keyword] is not base64 of 16 bytes.
  factory VieraKeys.forSession(String keyword) {
    final iv = _decode16(keyword, 'X_Keyword');
    final key = Uint8List(16);
    for (var i = 0; i < 16; i += 4) {
      key[i] = iv[i + 2];
      key[i + 1] = iv[i + 3];
      key[i + 2] = iv[i];
      key[i + 3] = iv[i + 1];
    }
    return VieraKeys._(key, iv, Uint8List.fromList([...iv, ...iv]));
  }

  /// The AES-128 key.
  final Uint8List aesKey;

  /// The CBC initialisation vector.
  final Uint8List iv;

  /// The HMAC-SHA-256 key (32 bytes).
  final Uint8List hmacKey;

  @override
  String toString() => 'VieraKeys(<redacted>)';
}

Uint8List _decode16(String text, String what) {
  final Uint8List bytes;
  try {
    bytes = base64.decode(text.trim());
  } on FormatException {
    throw FormatException('$what is not base64');
  }
  if (bytes.length != 16) {
    throw FormatException('$what is ${bytes.length} bytes, not 16');
  }
  return bytes;
}

/// Encrypts [payload] for the TV with [keys] and returns the base64 text
/// that goes into `X_AuthInfo` or `X_EncInfo`.
///
/// Framing: 12 random bytes ([header] in tests), the payload's UTF-8 length
/// as a big-endian 32-bit number, the payload, and 1 to 16 zero bytes (at
/// least one: a client that sent none when the length was already a
/// multiple of 16 was refused a session). The ciphertext is followed by
/// its full 32-byte HMAC-SHA-256.
String vieraSeal(
  VieraKeys keys,
  String payload, {
  Random? random,
  List<int>? header,
}) {
  final data = utf8.encode(payload);
  final head =
      header ??
      () {
        final r = random ?? Random.secure();
        return [for (var i = 0; i < _headerLength; i++) r.nextInt(256)];
      }();
  if (head.length != _headerLength) {
    throw ArgumentError.value(header, 'header', 'must be 12 bytes');
  }
  final used = 16 + data.length;
  final padded = used + (16 - used % 16);
  final plain = Uint8List(padded)
    ..setRange(0, _headerLength, head)
    ..setRange(16, used, data);
  ByteData.sublistView(plain).setUint32(12, data.length);
  final cipherText = _cbc(keys, plain, encrypt: true);
  return base64.encode([...cipherText, ...vieraMac(keys, cipherText)]);
}

/// HMAC-SHA-256 of [data] under [keys]' HMAC key.
Uint8List vieraMac(VieraKeys keys, List<int> data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(keys.hmacKey));
  return mac.process(Uint8List.fromList(data));
}

/// A payload the TV sent, decrypted by [vieraOpen].
typedef VieraPlaintext = ({String text, bool macOk});

/// Decrypts a base64 blob the TV sent (`X_AuthResult`, `X_EncResult`).
///
/// The whole buffer is decrypted, so the result is the same with or
/// without a trailing HMAC. The payload starts after the 16-byte header and
/// ends at the first zero byte: the TV zero-pads its answers, and the
/// length field in them is known to be wrong, so it is ignored. `macOk`
/// says whether the last 32 bytes are a valid HMAC of the rest; real TVs
/// are believed to always send one, but that is unconfirmed, so callers
/// keep the payload either way.
///
/// Throws [FormatException] when [text] is not base64 of whole AES blocks,
/// holds no terminated payload, or the payload is not UTF-8 (wrong keys).
VieraPlaintext vieraOpen(VieraKeys keys, String text) {
  final Uint8List raw;
  try {
    raw = base64.decode(text.trim());
  } on FormatException {
    throw const FormatException('The encrypted payload is not base64');
  }
  if (raw.length < 32 || raw.length % 16 != 0) {
    throw FormatException(
      'The encrypted payload is ${raw.length} bytes, not whole AES blocks '
      'with a header',
    );
  }
  final plain = _cbc(keys, raw, encrypt: false);
  final end = plain.indexOf(0, 16);
  if (end < 0) {
    throw const FormatException('The decrypted payload has no terminator');
  }
  final String payload;
  try {
    payload = utf8.decode(plain.sublist(16, end));
  } on FormatException {
    throw const FormatException('The decrypted payload is not UTF-8');
  }
  var macOk = false;
  if (raw.length >= 48) {
    final body = raw.sublist(0, raw.length - _macLength);
    final tag = raw.sublist(raw.length - _macLength);
    macOk = _constantTimeEquals(vieraMac(keys, body), tag);
  }
  return (text: payload, macOk: macOk);
}

/// AES-128-CBC decryption of whole blocks [data] under [keys], with no
/// unframing (for tests and diagnostics).
Uint8List vieraDecryptBlocks(VieraKeys keys, List<int> data) {
  if (data.length % 16 != 0) {
    throw const FormatException('Not whole AES blocks');
  }
  return _cbc(keys, Uint8List.fromList(data), encrypt: false);
}

Uint8List _cbc(VieraKeys keys, Uint8List data, {required bool encrypt}) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(encrypt, ParametersWithIV(KeyParameter(keys.aesKey), keys.iv));
  final out = Uint8List(data.length);
  for (var offset = 0; offset < data.length; offset += 16) {
    cipher.processBlock(data, offset, out, offset);
  }
  return out;
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
