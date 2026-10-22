import 'package:meta/meta.dart';

import 'capabilities.dart';
import 'commands.dart';
import 'driver.dart';
import 'errors.dart';
import 'events.dart';
import 'pairing.dart';
import 'results.dart';
import 'state.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// The engine: device registry, identity merge, discovery and pairing
/// orchestration, capability routing and power orchestration. Implemented in
/// watchme_engine; embedded in-process by the app and by the hub.
///
/// Unknown device ids: [send] returns [Failed] and [pair] returns a flow that
/// fails at once (neither throws); the other device methods throw
/// [WatchmeError] with [WatchmeErrorCode.internal].
abstract interface class WatchmeEngine {
  /// Loads persisted devices and makes the engine ready. Call once.
  Future<void> start();

  /// The device list: the current list on listen, then every change.
  Stream<List<DeviceView>> get devices;

  /// The current device list.
  List<DeviceView> get currentDevices;

  /// Runs every enabled discovery provider for [window], probes what they
  /// find, and merges results into the registry.
  Future<void> discover(Duration window);

  /// Probes [host] with every enabled driver and adds the device if any
  /// matches. [ports] overrides protocol ports (simulators on loopback).
  /// Throws [WatchmeError] when nothing matches.
  ///
  /// An IP literal outside the engine's `DestinationPolicy` is refused up
  /// front with [WatchmeErrorCode.destinationRefused], before any driver
  /// runs. A host name is checked by the network stack, which resolves it
  /// and refuses it if any address it resolves to is outside the policy.
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  });

  /// Forgets a device: closes its sessions and deletes its record and
  /// credentials.
  Future<void> forget(String deviceId);

  /// Starts pairing [driverId] with [deviceId]. On [Paired] the engine stores
  /// the credential and connects. A driver that needs no pairing yields
  /// [PairingFailed] with [WatchmeErrorCode.unsupported].
  PairingFlow pair(String deviceId, String driverId);

  /// Routes [command] to the best session for the device, falling back down
  /// the ranked list only while nothing has reached the device: never after
  /// a timeout or [WatchmeErrorCode.partiallyDelivered], after which the
  /// affected state is marked stale or refreshed. Never throws.
  ///
  /// [SetPower] and `PressKey(RemoteKey.power)` go to the power
  /// orchestrator instead (see [PressKey] and [SetPower.userConfirmed]).
  Future<CommandResult> send(String deviceId, Command command);

  /// Re-reads the device's state through its sessions.
  Future<void> refresh(String deviceId);

  /// The device's events, merged across its sessions.
  Stream<DeviceEvent> events(String deviceId);

  /// The device's capabilities merged across sessions.
  Map<Capability, CapabilitySupport> capabilitiesOf(String deviceId);

  /// Closes every session and stops background work.
  Future<void> close();
}

/// What the UI talks to; the same interface on every surface.
///
/// `InProcessClient` wraps a [WatchmeEngine] (desktop, mobile); `HubClient`
/// speaks the hub's HTTP/WebSocket API (web, or mobile attached to a hub).
/// Clients never see credentials.
abstract interface class WatchmeClient {
  /// The device list: the current list on listen, then every change.
  Stream<List<DeviceView>> watchDevices();

  /// Runs discovery for [window].
  Future<void> scan({Duration window = const Duration(seconds: 5)});

  /// Adds a device by address (see [WatchmeEngine.addManual]).
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  });

  /// Forgets a device.
  Future<void> forget(String deviceId);

  /// Starts pairing [driverId] with [deviceId].
  Future<PairingHandle> pair(String deviceId, String driverId);

  /// Sends a command. Never throws for device-level failures.
  ///
  /// When a power command returns
  /// `Unsupported(Unsupported.needsConfirmation)`, ask the user whether the
  /// TV is on right now and send `SetPower(!isOn, userConfirmed: true)`.
  Future<CommandResult> send(String deviceId, Command command);

  /// Re-reads the device's state.
  Future<void> refresh(String deviceId);

  /// Releases the client's resources.
  Future<void> close();
}

/// A pairing in progress, as the UI sees it.
abstract interface class PairingHandle {
  /// Pairing id (unique per engine).
  String get id;

  /// The device being paired.
  String get deviceId;

  /// The driver being paired.
  String get driverId;

  /// The conversation. A success arrives as [Paired.redacted]: clients never
  /// receive the credential.
  Stream<PairingStep> get steps;

  /// Answers the current step (see [PairingFlow.submit]).
  Future<void> submit(String value);

  /// Abandons the pairing.
  Future<void> cancel();
}

/// One driver's status on a device, for the UI.
@immutable
final class DriverView {
  /// Creates a driver view.
  const DriverView({
    required this.driverId,
    required this.protocol,
    this.requiresPairing = false,
    this.paired = false,
    this.connection = ConnectionState.disconnected,
    this.lastError,
    this.setup = const [],
    this.notes = const [],
  });

  /// Decodes the form written by [toJson].
  factory DriverView.fromJson(JsonMap json) => DriverView(
    driverId: req<String>(json, 'driverId'),
    protocol: req<String>(json, 'protocol'),
    requiresPairing: opt<bool>(json, 'requiresPairing') ?? false,
    paired: opt<bool>(json, 'paired') ?? false,
    connection:
        optEnum(json, 'connection', ConnectionState.values) ??
        ConnectionState.disconnected,
    lastError: switch (optMap(json, 'lastError')) {
      null => null,
      final e => WatchmeError.fromJson(e),
    },
    setup: objList(json, 'setup', SetupStep.fromJson),
    notes: strList(json, 'notes'),
  );

