// Proves the Roku driver is web-safe (its backend is tagged webSafe):
// `dart compile js` fails if anything it uses reaches dart:io.
//
//   dart compile js -o <scratch>/roku_web_safety_check.js tool/web_safety_check.dart

import 'package:watchme_driver_roku/watchme_driver_roku.dart';

void main() {
  final info = RokuDeviceInfo.parse(
    '<device-info><serial-number>X1</serial-number>'
    '<power-mode>PowerOn</power-mode></device-info>',
  );
  print(
    '${rokuDescriptor.id}: ${rokuKeyNames.length} keys, '
    '${rokuLiteralKeys('€')}, ${info.toDeviceInfo().stableId}, '
    '${rokuCapabilities(info, RokuEcpAccess.limited).length} capabilities, '
    '${const RokuDriver().descriptor.ports}',
  );
}
