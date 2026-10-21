import 'package:meta/meta.dart';

import 'capabilities.dart';
import 'commands.dart';
import 'credentials.dart';
import 'discovery.dart';
import 'endpoint.dart';
import 'errors.dart';
import 'events.dart';
import 'pairing.dart';
import 'results.dart';
import 'state.dart';
import 'transports/transports.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// How trustworthy a protocol's definition is.
enum Stability {
  /// Vendor-documented (Roku ECP, Sony REST).
  documented,

  /// Undocumented but widely implemented and stable (DIAL quirks, Samsung
  /// WebSocket).
  communityStandard,

  /// Reverse-engineered; may break on a firmware update (Fire TV remote API).
  reverseEngineered,

  /// Depends on a vendor secret watchme does not ship.
  privateVendorSecret,
}

/// Where a driver backend can run.
enum DriverTarget {
  /// Compiles to JS and runs in a browser with `BrowserTransports`.
  webSafe,

  /// Native Dart (desktop, mobile, hub).
  native,

  /// Only on the hub (cec-ctl, BlueZ).
  hubOnly,

  /// Only on Android (in-process HID, IR emitter).
  androidOnly,

  /// Only on iOS (HomeKit).
  iosOnly,
}

/// One way a driver can reach devices, gated by transport features.
@immutable
final class DriverBackend {
  /// Creates a backend description.
  const DriverBackend({
    required this.id,
    required this.requires,
    required this.targets,
  });

  /// Decodes the form written by [toJson].
  factory DriverBackend.fromJson(JsonMap json) => DriverBackend(
    id: req<String>(json, 'id'),
    requires: enumSet(json, 'requires', TransportFeature.values),
    targets: enumSet(json, 'targets', DriverTarget.values),
  );

  /// Backend id, e.g. `roku.ecp.http`, `cec.serial`.
  final String id;

  /// Transport features it needs; the engine enables it only where all are
  /// present.
  final Set<TransportFeature> requires;

  /// Where it can run.
  final Set<DriverTarget> targets;

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'requires': enumNames(requires),
    'targets': enumNames(targets),
  };

  @override
  bool operator ==(Object other) =>
      other is DriverBackend &&
      other.id == id &&
      setEquals(other.requires, requires) &&
      setEquals(other.targets, targets);

  @override
  int get hashCode => Object.hash(id, setHash(requires), setHash(targets));

  @override
  String toString() => 'DriverBackend($id)';
}

/// A setting the user must change on the TV before a driver works.
@immutable
final class SetupStep {
  /// Creates a setup step.
  const SetupStep({
    required this.id,
    required this.title,
    this.detail,
    this.helpUrl,
  });

  /// Decodes the form written by [toJson].
  factory SetupStep.fromJson(JsonMap json) => SetupStep(
    id: req<String>(json, 'id'),
    title: req<String>(json, 'title'),
    detail: opt<String>(json, 'detail'),
    helpUrl: optUri(json, 'helpUrl'),
  );

  /// Stable id, e.g. `roku.controlByMobileApps`.
  final String id;

  /// Short text, e.g. "Control by mobile apps = Enabled".
  final String title;

  /// Where the setting is and why it matters.
  final String? detail;

  /// Vendor help page.
  final Uri? helpUrl;

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'title': title,
    if (detail != null) 'detail': detail,
    if (helpUrl != null) 'helpUrl': helpUrl.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is SetupStep &&
      other.id == id &&
      other.title == title &&
      other.detail == detail &&
      other.helpUrl == helpUrl;

  @override
  int get hashCode => Object.hash(id, title, detail, helpUrl);

  @override
  String toString() => 'SetupStep($id)';
}

/// Static facts about a driver. These generate the capability matrix in the
/// docs, so they must stay truthful.
@immutable
final class DriverDescriptor {
  /// Creates a descriptor.
  const DriverDescriptor({
    required this.id,
    required this.vendor,
    required this.protocol,
    required this.ceiling,
    required this.backends,
    required this.stability,
    required this.provenance,
    this.matchers = const [],
    this.userSetup = const [],
    this.ports = const {},
    this.requiresPairing = false,
  });

