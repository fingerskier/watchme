import 'package:meta/meta.dart';

import 'capabilities.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// Protocol-neutral remote-control keys.
///
/// Each driver maps these to its own codes (Roku key names, Android keycodes,
/// Fire TV actions, CEC UI codes, ...). A key a driver cannot map yields
/// `Unsupported`; it never fails silently.
enum RemoteKey {
  /// D-pad up.
  up(Capability.dpadNavigation),

  /// D-pad down.
  down(Capability.dpadNavigation),

  /// D-pad left.
  left(Capability.dpadNavigation),

  /// D-pad right.
  right(Capability.dpadNavigation),

  /// D-pad centre / OK.
  select(Capability.dpadNavigation),

  /// Back.
  back(Capability.systemKeys),

  /// Home.
  home(Capability.systemKeys),

  /// Menu (Fire TV, Android TV) or the nearest equivalent.
  menu(Capability.systemKeys),

  /// Info / options (Roku `Info`, the `*` button).
  info(Capability.systemKeys),

  /// Programme guide.
  guide(Capability.systemKeys),

  /// Exit.
  exit(Capability.systemKeys),

  /// Settings.
  settings(Capability.systemKeys),

  /// Search.
  search(Capability.systemKeys),

  /// Subtitles / closed captions.
  captions(Capability.systemKeys),

  /// Colour key red.
  red(Capability.systemKeys),

  /// Colour key green.
  green(Capability.systemKeys),

  /// Colour key yellow.
  yellow(Capability.systemKeys),

  /// Colour key blue.
  blue(Capability.systemKeys),

  /// On-screen keyboard backspace.
  backspace(Capability.textInput),

  /// On-screen keyboard enter / submit (distinct from [select]).
  enter(Capability.textInput),

  /// Volume up one step.
  volumeUp(Capability.volume),

  /// Volume down one step.
  volumeDown(Capability.volume),

  /// Mute toggle.
  mute(Capability.mute),

  /// Channel up.
  channelUp(Capability.channel),

  /// Channel down.
  channelDown(Capability.channel),

  /// Previous channel.
  previousChannel(Capability.channel),

  /// Digit 0.
  digit0(Capability.channel),

  /// Digit 1.
  digit1(Capability.channel),

  /// Digit 2.
  digit2(Capability.channel),

  /// Digit 3.
  digit3(Capability.channel),

  /// Digit 4.
  digit4(Capability.channel),

  /// Digit 5.
  digit5(Capability.channel),

  /// Digit 6.
  digit6(Capability.channel),

  /// Digit 7.
  digit7(Capability.channel),

  /// Digit 8.
  digit8(Capability.channel),

  /// Digit 9.
  digit9(Capability.channel),

  /// Play.
  play(Capability.mediaTransport),

  /// Pause.
  pause(Capability.mediaTransport),

  /// Play/pause toggle.
  playPause(Capability.mediaTransport),

  /// Stop.
  stop(Capability.mediaTransport),

  /// Rewind.
  rewind(Capability.mediaTransport),

  /// Fast forward.
  fastForward(Capability.mediaTransport),

  /// Next track / chapter.
  next(Capability.mediaTransport),

  /// Previous track / chapter.
  previous(Capability.mediaTransport),

  /// Record.
  record(Capability.mediaTransport),

  /// Jump back a few seconds (Roku `InstantReplay`).
  instantReplay(Capability.mediaTransport),

  /// Power toggle.
  ///
  /// `PressKey(RemoteKey.power)` sent to the engine is a power-toggle
  /// intent, not a raw key press: the engine's power orchestrator handles it
  /// under the power rules (see [PressKey]). Drivers still map the key,
  /// because the orchestrator sends it as its toggle route. Prefer
  /// [powerOn] / [powerOff], or `SetPower`.
  power(Capability.powerOff),

  /// Discrete power on.
  powerOn(Capability.powerOn),

  /// Discrete power off.
  powerOff(Capability.powerOff),

  /// Cycle or open the input picker.
  input(Capability.inputSwitch),

  /// HDMI 1.
  inputHdmi1(Capability.inputSwitch),

  /// HDMI 2.
  inputHdmi2(Capability.inputSwitch),

