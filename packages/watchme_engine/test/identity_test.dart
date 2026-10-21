import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';

void main() {
  group('DeviceIdentity', () {
    test('normalises MACs and stable ids and drops the zero MAC', () {
      final id = DeviceIdentity(
        host: '192.0.2.10',
        macs: ['AA-BB-CC-DD-EE-FF', '00:00:00:00:00:00', 'not a mac'],
        stableIds: ['UUID:ABC::urn:dial-multiscreen-org:service:dial:1'],
        probeStableIds: ['roku:serial:X004'],
      );
      expect(id.macs, {'aa:bb:cc:dd:ee:ff'});
      expect(id.stableIds, {'uuid:abc', 'roku:serial:x004'});
      expect(id.probeStableIds, {'roku:serial:x004'});
    });

    test('conflicts on disjoint MACs or same-namespace probe ids', () {
      final a = DeviceIdentity(
        host: 'h',
        macs: ['aa:aa:aa:aa:aa:aa'],
        probeStableIds: ['roku:serial:A'],
      );
      expect(
        a.conflictsWith(DeviceIdentity(host: 'h', macs: ['bb:bb:bb:bb:bb:bb'])),
        isTrue,
      );
      expect(
        a.conflictsWith(
          DeviceIdentity(host: 'h', probeStableIds: ['roku:serial:B']),
        ),
        isTrue,
      );
      // Ids from different namespaces (another driver) prove nothing.
      expect(
        a.conflictsWith(DeviceIdentity(host: 'h', probeStableIds: ['uuid:1'])),
        isFalse,
      );
      // Hit ids (USNs) never conflict: devices advertise several.
      expect(
        a.conflictsWith(DeviceIdentity(host: 'h', stableIds: ['uuid:other'])),
        isFalse,
      );
    });
  });

  group('resolveIdentity', () {
    final known = {
      'tv-a': DeviceIdentity(
        host: '192.0.2.10',
        macs: ['aa:aa:aa:aa:aa:aa'],
        stableIds: ['uuid:roku-a'],
      ),
      'tv-b': DeviceIdentity(host: '192.0.2.20', stableIds: ['uuid:firetv-b']),
    };

    test('matches by MAC first, wherever the device is now', () {
      final r = resolveIdentity(
        DeviceIdentity(host: '192.0.2.99', macs: ['AA:AA:AA:AA:AA:AA']),
        known,
      );
      expect(r, (id: 'tv-a', kind: IdentityMatchKind.mac));
    });

    test('matches by stable id (an SSDP USN) across an IP change', () {
      final r = resolveIdentity(
        DeviceIdentity(
          host: '192.0.2.77',
          stableIds: ['uuid:firetv-b::urn:dial-multiscreen-org:service:dial:1'],
        ),
        known,
      );
      expect(r, (id: 'tv-b', kind: IdentityMatchKind.stableId));
    });

    test('matches by host when nothing conflicts', () {
      final r = resolveIdentity(
        DeviceIdentity(host: '192.0.2.20', stableIds: ['mdns:firetv']),
        known,
      );
      expect(r, (id: 'tv-b', kind: IdentityMatchKind.host));
    });

    test('a different MAC at a known host is a new device', () {
      final r = resolveIdentity(
        DeviceIdentity(host: '192.0.2.10', macs: ['cc:cc:cc:cc:cc:cc']),
        known,
      );
      expect(r, isNull);
    });
  });

  group('deviceIdFor', () {
    test('is deterministic, opaque and unique', () {
      final identity = DeviceIdentity(
        host: '192.0.2.1',
        macs: ['aa:bb:cc:dd:ee:ff'],
      );
      final id = deviceIdFor(identity, {});
      expect(id, matches(RegExp(r'^tv-[0-9a-f]{8}$')));
      expect(id, isNot(contains('aabbcc')));
      expect(deviceIdFor(identity, {}), id);
      expect(deviceIdFor(identity, {id}), '$id-2');
      expect(deviceIdFor(identity, {id, '$id-2'}), '$id-3');
    });

    test('prefers MAC over stable id over host', () {
      final byMac = deviceIdFor(
        DeviceIdentity(host: 'x', macs: ['aa:bb:cc:dd:ee:ff']),
        {},
      );
      final sameMacOtherHost = deviceIdFor(
        DeviceIdentity(
          host: 'y',
          macs: ['aa:bb:cc:dd:ee:ff'],
          stableIds: ['uuid:1'],
        ),
        {},
      );
      expect(sameMacOtherHost, byMac);
    });
  });

  test('Backoff doubles up to the cap and then gives up', () {
    const b = Backoff(
      initial: Duration(seconds: 1),
      max: Duration(seconds: 5),
      maxAttempts: 5,
    );
    expect(
      [for (var i = 0; i < 6; i++) b.delayFor(i)?.inSeconds],
      [1, 2, 4, 5, 5, null],
    );
    expect(normalizeMac('AABBCCDDEEFF'), 'aa:bb:cc:dd:ee:ff');
  });
}
