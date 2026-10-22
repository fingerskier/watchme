import 'package:watchme_core/watchme_core.dart';

/// A SmartCast key: a codeset and a code within it.
typedef VizioKey = ({int codeset, int code});

/// The SmartCast key for each [RemoteKey] this driver sends. Every code was
/// cross-checked across vizaio, pyvizio, heathbar and exiva (brief §6).
///
/// Left out on purpose:
/// * [RemoteKey.power]: the toggle (11/2) is never sent. Power is discrete:
///   [RemoteKey.powerOn] is 11/1 and [RemoteKey.powerOff] 11/0.
/// * [RemoteKey.guide]: 4/4 is "guide" in vizaio but closed captions in
///   pyvizio and heathbar, and which one it triggers per firmware is
///   unverified, so only the majority meaning ([RemoteKey.captions]) maps.
/// * [RemoteKey.playPause]: SmartCast has discrete PLAY (2/3) and PAUSE
///   (2/2) and no readable playback state; whether PLAY toggles is
///   unverified, so no key stands in for a toggle.
/// * Settings, search, colour keys, backspace, enter, stop, next, previous,
///   record and instant replay: no code in any reference.
///
/// [RemoteKey.home] is 4/3, the SmartCast key, which every reference agrees
/// opens SmartCast home. pyvizio's HOME (4/15) is in no other source and
/// unverified on hardware, so it is not used. [RemoteKey.exit] is 9/0
/// (pyvizio and heathbar; vizaio's 4/3 collides with its own SmartCast
/// key); still unverified on hardware.
///
/// Inputs ([RemoteKey.inputHdmi1] and the like) are not keys here: the
/// session selects them through the settings tree. [RemoteKey.input] is the
/// input-cycle key 7/1 (some panels acknowledge it without acting).
const Map<RemoteKey, VizioKey> vizioKeys = {
  RemoteKey.up: (codeset: 3, code: 8),
  RemoteKey.down: (codeset: 3, code: 0),
  RemoteKey.left: (codeset: 3, code: 1),
  RemoteKey.right: (codeset: 3, code: 7),
  RemoteKey.select: (codeset: 3, code: 2),
  RemoteKey.back: (codeset: 4, code: 0),
  RemoteKey.home: (codeset: 4, code: 3),
  RemoteKey.menu: (codeset: 4, code: 8),
  RemoteKey.info: (codeset: 4, code: 6),
  RemoteKey.exit: (codeset: 9, code: 0),
  RemoteKey.captions: (codeset: 4, code: 4),
  RemoteKey.volumeUp: (codeset: 5, code: 1),
  RemoteKey.volumeDown: (codeset: 5, code: 0),
  RemoteKey.mute: (codeset: 5, code: 4),
  RemoteKey.channelUp: (codeset: 8, code: 1),
  RemoteKey.channelDown: (codeset: 8, code: 0),
  RemoteKey.previousChannel: (codeset: 8, code: 2),
  RemoteKey.digit0: (codeset: 0, code: 48),
  RemoteKey.digit1: (codeset: 0, code: 49),
  RemoteKey.digit2: (codeset: 0, code: 50),
  RemoteKey.digit3: (codeset: 0, code: 51),
  RemoteKey.digit4: (codeset: 0, code: 52),
  RemoteKey.digit5: (codeset: 0, code: 53),
  RemoteKey.digit6: (codeset: 0, code: 54),
  RemoteKey.digit7: (codeset: 0, code: 55),
  RemoteKey.digit8: (codeset: 0, code: 56),
  RemoteKey.digit9: (codeset: 0, code: 57),
  RemoteKey.play: (codeset: 2, code: 3),
  RemoteKey.pause: (codeset: 2, code: 2),
  RemoteKey.fastForward: (codeset: 2, code: 0),
  RemoteKey.rewind: (codeset: 2, code: 1),
  RemoteKey.powerOn: (codeset: 11, code: 1),
  RemoteKey.powerOff: (codeset: 11, code: 0),
  RemoteKey.input: (codeset: 7, code: 1),
};

