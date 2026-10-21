import 'package:watchme_core/watchme_core.dart';

/// How a control shows on the Remote screen.
enum ControlGate {
  /// Visible and usable.
  enabled,

  /// Visible but greyed out.
  disabled,

  /// Not shown.
  hidden;

  /// Whether the control is shown at all.
  bool get visible => this != hidden;
}

/// Decides how a control backed by [capability] shows for [device], from
/// its merged capability support.
///
/// Core controls (d-pad, system keys, volume, power, media) stay visible but
/// disabled while support is unknown, so the layout does not jump while the
/// engine probes or before pairing. [optional] controls (channels, text,
/// apps) appear only once the device says they work.
ControlGate gateFor(
  DeviceView device,
  Capability capability, {
  bool optional = false,
}) => switch (device.supportOf(capability).level) {
  Support.yes || Support.partial => ControlGate.enabled,
  Support.no => ControlGate.hidden,
  Support.unknown => optional ? ControlGate.hidden : ControlGate.disabled,
};
