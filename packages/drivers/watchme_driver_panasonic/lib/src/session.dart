import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'client.dart';
import 'constants.dart';
import 'crypto.dart';
import 'descriptor.dart';
import 'keys.dart';
import 'redaction.dart';
import 'soap.dart';

/// How many requests in a row must time out, with no answer in between,
/// before a session reports its TV lost. One slow answer is not a lost TV
/// (the TV is briefly deaf around its periodic SSDP announcements); three
/// are.
const int panasonicTimeoutsBeforeDisconnect = 3;

/// The longest text one `TypeText` sends.
const int panasonicMaxTextLength = 1024;

/// The most digits one `TuneChannel` presses.
const int panasonicMaxChannelDigits = 8;

/// How often a session polls volume, mute and the foreground app while its
/// events are listened to, unless configured otherwise. Crestron's module
/// notes advise polling a VIERA in standby no faster than every 15 s:
/// faster polling yields spurious timeouts.
const Duration panasonicDefaultPollInterval = Duration(seconds: 15);

const String _instance = '<InstanceID>0</InstanceID><Channel>Master</Channel>';

/// Failure codes that prove a request reached nothing or was turned down,
/// so nothing it asked for happened.
const Set<WatchmeErrorCode> _nothingDone = {
  WatchmeErrorCode.unreachable,
  WatchmeErrorCode.destinationRefused,
  WatchmeErrorCode.rejected,
  WatchmeErrorCode.unsupported,
  WatchmeErrorCode.unauthorized,
  WatchmeErrorCode.reauthRequired,
  WatchmeErrorCode.cancelled,
};

/// A session with one VIERA's network remote control, created by
/// `PanasonicDriver.connect`.
///
/// Keys, apps and text go to the NRC service, wrapped in
/// `X_EncryptedCommand` on encrypted TVs; volume and mute go to UPnP
/// RenderingControl, which is plain and needs no pairing on any set.
///
/// **Encrypted sessions.** An encrypted session is opened on connect and
/// again whenever the TV answers an encrypted command with HTTP 500 (two
/// field clients treat any 500 as a lost session). The command the TV
/// refused that way is sent once more on the fresh session, with a new
/// sequence number; nothing else is ever retried. Sequence numbers only
/// grow, and every NRC request goes through one queue, so they reach the
/// TV in order.
///
/// **Power.** VIERA has only the `NRC_POWER-ONOFF` toggle. `SetPower`
/// returns [Unsupported], so the power orchestrator sends the power key
/// instead, which happens only under its two-source rule. Before the
/// toggle an encrypted session is always opened afresh (a power change may
/// have invalidated the old one, and a refused toggle may not be resent);
/// if that fails, no toggle goes out and the failure is returned. The
/// toggle itself is never retried. The power state is at most inferred:
/// RenderingControl's HTTP 400 hints at standby, and a Pro AV description
/// that answers proves the TV on; anything that merely answers proves
/// nothing. A read that sees neither, and any toggle that may have acted,
/// make an earlier inference stale, so it never outlives its evidence.
///
/// **Delivery.** A command sent as several requests (channel digits) that
/// fails after one of them was accepted reports
/// [WatchmeErrorCode.partiallyDelivered]. Reads, and the session requests
/// that encrypted commands need, never count as delivered. An HTTP 200
/// that is not a well-formed answer to the request (an HTML page, say, a
/// truncated document, or a decrypted fragment without the
/// acknowledgement, or for a read without the value asked for) is a
/// protocol error: it confirms nothing, is never retried, and stops the
/// command.
///
/// **Connection.** A request that reaches nothing, or
/// [panasonicTimeoutsBeforeDisconnect] timeouts in a row, mark the session
/// disconnected and its state stale; any answer brings it back. [refresh]
/// never wakes the TV.
///
/// No error or event carries the app id, the keyword, a session number or
/// any encrypted blob.
final class PanasonicSession implements DriverSession {
  PanasonicSession._(
    this._client,
    this._clock, {
    required this.encrypted,
    required this.model,
    required Set<String>? nrcCapabilities,
    required this._pollInterval,
    required this._allowKeyHolds,
    this._appId,
    this._keyword,
    this._keys,
  }) : _nrcCapabilities = nrcCapabilities,
       _caps = panasonicCapabilities(nrcCapabilities: nrcCapabilities) {
    _events = StreamController<DeviceEvent>.broadcast(
      onListen: _startPolling,
      onCancel: _stopPolling,
    );
  }

