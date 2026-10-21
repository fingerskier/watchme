import 'package:watchme_core/watchme_core.dart';
import 'package:xml/xml.dart';

/// How much of ECP the device's "Control by mobile apps" setting allows.
///
/// Roku OS 14.1 added the setting (Settings > System > Advanced system
/// settings > Control by mobile apps). Older firmware labels the levels
/// Default / Permissive / Disabled.
enum RokuEcpAccess {
  /// Enabled or Permissive (or the pre-14.1 Default): full control.
  enabled,

  /// Limited: device-info and active-app answer; key presses, text, the app
  /// list and the media player are refused with HTTP 403
  /// `ECP command not allowed in Limited mode.`
  limited,

  /// ECP refuses everything, including device-info.
  disabled,

  /// Not determined yet (e.g. the TV was in standby during the probe).
  unknown,
}

/// The parsed body of `GET /query/device-info`.
///
/// Every child element is kept in [fields] verbatim; the getters interpret
/// the ones watchme uses. Empty elements (`<keyed-developer-id/>`) read as
/// `null`.
final class RokuDeviceInfo {
  /// Wraps already-extracted device-info [fields].
  RokuDeviceInfo(Map<String, String> fields)
    : fields = Map.unmodifiable(fields);

  /// Parses a device-info XML document.
  ///
  /// Throws [FormatException] when [xml] is not XML or its root element is
  /// not `device-info`.
  factory RokuDeviceInfo.parse(String xml) {
    final root = _parseRoot(xml, 'device-info');
    return RokuDeviceInfo({
      for (final e in root.childElements) e.name.local: e.innerText.trim(),
    });
  }

  /// Every child element of `<device-info>`, by element name.
  final Map<String, String> fields;

  /// The field [name], or `null` when absent or empty.
  String? operator [](String name) {
    final v = fields[name];
    return v == null || v.isEmpty ? null : v;
  }

  bool? _flag(String name) => switch (this[name]?.toLowerCase()) {
    'true' => true,
    'false' => false,
    _ => null,
  };

  /// `udn`.
  String? get udn => this['udn'];

  /// `serial-number`, the identity Roku also puts in its SSDP USN.
  String? get serialNumber => this['serial-number'];

  /// `vendor-name` (e.g. `Roku`, `TCL`, `Hisense`).
  String? get vendorName => this['vendor-name'];

  /// `model-name` (e.g. `Roku Express 4K+`, `5-Series`).
  String? get modelName => this['model-name'];

  /// `model-number` (e.g. `3941X`, `7000X`).
  String? get modelNumber => this['model-number'];

  /// `is-tv`: a Roku TV rather than a player.
  bool get isTv => _flag('is-tv') ?? false;

  /// `is-stick`.
  bool get isStick => _flag('is-stick') ?? false;

  /// `wifi-mac`, normalised, or `null` when absent or malformed.
  String? get wifiMac => _mac('wifi-mac');

  /// `ethernet-mac`, normalised, or `null` when absent or malformed.
  String? get ethernetMac => _mac('ethernet-mac');

  /// `network-type` (`wifi` or `ethernet`).
  String? get networkType => this['network-type'];

  /// The best display name: `user-device-name`, then
  /// `friendly-device-name`, then `default-device-name`.
  String? get displayName =>
      this['user-device-name'] ??
      this['friendly-device-name'] ??
      this['default-device-name'];

  /// `software-version` (e.g. `14.1.4`).
  String? get softwareVersion => this['software-version'];

  /// `software-build`.
  String? get softwareBuild => this['software-build'];

  /// `power-mode` as reported (`PowerOn`, `DisplayOff`, `Ready`, ...).
  String? get powerModeRaw => this['power-mode'];

  /// [powerModeRaw] mapped to a [PowerMode].
  PowerMode get powerMode => rokuPowerMode(powerModeRaw);

  /// `tuner-type` (Roku TVs with a broadcast tuner, e.g. `ATSC`).
  String? get tunerType => this['tuner-type'];

  /// `supports-find-remote`.
  bool get supportsFindRemote => _flag('supports-find-remote') ?? false;

  /// `supports-wake-on-wlan`.
  bool get supportsWakeOnWlan => _flag('supports-wake-on-wlan') ?? false;

  /// `supports-tv-power-control` (Roku OS 15.0+; `null` before).
  bool? get supportsTvPowerControl => _flag('supports-tv-power-control');

  /// `supports-audio-volume-control` (Roku OS 15.0+; `null` before).
  bool? get supportsAudioVolumeControl =>
      _flag('supports-audio-volume-control');

