import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'api.dart';
import 'constants.dart';
import 'descriptor.dart';

/// A connected Fire TV remote-API session, created by `FireTvDriver.connect`.
///
/// Commands run one at a time, in order, so a `keyDown` always reaches the
/// device before its `keyUp`. Every call pins the TLS certificate recorded
/// at pairing and sends the client token. A 401 or 403 means the token was
/// revoked or reset: the session emits [ReauthRequired] and returns
/// [Failed] with [WatchmeErrorCode.reauthRequired].
///
/// A Fire TV closes its API port whenever it sleeps, including on its own
/// inactivity timer, so the session outlives the port. A command that finds
/// the port closed wakes the device through DIAL once, waits for the API
/// and is sent again, as pressing a key on a sleeping device means
/// (hms-firetv does the same). `SetPower(false)` and [refresh] never wake
/// it: they check the DIAL server instead and report the device asleep.
final class FireTvSession implements DriverSession {
  /// Wraps an authenticated [api] (used by the driver after connecting).
  FireTvSession(
    this._api,
    this._clock, {
    this.status,
    this.apiStartupTimeout = const Duration(seconds: 6),
    this.apiPollInterval = const Duration(milliseconds: 500),
  }) : _state = DeviceState(
         power: Observed.inferred(PowerMode.on, fireTvDriverId, _clock.now()),
         connections: const {fireTvDriverId: ConnectionState.connected},
       );

  final FireTvApi _api;
  final Clock _clock;
  final StreamController<DeviceEvent> _events = StreamController.broadcast();
  final Map<String, String> _appNames = {};
  DeviceState _state;
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool _reauthReported = false;

  /// What `GET /v1/FireTV/status` reported at connect time, if anything.
  final FireTvStatus? status;

  /// How long `SetPower(true)` waits for the API port after the DIAL wake.
  final Duration apiStartupTimeout;

  /// How often it checks meanwhile.
  final Duration apiPollInterval;

  /// How long a scan asks the device to seek. LibreControl observed that the
  /// device treats it as a hint and keeps scanning until play/pause.
  static const String scanSeconds = '10';

  static const Map<RemoteKey, String> _keyActions = {
    RemoteKey.up: 'dpad_up',
    RemoteKey.down: 'dpad_down',
    RemoteKey.left: 'dpad_left',
    RemoteKey.right: 'dpad_right',
    RemoteKey.select: 'select',
    RemoteKey.home: 'home',
    RemoteKey.back: 'back',
    RemoteKey.menu: 'menu',
    RemoteKey.volumeUp: 'volume_up',
    RemoteKey.volumeDown: 'volume_down',
    RemoteKey.mute: 'mute',
    // A toggle: LibreControl confirmed on hardware that it turns the
    // connected TV off over HDMI-CEC. It reports no state.
    RemoteKey.power: 'power',
  };

  // Press-and-hold is documented for the d-pad and select only.
  static const Set<RemoteKey> _holdable = {
    RemoteKey.up,
    RemoteKey.down,
    RemoteKey.left,
    RemoteKey.right,
    RemoteKey.select,
  };

  // Keyboard states LibreControl treats as open; `visible` and `text` were
  // observed on hardware.
  static const Set<String> _keyboardOpenStates = {
    'visible',
    'text',
    'active',
    'shown',
  };

  @override
  String get driverId => fireTvDriverId;

  @override
  List<CapabilitySupport> get capabilities => fireTvDescriptor.ceiling;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  @override
  Future<CommandResult> execute(Command command) => _serial(() async {
    if (_closed) {
      return const Failed(
        WatchmeError.cancelled('The Fire TV session is closed'),
      );
    }
    try {
      return await _dispatch(command);
    } on WatchmeError catch (e) {
      return Failed(e);
    } on Object catch (e) {
      return Failed(
        WatchmeError.internal('Fire TV ${command.type} failed: $e', cause: e),
      );
    }
  });

