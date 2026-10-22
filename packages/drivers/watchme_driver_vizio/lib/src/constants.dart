import 'package:watchme_core/watchme_core.dart';

/// The VIZIO driver id ([DriverDescriptor.id], [DeviceEvent.driverId]).
const String vizioDriverId = 'vizio.smartcast';

/// [Endpoint] port names used by the VIZIO driver, with their defaults.
///
/// A TV with firmware 4.0 or newer answers on 7345, an older one on 9000
/// (the firmware decides, not the model year; a sound bar in setup was seen
/// on 9000 too). The probe, pairing and connect try [api] first, then
/// [legacy], and keep the one that answered: the probe reports it as the
/// [api] port of its refined endpoint, and pairing stores it in the
/// credential.
abstract final class VizioPorts {
  /// The HTTPS SmartCast API.
  static const String api = 'api';

  /// Default SmartCast API port (firmware 4.0 and newer).
  static const int apiDefault = 7345;

  /// The SmartCast API port of firmware older than 4.0, tried after [api].
  static const String legacy = 'legacy';

  /// Default legacy API port.
  static const int legacyDefault = 9000;
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
