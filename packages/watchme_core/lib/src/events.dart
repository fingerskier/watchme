import 'package:meta/meta.dart';

import 'capabilities.dart';
import 'errors.dart';
import 'state.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// Something that happened to a device, emitted by a driver session and
/// re-emitted by the engine.
@immutable
sealed class DeviceEvent {
  const DeviceEvent({required this.driverId});

  /// Decodes the form written by [toJson].
  factory DeviceEvent.fromJson(JsonMap json) {
    final driverId = req<String>(json, 'driverId');
    return switch (typeOf(json)) {
      'stateChanged' => StateChanged(
        DeviceState.fromJson(reqMap(json, 'state')),
        driverId: driverId,
      ),
      'connectionChanged' => ConnectionChanged(
        reqEnum(json, 'state', ConnectionState.values),
        driverId: driverId,
        error: switch (optMap(json, 'error')) {
          null => null,
          final e => WatchmeError.fromJson(e),
        },
      ),
      'capabilitiesChanged' => CapabilitiesChanged(
        objList(json, 'capabilities', CapabilitySupport.fromJson),
        driverId: driverId,
      ),
      'reauthRequired' => ReauthRequired(
        WatchmeError.fromJson(reqMap(json, 'error')),
        driverId: driverId,
      ),
      final other => throw FormatException('Unknown event type: $other'),
    };
  }

  /// The driver whose session produced the event.
  final String driverId;

  /// JSON form: `{"type": ..., "driverId": ..., ...fields}`.
  JsonMap toJson();
}

/// Part of the device state changed.
///
/// [state] holds only the fields that changed (see
/// [DeviceState.changesSince]); listeners [DeviceState.merge] it into
/// what they hold.
final class StateChanged extends DeviceEvent {
  /// Creates a state-change event.
  const StateChanged(this.state, {required super.driverId});

  /// The changed fields.
  final DeviceState state;

  @override
  JsonMap toJson() => {
    'type': 'stateChanged',
    'driverId': driverId,
    'state': state.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is StateChanged &&
      other.driverId == driverId &&
      other.state == state;

  @override
  int get hashCode => Object.hash('stateChanged', driverId, state);

  @override
  String toString() => 'StateChanged($driverId, $state)';
}

/// A driver session's connection state changed.
final class ConnectionChanged extends DeviceEvent {
  /// Creates a connection event; [error] explains a
  /// [ConnectionState.failed] or unexpected [ConnectionState.disconnected].
  const ConnectionChanged(this.state, {required super.driverId, this.error});

  /// The new connection state.
  final ConnectionState state;

  /// Why, when the change was caused by a failure.
  final WatchmeError? error;

  @override
  JsonMap toJson() => {
    'type': 'connectionChanged',
    'driverId': driverId,
    'state': state.name,
    if (error != null) 'error': error!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ConnectionChanged &&
      other.driverId == driverId &&
      other.state == state &&
      other.error == error;

  @override
  int get hashCode => Object.hash('connectionChanged', driverId, state, error);

  @override
  String toString() => 'ConnectionChanged($driverId, ${state.name}, $error)';
}

/// A live session learned that the device supports more or less than
/// before (e.g. a pointer socket returned 401, Roku switched to Limited
/// mode).
final class CapabilitiesChanged extends DeviceEvent {
  /// Creates a capabilities event carrying the session's full new list.
  const CapabilitiesChanged(this.capabilities, {required super.driverId});

  /// The session's complete, updated capability list.
  final List<CapabilitySupport> capabilities;

  @override
  JsonMap toJson() => {
    'type': 'capabilitiesChanged',
    'driverId': driverId,
    'capabilities': [for (final c in capabilities) c.toJson()],
  };

  @override
  bool operator ==(Object other) =>
      other is CapabilitiesChanged &&
      other.driverId == driverId &&
      listEquals(other.capabilities, capabilities);

  @override
  int get hashCode =>
      Object.hash('capabilitiesChanged', driverId, listHash(capabilities));

  @override
  String toString() => 'CapabilitiesChanged($driverId, $capabilities)';
}

/// A stored credential stopped working; the user must pair again.
///
/// Examples: Fire TV 401/403 on a stored token, LG 403, Samsung
/// `ms.channel.unauthorized`, VIDAA tokens wiped by deep standby.
final class ReauthRequired extends DeviceEvent {
  /// Creates a re-auth event. [error] carries the device's raw message.
  const ReauthRequired(this.error, {required super.driverId});

  /// What the device said.
  final WatchmeError error;

  @override
  JsonMap toJson() => {
    'type': 'reauthRequired',
    'driverId': driverId,
    'error': error.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ReauthRequired &&
      other.driverId == driverId &&
      other.error == error;

  @override
  int get hashCode => Object.hash('reauthRequired', driverId, error);

  @override
  String toString() => 'ReauthRequired($driverId, $error)';
}