  /// HDMI 3.
  inputHdmi3(Capability.inputSwitch),

  /// HDMI 4.
  inputHdmi4(Capability.inputSwitch),

  /// Composite / AV 1.
  inputAv1(Capability.inputSwitch),

  /// Built-in tuner.
  inputTuner(Capability.inputSwitch);

  const RemoteKey(this.capability);

  /// The capability a press of this key exercises.
  final Capability capability;

  /// The digit keys in order, `digits[3] == RemoteKey.digit3`.
  static const List<RemoteKey> digits = [
    digit0, digit1, digit2, digit3, digit4, //
    digit5, digit6, digit7, digit8, digit9,
  ];
}

/// What happens to a key.
enum KeyAction {
  /// Press and release.
  click,

  /// Press and hold (for long-press and repeat where supported).
  down,

  /// Release a held key.
  up,
}

/// Media transport actions for [Media].
enum MediaAction {
  /// Start or resume playback.
  play,

  /// Pause.
  pause,

  /// Toggle between play and pause.
  playPause,

  /// Stop.
  stop,

  /// Rewind (scan backwards).
  rewind,

  /// Fast forward (scan forwards).
  fastForward,

  /// Next item.
  next,

  /// Previous item.
  previous,

  /// Seek to [Media.seekTo].
  seek,

  /// Jump back a few seconds.
  instantReplay,
}

/// Kinds of launchable entries in an app list.
enum AppKind {
  /// An installed app or channel.
  app,

  /// A TV input exposed as an app (Roku `tvin`, e.g. `tvinput.hdmi1`).
  input,

  /// Anything else (menus, system screens).
  other,
}

/// An installed app or launchable entry reported by a TV.
@immutable
final class AppInfo {
  /// Creates an app entry.
  const AppInfo({
    required this.id,
    required this.name,
    this.kind = AppKind.app,
    this.version,
    this.icon,
  });

  /// Decodes the form written by [toJson].
  factory AppInfo.fromJson(JsonMap json) => AppInfo(
    id: req<String>(json, 'id'),
    name: req<String>(json, 'name'),
    kind: optEnum(json, 'kind', AppKind.values) ?? AppKind.app,
    version: opt<String>(json, 'version'),
    icon: optUri(json, 'icon'),
  );

  /// Driver-specific id accepted by [LaunchApp].
  final String id;

  /// Display name.
  final String name;

  /// Entry kind.
  final AppKind kind;

  /// App version, if reported.
  final String? version;

  /// Icon location, if the device exposes one.
  final Uri? icon;

  /// JSON form.
  JsonMap toJson() => {
    'id': id,
    'name': name,
    'kind': kind.name,
    if (version != null) 'version': version,
    if (icon != null) 'icon': icon.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is AppInfo &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.version == version &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(id, name, kind, version, icon);

  @override
  String toString() => 'AppInfo($id, $name)';
}

/// Something the user asks a TV to do.
///
/// Commands are immutable values with a JSON form (`type` discriminator plus
/// fields) shared by the hub API and driver hosts.
@immutable
sealed class Command {
  const Command();

  /// Decodes the form written by [toJson].
  ///
  /// Throws [FormatException] for an unknown `type` or malformed fields.
  factory Command.fromJson(JsonMap json) => switch (typeOf(json)) {
    'pressKey' => PressKey(
      reqEnum(json, 'key', RemoteKey.values),
      optEnum(json, 'action', KeyAction.values) ?? KeyAction.click,
    ),
    'setPower' => SetPower(
      req<bool>(json, 'on'),
      userConfirmed: opt<bool>(json, 'userConfirmed') ?? false,
    ),
    'setVolume' => SetVolume(reqInt(json, 'level')),
    'stepVolume' => StepVolume(reqInt(json, 'steps')),
    'setMute' => SetMute(opt<bool>(json, 'muted')),
    'launchApp' => LaunchApp(
      req<String>(json, 'appId'),
      deepLink: optUri(json, 'deepLink'),
      params: strMap(json, 'params'),
    ),
    'listApps' => const ListApps(),
    'selectInput' => SelectInput(req<String>(json, 'inputId')),
    'tuneChannel' => TuneChannel(req<String>(json, 'channel')),
    'typeText' => TypeText(
      req<String>(json, 'text'),
      replace: opt<bool>(json, 'replace') ?? false,
    ),
    'media' => Media(
      reqEnum(json, 'action', MediaAction.values),
      seekTo: optMs(json, 'seekToMs'),
    ),
    'movePointer' => MovePointer(
      reqInt(json, 'dx'),
      reqInt(json, 'dy'),
      click: opt<bool>(json, 'click') ?? false,
    ),
    'showToast' => ShowToast(req<String>(json, 'message')),
    'castUrl' => CastUrl(
      reqUri(json, 'url'),
      mimeType: opt<String>(json, 'mimeType'),
      title: opt<String>(json, 'title'),
    ),
    'takeScreenshot' => const TakeScreenshot(),
    final other => throw FormatException('Unknown command type: $other'),
  };

