/// Test support for watchme: a scripted fake network stack and transports
/// bundle, a fake clock, a fake discovery provider, fingerprint helpers and
/// matchers.
///
/// Pure Dart (no `dart:io`). Protocol simulators live in their own
/// libraries (e.g. `package:watchme_testkit/roku_simulator.dart`) and are
/// not exported here.
library;

export 'src/fake_clock.dart';
export 'src/fake_discovery.dart';
export 'src/fake_network.dart';
export 'src/fake_transports.dart';
export 'src/fingerprints.dart';
export 'src/matchers.dart';