  /// The access level from `ecp-setting-mode`, when the firmware reports
  /// one; [RokuEcpAccess.unknown] otherwise.
  ///
  /// brs-desktop emits this element; whether all real firmware does is
  /// unverified, so the probe falls back to testing a gated endpoint.
  RokuEcpAccess get ecpAccess =>
      switch (this['ecp-setting-mode']?.toLowerCase()) {
        'enabled' || 'permissive' || 'default' => RokuEcpAccess.enabled,
        'limited' => RokuEcpAccess.limited,
        'disabled' => RokuEcpAccess.disabled,
        _ => RokuEcpAccess.unknown,
      };

  String? _mac(String name) => switch (this[name]) {
    null => null,
    final v => tryNormalizeMac(v),
  };

  /// Identity facts for a probe: name, manufacturer, model, MACs (the
  /// interface in use first), `roku:serial:<serial>` and OS version.
  DeviceInfo toDeviceInfo() {
    final ethernetFirst = networkType?.toLowerCase() == 'ethernet';
    final macs = [
      if (ethernetFirst) ...[
        ?ethernetMac,
        ?wifiMac,
      ] else ...[
        ?wifiMac,
        ?ethernetMac,
      ],
    ];
    final model = modelName ?? modelNumber;
    return DeviceInfo(
      name: displayName ?? [?vendorName, ?model].join(' '),
      manufacturer: vendorName ?? 'Roku',
      model: model,
      mac: macs.firstOrNull,
      otherMacs: macs.skip(1).toSet(),
      stableId: serialNumber == null ? null : rokuStableId(serialNumber!),
      osVersion: softwareVersion,
      extra: {for (final key in _extraKeys) key: ?this[key]},
    );
  }

  // Non-secret facts worth keeping; advertising-id and developer ids are
  // deliberately left out.
  static const List<String> _extraKeys = [
    'udn',
    'model-number',
    'is-tv',
    'is-stick',
    'power-mode',
    'network-type',
    'software-build',
    'tuner-type',
    'supports-wake-on-wlan',
    'supports-find-remote',
    'supports-tv-power-control',
    'supports-audio-volume-control',
    'ecp-setting-mode',
  ];

