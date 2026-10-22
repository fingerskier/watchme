import 'package:meta/meta.dart';

import 'util/equality.dart';
import 'util/json.dart';

/// The things a user can ask a TV to do, as used throughout the research.
enum Capability {
  /// Turn the TV off (discrete off, or a toggle under the power rules).
  powerOff,

  /// Turn the TV on (discrete on, Wake-on-LAN, CEC, ...).
  powerOn,

  /// Read whether the TV is on, in standby or off.
  powerState,

  /// Change the volume (absolute or relative; see [CapFlag.relativeOnly]).
  volume,

  /// Mute and unmute.
  mute,

  /// Up, down, left, right and select.
  dpadNavigation,

  /// Home, back, menu, info, settings and similar system keys.
  systemKeys,

  /// Type text into the TV's on-screen keyboard.
  textInput,

  /// List installed apps (and, on some TVs, inputs).
  appList,

  /// Launch an app, optionally with a deep link.
  appLaunch,

  /// Switch the TV input (HDMI, tuner, ...).
  inputSwitch,

  /// Change the broadcast channel.
  channel,

  /// Play, pause, seek, skip.
  mediaTransport,

  /// Read what is currently playing.
  nowPlaying,

  /// Move an on-screen pointer.
  pointer,

  /// Show a notification on the TV.
  notificationToast,

  /// Capture the screen.
  screenshot,

  /// Play a media URL on the TV.
  castMediaUrl,
}

/// How well a capability is supported.
///
/// The order matters: earlier values are better, which the router uses when
/// ranking sessions.
enum Support {
  /// Works.
  yes,

  /// Works with limits described by flags and the note.
  partial,

  /// Does not work.
  no,

  /// Not known yet (for example before a probe).
  unknown,
}

/// Qualifiers on a [CapabilitySupport] that the UI and the router both need.
enum CapFlag {
  /// Volume up/down only; no absolute level (Samsung WS, Roku, Android TV).
  relativeOnly,

  /// No readback (browser no-cors, IR).
  writeOnly,

  /// A KEY_POWER-style toggle: the router needs agreed state first.
  toggleOnly,

  /// Power-on works only while the TV's network interface stays up.
  needsNetworkStandby,

  /// Text works only while the TV's on-screen keyboard is active.
  needsKeyboardOpen,

  /// Affects only media we started (Cast, DLNA).
  sessionScoped,

  /// Launching a receiver interrupts viewing.
  takesOverScreen,

  /// Needs internet: a vendor cloud, a cloud catalog or a receiver app.
  cloud,

  /// Reverse-engineered; may break on a firmware update.
  undocumented,

  /// Needs a user-visible setting first (hidden menu, developer mode,
  /// "Control by mobile apps").
  userSetupRequired,
}

/// One capability, how well it is supported, and why.
@immutable
final class CapabilitySupport {
  /// Creates a support entry.
  const CapabilitySupport(
    this.capability,
    this.level, {
    this.flags = const {},
    this.note,
  });

  /// A [Support.yes] entry.
  const CapabilitySupport.yes(
    this.capability, {
    this.flags = const {},
    this.note,
  }) : level = Support.yes;

  /// A [Support.partial] entry.
  const CapabilitySupport.partial(
    this.capability, {
    this.flags = const {},
    this.note,
  }) : level = Support.partial;

  /// A [Support.no] entry.
  const CapabilitySupport.no(this.capability, {this.note})
    : level = Support.no,
      flags = const {};

  /// A [Support.unknown] entry.
  const CapabilitySupport.unknown(this.capability, {this.note})
    : level = Support.unknown,
      flags = const {};

  /// Decodes the form written by [toJson].
  factory CapabilitySupport.fromJson(JsonMap json) => CapabilitySupport(
    reqEnum(json, 'capability', Capability.values),
    reqEnum(json, 'level', Support.values),
    flags: enumSet(json, 'flags', CapFlag.values),
    note: opt<String>(json, 'note'),
  );

  /// The capability described.
  final Capability capability;

  /// How well it is supported.
  final Support level;

  /// Qualifiers.
  final Set<CapFlag> flags;

  /// Human text, e.g. "deep links only since the Aug 2026 Play Store change".
  final String? note;

  /// Whether the capability can be used at all ([Support.yes] or
  /// [Support.partial]).
  bool get usable => level == Support.yes || level == Support.partial;

  /// Whether [flag] is set.
  bool has(CapFlag flag) => flags.contains(flag);

  /// Returns a copy with the given fields replaced.
  CapabilitySupport copyWith({
    Support? level,
    Set<CapFlag>? flags,
    String? note,
  }) => CapabilitySupport(
    capability,
    level ?? this.level,
    flags: flags ?? this.flags,
    note: note ?? this.note,
  );

  /// JSON form.
  JsonMap toJson() => {
    'capability': capability.name,
    'level': level.name,
    if (flags.isNotEmpty) 'flags': enumNames(flags),
    if (note != null) 'note': note,
  };

  @override
  bool operator ==(Object other) =>
      other is CapabilitySupport &&
      other.capability == capability &&
      other.level == level &&
      setEquals(other.flags, flags) &&
      other.note == note;

  @override
  int get hashCode => Object.hash(capability, level, setHash(flags), note);

  @override
  String toString() {
    final f = flags.isEmpty ? '' : ' ${enumNames(flags)}';
    return 'CapabilitySupport(${capability.name}: ${level.name}$f)';
  }
}

/// Lookup helpers over a list of [CapabilitySupport] entries.
extension CapabilityListX on Iterable<CapabilitySupport> {
  /// The entry for [capability], or a [Support.unknown] entry when absent.
  CapabilitySupport supportFor(Capability capability) {
    for (final c in this) {
      if (c.capability == capability) return c;
    }
    return CapabilitySupport.unknown(capability);
  }

  /// Indexes the entries by capability; later entries win.
  Map<Capability, CapabilitySupport> toCapabilityMap() => {
    for (final c in this) c.capability: c,
  };
}
