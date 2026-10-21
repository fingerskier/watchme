/// "Control by mobile apps" on the simulated Roku.
enum RokuControlMode {
  /// Enabled (or Permissive): everything works.
  enabled,

  /// Limited, the Roku OS 14.1+ default: device-info, active-app and launch
  /// answer; key presses, text, `query/apps`, `query/media-player`,
  /// `query/icon`, the TV channel queries and `input` get HTTP 403
  /// `ECP command not allowed in Limited mode.`
  limited,

  /// ECP refuses everything with HTTP 403 `ECP command not allowed.` (the
  /// exact wording on real firmware is unverified).
  disabled,
}

/// The simulated Roku's `power-mode`.
enum RokuSimPowerMode {
  /// `PowerOn`.
  powerOn('PowerOn'),

  /// `DisplayOff`: on with the panel dark.
  displayOff('DisplayOff'),

  /// `Ready`: network standby. Only device-info, the root description and
  /// the `PowerOn` / `Power` keys answer; everything else gets an empty
  /// HTTP 403 (field reports; the real body is unverified).
  ready('Ready');

  const RokuSimPowerMode(this.wire);

  /// The `power-mode` text.
  final String wire;
}

/// The simulated media player's `state` attribute.
enum RokuSimPlayerState {
  /// Nothing loaded.
  none,

  /// Player closed (home screen or an idle app).
  close,

  /// Opening a stream.
  open,

  /// Starting up.
  startup,

  /// Buffering.
  buffer,

  /// Playing.
  play,

  /// Paused.
  pause,

  /// Stopped.
  stop,
}

/// Identity of a simulated Roku, written into device-info, the UPnP
/// description and SSDP replies.
final class RokuSimDevice {
  /// Creates a device identity; the defaults describe a TCL Roku TV on
  /// Roku OS 14.1.4.
  const RokuSimDevice({
    this.serialNumber = 'X01900SIM001',
    this.deviceId = 'S0A36SIM0001',
    this.udn = '015e5108-9000-1046-8035-b0a737000001',
    this.vendorName = 'TCL',
    this.modelName = '5-Series',
    this.modelNumber = '7000X',
    this.friendlyModelName = 'TCL•Roku TV',
    this.isTv = true,
    this.isStick = false,
    this.tunerType = 'ATSC',
    this.userDeviceName = 'Simulated Roku TV',
    this.userDeviceLocation = 'Living room',
    this.wifiMac = '02:00:5e:00:00:01',
    this.ethernetMac = '02:00:5e:00:00:02',
    this.networkType = 'wifi',
    this.softwareVersion = '14.1.4',
    this.softwareBuild = '6000',
    this.buildNumber = 'CHD.50E04174A',
    this.supportsFindRemote = true,
    this.supportsWakeOnWlan = true,
    this.supportsTvPowerControl,
    this.supportsAudioVolumeControl,
    this.reportEcpSettingMode = false,
  });

  /// A Roku Express 4K+ player on Roku OS 15 (no tuner, no inputs, Wi-Fi
  /// only, CEC power and volume fields present).
  static const RokuSimDevice player = RokuSimDevice(
    serialNumber: 'YH00SIM00002',
    deviceId: 'S0B41SIM0002',
    udn: '29600011-1c0d-1041-80e4-d83134000002',
    vendorName: 'Roku',
    modelName: 'Roku Express 4K+',
    modelNumber: '3941X',
    friendlyModelName: 'Roku Express 4K+',
    isTv: false,
    tunerType: null,
    userDeviceName: 'Simulated Roku Express',
    userDeviceLocation: 'Bedroom',
    ethernetMac: null,
    softwareVersion: '15.0.4',
    softwareBuild: '4170',
    buildNumber: 'D3B.00E04170A',
    supportsFindRemote: false,
    supportsWakeOnWlan: false,
    supportsTvPowerControl: true,
    supportsAudioVolumeControl: true,
  );

  /// `serial-number`; also in the SSDP USN `uuid:roku:ecp:<serial>`.
  final String serialNumber;

  /// `device-id`.
  final String deviceId;