  @override
  Future<DeviceState> refresh() => _serial(() async {
    if (_closed) {
      throw const WatchmeError.cancelled('The Fire TV session is closed');
    }
    final HttpResult result;
    try {
      result = await _api.get(FireTvPaths.status);
    } on WatchmeError catch (e) {
      // Passive: a closed API port is reported, never woken.
      if (!await _asleep(e)) rethrow;
      return _state;
    }
    if (isAuthFailure(result)) throw _reauth(result, 'Status');
    // Firmware without the status endpoint answers 404, which still shows
    // the API is up.
    if (!result.ok && result.status != 404) throw apiError(result, 'Status');
    // The API answers only while the device is awake.
    _setState(_state.copyWith(power: _observed(PowerMode.on)));
    return _state;
  });

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _setState(
      _state.copyWith(
        connections: const {fireTvDriverId: ConnectionState.disconnected},
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.disconnected,
        driverId: fireTvDriverId,
      ),
    );
    await _events.close();
  }

  Future<CommandResult> _dispatch(Command command) => switch (command) {
    PressKey(:final key, :final action) => _pressKey(key, action),
    SetPower(on: true) => _wake(),
    SetPower(on: false) => _sleep(),
    SetVolume() => _unsupported(
      'The Fire TV remote API only steps the volume; use StepVolume',
    ),
    StepVolume(:final steps) => _stepVolume(steps),
    SetMute(muted: null) => _action('mute', 'Mute'),
    SetMute() => _unsupported(
      'Fire TV mute is a toggle with no readable state; send SetMute(null)',
    ),
    LaunchApp() => _launch(command),
    ListApps() => _listApps(),
    SelectInput() => _unsupported('Fire TV has no input switching'),
    TuneChannel() => _unsupported('Fire TV has no channel tuning'),
    TypeText() => _typeText(command),
    Media() => _media(command.action),
    MovePointer() => _unsupported('The Fire TV remote API has no pointer'),
    ShowToast() => _unsupported('The Fire TV remote API cannot show toasts'),
    CastUrl() => _unsupported(
      'The Fire TV remote API cannot play URLs (Fire TV casts through '
      'Matter Casting)',
    ),
    TakeScreenshot() => _unsupported(
      'The Fire TV remote API cannot take screenshots',
    ),
  };

  Future<CommandResult> _pressKey(RemoteKey key, KeyAction action) {
    final click = action == KeyAction.click;
    if (!click && !_holdable.contains(key)) {
      return _unsupported(
        'Fire TV press-and-hold works only for the d-pad and select, '
        'not ${key.name}',
      );
    }
    switch (key) {
      case RemoteKey.powerOn:
        return _wake();
      case RemoteKey.powerOff:
        return _sleep();
      case RemoteKey.playPause:
        return _media(MediaAction.playPause);
      case RemoteKey.play:
        return _media(MediaAction.play);
      case RemoteKey.pause:
        return _media(MediaAction.pause);
      case RemoteKey.fastForward:
        return _media(MediaAction.fastForward);
      case RemoteKey.rewind:
        return _media(MediaAction.rewind);
      default:
        final mapped = _keyActions[key];
        if (mapped == null) {
          return _unsupported('No Fire TV remote action for ${key.name}');
        }
        return _action(
          mapped,
          'Key ${key.name}',
          keyActionType: switch (action) {
            KeyAction.click => null,
            KeyAction.down => 'keyDown',
            KeyAction.up => 'keyUp',
          },
        );
    }
  }

  /// A remote action: no body for a press, a `keyActionType` body for one
  /// edge of a hold.
  Future<CommandResult> _action(
    String action,
    String what, {
    String? keyActionType,
  }) async {
    await _call(
      () => _api.post(
        FireTvPaths.action,
        action: action,
        json: keyActionType == null ? null : {'keyActionType': keyActionType},
      ),
      what,
    );
    return const Confirmed();
  }

  Future<CommandResult> _wake() async {
    final result = await _api.wake();
    if (!FireTvApi.wakeStatuses.contains(result.status)) {
      throw wakeError(result);
    }
    _setState(_state.copyWith(power: _observed(PowerMode.on)));
    // Let the API port open so the next command does not find it closed.
    // The DIAL server already acknowledged the wake, so a slow start is not
    // a failure of this command.
    try {
      await _untilListening();
    } on WatchmeError {
      // Reported by the next command if it persists.
    }
    return const Confirmed();
  }

  Future<CommandResult> _sleep() async {
    try {
      await _call(
        () => _api.post(FireTvPaths.action, action: 'sleep'),
        'Sleep',
        wakeIfAsleep: false,
      );
    } on WatchmeError catch (e) {
      // Already asleep: waking it to send "sleep" would turn the TV on over
      // HDMI-CEC for nothing.
      if (!await _asleep(e)) rethrow;
      return const Confirmed();
    }
    _setState(_state.copyWith(power: _observed(PowerMode.standby)));
    return const Confirmed();
  }

  /// Whether [error] (from an API call) means the device is asleep: the API
  /// port refused the connection while the DIAL server answers. Records
  /// standby when it is. Passive: DIAL `GET` never launches anything.
  Future<bool> _asleep(WatchmeError error) async {
    if (error.code != WatchmeErrorCode.unreachable) return false;
    try {
      await _api.dialStatus();
    } on WatchmeError {
      return false;
    }
    _setState(_state.copyWith(power: _observed(PowerMode.standby)));
    return true;
  }

  Future<void> _untilListening() => untilListening(
    (timeout) => _api.get(FireTvPaths.status, timeout: timeout),
    clock: _clock,
    timeout: apiStartupTimeout,
    interval: apiPollInterval,
    cancelled: () => _closed,
  );

  /// Upper bound on [StepVolume] presses, so a bad value cannot flood the
  /// device.
  static const int maxVolumeSteps = 100;

  Future<CommandResult> _stepVolume(int steps) async {
    if (steps.abs() > maxVolumeSteps) {
      return Unsupported('At most $maxVolumeSteps volume steps at once');
    }
    final action = steps > 0 ? 'volume_up' : 'volume_down';
    for (var i = 0; i < steps.abs(); i++) {
      await _action(action, 'Volume step ${i + 1} of ${steps.abs()}');
    }
    return const Confirmed();
  }

  Future<CommandResult> _launch(LaunchApp command) async {
    if (command.deepLink != null || command.params.isNotEmpty) {
      return Unsupported(
        'Fire TV app launch takes no deep link or parameters '
        '(${command.appId})',
      );
    }
    final package = command.appId;
    if (!androidPackage.hasMatch(package)) {
      return Unsupported(
        'Fire TV app ids are Android package names, not "$package"',
      );
    }
    await _call(
      () => _api.post('${FireTvPaths.appLaunchPrefix}$package'),
      'Launch $package',
    );
    final app = AppInfo(id: package, name: _appNames[package] ?? package);
    _setState(
      _state.copyWith(
        foregroundApp: Observed.inferred(app, fireTvDriverId, _clock.now()),
      ),
    );
    return const Confirmed();
  }

  Future<CommandResult> _listApps() async {
    final result = await _call(() => _api.get(FireTvPaths.apps), 'App list');
    final apps = parseApps(result);
    _appNames
      ..clear()
      ..addEntries(apps.map((a) => MapEntry(a.id, a.name)));
    return Confirmed(payload: AppListPayload(apps));
  }

  Future<CommandResult> _typeText(TypeText command) async {
    if (command.replace) {
      return _unsupported(
        'The Fire TV keyboard endpoint cannot replace the field content',
      );
    }
    if (command.text.isEmpty) return const Confirmed();
    // LibreControl checks the keyboard first so text never goes nowhere. A
    // firmware without the read endpoint still gets the write.
    final keyboard = await _awake(() => _api.get(FireTvPaths.keyboard));
    if (isAuthFailure(keyboard)) throw _reauth(keyboard, 'Keyboard state');
    if (keyboard.ok) {
      final state = _keyboardState(keyboard);
      if (state != null && !_keyboardOpenStates.contains(state)) {
        throw WatchmeError.rejected(
          'The Fire TV on-screen keyboard is not open',
          rawDeviceMessage: keyboard.text,
        );
      }
    }
    await _call(
      () => _api.post(FireTvPaths.keyboard, json: {'text': command.text}),
      'Text input',
    );
    return const Confirmed();
  }

  Future<CommandResult> _media(MediaAction action) async {
    final (String, String, Object?, Map<String, String>?)? request =
        switch (action) {
          MediaAction.playPause => ('Play/pause', 'play', null, null),
          MediaAction.fastForward => (
            'Scan forward',
            'scan',
            _scan('forward'),
            null,
          ),
          // The official app sends `back` (hms-firetv, from its request
          // log, as a query parameter); `backward` in the body was refused
          // with HTTP 400 on hardware (LibreControl). Both carry `back`, in
          // the body shape a forward scan was accepted in.
          MediaAction.rewind => (
            'Scan backward',
            'scan',
            _scan('back'),
            const {'direction': 'back'},
          ),
          _ => null,
        };
    if (request == null) {
      return Unsupported(
        action == MediaAction.play || action == MediaAction.pause
            ? 'Fire TV has only a play/pause toggle; use playPause'
            : 'The Fire TV remote API cannot ${action.name}',
      );
    }
    final (what, mediaAction, body, query) = request;
    await _call(
      () => _api.post(
        FireTvPaths.media,
        action: mediaAction,
        query: query,
        json: body,
      ),
      what,
    );
    return const Confirmed();
  }

  static Map<String, String> _scan(String direction) => {
    'direction': direction,
    'durationInSeconds': scanSeconds,
    'speed': '1',
  };

  static String? _keyboardState(HttpResult result) {
    try {
      return switch (result.json()) {
        {'state': final String s} => s.toLowerCase(),
        _ => null,
      };
    } on WatchmeError {
      return null;
    }
  }

  /// Runs [request] and turns a non-2xx answer into a thrown error,
  /// reporting a refused token on the way. With [wakeIfAsleep], a device
  /// that went to sleep under the session is woken and [request] sent once
  /// more (see [_awake]).
  Future<HttpResult> _call(
    Future<HttpResult> Function() request,
    String what, {
    bool wakeIfAsleep = true,
  }) async {
    final result = wakeIfAsleep ? await _awake(request) : await request();
    if (result.ok) return result;
    if (isAuthFailure(result)) throw _reauth(result, what);
    throw apiError(result, what);
  }

  /// Runs [request]; if the API port refused it (`unreachable`, so nothing
  /// was delivered) the device has gone to sleep: wake it through DIAL,
  /// wait for the API and send [request] once more.
  Future<HttpResult> _awake(Future<HttpResult> Function() request) async {
    try {
      return await request();
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.unreachable || _closed) rethrow;
      final wakeFailure = await tryWake(_api);
      if (wakeFailure != null) throw withWakeContext(e, wakeFailure);
      await _untilListening();
      _setState(_state.copyWith(power: _observed(PowerMode.on)));
      return request();
    }
  }

  WatchmeError _reauth(HttpResult result, String what) {
    final error = apiError(result, what);
    if (!_reauthReported) {
      _reauthReported = true;
      _setState(
        _state.copyWith(
          connections: const {fireTvDriverId: ConnectionState.failed},
        ),
      );
      _emit(ReauthRequired(error, driverId: fireTvDriverId));
      _emit(
        ConnectionChanged(
          ConnectionState.failed,
          driverId: fireTvDriverId,
          error: error,
        ),
      );
    }
    return error;
  }

  Observed<PowerMode> _observed(PowerMode mode) =>
      Observed.inferred(mode, fireTvDriverId, _clock.now());

  void _setState(DeviceState next) {
    final diff = next.changesSince(_state);
    _state = next;
    if (!diff.isEmpty) _emit(StateChanged(diff, driverId: fireTvDriverId));
  }

  void _emit(DeviceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<CommandResult> _unsupported(String reason) =>
      Future.value(Unsupported(reason));

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