  /// Reads the TV's service description and opens a session: an encrypted
  /// one (with [credential]) when the TV encrypts its remote control, a
  /// plain one otherwise. Sends nothing that can wake the TV or change
  /// what it shows.
  ///
  /// Throws [WatchmeError]: transport codes when the TV does not answer,
  /// [WatchmeErrorCode.unauthorized] for an encrypted TV without
  /// [credential], [WatchmeErrorCode.reauthRequired] when the TV no longer
  /// accepts it, and [WatchmeErrorCode.rejected] for the subnet rule (HTTP
  /// 403) or a session the TV refused while it may be in standby.
  static Future<PanasonicSession> connect(
    VieraClient client,
    SharedSecretCredential? credential, {
    Clock clock = const SystemClock(),
    Duration? pollInterval = panasonicDefaultPollInterval,
    bool allowKeyHolds = false,
  }) async {
    final secrets = [?credential?.username, ?credential?.secret];
    try {
      final sdd = await client.get(VieraPaths.nrcService);
      if (!sdd.ok) {
        throw vieraHttpError(
          sdd,
          'Reading the NRC service description',
          secrets: secrets,
        );
      }
      final encrypted = isEncryptedService(sdd.text);
      String? appId;
      VieraKeys? keys;
      if (encrypted) {
        if (credential == null) {
          throw const WatchmeError.unauthorized(
            'This Panasonic TV encrypts its remote control: pair with it '
            'first',
          );
        }
        appId = credential.username;
        try {
          keys = VieraKeys.forSession(credential.secret);
        } on FormatException {
          keys = null;
        }
        if (appId == null || appId.isEmpty || keys == null) {
          throw const WatchmeError.reauthRequired(
            'The stored Panasonic pairing is incomplete; pair again',
          );
        }
      }
      // Optional: it only narrows the capabilities and names the model.
      VieraDescription? description;
      try {
        final ddd = await client.get(VieraPaths.nrcDescription);
        if (ddd.ok) description = VieraDescription.parse(ddd.text);
      } on FormatException {
        description = null;
      } on WatchmeError {
        description = null;
      }
      final session = PanasonicSession._(
        client,
        clock,
        encrypted: encrypted,
        model: description?.modelNumber,
        nrcCapabilities: description?.nrcCapabilities,
        pollInterval: pollInterval,
        allowKeyHolds: allowKeyHolds,
        appId: appId,
        keyword: credential?.secret,
        keys: keys,
      );
      if (encrypted) await session._openSession(inConnect: true);
      // Also finds out whether the TV has Pro AV control (see [hasPac]).
      await session._readState(strict: false);
      return session;
    } on WatchmeError catch (e) {
      throw redactVieraError(e, secrets);
    }
  }

  final VieraClient _client;
  final Clock _clock;
  final bool _allowKeyHolds;
  final Duration? _pollInterval;
  final String? _appId;
  final String? _keyword;
  final VieraKeys? _keys;
  final Set<String>? _nrcCapabilities;
  List<CapabilitySupport> _caps;
  late final StreamController<DeviceEvent> _events;
  final Map<String, String> _appNames = {};

  /// Whether the TV encrypts its NRC commands (and so needed pairing).
  final bool encrypted;

  /// The model number from the device description, e.g. `TX-55GZ1500`.
  final String? model;

  /// Whether the TV's Pro AV control (PAC) answered: PAC input codes and
  /// the current input are available. A PAC model answers only while it is
  /// on, so a session opened in standby learns it at a later read, and then
  /// emits [CapabilitiesChanged].
  bool get hasPac => _pac;
  bool _pac = false;

  String? _sessionId;
  int _sequence = 0;

  DeviceState _state = const DeviceState(
    connections: {panasonicDriverId: ConnectionState.connected},
  );
  ConnectionState _connection = ConnectionState.connected;
  Future<void> _queue = Future.value();
  Timer? _pollTimer;
  bool _polling = false;
  bool _closed = false;
  bool _reauthReported = false;

  /// Device-changing requests of the running command that the TV accepted.
  int _delivered = 0;

  /// Requests that timed out since the TV last answered.
  int _timeouts = 0;

  /// Encrypted answers whose trailing HMAC did not verify. Whether real
  /// TVs always send a valid one is unconfirmed, so such answers are still
  /// used; this counts them for diagnostics.
  int get macFailures => _macFailures;
  int _macFailures = 0;

  /// How many encrypted sessions this session opened.
  int get sessionsOpened => _sessionsOpened;
  int _sessionsOpened = 0;

  static const WatchmeError _closedError = WatchmeError.cancelled(
    'The Panasonic session is closed',
  );

  @override
  String get driverId => panasonicDriverId;

  @override
  List<CapabilitySupport> get capabilities => List.unmodifiable(_caps);

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  /// The values no error may show: the app id and the keyword.
  List<String> get _secrets => [?_appId, ?_keyword];

