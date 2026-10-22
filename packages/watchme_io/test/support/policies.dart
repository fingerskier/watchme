import 'package:watchme_core/watchme_core.dart';

/// The LAN-only policy plus loopback: what tests talking to loopback
/// servers and simulators must opt into explicitly.
const loopbackAllowed = DestinationPolicy(allowLoopback: true);
