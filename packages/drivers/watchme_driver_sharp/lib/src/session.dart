import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'capabilities.dart';
import 'constants.dart';
import 'keys.dart';
import 'link.dart';
import 'profiles.dart';
import 'protocol.dart';
import 'redaction.dart';

/// How often a session polls power, volume, mute and input while someone
/// listens to its events, unless configured otherwise. Each poll also
/// keeps the connection alive (the TV cuts one after 3 idle minutes).
const Duration sharpDefaultPollInterval = Duration(seconds: 10);

/// How many requests in a row must time out, with no answer in between,
/// before a session reports its TV lost.
const int sharpTimeoutsBeforeDisconnect = 3;

/// The most volume steps one `StepVolume` sends as key presses.
const int sharpMaxVolumeSteps = 100;

/// A session with one Sharp TV over its IP-control port.
///
/// One TCP connection carries every request, one at a time: commands,
/// refreshes and polls run in order and never overlap, and each request
/// waits for its reply before the next is written. The connection closes
/// after [SharpTimings.idleClose] without traffic, and whenever a request
/// times out or the TV answers out of turn, so that a late reply is never
/// taken for the next one; the next request opens a new one (logging in
/// again), at least [SharpTimings.reconnectGap] after the last.
///
/// Delivery:
///
/// * A connection the TV closed while idle is reopened before the next
///   request; only a reopen that fails is [WatchmeErrorCode.unreachable]
///   (nothing was sent), and it reports the TV lost: the session marks its
///   observations stale and emits [ConnectionChanged] with
///   [ConnectionState.disconnected].
/// * Once a request is handed to the connection, a send that fails, a
///   lost connection or a missing reply is [WatchmeErrorCode.timeout]:
///   the TV may have acted. Nothing that may have been delivered is sent
///   again, and the power key toggle never is.
///   [sharpTimeoutsBeforeDisconnect] timeouts in a row report the TV lost.
/// * `ERR` means the TV did not act: [WatchmeErrorCode.rejected], with
///   `ERR` as the raw device message. Within [SharpTimings.powerOnSettle]
///   of a delivered `POWR1`, idempotent absolute commands refused with
///   `ERR` (the TV is still starting) are sent again every
///   [SharpTimings.bootRetryInterval].
/// * A command sent as several requests (two-part channels, volume key
///   presses) that fails after one was accepted is
///   [WatchmeErrorCode.partiallyDelivered], [close] included.
///
/// Power: `SetPower` sends the discrete `POWR1`/`POWR0`. `POWR?` is the
/// TV's own report ([Confidence.reported]), except a `0` within the boot
/// window after `POWR1` and a `1` within [SharpTimings.powerOffSettle]
/// after `POWR0`, which are ignored. `POWR?` never reports
/// [PowerMode.off]: a TV that stops listening is unreachable, not off.
/// While it reads standby, only `POWR?` is polled. The POWER and NETFLIX
/// remote keys can wake a TV in standby, so they are sent only for an
/// explicit command, right after `POWR?` reads on.
///
/// No error, event or message carries the login ID or password.
final class SharpSession implements DriverSession {
  SharpSession._({
    required this._endpoint,
    required this._network,
    required this._clock,
    required this._timings,
    required this._credential,
    required this._pollInterval,
    required SharpLink this._link,
  }) : _secrets = sharpSecrets(_credential) {
    _events = StreamController<DeviceEvent>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  /// Connects to [endpoint], logs in with [credential], and reads which TV
  /// it is (`MNRD1`) and its state (`POWR?`, then volume, mute and input
  /// while it is on). Every request is a read: nothing here can wake the
  /// TV or change what it shows.
  ///
  /// Throws [WatchmeError]: [WatchmeErrorCode.unreachable] when nothing
  /// accepts the connection, [WatchmeErrorCode.unauthorized] when the TV
  /// asks for a login and [credential] is `null`,
  /// [WatchmeErrorCode.reauthRequired] when it refuses [credential] (or
  /// asks for a login [credential] says it does not need), and
  /// [WatchmeErrorCode.timeout] or [WatchmeErrorCode.protocol] when it
  /// does not answer `POWR?` properly.
  static Future<SharpSession> open({
    required Endpoint endpoint,
    required NetworkStack network,
    required Clock clock,
    required SharpTimings timings,
    SharedSecretCredential? credential,
    Duration? pollInterval = sharpDefaultPollInterval,
  }) async {
    final link = await openSharpLink(
      network: network,
      host: endpoint.host,
      port: endpoint.port(SharpPorts.ipc, SharpPorts.ipcDefault),
      clock: clock,
      timings: timings,
      credential: credential,
    );
    final session = SharpSession._(
      endpoint: endpoint,
      network: network,
      clock: clock,
      timings: timings,
      credential: credential,
      pollInterval: pollInterval,
      link: link,
    );
    try {
      await session._start();
    } on WatchmeError catch (e) {
      await session.close();
      throw session._redact(e);
    }
    return session;
  }

  final Endpoint _endpoint;
  final NetworkStack _network;
  final Clock _clock;
  final SharpTimings _timings;
  final SharedSecretCredential? _credential;
  final Duration? _pollInterval;
  final List<String> _secrets;

  SharpLink? _link;
  DateTime? _lastClose;
  DateTime _lastUsed = DateTime.fromMillisecondsSinceEpoch(0);
  int _discardedBefore = 0;

  SharpProfile _profile = SharpProfile.us2011;
  bool _modelPending = false;
  String? _model;
  int _volumeMax = SharpProfile.us2011.volumeMax;
  bool _volumeCertain = false;
  bool _volumeFixed = false;
  bool _powerStateSeen = false;
  bool _standby = false;
  DateTime? _bootUntil;
  DateTime? _retryUntil;
  DateTime? _offUntil;

  List<CapabilitySupport> _caps = const [];
  late final StreamController<DeviceEvent> _events;
  DeviceState _state = const DeviceState(
    connections: {sharpDriverId: ConnectionState.connected},
  );
  DeviceState? _batchStart;
  ConnectionState _connection = ConnectionState.connected;
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool _reauthReported = false;
  int _delivered = 0;
  int _timeouts = 0;
  Timer? _idleTimer;
  Timer? _pollTimer;
  bool _polling = false;

  static const WatchmeError _closedError = WatchmeError.cancelled(
    'The Sharp session is closed',
  );

  @override
  String get driverId => sharpDriverId;

  @override
  List<CapabilitySupport> get capabilities => _caps;

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  /// The model profile in use.
  SharpProfile get profile => _profile;

  /// What the TV answered to `MNRD1` (not the full model number), if it
  /// did.
  String? get model => _model;

  /// The top of the volume scale in use (60 or 100).
  int get volumeMax => _volumeMax;

  /// Unsolicited bytes the session dropped before requests (late replies,
  /// stray `OK`s), over all its connections.
  int get discardedBytes => _discardedBefore + (_link?.discardedBytes ?? 0);

  /// The endpoint this session talks to.
  Endpoint get endpoint => _endpoint;

  // ---------------------------------------------------------------- start

  Future<void> _start() async {
    final attrs = _endpoint.attributes;
    final fixed = SharpProfile.byId(attrs[SharpAttributes.profile]);
    final power = await _read('POWR');
    if (fixed != null) {
      _profile = fixed;
      _volumeCertain = true;
      _volumeMax = fixed.volumeMax;
    } else {
      final model = await _readInfo('MNRD');
      _model = model;
      final match =
          sharpProfileForModel(model) ??
          sharpProfileForModel(attrs[DiscoveryAttr.modelName]);
      if (match != null) {
        _profile = match.profile;
        _volumeCertain = match.volumeCertain;
        _volumeMax = match.volumeMax;
      } else if (power == null && model == null) {
        // Every query refused: the 2015 firmware.
        _profile = SharpProfile.us2015Limited;
        _volumeCertain = false;
      } else {
        _modelPending = model == null;
      }
    }
    final forced = int.tryParse(attrs[SharpAttributes.volumeMax] ?? '');
    if (forced == 60 || forced == 100) {
      _volumeMax = forced!;
      _volumeCertain = true;
      _volumeFixed = true;
    }
    _caps = _computeCapabilities();
    _observePower(power);
    if (power == '1' && _profile.queries) {
      try {
        await _readOnState();
      } on WatchmeError {
        // Optional reads; refresh tries again.
      }
    }
  }

  // ------------------------------------------------------------- commands

  @override
  Future<CommandResult> execute(Command command) => _serial(() async {
    if (_closed) return const Failed(_closedError);
    _delivered = 0;
    _beginBatch();
    try {
      return await _dispatch(command);
    } on WatchmeError catch (e) {
      return Failed(_failure(command, e));
    } on Object catch (e) {
      return Failed(
        _failure(
          command,
          WatchmeError.internal('Sharp ${command.type} failed: $e', cause: e),
        ),
      );
    } finally {
      _endBatch();
    }
  });

  /// The error of a command that stopped with [error], redacted: [error]
  /// itself while none of its requests was accepted, otherwise
  /// [WatchmeErrorCode.partiallyDelivered] with [error] as the cause.
  WatchmeError _failure(Command command, WatchmeError error) {
    final e = _redact(error);
    if (_delivered == 0 || e.code == WatchmeErrorCode.partiallyDelivered) {
      return e;
    }
    return WatchmeError.partiallyDelivered(
      'Sharp ${command.type} stopped after $_delivered of its requests '
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
    TypeText() => _unsupported(
      'Sharp IP control cannot type text (only the UPnP service on port '
      '12346 can, which this driver does not use)',
    ),
    Media(:final action) => _media(action),
    MovePointer() => _unsupported('Sharp IP control has no pointer'),
    ShowToast() => _unsupported('Sharp IP control cannot show messages'),
    CastUrl() => _unsupported(
      'Sharp IP control cannot play URLs (the TV DLNA renderer is a '
      'separate UPnP service)',
    ),
    TakeScreenshot() => _unsupported(
      'Sharp IP control cannot take screenshots',
    ),
  };

  Future<CommandResult> _pressKey(RemoteKey key, KeyAction action) async {
    if (action != KeyAction.click) {
      return Unsupported(
        'Sharp IP control has no press-and-hold; ${key.name} can only be '
        'clicked',
      );
    }
    switch (key) {
      case RemoteKey.powerOn:
        return _setPower(true);
      case RemoteKey.powerOff:
        return _setPower(false);
      case RemoteKey.mute:
        return _setMute(null);
      case RemoteKey.channelUp || RemoteKey.channelDown
          when _profile.channels != SharpChannels.keys:
        return _channelStep(up: key == RemoteKey.channelUp);
      case RemoteKey.volumeUp || RemoteKey.volumeDown
          when !_profile.rcky.containsAll(const [32, 33]):
        return _stepVolume(key == RemoteKey.volumeUp ? 1 : -1);
      default:
        break;
    }
    if (sharpInputKeys[key] case final input?) return _selectInput(input);
    final code = sharpKeyCodes[key];
    if (code == null) {
      return Unsupported('Sharp IP control has no ${key.name} key');
    }
    if (!_profile.rcky.contains(code)) {
      return Unsupported(
        'The ${_profile.label} command set has no ${key.name} remote key',
      );
    }
    if (sharpWakeKeys.contains(code)) return _wakeKey(code, 'the POWER key');
    await _write('RCKY', '$code', what: 'the ${key.name} key');
    switch (key) {
      case RemoteKey.volumeUp || RemoteKey.volumeDown:
        _setState(_state.copyWith(volume: _state.volume?.asStale()));
      case RemoteKey.channelUp || RemoteKey.channelDown:
        _inferInput('tv');
      default:
        break;
    }
    return const Confirmed();
  }

  /// Sends a key that can wake the TV from standby ([sharpWakeKeys]) only
  /// when `POWR?` reads on right now, outside the window after `POWR0`;
  /// otherwise refuses, so that every power change stays with the power
  /// orchestrator.
  Future<CommandResult> _wakeKey(int code, String what) async {
    if (_offSettling) {
      return Failed(
        WatchmeError.rejected(
          'The TV was just turned off, and $what could turn it on again; '
          'watchme does not send it now',
        ),
      );
    }
    final power = _profile.queries ? await _read('POWR') : null;
    if (power != '1') {
      _observePower(power);
      return Failed(
        WatchmeError.rejected(
          power == '0'
              ? 'The TV is in standby, and $what could turn it on; turn it '
                    'on first'
              : 'watchme cannot tell whether the TV is on, and $what could '
                    'turn it on, so it does not send it',
          rawDeviceMessage: power ?? sharpErr,
        ),
      );
    }
    _observePower(power);
    await _write('RCKY', '$code', what: what);
    if (code == sharpPowerKey) {
      // The toggle turned an "on" TV off.
      _offUntil = _clock.now().add(_timings.powerOffSettle);
      _bootUntil = null;
      _retryUntil = null;
      _standby = true;
      _setState(
        _state.copyWith(
          power: Observed.inferred(
            PowerMode.standby,
            sharpDriverId,
            _clock.now(),
          ),
        ),
      );
    }
    return const Confirmed();
  }

  Future<CommandResult> _setPower(bool on) async {
    if (on && !_profile.powerOn) {
      return Unsupported(
        'The ${_profile.label} command set has no power-on command (POWR1); '
        'use Wake-on-LAN, HDMI-CEC or IR',
      );
    }
    try {
      await _write(
        'POWR',
        on ? '1' : '0',
        what: on ? 'power on (POWR1)' : 'power off (POWR0)',
        timeout: _timings.powerReply,
        retryWhileBooting: on,
      );
    } on WatchmeError catch (e) {
      if (e.code == WatchmeErrorCode.timeout ||
          e.code == WatchmeErrorCode.protocol) {
        // It may have acted: what the session believed no longer holds,
        // and a TV that took it reads its old state for a while, so the
        // settle window applies as after a confirmed one (without the
        // resends, which only a confirmed POWR1 earns).
        _setState(_state.copyWith(power: _state.power?.asStale()));
        final now = _clock.now();
        if (on) {
          _bootUntil = now.add(_timings.powerOnSettle);
          _offUntil = null;
        } else {
          _offUntil = now.add(_timings.powerOffSettle);
          _bootUntil = null;
          _retryUntil = null;
        }
      }
      rethrow;
    }
    final now = _clock.now();
    if (on) {
      _bootUntil = now.add(_timings.powerOnSettle);
      _retryUntil = _bootUntil;
      _offUntil = null;
      _standby = false;
    } else {
      _offUntil = now.add(_timings.powerOffSettle);
      _bootUntil = null;
      _retryUntil = null;
      _standby = true;
    }
    _setState(
      _state.copyWith(
        power: Observed.inferred(
          on ? PowerMode.on : PowerMode.standby,
          sharpDriverId,
          now,
        ),
      ),
    );
    return const Confirmed();
  }

  Future<CommandResult> _setVolume(int level) async {
    if (!_profile.absoluteVolume) {
      return const Unsupported(
        'This firmware refuses absolute volume (VOLM); use StepVolume',
      );
    }
    final raw = (level * _volumeMax / 100).round().clamp(0, _volumeMax);
    await _write(
      'VOLM',
      '$raw',
      what: 'volume $raw (VOLM)',
      retryWhileBooting: true,
    );
    _setVolumeState(raw, reported: false);
    return const Confirmed();
  }

  Future<CommandResult> _stepVolume(int steps) async {
    if (steps == 0) return const Confirmed();
    if (steps.abs() > sharpMaxVolumeSteps) {
      return const Unsupported(
        'At most $sharpMaxVolumeSteps volume steps at a time',
      );
    }
    // One read and one absolute write, where the TV reads its volume: a
    // single request cannot be half delivered.
    if (_profile.absoluteVolume && _profile.queries) {
      final current = await _readVolume();
      if (current != null) {
        final target = (current + steps).clamp(0, _volumeMax);
        if (target != current) {
          await _write(
            'VOLM',
            '$target',
            what: 'volume $target (VOLM)',
            retryWhileBooting: true,
          );
        }
        _setVolumeState(target, reported: false);
        return const Confirmed();
      }
      // VOLM? refused: a TV in standby takes no volume keys either.
      if (_standby) throw _refusal('the volume');
    }
    if (_profile.rcky.containsAll(const [32, 33])) {
      final code = steps > 0 ? 33 : 32;
      for (var i = 0; i < steps.abs(); i++) {
        await _write(
          'RCKY',
          '$code',
          what: 'volume step ${i + 1} of ${steps.abs()}',
        );
      }
      _setState(_state.copyWith(volume: _state.volume?.asStale()));
      return const Confirmed();
    }
    throw WatchmeError.rejected(
      _standby
          ? 'The TV did not read its volume: it is in standby'
          : 'The TV did not read its volume, and this model has no volume '
                'keys',
      rawDeviceMessage: sharpErr,
    );
  }

  Future<CommandResult> _setMute(bool? muted) async {
    if (muted == null) {
      await _write('MUTE', '0', what: 'the mute toggle (MUTE0)');
      final known = _state.muted;
      if (known != null && known.confidence != Confidence.stale) {
        _setState(
          _state.copyWith(
            muted: Observed.inferred(!known.value, sharpDriverId, _clock.now()),
          ),
        );
      }
      return const Confirmed();
    }
    if (!_profile.discreteMute) {
      return const Unsupported(
        'This firmware has only the mute toggle (MUTE0); send SetMute(null)',
      );
    }
    await _write(
      'MUTE',
      muted ? '1' : '2',
      what: muted ? 'mute (MUTE1)' : 'unmute (MUTE2)',
      retryWhileBooting: true,
    );
    _setState(
      _state.copyWith(
        muted: Observed.inferred(muted, sharpDriverId, _clock.now()),
      ),
    );
    return const Confirmed();
  }

  Future<CommandResult> _launch(LaunchApp c) async {
    if (!_profile.rcky.contains(sharpNetflixKey)) {
      return Unsupported(
        'The ${_profile.label} command set cannot open apps (it has no '
        'NETFLIX key)',
      );
    }
    if (c.appId.trim().toLowerCase() != sharpNetflixAppId) {
      return Unsupported(
        'Sharp IP control opens only Netflix (its remote key), not '
        '"${c.appId}"',
      );
    }
    if (c.deepLink != null || c.params.isNotEmpty) {
      return const Unsupported(
        'The NETFLIX key takes no deep link or parameters',
      );
    }
    final result = await _wakeKey(sharpNetflixKey, 'the NETFLIX key');
    if (result is Confirmed) {
      _setState(
        _state.copyWith(
          foregroundApp: Observed.inferred(
            _netflix,
            sharpDriverId,
            _clock.now(),
          ),
        ),
      );
    }
    return result;
  }

  static const AppInfo _netflix = AppInfo(
    id: sharpNetflixAppId,
    name: 'Netflix',
  );

  Future<CommandResult> _listApps() async =>
      _profile.rcky.contains(sharpNetflixKey)
      ? const Confirmed(payload: AppListPayload([_netflix]))
      : Unsupported(
          'The ${_profile.label} command set has no app list and no NETFLIX '
          'key',
        );

  Future<CommandResult> _selectInput(String inputId) async {
    var want = inputId.trim().toLowerCase();
    if (want == 'tuner') want = 'tv';
    if (_profile.region == SharpRegion.eu && want == 'av1') want = 'ext1';
    final entry = _profile.inputs.entries
        .where((e) => e.key.toLowerCase() == want)
        .firstOrNull;
    if (entry == null) {
      return Unsupported(
        _profile.inputs.isEmpty
            ? 'The ${_profile.label} command set cannot switch inputs'
            : 'Unknown input "$inputId" for ${_profile.label}; use '
                  '${_profile.inputs.keys.join(', ')}',
      );
    }
    final (:command, :parameter, :iavd) = entry.value;
    final what = 'input ${entry.key} ($command)';
    while (true) {
      final reply = await _request(sharpFrame(command, parameter));
      if (reply == sharpOk) {
        _delivered++;
        _inferInput(entry.key);
        return const Confirmed();
      }
      if (reply != sharpErr) throw _unexpected(what, reply);
      // Some sets refuse IAVDn for the input already in front; reading it
      // back is a query, and the write is never sent again for it.
      if (iavd != null && _profile.queries) {
        final current = await _read('IAVD');
        if (current != null && int.tryParse(current) == iavd) {
          _setState(
            _state.copyWith(
              input: Observed.reported(entry.key, sharpDriverId, _clock.now()),
            ),
          );
          return const Confirmed();
        }
      }
      if (!await _waitWhileBooting()) throw _refusal(what);
    }
  }

  Future<CommandResult> _tune(String channel) async {
    final requests = switch (_profile.channels) {
      SharpChannels.us => sharpUsTuneRequests(channel),
      SharpChannels.eu => sharpEuTuneRequests(channel),
      SharpChannels.upDown || SharpChannels.keys => null,
    };
    if (requests == null) {
      return Unsupported(switch (_profile.channels) {
        SharpChannels.us =>
          'Not a channel the US command set can tune: "$channel" (use 7, '
              '7.1, 123.45 or a 5-digit cable channel)',
        SharpChannels.eu => 'Not a digital channel 1-999: "$channel"',
        _ => 'The ${_profile.label} command set has no direct tuning',
      });
    }
    for (final r in requests) {
      await _write(
        r.command,
        r.parameter,
        what: 'channel $channel (${r.command})',
      );
    }
    _inferInput(_profile.region == SharpRegion.eu ? 'dtv' : 'tv');
    return const Confirmed();
  }

  Future<CommandResult> _channelStep({required bool up}) async {
    final command = up ? 'CHUP' : 'CHDW';
    await _write(command, _profile.noArgument, what: 'channel $command');
    if (_profile.region == SharpRegion.us) _inferInput('tv');
    return const Confirmed();
  }

  Future<CommandResult> _media(MediaAction action) async {
    final code = sharpMediaCodes[action];
    if (code == null) {
      return Unsupported(
        action == MediaAction.playPause
            ? 'Sharp has separate play and pause keys, no toggle'
            : 'Sharp IP control cannot ${action.name}',
      );
    }
    if (!_profile.rcky.contains(code)) {
      return Unsupported(
        'The ${_profile.label} command set has no ${action.name} key',
      );
    }
    await _write('RCKY', '$code', what: 'the ${action.name} key');
    return const Confirmed();
  }

  Future<CommandResult> _unsupported(String reason) =>
      Future.value(Unsupported(reason));

  // --------------------------------------------------------------- reading

  /// Passive: sends only `POWR?` and, while the TV reads on, `VOLM?`,
  /// `MUTE?` and `IAVD?`. Never wakes the TV.
  @override
  Future<DeviceState> refresh() => _serial(() async {
    _beginBatch();
    try {
      if (_closed) throw _closedError;
      final power = await _read('POWR');
      _observePower(power);
      if (power == '1' && !_offSettling && _profile.queries) {
        await _readOnState();
      }
      return _state;
    } on WatchmeError catch (e) {
      throw _redact(e);
    } finally {
      _endBatch();
    }
  });

  /// The reads that answer only while the TV is on.
  Future<void> _readOnState() async {
    if (_modelPending) {
      _modelPending = false;
      final model = await _readInfo('MNRD');
      final match = sharpProfileForModel(model);
      if (model != null) _model = model;
      if (match != null) {
        _profile = match.profile;
        if (!_volumeFixed) {
          _volumeCertain = match.volumeCertain;
          _volumeMax = match.volumeMax;
        }
        _updateCapabilities();
      }
    }
    if (_profile.absoluteVolume) {
      final volume = await _readVolume();
      if (volume != null) _setVolumeState(volume, reported: true);
    }
    final mute = await _read('MUTE');
    if (mute != null) {
      if (mute != '1' && mute != '2') throw _unexpected('MUTE?', mute);
      _setState(
        _state.copyWith(
          muted: Observed.reported(mute == '1', sharpDriverId, _clock.now()),
        ),
      );
    }
    if (_profile.inputs.values.any((i) => i.iavd != null)) {
      final input = await _read('IAVD');
      final n = input == null ? null : int.tryParse(input);
      if (input != null && n == null) throw _unexpected('IAVD?', input);
      final id = n == null ? null : _profile.inputForIavd(n);
      if (id != null) {
        _setState(
          _state.copyWith(
            input: Observed.reported(id, sharpDriverId, _clock.now()),
          ),
        );
      } else if (input == null) {
        // The tuner or an app is in front: the last input no longer holds.
        _setState(_state.copyWith(input: _state.input?.asStale()));
      }
    }
  }

  /// `VOLM?` as a raw level, or `null` for `ERR`. A reading above 60 proves
  /// the 0-100 scale.
  Future<int?> _readVolume() async {
    final reply = await _read('VOLM');
    if (reply == null) return null;
    final raw = int.tryParse(reply);
    if (raw == null || raw < 0 || raw > 100) throw _unexpected('VOLM?', reply);
    if (raw > _volumeMax && !_volumeFixed) {
      _volumeMax = 100;
      _volumeCertain = true;
      _updateCapabilities();
    }
    return raw;
  }

  /// Takes in a `POWR?` reply ([reply] `null` for `ERR`).
  void _observePower(String? reply) {
    final now = _clock.now();
    switch (reply) {
      case null:
        // Changing state, or a firmware without readback.
        return;
      case '1':
        _markPowerSeen();
        // A TV just told to power off may still read on.
        if (_offSettling) return;
        _standby = false;
        _bootUntil = null;
        _setState(
          _state.copyWith(
            power: Observed.reported(PowerMode.on, sharpDriverId, now),
          ),
        );
      case '0':
        _markPowerSeen();
        // A TV just told to power on reads standby while it boots.
        if (_booting) return;
        _standby = true;
        _retryUntil = null;
        _setState(
          _state.copyWith(
            power: Observed.reported(PowerMode.standby, sharpDriverId, now),
            input: _state.input?.asStale(),
          ),
        );
      default:
        throw _unexpected('POWR?', reply);
    }
  }

  void _markPowerSeen() {
    if (_powerStateSeen) return;
    _powerStateSeen = true;
    _updateCapabilities();
  }

  bool get _booting {
    final until = _bootUntil;
    return until != null && _clock.now().isBefore(until);
  }

  bool get _offSettling {
    final until = _offUntil;
    return until != null && _clock.now().isBefore(until);
  }

  /// Waits [SharpTimings.bootRetryInterval] when the TV may still be
  /// starting after a delivered `POWR1`; `false` (no wait) otherwise.
  Future<bool> _waitWhileBooting() async {
    final until = _retryUntil;
    if (until == null || !_clock.now().isBefore(until)) return false;
    await _clock.delay(_timings.bootRetryInterval);
    _checkOpen();
    return true;
  }

  // -------------------------------------------------------------- requests

  /// Sends a write: returns on `OK`, which counts towards what the command
  /// delivered; `ERR` is [WatchmeErrorCode.rejected]. With
  /// [retryWhileBooting] (idempotent absolute commands only), an `ERR`
  /// within the boot window is followed by the same write again: `ERR`
  /// means the TV did not act, so nothing is repeated.
  Future<void> _write(
    String command,
    String parameter, {
    required String what,
    Duration? timeout,
    bool retryWhileBooting = false,
  }) async {
    final frame = sharpFrame(command, parameter);
    while (true) {
      final reply = await _request(frame, timeout: timeout);
      if (reply == sharpOk) {
        _delivered++;
        return;
      }
      if (reply != sharpErr) throw _unexpected(what, reply);
      if (!(retryWhileBooting && await _waitWhileBooting())) {
        throw _refusal(what);
      }
    }
  }

  /// A query: the value, or `null` for `ERR`.
  Future<String?> _read(String command) async {
    final reply = await _request(sharpQuery(command), query: true);
    return reply == sharpErr ? null : reply;
  }

  /// An information command (`MNRD1`, `TVNM1`, ...): the value, or `null`
  /// for `ERR` or no answer (it is optional everywhere).
  Future<String?> _readInfo(String command) async {
    try {
      final reply = await _request(sharpFrame(command, '1'), query: true);
      return reply == sharpErr || reply.isEmpty ? null : reply;
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.timeout) rethrow;
      return null;
    }
  }

  /// Sends one request and returns the reply. Every request goes through
  /// here, so a command stops before its next request once [close] is
  /// called, and every answer or failure counts towards the connection
  /// state.
  Future<String> _request(
    String frame, {
    Duration? timeout,
    bool query = false,
  }) async {
    for (var attempt = 1; ; attempt++) {
      _checkOpen();
      final link = await _ensureLink();
      _checkOpen();
      try {
        final reply = await link.request(
          frame,
          timeout: timeout ?? _timings.reply,
          skipOk: query,
        );
        _answered();
        return reply;
      } on SharpLinkDown {
        // The TV closed the connection before the request went out:
        // nothing was delivered, so a new connection may carry it.
        _dropLink();
        if (attempt >= 2) {
          final error = WatchmeError.unreachable(
            'The TV kept closing the connection before ${frame.trim()} '
            'could be sent',
          );
          _lost(error);
          throw error;
        }
      } on WatchmeError catch (e) {
        _dropLink();
        if (e.code == WatchmeErrorCode.timeout &&
            !(_standby && !frame.startsWith('POWR'))) {
          _timedOut(e);
        }
        rethrow;
      } finally {
        _lastUsed = _clock.now();
        _touchIdle();
      }
    }
  }

  /// The open connection, or a new one (logged in) when the last one
  /// closed, at least [SharpTimings.reconnectGap] after it.
  Future<SharpLink> _ensureLink() async {
    final current = _link;
    if (current != null && current.isOpen) {
      // Let a close the TV already sent (its idle cut, standby) arrive
      // first, so that nothing is written into a dead connection.
      await Future<void>.delayed(Duration.zero);
      if (current.isOpen) return current;
    }
    _dropLink();
    final last = _lastClose;
    if (last != null) {
      final wait = last.add(_timings.reconnectGap).difference(_clock.now());
      if (wait > Duration.zero) await _clock.delay(wait);
    }
    _checkOpen();
    try {
      final link = await openSharpLink(
        network: _network,
        host: _endpoint.host,
        port: _endpoint.port(SharpPorts.ipc, SharpPorts.ipcDefault),
        clock: _clock,
        timings: _timings,
        credential: _credential,
      );
      if (_closed) {
        await link.close();
        throw _closedError;
      }
      _link = link;
      _markReachable();
      return link;
    } on WatchmeError catch (e) {
      var error = _redact(e);
      switch (error.code) {
        case WatchmeErrorCode.unreachable:
          _lost(error);
        case WatchmeErrorCode.unauthorized || WatchmeErrorCode.reauthRequired:
          if (error.code == WatchmeErrorCode.unauthorized) {
            error = WatchmeError.reauthRequired(
              error.message,
              rawDeviceMessage: error.rawDeviceMessage,
              cause: error,
            );
          }
          _reauth(error);
        case WatchmeErrorCode.timeout:
          _timedOut(error);
        default:
          break;
      }
      throw error;
    }
  }

  void _dropLink() {
    final link = _link;
    _link = null;
    if (link == null) return;
    _discardedBefore += link.discardedBytes;
    _lastClose = link.closedAt ?? _clock.now();
    unawaited(link.close());
  }

  void _touchIdle() {
    _idleTimer?.cancel();
    if (_closed) return;
    _idleTimer = _clock.timer(_timings.idleClose, () {
      unawaited(
        _serial(() async {
          if (_closed) return;
          if (_clock.now().difference(_lastUsed) >= _timings.idleClose) {
            _dropLink();
          }
        }),
      );
    });
  }

  void _checkOpen() {
    if (_closed) throw _closedError;
  }

  WatchmeError _refusal(String what) => WatchmeError.rejected(
    _standby
        ? 'The TV refused $what: it is in standby'
        : 'The TV refused $what',
    rawDeviceMessage: sharpErr,
  );

  /// An answer that fits nothing: the connection is closed so the next
  /// request starts in step.
  WatchmeError _unexpected(String what, String reply) {
    _dropLink();
    return WatchmeError.protocol(
      'Unexpected answer from the TV to $what',
      rawDeviceMessage: reply,
    );
  }

  WatchmeError _redact(WatchmeError error) => redactSharpError(error, _secrets);

  // ------------------------------------------------------------ connection

  void _answered() {
    _timeouts = 0;
    _markReachable();
  }

  void _timedOut(WatchmeError e) {
    if (++_timeouts >= sharpTimeoutsBeforeDisconnect) _lost(e);
  }

  /// The TV stopped answering: marks every observation stale and reports
  /// the session disconnected with [e] (once).
  void _lost(WatchmeError e) {
    if (_closed || _connection != ConnectionState.connected) return;
    _connection = ConnectionState.disconnected;
    _setState(
      _state.markStale().copyWith(
        connections: const {sharpDriverId: ConnectionState.disconnected},
      ),
    );
    _emit(
      ConnectionChanged(
        ConnectionState.disconnected,
        driverId: sharpDriverId,
        error: e,
      ),
    );
  }

  void _markReachable() {
    if (_closed || _connection != ConnectionState.disconnected) return;
    _connection = ConnectionState.connected;
    _setState(
      _state.copyWith(
        connections: const {sharpDriverId: ConnectionState.connected},
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.connected,
        driverId: sharpDriverId,
      ),
    );
  }

  void _reauth(WatchmeError error) {
    if (_reauthReported || _closed) return;
    _reauthReported = true;
    _connection = ConnectionState.failed;
    _setState(
      _state.copyWith(
        connections: const {sharpDriverId: ConnectionState.failed},
      ),
    );
    _emit(ReauthRequired(error, driverId: sharpDriverId));
    _emit(
      ConnectionChanged(
        ConnectionState.failed,
        driverId: sharpDriverId,
        error: error,
      ),
    );
  }

  // ----------------------------------------------------------------- state

  void _setVolumeState(int raw, {required bool reported}) {
    final level = (raw * 100 / _volumeMax).round().clamp(0, 100);
    final now = _clock.now();
    _setState(
      _state.copyWith(
        volume: reported && _volumeCertain
            ? Observed.reported(level, sharpDriverId, now)
            : Observed.inferred(level, sharpDriverId, now),
      ),
    );
  }

  void _inferInput(String id) => _setState(
    _state.copyWith(input: Observed.inferred(id, sharpDriverId, _clock.now())),
  );

  /// Holds [StateChanged] back until [_endBatch], so that one command or
  /// refresh emits one event.
  void _beginBatch() => _batchStart ??= _state;

  void _endBatch() {
    final start = _batchStart;
    _batchStart = null;
    if (start != null) _emitChanges(start, _state);
  }

  /// Adopts [next] and emits the fields whose value or confidence changed
  /// (a poll that only re-stamps an observation is not a change).
  void _setState(DeviceState next) {
    final previous = _state;
    _state = next;
    if (_batchStart == null) _emitChanges(previous, next);
  }

  void _emitChanges(DeviceState previous, DeviceState next) {
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
    if (!diff.isEmpty) _emit(StateChanged(diff, driverId: sharpDriverId));
  }

  List<CapabilitySupport> _computeCapabilities() => sharpCapabilities(
    _profile,
    powerStateSeen: _powerStateSeen,
    volumeCertain: _volumeCertain,
    volumeMax: _volumeMax,
  );

  void _updateCapabilities() {
    final next = _computeCapabilities();
    final same =
        next.length == _caps.length &&
        [for (var i = 0; i < next.length; i++) next[i] == _caps[i]]
            .every((e) => e);
    if (same) return;
    _caps = next;
    _emit(CapabilitiesChanged(next, driverId: sharpDriverId));
  }

  void _emit(DeviceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // --------------------------------------------------------------- polling

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
      // A lost TV surfaces as ConnectionChanged; a single timeout leaves
      // the session as it was until the next poll.
    } finally {
      _polling = false;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopPolling();
    _idleTimer?.cancel();
    final link = _link;
    _link = null;
    _connection = ConnectionState.disconnected;
    _state = _state.copyWith(
      connections: const {sharpDriverId: ConnectionState.disconnected},
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.disconnected,
        driverId: sharpDriverId,
      ),
    );
    await link?.close();
    await _events.close();
  }

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}
