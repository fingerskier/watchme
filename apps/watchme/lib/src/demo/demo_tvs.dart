import 'package:watchme_core/watchme_core.dart';

/// The PIN the demo Fire TV accepts.
const String demoFireTvPin = '1234';

/// Address of the demo Roku TV (TEST-NET-1, never a real LAN host).
const String demoRokuHost = '192.0.2.10';

/// Address of the demo Fire TV (TEST-NET-1, never a real LAN host).
const String demoFireTvHost = '192.0.2.20';

const AppInfo _rokuHome = AppInfo(
  id: 'home',
  name: 'Home screen',
  kind: AppKind.other,
);
const AppInfo _fireTvHome = AppInfo(
  id: 'com.amazon.tv.launcher',
  name: 'Home screen',
  kind: AppKind.other,
);

/// One simulated TV and its mutable state. Capabilities and quirks follow
/// the protocol research for each platform (docs/research, sections 6.4 and
/// 6.5), so the demo exercises the same UI paths a real TV would.
class DemoTv {
  DemoTv._({
    required this.id,
    required this.name,
    required this.host,
    required this.manufacturer,
    required this.model,
    required this.driverId,
    required this.protocol,
    required this.requiresPairing,
    required this.capabilities,
    required this.apps,
    required this.unsupportedKeys,
    required this.home,
    required this.reportsState,
    required this.mediaActions,
    required DateTime now,
    this.refusedMedia = const {},
    this.setup = const [],
  }) : foreground = home,
       lastSeen = now,
       stateAt = now;

  /// A Roku TV on ECP: no pairing, relative volume, channels and inputs.
  factory DemoTv.roku(DateTime now) => DemoTv._(
    id: 'demo-roku',
    name: 'Living Room Roku TV',
    host: demoRokuHost,
    manufacturer: 'TCL',
    model: '55S455',
    driverId: 'roku.ecp',
    protocol: 'Roku ECP',
    requiresPairing: false,
    now: now,
    home: _rokuHome,
    reportsState: true,
    mediaActions: const {
      MediaAction.play,
      MediaAction.pause,
      MediaAction.playPause,
      MediaAction.rewind,
      MediaAction.fastForward,
      MediaAction.instantReplay,
    },
    capabilities: const [
      CapabilitySupport.yes(Capability.powerOff),
      CapabilitySupport.partial(
        Capability.powerOn,
        flags: {CapFlag.needsNetworkStandby, CapFlag.undocumented},
        note: 'Works while Fast TV Start keeps the network awake.',
      ),
      CapabilitySupport.yes(Capability.powerState),
      CapabilitySupport.partial(
        Capability.volume,
        flags: {CapFlag.relativeOnly},
      ),
      CapabilitySupport.partial(Capability.mute, flags: {CapFlag.toggleOnly}),
      CapabilitySupport.yes(Capability.dpadNavigation),
      CapabilitySupport.yes(Capability.systemKeys),
      CapabilitySupport.yes(
        Capability.textInput,
        flags: {CapFlag.needsKeyboardOpen},
      ),
      CapabilitySupport.yes(Capability.appList),
      CapabilitySupport.yes(Capability.appLaunch),
      CapabilitySupport.yes(Capability.inputSwitch),
      CapabilitySupport.yes(Capability.channel),
      CapabilitySupport.partial(Capability.mediaTransport),
      CapabilitySupport.partial(Capability.nowPlaying),
      CapabilitySupport.no(Capability.pointer),
      CapabilitySupport.no(Capability.notificationToast),
      CapabilitySupport.no(Capability.screenshot),
      CapabilitySupport.no(Capability.castMediaUrl),
    ],
    apps: const [
      AppInfo(id: '12', name: 'Netflix'),
      AppInfo(id: '837', name: 'YouTube'),
      AppInfo(id: '13', name: 'Prime Video'),
      AppInfo(id: '291097', name: 'Disney+'),
      AppInfo(id: '151908', name: 'The Roku Channel'),
      AppInfo(id: 'tvinput.dtv', name: 'Live TV', kind: AppKind.input),
      AppInfo(id: 'tvinput.hdmi1', name: 'HDMI 1', kind: AppKind.input),
      AppInfo(id: 'tvinput.hdmi2', name: 'HDMI 2', kind: AppKind.input),
    ],
    unsupportedKeys: const {
      RemoteKey.settings,
      RemoteKey.exit,
      RemoteKey.guide,
      RemoteKey.red,
      RemoteKey.green,
      RemoteKey.yellow,
      RemoteKey.blue,
      RemoteKey.record,
      RemoteKey.captions,
    },
    setup: [
      SetupStep(
        id: 'roku.controlByMobileApps',
        title: 'Control by mobile apps = Enabled',
        detail:
            'Settings > System > Advanced system settings > Control by '
            'mobile apps. In Limited mode the TV reports its status but '
            'refuses key presses.',
      ),
    ],
  );

