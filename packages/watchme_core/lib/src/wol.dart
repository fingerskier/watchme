import 'dart:typed_data';

/// The UDP port Wake-on-LAN magic packets are conventionally sent to.
const int wakeOnLanPort = 9;

final RegExp _separators = RegExp(r'[:\-.\s]');
final RegExp _hex12 = RegExp(r'^[0-9a-f]{12}$');

/// Normalises a MAC address to lower-case `aa:bb:cc:dd:ee:ff`.
///
/// Accepts `:`, `-` or `.` separators (`AA-BB-CC-DD-EE-FF`,
/// `aabb.ccdd.eeff`) or none (`aabbccddeeff`). Throws [FormatException]
/// for anything that is not 6 bytes of hex.
String normalizeMac(String mac) =>
    tryNormalizeMac(mac) ?? (throw FormatException('Not a MAC address', mac));

/// Like [normalizeMac], but returns `null` for invalid input.
String? tryNormalizeMac(String mac) {
  final hex = mac.trim().replaceAll(_separators, '').toLowerCase();
  if (!_hex12.hasMatch(hex)) return null;
  return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
}

/// The six bytes of [mac] (any format [normalizeMac] accepts).
Uint8List macBytes(String mac) {
  final hex = normalizeMac(mac).replaceAll(':', '');
  return Uint8List.fromList([
    for (var i = 0; i < 12; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// Builds a Wake-on-LAN magic packet for [mac]: six `0xFF` bytes followed by
/// the MAC repeated 16 times (102 bytes).
///
/// Throws [FormatException] for an invalid MAC.
Uint8List magicPacket(String mac) {
  final target = macBytes(mac);
  final packet = Uint8List(6 + 16 * 6);
  packet.fillRange(0, 6, 0xff);
  for (var i = 0; i < 16; i++) {
    packet.setRange(6 + i * 6, 12 + i * 6, target);
  }
  return packet;
}
