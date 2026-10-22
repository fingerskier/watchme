import 'package:watchme_core/watchme_core.dart';

// Remote-key codes (`RCKY`) from the US 2011, 2012 and 2014 manual tables
// and the 4T-B manual; the arrow and transport order is cross-checked with
// field explorations. Facts only.

/// The POWER key: a toggle that also wakes a TV in network standby.
const int sharpPowerKey = 12;

/// The NETFLIX key: the 2014 manual says it turns a TV in standby on.
const int sharpNetflixKey = 59;

/// Keys that can wake the TV from standby. The session sends them only for
/// a command the user sent while the TV reads as on, never from a probe,
/// a refresh or a connect.
const Set<int> sharpWakeKeys = {sharpPowerKey, sharpNetflixKey};

/// The `RCKY` code for each [RemoteKey] that has one. A profile without
/// the code (see `SharpProfile.rcky`) makes the key `Unsupported`.
///
/// Mapped elsewhere, not here: [RemoteKey.powerOn] and [RemoteKey.powerOff]
/// (`POWR1`/`POWR0`), [RemoteKey.mute] (the `MUTE0` toggle, which every
/// profile has), [RemoteKey.channelUp]/[RemoteKey.channelDown] (`CHUP`/
/// `CHDW` where the profile has them), and the input keys (`SelectInput`).
/// No code at all: guide, search, playPause, backspace, enter,
/// instantReplay. [RemoteKey.settings] uses MENU, the nearest key, and
/// [RemoteKey.home] the SmartCentral/APPS launcher key.
const Map<RemoteKey, int> sharpKeyCodes = {
  RemoteKey.digit0: 0,
  RemoteKey.digit1: 1,
  RemoteKey.digit2: 2,
  RemoteKey.digit3: 3,
  RemoteKey.digit4: 4,
  RemoteKey.digit5: 5,
  RemoteKey.digit6: 6,
  RemoteKey.digit7: 7,
  RemoteKey.digit8: 8,
  RemoteKey.digit9: 9,
  RemoteKey.power: sharpPowerKey,
  RemoteKey.info: 13,
  RemoteKey.rewind: 15,
  RemoteKey.play: 16,
  RemoteKey.fastForward: 17,
  RemoteKey.pause: 18,
  RemoteKey.previous: 19,
  RemoteKey.stop: 20,
  RemoteKey.next: 21,
  RemoteKey.record: 22,
  RemoteKey.captions: 27,
  RemoteKey.previousChannel: 30,
  RemoteKey.volumeDown: 32,
  RemoteKey.volumeUp: 33,
  RemoteKey.channelUp: 34,
  RemoteKey.channelDown: 35,
  RemoteKey.input: 36,
  RemoteKey.menu: 38,
  RemoteKey.settings: 38,
  RemoteKey.home: 39,
  RemoteKey.select: 40,
  RemoteKey.up: 41,
  RemoteKey.down: 42,
  RemoteKey.left: 43,
  RemoteKey.right: 44,
  RemoteKey.back: 45,
  RemoteKey.exit: 46,
  RemoteKey.red: 50,
  RemoteKey.green: 51,
  RemoteKey.blue: 52,
  RemoteKey.yellow: 53,
};

/// The transport key for each [MediaAction] that has one.
const Map<MediaAction, int> sharpMediaCodes = {
  MediaAction.rewind: 15,
  MediaAction.play: 16,
  MediaAction.fastForward: 17,
  MediaAction.pause: 18,
  MediaAction.previous: 19,
  MediaAction.stop: 20,
  MediaAction.next: 21,
};

/// The input each input key selects (`SelectInput` ids).
const Map<RemoteKey, String> sharpInputKeys = {
  RemoteKey.inputHdmi1: 'hdmi1',
  RemoteKey.inputHdmi2: 'hdmi2',
  RemoteKey.inputHdmi3: 'hdmi3',
  RemoteKey.inputHdmi4: 'hdmi4',
  RemoteKey.inputAv1: 'av1',
  RemoteKey.inputTuner: 'tv',
};

/// The app id `LaunchApp` takes for the NETFLIX key, the only app the
/// protocol can open.
const String sharpNetflixAppId = 'netflix';
