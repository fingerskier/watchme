import 'package:watchme_core/watchme_core.dart';

/// The NRC key name for each [RemoteKey] a VIERA has, without the `NRC_`
/// prefix and the `-ONOFF` suffix (a click sends `NRC_{name}-ONOFF`).
///
/// Keys absent here have no NRC equivalent and make the session return
/// `Unsupported`: search, backspace, the play/pause toggle, instant replay,
/// the AV input, and the discrete power keys (VIERA has only the `POWER`
/// toggle; gen1nya's `NRC_TV-ONOFF` as "power on" is unverified and is
/// the TV-input key here).
///
/// [RemoteKey.guide] and [RemoteKey.captions] depend on the market: see
/// [vieraKeyName].
const Map<RemoteKey, String> vieraKeyNames = {
  RemoteKey.up: 'UP',
  RemoteKey.down: 'DOWN',
  RemoteKey.left: 'LEFT',
  RemoteKey.right: 'RIGHT',
  RemoteKey.select: 'ENTER',
  RemoteKey.enter: 'ENTER',
  RemoteKey.back: 'RETURN',
  RemoteKey.home: 'HOME',
  RemoteKey.menu: 'MENU',
  RemoteKey.settings: 'MENU',
  RemoteKey.info: 'INFO',
  RemoteKey.guide: 'EPG',
  RemoteKey.exit: 'CANCEL',
  RemoteKey.captions: 'STTL',
  RemoteKey.red: 'RED',
  RemoteKey.green: 'GREEN',
  RemoteKey.yellow: 'YELLOW',
  RemoteKey.blue: 'BLUE',
  RemoteKey.volumeUp: 'VOLUP',
  RemoteKey.volumeDown: 'VOLDOWN',
  RemoteKey.mute: 'MUTE',
  RemoteKey.channelUp: 'CH_UP',
  RemoteKey.channelDown: 'CH_DOWN',
  RemoteKey.previousChannel: 'R_TUNE',
  RemoteKey.digit0: 'D0',
  RemoteKey.digit1: 'D1',
  RemoteKey.digit2: 'D2',
  RemoteKey.digit3: 'D3',
  RemoteKey.digit4: 'D4',
  RemoteKey.digit5: 'D5',
  RemoteKey.digit6: 'D6',
  RemoteKey.digit7: 'D7',
  RemoteKey.digit8: 'D8',
  RemoteKey.digit9: 'D9',
  RemoteKey.play: 'PLAY',
  RemoteKey.pause: 'PAUSE',
  RemoteKey.stop: 'STOP',
  RemoteKey.rewind: 'REW',
  RemoteKey.fastForward: 'FF',
  RemoteKey.next: 'SKIP_NEXT',
  RemoteKey.previous: 'SKIP_PREV',
  RemoteKey.record: 'REC',
  RemoteKey.power: 'POWER',
  RemoteKey.input: 'CHG_INPUT',
  RemoteKey.inputHdmi1: 'HDMI1',
  RemoteKey.inputHdmi2: 'HDMI2',
  RemoteKey.inputHdmi3: 'HDMI3',
  RemoteKey.inputHdmi4: 'HDMI4',
  RemoteKey.inputTuner: 'TV',
};

/// The NRC key name for [key] on a TV whose model number is [model], or
/// `null` when VIERA has no such key.
///
/// Two keys differ by market, and which one a set honours is unverified:
/// the programme guide is `EPG` on European and Asian sets (`TX-`, `TH-`)
/// and `GUIDE` on American ones (`TC-`, which Home Assistant sends), and
/// subtitles are `STTL`, or `CC` (closed captions) on `TC-` sets.
String? vieraKeyName(RemoteKey key, {String? model}) {
  final american = model?.toUpperCase().startsWith('TC-') ?? false;
  return switch (key) {
    RemoteKey.guide when american => 'GUIDE',
    RemoteKey.captions when american => 'CC',
    _ => vieraKeyNames[key],
  };
}

/// Keys that may be held with [KeyAction.down] and [KeyAction.up] when the
/// driver option allows it: `NRC_{name}-ON` holds and `NRC_{name}-OFF`
/// releases. Reported on a 2011 set only, and a missed release leaves the
/// key held, so the option is off by default. Never the power key.
const Set<RemoteKey> vieraHoldableKeys = {
  RemoteKey.up,
  RemoteKey.down,
  RemoteKey.left,
  RemoteKey.right,
  RemoteKey.volumeUp,
  RemoteKey.volumeDown,
};

/// The `X_KeyEvent` value for [name] and [action]: `NRC_{name}-ONOFF` for
/// a click, `-ON` to hold, `-OFF` to release.
String vieraKeyEvent(String name, KeyAction action) => switch (action) {
  KeyAction.click => 'NRC_$name-ONOFF',
  KeyAction.down => 'NRC_$name-ON',
  KeyAction.up => 'NRC_$name-OFF',
};

/// The NRC key that selects an input given to `SelectInput`, or `null`.
///
/// Accepts `hdmi1` to `hdmi4` and `tv` / `tuner` (case-insensitive). There
/// is no AV key.
String? vieraInputKey(String inputId) => switch (inputId.trim().toLowerCase()) {
  'hdmi1' => 'HDMI1',
  'hdmi2' => 'HDMI2',
  'hdmi3' => 'HDMI3',
  'hdmi4' => 'HDMI4',
  'tv' || 'tuner' => 'TV',
  _ => null,
};

/// The input id watchme reports for an input key name (`HDMI2` gives
/// `hdmi2`, `TV` gives `tv`).
String vieraInputIdForKey(String keyName) => keyName.toLowerCase();

/// The input id watchme reports for a Pro AV control input code: the key
/// path's id for the inputs a key selects (`H2` gives `hdmi2`, `TV` gives
/// `tv`), so that one input has one id whether it was selected by key or by
/// code, or read back; any other code as it is (`SelectInput` takes it).
String vieraInputIdForPac(String code) => switch (code.trim().toUpperCase()) {
  'H1' => 'hdmi1',
  'H2' => 'hdmi2',
  'H3' => 'hdmi3',
  'H4' => 'hdmi4',
  'TV' => 'tv',
  _ => code.trim(),
};
