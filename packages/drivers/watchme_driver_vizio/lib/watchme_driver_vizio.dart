/// VIZIO SmartCast driver for watchme: the HTTPS REST API of SmartCast and
/// VIZIO OS TVs, with PIN pairing, an `AUTH` token and trust-on-first-use
/// TLS.
///
/// Pure Dart: talks only to the watchme_core `Transports` interfaces.
///
/// ```dart
/// final driver = VizioDriver();
/// final flow = driver.startPairing(endpoint, transports,
///     const PairingContext(deviceId: 'living-room'))!;
/// // ... EnterCode step, flow.submit(pin), Paired(credential) ...
/// final session = await driver.connect(endpoint, transports, credential);
/// await session.execute(const SetVolume(20));
/// ```
library;

export 'src/api.dart'
    show VizioDeviceInfo, VizioPaths, vizioPortCandidates, vizioResultWords;
export 'src/constants.dart';
export 'src/descriptor.dart';
export 'src/driver.dart';
export 'src/keys.dart';
export 'src/session.dart';