  /// Decodes the form written by [toJson].
  factory DriverDescriptor.fromJson(JsonMap json) => DriverDescriptor(
    id: req<String>(json, 'id'),
    vendor: req<String>(json, 'vendor'),
    protocol: req<String>(json, 'protocol'),
    ceiling: objList(json, 'ceiling', CapabilitySupport.fromJson),
    backends: objList(json, 'backends', DriverBackend.fromJson),
    stability: reqEnum(json, 'stability', Stability.values),
    provenance: req<String>(json, 'provenance'),
    matchers: objList(json, 'matchers', DiscoveryMatcher.fromJson),
    userSetup: objList(json, 'userSetup', SetupStep.fromJson),
    ports: intMap(json, 'ports'),
    requiresPairing: opt<bool>(json, 'requiresPairing') ?? false,
  );

  /// Driver id, e.g. `roku.ecp`, `firetv.lightning`. Also the
  /// [Observed.source] and [DeviceEvent.driverId] of its sessions.
  final String id;

  /// Vendor or family, e.g. `Roku`, `Amazon`.
  final String vendor;

  /// Human protocol name, e.g. `Roku ECP`.
  final String protocol;

  /// The most the protocol can ever do. [Driver.probe] narrows it per
  /// device.
  final List<CapabilitySupport> ceiling;

  /// Ways to reach devices.
  final List<DriverBackend> backends;

  /// Discovery hits this driver recognises.
  final List<DiscoveryMatcher> matchers;

  /// How trustworthy the protocol definition is.
  final Stability stability;

  /// Settings the user must change on the TV.
  final List<SetupStep> userSetup;

  /// Where the implementation came from, e.g. "clean-room from Roku ECP
  /// docs" or "ported from aiowebostv (Apache-2.0)".
  final String provenance;

  /// Default port per port name (see [Endpoint.port]), e.g.
  /// `{'ecp': 8060}` or `{'dial': 8009, 'api': 8080}`.
  final Map<String, int> ports;

  /// Whether the protocol normally needs pairing before [Driver.connect].
  final bool requiresPairing;

  /// The ceiling entry for [capability] ([Support.unknown] when absent).
  CapabilitySupport ceilingFor(Capability capability) =>
      ceiling.supportFor(capability);

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'vendor': vendor,
    'protocol': protocol,
    'ceiling': [for (final c in ceiling) c.toJson()],
    'backends': [for (final b in backends) b.toJson()],
    'stability': stability.name,
    'provenance': provenance,
    if (matchers.isNotEmpty) 'matchers': [for (final m in matchers) m.toJson()],
    if (userSetup.isNotEmpty)
      'userSetup': [for (final s in userSetup) s.toJson()],
    if (ports.isNotEmpty) 'ports': ports,
    if (requiresPairing) 'requiresPairing': true,
  };

  @override
  bool operator ==(Object other) =>
      other is DriverDescriptor &&
      other.id == id &&
      other.vendor == vendor &&
      other.protocol == protocol &&
      listEquals(other.ceiling, ceiling) &&
      listEquals(other.backends, backends) &&
      listEquals(other.matchers, matchers) &&
      other.stability == stability &&
      listEquals(other.userSetup, userSetup) &&
      other.provenance == provenance &&
      mapEquals(other.ports, ports) &&
      other.requiresPairing == requiresPairing;

  @override
  int get hashCode => Object.hash(
    id,
    vendor,
    protocol,
    listHash(ceiling),
    listHash(backends),
    listHash(matchers),
    stability,
    listHash(userSetup),
    provenance,
    mapHash(ports),
    requiresPairing,
  );

  @override
  String toString() => 'DriverDescriptor($id)';
}

/// Identity facts a probe learned about a device.
@immutable
final class DeviceInfo {
  /// Creates device info. All fields are optional.
  const DeviceInfo({
    this.name,
    this.manufacturer,
    this.model,
    this.mac,
    this.otherMacs = const {},
    this.stableId,
    this.osVersion,
    this.extra = const {},
  });

  /// Decodes the form written by [toJson].
  factory DeviceInfo.fromJson(JsonMap json) => DeviceInfo(
    name: opt<String>(json, 'name'),
    manufacturer: opt<String>(json, 'manufacturer'),
    model: opt<String>(json, 'model'),
    mac: opt<String>(json, 'mac'),
    otherMacs: strList(json, 'otherMacs').toSet(),
    stableId: opt<String>(json, 'stableId'),
    osVersion: opt<String>(json, 'osVersion'),
    extra: strMap(json, 'extra'),
  );

  /// User-visible name (e.g. Roku `user-device-name`).
  final String? name;

  /// Manufacturer (e.g. `TCL`, `Amazon`).
  final String? manufacturer;

  /// Model name or number.
  final String? model;

  /// MAC of the interface in use, normalised with `normalizeMac`. Used for
  /// Wake-on-LAN and identity merge.
  final String? mac;

