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
  Future<String> refusalOf(String host) async {
    try {
      await client.addManual(host);
      return 'none';
    } on WatchmeError catch (e) {
      return e.code.name;
    }
  }

  // A LAN address passes the destination check and then finds no driver
  // that can run without transports; a public one is refused before that.
  // Nothing is contacted either way: there is no network stack.
  final refusal = await refusalOf('10.0.2.1');
  final publicRefusal = await refusalOf('8.8.8.8');
  final command = Command.fromJson(const PressKey(RemoteKey.home).toJson());
  // The LAN-only classifier is pure Dart; prove it compiles and runs in JS.
  final classes = [
    for (final a in ['192.168.1.7', '::ffff:127.0.0.1', '100.64.0.1'])
      classifyHostAddress(a).name,
  ];
  final power = Command.fromJson(
    const SetPower(true, userConfirmed: true).toJson(),
  );
  print(
    'drivers ${[rokuDescriptor.id, fireTvDescriptor.id]}, '
    'enabled ${engine.drivers.length}, manual add refused: $refusal, '
    'public host refused: $publicRefusal, '
    '$command, $power, classes $classes, '
    'LAN-only allows 192.168.1.7: '
    '${DestinationPolicy.lanOnly.allows('192.168.1.7')}',
  );
  await client.close();
}
