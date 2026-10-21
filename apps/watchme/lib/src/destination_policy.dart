import 'package:watchme_core/watchme_core.dart';

/// The unicast destinations the app's in-process engine may contact: the
/// LAN-only default (private, link-local and unique-local addresses), plus
/// loopback.
///
/// Loopback is allowed for two reasons. The protocol simulators (tests,
/// development, `watchme_testkit`) listen on 127.0.0.1. And the engine runs
/// inside the app, in the user's own process: reaching the user's own
/// machine gives a local service nothing the user could not already do, so
/// it crosses no trust boundary.
///
/// The M1 hub must NOT allow loopback. It acts for other devices on the
/// LAN, so a manual add or a spoofed discovery reply naming 127.0.0.1 would
/// let a LAN client reach the hub's own local services through it.
///
/// Discovery stays strictly LAN-only even here: its hits come from the
/// network, so the app never takes a loopback address from them (see
/// `createEngineClient`). Only an address the user types reaches loopback.
const DestinationPolicy appDestinationPolicy = DestinationPolicy(
  allowLoopback: true,
);