  /// Other MACs of the same device (e.g. Roku reports wifi and ethernet),
  /// normalised.
  final Set<String> otherMacs;

  /// A stable id unique to this physical device, prefixed by its namespace
  /// (e.g. `roku:serial:X00400ABCDEF`, `uuid:...`).
  final String? stableId;

  /// OS or firmware version.
  final String? osVersion;

  /// Other protocol facts worth keeping (non-secret).
  final Map<String, String> extra;

  /// [mac] and [otherMacs] together.
  Set<String> get allMacs => {?mac, ...otherMacs};

  /// JSON form.
  JsonMap toJson() => {
    if (name != null) 'name': name,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (mac != null) 'mac': mac,
    if (otherMacs.isNotEmpty) 'otherMacs': otherMacs.toList()..sort(),
    if (stableId != null) 'stableId': stableId,
    if (osVersion != null) 'osVersion': osVersion,
    if (extra.isNotEmpty) 'extra': extra,
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceInfo &&
      other.name == name &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      other.mac == mac &&
      setEquals(other.otherMacs, otherMacs) &&
      other.stableId == stableId &&
      other.osVersion == osVersion &&
      mapEquals(other.extra, extra);

  @override
  int get hashCode => Object.hash(
    name,
    manufacturer,
    model,
    mac,
    setHash(otherMacs),
    stableId,
    osVersion,
    mapHash(extra),
  );

  @override
  String toString() => 'DeviceInfo($manufacturer $model "$name" $stableId)';
}

/// What [Driver.probe] learned about one endpoint.
@immutable
final class ProbeResult {
  /// Creates a probe result.
  const ProbeResult({
    required this.matched,
    this.info,
    this.capabilities = const [],
    this.requiresPairing = false,
    this.endpoint,
    this.notes = const [],
    this.power,
    this.error,
  });

  /// A positive result.
  const ProbeResult.matched({
    required DeviceInfo this.info,
    required this.capabilities,
    this.requiresPairing = false,
    this.endpoint,
    this.notes = const [],
    this.power,
  }) : matched = true,
       error = null;

  /// A negative result; [error] says why when it was a failure rather than
  /// "not this protocol".
  const ProbeResult.notMatched({this.error, this.notes = const []})
    : matched = false,
      info = null,
      capabilities = const [],
      requiresPairing = false,
      endpoint = null,
      power = null;

  /// Whether the endpoint speaks this driver's protocol.
  final bool matched;

  /// Identity facts, when matched.
  final DeviceInfo? info;

  /// The ceiling narrowed for this device (e.g. Roku in Limited mode loses
  /// keys; a Roku player without a tuner loses `channel`).
  final List<CapabilitySupport> capabilities;

  /// Whether [Driver.startPairing] must succeed before [Driver.connect].
  final bool requiresPairing;

  /// The endpoint refined by the probe (e.g. ports learned from a DIAL
  /// description); `null` keeps the probed one.
  final Endpoint? endpoint;

  /// Human-readable observations, e.g. "Control by mobile apps is Limited".
  final List<String> notes;

  /// The power state the probe observed without changing it, if the
  /// protocol shows one passively: Roku's device-info `power-mode`
  /// ([Confidence.reported]), or a Fire TV whose remote API is closed while
  /// its DIAL server answers ([Confidence.inferred] standby). `null` when
  /// the probe cannot tell.
  ///
  /// The engine uses it as power evidence, e.g. to confirm a Wake-on-LAN or
  /// to skip waking a device only to turn it off.
  final Observed<PowerMode>? power;

  /// Why it did not match, when that was a failure (unreachable, timeout).
  final WatchmeError? error;

  @override
  bool operator ==(Object other) =>
      other is ProbeResult &&
      other.matched == matched &&
      other.info == info &&
      listEquals(other.capabilities, capabilities) &&
      other.requiresPairing == requiresPairing &&
      other.endpoint == endpoint &&
      listEquals(other.notes, notes) &&
      other.power == power &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    matched,
    info,
    listHash(capabilities),
    requiresPairing,
    endpoint,
    listHash(notes),
    power,
    error,
  );

  @override
  String toString() => matched
      ? 'ProbeResult(matched $info)'
      : 'ProbeResult(not matched${error == null ? '' : ': $error'})';
}