  /// The JSON `type` discriminator.
  String get type;

  /// The capability this command exercises; the router ranks sessions by it.
  Capability get capability;

  /// JSON form: `{"type": ..., ...fields}`.
  JsonMap toJson() => {'type': type, ..._fields()};

  JsonMap _fields();

  @override
  String toString() => '$runtimeType(${_fields()})';
}

/// Press, hold or release a remote key.
///
/// The engine treats `PressKey(RemoteKey.power)` as a power-toggle intent
/// and hands it to the power orchestrator instead of routing it as a key:
///
/// * When the evidence settles the current power state (overview section
///   2.8), it executes `SetPower(!current)`: a discrete route first, a
///   toggle only under the two-source rule. The evidence settles it when
///   two independent sources agree, or when the only source is the
///   device's own report (`Confidence.reported`, never an inferred state)
///   from a driver with full `powerState` support (not a player reporting
///   its own power) and the action it implies has a discrete route (an off route that is
///   not toggle-only; an on route that is not, or Wake-on-LAN). A discrete
///   on or off is idempotent, so a single source is enough for it, never
///   for a toggle.
/// * Otherwise, and within the quiet period after the last power command,
///   it returns `Unsupported(Unsupported.needsConfirmation)`, and the UI
///   asks the user (see [SetPower.userConfirmed]).
/// * [KeyAction.down] and [KeyAction.up] are refused with `Unsupported`:
///   holding a toggle makes no sense.
///
/// Drivers receive the power key only from the orchestrator, as its toggle.
final class PressKey extends Command {
  /// Creates a key command; [action] defaults to a click.
  const PressKey(this.key, [this.action = KeyAction.click]);

  /// The key.
  final RemoteKey key;

  /// Click, down or up.
  final KeyAction action;

  @override
  String get type => 'pressKey';

  @override
  Capability get capability => key.capability;

  @override
  JsonMap _fields() => {'key': key.name, 'action': action.name};

  @override
  bool operator ==(Object other) =>
      other is PressKey && other.key == key && other.action == action;

  @override
  int get hashCode => Object.hash(type, key, action);
}

/// Discrete power on or off. The engine's power orchestrator decides how
/// (overview section 2.8): a discrete route first, then Wake-on-LAN for
/// "on", and a power toggle only when two independent sources agree on the
/// current state. One source is never enough for a toggle, not even the
/// device's own report (which is enough for the power key to pick a
/// discrete command, see [PressKey]). When only a toggle is left and the
/// sources do not agree, the result is
/// `Unsupported(Unsupported.needsConfirmation)` and the UI asks the user.
final class SetPower extends Command {
  /// Creates a power command.
  const SetPower(this.on, {this.userConfirmed = false});

  /// `true` to turn on, `false` to turn off.
  final bool on;

  /// The user has just looked at the TV and says it is in the opposite
  /// state: off for `SetPower(true, ...)`, on for `SetPower(false, ...)`.
  ///
  /// The UI sets it only from the user's explicit answer to "Is the TV on
  /// right now?", after a `needsConfirmation` result; never on a guess. The
  /// power orchestrator counts it as the agreement the two-source rule asks
  /// for, so it may send a toggle. It still prefers a discrete route, still
  /// serialises power commands per device, and still sends no toggle within
  /// the quiet period after the last power command watchme delivered.
  ///
  /// Omitted from JSON when `false`.
  final bool userConfirmed;

  @override
  String get type => 'setPower';

