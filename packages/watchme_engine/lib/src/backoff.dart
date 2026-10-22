import 'dart:math' as math;

/// Exponential backoff for reconnecting dropped sessions.
///
/// Attempt `n` (0-based) waits `initial * factor^n`, capped at [max]. After
/// [maxAttempts] attempts the engine stops reconnecting in the background
/// and reconnects lazily on the next command instead.
final class Backoff {
  /// Creates a backoff policy.
  const Backoff({
    this.initial = const Duration(seconds: 1),
    this.max = const Duration(minutes: 1),
    this.factor = 2,
    this.maxAttempts = 8,
  }) : assert(factor >= 1);

  /// Delay before the first attempt.
  final Duration initial;

  /// Longest delay between attempts.
  final Duration max;

  /// Growth per attempt.
  final double factor;

  /// Attempts before giving up; `null` retries forever.
  final int? maxAttempts;

  /// The delay before attempt [attempt] (0-based), or `null` once
  /// [maxAttempts] is reached.
  Duration? delayFor(int attempt) {
    if (attempt < 0) throw RangeError.value(attempt, 'attempt');
    final limit = maxAttempts;
    if (limit != null && attempt >= limit) return null;
    final ms = initial.inMilliseconds * math.pow(factor, attempt);
    if (ms >= max.inMilliseconds) return max;
    return Duration(milliseconds: ms.round());
  }
}
