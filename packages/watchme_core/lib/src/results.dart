import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'commands.dart';
import 'errors.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// The outcome of executing a [Command].
///
/// Drivers never throw from `execute`; every outcome is one of these.
@immutable
sealed class CommandResult {
  const CommandResult();

  /// Decodes the form written by [toJson].
  factory CommandResult.fromJson(JsonMap json) => switch (typeOf(json)) {
    'confirmed' => Confirmed(
      payload: switch (optMap(json, 'payload')) {
        null => null,
        final p => CommandPayload.fromJson(p),
      },
    ),
    'sentUnconfirmed' => const SentUnconfirmed(),
    'unsupported' => Unsupported(req<String>(json, 'reason')),
    'failed' => Failed(WatchmeError.fromJson(reqMap(json, 'error'))),
    final other => throw FormatException('Unknown result type: $other'),
  };

  /// Whether the whole command reached the device without an error
  /// ([Confirmed] or [SentUnconfirmed]).
  ///
  /// `false` does not prove that nothing happened: after a [Failed] with
  /// [WatchmeErrorCode.timeout] or [WatchmeErrorCode.partiallyDelivered]
  /// the device may have acted. Only [Unsupported], and failures such as
  /// [WatchmeErrorCode.unreachable] and [WatchmeErrorCode.destinationRefused],
  /// mean nothing was delivered.
  bool get delivered => this is Confirmed || this is SentUnconfirmed;

  /// Whether part of a command made of several requests reached the device
  /// before it failed ([Failed] with [WatchmeErrorCode.partiallyDelivered]).
  ///
  /// The device state is then uncertain. Never retry the command or fall
  /// back to another route after it.
  bool get partiallyDelivered => switch (this) {
    Failed(:final error) => error.code == WatchmeErrorCode.partiallyDelivered,
    _ => false,
  };

  /// JSON form: `{"type": ..., ...fields}`.
  JsonMap toJson();
}

/// The device acknowledged the command, or its state visibly changed.
final class Confirmed extends CommandResult {
  /// Creates a confirmation, optionally carrying data the command asked for.
  const Confirmed({this.payload});

  /// Data returned by query-like commands ([ListApps], [TakeScreenshot]).
  final CommandPayload? payload;

  @override
  JsonMap toJson() => {
    'type': 'confirmed',
    if (payload != null) 'payload': payload!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Confirmed && other.payload == payload;

  @override
  int get hashCode => Object.hash('confirmed', payload);

  @override
  String toString() => payload == null ? 'Confirmed()' : 'Confirmed($payload)';
}

/// The command was sent on a write-only path; nothing confirmed it.
final class SentUnconfirmed extends CommandResult {
  /// Creates an unconfirmed result.
  const SentUnconfirmed();

  @override
  JsonMap toJson() => const {'type': 'sentUnconfirmed'};

  @override
  bool operator ==(Object other) => other is SentUnconfirmed;

  @override
  int get hashCode => 'sentUnconfirmed'.hashCode;

  @override
  String toString() => 'SentUnconfirmed()';
}

/// The command cannot be executed here, and nothing was sent.
///
/// Used for unmapped keys and commands, missing capabilities, and the power
/// orchestrator's refusal to send a toggle on a guess
/// ([needsConfirmation]).
final class Unsupported extends CommandResult {
  /// Creates an unsupported result with a human-readable [reason].
  const Unsupported(this.reason);

  /// The reason the power orchestrator gives when it refuses to guess: for
  /// [SetPower], a power toggle without two agreeing state sources; for
  /// `PressKey(RemoteKey.power)`, a current state that neither two agreeing
  /// sources nor a single device-reported one with a discrete route settles
  /// (see [PressKey]), or any press within the quiet period after the last
  /// power command.
  ///
  /// The UI then asks the user "Is the TV on right now?" and sends
  /// `SetPower(!isOn, userConfirmed: true)` (see [SetPower.userConfirmed]).
  static const String needsConfirmation = 'needs confirmation';

  /// Why the command was not sent.
  final String reason;

  @override
  JsonMap toJson() => {'type': 'unsupported', 'reason': reason};

  @override
  bool operator ==(Object other) =>
      other is Unsupported && other.reason == reason;

  @override
  int get hashCode => Object.hash('unsupported', reason);

  @override
  String toString() => 'Unsupported($reason)';
}

/// The command was attempted and failed.
final class Failed extends CommandResult {
  /// Creates a failure.
  const Failed(this.error);

  /// What went wrong.
  final WatchmeError error;

  /// The device's own error text, if any (same as
  /// [WatchmeError.rawDeviceMessage]).
  String? get rawDeviceMessage => error.rawDeviceMessage;

  @override
  JsonMap toJson() => {'type': 'failed', 'error': error.toJson()};

  @override
  bool operator ==(Object other) => other is Failed && other.error == error;

  @override
  int get hashCode => Object.hash('failed', error);

  @override
  String toString() => 'Failed($error)';
}

/// Data carried by a [Confirmed] result for query-like commands.
@immutable
sealed class CommandPayload {
  const CommandPayload();

  /// Decodes the form written by [toJson].
  factory CommandPayload.fromJson(JsonMap json) => switch (typeOf(json)) {
    'appList' => AppListPayload(objList(json, 'apps', AppInfo.fromJson)),
    'screenshot' => ScreenshotPayload(
      reqBytes(json, 'bytes'),
      mimeType: req<String>(json, 'mimeType'),
    ),
    final other => throw FormatException('Unknown payload type: $other'),
  };

  /// JSON form: `{"type": ..., ...fields}`.
  JsonMap toJson();
}

/// The result of [ListApps].
final class AppListPayload extends CommandPayload {
  /// Creates an app-list payload.
  const AppListPayload(this.apps);

  /// Installed apps and launchable entries.
  final List<AppInfo> apps;

  @override
  JsonMap toJson() => {
    'type': 'appList',
    'apps': [for (final a in apps) a.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is AppListPayload && listEquals(other.apps, apps);

  @override
  int get hashCode => Object.hash('appList', listHash(apps));

  @override
  String toString() => 'AppListPayload(${apps.length} apps)';
}

/// The result of [TakeScreenshot].
final class ScreenshotPayload extends CommandPayload {
  /// Creates a screenshot payload.
  const ScreenshotPayload(this.bytes, {required this.mimeType});

  /// Encoded image bytes.
  final Uint8List bytes;

  /// Image MIME type, e.g. `image/png`.
  final String mimeType;

  @override
  JsonMap toJson() => {
    'type': 'screenshot',
    'mimeType': mimeType,
    'bytes': base64Of(bytes),
  };

  @override
  bool operator ==(Object other) =>
      other is ScreenshotPayload &&
      other.mimeType == mimeType &&
      listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hash('screenshot', mimeType, listHash(bytes));

  @override
  String toString() => 'ScreenshotPayload($mimeType, ${bytes.length} bytes)';
}