  @override
  Capability get capability => on ? Capability.powerOn : Capability.powerOff;

  @override
  JsonMap _fields() => {'on': on, if (userConfirmed) 'userConfirmed': true};

  @override
  bool operator ==(Object other) =>
      other is SetPower &&
      other.on == on &&
      other.userConfirmed == userConfirmed;

  @override
  int get hashCode => Object.hash(type, on, userConfirmed);
}

/// Set the absolute volume, 0..100.
final class SetVolume extends Command {
  /// Creates an absolute volume command.
  const SetVolume(this.level) : assert(level >= 0 && level <= 100);

  /// Target level, 0..100.
  final int level;

  @override
  String get type => 'setVolume';

  @override
  Capability get capability => Capability.volume;

  @override
  JsonMap _fields() => {'level': level};

  @override
  bool operator ==(Object other) => other is SetVolume && other.level == level;

  @override
  int get hashCode => Object.hash(type, level);
}

/// Step the volume up (positive) or down (negative) by [steps].
final class StepVolume extends Command {
  /// Creates a relative volume command.
  const StepVolume(this.steps);

  /// Number of steps; the sign gives the direction.
  final int steps;

  @override
  String get type => 'stepVolume';

  @override
  Capability get capability => Capability.volume;

  @override
  JsonMap _fields() => {'steps': steps};

  @override
  bool operator ==(Object other) => other is StepVolume && other.steps == steps;

  @override
  int get hashCode => Object.hash(type, steps);
}

/// Mute, unmute or toggle.
final class SetMute extends Command {
  /// Creates a mute command; `null` toggles.
  const SetMute(this.muted);

  /// `true` mutes, `false` unmutes, `null` toggles.
  final bool? muted;

  @override
  String get type => 'setMute';

  @override
  Capability get capability => Capability.mute;

  @override
  JsonMap _fields() => {'muted': muted};

  @override
  bool operator ==(Object other) => other is SetMute && other.muted == muted;

  @override
  int get hashCode => Object.hash(type, muted);
}

/// Launch an app, optionally deep-linking into content.
final class LaunchApp extends Command {
  /// Creates a launch command.
  const LaunchApp(this.appId, {this.deepLink, this.params = const {}});

  /// Driver-specific app id, as reported in [AppInfo.id].
  final String appId;

  /// A deep link understood by the target app, if any.
  final Uri? deepLink;

  /// Protocol launch parameters, e.g. Roku `contentId` and `mediaType`.
  final Map<String, String> params;

  @override
  String get type => 'launchApp';

  @override
  Capability get capability => Capability.appLaunch;

  @override
  JsonMap _fields() => {
    'appId': appId,
    if (deepLink != null) 'deepLink': deepLink.toString(),
    if (params.isNotEmpty) 'params': params,
  };

  @override
  bool operator ==(Object other) =>
      other is LaunchApp &&
      other.appId == appId &&
      other.deepLink == deepLink &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(type, appId, deepLink, mapHash(params));
}

/// Ask for the installed apps. A successful result is `Confirmed` with an
/// `AppListPayload`.
final class ListApps extends Command {
  /// Creates an app-list query.
  const ListApps();

  @override
  String get type => 'listApps';

  @override
  Capability get capability => Capability.appList;

  @override
  JsonMap _fields() => const {};

  @override
  bool operator ==(Object other) => other is ListApps;

  @override
  int get hashCode => type.hashCode;
}

/// Switch to an input by driver-specific id (e.g. `hdmi1`, `tvinput.hdmi2`).
final class SelectInput extends Command {
  /// Creates an input command.
  const SelectInput(this.inputId);

  /// Driver-specific input id.
  final String inputId;

  @override
  String get type => 'selectInput';

  @override
  Capability get capability => Capability.inputSwitch;

  @override
  JsonMap _fields() => {'inputId': inputId};

  @override
  bool operator ==(Object other) =>
      other is SelectInput && other.inputId == inputId;

  @override
  int get hashCode => Object.hash(type, inputId);
}

/// Tune to a channel number or id (e.g. `7.1`).
final class TuneChannel extends Command {
  /// Creates a tune command.
  const TuneChannel(this.channel);

  /// Channel number or id.
  final String channel;

