import 'dart:async';
import 'dart:math';

import 'package:watchme_core/watchme_core.dart';

import 'api.dart';
import 'constants.dart';
import 'descriptor.dart';
import 'keys.dart';

/// How often a session polls power, volume, mute, input and the current
/// app while someone listens to its events, unless configured otherwise.
/// SmartCast TVs misbehave under bursts of requests, so it is unhurried.
const Duration vizioDefaultPollInterval = Duration(seconds: 10);

/// The most keys one `PUT /key_command/` carries; longer lists go in
/// several requests.
const int vizioMaxKeysPerRequest = 50;

/// The most volume steps one `StepVolume` sends.
const int vizioMaxVolumeSteps = 100;

/// The top of a VIZIO TV's volume scale (vizaio and pyvizio agree). A TV's
/// own static `MAXIMUM` may lower it, never raise it.
const int vizioTvMaxVolume = 100;

/// The longest text one `TypeText` sends.
const int vizioMaxTextLength = 256;

/// How many requests in a row must time out, with no answer in between,
/// before a session reports its TV lost.
const int vizioTimeoutsBeforeDisconnect = 3;

/// A session with one VIZIO TV over the SmartCast API, created by
/// `VizioDriver.connect`.
///
/// Every request pins the certificate recorded at pairing and carries the
/// `AUTH` token. Requests go out one at a time, commands, refreshes and
/// polls alike: the TVs misbehave under concurrent requests (vizaio and
/// pyvizio serialise too).
///
/// * **Power.** `SetPower` sends the discrete keys 11/1 and 11/0; the
///   toggle 11/2 is never sent, so `PressKey(RemoteKey.power)` is
///   [Unsupported]. [refresh] reads `power_mode` ([Confidence.reported]);
///   a power state the session only assumes from a command it sent is
///   [Confidence.inferred].
/// * **Settings.** Absolute volume, discrete mute and input selection read
///   the settings leaf for its `HASHVAL`, then `MODIFY` it. Absolute volume
///   is clamped to [maxVolume], which the first one reads. A refused
///   `HASHVAL` (the value changed meanwhile, nothing was applied) is
///   retried once after a fresh read, and the write is skipped when the
///   fresh read already shows the target, so nothing is applied twice.
/// * **Delivery.** Reads never count as delivered. A `PUT` the TV answered
///   `SUCCESS` does. A command sent as several requests (more than
///   [vizioMaxKeysPerRequest] keys) that fails after one was delivered,
///   [close] included, is [WatchmeErrorCode.partiallyDelivered]. A
///   `timeout` (the TV may have acted) is never retried.
/// * **Lost, not slow.** A request that reaches nothing (`unreachable`: the
///   TV went to Eco standby, or left the network), or
///   [vizioTimeoutsBeforeDisconnect] timeouts in a row, marks the state
///   stale and emits [ConnectionChanged] with
///   [ConnectionState.disconnected]. One timeout is only reported.
/// * **Re-auth.** A raw HTTP 401 or 403, `REQUIRES_PAIRING`, or
///   `PAIRING_DENIED` on a control call means the token was revoked (a
///   re-pair with the same controller id elsewhere, or a reset): the
///   session emits [ReauthRequired] and fails with
///   [WatchmeErrorCode.reauthRequired].
/// * **Never wakes.** Nothing here sends Wake-on-LAN; [refresh] and polling
///   only read.
/// * **Secrets.** No error or event carries the token.
final class VizioSession implements DriverSession {
  /// Wraps an authenticated [api] (used by the driver after connecting).
  VizioSession(
    this._api,
    this._clock, {
    required this.deviceInfo,
    Observed<PowerMode>? power,
    this._pollInterval = vizioDefaultPollInterval,
  }) : _state = DeviceState(
         power: power,
         connections: const {vizioDriverId: ConnectionState.connected},
       ) {
    _events = StreamController<DeviceEvent>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  final VizioApi _api;
  final Clock _clock;
  final Duration? _pollInterval;
  late final StreamController<DeviceEvent> _events;
  DeviceState _state;
  ConnectionState _connection = ConnectionState.connected;
  Future<void> _queue = Future.value();
  Timer? _pollTimer;
  bool _polling = false;
  bool _closed = false;
  bool _reauthReported = false;
  List<_Input>? _inputs;
  int? _maxVolume;

  /// Requests of the running command that the TV accepted.
  int _delivered = 0;

  /// Requests that timed out since the TV last answered.
  int _timeouts = 0;

  /// What `deviceinfo` said when connecting.
  final VizioDeviceInfo deviceInfo;

  /// The API port in use.
  int get port => _api.port;

  /// The highest volume the TV takes, once the first `SetVolume` read it
  /// (brief §6): the static `audio/volume` `MAXIMUM`, at most
  /// [vizioTvMaxVolume], or [vizioTvMaxVolume] when the TV gives none.
  int? get maxVolume => _maxVolume;

  static const WatchmeError _closedError = WatchmeError.cancelled(
    'The VIZIO session is closed',
  );

  @override
  String get driverId => vizioDriverId;

  @override
  List<CapabilitySupport> get capabilities => vizioDescriptor.ceiling;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  // ------------------------------------------------------------- commands

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
          WatchmeError.internal('VIZIO ${command.type} failed: $e', cause: e),
        ),
      );
    }
  });

  /// The error of a command that stopped with [error], redacted: [error]
  /// itself while none of its writes took effect, otherwise
  /// [WatchmeErrorCode.partiallyDelivered] with [error] as the cause.
  WatchmeError _failure(Command command, WatchmeError error) {
    final e = _api.redact(error);
    if (_delivered == 0 || e.code == WatchmeErrorCode.partiallyDelivered) {
      return e;
    }
    return WatchmeError.partiallyDelivered(
      'VIZIO ${command.type} stopped after $_delivered of its requests '
      'reached the TV: ${e.message}',
      rawDeviceMessage: e.rawDeviceMessage,
      cause: e,
    );
  }

  Future<CommandResult> _dispatch(Command command) => switch (command) {
    PressKey(:final key, :final action) => _pressKey(key, action),
    SetPower(:final on) => _setPower(on),
    SetVolume(:final level) => _setVolume(level),
    StepVolume(:final steps) => _stepVolume(steps),
    SetMute(:final muted) => _setMute(muted),
    final LaunchApp c => _launch(c),
    ListApps() => _listApps(),
    SelectInput(:final inputId) => _selectInput(inputId),
    TuneChannel(:final channel) => _tune(channel),
    TypeText(:final text, :final replace) => _typeText(text, replace),
    Media(:final action) => _media(action),
    MovePointer() => _unsupported('SmartCast has no pointer API'),
    ShowToast() => _unsupported('SmartCast has no notification API'),
    CastUrl() => _unsupported(
      'VIZIO plays URLs through Chromecast built-in, not the SmartCast API',
    ),
    TakeScreenshot() => _unsupported('SmartCast has no screenshot API'),
  };

  Future<CommandResult> _pressKey(RemoteKey key, KeyAction action) async {
    if (action != KeyAction.click) {
      return Unsupported(
        'SmartCast keys are presses only (KEYPRESS); ${key.name} cannot be '
        'held or released',
      );
    }
    switch (key) {
      case RemoteKey.power:
        return const Unsupported(
          'The VIZIO power toggle (11/2) is never sent; SetPower sends the '
          'discrete power keys',
        );
      case RemoteKey.powerOn:
        return _setPower(true);
      case RemoteKey.powerOff:
        return _setPower(false);
      case RemoteKey.inputHdmi1:
        return _selectInput('hdmi1');
      case RemoteKey.inputHdmi2:
        return _selectInput('hdmi2');
      case RemoteKey.inputHdmi3:
        return _selectInput('hdmi3');
      case RemoteKey.inputHdmi4:
        return _selectInput('hdmi4');
      case RemoteKey.inputTuner:
        return _selectInput('tuner');
      case RemoteKey.inputAv1:
        // The references name no composite input; the TV's own list
        // decides (`av`, `av1` or the shared `comp` jack).
        return _selectInput('av', alternatives: const ['av1', 'comp']);
      default:
        final code = vizioKeys[key];
        if (code == null) {
          return Unsupported('VIZIO SmartCast has no ${key.name} key');
        }
        await _sendKeys([code], 'Key ${key.name}');
        switch (key) {
          case RemoteKey.volumeUp || RemoteKey.volumeDown:
            _setState(_state.copyWith(volume: _state.volume?.asStale()));
          case RemoteKey.mute:
            _setState(_state.copyWith(muted: _state.muted?.asStale()));
          default:
            break;
        }
        return const Confirmed();
    }
  }

  Future<CommandResult> _setPower(bool on) async {
    final key = vizioKeys[on ? RemoteKey.powerOn : RemoteKey.powerOff]!;
    await _sendKeys([key], on ? 'Power on' : 'Power off');
    // A Quick Start TV goes to standby; an Eco one closes its port, which
    // the next request finds.
    _setState(
      _state.copyWith(power: _inferred(on ? PowerMode.on : PowerMode.standby)),
    );
    return const Confirmed();
  }

  Future<CommandResult> _setVolume(int level) async {
    final target = level.clamp(0, await _volumeMax());
    final result = await _modify(
      VizioPaths.volume,
      'volume',
      'the volume',
      target: target,
      matches: (value) => value == target,
    );
    if (result.current case final int current?) {
      _setState(
        _state.copyWith(volume: Observed.reported(current, driverId, _now)),
      );
    } else {
      _setState(_state.copyWith(volume: _inferred(target)));
    }
    return const Confirmed();
  }

  /// [maxVolume], read once per session: a level above it is
  /// `VALUE_OUT_OF_RANGE`. Only a TV that says it has no range
  /// (`URI_NOT_FOUND`, HTTP 404, or a `SUCCESS` without `MAXIMUM`) keeps
  /// the TV scale. Any other answer (`BUSY`, HTTP 500, a malformed body) or
  /// none fails the command before it writes anything, and the next one
  /// asks again.
  Future<int> _volumeMax() async {
    if (_maxVolume case final max?) return max;
    const what = 'Reading the volume range';
    final reply = await _get(VizioPaths.volumeRange);
    _checkAuth(reply, what);
    if (!reply.success) {
      final error = _error(reply, what);
      if (error.code != WatchmeErrorCode.unsupported) throw error;
      return _maxVolume = vizioTvMaxVolume;
    }
    final range = reply.itemNamed('volume') ?? reply.itemNamed();
    final max = switch (range?['maximum']) {
      null => vizioTvMaxVolume,
      final int max when max > 0 => max,
      _ => throw WatchmeError.protocol(
        '$what: the TV sent an unusable MAXIMUM',
        rawDeviceMessage: reply.text,
      ),
    };
    return _maxVolume = min(max, vizioTvMaxVolume);
  }

  Future<CommandResult> _stepVolume(int steps) async {
    if (steps == 0) return const Confirmed();
    if (steps.abs() > vizioMaxVolumeSteps) {
      return const Unsupported(
        'At most $vizioMaxVolumeSteps volume steps at a time',
      );
    }
    final key =
        vizioKeys[steps > 0 ? RemoteKey.volumeUp : RemoteKey.volumeDown]!;
    // One KEYLIST, processed in order by the TV.
    await _sendKeys(List.filled(steps.abs(), key), 'Volume steps');
    _setState(_state.copyWith(volume: _state.volume?.asStale()));
    return const Confirmed();
  }

  Future<CommandResult> _setMute(bool? muted) async {
    if (muted == null) {
      await _sendKeys([vizioKeys[RemoteKey.mute]!], 'Mute toggle');
      _setState(_state.copyWith(muted: _state.muted?.asStale()));
      return const Confirmed();
    }
    final value = muted ? 'On' : 'Off';
    final result = await _modify(
      VizioPaths.mute,
      'mute',
      'mute',
      target: value,
      matches: (current) =>
          current is String && current.toLowerCase() == value.toLowerCase(),
    );
    // In standby the TV acknowledges a mute change without applying it, so
    // the state is what the session asked for, not what it saw.
    _setState(
      _state.copyWith(
        muted: result.current != null
            ? Observed.reported(muted, driverId, _now)
            : _inferred(muted),
      ),
    );
    return const Confirmed();
  }

  /// Read-modify-write of the settings leaf [cname] at [path] to [target].
  ///
  /// Reads the leaf for its `HASHVAL`; when its value already [matches],
  /// writes nothing and returns it as `current`. Otherwise sends
  /// `MODIFY`. A `HASHVAL_ERROR` or `INVALID_PARAMETER` answer changed
  /// nothing (a value changed between the read and the write), so the leaf
  /// is read once more and, unless it now matches, written once more. A
  /// timeout is never retried.
  Future<({Object? current})> _modify(
    String path,
    String cname,
    String what, {
    required Object target,
    required bool Function(Object? value) matches,
  }) async {
    for (var attempt = 1; ; attempt++) {
      final leaf = await _readLeaf(path, cname, 'Reading $what');
      if (matches(leaf.value)) return (current: leaf.value);
      final reply = await _put(path, {
        'REQUEST': 'MODIFY',
        'VALUE': target,
        'HASHVAL': leaf.hash,
      });
      if (reply.success) {
        _delivered++;
        return (current: null);
      }
      if (attempt == 1 &&
          (reply.result == 'HASHVAL_ERROR' ||
              reply.result == 'INVALID_PARAMETER')) {
        continue;
      }
      throw _error(reply, 'Setting $what');
    }
  }

  Future<CommandResult> _launch(LaunchApp command) async {
    if (command.deepLink != null || command.params.isNotEmpty) {
      return Unsupported(
        'VIZIO app launch takes no deep link or parameters '
        '(${command.appId})',
      );
    }
    final id = command.appId.trim().toLowerCase();
    final app = vizioApps.where((a) => a.id == id).firstOrNull;
    if (app == null) {
      return Unsupported(
        'Unknown VIZIO app "${command.appId}"; the built-in launch table has '
        '${vizioApps.map((a) => a.id).join(', ')}',
      );
    }
    await _write(VizioPaths.appLaunch, app.launchBody, 'Launching ${app.name}');
    _setState(_state.copyWith(foregroundApp: _inferred(app.info)));
    return const Confirmed();
  }

  Future<CommandResult> _listApps() async => Confirmed(
    payload: AppListPayload([for (final app in vizioApps) app.info]),
  );

  Future<CommandResult> _selectInput(
    String inputId, {
    List<String> alternatives = const [],
  }) async {
    final wanted = inputId.trim();
    if (wanted.isEmpty) return const Unsupported('SelectInput needs an input');
    final inputs = await _inputList();
    _Input? target;
    for (final name in [wanted, ...alternatives]) {
      target ??= inputs.where((i) => i.isNamed(name)).firstOrNull;
    }
    if (target == null) {
      return Unsupported(
        'This VIZIO TV has no input "$inputId"; it has '
        '${inputs.map((i) => i.cname).join(', ')}',
      );
    }
    for (var attempt = 1; ; attempt++) {
      final current = await _readLeaf(
        VizioPaths.currentInput,
        'current_input',
        'Reading the current input',
      );
      // Selecting the input already in front answers FAILURE; nothing to
      // do, and nothing is sent.
      if (current.value case final String v when target.isNamed(v)) {
        _setState(
          _state.copyWith(
            input: Observed.reported(target.cname, driverId, _now),
          ),
        );
        return const Confirmed();
      }
      // Modern firmware takes the lowercase cname; older firmware the
      // display name (heathbar, exiva). Both carry current_input's HASHVAL,
      // which a FAILURE leaves unchanged.
      var reply = await _put(VizioPaths.currentInput, {
        'REQUEST': 'MODIFY',
        'VALUE': target.cname,
        'HASHVAL': current.hash,
      });
      if (reply.result == 'FAILURE' &&
          target.name.isNotEmpty &&
          target.name != target.cname) {
        reply = await _put(VizioPaths.currentInput, {
          'REQUEST': 'MODIFY',
          'VALUE': target.name,
          'HASHVAL': current.hash,
        });
      }
      if (reply.success) {
        _delivered++;
        _setState(_state.copyWith(input: _inferred(target.cname)));
        return const Confirmed();
      }
      if (attempt == 1 && reply.result == 'HASHVAL_ERROR') continue;
      throw _error(reply, 'Selecting input ${target.cname}');
    }
  }

  Future<CommandResult> _tune(String channel) async {
    final ch = channel.trim();
    if (!RegExp(r'^[0-9]+([.\-][0-9]+)?$').hasMatch(ch)) {
      return Unsupported(
        'VIZIO tunes by typing the channel number; "$channel" is not one',
      );
    }
    // Digit entry as codeset-0 ASCII ('7', '.', '1'), not the codeset-0
    // codes 0-9. No enter key follows: none is documented.
    await _sendKeys(vizioTextKeys(ch)!, 'Tuning $ch');
    return const Confirmed();
  }

  Future<CommandResult> _typeText(String text, bool replace) async {
    if (replace) {
      return const Unsupported(
        'SmartCast cannot clear a text field, so it cannot replace text',
      );
    }
    if (text.isEmpty) return const Confirmed();
    if (text.length > vizioMaxTextLength) {
      return const Unsupported(
        'Send at most $vizioMaxTextLength characters at a time',
      );
    }
    final keys = vizioTextKeys(text);
    if (keys == null) {
      return const Unsupported('SmartCast types printable ASCII only');
    }
    await _sendKeys(keys, 'Typing text');
    return const Confirmed();
  }

  Future<CommandResult> _media(MediaAction action) async {
    if (action == MediaAction.playPause) {
      return const Unsupported(
        'SmartCast has discrete play and pause keys and no readable '
        'playback state; send play or pause',
      );
    }
    final key = vizioMediaKey(action);
    if (key == null) {
      return Unsupported('SmartCast has no ${action.name} key');
    }
    await _sendKeys([key], 'Media ${action.name}');
    return const Confirmed();
  }

  // ---------------------------------------------------------------- state

  /// Passive: reads only. Reads `power_mode`, then while the TV is on the
  /// volume, mute, input and current app, and in standby the volume and
  /// mute (input and app are no longer current; they go stale).
  ///
  /// Throws when `power_mode` cannot be read: a transport failure (see the
  /// class notes on lost TVs) or a refused token. Also throws, keeping
  /// nothing it read, when a later read loses the TV or [close] comes
  /// first.
  @override
  Future<DeviceState> refresh() => _serial(() async {
    _checkOpen();
    try {
      final powerReply = await _get(VizioPaths.powerMode);
      _checkAuth(powerReply, 'Reading the power state');
      final mode = parsePowerMode(powerReply);
      final now = _now;
      var next = _state.copyWith(
        power: mode == null
            ? _state.power?.asStale()
            : Observed.reported(mode, driverId, now),
      );
      if (mode != null) {
        final volume = await _tryLeaf(VizioPaths.volume, 'volume');
        if (volume?.value case final int v) {
          next = next.copyWith(volume: Observed.reported(v, driverId, now));
        }
        final mute = await _tryLeaf(VizioPaths.mute, 'mute');
        if (mute?.value case final String m) {
          next = next.copyWith(
            muted: Observed.reported(m.toLowerCase() == 'on', driverId, now),
          );
        }
      }
      if (mode == PowerMode.on) {
        final input = await _tryLeaf(VizioPaths.currentInput, 'current_input');
        if (input?.value case final String v) {
          next = next.copyWith(
            input: Observed.reported(await _inputIdFor(v), driverId, now),
          );
        }
        next = await _withCurrentApp(next, now);
      } else if (mode == PowerMode.standby) {
        next = next.copyWith(
          input: _state.input?.asStale(),
          foregroundApp: _state.foregroundApp?.asStale(),
          nowPlaying: _state.nowPlaying?.asStale(),
        );
      }
      // [next] began as the state before the reads; a close while the last
      // one was in flight has made the session disconnected since, and it
      // stays so.
      _checkOpen();
      _setState(next);
      return _state;
    } on WatchmeError catch (e) {
      throw _api.redact(e);
    }
  });

  Future<DeviceState> _withCurrentApp(DeviceState next, DateTime now) async {
    final VizioReply reply;
    try {
      reply = await _get(VizioPaths.appCurrent);
      _checkAuth(reply, 'Reading the current app');
    } on WatchmeError catch (e) {
      if (_fatal(e)) rethrow;
      return next;
    }
    if (!reply.success) return next;
    switch (reply.item?['value']) {
      case {'app_id': final Object appId, 'name_space': final int ns}:
        final id = '$appId';
        final app =
            vizioApps.where((a) => a.matches(ns, id)).firstOrNull?.info ??
            AppInfo(id: 'vizio:$ns:$id', name: 'VIZIO app $ns/$id');
        return next.copyWith(
          foregroundApp: Observed.reported(app, driverId, now),
        );
      default:
        // No app in front (VALUE null or absent): an input is showing.
        return next.copyWith(foregroundApp: _state.foregroundApp?.asStale());
    }
  }

  /// The input id for a `current_input` value: the cname of the input it
  /// names (display name, meta name or cname), else the value lower-cased.
  Future<String> _inputIdFor(String value) async {
    List<_Input> inputs;
    try {
      inputs = await _inputList();
    } on WatchmeError catch (e) {
      if (_fatal(e)) rethrow;
      inputs = const [];
    }
    return inputs.where((i) => i.isNamed(value)).firstOrNull?.cname ??
        value.toLowerCase();
  }

  /// The TV's inputs (`devices/name_input`), read once per session.
  Future<List<_Input>> _inputList() async {
    if (_inputs case final cached?) return cached;
    final reply = await _get(VizioPaths.inputList);
    if (!reply.success) throw _error(reply, 'Reading the input list');
    bool? flag(Object? v) => switch (v) {
      true || 1 => true,
      false || 0 => false,
      final String s when s.toLowerCase() == 'true' => true,
      final String s when s.toLowerCase() == 'false' => false,
      _ => null,
    };
    final inputs = <_Input>[];
    for (final item in reply.items) {
      final cname = item['cname'];
      if (cname is! String || cname.isEmpty) continue;
      // The official app lists an input when it is enabled or visible.
      final enabled = flag(item['enabled']);
      final visible = flag(item['visible']);
      if (enabled != true && visible != true && (enabled ?? visible) != null) {
        continue;
      }
      inputs.add(
        _Input(
          cname,
          switch (item['name']) {
            final String n => n,
            _ => '',
          },
          switch (item['value']) {
            {'name': final String m} => m,
            _ => '',
          },
        ),
      );
    }
    return _inputs = inputs;
  }

  // ------------------------------------------------------------- requests

  /// Sends [keys] as KEYLISTs of at most [vizioMaxKeysPerRequest] each; each
  /// accepted one counts as delivered.
  Future<void> _sendKeys(List<VizioKey> keys, String what) async {
    for (var i = 0; i < keys.length; i += vizioMaxKeysPerRequest) {
      final chunk = keys.sublist(
        i,
        min(i + vizioMaxKeysPerRequest, keys.length),
      );
      await _write(VizioPaths.keyCommand, vizioKeyListBody(chunk), what);
    }
  }

  /// A `PUT` that must answer `SUCCESS`; it then counts as delivered.
  Future<void> _write(String path, Object body, String what) async {
    final reply = await _put(path, body);
    if (!reply.success) throw _error(reply, what);
    _delivered++;
  }

  /// Reads the settings leaf [cname] at [path]: its value and `HASHVAL`.
  Future<({Object? value, int hash})> _readLeaf(
    String path,
    String cname,
    String what,
  ) async {
    final reply = await _get(path);
    if (!reply.success) throw _error(reply, what);
    return parseLeaf(reply, cname) ??
        (throw WatchmeError.protocol(
          '$what: the TV sent no HASHVAL',
          rawDeviceMessage: reply.text,
        ));
  }

  /// Whether [e], met by an optional read of [refresh], must end the
  /// refresh: a refused token, a TV that stopped answering (a timeout that
  /// was the last straw included: the session is no longer connected), or
  /// [close].
  bool _fatal(WatchmeError e) =>
      _connection != ConnectionState.connected ||
      const {
        WatchmeErrorCode.reauthRequired,
        WatchmeErrorCode.unreachable,
        WatchmeErrorCode.cancelled,
      }.contains(e.code);

  /// [_readLeaf] for [refresh]: `null` when it fails, unless the failure is
  /// [_fatal].
  Future<({Object? value, int hash})?> _tryLeaf(
    String path,
    String cname,
  ) async {
    try {
      final reply = await _get(path);
      _checkAuth(reply, 'Reading $cname');
      return parseLeaf(reply, cname);
    } on WatchmeError catch (e) {
      if (_fatal(e)) rethrow;
      return null;
    }
  }

  Future<VizioReply> _get(String path) => _send(() => _api.get(path));

  Future<VizioReply> _put(String path, Object body) =>
      _send(() => _api.put(path, body));

  /// Sends one request unless the session was closed meanwhile. Every
  /// request goes through here, so a command stops before its next request
  /// once [close] is called, and every answer or transport failure counts
  /// towards the connection state.
  Future<VizioReply> _send(Future<VizioReply> Function() request) async {
    _checkOpen();
    final VizioReply reply;
    try {
      reply = await request();
    } on WatchmeError catch (e) {
      _noteTransportError(e);
      rethrow;
    }
    _markReachable();
    return reply;
  }

  /// Throws the re-auth error when [reply] refused the token.
  void _checkAuth(VizioReply reply, String what) {
    if (reply.authRefused) throw _error(reply, what);
  }

  /// The error for a [reply] that is not a success, redacted. A refused
  /// token is reported once as [ReauthRequired].
  WatchmeError _error(VizioReply reply, String what) {
    final error = _api.redact(
      vizioError(reply, what, context: VizioContext.session),
    );
    if (error.code == WatchmeErrorCode.reauthRequired) _reauth(error);
    return error;
  }

  void _reauth(WatchmeError error) {
    if (_reauthReported || _closed) return;
    _reauthReported = true;
    _connection = ConnectionState.failed;
    _setState(
      _state.copyWith(
        connections: const {vizioDriverId: ConnectionState.failed},
      ),
    );
    _emit(ReauthRequired(error, driverId: vizioDriverId));
    _emit(
      ConnectionChanged(
        ConnectionState.failed,
        driverId: vizioDriverId,
        error: error,
      ),
    );
  }

  void _checkOpen() {
    if (_closed) throw _closedError;
  }

  /// Takes in a request that failed with [e]: one that reached nothing, or
  /// the [vizioTimeoutsBeforeDisconnect]th timeout in a row, means the TV
  /// is gone.
  void _noteTransportError(WatchmeError e) {
    switch (e.code) {
      case WatchmeErrorCode.unreachable:
        _lost(e);
      case WatchmeErrorCode.timeout:
        if (++_timeouts >= vizioTimeoutsBeforeDisconnect) _lost(e);
      default:
        break;
    }
  }

  /// The TV stopped answering: marks every observation stale and reports
  /// the session disconnected with [e] (once).
  void _lost(WatchmeError e) {
    if (_connection != ConnectionState.connected || _closed) return;
    _connection = ConnectionState.disconnected;
    final error = _api.redact(e);
    _setState(
      _state.markStale().copyWith(
        connections: const {vizioDriverId: ConnectionState.disconnected},
      ),
    );
    _emit(
      ConnectionChanged(
        ConnectionState.disconnected,
        driverId: vizioDriverId,
        error: error,
      ),
    );
  }

  /// The TV answered a request (whatever it said).
  void _markReachable() {
    _timeouts = 0;
    if (_connection != ConnectionState.disconnected || _closed) return;
    _connection = ConnectionState.connected;
    _setState(
      _state.copyWith(
        connections: const {vizioDriverId: ConnectionState.connected},
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.connected,
        driverId: vizioDriverId,
      ),
    );
  }

  DateTime get _now => _clock.now();

  Observed<T> _inferred<T>(T value) =>
      Observed.inferred(value, vizioDriverId, _now);

  /// Adopts [next] and emits the fields whose value or confidence changed
  /// (a poll that re-stamps the same value is not a change).
  void _setState(DeviceState next) {
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
    if (!diff.isEmpty) _emit(StateChanged(diff, driverId: vizioDriverId));
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

  // -------------------------------------------------------------- polling

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
      // A lost TV and a refused token surface as events; a single timeout
      // leaves the session as it was until the next poll.
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
      connections: const {vizioDriverId: ConnectionState.disconnected},
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.disconnected,
        driverId: vizioDriverId,
      ),
    );
    await _events.close();
  }
}

/// One entry of `devices/name_input`.
final class _Input {
  const _Input(this.cname, this.name, this.meta);

  /// Canonical id, e.g. `hdmi1`.
  final String cname;

  /// Display name, e.g. `HDMI-1`.
  final String name;

  /// User or meta name, e.g. `SMARTCAST`.
  final String meta;

  /// Whether [value] names this input: its cname, display name or meta
  /// name, ignoring case.
  bool isNamed(String value) {
    final v = value.trim().toLowerCase();
    return v.isNotEmpty &&
        (v == cname.toLowerCase() ||
            v == name.toLowerCase() ||
            (meta.isNotEmpty && v == meta.toLowerCase()));
  }
}