/// A protocol implementation. Stateless apart from configuration: per-device
/// state lives in [DriverSession]s.
///
/// Contract rules every driver follows:
///
/// * Drivers talk to the world only through [Transports]; they never import
///   `dart:io`, `package:web` or Flutter.
/// * Every port comes from [Endpoint.port] with the protocol default, so
///   simulators on random ports work.
/// * [probe] is passive: no wake, no app launch, no pairing prompt, no state
///   change on the TV. It may read device-info style endpoints and use
///   discovery attributes. (Fire TV's DIAL `POST /apps/FireTVRemote` is a
///   launch, so it is not allowed in [probe].)
/// * Waking (Fire TV DIAL wake, Wake-on-LAN) happens only in [connect] with
///   `allowWake: true`, during pairing, or in a session executing a command
///   the user sent (a Fire TV that fell asleep under its session is woken
///   and the command resent once). [DriverSession.refresh] never wakes.
/// * A key or command the driver cannot map returns [Unsupported]; it never
///   silently succeeds.
/// * The device's own error text is preserved in
///   [WatchmeError.rawDeviceMessage].
abstract interface class Driver {
  /// Static facts.
  DriverDescriptor get descriptor;

  /// Checks whether [endpoint] speaks this protocol and narrows the ceiling
  /// for it. Passive (see the class rules).
  ///
  /// Returns [ProbeResult.notMatched] rather than throwing when the device
  /// does not answer or is not this kind of device; put the cause in
  /// [ProbeResult.error].
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports);

  /// Starts pairing, or returns `null` when the protocol needs none.
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  );

  /// Opens a session.
  ///
  /// With [allowWake] (the default) the driver may wake the device first
  /// when the protocol needs it, e.g. Fire TV's DIAL launch. Callers allow
  /// it only for a command the user just sent (or right after pairing).
  ///
  /// With `allowWake: false` the driver must not do anything that can wake
  /// the device or change what it shows: no DIAL launch, no Wake-on-LAN, no
  /// CEC power-on or Image View On, no app launch, no power key. If the
  /// device cannot be reached without waking it (Fire TV's API port is
  /// closed while it sleeps), [connect] fails fast with
  /// [WatchmeErrorCode.unreachable]. The engine passes `false` for every
  /// connection the user did not ask for: background and engine-initiated
  /// reconnects, refreshes and polling.
  ///
  /// Throws [WatchmeError]: [WatchmeErrorCode.unauthorized] when pairing is
  /// required and [credential] is `null`; [WatchmeErrorCode.reauthRequired]
  /// when the device rejects [credential]; transport codes otherwise.
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  });
}

/// A live connection from one driver to one device.
abstract interface class DriverSession {
  /// The driver id ([DriverDescriptor.id]).
  String get driverId;

  /// Runtime capabilities for this device and firmware. Updated in place
  /// when the session emits [CapabilitiesChanged].
  List<CapabilitySupport> get capabilities;

  /// The latest state this session knows.
  DeviceState get state;

  /// State, connection, capability and re-auth events. Broadcast; closes on
  /// [close].
  ///
  /// A [ConnectionChanged] to [ConnectionState.disconnected] or
  /// [ConnectionState.failed] that the session emits on its own (not from
  /// [close]) means the device stopped answering. The engine then closes
  /// the session, marks every observation it made stale, and recovers only
  /// passively (a probe, or [Driver.connect] with `allowWake: false`).
  Stream<DeviceEvent> get events;

  /// Executes [command]. Never throws: failures are [Failed], unmappable
  /// commands are [Unsupported]. A session that detects a revoked
  /// credential returns [Failed] with [WatchmeErrorCode.reauthRequired] and
  /// emits [ReauthRequired].
  ///
  /// A command the session carries out as several requests (volume steps,
  /// key presses, characters) fails with [WatchmeErrorCode.unreachable]
  /// only when none of them was delivered; after the first one it fails
  /// with [WatchmeErrorCode.partiallyDelivered], whatever stopped it,
  /// including [close].
  Future<CommandResult> execute(Command command);

  /// Re-reads device state (polling protocols) and returns it, emitting
  /// [StateChanged] for any change. Push-based sessions may return [state].
  /// Throws [WatchmeError] when the device cannot be read.
  ///
  /// Passive: it never wakes the device. When nothing answers at all (every
  /// way of reading the device is [WatchmeErrorCode.unreachable]), the
  /// session marks its [state] stale ([DeviceState.markStale]), emits
  /// [ConnectionChanged] with [ConnectionState.disconnected] and the error,
  /// and throws that error.
  Future<DeviceState> refresh();

  /// Closes the session. Later [execute] calls return [Failed], and a
  /// command in progress sends nothing more: it stops before its next
  /// request.
  Future<void> close();
}
