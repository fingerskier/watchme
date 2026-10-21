import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 21, 12);
  final t1 = t0.add(const Duration(seconds: 5));

  group('DeviceState.merge', () {
    test('newer observations win', () {
      final old = DeviceState(
        power: Observed.reported(PowerMode.on, 'roku.ecp', t0),
      );
      final update = DeviceState(
        power: Observed.inferred(PowerMode.standby, 'engine', t1),
      );
      expect(old.merge(update).power!.value, PowerMode.standby);
      expect(update.merge(old).power!.value, PowerMode.standby);
    });

    test('at the same instant the more confident observation wins', () {
      final reported = DeviceState(
        power: Observed.reported(PowerMode.on, 'a', t0),
      );
      final inferred = DeviceState(
        power: Observed.inferred(PowerMode.off, 'b', t0),
      );
      expect(reported.merge(inferred).power!.value, PowerMode.on);
      expect(inferred.merge(reported).power!.value, PowerMode.on);
    });

    test('a full tie prefers the incoming state', () {
      final a = DeviceState(volume: Observed.reported(10, 'a', t0));
      final b = DeviceState(volume: Observed.reported(20, 'b', t0));
      expect(a.merge(b).volume!.value, 20);
    });

    test('absent fields are kept and connections are combined', () {
      final base = DeviceState(
        power: Observed.reported(PowerMode.on, 'roku.ecp', t0),
        muted: Observed.reported(false, 'roku.ecp', t0),
        connections: const {'roku.ecp': ConnectionState.connected},
      );
      final update = DeviceState(
        volume: Observed.reported(30, 'upnp', t1),
        connections: const {
          'roku.ecp': ConnectionState.failed,
          'wol': ConnectionState.disconnected,
        },
      );
      final merged = base.merge(update);
      expect(merged.power, base.power);
      expect(merged.muted, base.muted);
      expect(merged.volume, update.volume);
      expect(merged.connections, {
        'roku.ecp': ConnectionState.failed,
        'wol': ConnectionState.disconnected,
      });
    });

    test('merging empty is the identity', () {
      final s = DeviceState(power: Observed.reported(PowerMode.on, 'x', t0));
      expect(s.merge(DeviceState.empty), s);
      expect(DeviceState.empty.merge(s), s);
    });
  });

  test('copyWith replaces only given fields', () {
    final s = DeviceState(
      power: Observed.reported(PowerMode.on, 'x', t0),
      volume: Observed.reported(5, 'x', t0),
    );
    final c = s.copyWith(volume: Observed.reported(6, 'x', t1));
    expect(c.power, s.power);
    expect(c.volume!.value, 6);
    expect(s.copyWith(), s);
  });

  test('changesSince returns only differing fields', () {
    final before = DeviceState(
      power: Observed.reported(PowerMode.on, 'x', t0),
      volume: Observed.reported(5, 'x', t0),
      connections: const {'x': ConnectionState.connected},
    );
    final after = before.copyWith(
      volume: Observed.reported(6, 'x', t1),
      connections: const {
        'x': ConnectionState.connected,
        'y': ConnectionState.connecting,
      },
    );
    final diff = after.changesSince(before);
    expect(diff.power, isNull);
    expect(diff.volume!.value, 6);
    expect(diff.connections, {'y': ConnectionState.connecting});
    expect(before.changesSince(before).isEmpty, isTrue);
    expect(before.merge(diff), after);
  });

  test('markStale downgrades every observation and keeps timestamps', () {
    final s = DeviceState(
      power: Observed.reported(PowerMode.on, 'x', t0),
      nowPlaying: Observed.reported(const NowPlaying(), 'x', t0),
    ).markStale();
    expect(s.power!.confidence, Confidence.stale);
    expect(s.power!.at, t0);
    expect(s.nowPlaying!.confidence, Confidence.stale);
    expect(s.volume, isNull);
  });

  test('Observed equality compares instants across time zones', () {
    final utc = Observed.reported(1, 's', t0);
    final local = Observed.reported(1, 's', t0.toLocal());
    expect(utc, local);
    expect(utc.hashCode, local.hashCode);
  });

  test('capability list helpers', () {
    const caps = [
      CapabilitySupport.yes(Capability.mute),
      CapabilitySupport.partial(
        Capability.volume,
        flags: {CapFlag.relativeOnly},
      ),
    ];
    expect(caps.supportFor(Capability.mute).usable, isTrue);
    expect(caps.supportFor(Capability.channel).level, Support.unknown);
    expect(caps.toCapabilityMap().keys, [Capability.mute, Capability.volume]);
    expect(const CapabilitySupport.no(Capability.mute).usable, isFalse);
  });
}
