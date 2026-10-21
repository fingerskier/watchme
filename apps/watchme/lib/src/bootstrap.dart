import 'dart:io' hide Datagram;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_io/watchme_io.dart';

import 'demo/demo_client.dart';

/// Whether the app runs on simulated TVs, set with
/// `--dart-define=WATCHME_DEMO=true`.
const bool demoRequested = bool.fromEnvironment('WATCHME_DEMO');

/// Creates the client the app talks to: the in-process engine, or the demo
/// client when [demoRequested].
Future<WatchmeClient> createClient() async {
  if (demoRequested) return DemoWatchmeClient();
  final directory = await getApplicationSupportDirectory();
  return createEngineClient(stateDirectory: directory.path);
}

/// Builds and starts the real engine and wraps it in an [InProcessClient]
/// that owns it.
///
/// * Transports: [IoTransports] (`dart:io`). Multicast discovery is off
///   where the platform forbids it without an entitlement (iOS); manual add
///   by IP still works there.
/// * Discovery: SSDP (Roku ECP, DIAL) and mDNS (Fire TV and other DNS-SD
///   types).
/// * Drivers: Roku ECP and Fire TV.
/// * Wake-on-LAN: [WakeOnLan], which also sends to each subnet-directed
///   broadcast and on ports 9 and 7, repeated, so a multi-homed host and a
///   lossy Wi-Fi link still reach the TV.
/// * Stores: `credentials.json` and `devices.json` in [stateDirectory],
///   written atomically with mode 0600 in a 0700 directory; a store that
///   cannot be made private refuses to write.
Future<WatchmeClient> createEngineClient({
  required String stateDirectory,
  Iterable<Driver>? drivers,
}) async {
  final network = IoNetworkStack();
  void warn(StoreWarning warning) =>
      debugPrint('watchme store: ${warning.path}: ${warning.message}');
  final engine = Engine(
    drivers: drivers ?? [const RokuDriver(), FireTvDriver()],
    transports: IoTransports(network: network),
    discoveryProviders: [SsdpDiscovery(network), MdnsDiscovery()],
    wakeOnLan: WakeOnLan(network).send,
    credentials: FileCredentialStore(
      _join(stateDirectory, 'credentials.json'),
      onWarning: warn,
    ),
    repository: FileDeviceRepository(
      _join(stateDirectory, 'devices.json'),
      onWarning: warn,
    ),
  );
  try {
    await engine.start();
  } on Object {
    await engine.close();
    rethrow;
  }
  return InProcessClient(engine, ownsEngine: true);
}

String _join(String directory, String name) =>
    directory.endsWith(Platform.pathSeparator)
    ? '$directory$name'
    : '$directory${Platform.pathSeparator}$name';
