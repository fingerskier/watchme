import 'package:meta/meta.dart';

import 'endpoint.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// A device's persisted identity: what the engine remembers between runs.
///
/// Physical devices are keyed by MAC or stable id, not by IP; [host] and
/// [ports] are only where it was last seen. No secrets live here (those are
/// in a `CredentialStore`).
@immutable
final class DeviceRecord {
  /// Creates a record.
  const DeviceRecord({
    required this.id,
    required this.name,
    required this.host,
    this.manufacturer,
    this.model,
    this.mac,
    this.otherMacs = const {},
    this.stableId,
    this.ports = const {},
    this.driverIds = const [],
    this.lastSeen,
  });

  /// Decodes the form written by [toJson].
  factory DeviceRecord.fromJson(JsonMap json) => DeviceRecord(
    id: req<String>(json, 'id'),
    name: req<String>(json, 'name'),
    host: req<String>(json, 'host'),
    manufacturer: opt<String>(json, 'manufacturer'),
    model: opt<String>(json, 'model'),
    mac: opt<String>(json, 'mac'),
    otherMacs: strList(json, 'otherMacs').toSet(),
    stableId: opt<String>(json, 'stableId'),
    ports: intMap(json, 'ports'),
    driverIds: strList(json, 'driverIds'),
    lastSeen: optTime(json, 'lastSeen'),
  );

  /// The engine's device id (stable across IP changes).
  final String id;

  /// Display name.
  final String name;

  /// Last known host.
  final String host;

  /// Manufacturer.
  final String? manufacturer;

  /// Model.
  final String? model;

  /// Primary MAC, normalised.
  final String? mac;

  /// Other MACs of the device, normalised.
  final Set<String> otherMacs;

  /// Stable id (see `DeviceInfo.stableId`).
  final String? stableId;

  /// Last known port overrides (see [Endpoint.ports]).
  final Map<String, int> ports;

  /// Drivers known to work with this device, in preference order.
  final List<String> driverIds;

  /// When the device last answered.
  final DateTime? lastSeen;

  /// [mac] and [otherMacs] together.
  Set<String> get allMacs => {?mac, ...otherMacs};

  /// Where to reach the device now.
  Endpoint get endpoint => Endpoint(host, ports: ports);

  /// Returns a copy with the given fields replaced (`null` keeps a field).
  DeviceRecord copyWith({
    String? name,
    String? host,
    String? manufacturer,
    String? model,
    String? mac,
    Set<String>? otherMacs,
    String? stableId,
    Map<String, int>? ports,
    List<String>? driverIds,
    DateTime? lastSeen,
  }) => DeviceRecord(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    manufacturer: manufacturer ?? this.manufacturer,
    model: model ?? this.model,
    mac: mac ?? this.mac,
    otherMacs: otherMacs ?? this.otherMacs,
    stableId: stableId ?? this.stableId,
    ports: ports ?? this.ports,
    driverIds: driverIds ?? this.driverIds,
    lastSeen: lastSeen ?? this.lastSeen,
  );

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'host': host,
    if (manufacturer != null) 'manufacturer': manufacturer,
    if (model != null) 'model': model,
    if (mac != null) 'mac': mac,
    if (otherMacs.isNotEmpty) 'otherMacs': otherMacs.toList()..sort(),
    if (stableId != null) 'stableId': stableId,
    if (ports.isNotEmpty) 'ports': ports,
    if (driverIds.isNotEmpty) 'driverIds': driverIds,
    if (lastSeen != null) 'lastSeen': isoTime(lastSeen!),
  };

  @override
  bool operator ==(Object other) =>
      other is DeviceRecord &&
      other.id == id &&
      other.name == name &&
      other.host == host &&
      other.manufacturer == manufacturer &&
      other.model == model &&
      other.mac == mac &&
      setEquals(other.otherMacs, otherMacs) &&
      other.stableId == stableId &&
      mapEquals(other.ports, ports) &&
      listEquals(other.driverIds, driverIds) &&
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
    mac,
    setHash(otherMacs),
    stableId,
    mapHash(ports),
    listHash(driverIds),
    lastSeen?.microsecondsSinceEpoch,
  );

  @override
  String toString() => 'DeviceRecord($id "$name" at $host)';
}

/// Persists [DeviceRecord]s. Implementations: [MemoryDeviceRepository], a
/// JSON file repository in watchme_io.
abstract interface class DeviceRepository {
  /// Every record.
  Future<List<DeviceRecord>> all();

  /// The record with [id], or `null`.
  Future<DeviceRecord?> get(String id);

  /// Inserts or replaces the record with the same id.
  Future<void> put(DeviceRecord record);

  /// Removes the record with [id], if any.
  Future<void> remove(String id);
}

/// A [DeviceRepository] held in memory.
final class MemoryDeviceRepository implements DeviceRepository {
  /// Creates a repository, optionally seeded with [initial] records.
  MemoryDeviceRepository([Iterable<DeviceRecord> initial = const []]) {
    for (final r in initial) {
      _records[r.id] = r;
    }
  }

  final Map<String, DeviceRecord> _records = {};

  @override
  Future<List<DeviceRecord>> all() async => List.of(_records.values);

  @override
  Future<DeviceRecord?> get(String id) async => _records[id];

  @override
  Future<void> put(DeviceRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<void> remove(String id) async {
    _records.remove(id);
  }
}
