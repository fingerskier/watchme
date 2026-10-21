// Proves the pure-Dart half of watchme is web-safe: `dart compile js` fails
// if watchme_core, watchme_engine or either driver reaches dart:io or
// another VM-only library. CI compiles this and runs the output with Node.
//
//   dart compile js -o <scratch>/web_safety_check.js tool/web_safety_check.dart
//   node <scratch>/web_safety_check.js

import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_engine/watchme_engine.dart';

/// A browser-like bundle with no transports at all: the engine must still
/// build, list its drivers and refuse work cleanly.
final class _NoTransports implements Transports {
  @override
  Set<TransportFeature> get features => const {};
  @override
  NetworkStack? get network => null;
  @override
  SerialPortProvider? get serial => null;
  @override
  BleCentral? get ble => null;
  @override
  HidPeripheral? get hid => null;
  @override
  IrEmitter? get ir => null;
  @override
  ProcessRunner? get process => null;
}

Future<void> main() async {
  final engine = Engine(
    drivers: [const RokuDriver(), FireTvDriver()],
    transports: _NoTransports(),
  );
  await engine.start();
  final client = InProcessClient(engine, ownsEngine: true);
  String refusal;
  try {
    await client.addManual('192.0.2.1');
    refusal = 'none';
  } on WatchmeError catch (e) {
    refusal = e.code.name;
  }
  final command = Command.fromJson(const PressKey(RemoteKey.home).toJson());
  print(
    'drivers ${[rokuDescriptor.id, fireTvDescriptor.id]}, '
    'enabled ${engine.drivers.length}, manual add refused: $refusal, '
    '$command',
  );
  await client.close();
}
