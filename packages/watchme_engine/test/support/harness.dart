import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'fakes.dart';

/// An [Engine] wired to fakes: [FakeTransports], [FakeClock] and in-memory
/// stores.
class Harness {
  Harness({
    List<Driver> drivers = const [],
    List<DiscoveryProvider> providers = const [],
    EngineConfig config = const EngineConfig(),
    CredentialStore? credentials,
    MemoryDeviceRepository? repository,
    FakeTransports? transports,
    WakeOnLanSender? wakeOnLan,
  }) : clock = FakeClock(DateTime.utc(2026, 10, 21, 12)),
       transports = transports ?? FakeTransports(),
       credentials = credentials ?? MemoryCredentialStore(),
       repository = repository ?? MemoryDeviceRepository() {
    engine = Engine(
      drivers: drivers,
      transports: this.transports,
      discoveryProviders: providers,
      credentials: this.credentials,
      repository: this.repository,
      clock: clock,
      config: config,
      wakeOnLan: wakeOnLan,
    );
  }

  final FakeClock clock;
  final FakeTransports transports;
  final CredentialStore credentials;
  final MemoryDeviceRepository repository;
  late final Engine engine;

  DeviceView view(String id) =>
      engine.currentDevices.firstWhere((d) => d.id == id);

  DriverView driverView(String deviceId, String driverId) =>
      view(deviceId).drivers.firstWhere((d) => d.driverId == driverId);

  /// Adds the device at [host] and returns its id.
  Future<String> add(String host, {Map<String, int> ports = const {}}) async =>
      (await engine.addManual(host, ports: ports)).id;

  Observed<T> reported<T>(T value, String source) =>
      Observed.reported(value, source, clock.now());

  Future<void> close() async {
    await engine.close();
    await pump();
  }
}
