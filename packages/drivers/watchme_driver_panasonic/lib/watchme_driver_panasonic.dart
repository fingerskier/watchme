/// Panasonic VIERA driver for watchme: the UPnP/SOAP network remote
/// control on port 55000, for plain (pre-2018) sets and encrypted,
/// PIN-paired ones, with volume and mute through UPnP RenderingControl.
///
/// Pure Dart: talks only to the watchme_core `Transports` interfaces.
///
/// ```dart
/// final driver = PanasonicDriver();
/// final probe = await driver.probe(endpoint, transports);
/// final flow = driver.startPairing(
///     probe.endpoint ?? endpoint, transports,
///     const PairingContext(deviceId: 'living-room'));
/// // null for a plain TV; otherwise Instruct, EnterCode, flow.submit(pin),
/// // Paired(credential).
/// final session = await driver.connect(endpoint, transports, credential);
/// await session.execute(const SetVolume(20));
/// ```
library;

export 'src/constants.dart';
export 'src/descriptor.dart';
export 'src/driver.dart';
export 'src/keys.dart'
    show vieraHoldableKeys, vieraKeyEvent, vieraKeyName, vieraKeyNames;
export 'src/session.dart'
    show
        PanasonicSession,
        panasonicDefaultPollInterval,
        panasonicMaxChannelDigits,
        panasonicMaxTextLength,
        panasonicTimeoutsBeforeDisconnect;