  @override
  bool operator ==(Object other) =>
      other is RokuDeviceInfo &&
      other.fields.length == fields.length &&
      fields.entries.every((e) => other.fields[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(
    fields.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() => 'RokuDeviceInfo($vendorName $modelName $serialNumber)';
}

/// The [DeviceInfo.stableId] watchme uses for the Roku with [serialNumber].
String rokuStableId(String serialNumber) => 'roku:serial:$serialNumber';

/// The serial number in a Roku SSDP USN (`uuid:roku:ecp:<serial>`), or
/// `null` when [usn] is not one.
String? rokuSerialFromUsn(String? usn) {
  const prefix = 'uuid:roku:ecp:';
  if (usn == null || !usn.toLowerCase().startsWith(prefix)) return null;
  final serial = usn.substring(prefix.length).split('::').first.trim();
  return serial.isEmpty ? null : serial;
}

/// Maps a device-info `power-mode` value to a [PowerMode].
///
/// `PowerOn` is on, `DisplayOff` and `Headless` (a player with no display)
/// are screen-off, `Ready` and `Suspend*` are network standby.
PowerMode rokuPowerMode(String? raw) => switch (raw?.toLowerCase()) {
  'poweron' => PowerMode.on,
  'displayoff' || 'headless' => PowerMode.screenOff,
  'ready' || 'suspend' || 'suspended' => PowerMode.standby,
  _ => PowerMode.unknown,
};

/// Parses `GET /query/apps`.
///
/// `type="tvin"` entries become [AppKind.input], `appl` [AppKind.app], and
/// anything else (`menu`, ...) [AppKind.other]. With [iconBase] (the ECP
/// base URI), each entry's [AppInfo.icon] points at `query/icon/<id>`.
///
/// Throws [FormatException] for malformed XML or a root other than `apps`.
List<AppInfo> parseRokuApps(String xml, {Uri? iconBase}) {
  final root = _parseRoot(xml, 'apps');
  return [
    for (final e in root.findElements('app')) ?_appFrom(e, iconBase: iconBase),
  ];
}

/// The id watchme gives the Roku home screen, which `query/active-app`
/// reports without an id (`<app>Roku</app>`).
const String rokuHomeAppId = 'home';

/// Parses `GET /query/active-app`. The home screen becomes
/// `AppInfo(id: rokuHomeAppId, kind: AppKind.other)`.
///
/// Throws [FormatException] for malformed XML or a root other than
/// `active-app`.
AppInfo parseRokuActiveApp(String xml) {
  final root = _parseRoot(xml, 'active-app');
  final app = root.findElements('app').firstOrNull;
  if (app == null) {
    return const AppInfo(id: rokuHomeAppId, name: 'Home', kind: AppKind.other);
  }
  return _appFrom(app) ??
      AppInfo(
        id: rokuHomeAppId,
        name: app.innerText.trim().isEmpty ? 'Home' : app.innerText.trim(),
        kind: AppKind.other,
      );
}

AppInfo? _appFrom(XmlElement e, {Uri? iconBase}) {
  final id = e.getAttribute('id')?.trim();
  if (id == null || id.isEmpty) return null;
  final name = e.innerText.trim();
  return AppInfo(
    id: id,
    name: name.isEmpty ? id : name,
    kind: switch (e.getAttribute('type')) {
      'tvin' => AppKind.input,
      'appl' => AppKind.app,
      null => AppKind.app,
      _ => AppKind.other,
    },
    version: switch (e.getAttribute('version')?.trim()) {
      null || '' => null,
      final v => v,
    },
    icon: iconBase?.replace(path: '/query/icon/${Uri.encodeComponent(id)}'),
  );
}

/// The parsed body of `GET /query/media-player`.
final class RokuMediaPlayer {
  /// Creates a media-player snapshot.
  const RokuMediaPlayer({
    required this.state,
    this.error = false,
    this.pluginId,
    this.pluginName,
    this.position,
    this.duration,
    this.isLive = false,
  });

  /// Parses a media-player XML document.
  ///
  /// Throws [FormatException] for malformed XML or a root other than
  /// `player`.
  factory RokuMediaPlayer.parse(String xml) {
    final root = _parseRoot(xml, 'player');
    final plugin = root.findElements('plugin').firstOrNull;
    String? child(String name) =>
        switch (root.findElements(name).firstOrNull?.innerText.trim()) {
          null || '' => null,
          final v => v,
        };
    return RokuMediaPlayer(
      state: root.getAttribute('state') ?? 'none',
      error: root.getAttribute('error')?.toLowerCase() == 'true',
      pluginId: plugin?.getAttribute('id'),
      pluginName: plugin?.getAttribute('name'),
      position: _millis(child('position')),
      duration: _millis(child('duration')),
      isLive: child('is_live')?.toLowerCase() == 'true',
    );
  }

  /// The `state` attribute as reported: `play`, `pause`, `buffer`,
  /// `startup`, `open`, `stop`, `close` or `none`.
  final String state;

  /// The `error` attribute.
  final bool error;

  /// The playing app (`plugin id`).
  final String? pluginId;

  /// The playing app's name (`plugin name`).
  final String? pluginName;

  /// `position`.
  final Duration? position;

  /// `duration`.
  final Duration? duration;

  /// `is_live`.
  final bool isLive;

  /// [state] mapped to a [PlaybackState].
  PlaybackState get playbackState => switch (state.toLowerCase()) {
    'play' => PlaybackState.playing,
    'pause' => PlaybackState.paused,
    'buffer' || 'startup' || 'open' => PlaybackState.buffering,
    'stop' || 'close' || 'none' => PlaybackState.stopped,
    _ => PlaybackState.unknown,
  };

  /// This snapshot as a [NowPlaying]. ECP reports no titles.
  NowPlaying toNowPlaying() => NowPlaying(
    state: playbackState,
    appId: pluginId,
    position: position,
    duration: isLive ? null : duration,
    isLive: isLive,
  );

  @override
  bool operator ==(Object other) =>
      other is RokuMediaPlayer &&
      other.state == state &&
      other.error == error &&
      other.pluginId == pluginId &&
      other.pluginName == pluginName &&
      other.position == position &&
      other.duration == duration &&
      other.isLive == isLive;

  @override
  int get hashCode => Object.hash(
    state,
    error,
    pluginId,
    pluginName,
    position,
    duration,
    isLive,
  );

  @override
  String toString() => 'RokuMediaPlayer($state, $pluginId, $position)';
}

// ECP writes times as "12345 ms"; tolerate a bare number too.
Duration? _millis(String? raw) {
  if (raw == null) return null;
  final digits = RegExp(r'-?\d+').firstMatch(raw)?.group(0);
  final ms = digits == null ? null : int.tryParse(digits);
  return ms == null ? null : Duration(milliseconds: ms);
}

XmlElement _parseRoot(String xml, String rootName) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException catch (e) {
    throw FormatException('Malformed Roku XML: ${e.message}', xml);
  }
  final root = doc.rootElement;
  if (root.name.local != rootName) {
    throw FormatException(
      'Expected <$rootName>, got <${root.name.local}>',
      xml,
    );
  }
  return root;
}
