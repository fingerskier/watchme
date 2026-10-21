import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';

/// Every key name Roku's ECP accepts in `keypress`, `keydown` and `keyup`
/// (besides `Lit_` text), as documented, plus the undocumented `PowerOn`
/// and `Power` that every maintained library uses.
const Set<String> rokuEcpKeyNames = {
  'Home', 'Rev', 'Fwd', 'Play', 'Select', 'Left', 'Right', 'Down', 'Up', //
  'Back', 'InstantReplay', 'Info', 'Backspace', 'Search', 'Enter',
  'FindRemote',
  'VolumeDown', 'VolumeMute', 'VolumeUp',
  'PowerOff', 'PowerOn', 'Power',
  'ChannelUp', 'ChannelDown',
  'InputTuner', 'InputHDMI1', 'InputHDMI2', 'InputHDMI3', 'InputHDMI4',
  'InputAV1',
};

/// The ECP key name for each [RemoteKey] Roku has. Keys absent here
/// (guide, exit, settings, captions, colour keys, digits, stop, next,
/// previous, record, previousChannel, the input picker) make the session
/// return `Unsupported`.
///
/// Roku remotes have a single play/pause key, so only
/// [RemoteKey.playPause] presses `Play` (a toggle). [RemoteKey.play] and
/// [RemoteKey.pause] are not here: the session treats a press of either as
/// `Media(MediaAction.play)` / `Media(MediaAction.pause)`, which read the
/// player first so a "pause" never resumes, and refuses holding them.
/// [RemoteKey.menu] maps to `Info`, the options (`*`) key, as the nearest
/// equivalent. `FindRemote` has no [RemoteKey].
const Map<RemoteKey, String> rokuKeyNames = {
  RemoteKey.up: 'Up',
  RemoteKey.down: 'Down',
  RemoteKey.left: 'Left',
  RemoteKey.right: 'Right',
  RemoteKey.select: 'Select',
  RemoteKey.back: 'Back',
  RemoteKey.home: 'Home',
  RemoteKey.menu: 'Info',
  RemoteKey.info: 'Info',
  RemoteKey.search: 'Search',
  RemoteKey.backspace: 'Backspace',
  RemoteKey.enter: 'Enter',
  RemoteKey.volumeUp: 'VolumeUp',
  RemoteKey.volumeDown: 'VolumeDown',
  RemoteKey.mute: 'VolumeMute',
  RemoteKey.channelUp: 'ChannelUp',
  RemoteKey.channelDown: 'ChannelDown',
  RemoteKey.playPause: 'Play',
  RemoteKey.rewind: 'Rev',
  RemoteKey.fastForward: 'Fwd',
  RemoteKey.instantReplay: 'InstantReplay',
  RemoteKey.power: 'Power',
  RemoteKey.powerOn: 'PowerOn',
  RemoteKey.powerOff: 'PowerOff',
  RemoteKey.inputHdmi1: 'InputHDMI1',
  RemoteKey.inputHdmi2: 'InputHDMI2',
  RemoteKey.inputHdmi3: 'InputHDMI3',
  RemoteKey.inputHdmi4: 'InputHDMI4',
  RemoteKey.inputAv1: 'InputAV1',
  RemoteKey.inputTuner: 'InputTuner',
};

/// The ECP path verb for [action]: `keypress`, `keydown` or `keyup`.
String rokuKeyVerb(KeyAction action) => switch (action) {
  KeyAction.click => 'keypress',
  KeyAction.down => 'keydown',
  KeyAction.up => 'keyup',
};

/// The `Lit_` key name that types the Unicode code point [rune]: `Lit_`
/// followed by its UTF-8 bytes percent-encoded, e.g. `Lit_a`, `Lit_%20`,
/// `Lit_%E2%82%AC` for the euro sign.
///
/// Only RFC 3986 unreserved characters stay literal, so `+`, `/`, `?`, `%`
/// and quotes can never be misread in the URL path.
String rokuLiteralKey(int rune) {
  final out = StringBuffer('Lit_');
  for (final b in utf8.encode(String.fromCharCode(rune))) {
    if (_isUnreserved(b)) {
      out.writeCharCode(b);
    } else {
      out
        ..write('%')
        ..write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return out.toString();
}

/// The `Lit_` key names that type [text], one per Unicode code point.
List<String> rokuLiteralKeys(String text) => [
  for (final rune in text.runes) rokuLiteralKey(rune),
];

bool _isUnreserved(int b) =>
    (b >= 0x30 && b <= 0x39) || // 0-9
    (b >= 0x41 && b <= 0x5a) || // A-Z
    (b >= 0x61 && b <= 0x7a) || // a-z
    b == 0x2d || // -
    b == 0x2e || // .
    b == 0x5f || // _
    b == 0x7e; // ~

/// Maps an input id given to `SelectInput` to the ECP key that selects it,
/// or `null` when the id is not a known key-selectable input.
///
/// Accepts the short ids watchme reports in `DeviceState.input` (`hdmi1` to
/// `hdmi4`, `av1`, `tuner`, and [rokuAppsInputId] for Roku's own home
/// screen) and the Roku input app ids from `query/apps`
/// (`tvinput.hdmi1`, `tvinput.dtv`, `tvinput.cvbs`). Case-insensitive.
String? rokuInputKey(String inputId) => switch (inputId.trim().toLowerCase()) {
  'hdmi1' || 'tvinput.hdmi1' => 'InputHDMI1',
  'hdmi2' || 'tvinput.hdmi2' => 'InputHDMI2',
  'hdmi3' || 'tvinput.hdmi3' => 'InputHDMI3',
  'hdmi4' || 'tvinput.hdmi4' => 'InputHDMI4',
  'av1' || 'av' || 'tvinput.cvbs' || 'tvinput.av1' => 'InputAV1',
  'tuner' || 'dtv' || 'tvinput.dtv' => 'InputTuner',
  _ => null,
};

/// The `DeviceState.input` id watchme reports on a Roku TV when no
/// external input is in front (Roku's home screen or an app).
/// `SelectInput(rokuAppsInputId)` presses Home.
const String rokuAppsInputId = 'roku';

/// The short input id for a Roku input app id (`tvinput.hdmi2` gives
/// `hdmi2`, `tvinput.dtv` gives `tuner`, `tvinput.cvbs` gives `av1`);
/// other `tvinput.*` ids are returned unchanged.
String rokuInputIdForApp(String appId) => switch (appId.trim().toLowerCase()) {
  'tvinput.dtv' => 'tuner',
  'tvinput.cvbs' || 'tvinput.av1' => 'av1',
  final id when id.startsWith('tvinput.hdmi') => id.substring(8),
  _ => appId,
};
