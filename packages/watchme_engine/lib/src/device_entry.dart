part of 'engine.dart';

/// Source id for the engine's own reachability evidence.
const String _reachabilitySource = 'watchme.reachability';

/// One device in the registry.
final class _DeviceEntry {
  _DeviceEntry(this.record, this.identity);

  DeviceRecord record;
  DeviceIdentity identity;

  /// Merged state from every session (without connections; the view adds
  /// those from the slots).
  DeviceState state = DeviceState.empty;

  /// When each driver last failed to reach the device, until that driver
  /// gets an answer again.
  final Map<String, DateTime> unreachable = {};

  /// When a command that may have changed the volume failed without saying
  /// how far it got (a partial delivery, a timeout). A volume observation
  /// made at or before then describes the device before that command, so
  /// it is not believed; a newer one ends the uncertainty.
  DateTime? volumeUncertainSince;

  /// The same for mute.
  DateTime? mutedUncertainSince;

  /// `off`, inferred, while some driver gets no answer (e.g. the Samsung
  /// WebSocket is down while REST still answers). All such failures share
  /// one cause, so together they count as a single power source.
  Observed<PowerMode>? get reachability {
    if (unreachable.isEmpty) return null;
    final latest = unreachable.values.reduce((a, b) => a.isAfter(b) ? a : b);
    return Observed.inferred(PowerMode.off, _reachabilitySource, latest);
  }

  /// Attached drivers, in engine registration order.
  final List<_DriverSlot> slots = [];

  final StreamController<DeviceEvent> events = StreamController.broadcast();
  bool forgotten = false;

  String get id => record.id;

  _DriverSlot? slot(String driverId) {
    for (final s in slots) {
      if (s.driverId == driverId) return s;
    }
    return null;
  }

  Endpoint endpointFor(_DriverSlot slot) =>
      Endpoint(record.host, ports: record.ports, attributes: slot.attributes);

  void emit(DeviceEvent event) {
    if (!events.isClosed) events.add(event);
  }
}

/// One driver attached to one device: what its probe said and its session.
final class _DriverSlot {
  _DriverSlot(this.driver)
    : capabilities = List.of(driver.descriptor.ceiling),
      requiresPairing = driver.descriptor.requiresPairing;

  final Driver driver;

  DriverDescriptor get descriptor => driver.descriptor;
  String get driverId => descriptor.id;

  /// Probe capabilities, replaced by the session's while one is open.
  /// Before any probe this is the descriptor's ceiling.
  List<CapabilitySupport> capabilities;
  bool requiresPairing;
  List<String> notes = const [];
  Map<String, String> attributes = const {};

  bool hasCredential = false;

  /// Set when the device revoked the credential; cleared by a new pairing.
  bool reauthInvalid = false;

  ConnectionState connection = ConnectionState.disconnected;
  WatchmeError? lastError;

  DriverSession? session;
  StreamSubscription<DeviceEvent>? subscription;
  Future<DriverSession>? connecting;

  /// Whether [connecting] may wake the device.
  bool connectingMayWake = false;

  /// Bumped whenever the session is reset, so a connect that was in flight
  /// knows its result is unwanted.
  int generation = 0;

  Timer? reconnectTimer;
  int reconnectAttempts = 0;
  int consecutiveFailures = 0;
  Duration? latency;

  bool get paired => hasCredential && !reauthInvalid;
  bool get needsPairing => (requiresPairing && !hasCredential) || reauthInvalid;

  CapabilitySupport supportFor(Capability capability) =>
      capabilities.supportFor(capability);

  RouteHealth get health => RouteHealth(
    connection: connection,
    ready: !needsPairing,
    consecutiveFailures: consecutiveFailures,
    latency: latency,
  );

  void cancelReconnect() {
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }
}

/// One device as seen by one discovery pass or manual add, before identity
/// resolution.
final class _Sighting {
  _Sighting({
    required this.host,
    required this.probes,
    this.hits = const [],
    this.ports = const {},
    this.attachFailedProbes = false,
  });

  final String host;
  final List<_Probe> probes;
  final List<DiscoveryHit> hits;
  final Map<String, int> ports;

  /// Attach drivers whose probe failed with a transport error (discovery:
  /// the matcher already recognised the device). Manual adds attach only
  /// drivers that matched.
  final bool attachFailedProbes;

  Iterable<DeviceInfo> get _infos => [
    for (final p in probes)
      if (p.result.matched && p.result.info != null) p.result.info!,
  ];

  String? _attr(String key) {
    for (final h in hits) {
      final v = h.attributes[key];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  DeviceIdentity get identity => DeviceIdentity(
    host: host,
    macs: [for (final i in _infos) ...i.allMacs, for (final h in hits) ?h.mac],
    stableIds: [for (final h in hits) ?h.stableId],
    probeStableIds: [for (final i in _infos) ?i.stableId],
  );

  String? get infoName => _infos.map((i) => i.name).nonNulls.firstOrNull;

  String? get manufacturer =>
      _infos.map((i) => i.manufacturer).nonNulls.firstOrNull ??
      _attr(DiscoveryAttr.manufacturer);

  String? get model =>
      _infos.map((i) => i.model).nonNulls.firstOrNull ??
      _attr(DiscoveryAttr.modelName);

  String get displayName {
    final named =
        infoName ??
        hits.map((h) => h.name).nonNulls.firstOrNull ??
        _attr(DiscoveryAttr.friendlyName);
    if (named != null) return named;
    final label = [?manufacturer, ?model].join(' ');
    return label.isEmpty ? host : label;
  }

  String? get primaryMac {
    for (final m in [
      for (final i in _infos) ?i.mac,
      for (final h in hits) ?h.mac,
    ]) {
      if (identity.macs.contains(tryNormalizeMac(m))) return tryNormalizeMac(m);
    }
    return null;
  }

  String? get primaryStableId =>
      _infos.map((i) => i.stableId).nonNulls.firstOrNull ??
      hits.map((h) => h.stableId).nonNulls.firstOrNull;
}

/// One driver's probe of one endpoint.
typedef _Probe = ({Driver driver, Endpoint endpoint, ProbeResult result});
