import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:math';
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart' show Endpoint;
import 'package:xml/xml.dart';

import 'panasonic_sim_crypto.dart';
import 'panasonic_sim_models.dart';
import 'panasonic_sim_xml.dart';

// A synthetic Panasonic VIERA UPnP server (network remote control,
// RenderingControl, Pro AV control and GENA eventing), written from the
// simulator specification in the watchme research brief (section 11). It is
// NOT a capture of a real TV. Behaviour the brief marks as an assumption is
// marked [A] below and is switchable where a test may need the other
// choice. No code was copied from any client library.

typedef _Reply = ({
  int status,
  String reason,
  List<(String, String)> headers,
  String body,
});

/// A Panasonic VIERA on loopback, for driver, engine and UI tests.
///
/// Serves one HTTP/1.1 port (port name `nrc`, real TVs use 55000) on raw
/// sockets, so that every answer has exactly the TV's header set and the
/// connection closes after it:
///
/// * SOAP 200: `CONTENT-LENGTH`, `Content-Type: text/xml; charset="utf-8"`,
///   `EXT: `, `SERVER`, `CONNECTION: close`, in that order, with the TV's
///   byte layout.
/// * Description GETs: the same without `EXT:`.
/// * 400, 403 and 404: only a status line and `CONNECTION: close`.
/// * 500 faults: the SOAP set [A], optionally with an empty body.
///
/// Plain (pre-2018) and encrypted sets: with [encrypted], NRC actions must
/// be wrapped in `X_EncryptedCommand` after PIN pairing (`X_DisplayPinCode`,
/// `X_RequestAuth`, `X_GetEncryptSessionId`), with strict checks of the
/// client's padding, HMAC and length field, and zero-padded answers that
/// carry a trailing HMAC and a random length field. RenderingControl and
/// PAC are always plain.
///
/// Power follows [PanasonicSimPower]: the NRC power key moves between on
/// and standby (network standby with [poweredOnByApps], otherwise the port
/// closes), switching on takes [bootDelay], Wake-on-LAN is ignored for
/// [wolIgnoredAfterOff] after switching off, and every screen-state change
/// drops the encrypted sessions ([invalidateSessionsOnPowerChange]).
///
/// Peers outside [allowedSubnet] get `403` with an empty body, as clients on
/// another subnet do from a real TV.
///
/// ```dart
/// final sim = PanasonicSimulator(encrypted: true);
/// await sim.start();
/// final ep = sim.endpoint; // Endpoint('127.0.0.1', ports: {'nrc': sim.port})
/// // ... pair (read sim.displayedPin), send keys, read sim.keyLog ...
/// await sim.stop();
/// ```
class PanasonicSimulator {
  /// Creates a simulator (not yet listening; call [start]).
  PanasonicSimulator({
    this.encrypted = false,
    this.pac = false,
    this._power = PanasonicSimPower.on,
    this.poweredOnByApps = true,
    this.wakeOnLan = true,
    this.tvRemote = true,
    this.dmrAnswersInStandby = false,
    String? modelNumber,
    String? friendlyName,
    this.nrcCapabilities = defaultNrcCapabilities,
    this.mac = '80:c7:55:b8:6c:63',
    this.nrcId = '2824FF385E27',
    List<PanasonicSimApp>? apps,
    this.bootDelay = const Duration(seconds: 5),
    this.bootRefusesConnections = false,
    this.nicSleepDelay = Duration.zero,
    this.wolIgnoredAfterOff = const Duration(seconds: 30),
    this.fixedPin,
    this.pinTimeout = const Duration(seconds: 120),
    this.maxWrongPins,
    this.lockoutDuration = const Duration(seconds: 60),
    this.sessionTtl,
    this.seqCheck = PanasonicSimSeqCheck.strict,
    this.invalidateSessionsOnPowerChange = true,
    this.strictClientPadding = true,
    this.wrapEncryptedAnswers = false,
    this.encryptedAnswerMac = true,
    this.sessionErrorReason = 'Internal Server Error',
    this.sessionErrorEmptyBody = false,
    this.allowedSubnet = '127.0.0.0/8',
    this.latency = Duration.zero,
    this.subscribeStatus,
    this.notifyEnabled = true,
    this.notifyAppendsNul = false,
    this.notifyOmitsScreenState = false,
    this.screenStateNone = false,
    this.grantRequestedTimeout = false,
    this.randomSids = false,
    int? seed,
  }) : modelNumber =
           modelNumber ?? (encrypted ? 'TX-55GZ1500' : 'TX-49DX600EA'),
       friendlyName =
           friendlyName ?? (encrypted ? '55GZ1500_Series' : '49DX600_Series'),
       apps = List.of(apps ?? defaultApps),
       _random = seed == null ? Random.secure() : Random(seed) {
    if (fixedPin != null && !RegExp(r'^\d{4}$').hasMatch(fixedPin!)) {
      throw ArgumentError.value(fixedPin, 'fixedPin', 'must be four digits');
    }
  }

  /// `X_NRCCAP` of a 2016 TX-49DX600EA (real description).
  static const String defaultNrcCapabilities =
      'VR_POWER,VR_DMR,VR_DMS,VR_VECTOR,VR_BROWSER,VR_VCTRL,VR_LAUNCH,'
      'VR_RECDMS,VR_TUNERDMS,VR_MEDIADMS,VR_LVDMS,VR_VGADMS,VR_UPDMS,'
      'VR_TUNER1,VR_WOL,VR_OWNPLAY,VR_XRC,VR_MES,VR_UPBROWSER,VR_MC';

  /// `X_NRCCAP` of a 2013 ET60, which cannot be switched on over the
  /// network (no `VR_POWER`, no `VR_WOL`).
  static const String et60NrcCapabilities =
      'VR_DMR,VR_DMS,VR_GPAD,VR_VECTOR,VR_BROWSER,VR_LAUNCH,VR_RECDMS,'
      'VR_TUNERDMS,VR_MEDIADMS,VR_LVDMS,VR_UPDMS,VR_TVMUTE,VR_OWNPLAY,VR_XRC';

  /// Apps listed by default, with product ids the client libraries know.
  static const List<PanasonicSimApp> defaultApps = [
    PanasonicSimApp('0387878700000102', 'Apps Market'),
    PanasonicSimApp('0010000200000001', 'Netflix', state: 'Stop'),
    PanasonicSimApp('0070000200180001', 'YouTube'),
    PanasonicSimApp('0010000100180001', 'Prime Video'),
    PanasonicSimApp('0070002900000002', 'Disney+'),
    PanasonicSimApp('0077777700160002', 'Browser'),
  ];

  /// Inputs listed by Pro AV control (`PAC_QIL`), code and name.
  static const List<(String, String)> pacInputs = [
    ('TV', 'TV'),
    ('H1', 'HDMI1'),
    ('H2', 'HDMI2'),
    ('H3', 'HDMI3'),
    ('H4', 'HDMI4'),
  ];

  // ------------------------------------------------------------- settings

  /// Whether NRC commands must be encrypted (2018 and later sets).
  bool encrypted;

  /// Whether the TV has Pro AV control (`/pac/*`), answered only while on.
  bool pac;

