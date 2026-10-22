import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

void main() {
  test('features derive from the network stack and extras', () {
    final t = FakeTransports(extraFeatures: {TransportFeature.internet});
    expect(t.features, containsAll(TransportFeature.allNetwork));
    expect(t.features, contains(TransportFeature.internet));
    expect(t.features, isNot(contains(TransportFeature.subprocess)));
    expect(t.requireNetwork(), same(t.net));

    t.net.features.remove(TransportFeature.multicast);
    expect(t.supportsAll({TransportFeature.multicast}), isFalse);
  });

  test('offline bundle has no network', () {
    final t = FakeTransports.offline();
    expect(t.network, isNull);
    expect(t.features, isEmpty);
    expect(() => t.net, throwsStateError);
    expect(t.requireNetwork, throwsWatchmeError(WatchmeErrorCode.unsupported));
  });

  test(
    'FakeDiscoveryProvider filters by service type and records scans',
    () async {
      final provider = FakeDiscoveryProvider(
        DiscoveryProviderId.ssdp,
        hits: const [
          DiscoveryHit(
            host: '192.0.2.10',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'roku:ecp',
          ),
          DiscoveryHit(
            host: '192.0.2.7',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'urn:dial-multiscreen-org:service:dial:1',
          ),
        ],
      );
      final all = await provider.scan(const Duration(seconds: 1)).toList();
      expect(all, hasLength(2));
      final roku = await provider
          .scan(const Duration(seconds: 2), serviceTypes: {'ROKU:ECP'})
          .toList();
      expect(roku.single.host, '192.0.2.10');
      expect(provider.scans, hasLength(2));
      expect(provider.scans.last.serviceTypes, {'ROKU:ECP'});
    },
  );

  test('matchers', () {
    expect(const Confirmed(), isConfirmed);
    expect(
      const Confirmed(payload: AppListPayload([])),
      isConfirmedWith(isA<AppListPayload>()),
    );
    expect(const SentUnconfirmed(), isSentUnconfirmed);
    expect(const SentUnconfirmed(), isDelivered);
    expect(const Unsupported('no mapping'), isUnsupported('no mapping'));
    expect(const Unsupported('x'), isUnsupported());
    expect(
      const Failed(WatchmeError.rejected('no', rawDeviceMessage: 'raw')),
      isFailedWith(WatchmeErrorCode.rejected, rawDeviceMessage: 'raw'),
    );
    expect(
      const PairingFailed(WatchmeError.cancelled('stop')),
      isPairingFailedWith(WatchmeErrorCode.cancelled),
    );
    expect(const Paired.redacted(), isPairedWith(isNull));
    expect(fakeFingerprint('x'), hasLength(64));
    expect(sha256Hex([]), startsWith('e3b0c442'));
  });
}
