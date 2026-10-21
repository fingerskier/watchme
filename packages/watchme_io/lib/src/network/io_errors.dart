import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

/// Runs [body] and fails with [onTimeout]'s error if it has not finished
/// within [limit] on [clock].
///
/// The abandoned future keeps its error handler, so a late failure is never
/// reported as unhandled; [onTimeout] is where the caller tears the work down.
Future<T> runWithin<T>(
  Clock clock,
  Duration limit,
  Future<T> Function() body, {
  required WatchmeError Function() onTimeout,
}) {
  final completer = Completer<T>();
  final timer = clock.timer(limit, () {
    if (!completer.isCompleted) completer.completeError(onTimeout());
  });
  Future.sync(body).then(
    (value) {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      timer.cancel();
      if (!completer.isCompleted) completer.completeError(error, stack);
    },
  );
  return completer.future;
}

/// Maps a `dart:io` failure talking to [target] onto the `NetworkStack`
/// error contract.
///
/// [connected] says whether a connection had been established: before that,
/// every failure means nothing answered ([WatchmeErrorCode.unreachable]);
/// after it, a missing answer or a dropped connection is a
/// [WatchmeErrorCode.timeout], because the request may already have reached
/// the device and callers must not repeat it as if it had not.
WatchmeError ioError(Object error, String target, {required bool connected}) =>
    switch (error) {
      WatchmeError() => error,
      HandshakeException() => WatchmeError.protocol(
        'TLS handshake with $target failed: ${_describe(error)}',
        cause: error,
      ),
      TlsException() => WatchmeError.protocol(
        'TLS failure with $target: ${_describe(error)}',
        cause: error,
      ),
      SocketException() =>
        connected
            ? WatchmeError.timeout(
                'Connection to $target lost: ${_describe(error)}',
                cause: error,
              )
            : WatchmeError.unreachable(
                'Cannot reach $target: ${_describe(error)}',
                cause: error,
              ),
      WebSocketException() => WatchmeError.protocol(
        'WebSocket failure with $target: ${error.message}',
        cause: error,
      ),
      HttpException() => WatchmeError.protocol(
        'Malformed HTTP exchange with $target: ${error.message}',
        cause: error,
      ),
      TimeoutException() =>
        connected
            ? WatchmeError.timeout('No answer from $target', cause: error)
            : WatchmeError.unreachable(
                'No answer to connect from $target',
                cause: error,
              ),
      _ => WatchmeError.internal(
        'Unexpected failure talking to $target: $error',
        cause: error,
      ),
    };

String _describe(Object error) => switch (error) {
  SocketException(:final message, :final osError) =>
    osError == null || osError.message.isEmpty
        ? message
        : message.isEmpty
        ? osError.message
        : '$message (${osError.message})',
  TlsException(:final message, :final osError) =>
    osError == null ? message : '$message (${osError.message})',
  _ => '$error',
};