  /// Driver id.
  final String driverId;

  /// Human protocol name (from the descriptor).
  final String protocol;

  /// Whether the driver needs pairing for this device.
  final bool requiresPairing;

  /// Whether a credential is stored.
  final bool paired;

  /// Session connection state.
  final ConnectionState connection;

  /// The last failure, with the device's raw text.
  final WatchmeError? lastError;

  /// Settings the user may need to change on the TV.
  final List<SetupStep> setup;

  /// Probe notes, e.g. "Control by mobile apps is Limited".
  final List<String> notes;

  /// Whether the user must pair before this driver works.
  bool get needsPairing => requiresPairing && !paired;

  /// Whether the session is connected.
  bool get connected => connection == ConnectionState.connected;

  /// JSON form.
  JsonMap toJson() => {
    'driverId': driverId,
    'protocol': protocol,
    'requiresPairing': requiresPairing,
    'paired': paired,
    'connection': connection.name,
    if (lastError != null) 'lastError': lastError!.toJson(),
    if (setup.isNotEmpty) 'setup': [for (final s in setup) s.toJson()],
    if (notes.isNotEmpty) 'notes': notes,
  };

  @override
  bool operator ==(Object other) =>
      other is DriverView &&
      other.driverId == driverId &&
      other.protocol == protocol &&
      other.requiresPairing == requiresPairing &&
      other.paired == paired &&
      other.connection == connection &&
      other.lastError == lastError &&
      listEquals(other.setup, setup) &&
      listEquals(other.notes, notes);

  @override
  int get hashCode => Object.hash(
    driverId,
    protocol,
    requiresPairing,
    paired,
    connection,
    lastError,
    listHash(setup),
    listHash(notes),
  );

  @override
  String toString() => 'DriverView($driverId, ${connection.name})';
}

/// A device as the UI sees it: no secrets.
@immutable
final class DeviceView {
  /// Creates a device view.
  const DeviceView({
    required this.id,
    required this.name,
    required this.host,
    this.manufacturer,
    this.model,
    this.drivers = const [],
    this.capabilities = const [],
    this.state = DeviceState.empty,
    this.lastSeen,
  });

  /// Decodes the form written by [toJson].
  factory DeviceView.fromJson(JsonMap json) => DeviceView(
    id: req<String>(json, 'id'),
    name: req<String>(json, 'name'),
    host: req<String>(json, 'host'),
    manufacturer: opt<String>(json, 'manufacturer'),
    model: opt<String>(json, 'model'),
    drivers: objList(json, 'drivers', DriverView.fromJson),
    capabilities: objList(json, 'capabilities', CapabilitySupport.fromJson),
    state: switch (optMap(json, 'state')) {
      null => DeviceState.empty,
      final s => DeviceState.fromJson(s),
    },
    lastSeen: optTime(json, 'lastSeen'),
  );

  /// Engine device id.
  final String id;

  /// Display name.
  final String name;

  /// Current host.
  final String host;

  /// Manufacturer.
  final String? manufacturer;

  /// Model.
  final String? model;

  /// Drivers for this device and their status.
  final List<DriverView> drivers;

  /// Capabilities merged across sessions.
  final List<CapabilitySupport> capabilities;

  /// Merged state.
  final DeviceState state;

  /// When the device last answered.
  final DateTime? lastSeen;

  /// The merged support for [capability] ([Support.unknown] when absent).
  CapabilitySupport supportOf(Capability capability) =>
      capabilities.supportFor(capability);

  /// Whether some driver needs pairing before it works.
  bool get needsPairing => drivers.any((d) => d.needsPairing);

  /// Whether at least one session is connected.
  bool get connected => drivers.any((d) => d.connected);

  /// Returns a copy with the given fields replaced.
  DeviceView copyWith({
    String? name,
    String? host,
    String? manufacturer,
    String? model,
    List<DriverView>? drivers,
    List<CapabilitySupport>? capabilities,
    DeviceState? state,
    DateTime? lastSeen,
  }) => DeviceView(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    manufacturer: manufacturer ?? this.manufacturer,
    model: model ?? this.model,
    drivers: drivers ?? this.drivers,
    capabilities: capabilities ?? this.capabilities,
    state: state ?? this.state,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'host': host,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    'drivers': [for (final d in drivers) d.toJson()],
    'capabilities': [for (final c in capabilities) c.toJson()],
    'state': state.toJson(),
    if (lastSeen != null) 'lastSeen': isoTime(lastSeen!),
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceView &&
      other.id == id &&
      other.name == name &&
      other.host == host &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      listEquals(other.drivers, drivers) &&
      listEquals(other.capabilities, capabilities) &&
      other.state == state &&
      (other.lastSeen == null
          ? lastSeen == null
          : lastSeen != null && other.lastSeen!.isAtSameMomentAs(lastSeen!));

  @override
  int get hashCode => Object.hash(
    id,
    name,
    host,
    manufacturer,
    model,
    listHash(drivers),
    listHash(capabilities),
    state,
    lastSeen?.microsecondsSinceEpoch,
  );

  @override
  String toString() => 'DeviceView($id "$name" at $host)';
}
