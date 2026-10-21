/// The watchme engine: device registry and identity merge, discovery and
/// pairing orchestration, the capability router and the power orchestrator,
/// plus the in-process `WatchmeClient`.
///
/// Pure Dart: depends only on watchme_core interfaces, so it also compiles
/// for the web.
///
/// ```dart
/// final engine = Engine(
///   drivers: [RokuDriver(), FireTvDriver()],
///   transports: IoTransports(),
///   discoveryProviders: [SsdpDiscovery(...)],
///   credentials: fileCredentialStore,
///   repository: fileDeviceRepository,
/// );
/// await engine.start();
/// final client = InProcessClient(engine, ownsEngine: true);
/// ```
library;

export 'src/backoff.dart';
export 'src/capability_router.dart';
export 'src/engine.dart';
export 'src/identity.dart';
export 'src/in_process_client.dart';
export 'src/power_orchestrator.dart';