  WatchmeError _redact(WatchmeError error) => redactVieraError(error, _secrets);

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
          WatchmeError.internal(
            'Panasonic ${command.type} failed: ${e.runtimeType}',
            cause: e,
          ),
        ),
      );
    }
  });

  /// The error of a command that stopped with [error], redacted: [error]
  /// itself while none of its requests took effect, otherwise
  /// [WatchmeErrorCode.partiallyDelivered] with [error] as the cause.
  WatchmeError _failure(Command command, WatchmeError error) {
    final e = _redact(error);
    if (_delivered == 0 || e.code == WatchmeErrorCode.partiallyDelivered) {
      return e;
    }
    return WatchmeError.partiallyDelivered(
      'Panasonic ${command.type} stopped after $_delivered of its requests '
      'reached the TV: ${e.message}',
      rawDeviceMessage: e.rawDeviceMessage,
      cause: e,
    );
  }

  Future<CommandResult> _dispatch(Command command) => switch (command) {
    PressKey(:final key, :final action) => _pressKey(key, action),
    SetPower() => _unsupported(
      'Panasonic VIERA has only a power toggle; watchme sends it as the '
      'power key under the power rules',
    ),
    SetVolume(:final level) => _setVolume(level),
    StepVolume(:final steps) => _stepVolume(steps),
    SetMute(:final muted) => _setMute(muted),
    final LaunchApp c => _launch(c),
    ListApps() => _listApps(),
    SelectInput(:final inputId) => _selectInput(inputId),
    TuneChannel(:final channel) => _tune(channel),
    TypeText(:final text, :final replace) => _typeText(text, replace),
    Media(:final action) => _media(action),
    MovePointer() => _unsupportedCap(Capability.pointer),
    ShowToast() => _unsupportedCap(Capability.notificationToast),
    CastUrl() => _unsupportedCap(Capability.castMediaUrl),
    TakeScreenshot() => _unsupportedCap(Capability.screenshot),
  };

  Future<CommandResult> _pressKey(RemoteKey key, KeyAction action) async {
    if (key == RemoteKey.power) {
      if (action != KeyAction.click) {
        return const Unsupported(
          'The VIERA power key is a toggle, so it cannot be held',
        );
      }
      return _powerToggle();
    }
    if (key == RemoteKey.powerOn || key == RemoteKey.powerOff) {
      return const Unsupported(
        'Panasonic VIERA has no discrete power keys, only the power toggle',
      );
    }
    final name = vieraKeyName(key, model: model);
    if (name == null) return Unsupported('VIERA has no ${key.name} key');
    if (action != KeyAction.click) {
      if (!_allowKeyHolds) {
        return const Unsupported(
          'Holding VIERA keys is off: a release that never arrives leaves '
          'the key held on the TV',
        );
      }
      if (!vieraHoldableKeys.contains(key)) {
        return Unsupported(
          'VIERA can hold only the d-pad and volume keys, '
          'not ${key.name}',
        );
      }
    }
    await _sendKey(name, action);
    if (action == KeyAction.click) _inferFromKey(key, name);
    return const Confirmed();
  }

  Future<void> _sendKey(String name, KeyAction action) => _nrc(
    'X_SendKey',
    '<X_KeyEvent>${vieraKeyEvent(name, action)}</X_KeyEvent>',
    effect: true,
  );

  /// Sends `NRC_POWER-ONOFF` once. See the class notes.
  Future<CommandResult> _powerToggle() async {
    if (encrypted) {
      _dropSession();
      try {
        await _openSession();
      } on WatchmeError catch (e) {
        throw _toggleNotSent(e);
      }
    }
    try {
      await _nrc(
        'X_SendKey',
        '<X_KeyEvent>${vieraKeyEvent('POWER', KeyAction.click)}</X_KeyEvent>',
        effect: true,
        retryRefused: false,
      );
    } finally {
      // A power change may invalidate the encrypted session; the next
      // command opens a fresh one. Whatever the toggle's outcome (accepted,
      // or a timeout that may have reached the TV), the power state from
      // before it is no evidence any more.
      _dropSession();
      _emitState(_state.copyWith(power: _state.power?.asStale()));
    }
    return const Confirmed();
  }

  /// The failure of the fresh session a toggle needs, which kept the
  /// toggle from being sent. A session request that may have reached the
  /// TV (it timed out) is harmless, and no toggle went out, so the result
  /// is a refusal: nothing the power command asked for happened.
  static WatchmeError _toggleNotSent(WatchmeError e) {
    final message =
        'The power toggle was not sent: opening a fresh encrypted session '
        'failed first (${e.message})';
    return _nothingDone.contains(e.code)
        ? WatchmeError(
            e.code,
            message,
            rawDeviceMessage: e.rawDeviceMessage,
            cause: e,
          )
        : WatchmeError.rejected(
            message,
            rawDeviceMessage: e.rawDeviceMessage,
            cause: e,
          );
  }

  Future<CommandResult> _setVolume(int level) async {
    await _dmr(
      'SetVolume',
      '$_instance<DesiredVolume>$level</DesiredVolume>',
      effect: true,
    );
    await _afterVolumeChange(level);
    return const Confirmed();
  }

  /// Reads the volume back after a change to [level]; a failed read leaves
  /// the level watchme set, inferred.
  Future<void> _afterVolumeChange(int level) async {
    _emitState(_state.copyWith(volume: _inferred(level)));
    try {
      await _readVolume();
    } on WatchmeError {
      // The change was delivered; only the readback failed.
    }
  }

  /// One RenderingControl read, then at most one `SetVolume`: never a
  /// partial delivery. There is no fallback to volume keys: RenderingControl
  /// answers 403 to other subnets just as the NRC service does, and its 400
  /// in standby means keys would do nothing either. (A 400 while the TV is
  /// known to be on would allow keys, but nothing tells this driver that
  /// yet.)
  Future<CommandResult> _stepVolume(int steps) async {
    if (steps == 0) return const Confirmed();
    final current = await _readVolume();
    final target = (current + steps).clamp(0, 100);
    if (target == current) return const Confirmed();
    await _dmr(
      'SetVolume',
      '$_instance<DesiredVolume>$target</DesiredVolume>',
      effect: true,
    );
    await _afterVolumeChange(target);
    return const Confirmed();
  }

  Future<CommandResult> _setMute(bool? muted) async {
    final target = muted ?? !await _readMute();
    await _dmr(
      'SetMute',
      '$_instance<DesiredMute>${target ? 1 : 0}</DesiredMute>',
      effect: true,
    );
    _emitState(_state.copyWith(muted: _inferred(target)));
    try {
      await _readMute();
    } on WatchmeError {
      // The change was delivered; only the readback failed.
    }
    return const Confirmed();
  }

  static final RegExp _productId = RegExp(r'^[0-9A-Z]{16}$');
  static final RegExp _appIdShape = RegExp(r'^[0-9A-Za-z_.\-]{1,64}$');

  Future<CommandResult> _launch(LaunchApp c) async {
    if (c.deepLink != null || c.params.isNotEmpty) {
      return const Unsupported(
        'VIERA launches apps by id only; it takes no deep links or '
        'parameters',
      );
    }
    final id = c.appId.trim();
    if (!_appIdShape.hasMatch(id)) {
      return Unsupported('"$id" is not a VIERA app id');
    }
    // A 16-character product id from the app list; anything else is a
    // resource id (the browser is resource_id=1063).
    final keyword = _productId.hasMatch(id)
        ? 'product_id=$id'
        : 'resource_id=$id';
    await _nrc(
      'X_LaunchApp',
      '<X_AppType>vc_app</X_AppType>'
          '<X_LaunchKeyword>${xmlEscape(keyword)}</X_LaunchKeyword>',
      effect: true,
    );
    _emitState(
      _state.copyWith(
        foregroundApp: _inferred(AppInfo(id: id, name: _appNames[id] ?? id)),
      ),
    );
    return const Confirmed();
  }

  /// An empty list is what a TV in standby sends, not "no apps installed":
  /// it is reported as [Unsupported] with a standby observation.
  Future<CommandResult> _listApps() async {
    final list = await _nrc(
      'X_GetAppList',
      'None',
      effect: false,
      output: 'X_AppList',
    );
    if (list.trim().isEmpty) {
      _emitState(_state.copyWith(power: _observed(PowerMode.standby)));
      return const Unsupported(
        'The TV lists no apps while it is in standby; switch it on first',
      );
    }
    final apps = parseVieraAppList(list);
    if (apps.isEmpty) {
      throw WatchmeError.protocol(
        'The TV sent an app list watchme cannot read',
        rawDeviceMessage: _shown(list),
      );
    }
    _appNames
      ..clear()
      ..addEntries(apps.map((a) => MapEntry(a.id, a.name)));
    _emitState(_state.copyWith(power: _observed(PowerMode.on)));
    return Confirmed(payload: AppListPayload(List.unmodifiable(apps)));
  }

  static final RegExp _pacCode = RegExp(r'^[A-Z][A-Z0-9]{0,7}$');

  Future<CommandResult> _selectInput(String inputId) async {
    final id = inputId.trim();
    if (vieraInputKey(id) case final key?) {
      await _sendKey(key, KeyAction.click);
      _emitState(_state.copyWith(input: _inferred(vieraInputIdForKey(key))));
      return const Confirmed();
    }
    if (_pac && _pacCode.hasMatch(id)) {
      await _pacCall(
        'X_SendCtrlCmd',
        '<X_CtrlCmd>PAC_IMS:$id</X_CtrlCmd>',
        effect: true,
      );
      _emitState(_state.copyWith(input: _inferred(vieraInputIdForPac(id))));
      return const Confirmed();
    }
    if (const {'av', 'av1'}.contains(id.toLowerCase())) {
      return const Unsupported('VIERA has no AV input key');
    }
    return Unsupported(
      'Unknown VIERA input "$inputId"; use hdmi1-hdmi4 or tv'
      '${_pac ? ', or a Pro AV input code such as H1' : ''}',
    );
  }

  Future<CommandResult> _tune(String channel) async {
    final ch = channel.trim();
    if (ch.isEmpty) return const Unsupported('TuneChannel needs a channel');
    if (ch.contains('.') || ch.contains('-')) {
      return const Unsupported(
        'VIERA has no key for a sub-channel separator; send whole channel '
        'numbers',
      );
    }
    if (!RegExp(r'^[0-9]+$').hasMatch(ch)) {
      return Unsupported('VIERA tunes by channel number, not "$ch"');
    }
    if (ch.length > panasonicMaxChannelDigits) {
      return const Unsupported(
        'At most $panasonicMaxChannelDigits channel digits at a time',
      );
    }
    for (final digit in ch.split('')) {
      await _sendKey('D$digit', KeyAction.click);
    }
    return const Confirmed();
  }

  Future<CommandResult> _typeText(String text, bool replace) async {
    if (replace) {
      return const Unsupported(
        'VIERA cannot clear a text field: it has no backspace key',
      );
    }
    if (text.isEmpty) return const Confirmed();
    if (text.length > panasonicMaxTextLength) {
      return const Unsupported(
        'At most $panasonicMaxTextLength characters at a time',
      );
    }
    await _nrc(
      'X_SendString',
      '<X_String>${xmlEscape(text)}</X_String>',
      effect: true,
    );
    return const Confirmed();
  }

  Future<CommandResult> _media(MediaAction action) async {
    final name = switch (action) {
      MediaAction.play => 'PLAY',
      MediaAction.pause => 'PAUSE',
      MediaAction.stop => 'STOP',
      MediaAction.rewind => 'REW',
      MediaAction.fastForward => 'FF',
      MediaAction.next => 'SKIP_NEXT',
      MediaAction.previous => 'SKIP_PREV',
      MediaAction.playPause ||
      MediaAction.seek ||
      MediaAction.instantReplay => null,
    };
    if (name == null) {
      return Unsupported(
        action == MediaAction.playPause
            ? 'VIERA has no play/pause toggle; send play or pause'
            : 'VIERA has no ${action.name} key',
      );
    }
    await _sendKey(name, KeyAction.click);
    return const Confirmed();
  }

  void _inferFromKey(RemoteKey key, String name) {
    switch (key) {
      case RemoteKey.inputHdmi1 ||
          RemoteKey.inputHdmi2 ||
          RemoteKey.inputHdmi3 ||
          RemoteKey.inputHdmi4 ||
          RemoteKey.inputTuner:
        _emitState(_state.copyWith(input: _inferred(vieraInputIdForKey(name))));
      case RemoteKey.input:
        // NRC_CHG_INPUT cycles to an input watchme cannot know.
        _emitState(_state.copyWith(input: _state.input?.asStale()));
      case RemoteKey.home:
        // The home screen replaces the app in front.
        _emitState(
          _state.copyWith(foregroundApp: _state.foregroundApp?.asStale()),
        );
      case RemoteKey.volumeUp || RemoteKey.volumeDown:
        // A key step changes the level by an amount watchme cannot know.
        _emitState(_state.copyWith(volume: _state.volume?.asStale()));
      case RemoteKey.mute:
        _emitState(_state.copyWith(muted: _state.muted?.asStale()));
      default:
        break;
    }
  }

  // ------------------------------------------------------------ requests

  /// Sends one NRC action and returns the text of its [output] leaf (the
  /// empty string when there is none to read). A 200 to an [effect]
  /// request counts towards what the command delivered once it proves to
  /// be an answer to [action]; one that is not is a protocol error (see
  /// [_plainAnswer] and [_decrypted]).
  ///
  /// On an encrypted TV, a 500 means the TV refused the command without
  /// running it, usually because the session expired: the session is
  /// dropped and, with [retryRefused], reopened and the command sent once
  /// more. Nothing that may have been delivered (a timeout, a lost
  /// connection) is ever sent again.
  Future<String> _nrc(
    String action,
    String args, {
    required bool effect,
    String? output,
    bool retryRefused = true,
  }) async {
    if (!encrypted) {
      final r = await _send(() => _client.soap(VieraService.nrc, action, args));
      if (!r.ok) throw _httpError(r, action, plainNrc: true);
      final value = _plainAnswer(r, action, action, output: output);
      if (effect) _delivered++;
      return value;
    }
    if (_sessionId == null) await _openSession();
    final r = await _sendEncrypted(action, args);
    if (r.ok) return _decrypted(r, action, effect: effect, output: output);
    if (r.status != 500) throw _httpError(r, action);
    _dropSession();
    if (!retryRefused) {
      throw WatchmeError.rejected(
        '$action: the TV refused the encrypted command (HTTP 500), so it '
        'was not run; it is not resent',
        rawDeviceMessage: _rawOf(r),
      );
    }
    await _openSession();
    final again = await _sendEncrypted(action, args);
    if (again.ok) {
      return _decrypted(again, action, effect: effect, output: output);
    }
    if (again.status == 500) _dropSession();
    throw _httpError(again, action);
  }

  Future<HttpResult> _sendEncrypted(String action, String args) {
    final keys = _keys!;
    final sequence = ++_sequence;
    final plaintext = encryptedCommandPlaintext(
      _sessionId!,
      sequence,
      action,
      args,
    );
    return _send(
      () => _client.soap(
        VieraService.nrc,
        'X_EncryptedCommand',
        '<X_ApplicationId>${xmlEscape(_appId!)}</X_ApplicationId>'
            '<X_EncInfo>${vieraSeal(keys, plaintext)}</X_EncInfo>',
      ),
    );
  }

  /// The text of the [output] leaf in the decrypted answer to an encrypted
  /// command the TV accepted, or the empty string for an [effect], whose
  /// answer must acknowledge [action] instead
  /// ([isEncryptedAcknowledgement]). A read needs only its leaf, anywhere
  /// in a well-formed fragment ([encryptedAnswerLeaf]): the brief leaves
  /// the fragment's wrapper unknown.
  ///
  /// An answer that is not well-formed XML, cannot be decrypted, or is no
  /// answer to [action] is a protocol error: the TV may have run the
  /// command. The fragment is what proves the answer; the outer wrapper of
  /// `X_EncResult` is not checked, as the field clients look for
  /// `X_EncResult` alone.
  String _decrypted(
    HttpResult r,
    String action, {
    required bool effect,
    String? output,
  }) {
    final blob = encryptedResult(r.text);
    if (blob == null) {
      throw WatchmeError.protocol(
        '$action: the TV accepted the encrypted command but sent no '
        'encrypted answer',
        rawDeviceMessage: _rawOf(r),
      );
    }
    final VieraPlaintext opened;
    try {
      opened = vieraOpen(_keys!, blob);
    } on FormatException catch (e) {
      throw WatchmeError.protocol(
        '$action: the TV accepted the encrypted command but its answer '
        'could not be decrypted (${e.message})',
        rawDeviceMessage: _rawOf(r),
      );
    }
    if (!opened.macOk) _macFailures++;
    // Never the decrypted text in an error: it holds the session's numbers.
    if (output != null) {
      final value = encryptedAnswerLeaf(opened.text, output);
      if (value == null) {
        throw WatchmeError.protocol(
          '$action: the TV accepted the encrypted command, but its decrypted '
          'answer holds no $output',
          rawDeviceMessage: _rawOf(r),
        );
      }
      if (effect) _delivered++;
      return value;
    }
    if (!isEncryptedAcknowledgement(opened.text, action)) {
      throw WatchmeError.protocol(
        '$action: the TV accepted the encrypted command, but its decrypted '
        'answer is not an answer to it',
        rawDeviceMessage: _rawOf(r),
      );
    }
    if (effect) _delivered++;
    return '';
  }

  /// The text of the [output] leaf of the plain 200 answer [r] to [action]
  /// ([what] names the request), or the empty string without one. Throws
  /// [WatchmeErrorCode.protocol] unless [r] is an answer to [action]
  /// ([soapAnswer]) holding that leaf. Anything else (an HTML page, an
  /// empty or truncated body, another action's answer) says nothing about
  /// what the TV did: it is never taken as success, never retried, and it
  /// stops the command.
  String _plainAnswer(
    HttpResult r,
    String action,
    String what, {
    String? output,
  }) {
    final answer = soapAnswer(r.text, action);
    if (answer == null) {
      throw WatchmeError.protocol(
        '$what: the TV answered HTTP 200, but with something that is not an '
        'answer to $action',
        rawDeviceMessage: _rawOf(r),
      );
    }
    if (output == null) return '';
    final value = soapAnswerLeaf(answer, output);
    if (value == null) {
      throw WatchmeError.protocol(
        '$what: the TV answered $action without $output',
        rawDeviceMessage: _rawOf(r),
      );
    }
    return value;
  }

  /// Opens an encrypted session (`X_GetEncryptSessionId`) and restarts the
  /// sequence numbers. A plaintext request that changes nothing on the TV.
  ///
  /// A 200 without a session that the stored keyword decrypts means the TV
  /// no longer has the pairing: [WatchmeErrorCode.reauthRequired]. A 500
  /// means that too only while the TV is known to be on (its Pro AV
  /// description answers); otherwise it may just be in standby, so it is
  /// [WatchmeErrorCode.rejected].
  Future<void> _openSession({bool inConnect = false}) async {
    final keys = _keys!;
    final r = await _send(
      () => _client.soap(
        VieraService.nrc,
        'X_GetEncryptSessionId',
        vieraSessionRequestArgs(_appId!, keys),
      ),
    );
    if (r.ok) {
      final id = vieraSessionIdFrom(r.text, keys);
      if (id == null) {
        throw _reauth(
          WatchmeError.reauthRequired(
            'The TV no longer accepts the stored pairing key (its session '
            'answer did not decrypt); pair again',
            rawDeviceMessage: _rawOf(r),
          ),
          inConnect: inConnect,
        );
      }
      _sessionId = id;
      _sequence = 1;
      _sessionsOpened++;
      return;
    }
    if (r.status == 500) {
      if (await _pacAnswers()) {
        throw _reauth(
          WatchmeError.reauthRequired(
            'The TV is on but refused to open an encrypted session (HTTP '
            '500): it no longer has its pairing with watchme; pair again',
            rawDeviceMessage: _rawOf(r),
          ),
          inConnect: inConnect,
        );
      }
      throw WatchmeError.rejected(
        'The TV refused to open an encrypted session (HTTP 500). It may be '
        'in standby; if it is on and this persists, it has probably '
        'forgotten its pairing with watchme: pair again',
        rawDeviceMessage: _rawOf(r),
      );
    }
    throw _httpError(r, 'X_GetEncryptSessionId');
  }

  void _dropSession() => _sessionId = null;

  Future<String> _dmr(
    String action,
    String args, {
    required bool effect,
    String? output,
  }) async {
    final r = await _send(() => _client.soap(VieraService.dmr, action, args));
    if (!r.ok) throw _httpError(r, action);
    final value = _plainAnswer(r, action, action, output: output);
    if (effect) _delivered++;
    return value;
  }

  Future<String> _pacCall(
    String action,
    String args, {
    required bool effect,
    String? output,
  }) async {
    final r = await _send(() => _client.soap(VieraService.pac, action, args));
    if (!r.ok) throw _httpError(r, 'PAC $action');
    final value = _plainAnswer(r, action, 'PAC $action', output: output);
    if (effect) _delivered++;
    return value;
  }

  Future<int> _readVolume() async {
    final text = await _dmr(
      'GetVolume',
      _instance,
      effect: false,
      output: 'CurrentVolume',
    );
    final level = int.tryParse(text.trim());
    if (level == null || level < 0 || level > 100) {
      throw WatchmeError.protocol(
        'The TV answered GetVolume without a level',
        rawDeviceMessage: _shown(text),
      );
    }
    _emitState(_state.copyWith(volume: _reported(level)));
    return level;
  }

  Future<bool> _readMute() async {
    final text = await _dmr(
      'GetMute',
      _instance,
      effect: false,
      output: 'CurrentMute',
    );
    final muted = switch (text.trim()) {
      '1' || 'true' => true,
      '0' || 'false' => false,
      _ => null,
    };
    if (muted == null) {
      throw WatchmeError.protocol(
        'The TV answered GetMute without a mute state',
        rawDeviceMessage: _shown(text),
      );
    }
    _emitState(_state.copyWith(muted: _reported(muted)));
    return muted;
  }

  /// [vieraPacAnswers] as a request of this session ([_send]): not sent
  /// once the session is closed, and a session closed while it was out
  /// stops the caller instead of acting on its answer.
  Future<bool> _pacAnswers() async {
    final HttpResult r;
    try {
      r = await _send(() => _client.get(VieraPaths.pacDescription));
    } on WatchmeError {
      if (_closed) throw _closedError;
      return false;
    }
    if (_closed) throw _closedError;
    return _isPacDescription(r);
  }

  /// Sends one request unless the session was closed meanwhile. Every
  /// request goes through here, so a command stops before its next request
  /// once [close] is called, and every answer or transport failure counts
  /// towards the connection state.
  Future<HttpResult> _send(Future<HttpResult> Function() request) async {
    if (_closed) throw _closedError;
    final HttpResult r;
    try {
      r = await request();
    } on WatchmeError catch (e) {
      _noteTransportError(e);
      rethrow;
    }
    _markReachable();
    return r;
  }

  WatchmeError _httpError(HttpResult r, String what, {bool plainNrc = false}) =>
      vieraHttpError(r, what, secrets: _secrets, plainNrc: plainNrc);

  String _rawOf(HttpResult r) =>
      r.body.isEmpty ? 'HTTP ${r.status}' : _shown(r.text);

  String _shown(String text) => redactViera(text, secrets: _secrets);

  WatchmeError _reauth(WatchmeError error, {required bool inConnect}) {
    final e = _redact(error);
    if (!inConnect && !_reauthReported) {
      _reauthReported = true;
      _connection = ConnectionState.failed;
      _emitState(
        _state.copyWith(
          connections: {
            ..._state.connections,
            panasonicDriverId: ConnectionState.failed,
          },
        ),
      );
      _emit(ReauthRequired(e, driverId: panasonicDriverId));
      _emit(
        ConnectionChanged(
          ConnectionState.failed,
          driverId: panasonicDriverId,
          error: e,
        ),
      );
    }
    return e;
  }

  // --------------------------------------------------------------- state

  /// Passive: reads RenderingControl (volume, mute; a 400 there hints at
  /// standby), the Pro AV description and current input on PAC models,
  /// and the foreground app. Never wakes the TV.
  @override
  Future<DeviceState> refresh() => _serial(() async {
    if (_closed) throw _closedError;
    try {
      await _readState(strict: true);
      return _state;
    } on WatchmeError catch (e) {
      throw _redact(e);
    }
  });

  /// Reads what the TV shows without changing anything. With [strict], a
  /// failure of the first read (RenderingControl) is thrown; the other
  /// reads are best effort.
  Future<void> _readState({required bool strict}) async {
    final HttpResult volume;
    try {
      volume = await _send(
        () => _client.soap(VieraService.dmr, 'GetVolume', _instance),
      );
    } on WatchmeError {
      if (strict) rethrow;
      return;
    }
    // A session closed while the read was out uses nothing more.
    if (_closed) throw _closedError;
    var standby = false;
    switch (volume.status) {
      case 200:
        final answer = soapAnswer(volume.text, 'GetVolume');
        final level = int.tryParse(
          (answer == null ? null : soapAnswerLeaf(answer, 'CurrentVolume'))
                  ?.trim() ??
              '',
        );
        if (level != null && level >= 0 && level <= 100) {
          _emitState(_state.copyWith(volume: _reported(level)));
        }
        await _bestEffort(_readMute);
      case 400:
        // RenderingControl refuses requests in standby on many sets (and
        // answers them on others, so a 200 proves nothing). A hint only.
        standby = true;
      case 403 when strict:
        throw _httpError(volume, 'GetVolume');
      default:
        break;
    }
    // A Pro AV description answers only on PAC models, and only while on.
    final on = await _pacAnswers();
    if (on) {
      if (!_pac) _learnPac();
      final result = await _bestEffort(
        () => _pacCall(
          'X_SendInquiryCmd',
          '<X_InquiryCmdType>PAC_QMI</X_InquiryCmdType>',
          effect: false,
          output: 'X_InquiryCmdResult',
        ),
      );
      final current = result == null ? null : _pacValue(result, 'QMI');
      if (current != null && current.isNotEmpty) {
        _emitState(
          _state.copyWith(input: _reported(vieraInputIdForPac(current))),
        );
      }
      _emitState(_state.copyWith(power: _observed(PowerMode.on)));
    } else if (standby) {
      _emitState(_state.copyWith(power: _observed(PowerMode.standby)));
      return;
    } else {
      // Nothing read now says on or standby (an answer from RenderingControl
      // proves nothing), so an earlier inference (a Pro AV description that
      // has stopped answering, an app list) no longer holds: left fresh, it
      // would count as power evidence after the TV was switched off with
      // its own remote.
      _emitState(_state.copyWith(power: _state.power?.asStale()));
    }
    final info = await _bestEffort(
      () => _nrc(
        'X_GetAppInfo',
        '<u:X_InfoType></u:X_InfoType>',
        effect: false,
        output: 'X_AppInfo',
      ),
    );
    final app = info == null ? null : parseVieraAppInfo(info);
    if (app != null) {
      final named = AppInfo(id: app.id, name: _appNames[app.id] ?? app.name);
      _emitState(_state.copyWith(foregroundApp: _reported(named)));
    }
  }

  /// [read]'s value, or `null` when it fails. A transport failure still
  /// counts towards the connection state (see [_send]). A session closed
  /// meanwhile stops the caller instead, whatever the read's outcome.
  Future<T?> _bestEffort<T>(Future<T> Function() read) async {
    final T value;
    try {
      value = await read();
    } on WatchmeError {
      if (_closed) throw _closedError;
      return null;
    }
    if (_closed) throw _closedError;
    return value;
  }

  /// The TV answered its Pro AV description: PAC input codes and the
  /// current input are available from now on, and the capabilities say so.
  void _learnPac() {
    _pac = true;
    _caps = panasonicCapabilities(nrcCapabilities: _nrcCapabilities, pac: true);
    _emit(
      CapabilitiesChanged(
        List.unmodifiable(_caps),
        driverId: panasonicDriverId,
      ),
    );
  }

  /// The value of a PAC inquiry result `QMI:H1` for [command] (`QMI`).
  static String? _pacValue(String result, String command) {
    final text = result.trim();
    if (!text.startsWith('$command:')) return null;
    return text.substring(command.length + 1).trim();
  }

  Observed<PowerMode> _observed(PowerMode mode) =>
      Observed.inferred(mode, panasonicDriverId, _clock.now());

  Observed<T> _inferred<T>(T value) =>
      Observed.inferred(value, panasonicDriverId, _clock.now());

  Observed<T> _reported<T>(T value) =>
      Observed.reported(value, panasonicDriverId, _clock.now());

  /// Adopts [next] (with its fresh observation times) and emits the fields
  /// whose value or confidence changed: a poll re-stamps every observation,
  /// which on its own is not a change.
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
    if (!diff.isEmpty) _emit(StateChanged(diff, driverId: panasonicDriverId));
  }

  /// Takes in a request that failed with [e]. Only a TV that stopped
  /// answering is reported lost: a request that reached nothing, or the
  /// [panasonicTimeoutsBeforeDisconnect]th timeout in a row.
  void _noteTransportError(WatchmeError e) {
    switch (e.code) {
      case WatchmeErrorCode.unreachable:
        _lost(e);
      case WatchmeErrorCode.timeout:
        if (++_timeouts >= panasonicTimeoutsBeforeDisconnect) _lost(e);
      default:
        break;
    }
  }

  /// The TV stopped answering: drops the encrypted session (a TV that went
  /// to standby or rebooted has forgotten it), marks every observation
  /// stale and reports the session disconnected with [e] (once).
  void _lost(WatchmeError e) {
    _dropSession();
    if (_connection != ConnectionState.connected || _closed) return;
    _connection = ConnectionState.disconnected;
    _emitState(
      _state.markStale().copyWith(
        connections: {
          ..._state.connections,
          panasonicDriverId: ConnectionState.disconnected,
        },
      ),
    );
    _emit(
      ConnectionChanged(
        ConnectionState.disconnected,
        driverId: panasonicDriverId,
        error: _redact(e),
      ),
    );
  }

  /// The TV answered a request (whatever its status).
  void _markReachable() {
    _timeouts = 0;
    if (_connection != ConnectionState.disconnected || _closed) return;
    _connection = ConnectionState.connected;
    _emitState(
      _state.copyWith(
        connections: {
          ..._state.connections,
          panasonicDriverId: ConnectionState.connected,
        },
      ),
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.connected,
        driverId: panasonicDriverId,
      ),
    );
  }

  void _emit(DeviceEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<CommandResult> _unsupported(String reason) =>
      Future.value(Unsupported(reason));

  Future<CommandResult> _unsupportedCap(Capability capability) => _unsupported(
    _caps.supportFor(capability).note ?? 'Panasonic VIERA cannot do this',
  );

  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _queue.then((_) => task());
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
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
    _dropSession();
    _connection = ConnectionState.disconnected;
    _state = _state.copyWith(
      connections: {
        ..._state.connections,
        panasonicDriverId: ConnectionState.disconnected,
      },
    );
    _emit(
      const ConnectionChanged(
        ConnectionState.disconnected,
        driverId: panasonicDriverId,
      ),
    );
    await _events.close();
  }

  @override
  String toString() =>
      'PanasonicSession(${_client.endpoint.host}, '
      '${encrypted ? 'encrypted' : 'plain'})';
}

/// Whether the TV's Pro AV description answers 200, which a PAC model
/// does only while it is on. Any failure or other status is `false`: it is
/// also what TVs without PAC answer. Passive.
Future<bool> vieraPacAnswers(VieraClient client, {Duration? timeout}) async {
  try {
    return _isPacDescription(
      await client.get(VieraPaths.pacDescription, timeout: timeout),
    );
  } on WatchmeError {
    return false;
  }
}

/// Whether [r] is a Pro AV description that answered 200.
bool _isPacDescription(HttpResult r) =>
    r.status == 200 && r.text.contains('p00ProAVController');
