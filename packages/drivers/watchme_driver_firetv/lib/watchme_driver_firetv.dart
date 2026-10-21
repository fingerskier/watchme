/// Amazon Fire TV driver for watchme: DIAL wake, PIN pairing and the HTTPS
/// remote API with trust-on-first-use TLS.
///
/// Pure Dart: talks only to the watchme_core `Transports` interfaces.
///
/// ```dart
/// final driver = FireTvDriver();
/// final flow = driver.startPairing(endpoint, transports,
///     const PairingContext(deviceId: 'living-room'))!;
/// // ... EnterCode step, flow.submit(pin), Paired(credential) ...
/// final session = await driver.connect(endpoint, transports, credential);
/// await session.execute(const PressKey(RemoteKey.home));
/// ```
library;

export 'src/constants.dart';
export 'src/descriptor.dart';
export 'src/driver.dart';
