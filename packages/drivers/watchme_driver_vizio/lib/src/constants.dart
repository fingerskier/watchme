import 'package:watchme_core/watchme_core.dart';

/// The VIZIO driver id ([DriverDescriptor.id], [DeviceEvent.driverId]).
const String vizioDriverId = 'vizio.smartcast';

/// [Endpoint] port names used by the VIZIO driver, with their defaults.
///
/// A TV with firmware 4.0 or newer answers on 7345, an older one on 9000
/// (the firmware decides, not the model year; a sound bar in setup was seen
/// on 9000 too). The probe, pairing and connect try [smartcast] first,
/// then [smartcastLegacy], and keep the one that answered: the probe
/// reports it as the [smartcast] port of its refined endpoint, and pairing
/// stores it in the credential.
///
/// The names are VIZIO's own. A device record keeps one flat port map, so
/// a name another driver reads too (Fire TV's `api`) would point that
/// driver's probe at the SmartCast API whenever a caller names the ports.
abstract final class VizioPorts {
  /// The HTTPS SmartCast API.
  static const String smartcast = 'smartcast';

  /// Default SmartCast API port (firmware 4.0 and newer).
  static const int smartcastDefault = 7345;

  /// The SmartCast API port of firmware older than 4.0, tried after
  /// [smartcast].
  static const String smartcastLegacy = 'smartcastLegacy';

  /// Default legacy API port.
  static const int smartcastLegacyDefault = 9000;
}

/// Keys of [TokenCredential.attributes] the VIZIO driver writes. None is a
/// secret: the `AUTH` token is the only bearer value.
abstract final class VizioCredentialKeys {
  /// The controller `DEVICE_ID` sent at pairing. The token is bound to it.
  static const String controllerId = 'controllerId';

  /// The `DEVICE_NAME` shown on the TV at pairing.
  static const String friendlyName = 'friendlyName';

  /// The API port that answered at pairing, tried first by `connect`.
  static const String port = 'port';
}
