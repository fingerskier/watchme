// Proves watchme_core is web-safe: `dart compile js` fails if anything it
// exports reaches dart:io or another VM-only library.
//
//   dart compile js -o <scratch>/web_safety_check.js tool/web_safety_check.dart

import 'package:watchme_core/watchme_core.dart';

void main() {
  final packet = magicPacket('01:23:45:67:89:ab');
  final command = Command.fromJson(const PressKey(RemoteKey.home).toJson());
  final lan = classifyHostAddress('fe80::1%25eth0');
  print(
    '${Capability.values.length} capabilities, ${packet.length}-byte '
    'magic packet, $command, fe80::1%25eth0 is ${lan.name}',
  );
}
