import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'capabilities.dart';
import 'ecp_client.dart';
import 'ecp_xml.dart';
import 'keys.dart';

/// The driver id of the Roku ECP driver and the source of its observations.
const String rokuDriverId = 'roku.ecp';

/// The store id of Media Assistant (Apache-2.0), the receiver channel
/// `CastUrl` launches by default. Roku's own Play on Roku (15985) was locked
/// down in Roku OS 11.5.
const String mediaAssistantAppId = '782875';

/// How often a session polls power mode, foreground app and media player
/// while someone listens to its events, unless configured otherwise.
const Duration rokuDefaultPollInterval = Duration(seconds: 5);

/// How many `Backspace` presses `TypeText(replace: true)` sends before
/// typing, unless configured otherwise. ECP cannot read or clear a text
/// field, so this is a bound on the length it can replace.
const int rokuDefaultReplaceBackspaces = 32;

/// The most volume steps one `StepVolume` sends.
const int rokuMaxVolumeSteps = 100;

/// The longest text one `TypeText` sends. ECP types one character per
/// request, in the session's single command queue, so a long paste would
/// hold up every other command (Back, power off) for minutes.
const int rokuMaxTextRunes = 256;

/// A session with one Roku over ECP.
///
/// ECP is stateless HTTP, so "connected" means the device answered its last
/// request. While anyone listens to [events], the session polls
/// device-info, the foreground app and the media player every poll
/// interval. It emits [StateChanged] for the fields whose value or
/// confidence changed ([state] always carries the latest observation
/// times), [ConnectionChanged] when the device stops or resumes answering,
/// and [CapabilitiesChanged] when the "Control by mobile apps" level turns
/// out to differ (for example a key press answered
/// `ECP command not allowed in Limited mode.`).
///
/// Commands run one at a time in the order given, so key presses and text
/// arrive in order. [close] stops a command in progress before its next
/// request. A command sent as several requests (volume steps, typed
/// characters, backspaces) that fails after one of them took effect
/// reports [WatchmeErrorCode.partiallyDelivered], never
/// [WatchmeErrorCode.unreachable]: sending it again would repeat what was
/// delivered.
final class RokuSession implements DriverSession {
  RokuSession._(
    this._client,
    this._info,
    this._clock,
    this._pollInterval,
    this._replaceBackspaces,
    this._castReceiverAppId,
  ) : _access = _info.ecpAccess {
    _caps = rokuCapabilities(_info, _access);
    _events = StreamController<DeviceEvent>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  /// Reads device-info from [endpoint] and opens a session.
  ///
  /// Also reads the foreground app and the media player when the device is
  /// awake, which tells whether "Control by mobile apps" is Enabled.
  ///
  /// Throws [WatchmeError]: [WatchmeErrorCode.unreachable] or
  /// [WatchmeErrorCode.timeout] when nothing answers,
  /// [WatchmeErrorCode.rejected] when the Roku refuses device-info (ECP
  /// disabled, or addressed by a host name), [WatchmeErrorCode.protocol]
  /// when the answer is not Roku device-info, and
  /// [WatchmeErrorCode.unsupported] without a network transport.
  static Future<RokuSession> connect(
    Endpoint endpoint,
    Transports transports, {
    Clock clock = const SystemClock(),
    Duration? pollInterval = rokuDefaultPollInterval,
    Duration requestTimeout = const Duration(seconds: 5),
    int replaceBackspaces = rokuDefaultReplaceBackspaces,
    String? castReceiverAppId = mediaAssistantAppId,
  }) async {
    final client = EcpClient(endpoint, transports, timeout: requestTimeout);
    final r = await client.get('/query/device-info');
    if (!r.ok) throw client.errorFor(r, 'query/device-info');
    final session = RokuSession._(
      client,
      _parseDeviceInfo(r),
      clock,
      pollInterval,
      replaceBackspaces,
      castReceiverAppId,
    );
    await session._absorb(session._info);
    return session;
  }

  final EcpClient _client;
  final Clock _clock;
  final Duration? _pollInterval;
  final int _replaceBackspaces;
  final String? _castReceiverAppId;

  RokuDeviceInfo _info;
  RokuEcpAccess _access;
  late List<CapabilitySupport> _caps;
  late final StreamController<DeviceEvent> _events;
  DeviceState _state = const DeviceState(
    connections: {rokuDriverId: ConnectionState.connected},
  );
  ConnectionState _connection = ConnectionState.connected;
  List<AppInfo> _apps = const [];
  Future<void> _tail = Future.value();
  Timer? _pollTimer;
  bool _polling = false;
  bool _closed = false;

  /// ECP commands of the running command that the device accepted.
  int _delivered = 0;

  @override
  String get driverId => rokuDriverId;

  @override
  List<CapabilitySupport> get capabilities => List.unmodifiable(_caps);

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  /// The device-info read most recently.
  RokuDeviceInfo get deviceInfo => _info;

  /// The "Control by mobile apps" level as far as the session knows.
  RokuEcpAccess get access => _access;

  /// The endpoint this session talks to.
  Endpoint get endpoint => _client.endpoint;

  // ------------------------------------------------------------- commands

  @override
  Future<CommandResult> execute(Command command) {
    final result = _tail.then((_) => _execute(command));
    _tail = result.then<void>((_) {});
    return result;
  }

  Future<CommandResult> _execute(Command command) async {
    if (_closed) return const Failed(_closedError);
    _delivered = 0;
    try {
      return await switch (command) {
        PressKey(:final key, :final action) => _pressKey(key, action),
        SetPower(:final on) => _setPower(on),
        SetVolume() => Future.value(
          const Unsupported(
            'Roku ECP has no absolute volume; use StepVolume '
            '(VolumeUp/VolumeDown keys)',
          ),
        ),
        StepVolume(:final steps) => _stepVolume(steps),
        SetMute(:final muted) => _setMute(muted),
        final LaunchApp c => _launch(c),
        ListApps() => _listApps(),
        SelectInput(:final inputId) => _selectInput(inputId),
        TuneChannel(:final channel) => _tune(channel),
        TypeText(:final text, :final replace) => _typeText(text, replace),
        Media(:final action) => _media(action),
        MovePointer() => Future.value(_unsupportedCap(Capability.pointer)),
        ShowToast() => Future.value(
          _unsupportedCap(Capability.notificationToast),
        ),
        final CastUrl c => _cast(c),
        TakeScreenshot() => Future.value(
          _unsupportedCap(Capability.screenshot),
        ),
      };
    } on WatchmeError catch (e) {
      return Failed(_failure(command, e));
    } on Object catch (e) {
      return Failed(
        _failure(
          command,
          WatchmeError.internal('Roku driver failed on $command: $e', cause: e),
        ),
      );
    }
  }

  /// The error of a command that stopped with [error]: [error] itself while
  /// none of its ECP commands took effect, otherwise
  /// [WatchmeErrorCode.partiallyDelivered] with [error] as the cause.
  WatchmeError _failure(Command command, WatchmeError error) =>
      _delivered == 0 || error.code == WatchmeErrorCode.partiallyDelivered
      ? error
      : WatchmeError.partiallyDelivered(
          'Roku ${command.type} stopped after $_delivered of its requests '
          'reached the device: ${error.message}',
          rawDeviceMessage: error.rawDeviceMessage,
          cause: error,
        );

  Future<CommandResult> _pressKey(RemoteKey key, KeyAction action) async {
    if (key == RemoteKey.play || key == RemoteKey.pause) {
      // Roku has only the Play toggle: a discrete play or pause reads the
      // player first, and a toggle cannot be held as one.
      if (action != KeyAction.click) {
        return Unsupported(
          'Roku has only a play/pause toggle, so ${key.name} cannot be held',
        );
      }
      return _media(
        key == RemoteKey.play ? MediaAction.play : MediaAction.pause,
      );
    }
    final name = rokuKeyNames[key];
    if (name == null) {
      return Unsupported('Roku ECP has no ${key.name} key');
    }
    if (key == RemoteKey.power && action != KeyAction.click) {
      // The engine refuses these too; a toggle held down means nothing.
      return const Unsupported(
        'The Roku Power key is a toggle, so it cannot be held',
      );
    }
    if (_gate(key.capability) case final refused?) return refused;
    await _command('/${rokuKeyVerb(action)}/$name');
    if (action != KeyAction.up) _inferFromKey(key);
    return const Confirmed();
  }

  Future<CommandResult> _setPower(bool on) async {
    if (_gate(on ? Capability.powerOn : Capability.powerOff)
        case final refused?) {
      return refused;
    }
    await _command('/keypress/${on ? 'PowerOn' : 'PowerOff'}');
    _inferFromKey(on ? RemoteKey.powerOn : RemoteKey.powerOff);
    return const Confirmed();
  }

  Future<CommandResult> _stepVolume(int steps) async {
    if (_gate(Capability.volume) case final refused?) return refused;
    if (steps.abs() > rokuMaxVolumeSteps) {
      return Unsupported('At most $rokuMaxVolumeSteps volume steps at a time');
    }
    final key = steps > 0 ? 'VolumeUp' : 'VolumeDown';
    for (var i = 0; i < steps.abs(); i++) {
      await _command('/keypress/$key');
    }
    return const Confirmed();
  }

  Future<CommandResult> _setMute(bool? muted) async {
    if (_gate(Capability.mute) case final refused?) return refused;
    if (muted != null) {
      return const Unsupported(
        'Roku has only a mute toggle and cannot read the mute state; send '
        'SetMute(null) to toggle',
      );
    }
    await _command('/keypress/VolumeMute');
    return const Confirmed();
  }

  Future<CommandResult> _launch(LaunchApp c) async {
    if (_gate(Capability.appLaunch) case final refused?) return refused;
    if (c.deepLink != null) {
      return const Unsupported(
        'Roku deep links are launch parameters; pass contentId and '
        'mediaType in LaunchApp.params instead of a deepLink URI',
      );
    }
    final appId = c.appId.trim();
    if (appId.isEmpty) return const Unsupported('LaunchApp needs an app id');
    await _command(
      '/launch/${Uri.encodeComponent(appId)}',
      query: c.params,
      gated: false,
    );
    _inferForeground(appId);
    return const Confirmed();
  }

  Future<CommandResult> _listApps() async {
    if (_gate(Capability.appList) case final refused?) return refused;
    final text = await _query('/query/apps');
    try {
      _apps = parseRokuApps(text, iconBase: _client.baseUri);
    } on FormatException catch (e) {
      throw WatchmeError.protocol(
        'Roku sent a malformed app list',
        rawDeviceMessage: text,
        cause: e,
      );
    }
    return Confirmed(payload: AppListPayload(List.unmodifiable(_apps)));
  }

  Future<CommandResult> _selectInput(String inputId) async {
    if (_gate(Capability.inputSwitch) case final refused?) return refused;
    final id = inputId.trim();
    final lower = id.toLowerCase();
    if (lower == rokuAppsInputId || lower == rokuHomeAppId) {
      await _command('/keypress/Home');
      _inferFromKey(RemoteKey.home);
      return const Confirmed();
    }
    if (rokuInputKey(lower) case final key?) {
      await _command('/keypress/$key');
      _inferInput(_inputIdForKey(key));
      return const Confirmed();
    }
    if (lower.startsWith('tvinput.')) {
      await _command('/launch/${Uri.encodeComponent(id)}', gated: false);
      _inferForeground(id);
      return const Confirmed();
    }
    return Unsupported(
      'Unknown Roku input "$inputId"; use hdmi1-hdmi4, av1, tuner, '
      '$rokuAppsInputId, or a tvinput.* id from the app list',
    );
  }

  Future<CommandResult> _tune(String channel) async {
    if (_gate(Capability.channel) case final refused?) return refused;
    final ch = channel.trim();
    if (ch.isEmpty) return const Unsupported('TuneChannel needs a channel');
    await _command('/launch/tvinput.dtv', query: {'ch': ch}, gated: false);
    _inferForeground('tvinput.dtv');
    return const Confirmed();
  }

  Future<CommandResult> _typeText(String text, bool replace) async {
    if (_gate(Capability.textInput) case final refused?) return refused;
    if (text.runes.length > rokuMaxTextRunes) {
      return Unsupported(
        'Roku types one character per request; send at most '
        '$rokuMaxTextRunes characters at a time',
      );
    }
    if (replace) {
      for (var i = 0; i < _replaceBackspaces; i++) {
        await _command('/keypress/Backspace');
      }
    }
    // Each key goes through _request, which stops at close(); what was
    // typed by then makes the failure a partial delivery.
    for (final key in rokuLiteralKeys(text)) {
      await _command('/keypress/$key');
    }
    return const Confirmed();
  }

  Future<CommandResult> _media(MediaAction action) async {
    if (_gate(Capability.mediaTransport) case final refused?) return refused;
    final key = switch (action) {
      MediaAction.playPause => 'Play',
      MediaAction.rewind => 'Rev',
      MediaAction.fastForward => 'Fwd',
      MediaAction.instantReplay => 'InstantReplay',
      _ => null,
    };
    if (key != null) {
      await _command('/keypress/$key');
      return const Confirmed();
    }
    return switch (action) {
      MediaAction.play => _discretePlay(play: true),
      MediaAction.pause => _discretePlay(play: false),
      _ => Unsupported('Roku ECP has no ${action.name} command'),
    };
  }

  // Roku has one play/pause toggle; read the player first so a "pause" never
  // resumes and a "play" never pauses.
  Future<CommandResult> _discretePlay({required bool play}) async {
    final text = await _query('/query/media-player');
    final RokuMediaPlayer player;
    try {
      player = RokuMediaPlayer.parse(text);
    } on FormatException catch (e) {
      throw WatchmeError.protocol(
        'Roku sent a malformed media-player state',
        rawDeviceMessage: text,
        cause: e,
      );
    }
    _emitState(
      _state.copyWith(
        nowPlaying: Observed.reported(
          player.toNowPlaying(),
          rokuDriverId,
          _clock.now(),
        ),
      ),
    );
    final playing = switch (player.playbackState) {
      PlaybackState.playing || PlaybackState.buffering => true,
      PlaybackState.paused => false,
      _ => null,
    };
    if (playing == null) {
      return Unsupported(
        'Roku has only a play/pause toggle and its player is '
        '"${player.state}", so there is nothing to ${play ? 'resume' : 'pause'}',
      );
    }
    if (playing != play) await _command('/keypress/Play');
    return const Confirmed();
  }

  Future<CommandResult> _cast(CastUrl c) async {
    if (_gate(Capability.castMediaUrl) case final refused?) return refused;
    final appId = _castReceiverAppId;
    if (appId == null) {
      return const Unsupported('No Roku receiver channel is configured');
    }
    final mime = c.mimeType?.toLowerCase() ?? '';
    await _command(
      '/launch/${Uri.encodeComponent(appId)}',
      query: {
        'u': c.url.toString(),
        't': mime.startsWith('audio/') ? 'a' : 'v',
      },
      gated: false,
    );
    _inferForeground(appId);
    return const Confirmed();
  }

  /// `Unsupported` when this device lacks [capability] for good (not merely
  /// because of the access setting, which may have changed since).
  Unsupported? _gate(Capability capability) {
    final s = _caps.supportFor(capability);
    if (s.level != Support.no || s.has(CapFlag.userSetupRequired)) return null;
    return Unsupported(s.note ?? 'Not supported by this Roku');
  }

  Unsupported _unsupportedCap(Capability capability) => Unsupported(
    _caps.supportFor(capability).note ?? 'Roku ECP cannot do this',
  );

  // ------------------------------------------------------------ requests

  static const _closedError = WatchmeError.cancelled('Roku session is closed');

  /// POSTs an ECP command; an accepted one counts towards what the running
  /// command delivered. A success of a [gated] command proves "Control by
  /// mobile apps" is Enabled.
  Future<void> _command(
    String path, {
    Map<String, String>? query,
    bool gated = true,
  }) async {
    final r = await _request(() => _client.post(path, query: query));
    if (!r.ok) throw _refused(r, path.substring(1));
    _delivered++;
    if (gated) _setAccess(RokuEcpAccess.enabled);
  }

  /// GETs a gated query and returns its body.
  Future<String> _query(String path) async {
    final r = await _request(() => _client.get(path));
    if (!r.ok) throw _refused(r, path.substring(1));
    _setAccess(RokuEcpAccess.enabled);
    return r.text;
  }

  /// Sends one request unless the session was closed meanwhile. Every
  /// request goes through here, so a command stops before its next request
  /// once [close] is called.
  Future<HttpResult> _request(Future<HttpResult> Function() send) async {
    if (_closed) throw _closedError;
    final HttpResult r;
    try {
      r = await send();
    } on WatchmeError catch (e) {
      _noteTransportError(e);
      rethrow;
    }
    _markReachable();
    return r;
  }

  WatchmeError _refused(HttpResult r, String what) {
    final refusal = rokuRefusal(r);
    if (refusal != null) _setAccess(refusal);
    if (refusal == null &&
        r.status == 403 &&
        _client.hostIsIpLiteral &&
        _state.power?.value == PowerMode.standby) {
      return r.toError(
        WatchmeErrorCode.rejected,
        'Roku refused $what while in standby; turn it on first',
      );
    }
    return _client.errorFor(r, what);
  }

  // --------------------------------------------------------------- state

  @override
  Future<DeviceState> refresh() async {
    final r = await _request(() => _client.get('/query/device-info'));
    if (!r.ok) throw _refused(r, 'query/device-info');
    await _absorb(_parseDeviceInfo(r));
    return _state;
  }

  static RokuDeviceInfo _parseDeviceInfo(HttpResult r) {
    try {
      return RokuDeviceInfo.parse(r.text);
    } on FormatException catch (e) {
      throw WatchmeError.protocol(
        'The device did not answer with Roku device-info',
        rawDeviceMessage: r.text,
        cause: e,
      );
    }
  }

  /// Takes in fresh device-info and, while the device is awake, the
  /// foreground app and media player; emits what changed.
  Future<void> _absorb(RokuDeviceInfo info) async {
    final devicePropertiesChanged =
        info.isTv != _info.isTv ||
        info.supportsTvPowerControl != _info.supportsTvPowerControl ||
        info.supportsAudioVolumeControl != _info.supportsAudioVolumeControl;
    _info = info;
    if (info.ecpAccess != RokuEcpAccess.unknown) {
      _setAccess(info.ecpAccess);
    } else if (devicePropertiesChanged) {
      _setCapabilities(rokuCapabilities(_info, _access));
    }
    final now = _clock.now();
    final power = Observed.reported(info.powerMode, rokuDriverId, now);
    if (power.value != PowerMode.on && power.value != PowerMode.screenOff) {
      // Asleep: the app and player are no longer current, and standby
      // refuses the queries that would say otherwise.
      _emitState(
        DeviceState(
          power: power,
          volume: _state.volume,
          muted: _state.muted,
          input: _state.input?.asStale(),
          foregroundApp: _state.foregroundApp?.asStale(),
          nowPlaying: _state.nowPlaying?.asStale(),
          connections: _state.connections,
        ),
      );
      return;
    }
    var next = _state.copyWith(power: power);
    final app = await _tryRead('/query/active-app', parseRokuActiveApp);
    if (app != null) {
      next = next.copyWith(
        foregroundApp: Observed.reported(app, rokuDriverId, now),
        input: info.isTv
            ? Observed.reported(_inputIdForApp(app), rokuDriverId, now)
            : null,
      );
    }
    final player = await _tryRead(
      '/query/media-player',
      RokuMediaPlayer.parse,
      gated: true,
    );
    if (player != null) {
      next = next.copyWith(
        nowPlaying: Observed.reported(player.toNowPlaying(), rokuDriverId, now),
      );
    }
    _emitState(next);
  }

  /// Reads an optional part of the state; failures leave it unknown.
  Future<T?> _tryRead<T>(
    String path,
    T Function(String xml) parse, {
    bool gated = false,
  }) async {
    final HttpResult r;
    try {
      r = await _request(() => _client.get(path));
    } on WatchmeError {
      return null;
    }
    if (!r.ok) {
      if (rokuRefusal(r) case final refusal?) _setAccess(refusal);
      return null;
    }
    if (gated) _setAccess(RokuEcpAccess.enabled);
    try {
      return parse(r.text);
    } on FormatException {
      return null;
    }
  }

  void _inferFromKey(RemoteKey key) {
    final now = _clock.now();
    switch (key) {
      case RemoteKey.powerOn:
        _emitState(
          _state.copyWith(
            power: Observed.inferred(PowerMode.on, rokuDriverId, now),
          ),
        );
      case RemoteKey.powerOff when _info.isTv:
        _emitState(
          _state.copyWith(
            power: Observed.inferred(PowerMode.standby, rokuDriverId, now),
          ),
        );
      case RemoteKey.home:
        _inferForeground(rokuHomeAppId);
      case RemoteKey.inputHdmi1 ||
          RemoteKey.inputHdmi2 ||
          RemoteKey.inputHdmi3 ||
          RemoteKey.inputHdmi4 ||
          RemoteKey.inputAv1 ||
          RemoteKey.inputTuner:
        _inferInput(_inputIdForKey(rokuKeyNames[key]!));
      default:
        break;
    }
  }

  void _inferForeground(String appId) {
    final now = _clock.now();
    final app =
        _apps.where((a) => a.id == appId).firstOrNull ??
        AppInfo(
          id: appId,
          name: appId == rokuHomeAppId ? 'Home' : appId,
          kind: appId == rokuHomeAppId
              ? AppKind.other
              : appId.toLowerCase().startsWith('tvinput.')
              ? AppKind.input
              : AppKind.app,
        );
    _emitState(
      _state.copyWith(
        foregroundApp: Observed.inferred(app, rokuDriverId, now),
        input: _info.isTv
            ? Observed.inferred(_inputIdForApp(app), rokuDriverId, now)
            : null,
      ),
    );
  }

  void _inferInput(String inputId) {
    if (!_info.isTv) return;
    _emitState(
      _state.copyWith(
        input: Observed.inferred(inputId, rokuDriverId, _clock.now()),
      ),
    );
  }

  static String _inputIdForApp(AppInfo app) =>
      app.kind == AppKind.input || app.id.toLowerCase().startsWith('tvinput.')
      ? rokuInputIdForApp(app.id)
      : rokuAppsInputId;

  static String _inputIdForKey(String key) => switch (key) {
    'InputTuner' => 'tuner',
    'InputAV1' => 'av1',
    _ => key.substring('Input'.length).toLowerCase(),
  };

  /// Adopts [next] (with its fresh observation times) and emits the fields
  /// whose value or confidence changed. Comparing whole observations would
  /// report every poll as a change, because each poll re-stamps `at`.
  void _emitState(DeviceState next) {
    final previous = _state;
    _state = next;
    Observed<T>? changed<T>(Observed<T>? now, Observed<T>? before) =>
        now == null ||
            (before != null &&
                now.value == before.value &&
                now.confidence == before.confidence)
        ? null
        : now;
    final diff = DeviceState(
      power: changed(next.power, previous.power),
      volume: changed(next.volume, previous.volume),
      muted: changed(next.muted, previous.muted),
      input: changed(next.input, previous.input),
      foregroundApp: changed(next.foregroundApp, previous.foregroundApp),
      nowPlaying: changed(next.nowPlaying, previous.nowPlaying),
      connections: next.changesSince(previous).connections,
    );
    if (!diff.isEmpty) _emit(StateChanged(diff, driverId: rokuDriverId));
  }

  void _setAccess(RokuEcpAccess access) {
    if (access == _access) return;
    _access = access;
    _setCapabilities(rokuCapabilities(_info, access));
  }

  void _setCapabilities(List<CapabilitySupport> caps) {
    final same =
        caps.length == _caps.length &&
        [for (var i = 0; i < caps.length; i++) caps[i] == _caps[i]]
            .every((e) => e);
    if (same) return;
    _caps = caps;
    _emit(CapabilitiesChanged(List.unmodifiable(caps), driverId: rokuDriverId));
  }

  void _noteTransportError(WatchmeError e) {
    if (e.code != WatchmeErrorCode.unreachable &&
        e.code != WatchmeErrorCode.timeout) {
      return;
    }
    if (_connection != ConnectionState.connected) return;
    _connection = ConnectionState.disconnected;
    _emitState(
      _state.markStale().copyWith(
        connections: {
          ..._state.connections,
          rokuDriverId: ConnectionState.disconnected,
        },
      ),
    );
    _emit(
      ConnectionChanged(
        ConnectionState.disconnected,
        driverId: rokuDriverId,
        error: e,
      ),
    );
  }

  void _markReachable() {
    if (_connection == ConnectionState.connected || _closed) return;
    _connection = ConnectionState.connected;
    _emitState(
      _state.copyWith(
        connections: {
          ..._state.connections,
          rokuDriverId: ConnectionState.connected,
        },
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.connected,
        driverId: rokuDriverId,
      ),
    );
  }

  void _emit(DeviceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // ------------------------------------------------------------- polling

  void _startPolling() {
    final interval = _pollInterval;
    if (interval == null || _closed || _pollTimer != null) return;
    _pollTimer = _clock.periodic(interval, (_) => unawaited(_poll()));
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    if (_polling || _closed) return;
    _polling = true;
    try {
      await refresh();
    } on Object {
      // Failures surface as ConnectionChanged / CapabilitiesChanged events.
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopPolling();
    _connection = ConnectionState.disconnected;
    _state = _state.copyWith(
      connections: {
        ..._state.connections,
        rokuDriverId: ConnectionState.disconnected,
      },
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.disconnected,
        driverId: rokuDriverId,
      ),
    );
    await _events.close();
  }
}