/// The power toggle (11/2). Listed so tests can check it is never sent.
const VizioKey vizioPowerToggleKey = (codeset: 11, code: 2);

/// The SmartCast key for [action], or `null` for an action without one.
VizioKey? vizioMediaKey(MediaAction action) => switch (action) {
  MediaAction.play => vizioKeys[RemoteKey.play],
  MediaAction.pause => vizioKeys[RemoteKey.pause],
  MediaAction.fastForward => vizioKeys[RemoteKey.fastForward],
  MediaAction.rewind => vizioKeys[RemoteKey.rewind],
  _ => null,
};

/// The codeset-0 (ASCII) keys that type [text]: one per character, its
/// code point as the code (`'H'` is 72, a space 32, a digit `'7'` 55).
/// `null` when [text] has anything but printable ASCII (32 to 126): the
/// TV injects ASCII only.
List<VizioKey>? vizioTextKeys(String text) {
  final keys = <VizioKey>[];
  for (final rune in text.runes) {
    if (rune < 0x20 || rune > 0x7e) return null;
    keys.add((codeset: 0, code: rune));
  }
  return keys;
}

/// The `PUT /key_command/` body for [keys]: one `KEYPRESS` each, in order
/// (the only action the official app sends).
Map<String, Object?> vizioKeyListBody(Iterable<VizioKey> keys) => {
  'KEYLIST': [
    for (final k in keys)
      {'CODESET': k.codeset, 'CODE': k.code, 'ACTION': 'KEYPRESS'},
  ],
};

/// An app this driver can launch: the `(NAME_SPACE, APP_ID, MESSAGE)`
/// triple `PUT /app/launch` takes.
final class VizioApp {
  /// Creates a table entry.
  const VizioApp(
    this.id,
    this.name,
    this.nameSpace,
    this.appId, {
    this.message,
  });

  /// watchme's id for it, as [AppInfo.id] and [LaunchApp.appId].
  final String id;

  /// Display name.
  final String name;

  /// `NAME_SPACE`.
  final int nameSpace;

  /// `APP_ID`.
  final String appId;

  /// `MESSAGE`.
  final String? message;

  /// The `PUT /app/launch` body.
  Map<String, Object?> get launchBody => {
    'VALUE': {'APP_ID': appId, 'NAME_SPACE': nameSpace, 'MESSAGE': message},
  };

  /// As an [AppInfo].
  AppInfo get info => AppInfo(
    id: id,
    name: name,
    kind: nameSpace == 4 ? AppKind.other : AppKind.app,
  );

  /// Whether `/app/current` reporting [nameSpace] and [appId] means this
  /// app. Name spaces 2 and 4 are interchangeable there (vizaio).
  bool matches(int nameSpace, String appId) =>
      appId == this.appId &&
      (nameSpace == this.nameSpace ||
          ({nameSpace, this.nameSpace}.difference(const {2, 4}).isEmpty));
}

/// The launch payloads the brief verified against vizaio's bundled
/// availability data, the same on every chipset: Netflix, YouTube and
/// SmartCast Home. Prime Video is left out because its payload depends on
/// the chipset (`2/"4"` or `3/"3"`). The full catalog lives in VIZIO's
/// cloud, which this driver does not use.
///
/// Only these entries can be launched: `LaunchApp` never forwards a raw
/// triple, so the `NAME_SPACE 4 / APP_ID "3001"` raw-URL launcher (the
/// surface security research abuses) is unreachable.
const List<VizioApp> vizioApps = [
  VizioApp('netflix', 'Netflix', 3, '1'),
  VizioApp('youtube', 'YouTube', 5, '1'),
  VizioApp(
    'smartcast-home',
    'SmartCast Home',
    4,
    '1',
    message: 'http://127.0.0.1:12345/scfs/sctv/main.html',
  ),
];
