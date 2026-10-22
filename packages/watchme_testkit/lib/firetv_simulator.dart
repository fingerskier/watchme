/// A loopback simulator of the Amazon Fire TV remote API ("Lightning"): a
/// DIAL server that wakes the device and an HTTPS API with PIN pairing,
/// client tokens, keys, text, apps and media.
///
/// Uses `dart:io`, so it is not exported from the pure-Dart
/// `package:watchme_testkit/watchme_testkit.dart`. Its certificates are
/// test-only fixtures.
library;

export 'src/simulators/firetv/firetv_simulator.dart';
