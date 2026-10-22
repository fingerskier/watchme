import 'package:test/test.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

void main() {
  final start = DateTime.utc(2026, 10, 21, 12);

  test('time moves only on advance', () async {
    final clock = FakeClock(start);
    expect(clock.now(), start);
    await clock.advance(const Duration(minutes: 1));
    expect(clock.now(), start.add(const Duration(minutes: 1)));
    await clock.advanceTo(start);
    expect(clock.now(), start.add(const Duration(minutes: 1)));
  });

  test('timers fire in time order at their due time', () async {
    final clock = FakeClock(start);
    final fired = <String>[];
    clock.timer(
      const Duration(seconds: 3),
      () => fired.add('b@${clock.now().second}'),
    );
    clock.timer(
      const Duration(seconds: 1),
      () => fired.add('a@${clock.now().second}'),
    );
    final cancelled = clock.timer(
      const Duration(seconds: 2),
      () => fired.add('x'),
    );
    cancelled.cancel();
    expect(clock.pendingTimers, 2);
    await clock.advance(const Duration(seconds: 2));
    expect(fired, ['a@1']);
    await clock.advance(const Duration(seconds: 5));
    expect(fired, ['a@1', 'b@3']);
    expect(clock.pendingTimers, 0);
  });

  test('periodic timers repeat until cancelled', () async {
    final clock = FakeClock(start);
    final ticks = <int>[];
    final timer = clock.periodic(const Duration(seconds: 5), (t) {
      ticks.add(t.tick);
      if (t.tick == 3) t.cancel();
    });
    await clock.advance(const Duration(seconds: 12));
    expect(ticks, [1, 2]);
    await clock.advance(const Duration(seconds: 100));
    expect(ticks, [1, 2, 3]);
    expect(timer.isActive, isFalse);
  });

  test('delay completes and async code continues inside advance', () async {
    final clock = FakeClock(start);
    final log = <String>[];
    Future<void> poller() async {
      for (var i = 0; i < 3; i++) {
        await clock.delay(const Duration(seconds: 10));
        log.add('poll ${clock.now().difference(start).inSeconds}');
      }
    }

    final done = poller();
    await clock.advance(const Duration(seconds: 25));
    expect(log, ['poll 10', 'poll 20']);
    await clock.advance(const Duration(seconds: 5));
    await done;
    expect(log, ['poll 10', 'poll 20', 'poll 30']);
  });
}
