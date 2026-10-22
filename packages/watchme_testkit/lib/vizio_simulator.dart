/// A loopback simulator of the VIZIO SmartCast REST API: HTTPS with a
/// self-signed certificate, PIN pairing and the `AUTH` token, key
/// commands, the settings tree with `HASHVAL`s, inputs, apps, power modes
/// (on, Quick Start standby, Eco off) and the 7345 / 9000 port split.
///
/// Uses `dart:io`, so it is not exported from the pure-Dart
/// `package:watchme_testkit/watchme_testkit.dart`. Its certificates are
/// test-only fixtures.
library;

export 'src/simulators/vizio/vizio_sim_models.dart';
export 'src/simulators/vizio/vizio_simulator.dart';
