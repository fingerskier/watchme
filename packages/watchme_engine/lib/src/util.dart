import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

/// Completes with [future]'s outcome, or fails with [onTimeout]'s error once
/// [timeout] has passed on [clock].
///
/// The engine uses [Clock] timers instead of `Future.timeout` so tests can
/// drive time with a fake clock. A value that arrives after the timeout is
/// passed to [onLateValue] (e.g. to close a session nobody will use).
Future<T> withClockTimeout<T>(
  Future<T> future,
  Duration timeout,
  Clock clock,
  WatchmeError Function() onTimeout, {
  void Function(T value)? onLateValue,
}) {
  final done = Completer<T>();
  final timer = clock.timer(timeout, () {
    if (!done.isCompleted) done.completeError(onTimeout());
  });
  future.then(
    (value) {
      timer.cancel();
      if (done.isCompleted) {
        onLateValue?.call(value);
      } else {
        done.complete(value);
      }
    },
    onError: (Object error, StackTrace stack) {
      timer.cancel();
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  return done.future;
}

/// Failure codes that prove the device did not act on a command: nothing
/// reached it, or it understood and declined.
const Set<WatchmeErrorCode> _nothingDone = {
  WatchmeErrorCode.unreachable,
  WatchmeErrorCode.destinationRefused,
  WatchmeErrorCode.unauthorized,
  WatchmeErrorCode.reauthRequired,
  WatchmeErrorCode.rejected,
  WatchmeErrorCode.unsupported,
  WatchmeErrorCode.cancelled,
};

/// Whether [result] is a failure after which the device may still have
/// acted on the command, in full or in part: a timeout, a partial delivery,
/// a malformed answer or a driver bug. The state the command changes is
/// then uncertain, and nothing may be retried or toggled on top of it.
bool mayHaveActed(CommandResult result) => switch (result) {
  Failed(:final error) => !_nothingDone.contains(error.code),
  _ => false,
};

/// 32-bit FNV-1a of [text]'s UTF-16 code units, as 8 hex digits.
///
/// The multiply is split so the result is the same when compiled to
/// JavaScript, where integers above 2^53 lose precision.
String fnv1a32(String text) {
  var hash = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    // hash * 16777619 == hash * 2^24 + hash * 403 (mod 2^32).
    hash = (((hash << 24) & 0xffffffff) + hash * 403) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