  /// `udn` (without the `uuid:` prefix).
  final String udn;

  /// `vendor-name`.
  final String vendorName;

  /// `model-name`.
  final String modelName;

  /// `model-number`.
  final String modelNumber;

  /// `friendly-model-name`.
  final String friendlyModelName;

  /// `is-tv`.
  final bool isTv;

  /// `is-stick`.
  final bool isStick;

  /// `tuner-type` (omitted when `null`).
  final String? tunerType;

  /// `user-device-name`.
  final String userDeviceName;

  /// `user-device-location`.
  final String userDeviceLocation;

  /// `wifi-mac`.
  final String wifiMac;

  /// `ethernet-mac` (omitted when `null`).
  final String? ethernetMac;

  /// `network-type` (`wifi` or `ethernet`).
  final String networkType;

  /// `software-version`.
  final String softwareVersion;

  /// `software-build`.
  final String softwareBuild;

  /// `build-number`.
  final String buildNumber;

  /// `supports-find-remote`.
  final bool supportsFindRemote;

  /// `supports-wake-on-wlan`.
  final bool supportsWakeOnWlan;

  /// `supports-tv-power-control` (Roku OS 15+; omitted when `null`).
  final bool? supportsTvPowerControl;

  /// `supports-audio-volume-control` (Roku OS 15+; omitted when `null`).
  final bool? supportsAudioVolumeControl;

  /// Whether device-info includes `ecp-setting-mode` (brs-desktop does;
  /// real firmware is unverified, so off by default).
  final bool reportEcpSettingMode;

  /// `default-device-name`.
  String get defaultDeviceName => '$friendlyModelName - $serialNumber';
}

/// An installed app (channel) on the simulated Roku.
final class RokuSimApp {
  /// Creates an app entry; [type] is `appl` for apps and `tvin` for TV
  /// inputs.
  const RokuSimApp(
    this.id,
    this.name, {
    this.type = 'appl',
    this.version = '1.0.0',
  });

  /// Channel id, e.g. `12` (Netflix) or `tvinput.hdmi1`.
  final String id;

  /// Display name.
  final String name;

  /// `appl`, `tvin` or `menu`.
  final String type;

  /// Version string.
  final String version;

  @override
  String toString() => 'RokuSimApp($id, $name)';
}

/// How a key event arrived.
enum RokuSimKeyAction {
  /// `POST /keypress/<key>`.
  press,

  /// `POST /keydown/<key>`.
  down,

  /// `POST /keyup/<key>`.
  up,
}

/// One accepted key request.
final class RokuSimKeyEvent {
  /// Records [key] arriving as [action].
  const RokuSimKeyEvent(this.action, this.key);

  /// Press, down or up.
  final RokuSimKeyAction action;

  /// The canonical key name (`Home`, `VolumeUp`, ...) or, for text,
  /// `Lit_` plus the decoded character (`Lit_€`).
  final String key;

  @override
  bool operator ==(Object other) =>
      other is RokuSimKeyEvent && other.action == action && other.key == key;

  @override
  int get hashCode => Object.hash(action, key);

  @override
  String toString() => '${action.name} $key';
}

/// One accepted `POST /launch/<id>`.
final class RokuSimLaunch {
  /// Records a launch of [appId] with query [params].
  const RokuSimLaunch(this.appId, this.params);

  /// The launched channel id.
  final String appId;

  /// The query parameters (e.g. `contentId`, `mediaType`, `ch`, `u`).
  final Map<String, String> params;

  @override
  String toString() => 'RokuSimLaunch($appId, $params)';
}

/// One HTTP request the simulator answered.
final class RokuSimRequest {
  /// Records a request.
  const RokuSimRequest({
    required this.method,
    required this.path,
    required this.query,
    required this.hostHeader,
    required this.status,
  });

  /// HTTP method.
  final String method;

  /// The request path, percent-encoded as received.
  final String path;

  /// The raw query string.
  final String query;

  /// The `Host` header as received.
  final String? hostHeader;

  /// The status the simulator answered with.
  final int status;

  @override
  String toString() => '$method $path -> $status';
}
