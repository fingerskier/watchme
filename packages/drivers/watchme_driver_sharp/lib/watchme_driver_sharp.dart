/// Sharp AQUOS driver for watchme: the IP-control text protocol on TCP
/// port 10002, with an optional login ID and password.
///
/// Pure Dart: talks only to the watchme_core `Transports` interfaces.
///
/// ```dart
/// final driver = SharpDriver();
/// final flow = driver.startPairing(endpoint, transports,
///     const PairingContext(deviceId: 'living-room'))!;
/// // ... EnterText steps if the TV asks for a login, an optional
/// // ConfirmChange for power-on over the network, Paired(credential) ...
/// final session = await driver.connect(endpoint, transports, credential);
/// await session.execute(const SetVolume(20));
/// ```
library;

export 'src/capabilities.dart' show sharpCapabilities, sharpCeiling;
export 'src/constants.dart';
export 'src/descriptor.dart';
export 'src/driver.dart';
export 'src/keys.dart';
export 'src/link.dart' show isSharpNoLogin;
export 'src/profiles.dart';
export 'src/protocol.dart';
export 'src/redaction.dart';
export 'src/session.dart';