  /// A Fire TV stick on the Lightning API: PIN pairing, no channels.
  factory DemoTv.fireTv(DateTime now) => DemoTv._(
    id: 'demo-firetv',
    name: 'Bedroom Fire TV Stick',
    host: demoFireTvHost,
    manufacturer: 'Amazon',
    model: 'AFTKA',
    driverId: 'firetv.lightning',
    protocol: 'Fire TV remote API',
    requiresPairing: true,
    now: now,
    home: _fireTvHome,
    reportsState: false,
    mediaActions: const {
      MediaAction.play,
      MediaAction.pause,
      MediaAction.playPause,
      MediaAction.rewind,
      MediaAction.fastForward,
    },
    // Backward scan is unverified on hardware (`backward` returned HTTP 400
    // on one receiver); the demo refuses it to show what a refusal looks
    // like.
    refusedMedia: const {MediaAction.rewind},
    capabilities: const [
      CapabilitySupport.yes(Capability.powerOff, flags: {CapFlag.undocumented}),
      CapabilitySupport.partial(
        Capability.powerOn,
        note: 'DIAL wakes a sleeping stick; not a fully powered-off one.',
      ),
      CapabilitySupport.no(Capability.powerState),
      CapabilitySupport.partial(
        Capability.volume,
        flags: {CapFlag.relativeOnly, CapFlag.undocumented},
        note: 'Forwarded to the TV over HDMI-CEC.',
      ),
      CapabilitySupport.partial(
        Capability.mute,
        flags: {CapFlag.toggleOnly, CapFlag.undocumented},
      ),
      CapabilitySupport.yes(
        Capability.dpadNavigation,
        flags: {CapFlag.undocumented},
      ),
      CapabilitySupport.yes(
        Capability.systemKeys,
        flags: {CapFlag.undocumented},
      ),
      CapabilitySupport.partial(
        Capability.textInput,
        flags: {CapFlag.needsKeyboardOpen, CapFlag.undocumented},
      ),
      CapabilitySupport.yes(Capability.appList, flags: {CapFlag.undocumented}),
      CapabilitySupport.yes(
        Capability.appLaunch,
        flags: {CapFlag.undocumented},
      ),
      CapabilitySupport.no(Capability.inputSwitch),
      CapabilitySupport.no(Capability.channel),
      CapabilitySupport.partial(
        Capability.mediaTransport,
        flags: {CapFlag.undocumented},
        note: 'Rewind is refused by some sticks.',
      ),
      CapabilitySupport.unknown(Capability.nowPlaying),
      CapabilitySupport.no(Capability.pointer),
      CapabilitySupport.no(Capability.notificationToast),
      CapabilitySupport.no(Capability.screenshot),
      CapabilitySupport.no(Capability.castMediaUrl),
    ],
    apps: const [
      AppInfo(id: 'com.netflix.ninja', name: 'Netflix'),
      AppInfo(id: 'com.amazon.firebat', name: 'Prime Video'),
      AppInfo(id: 'com.amazon.firetv.youtube', name: 'YouTube'),
      AppInfo(id: 'com.disney.disneyplus', name: 'Disney+'),
    ],
    unsupportedKeys: const {
      RemoteKey.info,
      RemoteKey.guide,
      RemoteKey.exit,
      RemoteKey.settings,
      RemoteKey.search,
      RemoteKey.captions,
      RemoteKey.red,
      RemoteKey.green,
      RemoteKey.yellow,
      RemoteKey.blue,
      RemoteKey.record,
      RemoteKey.instantReplay,
    },
  );

