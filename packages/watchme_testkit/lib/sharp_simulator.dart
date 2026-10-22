/// A loopback simulator of a Sharp AQUOS TV's IP-control port (TCP 10002):
/// the text protocol with its optional login, model profiles, network
/// standby, firmware quirks and fault injection.
///
/// Uses `dart:io`, so it is not exported from the pure-Dart
/// `package:watchme_testkit/watchme_testkit.dart`. Device identities are
/// made up.
library;

export 'src/simulators/sharp/sharp_sim_models.dart';
export 'src/simulators/sharp/sharp_simulator.dart';
