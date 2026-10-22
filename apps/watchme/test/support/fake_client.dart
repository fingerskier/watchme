import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/app.dart';
import 'package:watchme_core/watchme_core.dart';

/// A scriptable [WatchmeClient] that records every call.
class FakeWatchmeClient implements WatchmeClient {
  /// Creates the fake with an initial device list.
  FakeWatchmeClient({List<DeviceView> devices = const []})
    : _devices = List.of(devices);

  List<DeviceView> _devices;
  final StreamController<List<DeviceView>> _changes =
      StreamController.broadcast();

  /// Number of [scan] calls.
  int scanCalls = 0;

  /// When set, [scan] waits for it.
  Completer<void>? scanGate;

  /// When set, [scan] throws it.
  WatchmeError? scanError;

  /// Hosts passed to [addManual].
  final List<String> addedHosts = [];

  /// Answers [addManual]; the default throws unreachable.
  FutureOr<DeviceView> Function(String host) onAddManual = (host) =>
      throw WatchmeError.unreachable('Nothing answered at $host');

  /// Every (deviceId, command) sent.
  final List<(String, Command)> sent = [];

  /// Answers [send]; the default confirms.
  CommandResult Function(Command command) onSend = (_) => const Confirmed();

  /// When set, [send] waits for it before answering (a slow TV).
  Completer<void>? sendGate;

  /// Every pairing started, newest last.
  final List<FakePairingHandle> pairings = [];

  /// Ids passed to [forget].
  final List<String> forgotten = [];

  /// Ids passed to [refresh].
  final List<String> refreshed = [];

  /// Whether [close] ran.
  bool closed = false;

  /// The commands sent, without device ids.
  List<Command> get commands => [for (final (_, c) in sent) c];

  /// Replaces the device list and notifies watchers.
  void setDevices(List<DeviceView> devices) {
    _devices = List.of(devices);
    _changes.add(List.unmodifiable(_devices));
  }

  @override
  Stream<List<DeviceView>> watchDevices() => Stream.multi((listener) {
    listener.add(List.unmodifiable(_devices));
    final subscription = _changes.stream.listen(listener.add);
    listener.onCancel = subscription.cancel;
  });

  @override
  Future<void> scan({Duration window = const Duration(seconds: 5)}) async {
    scanCalls++;
    final gate = scanGate;
    if (gate != null) await gate.future;
    final error = scanError;
    if (error != null) throw error;
  }

  @override
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  }) async {
    addedHosts.add(host);
    return onAddManual(host);
  }

  @override
  Future<void> forget(String deviceId) async {
    forgotten.add(deviceId);
    setDevices([
      for (final d in _devices)
        if (d.id != deviceId) d,
    ]);
  }

  @override
  Future<PairingHandle> pair(String deviceId, String driverId) async {
    final handle = FakePairingHandle(
      'pairing-${pairings.length + 1}',
      deviceId,
      driverId,
    );
    pairings.add(handle);
    return handle;
  }

  @override
  Future<CommandResult> send(String deviceId, Command command) async {
    sent.add((deviceId, command));
    final gate = sendGate;
    if (gate != null) await gate.future;
    return onSend(command);
  }

  @override
  Future<void> refresh(String deviceId) async => refreshed.add(deviceId);

  @override
  Future<void> close() async {
    closed = true;
    await _changes.close();
  }
}

/// A pairing whose steps the test emits by hand.
class FakePairingHandle implements PairingHandle {
  /// Creates the handle.
  FakePairingHandle(this.id, this.deviceId, this.driverId);

  @override
  final String id;

  @override
  final String deviceId;

  @override
  final String driverId;

  final StreamController<PairingStep> _steps = StreamController();

  /// Values passed to [submit].
  final List<String> submitted = [];

  /// Whether [cancel] ran.
  bool cancelled = false;

  /// Emits [step]; closes the stream after a terminal step.
  void emit(PairingStep step) {
    _steps.add(step);
    if (step.isTerminal) unawaited(_steps.close());
  }

  @override
  Stream<PairingStep> get steps => _steps.stream;

  @override
  Future<void> submit(String value) async => submitted.add(value);

  @override
  Future<void> cancel() async => cancelled = true;
}

/// Every capability at [Support.yes], except those in [overrides].
List<CapabilitySupport> allCapabilities([
  Map<Capability, CapabilitySupport> overrides = const {},
]) => [
  for (final c in Capability.values) overrides[c] ?? CapabilitySupport.yes(c),
];

/// A connected Roku TV that supports everything (unless [capabilities]
/// says otherwise).
DeviceView rokuDevice({
  List<CapabilitySupport>? capabilities,
  DeviceState state = DeviceState.empty,
  ConnectionState connection = ConnectionState.connected,
}) => DeviceView(
  id: 'roku-1',
  name: 'Living Room Roku',
  host: '192.0.2.10',
  manufacturer: 'TCL',
  model: '55S455',
  drivers: [
    DriverView(
      driverId: 'roku.ecp',
      protocol: 'Roku ECP',
      connection: connection,
    ),
  ],
  capabilities: capabilities ?? allCapabilities(),
  state: state,
);

/// A Fire TV that still needs pairing.
DeviceView fireTvDevice({bool paired = false}) => DeviceView(
  id: 'firetv-1',
  name: 'Bedroom Fire TV',
  host: '192.0.2.20',
  manufacturer: 'Amazon',
  model: 'AFTKA',
  drivers: [
    DriverView(
      driverId: 'firetv.lightning',
      protocol: 'Fire TV remote API',
      requiresPairing: true,
      paired: paired,
      connection: paired
          ? ConnectionState.connected
          : ConnectionState.disconnected,
    ),
  ],
  capabilities: allCapabilities({
    Capability.channel: const CapabilitySupport.no(Capability.channel),
  }),
);

/// A Sharp AQUOS without a login: it works unpaired, and its driver offers
/// pairing for the optional login and network power-on.
DeviceView sharpDevice({bool paired = false}) => DeviceView(
  id: 'sharp-1',
  name: 'Den AQUOS',
  host: '192.0.2.30',
  manufacturer: 'Sharp',
  model: 'LC-60LE650U',
  drivers: [
    DriverView(
      driverId: 'sharp.aquos',
      protocol: 'Sharp AQUOS IP control',
      offersPairing: true,
      paired: paired,
      connection: ConnectionState.connected,
    ),
  ],
  capabilities: allCapabilities({}),
);

/// Sets the test window to [size] logical pixels.
void useWindowSize(WidgetTester tester, Size size) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps the app around [client] and lets the first list arrive.
Future<void> pumpApp(
  WidgetTester tester,
  WatchmeClient client, {
  Size size = const Size(1200, 1000),
  bool scanOnStart = false,
}) async {
  useWindowSize(tester, size);
  await tester.pumpWidget(WatchmeApp(client: client, scanOnStart: scanOnStart));
  await tester.pumpAndSettle();
}
