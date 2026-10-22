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
/// (hms-firetv does the same). `SetPower(false)`, the end of a hold
/// (`keyUp`) and [refresh] never wake it: they check the DIAL server
/// instead and report the device asleep. A wake that may have reached the
/// device although it failed (a timeout) is reported as such, never as
/// [WatchmeErrorCode.unreachable].
/// When the DIAL server does not answer either, the device is gone: the
/// session marks its observations stale and emits [ConnectionChanged] with
/// [ConnectionState.disconnected].
///
/// [close] stops a command in progress before its next request. A command
/// sent as several requests (volume steps, a wake and a resend) that fails
/// after one of them took effect reports
/// [WatchmeErrorCode.partiallyDelivered], never
/// [WatchmeErrorCode.unreachable]. No error or event carries the client
/// token or the `X-Api-Key` value.
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

  /// Requests of the running command that took effect on the device.
  int _delivered = 0;

  static const WatchmeError _closedError = WatchmeError.cancelled(
    'The Fire TV session is closed',
  );

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
    if (_closed) return const Failed(_closedError);
    _delivered = 0;
    try {
      return await _dispatch(command);
    } on WatchmeError catch (e) {
      return Failed(_failure(command, e));
    } on Object catch (e) {
      return Failed(
        _failure(
          command,
          WatchmeError.internal('Fire TV ${command.type} failed: $e', cause: e),
        ),
      );
    }
  });

  /// The error of a command that stopped with [error], redacted: [error]
  /// itself while none of its requests took effect, otherwise
  /// [WatchmeErrorCode.partiallyDelivered] with [error] as the cause, since
  /// sending it again would repeat what was delivered.
  WatchmeError _failure(Command command, WatchmeError error) {
    final e = _api.redact(error);
    if (_delivered == 0 || e.code == WatchmeErrorCode.partiallyDelivered) {
      return e;
    }
    return WatchmeError.partiallyDelivered(
      'Fire TV ${command.type} stopped after $_delivered of its requests '
      'reached the device: ${e.message}',
      rawDeviceMessage: e.rawDeviceMessage,
      cause: e,
    );
  }

  /// Passive: never wakes the device. A closed API port next to a live DIAL
  /// server reports standby; with neither answering the device is gone
  /// (see [FireTvSession]).
  @override
  Future<DeviceState> refresh() => _serial(() async {
    try {
      final HttpResult result;
      try {
        result = await _send(() => _api.get(FireTvPaths.status));
      } on WatchmeError catch (e) {
        if (!await _asleep(e)) rethrow;
        return _state;
      }
      if (isAuthFailure(result)) throw _reauth(result, 'Status');
      // Firmware without the status endpoint answers 404, which still
      // shows the API is up.
      if (!result.ok && result.status != 404) {
        throw _api.errorFor(result, 'Status');
      }
      // The API answers only while the device is awake.
      _setState(_state.copyWith(power: _observed(PowerMode.on)));
      return _state;
    } on WatchmeError catch (e) {
      throw _api.redact(e);
    }
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
        if (action == KeyAction.up) return _release(mapped, key);
        return _action(
          mapped,
          'Key ${key.name}',
          keyActionType: action == KeyAction.down ? 'keyDown' : null,
        );
    }
  }

  /// A remote action: no body for a press, a `keyActionType` body for one
  /// edge of a hold.
  Future<CommandResult> _action(
    String action,
    String what, {
    String? keyActionType,
    bool wakeIfAsleep = true,
  }) async {
    await _call(
      () => _api.post(
        FireTvPaths.action,
        action: action,
        json: keyActionType == null ? null : {'keyActionType': keyActionType},
      ),
      what,
      wakeIfAsleep: wakeIfAsleep,
    );
    return const Confirmed();
  }

  /// The end of a hold (`keyUp`). It never wakes the device: apps send it
  /// on their own when they stop getting the key-up, and a sleeping device
  /// repeats no key, so a device found asleep has nothing to release.
  Future<CommandResult> _release(String action, RemoteKey key) async {
    try {
      return await _action(
        action,
        'Releasing ${key.name}',
        keyActionType: 'keyUp',
        wakeIfAsleep: false,
      );
    } on WatchmeError catch (e) {
      if (!await _asleep(e)) rethrow;
      return const Confirmed();
    }
  }

  Future<CommandResult> _wake() async {
    final result = await _send(_api.wake);
    if (!FireTvApi.wakeStatuses.contains(result.status)) {
      throw wakeError(result);
    }
    _delivered++;
    _setState(_state.copyWith(power: _observed(PowerMode.on)));
    // Let the API port open so the next command does not find it closed.
    // The DIAL server already acknowledged the wake, so a slow start (or a
    // close() meanwhile, which ends the wait) is not a failure of this
    // command: the wake was its only request.
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
  ///
  /// When the DIAL server is unreachable too, the device is gone: throws
  /// the error [_lost] reports.
  Future<bool> _asleep(WatchmeError error) async {
    if (error.code != WatchmeErrorCode.unreachable) return false;
    _checkOpen();
    try {
      await _api.dialStatus();
    } on WatchmeError catch (dial) {
      if (dial.code != WatchmeErrorCode.unreachable) return false;
      throw _lost(
        WatchmeError.unreachable(
          'Neither the Fire TV remote API nor its DIAL server answered',
          cause: error,
        ),
      );
    }
    _markReachable();
    _setState(_state.copyWith(power: _observed(PowerMode.standby)));
    return true;
  }

  /// The device stopped answering at all (API and DIAL unreachable): marks
  /// every observation stale, reports the session disconnected with
  /// [error] (once) and returns [error], redacted, for the caller to throw.
  WatchmeError _lost(WatchmeError error) {
    final e = _api.redact(error);
    if (!_closed &&
        _state.connections[fireTvDriverId] == ConnectionState.connected) {
      _setState(
        _state.markStale().copyWith(
          connections: const {fireTvDriverId: ConnectionState.disconnected},
        ),
      );
      _emit(
        ConnectionChanged(
          ConnectionState.disconnected,
          driverId: fireTvDriverId,
          error: e,
        ),
      );
    }
    return e;
  }

  /// The device answered again after [_lost].
  void _markReachable() {
    if (_closed ||
        _state.connections[fireTvDriverId] != ConnectionState.disconnected) {
      return;
    }
    _setState(
      _state.copyWith(
        connections: const {fireTvDriverId: ConnectionState.connected},
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.connected,
        driverId: fireTvDriverId,
      ),
    );
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
    final result = await _call(
      () => _api.get(FireTvPaths.apps),
      'App list',
      effect: false,
    );
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
  /// reporting a refused token on the way. A 2xx answer to a request with
  /// an [effect] counts towards what the command delivered. With
  /// [wakeIfAsleep], a device that went to sleep under the session is woken
  /// and [request] sent once more (see [_awake]).
  Future<HttpResult> _call(
    Future<HttpResult> Function() request,
    String what, {
    bool wakeIfAsleep = true,
    bool effect = true,
  }) async {
    final result = wakeIfAsleep ? await _awake(request) : await _send(request);
    if (result.ok) {
      if (effect) _delivered++;
      return result;
    }
    if (isAuthFailure(result)) throw _reauth(result, what);
    throw _api.errorFor(result, what);
  }

  /// Runs [request]; if the API port refused it (`unreachable`, so nothing
  /// was delivered) the device has gone to sleep: wake it through DIAL,
  /// wait for the API and send [request] once more. An acknowledged wake
  /// took effect, so a later failure is a partial delivery.
  ///
  /// A wake that failed without proving it did nothing (it timed out, say:
  /// the launch may have reached the device and woken it, and the TV over
  /// HDMI-CEC) is reported with its own code, never as `unreachable`, and
  /// the power observation goes stale.
  Future<HttpResult> _awake(Future<HttpResult> Function() request) async {
    try {
      return await _send(request);
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.unreachable) rethrow;
      _checkOpen();
      final wakeFailure = await tryWake(_api);
      if (wakeFailure != null) {
        final error = withWakeContext(e, wakeFailure);
        if (wakeMayHaveActed(wakeFailure)) {
          _setState(_state.copyWith(power: _state.power?.asStale()));
          throw error;
        }
        throw wakeFailure.code == WatchmeErrorCode.unreachable
            ? _lost(error)
            : error;
      }
      _delivered++;
      _markReachable();
      await _untilListening();
      _setState(_state.copyWith(power: _observed(PowerMode.on)));
      return _send(request);
    }
  }

  /// Sends one request unless the session was closed meanwhile. Every
  /// request a command makes goes through here (or through
  /// [_untilListening], which stops on close too), so a command stops
  /// before its next request once [close] is called.
  Future<HttpResult> _send(Future<HttpResult> Function() request) async {
    _checkOpen();
    final result = await request();
    _markReachable();
    return result;
  }

  void _checkOpen() {
    if (_closed) throw _closedError;
  }

  WatchmeError _reauth(HttpResult result, String what) {
    final error = _api.errorFor(result, what);
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