  /// "Powered On by Apps": the network stays up in standby, so the power
  /// key can switch the TV back on.
  bool poweredOnByApps;

  /// Whether Wake-on-LAN switches the TV on.
  bool wakeOnLan;

  /// "TV Remote" in the TV's menu. Off, the NRC control URL answers 403
  /// [A: whether a real TV refuses the connection instead is unknown].
  bool tvRemote;

  /// Whether RenderingControl answers in network standby (some sets do,
  /// most answer 400).
  bool dmrAnswersInStandby;

  /// `modelNumber` in the descriptions.
  String modelNumber;

  /// `friendlyName` in the descriptions.
  String friendlyName;

  /// `X_NRCCAP`; `null` leaves it out.
  String? nrcCapabilities;

  /// The MAC behind the UDNs and the one Wake-on-LAN packets must carry.
  final String mac;

  /// `X_NRC_ID`.
  final String nrcId;

  /// Installed apps. Mutable.
  final List<PanasonicSimApp> apps;

  /// How long switching on takes; meanwhile RenderingControl and PAC answer
  /// 400 (or connections are refused with [bootRefusesConnections]) and
  /// keys are swallowed [A].
  Duration bootDelay;

  /// Whether a booting TV refuses connections instead of answering 400.
  bool bootRefusesConnections;

  /// How long after switching to standby (without network) the port
  /// closes.
  Duration nicSleepDelay;

  /// Wake-on-LAN is ignored for this long after switching off.
  Duration wolIgnoredAfterOff;

  /// The PIN every `X_DisplayPinCode` shows; random when `null`.
  String? fixedPin;

  /// How long a shown PIN stays valid [A: 120 s].
  Duration pinTimeout;

  /// Wrong PINs in a row before `X_DisplayPinCode` is refused for
  /// [lockoutDuration]; `null` (the default) never locks [A].
  int? maxWrongPins;

  /// How long a lockout lasts.
  Duration lockoutDuration;

  /// How long an encrypted session lives; `null` for ever.
  Duration? sessionTtl;

  /// How sequence numbers are checked.
  PanasonicSimSeqCheck seqCheck;

  /// Whether every screen-state change drops the encrypted sessions.
  bool invalidateSessionsOnPowerChange;

  /// Whether a client payload with no pad byte at all is refused (one
  /// field report says the TV refuses it).
  bool strictClientPadding;

  /// Whether encrypted answers wrap the inner answer in `X_OriginalResult`
  /// [A: the real wrapper is unknown].
  bool wrapEncryptedAnswers;

  /// Whether encrypted command answers carry the trailing HMAC.
  bool encryptedAnswerMac;

  /// The reason phrase of a 500 for an unknown or expired session.
  String sessionErrorReason;

  /// Whether that 500 has an empty body.
  bool sessionErrorEmptyBody;

  /// Peers outside this IPv4 CIDR block get 403.
  String allowedSubnet;

  /// Delay before every answer.
  Duration latency;

  /// A status every `SUBSCRIBE` gets instead of a subscription (400 was
  /// seen in the field).
  int? subscribeStatus;

  /// Whether NOTIFYs are sent (off: a firewalled callback).
  bool notifyEnabled;

  /// Whether NOTIFY bodies end with a NUL byte (some clients strip one).
  bool notifyAppendsNul;

  /// Whether NOTIFYs leave out `X_ScreenState`.
  bool notifyOmitsScreenState;

  /// Whether `X_ScreenState` reads `none`.
  bool screenStateNone;

  /// Whether a subscription gets the requested timeout instead of 300 s.
  bool grantRequestedTimeout;

  /// Whether subscription ids are random instead of the NRC UDN.
  bool randomSids;

  // ---------------------------------------------------------------- state

  /// Volume, 0..100.
  int volume = 20;

  /// Mute.
  bool muted = false;

  /// The current input code (`TV`, `H1`..`H4`).
  String input = 'TV';

  /// The product id of the app in front, or `null`.
  String? foregroundAppId;

  /// Whether an on-screen keyboard is open (tests set it).
  bool keyboardOpen = false;

  /// Text typed with `X_SendString` while a keyboard was open.
  String typedText = '';

  /// Digits pressed since the last [clearLog].
  String channelDigits = '';

  /// The key held by `-ON`, until `-OFF`.
  String? heldKey;

  PanasonicSimPower _power;
  bool _booting = false;
  DateTime? _offSince;
  Timer? _bootTimer;
  Timer? _sleepTimer;
  final Random _random;

  ServerSocket? _server;
  final Set<Socket> _sockets = {};
  RawDatagramSocket? _wol;
  String _host = '127.0.0.1';
  int? _port;
  bool _stopped = false;

  final Map<String, String> _pairings = {};
  final Map<String, _SimSession> _sessions = {};
  ({String pin, Uint8List challenge, String name, DateTime shownAt})? _pending;
  int _wrongPins = 0;
  DateTime? _lockedUntil;

  final List<PanasonicSimRequest> _requests = [];
  final List<String> _keyLog = [];
  final List<String> _effects = [];
  final List<String> _pinDeviceNames = [];
  final List<_Override> _overrides = [];
  final Set<PanasonicSimRequest> _dropping = {};
  final List<PanasonicSimGate> _gates = [];
  final Map<String, _Subscription> _subscriptions = {};
  final List<PanasonicSimNotify> _notifies = [];
  final StreamController<PanasonicSimNotify> _notifyEvents =
      StreamController.broadcast(sync: true);
  final StreamController<String> _pinEvents = StreamController.broadcast(
    sync: true,
  );
  int _powerToggles = 0;
  int _sessionsOpened = 0;
  int _wakes = 0;

  // ------------------------------------------------------------ lifecycle