  /// Engine-style device id.
  final String id;

  /// Display name.
  final String name;

  /// Address the TV answers on.
  final String host;

  /// Manufacturer.
  final String manufacturer;

  /// Model.
  final String model;

  /// The one driver this TV uses.
  final String driverId;

  /// The driver's human protocol name.
  final String protocol;

  /// Whether the driver needs pairing.
  final bool requiresPairing;

  /// What the TV can do.
  final List<CapabilitySupport> capabilities;

  /// Installed apps and inputs.
  final List<AppInfo> apps;

  /// Keys the protocol cannot send.
  final Set<RemoteKey> unsupportedKeys;

  /// The launcher, shown as the foreground app after Home.
  final AppInfo home;

  /// Whether the TV reports its power and foreground app (Roku device-info
  /// and active-app) or watchme can only infer them from what it sent.
  final bool reportsState;

  /// Settings the user may need to change on the TV.
  final List<SetupStep> setup;

  /// Media actions the protocol has.
  final Set<MediaAction> mediaActions;

  /// Media actions the TV answers with an error.
  final Set<MediaAction> refusedMedia;

  /// Whether a pairing has succeeded.
  bool paired = false;

  /// Power mode.
  PowerMode power = PowerMode.on;

  /// Mute state as last toggled.
  bool muted = false;

  /// Selected input id, if one was chosen.
  String? input;

  /// The app in the foreground.
  AppInfo foreground;

  /// Playback state of the foreground app.
  PlaybackState playback = PlaybackState.stopped;

  /// When the TV last answered.
  DateTime lastSeen;

  /// When the simulated state last changed.
  DateTime stateAt;

  /// Whether the TV accepts commands now.
  bool get connected => !requiresPairing || paired;

  /// The TV as the UI sees it.
  DeviceView view() {
    final source = driverId;
    final connection = connected
        ? ConnectionState.connected
        : ConnectionState.disconnected;
    Observed<T> observed<T>(T value, {bool reported = true}) => reported
        ? Observed.reported(value, source, stateAt)
        : Observed.inferred(value, source, stateAt);
    return DeviceView(
      id: id,
      name: name,
      host: host,
      manufacturer: manufacturer,
      model: model,
      drivers: [
        DriverView(
          driverId: driverId,
          protocol: protocol,
          requiresPairing: requiresPairing,
          paired: paired,
          connection: connection,
          setup: setup,
        ),
      ],
      capabilities: capabilities,
      state: connected
          ? DeviceState(
              power: observed(power, reported: reportsState),
              muted: observed(muted, reported: false),
              input: switch (input) {
                null => null,
                final id => observed(id),
              },
              foregroundApp: observed(foreground, reported: reportsState),
              nowPlaying: capabilities.supportFor(Capability.nowPlaying).usable
                  ? observed(NowPlaying(state: playback, appId: foreground.id))
                  : null,
              connections: {driverId: connection},
            )
          : DeviceState(connections: {driverId: connection}),
      lastSeen: lastSeen,
    );
  }

  /// Runs [command] against the simulated TV at time [now].
  CommandResult execute(Command command, DateTime now) {
    if (!connected) {
      return const Failed(
        WatchmeError.unauthorized(
          'Pair with this TV first.',
          rawDeviceMessage: 'HTTP 401 Unauthorized (simulated)',
        ),
      );
    }
    final support = capabilities.supportFor(command.capability);
    if (!support.usable) {
      return Unsupported('$protocol cannot do ${command.capability.name}.');
    }
    lastSeen = now;
    final result = _apply(command);
    if (result.delivered) stateAt = now;
    return result;
  }

