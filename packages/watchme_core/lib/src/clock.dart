import 'dart:async';

/// Time, injectable so tests can control it (`FakeClock` in
/// watchme_testkit). Drivers and the engine use this instead of
/// `DateTime.now()`, `Future.delayed` and `Timer` directly.
abstract interface class Clock {
  /// The current time.
  DateTime now();

  /// Completes after [duration].
  Future<void> delay(Duration duration);

  /// Calls [callback] once after [duration].
  Timer timer(Duration duration, void Function() callback);

  /// Calls [callback] every [period] until the timer is cancelled.
  Timer periodic(Duration period, void Function(Timer timer) callback);
}

/// The real clock.
final class SystemClock implements Clock {
  /// Creates the real clock.
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  Future<void> delay(Duration duration) => Future.delayed(duration);

  @override
  Timer timer(Duration duration, void Function() callback) =>
      Timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      Timer.periodic(period, callback);
}
