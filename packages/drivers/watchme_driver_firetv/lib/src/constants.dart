import 'package:watchme_core/watchme_core.dart';

/// The Fire TV driver id ([DriverDescriptor.id], [DeviceEvent.driverId]).
///
/// Named after the official remote app,
/// `com.amazon.storm.lightning.client.aosp`.
const String fireTvDriverId = 'firetv.lightning';

/// The static `X-Api-Key` value every remote-API request carries.
///
/// It is a public protocol identifier taken from the official app and
/// published in community write-ups, not a user credential.
const String fireTvApiKey = '0987654321';

/// [Endpoint] port names used by the Fire TV driver, with their defaults.
abstract final class FireTvPorts {
  /// The DIAL server that wakes the remote service (plain HTTP).
  static const String dial = 'dial';

  /// Default DIAL port.
  static const int dialDefault = 8009;

  /// The HTTPS remote API.
  static const String api = 'api';

  /// Default remote-API port.
  static const int apiDefault = 8080;
}
