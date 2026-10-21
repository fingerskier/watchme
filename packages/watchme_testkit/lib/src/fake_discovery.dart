import 'package:watchme_core/watchme_core.dart';

/// A [DiscoveryProvider] that yields scripted hits.
///
/// With non-empty `serviceTypes`, [scan] yields only hits whose service type
/// is among them (as a real SSDP or mDNS query would), compared with
/// [normalizeServiceType].
class FakeDiscoveryProvider implements DiscoveryProvider {
  /// Creates a provider with id [id] that will report [hits].
  FakeDiscoveryProvider(
    this.id, {
    Iterable<DiscoveryHit> hits = const [],
    this.requires = const {},
  }) : hits = [...hits];

  @override
  final String id;

  @override
  final Set<TransportFeature> requires;

  /// Hits reported by every scan. Mutable.
  final List<DiscoveryHit> hits;

  /// Every scan so far: its window and requested service types.
  final List<({Duration window, Set<String> serviceTypes})> scans = [];

  @override
  Stream<DiscoveryHit> scan(
    Duration window, {
    Set<String> serviceTypes = const {},
  }) {
    scans.add((window: window, serviceTypes: serviceTypes));
    final wanted = {for (final t in serviceTypes) normalizeServiceType(t)};
    return Stream.fromIterable([
      for (final hit in hits)
        if (wanted.isEmpty ||
            (hit.serviceType != null &&
                wanted.contains(normalizeServiceType(hit.serviceType!))))
          hit,
    ]);
  }
}
