import 'package:watchme_core/watchme_core.dart';

import 'util.dart';

/// What the engine knows about who a physical device is, independent of its
/// current IP address.
///
/// Stable ids come from two places, and they are treated differently:
///
/// * [stableIds] holds every id seen for the device: SSDP USN uuids, mDNS
///   ids and probe ids. A device advertises several (one per UPnP service),
///   so a mismatch between them proves nothing.
/// * [probeStableIds] holds the ids drivers reported from a probe
///   ([DeviceInfo.stableId]). A driver reports one per device, so two
///   different ids in the same namespace (`roku:serial:A` and
///   `roku:serial:B`) mean two different devices.
///
/// MACs and stable ids are normalised: MACs with [tryNormalizeMac] (the
/// all-zero MAC some devices report is dropped), stable ids lower-cased
/// with any `::service` suffix of an SSDP USN removed.
final class DeviceIdentity {
  /// Creates an identity at [host].
  DeviceIdentity({
    required this.host,
    Iterable<String> macs = const [],
    Iterable<String> stableIds = const [],
    Iterable<String> probeStableIds = const [],
  }) : macs = {
         for (final m in macs)
           if (tryNormalizeMac(m) case final mac? when mac != _zeroMac) mac,
       },
       probeStableIds = {
         for (final id in probeStableIds) ?normalizeStableId(id),
       },
       stableIds = {
         for (final id in [...stableIds, ...probeStableIds])
           ?normalizeStableId(id),
       };

  /// The identity a persisted record describes. The record's stable id is
  /// treated as a probe id (it is one whenever a probe supplied it).
  factory DeviceIdentity.ofRecord(DeviceRecord record) => DeviceIdentity(
    host: record.host,
    macs: record.allMacs,
    probeStableIds: [?record.stableId],
  );

  static const String _zeroMac = '00:00:00:00:00:00';

  /// Where the device was last seen.
  final String host;

  /// Normalised MACs.
  final Set<String> macs;

  /// Every normalised stable id, including [probeStableIds].
  final Set<String> stableIds;

  /// Normalised stable ids reported by driver probes.
  final Set<String> probeStableIds;

  /// Whether nothing but the host is known.
  bool get isHostOnly => macs.isEmpty && stableIds.isEmpty;

  /// Whether [other] must be a different device even if it shares a host:
  /// both know MACs and share none, or both have probe ids in a common
  /// namespace and share none.
  bool conflictsWith(DeviceIdentity other) {
    if (macs.isNotEmpty &&
        other.macs.isNotEmpty &&
        !macs.any(other.macs.contains)) {
      return true;
    }
    if (probeStableIds.any(other.probeStableIds.contains)) return false;
    final mine = probeStableIds.map(_namespace).toSet();
    return other.probeStableIds.map(_namespace).any(mine.contains);
  }

  /// The union of both identities, at [other]'s host (the newer sighting).
  DeviceIdentity mergedWith(DeviceIdentity other) => DeviceIdentity(
    host: other.host,
    macs: {...macs, ...other.macs},
    stableIds: {...stableIds, ...other.stableIds},
    probeStableIds: {...probeStableIds, ...other.probeStableIds},
  );

  @override
  String toString() => 'DeviceIdentity($host, $macs, $stableIds)';

  static String _namespace(String id) {
    final cut = id.lastIndexOf(':');
    return cut <= 0 ? id : id.substring(0, cut);
  }
}

/// Normalises a stable id for comparison: trimmed, lower-cased, and cut at
/// `::` so an SSDP USN (`uuid:X::urn:...`) compares equal to its UDN.
/// Returns `null` for an empty id.
String? normalizeStableId(String id) {
  var s = id.trim().toLowerCase();
  final cut = s.indexOf('::');
  if (cut >= 0) s = s.substring(0, cut);
  return s.isEmpty ? null : s;
}

/// Which rule matched in [resolveIdentity].
enum IdentityMatchKind {
  /// A shared MAC address.
  mac,

  /// A shared stable id.
  stableId,

  /// The same host, with no conflicting MAC or probe id.
  host,
}

/// Finds the known device that [candidate] belongs to, or `null` for a new
/// device.
///
/// Rules, strongest first; the first rule that matches any device wins:
///
/// 1. A shared MAC.
/// 2. A shared stable id.
/// 3. The same host, unless [DeviceIdentity.conflictsWith] says the two
///    cannot be the same device (an IP address handed to another TV).
///
/// Matching by MAC or stable id is what keeps a device's identity across
/// DHCP changes.
({String id, IdentityMatchKind kind})? resolveIdentity(
  DeviceIdentity candidate,
  Map<String, DeviceIdentity> known,
) {
  for (final MapEntry(:key, :value) in known.entries) {
    if (candidate.macs.any(value.macs.contains)) {
      return (id: key, kind: IdentityMatchKind.mac);
    }
  }
  for (final MapEntry(:key, :value) in known.entries) {
    if (candidate.stableIds.any(value.stableIds.contains)) {
      return (id: key, kind: IdentityMatchKind.stableId);
    }
  }
  for (final MapEntry(:key, :value) in known.entries) {
    if (value.host == candidate.host && !value.conflictsWith(candidate)) {
      return (id: key, kind: IdentityMatchKind.host);
    }
  }
  return null;
}

/// A device id derived from [identity]'s strongest key (MAC, then probe id,
/// then any stable id, then host), unique among [taken].
///
/// Ids are opaque (a hash), so they do not leak MAC addresses into URLs and
/// logs, and deterministic, so the same device gets the same id if the
/// registry is rebuilt.
String deviceIdFor(DeviceIdentity identity, Set<String> taken) {
  String first(Set<String> s) => (s.toList()..sort()).first;
  final key = identity.macs.isNotEmpty
      ? 'mac:${first(identity.macs)}'
      : identity.probeStableIds.isNotEmpty
      ? 'id:${first(identity.probeStableIds)}'
      : identity.stableIds.isNotEmpty
      ? 'id:${first(identity.stableIds)}'
      : 'host:${identity.host}';
  final base = 'tv-${fnv1a32(key)}';
  if (!taken.contains(base)) return base;
  for (var n = 2; ; n++) {
    final id = '$base-$n';
    if (!taken.contains(id)) return id;
  }
}
