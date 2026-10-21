import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

/// Matches a [Confirmed] result.
final Matcher isConfirmed = isA<Confirmed>();

/// Matches a [Confirmed] result whose payload matches [payload].
Matcher isConfirmedWith(Object? payload) =>
    isA<Confirmed>().having((r) => r.payload, 'payload', payload);

/// Matches a [SentUnconfirmed] result.
final Matcher isSentUnconfirmed = isA<SentUnconfirmed>();

/// Matches a delivered result ([Confirmed] or [SentUnconfirmed]).
final Matcher isDelivered = isA<CommandResult>().having(
  (r) => r.delivered,
  'delivered',
  isTrue,
);

/// Matches an [Unsupported] result, optionally with a matching [reason].
Matcher isUnsupported([Object? reason]) =>
    isA<Unsupported>().having((r) => r.reason, 'reason', reason ?? anything);

/// Matches a [WatchmeError] with [code] and, optionally, matching [message]
/// and [rawDeviceMessage].
Matcher isWatchmeError(
  WatchmeErrorCode code, {
  Object? message,
  Object? rawDeviceMessage,
}) => isA<WatchmeError>()
    .having((e) => e.code, 'code', code)
    .having((e) => e.message, 'message', message ?? anything)
    .having(
      (e) => e.rawDeviceMessage,
      'rawDeviceMessage',
      rawDeviceMessage ?? anything,
    );

/// Matches a function or future that throws a matching [WatchmeError].
Matcher throwsWatchmeError(
  WatchmeErrorCode code, {
  Object? message,
  Object? rawDeviceMessage,
}) => throwsA(
  isWatchmeError(code, message: message, rawDeviceMessage: rawDeviceMessage),
);

/// Matches a [Failed] result whose error has [code] (and optional message
/// matchers).
Matcher isFailedWith(
  WatchmeErrorCode code, {
  Object? message,
  Object? rawDeviceMessage,
}) => isA<Failed>().having(
  (r) => r.error,
  'error',
  isWatchmeError(code, message: message, rawDeviceMessage: rawDeviceMessage),
);

/// Matches a [PairingFailed] step whose error has [code].
Matcher isPairingFailedWith(
  WatchmeErrorCode code, {
  Object? rawDeviceMessage,
}) => isA<PairingFailed>().having(
  (s) => s.error,
  'error',
  isWatchmeError(code, rawDeviceMessage: rawDeviceMessage),
);

/// Matches a [Paired] step, optionally with a credential matching
/// [credential].
Matcher isPairedWith([Object? credential]) => isA<Paired>().having(
  (s) => s.credential,
  'credential',
  credential ?? anything,
);
