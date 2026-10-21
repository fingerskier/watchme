import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

/// Answers a probe for an endpoint.
typedef ProbeHandler = FutureOr<ProbeResult> Function(Endpoint endpoint);

/// Answers a command on a [FakeSession].
typedef ExecuteHandler = FutureOr<CommandResult> Function(Command command);

/// A scripted [Driver].
///
/// By default it does not recognise anything, connects to a [FakeSession]
/// with [sessionCapabilities] (the ceiling unless set) and needs no pairing.
class FakeDriver implements Driver {
  FakeDriver(
    String id, {
    List<CapabilitySupport> ceiling = const [],
    List<DiscoveryMatcher> matchers = const [],
    List<DriverBackend> backends = const [],
    Stability stability = Stability.documented,
    bool requiresPairing = false,
    this.onProbe,
    this.onConnect,
    this.onPair,
    this.onExecute,
    List<CapabilitySupport>? sessionCapabilities,
    this.sessionState = DeviceState.empty,
  }) : descriptor = DriverDescriptor(
         id: id,
         vendor: 'Test',
         protocol: 'Fake $id',
         ceiling: ceiling,
         backends: backends,
         stability: stability,
         provenance: 'test fake',
         matchers: matchers,
         requiresPairing: requiresPairing,
       ),
       sessionCapabilities = sessionCapabilities ?? ceiling;

  @override
  final DriverDescriptor descriptor;

  ProbeHandler? onProbe;
  FutureOr<DriverSession> Function(Endpoint endpoint, Credential? credential)?
  onConnect;
  PairingFlow? Function(Endpoint endpoint, PairingContext context)? onPair;
  ExecuteHandler? onExecute;
  List<CapabilitySupport> sessionCapabilities;
  DeviceState sessionState;

  /// When set, [connect] throws it (the device is off, or rejects us).
  WatchmeError? connectError;

  final List<Endpoint> probes = [];
  final List<({Endpoint endpoint, Credential? credential})> connects = [];
  final List<PairingContext> pairings = [];
  final List<FakeSession> sessions = [];

  String get id => descriptor.id;

  /// Every command executed on any of this driver's sessions.
  List<Command> get executed => [for (final s in sessions) ...s.executed];

  FakeSession get lastSession => sessions.last;

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    probes.add(endpoint);
    final handler = onProbe;
    if (handler == null) return const ProbeResult.notMatched();
    return handler(endpoint);
  }

  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) {
    pairings.add(context);
    return onPair?.call(endpoint, context);
  }

  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential,
  ) async {
    connects.add((endpoint: endpoint, credential: credential));
    final error = connectError;
    if (error != null) throw error;
    final handler = onConnect;
    if (handler != null) return handler(endpoint, credential);
    final session = FakeSession(
      id,
      capabilities: sessionCapabilities,
      state: sessionState,
      onExecute: onExecute,
    );
    sessions.add(session);
    return session;
  }
}

/// A scripted [DriverSession].
///
/// By default a command is [Confirmed] when its capability is usable in
/// [capabilities] and [Unsupported] otherwise.
class FakeSession implements DriverSession {
  FakeSession(
    this.driverId, {
    List<CapabilitySupport> capabilities = const [],
    this._state = DeviceState.empty,
    this.onExecute,
    this.onRefresh,
  }) : capabilities = List.of(capabilities);

  @override
  final String driverId;

  @override
  List<CapabilitySupport> capabilities;

  DeviceState _state;
  ExecuteHandler? onExecute;
  FutureOr<DeviceState> Function()? onRefresh;
  final List<Command> executed = [];
  final StreamController<DeviceEvent> _events = StreamController.broadcast(
    sync: true,
  );
  bool closed = false;
  int refreshes = 0;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  /// Emits [event] as the device would.
  void emit(DeviceEvent event) => _events.add(event);

  /// Updates the state and emits the change.
  void report(DeviceState diff) {
    _state = _state.merge(diff);
    emit(StateChanged(diff, driverId: driverId));
  }

  @override
  Future<CommandResult> execute(Command command) async {
    if (closed) {
      return const Failed(WatchmeError.unreachable('session closed'));
    }
    executed.add(command);
    final handler = onExecute;
    if (handler != null) return handler(command);
    return capabilities.supportFor(command.capability).usable
        ? const Confirmed()
        : Unsupported('no ${command.capability.name}');
  }

  @override
  Future<DeviceState> refresh() async {
    refreshes++;
    final handler = onRefresh;
    if (handler != null) _state = await handler();
    return _state;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _events.close();
  }
}

/// A matched probe result.
ProbeResult matched({
  String? name,
  String? mac,
  String? stableId,
  String? manufacturer,
  String? model,
  List<CapabilitySupport> capabilities = const [],
  bool requiresPairing = false,
  List<String> notes = const [],
  Observed<PowerMode>? power,
}) => ProbeResult.matched(
  info: DeviceInfo(
    name: name,
    mac: mac,
    stableId: stableId,
    manufacturer: manufacturer,
    model: model,
  ),
  capabilities: capabilities,
  requiresPairing: requiresPairing,
  notes: notes,
  power: power,
);

/// A test token credential.
TokenCredential token(
  String deviceId,
  String driverId, {
  String secret = 'SECRET-TOKEN-1234',
}) => TokenCredential(
  driverId: driverId,
  deviceId: deviceId,
  createdAt: DateTime.utc(2026),
  token: secret,
);

/// Lets queued microtasks and events run.
Future<void> pump() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A [CredentialStore] whose reads wait for [gate] while it is set, so a
/// test can act while a connect is reading its credential.
class GatedCredentialStore implements CredentialStore {
  final MemoryCredentialStore _inner = MemoryCredentialStore();

  /// While non-null and not completed, [read] waits for it.
  Completer<void>? gate;

  /// How many reads started.
  int reads = 0;

  @override
  Future<Credential?> read(String deviceId, String driverId) async {
    reads++;
    await gate?.future;
    return _inner.read(deviceId, driverId);
  }

  @override
  Future<List<Credential>> readAll(String deviceId) => _inner.readAll(deviceId);

  @override
  Future<void> write(Credential credential) => _inner.write(credential);

  @override
  Future<void> delete(String deviceId, {String? driverId}) =>
      _inner.delete(deviceId, driverId: driverId);
}