  /// Starts listening on [host] (loopback by default) at [port] (0 picks a
  /// free one; 55000 stands in for a real TV). With [wolPort], magic
  /// packets sent to that UDP port on [host] wake the TV.
  Future<void> start({
    String host = '127.0.0.1',
    int port = 0,
    int? wolPort,
  }) async {
    if (_port != null) throw StateError('Already started');
    _host = host;
    final server = await ServerSocket.bind(host, port);
    _port = server.port;
    if (_listening) {
      _attach(server);
    } else {
      await server.close();
    }
    if (wolPort != null) {
      final wol = await RawDatagramSocket.bind(host, wolPort);
      _wol = wol;
      wol.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = wol.receive();
        if (d != null) receiveMagicPacket(d.data);
      });
    }
  }

  /// Stops everything.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _bootTimer?.cancel();
    _sleepTimer?.cancel();
    for (final gate in _gates) {
      gate.release();
    }
    _wol?.close();
    await _closeServer(dropConnections: true);
    await _notifyEvents.close();
    await _pinEvents.close();
  }

  /// Whether [start] has completed and [stop] has not been called.
  bool get isRunning => _port != null && !_stopped;

  /// The address it listens on.
  String get host => _host;

  /// The port (stable across standby, when the socket closes).
  int get port => _port ?? (throw StateError('Not started'));

  /// The UDP port Wake-on-LAN packets go to, if any.
  int? get wolPort => _wol?.port;

  /// An endpoint for the Panasonic driver: [host] with the `nrc` port.
  Endpoint get endpoint => Endpoint(host, ports: {'nrc': port});

  // ----------------------------------------------------------- inspection

  /// The power state.
  PanasonicSimPower get power => _power;

  /// Whether the TV is switching on.
  bool get booting => _booting;

  /// The value of `X_ScreenState`: `on`, `off`, or `none` with
  /// [screenStateNone].
  String get screenState => screenStateNone
      ? 'none'
      : _power == PanasonicSimPower.on && !_booting
      ? 'on'
      : 'off';

  /// The PIN on screen, or `null`.
  String? get displayedPin => _pending?.pin;

  /// Each PIN as the TV shows it (for a command-line runner to print).
  Stream<String> get onPinDisplayed => _pinEvents.stream;

  /// The `X_DeviceName` of every `X_DisplayPinCode`, in order.
  List<String> get pinDeviceNames => List.unmodifiable(_pinDeviceNames);

  /// Paired clients: application id to keyword (both base64).
  Map<String, String> get pairings => Map.unmodifiable(_pairings);

  /// Open encrypted sessions by id.
  Set<String> get sessionIds => Set.unmodifiable(_sessions.keys);

  /// The last sequence number accepted in session [id].
  int? lastSequence(String id) => _sessions[id]?.lastSeq;

  /// How many encrypted sessions were opened.
  int get sessionsOpened => _sessionsOpened;

  /// How many `NRC_POWER-ONOFF` presses the TV acted on.
  int get powerToggles => _powerToggles;

  /// How many Wake-on-LAN packets switched the TV on.
  int get wakes => _wakes;

  /// Every `X_KeyEvent` answered 200, in order (also those that did
  /// nothing).
  List<String> get keyLog => List.unmodifiable(_keyLog);

  /// What the TV did, e.g. `key:VOLUP`, `launch:0010000200000001`,
  /// `volume:30`, `power:networkStandby`, `text:abc`.
  List<String> get effects => List.unmodifiable(_effects);

  /// Every request received, in order.
  List<PanasonicSimRequest> get requests => List.unmodifiable(_requests);

  /// The SOAP actions received (inner actions for encrypted commands), in
  /// order.
  List<String> get actions => [for (final r in _requests) ?r.effectiveAction];

  /// Every NOTIFY sent.
  List<PanasonicSimNotify> get notifies => List.unmodifiable(_notifies);

  /// Each NOTIFY once its subscriber answered (or could not be reached).
  Stream<PanasonicSimNotify> get onNotify => _notifyEvents.stream;

  /// Active subscription ids.
  Set<String> get subscriptionIds => Set.unmodifiable(_subscriptions.keys);

  /// The NRC UDN, `uuid:4D454931-0200-1090-8001-<MAC>`.
  String get nrcUdn => 'uuid:4D454931-0200-1090-8001-$_macHex';

  String get _dmrUdn => 'uuid:4D454931-0100-1090-8001-$_macHex';
  String get _dmsUdn => 'uuid:4D454931-0000-1090-8001-$_macHex';
  String get _pacUdn => 'uuid:4D454931-0300-1090-8001-$_macHex';
  String get _macHex => mac.replaceAll(RegExp('[:-]'), '').toUpperCase();

  /// Clears the request, key and effect logs (state is kept).
  void clearLog() {
    _requests.clear();
    _keyLog.clear();
    _effects.clear();
    channelDigits = '';
  }

  // ------------------------------------------------------------- controls

  /// Adds a pairing as if a client had paired: [appId] and [keyword] are
  /// base64 (10 and 16 bytes on real TVs).
  void addPairing(String appId, String keyword) => _pairings[appId] = keyword;

  /// Deletes every pairing, as the user can on the TV.
  void forgetPairings() => _pairings.clear();

  /// Drops every encrypted session (they expire at unknown intervals on
  /// real TVs).
  void expireAllSessions() => _sessions.clear();

  /// Answers the next request whose path, SOAP action or (decrypted) inner
  /// action is [target] with [status], [body] and [reason] instead of
  /// handling it. The request has no effect.
  void respondOnce(
    String target, {
    required int status,
    String body = '',
    String? reason,
  }) => _overrides.add(
    _Override(target, status: status, body: body, reason: reason),
  );

  /// Closes the connection of the next request matching [target] without
  /// answering, as a TV that stopped answering mid-request; with
  /// [execute] the request still takes effect first.
  void dropNext(String target, {bool execute = true}) =>
      _overrides.add(_Override(target, drop: true, execute: execute));

  /// Holds the answer to the next request matching [target] (handled at
  /// once, so its effect happens) until [PanasonicSimGate.release].
  PanasonicSimGate holdNext(String target) {
    final gate = PanasonicSimGate(target);
    _gates.add(gate);
    return gate;
  }

  /// Presses the power button of the TV's own remote.
  Future<void> pressPowerButton() async {
    switch (_power) {
      case PanasonicSimPower.on:
        await _switchOff();
      case PanasonicSimPower.networkStandby || PanasonicSimPower.standby:
        await _switchOn();
      case PanasonicSimPower.unplugged:
        break;
    }
  }

  /// Sets the power at once (no boot delay), as a test fixture.
  Future<void> setPower(PanasonicSimPower power) async {
    _bootTimer?.cancel();
    _booting = false;
    await _setPower(power);
  }

  /// Takes a magic packet (6 x `FF` then this TV's MAC 16 times). Returns
  /// whether it switched the TV on.
  bool receiveMagicPacket(List<int> packet) {
    final target = [
      for (var i = 0; i < 12; i += 2)
        int.parse(_macHex.substring(i, i + 2), radix: 16),
    ];
    if (packet.length < 102) return false;
    for (var i = 0; i < 6; i++) {
      if (packet[i] != 0xff) return false;
    }
    for (var r = 0; r < 16; r++) {
      for (var j = 0; j < 6; j++) {
        if (packet[6 + r * 6 + j] != target[j]) return false;
      }
    }
    return receiveWakeOnLan();
  }

  /// Wakes the TV as a valid magic packet would: only with [wakeOnLan],
  /// from standby, and not within [wolIgnoredAfterOff] of switching off.
  bool receiveWakeOnLan() {
    if (!wakeOnLan) return false;
    if (_power != PanasonicSimPower.networkStandby &&
        _power != PanasonicSimPower.standby) {
      return false;
    }
    final off = _offSince;
    if (off != null && DateTime.now().difference(off) < wolIgnoredAfterOff) {
      _effects.add('wol:ignored');
      return false;
    }
    _wakes++;
    _effects.add('wol:wake');
    unawaited(_switchOn());
    return true;
  }

  // ---------------------------------------------------------------- power

  bool get _listening =>
      _power == PanasonicSimPower.on ||
      _power == PanasonicSimPower.networkStandby;

  bool get _screenOn => _power == PanasonicSimPower.on && !_booting;

  Future<void> _switchOff() async {
    await _setPower(
      poweredOnByApps
          ? PanasonicSimPower.networkStandby
          : PanasonicSimPower.standby,
    );
  }

  /// Starts switching on: on, booting for [bootDelay].
  Future<void> _switchOn() async {
    _bootTimer?.cancel();
    if (bootDelay <= Duration.zero) {
      _booting = false;
      await _setPower(PanasonicSimPower.on);
      return;
    }
    _booting = true;
    if (bootRefusesConnections) await _closeServer(dropConnections: false);
    await _setPower(PanasonicSimPower.on);
    _bootTimer = Timer(bootDelay, () {
      if (_stopped) return;
      final before = screenState;
      _booting = false;
      _effects.add('booted');
      unawaited(_ensureListening());
      _screenChanged(before);
    });
  }

  Future<void> _setPower(PanasonicSimPower power) async {
    final before = screenState;
    final was = _power;
    _power = power;
    if (was == PanasonicSimPower.on && power != PanasonicSimPower.on) {
      _offSince = DateTime.now();
    }
    if (power != PanasonicSimPower.on) {
      _pending = null;
      foregroundAppId = null;
      keyboardOpen = false;
    }
    if (was != power) _effects.add('power:${power.name}');
    _screenChanged(before);
    _sleepTimer?.cancel();
    switch (power) {
      case PanasonicSimPower.on || PanasonicSimPower.networkStandby:
        await _ensureListening();
      case PanasonicSimPower.standby:
        if (nicSleepDelay <= Duration.zero) {
          await _closeServer(dropConnections: false);
        } else {
          _sleepTimer = Timer(
            nicSleepDelay,
            () => unawaited(_closeServer(dropConnections: false)),
          );
        }
      case PanasonicSimPower.unplugged:
        await _closeServer(dropConnections: true);
    }
  }

  void _screenChanged(String before) {
    final now = screenState;
    if (now == before) return;
    if (invalidateSessionsOnPowerChange) _sessions.clear();
    _notifyChange([('X_ScreenState', now)]);
  }

  Future<void> _ensureListening() async {
    if (_server != null || _stopped || _port == null) return;
    if (_booting && bootRefusesConnections) return;
    _attach(await ServerSocket.bind(_host, _port!));
  }

  Future<void> _closeServer({required bool dropConnections}) async {
    final server = _server;
    _server = null;
    await server?.close();
    if (dropConnections) {
      for (final s in [..._sockets]) {
        s.destroy();
      }
      _sockets.clear();
    }
  }

  // ------------------------------------------------------------------ HTTP

  void _attach(ServerSocket server) {
    _server = server;
    server.listen(_accept);
  }

  void _accept(Socket socket) {
    _sockets.add(socket);
    final buffer = BytesBuilder(copy: false);
    var taken = false;
    void forget() {
      _sockets.remove(socket);
      socket.destroy();
    }

    socket.listen(
      (chunk) {
        if (taken) return;
        buffer.add(chunk);
        final parsed = _parse(buffer.toBytes());
        if (parsed == null) return;
        taken = true;
        unawaited(
          _serve(socket, parsed).catchError((Object _) {}).whenComplete(forget),
        );
      },
      onError: (Object _) => forget(),
      onDone: () {
        if (!taken) forget();
      },
      cancelOnError: true,
    );
  }

  /// A complete request in [bytes], `null` while incomplete, or a request
  /// with method `!` when it is malformed.
  static _RawRequest? _parse(Uint8List bytes) {
    var end = -1;
    var sep = 0;
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 10 && bytes[i + 1] == 10) {
        end = i;
        sep = 2;
        break;
      }
      if (i + 3 < bytes.length &&
          bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        end = i;
        sep = 4;
        break;
      }
    }
    if (end < 0) return bytes.length > 65536 ? _RawRequest.malformed : null;
    final head = latin1.decode(bytes.sublist(0, end)).split(RegExp(r'\r?\n'));
    final line = head.first.split(' ');
    if (line.length < 3) return _RawRequest.malformed;
    final headers = <(String, String)>[];
    for (final h in head.skip(1)) {
      final colon = h.indexOf(':');
      if (colon <= 0) return _RawRequest.malformed;
      headers.add((
        h.substring(0, colon).trim(),
        h.substring(colon + 1).trim(),
      ));
    }
    String? header(String name) {
      for (final (n, v) in headers) {
        if (n.toLowerCase() == name) return v;
      }
      return null;
    }

    if (header('transfer-encoding') != null) return _RawRequest.malformed;
    final length = int.tryParse(header('content-length') ?? '0') ?? -1;
    if (length < 0) return _RawRequest.malformed;
    final bodyStart = end + sep;
    if (bytes.length < bodyStart + length) return null;
    return _RawRequest(
      line[0].toUpperCase(),
      line[1],
      headers,
      utf8.decode(
        bytes.sublist(bodyStart, bodyStart + length),
        allowMalformed: true,
      ),
    );
  }

  Future<void> _serve(Socket socket, _RawRequest raw) async {
    final after = <void Function()>[];
    final peer = socket.remoteAddress.address;
    final req = PanasonicSimRequest(
      method: raw.method,
      path: raw.path,
      headerLines: raw.headers,
      body: raw.body,
      peer: peer,
      action: raw.method == 'POST' ? _soapAction(raw.body) : null,
    );
    _requests.add(req);
    _Reply reply;
    var drop = false;
    if (raw == _RawRequest.malformed) {
      reply = _bare(400);
    } else if (!_peerAllowed(peer)) {
      reply = _bare(403);
    } else {
      final override = _takeOverride(req);
      if (override == null) {
        reply = _route(req, after);
      } else if (!override.drop) {
        reply = override.reply;
      } else {
        // Dropped: handled first (or not, without execute), never answered.
        reply = override.execute ? _route(req, after) : _bare(500);
        drop = true;
      }
      // An override found inside an encrypted command.
      if (_dropping.remove(req)) drop = true;
    }
    final gate = _gates.where((g) => g.matches(req)).firstOrNull;
    if (gate != null) {
      _gates.remove(gate);
      await gate.hold(req);
    }
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    try {
      if (drop) {
        socket.destroy();
      } else {
        socket.add(_bytes(reply));
        await socket.flush();
        // The TV closes the connection after every answer.
        await socket.close().timeout(const Duration(seconds: 5));
      }
    } on Object {
      // The client went away.
    }
    for (final f in after) {
      f();
    }
  }

  _Override? _takeOverride(PanasonicSimRequest req) {
    final i = _overrides.indexWhere(
      (o) =>
          o.target == req.path ||
          o.target == req.action ||
          (req.innerAction != null && o.target == req.innerAction),
    );
    return i < 0 ? null : _overrides.removeAt(i);
  }

  bool _peerAllowed(String peer) {
    final parts = allowedSubnet.split('/');
    final net = InternetAddress.tryParse(parts.first);
    final bits = parts.length > 1 ? int.tryParse(parts[1]) ?? 32 : 32;
    var address = InternetAddress.tryParse(peer);
    if (address == null || net == null) return false;
    if (address.type == InternetAddressType.IPv6 &&
        address.isLoopback &&
        net.type == InternetAddressType.IPv4) {
      address = InternetAddress.loopbackIPv4;
    }
    if (address.type != net.type) return false;
    final a = address.rawAddress;
    final b = net.rawAddress;
    for (var bit = 0; bit < bits; bit++) {
      final mask = 0x80 >> (bit % 8);
      if ((a[bit ~/ 8] & mask) != (b[bit ~/ 8] & mask)) return false;
    }
    return true;
  }

  static List<int> _bytes(_Reply r) {
    final head = StringBuffer('HTTP/1.1 ${r.status} ${r.reason}\r\n');
    for (final (name, value) in r.headers) {
      head.write('$name: $value\r\n');
    }
    head.write('\r\n');
    return [...utf8.encode(head.toString()), ...utf8.encode(r.body)];
  }

  static const Map<int, String> _reasons = {
    200: 'OK',
    400: 'Bad Request',
    403: 'Forbidden',
    404: 'Not Found',
    412: 'Precondition Failed',
    500: 'Internal Server Error',
  };

  /// A status line and `CONNECTION: close`, nothing else (400, 403, 404).
  static _Reply _bare(int status) => (
    status: status,
    reason: _reasons[status] ?? 'Error',
    headers: const [('CONNECTION', 'close')],
    body: '',
  );

  static _Reply _soapOk(String body) => (
    status: 200,
    reason: 'OK',
    headers: [
      ('CONTENT-LENGTH', '${utf8.encode(body).length}'),
      ('Content-Type', 'text/xml; charset="utf-8"'),
      ('EXT', ''),
      ('SERVER', panasonicSimServer),
      ('CONNECTION', 'close'),
    ],
    body: body,
  );

  static _Reply _document(String body) => (
    status: 200,
    reason: 'OK',
    headers: [
      ('CONTENT-LENGTH', '${utf8.encode(body).length}'),
      ('Content-Type', 'text/xml; charset="utf-8"'),
      ('SERVER', panasonicSimServer),
      ('CONNECTION', 'close'),
    ],
    body: body,
  );

  /// A 500 with a UPnP fault (headers [A]: the SOAP set).
  static _Reply _fault(
    int code,
    String description, {
    String reason = 'Internal Server Error',
    bool emptyBody = false,
  }) {
    final body = emptyBody ? '' : panasonicSimFault(code, description);
    return (
      status: 500,
      reason: reason,
      headers: [
        ('CONTENT-LENGTH', '${utf8.encode(body).length}'),
        ('Content-Type', 'text/xml; charset="utf-8"'),
        ('EXT', ''),
        ('SERVER', panasonicSimServer),
        ('CONNECTION', 'close'),
      ],
      body: body,
    );
  }

  _Reply _route(PanasonicSimRequest req, List<void Function()> after) {
    switch ((req.method, req.path)) {
      case ('GET', '/nrc/ddd.xml'):
        return _document(
          panasonicSimNrcDescription(
            friendlyName: friendlyName,
            modelNumber: modelNumber,
            nrcUdn: nrcUdn,
            dmrUdn: _dmrUdn,
            dmsUdn: _dmsUdn,
            nrcId: nrcId,
            nrcCapabilities: nrcCapabilities,
          ),
        );
      case ('GET', '/nrc/sdd_0.xml'):
        return _document(panasonicSimNrcService(encrypted: encrypted));
      case ('GET', '/dmr/ddd.xml'):
        if (!_dmrAvailable) return _bare(400);
        return _document(
          panasonicSimDmrDescription(
            friendlyName: friendlyName,
            modelNumber: modelNumber,
            dmrUdn: _dmrUdn,
          ),
        );
      case ('GET', '/dmr/sdd_0.xml'):
        if (!_dmrAvailable) return _bare(400);
        return _document(panasonicSimDmrService());
      case ('GET', '/pac/ddd.xml'):
        if (!pac || !_screenOn) return _bare(400);
        return _document(
          panasonicSimPacDescription(
            friendlyName: friendlyName,
            pacUdn: _pacUdn,
          ),
        );
      case ('POST', '/nrc/control_0'):
        return _soap(req, _Service.nrc, after);
      case ('POST', '/dmr/control_0'):
        return _soap(req, _Service.dmr, after);
      case ('POST', '/pac/control_0'):
        return _soap(req, _Service.pac, after);
      case ('SUBSCRIBE', '/nrc/event_0'):
        return _subscribe(req, after);
      case ('UNSUBSCRIBE', '/nrc/event_0'):
        return _unsubscribe(req);
      default:
        return _bare(404);
    }
  }

  bool get _dmrAvailable =>
      _screenOn ||
      (dmrAnswersInStandby && _power == PanasonicSimPower.networkStandby);

  // ------------------------------------------------------------------ SOAP

  /// The local name of the SOAP body's first element, or `null`.
  static String? _soapAction(String body) => _parseSoap(body)?.action;

  static _SoapCall? _parseSoap(String body) {
    try {
      final doc = XmlDocument.parse(body.trim());
      final soapBody = doc.descendantElements
          .where((e) => e.name.local == 'Body')
          .firstOrNull;
      final action = soapBody?.childElements.firstOrNull;
      if (action == null) return null;
      return _SoapCall.of(action);
    } on XmlException {
      return null;
    }
  }

  _Reply _soap(
    PanasonicSimRequest req,
    _Service service,
    List<void Function()> after,
  ) {
    final call = _parseSoap(req.body);
    if (call == null) return _bare(400);
    // Header name in any case; the value quoted (every client quotes it)
    // or not. It must name the same action as the body.
    final header = req.header('soapaction');
    if (header != null) {
      final value = header.replaceAll('"', '').trim();
      final hash = value.lastIndexOf('#');
      if (hash < 0 || value.substring(hash + 1) != call.action) {
        return _bare(400);
      }
    }
    return switch (service) {
      _Service.nrc => _nrcControl(req, call, after),
      _Service.dmr => _dmr(call),
      _Service.pac => _pacControl(call),
    };
  }

  static const Set<String> _pairingActions = {
    'X_DisplayPinCode',
    'X_RequestAuth',
    'X_GetEncryptSessionId',
    'X_EncryptedCommand',
  };

  _Reply _nrcControl(
    PanasonicSimRequest req,
    _SoapCall call,
    List<void Function()> after,
  ) {
    if (!tvRemote) return _bare(403);
    if (_pairingActions.contains(call.action)) {
      if (!encrypted) return _fault(401, 'Invalid Action');
      return switch (call.action) {
        'X_DisplayPinCode' => _displayPin(call),
        'X_RequestAuth' => _requestAuth(call),
        'X_GetEncryptSessionId' => _openSession(call),
        _ => _encryptedCommand(req, call, after),
      };
    }
    // A plain NRC action on an encrypted TV: the literal
    // `<errorCode>401</errorCode>` FHEM's encryption check looks for.
    if (encrypted) return _fault(401, 'Invalid Action');
    final result = _nrcAction(call, after);
    return switch (result) {
      _Out(:final args) => _soapOk(
        panasonicSimSoapAnswer(call.action, panasonicSimNrcUrn, args),
      ),
      _Fault(:final code, :final description) => _fault(code, description),
    };
  }

  /// Runs one NRC action (plain, or the inside of an encrypted command).
  _Result _nrcAction(_SoapCall call, List<void Function()> after) {
    switch (call.action) {
      case 'X_SendKey':
        _sendKey(call.args['X_KeyEvent']?.trim() ?? '', after);
        return const _Out([]);
      case 'X_SendString':
        final text = call.args['X_String'] ?? '';
        if (_screenOn && keyboardOpen) {
          typedText += text;
          _effects.add('text:$text');
        }
        return const _Out([]);
      case 'X_GetAppList':
        // `None`, empty or whitespace content are all accepted.
        if (!_screenOn) return const _Out([('X_AppList', '')]);
        return _Out([('X_AppList', _appList())]);
      case 'X_LaunchApp':
        return _launch(call);
      case 'X_GetAppInfo':
        return _Out([('X_AppInfo', panasonicSimEscape(_appInfo()))]);
      case 'X_GetVectorInfo':
        return const _Out([('X_PortNumber', '55000')]);
      case 'X_GetInputMode':
        return const _Out([('X_InputMode', 'rc-mode')]);
      case 'X_GetKeyboardType':
        return const _Out([('X_KeyboardType', 'default')]);
      default:
        return const _Fault(401, 'Invalid Action');
    }
  }

  static final RegExp _keyEvent = RegExp(r'^NRC_([A-Z0-9_]+)-(ONOFF|ON|OFF)$');

  /// Unknown key names are answered 200 and do nothing, as on some real
  /// sets [I].
  void _sendKey(String event, List<void Function()> after) {
    _keyLog.add(event);
    final m = _keyEvent.firstMatch(event);
    if (m == null) return;
    final name = m.group(1)!;
    final edge = m.group(2)!;
    if (edge != 'ONOFF') {
      if (_screenOn) {
        heldKey = edge == 'ON' ? name : (heldKey == name ? null : heldKey);
        _effects.add('hold:$name-$edge');
      }
      return;
    }
    if (_booting) {
      // A key sent while the TV boots is swallowed [A].
      _effects.add('swallowed:$name');
      return;
    }
    if (_power == PanasonicSimPower.networkStandby) {
      // Only the power key does anything in network standby [A].
      if (name == 'POWER') {
        _powerToggles++;
        _effects.add('key:POWER');
        after.add(() => unawaited(_switchOn()));
      }
      return;
    }
    _effects.add('key:$name');
    switch (name) {
      case 'POWER':
        _powerToggles++;
        after.add(() => unawaited(_switchOff()));
      case 'VOLUP':
        volume = min(100, volume + 1);
      case 'VOLDOWN':
        volume = max(0, volume - 1);
      case 'MUTE':
        muted = !muted;
      case 'HDMI1' || 'HDMI2' || 'HDMI3' || 'HDMI4':
        input = 'H${name.substring(4)}';
      case 'TV':
        input = 'TV';
      case 'CHG_INPUT':
        final codes = [for (final i in pacInputs) i.$1];
        input = codes[(codes.indexOf(input) + 1) % codes.length];
      case 'HOME':
        _setForeground(null);
        keyboardOpen = false;
      default:
        if (RegExp(r'^D[0-9]$').hasMatch(name)) channelDigits += name[1];
    }
  }

  String _appList() => [
    for (final a in apps)
      panasonicSimEscape(
        "vc_app'${a.state}'product_id=${a.productId}'${a.name}'"
        "http://$_host:$port/nrc/app_icon/${a.productId}'Unknown>",
      ),
  ].join();

  String _appInfo() {
    final id = foregroundAppId;
    if (id == null) return '';
    final app = apps.where((a) => a.productId == id).firstOrNull;
    return 'vc_app:1:product_id=$id:${app?.name ?? id}';
  }

  _Result _launch(_SoapCall call) {
    final keyword = call.args['X_LaunchKeyword']?.trim() ?? '';
    if (call.args['X_AppType']?.trim() != 'vc_app') {
      return const _Fault(402, 'Invalid Args');
    }
    final String id;
    if (keyword.startsWith('product_id=')) {
      id = keyword.substring('product_id='.length);
      if (!apps.any((a) => a.productId == id)) {
        // Unknown product: the real answer is unknown [A].
        return const _Fault(501, 'Action Failed');
      }
    } else if (keyword == 'resource_id=1063') {
      id = 'resource_id=1063';
    } else {
      return const _Fault(501, 'Action Failed');
    }
    if (_screenOn) {
      _setForeground(id);
      keyboardOpen = false;
      _effects.add('launch:$id');
    }
    return const _Out([('X_SessionId', '1')]);
  }

  void _setForeground(String? id) {
    if (foregroundAppId == id) return;
    foregroundAppId = id;
    _notifyChange([('X_AppInfo', _appInfo())]);
  }

  _Reply _dmr(_SoapCall call) {
    if (!_dmrAvailable) return _bare(400);
    final result = switch (call.action) {
      'GetVolume' => _Out([('CurrentVolume', '$volume')]),
      'SetVolume' => switch (int.tryParse(
        call.args['DesiredVolume']?.trim() ?? '',
      )) {
        null => const _Fault(402, 'Invalid Args'),
        final v when v < 0 || v > 100 => const _Fault(
          601,
          'Argument Value Out of Range',
        ),
        final v => _setVolume(v),
      },
      'GetMute' => _Out([('CurrentMute', muted ? '1' : '0')]),
      'SetMute' => switch (call.args['DesiredMute']?.trim()) {
        '1' || 'true' => _setMute(true),
        '0' || 'false' => _setMute(false),
        _ => const _Fault(402, 'Invalid Args'),
      },
      _ => const _Fault(401, 'Invalid Action'),
    };
    return switch (result) {
      _Out(:final args) => _soapOk(
        panasonicSimSoapAnswer(
          call.action,
          panasonicSimRenderingControlUrn,
          args,
        ),
      ),
      _Fault(:final code, :final description) => _fault(code, description),
    };
  }

  _Result _setVolume(int v) {
    volume = v;
    _effects.add('volume:$v');
    return const _Out([]);
  }

  _Result _setMute(bool m) {
    muted = m;
    _effects.add('mute:$m');
    return const _Out([]);
  }

  _Reply _pacControl(_SoapCall call) {
    if (!pac || !_screenOn) return _bare(400);
    final _Result result;
    switch (call.action) {
      case 'X_SendInquiryCmd':
        result = switch (call.args['X_InquiryCmdType']?.trim()) {
          'PAC_QIL' => _Out([
            (
              'X_InquiryCmdResult',
              'QIL:${pacInputs.map((i) => '${i.$1}[${i.$2}]').join(',')}',
            ),
          ]),
          'PAC_QMI' => _Out([('X_InquiryCmdResult', 'QMI:$input')]),
          _ => const _Fault(600, 'Argument Value Invalid'),
        };
      case 'X_SendCtrlCmd':
        final cmd = call.args['X_CtrlCmd']?.trim() ?? '';
        final code = cmd.startsWith('PAC_IMS:') ? cmd.substring(8) : null;
        if (code != null && pacInputs.any((i) => i.$1 == code)) {
          input = code;
          _effects.add('pac:input:$code');
          result = const _Out([]);
        } else {
          result = const _Fault(600, 'Argument Value Invalid');
        }
      default:
        result = const _Fault(401, 'Invalid Action');
    }
    return switch (result) {
      _Out(:final args) => _soapOk(
        panasonicSimSoapAnswer(call.action, panasonicSimPacUrn, args),
      ),
      _Fault(:final code, :final description) => _fault(code, description),
    };
  }

  // -------------------------------------------------------------- pairing

  _Reply _displayPin(_SoapCall call) {
    final now = DateTime.now();
    final locked = _lockedUntil;
    if (locked != null && now.isBefore(locked)) {
      // [A]: the real lockout, if any, is unknown.
      return _fault(501, 'Too many wrong PIN codes; try again later');
    }
    // The TV shows a PIN only while on [A: the real fault is unknown].
    if (!_screenOn) return _fault(501, 'The TV is not on');
    final pin = fixedPin ?? _random.nextInt(10000).toString().padLeft(4, '0');
    final challenge = Uint8List.fromList([
      for (var i = 0; i < 16; i++) _random.nextInt(256),
    ]);
    final name = call.args['X_DeviceName'] ?? '';
    _pending = (pin: pin, challenge: challenge, name: name, shownAt: now);
    _pinDeviceNames.add(name);
    _effects.add('pin:display');
    if (!_pinEvents.isClosed) _pinEvents.add(pin);
    return _soapOk(
      panasonicSimSoapAnswer('X_DisplayPinCode', panasonicSimNrcUrn, [
        ('X_ChallengeKey', base64.encode(challenge)),
      ]),
    );
  }

  _Reply _requestAuth(_SoapCall call) {
    final pending = _pending;
    if (pending == null) return _fault(600, 'No PIN code is shown');
    final keys = PanasonicSimKeys.pairing(pending.challenge);
    final opened = panasonicSimOpen(
      keys,
      call.args['X_AuthInfo'] ?? '',
      strictPadding: strictClientPadding,
    );
    final payload = opened.payload;
    if (payload == null) {
      _effects.add('auth:${opened.failure!.name}');
      return _fault(402, 'Invalid Args');
    }
    final m = RegExp(r'^\s*<X_PinCode>(\d{4})</X_PinCode>\s*$')
        .firstMatch(payload);
    if (m == null) return _fault(402, 'Invalid Args');
    final now = DateTime.now();
    if (now.difference(pending.shownAt) > pinTimeout) {
      _pending = null;
      _effects.add('pin:expired');
      return _fault(600, 'Invalid PIN Code');
    }
    if (m.group(1) != pending.pin) {
      _pending = null;
      _effects.add('pin:wrong');
      final limit = maxWrongPins;
      if (limit != null && ++_wrongPins >= limit) {
        _wrongPins = 0;
        _lockedUntil = now.add(lockoutDuration);
        _effects.add('pin:locked');
      }
      return _fault(600, 'Invalid PIN Code');
    }
    _pending = null;
    _wrongPins = 0;
    final appId = base64.encode([
      for (var i = 0; i < 10; i++) _random.nextInt(256),
    ]);
    final keyword = base64.encode([
      for (var i = 0; i < 16; i++) _random.nextInt(256),
    ]);
    _pairings[appId] = keyword;
    _effects.add('pin:paired');
    final sealed = panasonicSimSeal(
      keys,
      '<X_ApplicationId>$appId</X_ApplicationId>\n'
      '<X_Keyword>$keyword</X_Keyword>',
      _random,
    );
    return _soapOk(
      panasonicSimSoapAnswer('X_RequestAuth', panasonicSimNrcUrn, [
        ('X_AuthResult', sealed),
      ]),
    );
  }

  PanasonicSimKeys? _sessionKeys(String? appId) {
    final keyword = appId == null ? null : _pairings[appId];
    return keyword == null
        ? null
        : PanasonicSimKeys.session(base64.decode(keyword));
  }

  _Reply _openSession(_SoapCall call) {
    final appId = call.args['X_ApplicationId']?.trim();
    final keys = _sessionKeys(appId);
    // A deleted pairing [A: the real code is unknown].
    if (keys == null) return _fault(401, 'No such application');
    final opened = panasonicSimOpen(
      keys,
      call.args['X_EncInfo'] ?? '',
      strictPadding: strictClientPadding,
    );
    final payload = opened.payload;
    final claimed = payload == null
        ? null
        : RegExp(r'<X_ApplicationId>\s*([^<]*?)\s*</X_ApplicationId>')
              .firstMatch(payload)
              ?.group(1);
    if (claimed != appId) return _fault(402, 'Invalid Args');
    String id;
    do {
      id = '${10000 + _random.nextInt(90000)}';
    } while (_sessions.containsKey(id));
    _sessions[id] = _SimSession(appId!, DateTime.now());
    _sessionsOpened++;
    return _soapOk(
      panasonicSimSoapAnswer('X_GetEncryptSessionId', panasonicSimNrcUrn, [
        (
          'X_EncResult',
          panasonicSimSeal(keys, '<X_SessionId>$id</X_SessionId>', _random),
        ),
      ]),
    );
  }

  _Reply _encryptedCommand(
    PanasonicSimRequest req,
    _SoapCall call,
    List<void Function()> after,
  ) {
    final appId = call.args['X_ApplicationId']?.trim();
    final keys = _sessionKeys(appId);
    if (keys == null) return _fault(401, 'No such application');
    final opened = panasonicSimOpen(
      keys,
      call.args['X_EncInfo'] ?? '',
      strictPadding: strictClientPadding,
    );
    final payload = opened.payload;
    if (payload == null) return _fault(402, 'Invalid Args');
    // The three inner elements in any order, with any whitespace (FHEM
    // puts CRLF around them).
    final XmlElement root;
    try {
      root = XmlDocument.parse('<X_Data>$payload</X_Data>').rootElement;
    } on XmlException {
      return _fault(402, 'Invalid Args');
    }
    String? leaf(String name) => root.childElements
        .where((e) => e.name.local == name)
        .firstOrNull
        ?.innerText
        .trim();
    final original = root.childElements
        .where((e) => e.name.local == 'X_OriginalCommand')
        .firstOrNull
        ?.childElements
        .firstOrNull;
    final sid = leaf('X_SessionId');
    final seq = int.tryParse(leaf('X_SequenceNumber') ?? '');
    if (original == null || sid == null || seq == null) {
      return _fault(402, 'Invalid Args');
    }
    final inner = _SoapCall.of(original);
    req.innerAction = inner.action;
    final override = _takeOverride(req);
    if (override != null) {
      if (!override.drop) return override.reply;
      _dropping.add(req);
      if (!override.execute) return _bare(500);
    }
    final session = _sessions[sid];
    final ttl = sessionTtl;
    if (session == null ||
        session.appId != appId ||
        (ttl != null && DateTime.now().difference(session.createdAt) > ttl)) {
      _sessions.remove(sid);
      // A stale session [A: some clients expect "No such session" in the
      // reason phrase; others drop the session on any 500].
      return _fault(
        501,
        'No such session',
        reason: sessionErrorReason,
        emptyBody: sessionErrorEmptyBody,
      );
    }
    if (seqCheck == PanasonicSimSeqCheck.strict && seq <= session.lastSeq) {
      return _fault(501, 'Invalid sequence number'); // [A]
    }
    session.lastSeq = seq;
    if (_pairingActions.contains(inner.action)) {
      return _fault(401, 'Invalid Action');
    }
    final result = _nrcAction(inner, after);
    return switch (result) {
      _Out(:final args) => _soapOk(
        panasonicSimSoapAnswer('X_EncryptedCommand', panasonicSimNrcUrn, [
          (
            'X_EncResult',
            panasonicSimSeal(
              keys,
              panasonicSimEncryptedAnswer(
                inner.action,
                args,
                wrapped: wrapEncryptedAnswers,
              ),
              _random,
              withMac: encryptedAnswerMac,
            ),
          ),
        ]),
      ),
      _Fault(:final code, :final description) => _fault(code, description),
    };
  }

  // ------------------------------------------------------------------ GENA

  _Reply _subscribe(PanasonicSimRequest req, List<void Function()> after) {
    final forced = subscribeStatus;
    if (forced != null) return _bare(forced);
    final requested = RegExp(r'Second-(\d+)')
        .firstMatch(req.header('timeout') ?? '')
        ?.group(1);
    final timeout = grantRequestedTimeout && requested != null
        ? requested
        : '300';
    final renewal = req.header('sid');
    if (renewal != null) {
      if (req.header('callback') != null || req.header('nt') != null) {
        return _bare(400);
      }
      if (!_subscriptions.containsKey(renewal)) return _bare(412);
      return _subscribed(renewal, timeout);
    }
    final callback = Uri.tryParse(
      RegExp(r'<([^>]+)>').firstMatch(req.header('callback') ?? '')?.group(1) ??
          '',
    );
    if (callback == null ||
        callback.scheme != 'http' ||
        req.header('nt') != 'upnp:event') {
      return _bare(412);
    }
    final sid = randomSids ? 'uuid:${_randomUuid()}' : nrcUdn;
    final subscription = _Subscription(sid, callback);
    _subscriptions[sid] = subscription;
    after.add(
      () => unawaited(
        _notify(subscription, [
          ('X_InputMode', 'rc-mode'),
          ('X_KeyboardType', 'default'),
          ('X_ScreenState', screenState),
          ('X_AppInfo', _appInfo()),
        ]),
      ),
    );
    return _subscribed(sid, timeout);
  }

  static _Reply _subscribed(String sid, String timeout) => (
    status: 200,
    reason: 'OK',
    headers: [
      ('SERVER', panasonicSimServer),
      ('SID', sid),
      ('TIMEOUT', 'Second-$timeout'),
      ('CONTENT-LENGTH', '0'),
      ('CONNECTION', 'close'),
    ],
    body: '',
  );

  _Reply _unsubscribe(PanasonicSimRequest req) {
    final sid = req.header('sid');
    if (sid == null || _subscriptions.remove(sid) == null) return _bare(412);
    return (
      status: 200,
      reason: 'OK',
      headers: const [
        ('SERVER', panasonicSimServer),
        ('CONTENT-LENGTH', '0'),
        ('CONNECTION', 'close'),
      ],
      body: '',
    );
  }

  /// A change NOTIFY carries only the changed variables.
  void _notifyChange(List<(String, String)> variables) {
    for (final s in [..._subscriptions.values]) {
      unawaited(_notify(s, variables));
    }
  }

  Future<void> _notify(
    _Subscription subscription,
    List<(String, String)> variables,
  ) async {
    if (!notifyEnabled || _stopped) return;
    final vars = [
      for (final v in variables)
        if (!(notifyOmitsScreenState && v.$1 == 'X_ScreenState')) v,
    ];
    if (vars.isEmpty) return;
    final body =
        panasonicSimPropertySet(vars) + (notifyAppendsNul ? '\u0000' : '');
    final record = PanasonicSimNotify(
      subscription.callback,
      subscription.sid,
      subscription.seq++,
      body,
    );
    _notifies.add(record);
    // Never contact anything but loopback.
    final address = InternetAddress.tryParse(subscription.callback.host);
    if (address != null && address.isLoopback) {
      final client = HttpClient();
      try {
        final request = await client
            .openUrl('NOTIFY', subscription.callback)
            .timeout(const Duration(seconds: 3));
        final bytes = utf8.encode(body);
        request.headers
          ..set(
            'HOST',
            '${subscription.callback.host}:'
                '${subscription.callback.port}',
            preserveHeaderCase: true,
          )
          ..set(
            'CONTENT-TYPE',
            'text/xml; charset="utf-8"',
            preserveHeaderCase: true,
          )
          ..set('NT', 'upnp:event', preserveHeaderCase: true)
          ..set('NTS', 'upnp:propchange', preserveHeaderCase: true)
          ..set('SID', subscription.sid, preserveHeaderCase: true)
          ..set('SEQ', '${record.seq}', preserveHeaderCase: true);
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        await response.drain<void>();
        record.status = response.statusCode;
      } on Object {
        record.status = null;
      } finally {
        client.close(force: true);
      }
    }
    if (!_notifyEvents.isClosed) _notifyEvents.add(record);
  }

  String _randomUuid() {
    final b = [for (var i = 0; i < 16; i++) _random.nextInt(256)];
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

enum _Service { nrc, dmr, pac }

final class _RawRequest {
  _RawRequest(this.method, this.path, this.headers, this.body);

  static final _RawRequest malformed = _RawRequest('!', '', const [], '');

  final String method;
  final String path;
  final List<(String, String)> headers;
  final String body;
}

final class _SoapCall {
  _SoapCall(this.action, this.args);

  factory _SoapCall.of(XmlElement element) => _SoapCall(element.name.local, {
    for (final child in element.childElements)
      child.name.local: child.innerText,
  });

  final String action;
  final Map<String, String> args;
}

sealed class _Result {
  const _Result();
}

final class _Out extends _Result {
  const _Out(this.args);

  /// Out-arguments, values already escaped.
  final List<(String, String)> args;
}

final class _Fault extends _Result {
  const _Fault(this.code, this.description);

  final int code;
  final String description;
}

final class _SimSession {
  _SimSession(this.appId, this.createdAt);

  final String appId;
  final DateTime createdAt;

  /// Starts at 0, so a first command numbered 1 is accepted (FHEM's).
  int lastSeq = 0;
}

final class _Override {
  _Override(
    this.target, {
    this.status = 500,
    this.body = '',
    this.reason,
    this.drop = false,
    this.execute = true,
  });

  final String target;
  final int status;
  final String body;
  final String? reason;
  final bool drop;
  final bool execute;

  _Reply get reply => (
    status: status,
    reason: reason ?? PanasonicSimulator._reasons[status] ?? 'Error',
    headers: [
      if (body.isNotEmpty) ...[
        ('CONTENT-LENGTH', '${utf8.encode(body).length}'),
        ('Content-Type', 'text/xml; charset="utf-8"'),
      ],
      ('CONNECTION', 'close'),
    ],
    body: body,
  );
}

final class _Subscription {
  _Subscription(this.sid, this.callback);

  final String sid;
  final Uri callback;
  int seq = 0;
}