  @override
  String get type => 'tuneChannel';

  @override
  Capability get capability => Capability.channel;

  @override
  JsonMap _fields() => {'channel': channel};

  @override
  bool operator ==(Object other) =>
      other is TuneChannel && other.channel == channel;

  @override
  int get hashCode => Object.hash(type, channel);
}

/// Type text into the active on-screen keyboard.
final class TypeText extends Command {
  /// Creates a text command.
  const TypeText(this.text, {this.replace = false});

  /// The text to type.
  final String text;

  /// Replace the field's content instead of appending, where supported.
  final bool replace;

  @override
  String get type => 'typeText';

  @override
  Capability get capability => Capability.textInput;

  @override
  JsonMap _fields() => {'text': text, 'replace': replace};

  @override
  bool operator ==(Object other) =>
      other is TypeText && other.text == text && other.replace == replace;

  @override
  int get hashCode => Object.hash(type, text, replace);
}

/// A media transport action.
final class Media extends Command {
  /// Creates a media command; [seekTo] is used with [MediaAction.seek].
  const Media(this.action, {this.seekTo});

  /// The action.
  final MediaAction action;

  /// Absolute position for [MediaAction.seek].
  final Duration? seekTo;

  @override
  String get type => 'media';

  @override
  Capability get capability => Capability.mediaTransport;

  @override
  JsonMap _fields() => {
    'action': action.name,
    if (seekTo != null) 'seekToMs': seekTo!.inMilliseconds,
  };

  @override
  bool operator ==(Object other) =>
      other is Media && other.action == action && other.seekTo == seekTo;

  @override
  int get hashCode => Object.hash(type, action, seekTo);
}

/// Move the on-screen pointer by a relative offset.
final class MovePointer extends Command {
  /// Creates a pointer command.
  const MovePointer(this.dx, this.dy, {this.click = false});

  /// Horizontal offset in device pointer units.
  final int dx;

  /// Vertical offset in device pointer units.
  final int dy;

  /// Click after moving.
  final bool click;

  @override
  String get type => 'movePointer';

  @override
  Capability get capability => Capability.pointer;

  @override
  JsonMap _fields() => {'dx': dx, 'dy': dy, 'click': click};

  @override
  bool operator ==(Object other) =>
      other is MovePointer &&
      other.dx == dx &&
      other.dy == dy &&
      other.click == click;

  @override
  int get hashCode => Object.hash(type, dx, dy, click);
}

/// Show a notification on the TV.
final class ShowToast extends Command {
  /// Creates a toast command.
  const ShowToast(this.message);

  /// The text to show.
  final String message;

  @override
  String get type => 'showToast';

  @override
  Capability get capability => Capability.notificationToast;

  @override
  JsonMap _fields() => {'message': message};

  @override
  bool operator ==(Object other) =>
      other is ShowToast && other.message == message;

  @override
  int get hashCode => Object.hash(type, message);
}

/// Play a media URL on the TV.
final class CastUrl extends Command {
  /// Creates a cast command.
  const CastUrl(this.url, {this.mimeType, this.title});

  /// Media location reachable from the TV.
  final Uri url;

  /// MIME type, if known.
  final String? mimeType;

  /// Title to display, if supported.
  final String? title;

  @override
  String get type => 'castUrl';

  @override
  Capability get capability => Capability.castMediaUrl;

  @override
  JsonMap _fields() => {
    'url': url.toString(),
    if (mimeType != null) 'mimeType': mimeType,
    if (title != null) 'title': title,
  };

  @override
  bool operator ==(Object other) =>
      other is CastUrl &&
      other.url == url &&
      other.mimeType == mimeType &&
      other.title == title;

  @override
  int get hashCode => Object.hash(type, url, mimeType, title);
}

/// Capture the screen. A successful result is `Confirmed` with a
/// `ScreenshotPayload`.
final class TakeScreenshot extends Command {
  /// Creates a screenshot command.
  const TakeScreenshot();

  @override
  String get type => 'takeScreenshot';

  @override
  Capability get capability => Capability.screenshot;

  @override
  JsonMap _fields() => const {};

  @override
  bool operator ==(Object other) => other is TakeScreenshot;

  @override
  int get hashCode => type.hashCode;
}