  CommandResult _apply(Command command) => switch (command) {
    PressKey(key: final key) when unsupportedKeys.contains(key) => Unsupported(
      '$protocol has no ${key.name} key.',
    ),
    // As in the engine, the power key is a toggle intent, not a key press.
    PressKey(key: RemoteKey.power, action: KeyAction.click) => _togglePower(),
    PressKey(key: RemoteKey.power) => const Unsupported(
      'The power key toggles; it cannot be held.',
    ),
    PressKey(:final key, action: KeyAction.click) => _click(key),
    PressKey() => const Confirmed(),
    // A discrete route exists for both TVs, so a confirmed command needs
    // no toggle.
    SetPower(:final on) => _setPower(on),
    SetMute(:final muted) => _setMute(muted ?? !this.muted),
    StepVolume() => const Confirmed(),
    SetVolume() => const Unsupported(
      'This TV can only step the volume up or down.',
    ),
    ListApps() => Confirmed(payload: AppListPayload(apps)),
    LaunchApp(:final appId) => _launch(appId),
    TypeText() =>
      // Text lands only if an on-screen keyboard is open, which the TV does
      // not report.
      const SentUnconfirmed(),
    SelectInput(:final inputId) => _selectInput(inputId),
    TuneChannel() => const Confirmed(),
    Media(:final action) => _media(action),
    _ => Unsupported('The demo does not simulate ${command.type}.'),
  };

  CommandResult _click(RemoteKey key) {
    switch (key) {
      case RemoteKey.home:
        foreground = home;
        playback = PlaybackState.stopped;
      case RemoteKey.mute:
        muted = !muted;
      case RemoteKey.powerOn:
        power = PowerMode.on;
      case RemoteKey.powerOff:
        power = PowerMode.standby;
      case RemoteKey.play || RemoteKey.pause || RemoteKey.playPause:
        return _media(MediaAction.playPause);
      default:
        break;
    }
    return const Confirmed();
  }

  /// The engine's answer to the power key. It turns the TV the other way
  /// only when at least two independent sources agree on the TV's state,
  /// and each demo TV has one: its own driver (the Roku reports its power
  /// state, the Fire TV cannot). So, as the engine would, it asks the user,
  /// who answers with a confirmed [SetPower].
  CommandResult _togglePower() =>
      const Unsupported(Unsupported.needsConfirmation);

  CommandResult _setPower(bool on) {
    power = on ? PowerMode.on : PowerMode.standby;
    return const Confirmed();
  }

  CommandResult _setMute(bool value) {
    muted = value;
    return const Confirmed();
  }

  CommandResult _launch(String appId) {
    for (final app in apps) {
      if (app.id == appId) {
        foreground = app;
        playback = PlaybackState.stopped;
        if (app.kind == AppKind.input) input = app.id;
        return const Confirmed();
      }
    }
    return Failed(
      WatchmeError.rejected(
        'The TV has no app $appId.',
        rawDeviceMessage: 'HTTP 404 Not Found (simulated)',
      ),
    );
  }

  CommandResult _selectInput(String inputId) {
    input = inputId;
    return const Confirmed();
  }

  CommandResult _media(MediaAction action) {
    if (!mediaActions.contains(action)) {
      return Unsupported('$protocol has no ${action.name} media command.');
    }
    if (refusedMedia.contains(action)) {
      return Failed(
        WatchmeError.rejected(
          'The TV refused the ${action.name} request.',
          rawDeviceMessage: 'HTTP 400 Bad Request (simulated)',
        ),
      );
    }
    if (action
        case MediaAction.play || MediaAction.pause || MediaAction.playPause) {
      playback = playback == PlaybackState.playing
          ? PlaybackState.paused
          : PlaybackState.playing;
    }
    return const Confirmed();
  }
}
