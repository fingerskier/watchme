import 'package:watchme_core/watchme_core.dart';

/// Human text for a power mode.
String powerModeLabel(PowerMode mode) => switch (mode) {
  PowerMode.on => 'On',
  PowerMode.screenOff => 'Screen off',
  PowerMode.artMode => 'Art mode',
  PowerMode.standby => 'Standby',
  PowerMode.off => 'Off',
  PowerMode.unknown => 'Power unknown',
};

/// Human text for a session's connection state.
String connectionLabel(ConnectionState state) => switch (state) {
  ConnectionState.disconnected => 'Not connected',
  ConnectionState.connecting => 'Connecting…',
  ConnectionState.connected => 'Connected',
  ConnectionState.failed => 'Connection failed',
};

/// A short headline for an error code, used above the error's own message.
String errorCodeLabel(WatchmeErrorCode code) => switch (code) {
  WatchmeErrorCode.unreachable => "Couldn't reach the TV",
  WatchmeErrorCode.destinationRefused => 'Not a local network address',
  WatchmeErrorCode.timeout => 'The TV did not answer in time',
  WatchmeErrorCode.partiallyDelivered =>
    'Only part of the command reached the TV',
  WatchmeErrorCode.unauthorized => 'The TV did not accept watchme',
  WatchmeErrorCode.reauthRequired => 'Pair again',
  WatchmeErrorCode.rejected => 'The TV refused',
  WatchmeErrorCode.protocol => 'Unexpected reply from the TV',
  WatchmeErrorCode.unsupported => 'Not supported',
  WatchmeErrorCode.cancelled => 'Cancelled',
  WatchmeErrorCode.internal => 'Something went wrong in watchme',
};

/// "Manufacturer Model", or null when neither is known.
String? makeAndModel(DeviceView device) {
  final parts = [
    ?device.manufacturer,
    ?device.model,
  ].where((p) => p.trim().isNotEmpty);
  return parts.isEmpty ? null : parts.join(' ');
}

/// The single status line a device shows in the list.
String deviceStatusLabel(DeviceView device) {
  if (device.connected) return 'Connected';
  if (device.needsPairing) return 'Needs pairing';
  final states = {for (final d in device.drivers) d.connection};
  if (states.contains(ConnectionState.connecting)) return 'Connecting…';
  if (states.contains(ConnectionState.failed)) return 'Connection failed';
  return 'Not connected';
}
