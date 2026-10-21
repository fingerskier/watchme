import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

/// A [Clock] that only moves when the test says so.
///
/// ```dart
/// final clock = FakeClock(DateTime.utc(2026, 10, 21, 12));
/// final polls = <DateTime>[];
/// clock.periodic(const Duration(seconds: 5), (_) => polls.add(clock.now()));
/// await clock.advance(const Duration(seconds: 12)); // fires at 5 s and 10 s
/// ```
///
/// [advance] fires due timers in time order (ties in creation order) and
/// lets pending microtasks and zero-delay events run before and after each
/// one, so async code awaiting [delay] continues as it would in real time.
class FakeClock implements Clock {
  /// Creates a clock reading [start] (default 2026-01-01T00:00Z).
  FakeClock([DateTime? start]) : _now = start ?? DateTime.utc(2026);

  DateTime _now;
  int _sequence = 0;
  final List<_FakeTimer> _timers = [];

  @override
  DateTime now() => _now;

  /// Timers that have not fired (one-shot) or been cancelled.
  int get pendingTimers => _timers.where((t) => t.isActive).length;

  @override
  Future<void> delay(Duration duration) {
    final done = Completer<void>();
    timer(duration, done.complete);
    return done.future;
  }

  @override
  Timer timer(Duration duration, void Function() callback) =>
      _add(duration, null, (_) => callback());

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) {
    if (period <= Duration.zero) {
      throw ArgumentError.value(period, 'period', 'must be positive');
    }
    return _add(period, period, callback);
  }

  _FakeTimer _add(
    Duration delay,
    Duration? period,
    void Function(Timer) callback,
  ) {
    final t = _FakeTimer(
      this,
      _now.add(delay < Duration.zero ? Duration.zero : delay),
      period,
      callback,
      _sequence++,
    );
    _timers.add(t);
    return t;
  }

  /// Moves time forward by [by], firing every timer that falls due.
  Future<void> advance(Duration by) async {
    final target = _now.add(by);
    while (true) {
      await flush();
      final due = _timers.where((t) => t.isActive && !t.due.isAfter(target));
      if (due.isEmpty) break;
      final next = due.reduce(
        (a, b) =>
            a.due.isBefore(b.due) || (a.due == b.due && a.seq < b.seq) ? a : b,
      );
      if (next.due.isAfter(_now)) _now = next.due;
      next._fire();
    }
    _now = target;
    await flush();
  }

  /// Moves time forward to [time] (no-op if it is in the past).
  Future<void> advanceTo(DateTime time) async {
    if (time.isAfter(_now)) await advance(time.difference(_now));
  }

  /// Lets pending microtasks and zero-delay events run without moving time.
  Future<void> flush() async {
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this._clock, this.due, this._period, this._callback, this.seq);

  final FakeClock _clock;
  final Duration? _period;
  final void Function(Timer) _callback;
  final int seq;
  DateTime due;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  void _fire() {
    _tick++;
    if (_period == null) {
      _active = false;
      _clock._timers.remove(this);
    } else {
      due = due.add(_period);
    }
    _callback(this);
  }
}
