import 'package:meta/meta.dart';

import 'util/json.dart';

/// Broad classes of failure, chosen so the engine and UI can react without
/// parsing messages.
enum WatchmeErrorCode {
  /// Nothing answered: connection refused, no route, DNS failure, port closed.
  /// Nothing reached the device, so retrying or falling back is safe.
  unreachable,

  /// The peer accepted the connection but did not answer in time, or the
  /// connection was lost after it was made. The device may have acted.
  timeout,

  /// The device refused us for lack of credentials (no token yet, wrong PIN).
  unauthorized,

  /// A credential that used to work was revoked or wiped; pair again.
  ///
  /// Examples: Fire TV 401/403 on a stored token, LG 403 after a reset,
  /// VIDAA tokens wiped by deep standby.
  reauthRequired,

  /// The device understood the request and declined it.
  ///
  /// Examples: Roku `403 ECP command not allowed in Limited mode.`, a user
  /// pressing "Deny" on the TV, LG `blacklisted certificate`.
  rejected,

  /// The peer answered with something we could not interpret, or TLS failed
  /// (including a pinned certificate that no longer matches).
  protocol,

  /// The device, driver or transport cannot do this at all.
  unsupported,

  /// The operation was cancelled by the user or by shutdown.
  cancelled,

  /// A bug or unexpected state inside watchme.
  internal,
}

/// The single error type that crosses watchme package boundaries.
///
/// Transports throw it for transport-level failures, drivers wrap it in
/// `Failed` and `PairingFailed`, and the hub serialises it to JSON.
/// [rawDeviceMessage] preserves the device's own words (an HTTP body, a
/// WebSocket error frame) so the UI can show them instead of a generic text.
@immutable
final class WatchmeError implements Exception {
  /// Creates an error with an explicit [code].
  const WatchmeError(
    this.code,
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  });

  /// Creates a [WatchmeErrorCode.unreachable] error.
  const WatchmeError.unreachable(
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  }) : code = WatchmeErrorCode.unreachable;

  /// Creates a [WatchmeErrorCode.timeout] error.
  const WatchmeError.timeout(this.message, {this.rawDeviceMessage, this.cause})
    : code = WatchmeErrorCode.timeout;

  /// Creates a [WatchmeErrorCode.unauthorized] error.
  const WatchmeError.unauthorized(
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  }) : code = WatchmeErrorCode.unauthorized;

  /// Creates a [WatchmeErrorCode.reauthRequired] error.
  const WatchmeError.reauthRequired(
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  }) : code = WatchmeErrorCode.reauthRequired;

  /// Creates a [WatchmeErrorCode.rejected] error.
  const WatchmeError.rejected(this.message, {this.rawDeviceMessage, this.cause})
    : code = WatchmeErrorCode.rejected;

  /// Creates a [WatchmeErrorCode.protocol] error.
  const WatchmeError.protocol(this.message, {this.rawDeviceMessage, this.cause})
    : code = WatchmeErrorCode.protocol;

  /// Creates a [WatchmeErrorCode.unsupported] error.
  const WatchmeError.unsupported(
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  }) : code = WatchmeErrorCode.unsupported;

  /// Creates a [WatchmeErrorCode.cancelled] error.
  const WatchmeError.cancelled(
    this.message, {
    this.rawDeviceMessage,
    this.cause,
  }) : code = WatchmeErrorCode.cancelled;

  /// Creates a [WatchmeErrorCode.internal] error.
  const WatchmeError.internal(this.message, {this.rawDeviceMessage, this.cause})
    : code = WatchmeErrorCode.internal;

  /// Decodes the form written by [toJson].
  factory WatchmeError.fromJson(JsonMap json) => WatchmeError(
    reqEnum(json, 'code', WatchmeErrorCode.values),
    req<String>(json, 'message'),
    rawDeviceMessage: opt<String>(json, 'rawDeviceMessage'),
  );

  /// What kind of failure this is.
  final WatchmeErrorCode code;

  /// A short English explanation written by watchme.
  final String message;

  /// The device's own error text, verbatim, when it gave one.
  final String? rawDeviceMessage;

  /// The underlying exception, for logs only. Not serialised and not part of
  /// equality.
  final Object? cause;

  /// JSON form. [cause] is dropped.
  JsonMap toJson() => {
    'code': code.name,
    'message': message,
    if (rawDeviceMessage != null) 'rawDeviceMessage': rawDeviceMessage,
  };

  @override
  bool operator ==(Object other) =>
      other is WatchmeError &&
      other.code == code &&
      other.message == message &&
      other.rawDeviceMessage == rawDeviceMessage;

  @override
  int get hashCode => Object.hash(code, message, rawDeviceMessage);

  @override
  String toString() {
    final raw = rawDeviceMessage == null ? '' : ' (device: $rawDeviceMessage)';
    return 'WatchmeError(${code.name}): $message$raw';
  }
}
