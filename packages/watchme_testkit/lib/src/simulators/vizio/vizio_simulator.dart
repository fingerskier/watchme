import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:watchme_core/watchme_core.dart'
    show DiscoveryAttr, DiscoveryHit, DiscoveryProviderId, Endpoint;

import 'vizio_sim_models.dart';

// A synthetic VIZIO SmartCast TV. It is written from the watchme VIZIO
// protocol brief, whose facts were checked against vizaio (MIT), pyvizio
// (MIT), heathbar/vizio-smart-cast (MIT), the Home Assistant vizio
// integration (Apache-2.0) and exiva/Vizio_SmartCast_API (no licence:
// facts only). No code was copied. It is NOT a capture of real device
// traffic: behaviour the references do not pin down is marked "synthetic"
// below.
//
// Out of scope on purpose (security research shows they are abuse
// surfaces, not remote-control features): the internal loopback twin on
// port 7346, the SCPL WebSocket bus, and the NAME_SPACE 4 / APP_ID "3001"
// raw-URL launcher. The simulator implements none of them.

/// The `Endpoint` port name of the SmartCast API (default 7345), the
/// driver's `VizioPorts.smartcast`.
const String vizioSimApiPortName = 'smartcast';

/// The `Endpoint` port name of the pre-4.0 firmware API port (default 9000),
/// the driver's `VizioPorts.smartcastLegacy`.
const String vizioSimLegacyPortName = 'smartcastLegacy';

/// A VIZIO SmartCast TV simulator on loopback: the HTTPS REST API on a
/// random port, with a second reserved port that stands in for 9000.
///
/// ```dart
/// final sim = await VizioSimulator.start(pin: '1234');
/// final endpoint = sim.endpoint; // ports 'smartcast', 'smartcastLegacy'
/// // ... PUT /pairing/start, read sim.displayedPin, PUT /pairing/pair ...
/// await sim.close();
/// ```
///
/// Behaviour (all answers are JSON envelopes `{"ITEMS"|"ITEM", "STATUS":
/// {"RESULT","DETAIL"}, "URI"}`, keys spelt as [keyCase] says):
/// * Only `GET /state/device/deviceinfo` and `PUT /pairing/*` work without
///   the `AUTH` header. Everything else, `GET /state/device/power_mode`
///   included, answers a raw HTTP 403 with an empty body (no envelope)
///   without a valid token.
/// * Pairing: `/pairing/start` shows a 4-digit PIN ([displayedPin]) and
///   answers `CHALLENGE_TYPE 1` and a `PAIRING_REQ_TOKEN`; a second start
///   while one is open is `BLOCKED`. `/pairing/pair` answers the token for
///   the right PIN, `PAIRING_DENIED` for a wrong one,
///   `MAX_CHALLENGES_EXCEEDED` at the [maxPinAttempts]th wrong one (and
///   until `/pairing/cancel`), `VALUE_OUT_OF_RANGE` for a PIN that is not 4
///   digits and `CHALLENGE_INCORRECT` for a wrong or expired challenge.
///   Pairing again with the same `DEVICE_ID` revokes that id's old token.
/// * Settings leaves carry a `HASHVAL` that changes with the value; a
///   `MODIFY` with a stale one is `HASHVAL_ERROR`, without one
///   `INVALID_PARAMETER`. `blank_screen` is a `T_ACTION_V1` item: it takes
///   `REQUEST: ACTION` and answers `PROXY_ERROR` to `MODIFY`.
///   `system_information` leaves are read-only (`READ_ONLY_ERROR`).
/// * `current_input` accepts only the lowercase cname on modern firmware:
///   the display name is `FAILURE`, the meta name `HASHVAL_ERROR`, and the
///   input already current `FAILURE`. With [legacyFirmware] the display
///   name is accepted too.
/// * Volume answers in standby; mute is inert there (`SUCCESS`, no
///   change). With [ecoMode] the power-off key closes the port.
/// * A path outside `/menu_native/` that the TV does not know answers HTTP
///   500 `Unhandled Exception`; an unknown `/menu_native/` leaf answers
///   `URI_NOT_FOUND` (HTTP 200).
///
/// Test controls: [respondOnce] replaces one answer, [holdNext] holds one
/// answer back until released, [vanish] / [reappear] take the TV off the
/// network and back, [pressPowerOnRemote] / [wake] change its power as
/// the physical remote or Wake-on-LAN would, [expirePin] withdraws the PIN
/// on screen, and [revokeTokens] forgets every pairing.
class VizioSimulator {
  VizioSimulator._(
    this.host,
    this.apiPort,
    this.legacyPort,
    this._certificate,
    this._random, {
    required this.servesLegacyPort,
    required this.fixedPin,
    required this.maxPinAttempts,
    required this.maxPairedDevices,
    required this.ecoMode,
    required this.legacyFirmware,
    required this.v2Volume,
    required this.stateExtended,
    required this.hasTuner,
    required this.keyCase,
    required this.settingsRoot,
    required this.modelName,
    required this.serialNumber,
    required this.firmwareVersion,
    required this.apiVersion,
    required this.castName,
    required this.roomName,
    required this.mac,
    required this.maxVolume,
    required List<VizioSimInput> inputs,
    required List<VizioSimApp> apps,
  }) : inputs = List.of(inputs),
       apps = List.of(apps),
       _currentInput = inputs.first.cname {
    _volumeHash = _newHash();
    _muteHash = _newHash();
    _inputHash = _newHash();
    _blankHash = _newHash();
  }

  /// Starts a simulator on [host] (loopback by default).
  ///
  /// [apiPort] and [legacyPort] default to 0 (free ports); the simulator
  /// reserves both and listens on [apiPort], or on [legacyPort] with
  /// [servesLegacyPort] (firmware older than 4.0, which answers on 9000).
  /// [power] is the starting power. [pin] fixes the PIN every
  /// `/pairing/start` shows (default: random per start); [seed] makes PINs,
  /// tokens and HASHVALs reproducible.
  static Future<VizioSimulator> start({
    String host = '127.0.0.1',
    int apiPort = 0,
    int legacyPort = 0,
    bool servesLegacyPort = false,
    VizioSimPower power = VizioSimPower.on,
    String? pin,
    int maxPinAttempts = 3,
    int maxPairedDevices = 16,
    bool ecoMode = false,
    bool legacyFirmware = false,
    bool v2Volume = false,
    bool stateExtended = false,
    bool hasTuner = true,
    VizioSimKeyCase keyCase = VizioSimKeyCase.alternate,
    String settingsRoot = 'tv_settings',
    String modelName = 'V505-J09',
    String serialNumber = 'LWZSIM0000001',
    String firmwareVersion = '3.720.9.1-1',
    String apiVersion = '1.0.0',
    String castName = 'Living Room TV',
    String roomName = 'Living Room',
    String mac = 'f0:4f:e0:2d:6e:20',
    int maxVolume = 100,
    List<VizioSimInput> inputs = defaultInputs,
    List<VizioSimApp> apps = defaultApps,
    VizioSimulatorCertificate certificate = VizioSimulatorCertificate.primary,
    int? seed,
  }) async {
    if (pin != null && !RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be four digits');
    }
    if (inputs.isEmpty) throw ArgumentError.value(inputs, 'inputs', 'empty');
    // Reserve both ports by binding them once; the one not served is closed
    // again, so connections to it are refused (a TV listens on 7345 or on
    // 9000, never both).
    final primary = await HttpServer.bindSecure(
      host,
      apiPort,
      certificate.context(),
    );
    final HttpServer legacy;
    try {
      legacy = await HttpServer.bindSecure(
        host,
        legacyPort,
        certificate.context(),
      );
    } on Object {
      await primary.close(force: true);
      rethrow;
    }
    final sim = VizioSimulator._(
      host,
      primary.port,
      legacy.port,
      certificate,
      seed == null ? Random.secure() : Random(seed),
      servesLegacyPort: servesLegacyPort,
      fixedPin: pin,
      maxPinAttempts: maxPinAttempts,
      maxPairedDevices: maxPairedDevices,
      ecoMode: ecoMode,
      legacyFirmware: legacyFirmware,
      v2Volume: v2Volume,
      stateExtended: stateExtended,
      hasTuner: hasTuner,
      keyCase: keyCase,
      settingsRoot: settingsRoot,
      modelName: modelName,
      serialNumber: serialNumber,
      firmwareVersion: firmwareVersion,
      apiVersion: apiVersion,
      castName: castName,
      roomName: roomName,
      mac: mac,
      maxVolume: maxVolume,
      inputs: inputs,
      apps: apps,
    );
    sim._power = power;
    final (serving, idle) = servesLegacyPort
        ? (legacy, primary)
        : (primary, legacy);
    await idle.close(force: true);
    if (power == VizioSimPower.off) {
      await serving.close(force: true);
    } else {
      sim._attach(serving);
    }
    return sim;
  }

  /// Inputs by default: SmartCast (current), HDMI 1-3, component and the
  /// tuner.
  static const List<VizioSimInput> defaultInputs = [
    VizioSimInput('cast', 'CAST', meta: 'SMARTCAST'),
    VizioSimInput('hdmi1', 'HDMI-1', meta: 'Game Console'),
    VizioSimInput('hdmi2', 'HDMI-2'),
    VizioSimInput('hdmi3', 'HDMI-3'),
    VizioSimInput('comp', 'COMP'),
    VizioSimInput('tuner', 'TV'),
  ];

  /// Launchable apps by default, with the payloads the brief verified
  /// against vizaio's bundled availability data.
  static const List<VizioSimApp> defaultApps = [
    VizioSimApp('Netflix', '1', 3),
    VizioSimApp('YouTube', '1', 5),
    VizioSimApp(
      'SmartCast Home',
      '1',
      4,
      message: 'http://127.0.0.1:12345/scfs/sctv/main.html',
    ),
  ];

  /// The address the API listens on.
  final String host;

  /// The primary API port (stands in for 7345).
  final int apiPort;

  /// The legacy API port (stands in for 9000).
  final int legacyPort;

  /// Whether the API listens on [legacyPort] instead of [apiPort].
  final bool servesLegacyPort;

  /// The fixed PIN, if one was given to [start].
  final String? fixedPin;

  /// Wrong PINs per challenge; the last one answers
  /// `MAX_CHALLENGES_EXCEEDED` and locks pairing until `/pairing/cancel`.
  final int maxPinAttempts;

  /// Controller ids the pairing table holds before `/pairing/start` answers
  /// `TOO_MANY_PAIRED_DEVICES`.
  final int maxPairedDevices;

  /// Eco mode: the power-off key closes the API port (Quick Start keeps it
  /// open in standby).
  bool ecoMode;

  /// Firmware older than about 3.7: `current_input` also accepts the
  /// display name, and identity is served per field instead of as an
  /// aggregate.
  bool legacyFirmware;

  /// Volume-V2 firmware: the flat `/audio/volume/level` and
  /// `/audio/volume/mute` endpoints exist.
  bool v2Volume;

  /// Whether `deviceinfo` advertises, and the API serves, `/state_extended`.
  bool stateExtended;

  /// Whether the TV has a tuner (channel keys and digit entry are `FAILURE`
  /// without one).
  bool hasTuner;

  /// How answer keys are spelt.
  VizioSimKeyCase keyCase;

  /// `tv_settings` for a TV, `audio_settings` for a sound bar.
  String settingsRoot;

  /// `SYSTEM_INFO.MODEL_NAME`.
  String modelName;

  /// `SYSTEM_INFO.SERIAL_NUMBER`.
  String serialNumber;

  /// `SYSTEM_INFO.VERSION`.
  String firmwareVersion;

  /// `API_VERSION`.
  String apiVersion;

  /// `CAST_NAME`.
  String castName;

  /// The friendly (room) name in the mDNS TXT `name` key.
  String roomName;

  /// The MAC advertised in the mDNS TXT `wifi` key.
  String mac;

  /// The volume ceiling (100 on TVs).
  final int maxVolume;

  /// Inputs listed by `name_input`. Mutable.
  final List<VizioSimInput> inputs;

  /// Apps `/app/launch` accepts. Mutable.
  final List<VizioSimApp> apps;

  final Random _random;
  VizioSimulatorCertificate _certificate;
  HttpServer? _server;
  bool _vanished = false;
  bool _closed = false;
  VizioSimPower _power = VizioSimPower.on;
  int _answers = 0;
  int _inFlight = 0;
  int _maxInFlight = 0;
  final List<VizioSimRequest> _requests = [];
  final StreamController<VizioSimRequest> _requestEvents =
      StreamController.broadcast(sync: true);
  final List<String> _effects = [];
  final List<(int, int)> _keys = [];
  final List<_Fault> _faults = [];
  final List<VizioSimGate> _gates = [];
  final Map<String, String> _tokens = {};
  final List<String> _pairingNames = [];
  _Challenge? _challenge;
  int _cancels = 0;
  Timer? _wakeTimer;

  late int _volumeHash;
  late int _muteHash;
  late int _inputHash;
  late int _blankHash;

  int _volume = 15;
  bool _muted = false;
  String _currentInput;

  /// Volume, 0..[maxVolume]. Setting it stands in for a change the API did
  /// not make (the physical remote): like every change of the value, it
  /// rotates the leaf's `HASHVAL`, so a `HASHVAL` read before it is stale.
  int get volume => _volume;
  set volume(int level) {
    if (level == _volume) return;
    _volume = level;
    _volumeHash = _newHash(_volumeHash);
  }

  /// Mute. Setting it rotates the mute leaf's `HASHVAL` when it changes
  /// (see [volume]).
  bool get muted => _muted;
  set muted(bool value) {
    if (value == _muted) return;
    _muted = value;
    _muteHash = _newHash(_muteHash);
  }

  /// The cname of the current input. Setting it rotates `current_input`'s
  /// `HASHVAL` when it changes (see [volume]), whatever moved the TV:
  /// a `MODIFY`, an app launch or the SmartCast key, which switch to the
  /// cast input, or a test.
  String get currentInput => _currentInput;
  set currentInput(String cname) {
    if (cname == _currentInput) return;
    _currentInput = cname;
    _inputHash = _newHash(_inputHash);
  }

  /// The app in front, or `null` (an input without an app).
  VizioSimApp? currentApp;

  /// With no app in front, whether `/app/current` omits `VALUE` (true) or
  /// sends `VALUE: null` (false). Both shapes occur.
  bool omitAppValueWhenNone = false;

  /// Whether media plays (keys 2/3 and 2/2), for `MEDIA_STATE`.
  bool playing = false;

  /// Whether the panel was blanked through `blank_screen`.
  bool screenBlanked = false;

  /// Text typed with codeset-0 (ASCII) keys.
  String typedText = '';

  // --------------------------------------------------------------- getters

  /// The endpoint a driver uses: [host] with port names `smartcast` and
  /// `smartcastLegacy`.
  Endpoint get endpoint => Endpoint(
    host,
    ports: {vizioSimApiPortName: apiPort, vizioSimLegacyPortName: legacyPort},
  );

  /// The port the API listens on while it listens.
  int get activePort => servesLegacyPort ? legacyPort : apiPort;

  /// The simulated power.
  VizioSimPower get power => _power;

  /// Whether the API port accepts connections.
  bool get listening => _server != null;

  /// The certificate the API presents.
  VizioSimulatorCertificate get certificate => _certificate;

  /// SHA-256 of the current certificate, lower-case hex.
  String get certificateSha256 => _certificate.sha256Fingerprint;

  /// The PIN on the simulated screen, or `null`.
  String? get displayedPin => _challenge?.pin;

  /// Whether pairing is locked after too many wrong PINs.
  bool get pairingLocked => _challenge?.locked ?? false;

  /// The `DEVICE_NAME` of every `/pairing/start` that showed a PIN.
  List<String> get pairingNames => List.unmodifiable(_pairingNames);

  /// How many `/pairing/cancel` requests arrived.
  int get cancelCount => _cancels;

  /// Accepted tokens and the controller `DEVICE_ID` each was paired with.
  Map<String, String> get pairedTokens => Map.unmodifiable(_tokens);

  /// Accepted tokens.
  Set<String> get validTokens => _tokens.keys.toSet();

  /// Every request received, in order.
  List<VizioSimRequest> get requests => List.unmodifiable(_requests);

  /// Every request as it arrives (broadcast).
  Stream<VizioSimRequest> get onRequest => _requestEvents.stream;

  /// What the simulated TV did, in order, e.g. `power:off`, `volume:16`,
  /// `mute:on`, `input:hdmi1`, `launch:Netflix`, `text:H`, `pin:display`.
  List<String> get effects => List.unmodifiable(_effects);

  /// Every key of every accepted `KEYLIST`, as `(codeset, code)`.
  List<(int, int)> get keyPresses => List.unmodifiable(_keys);

  /// The most requests the simulator was answering at the same time. A
  /// client that serialises its requests keeps it at 1.
  int get maxConcurrentRequests => _maxInFlight;

  /// The current input's `current_input` value.
  String get currentInputValue => _input(currentInput)!.currentValue;

  /// The mDNS TXT record a `_viziocast._tcp` advertisement carries: `name`
  /// is the room name (not the model), `hsp` the REST port, `hp` the
  /// internal loopback port (which the simulator does not serve), `wifi`
  /// the MAC without separators.
  Map<String, String> get mdnsTxt => {
    'name': roomName,
    'id': serialNumber.codeUnits
        .map((c) => c.toRadixString(16).padLeft(2, '0'))
        .join(),
    'wp': '8005',
    'wsp': '8006',
    'hp': '7346',
    'hsp': '$activePort',
    'wifi': mac.replaceAll(':', '').toLowerCase(),
    'esn': 'ESN$serialNumber',
  };

  /// A discovery hit as an mDNS provider would report this TV.
  DiscoveryHit get mdnsHit => DiscoveryHit(
    host: host,
    provider: DiscoveryProviderId.mdns,
    port: activePort,
    serviceType: '_viziocast._tcp',
    name: roomName,
    attributes: {
      ...mdnsTxt,
      DiscoveryAttr.mdnsService: '_viziocast._tcp',
      DiscoveryAttr.mdnsInstance: '$roomName._viziocast._tcp.local',
    },
    mac: mac.toLowerCase(),
  );

  // -------------------------------------------------------- test controls

  /// Clears the request log, effects and key log (state is kept).
  void clearLog() {
    _requests.clear();
    _effects.clear();
    _keys.clear();
    _maxInFlight = _inFlight;
  }

  /// Forgets every pairing: later calls with any token get a raw 403, as
  /// after a factory reset.
  void revokeTokens() => _tokens.clear();

  /// Withdraws the PIN on screen (it timed out): the challenge token is no
  /// longer known, so `/pairing/pair` answers `CHALLENGE_INCORRECT`
  /// (synthetic: the references do not say which result an expired
  /// challenge gives).
  void expirePin() => _challenge = null;

  /// Answers the next request matching [method] and [path] (exact path,
  /// query ignored) with [status] and [body] instead of the normal
  /// handling. A [json] body is spelt as [keyCase] says.
  void respondOnce(
    String method,
    String path,
    int status, {
    String body = '',
    Map<String, Object?>? json,
  }) => _faults.add(_Fault(method.toUpperCase(), path, status, json ?? body));

  /// Holds the answer to the next [method] [path] request until
  /// [VizioSimGate.release]. The request is handled at once, so its effect
  /// happens; only the answer waits, as with a TV slow to reply.
  VizioSimGate holdNext(String method, String path) {
    final gate = VizioSimGate(method.toUpperCase(), path);
    _gates.add(gate);
    return gate;
  }

  /// The power button on the physical remote: on goes to standby (or off
  /// in [ecoMode], closing the port); standby or off goes on.
  Future<void> pressPowerOnRemote() =>
      _power == VizioSimPower.on ? _powerOff() : _powerOn();

  /// A Wake-on-LAN packet: an Eco-off TV starts listening [delay] later
  /// (the HTTPS server takes a while to start); a TV in standby turns on.
  Future<void> wake({Duration delay = Duration.zero}) async {
    _effects.add('wol');
    if (_power != VizioSimPower.off) {
      await _powerOn();
      return;
    }
    if (delay <= Duration.zero) {
      await _powerOn();
      return;
    }
    _wakeTimer?.cancel();
    _wakeTimer = Timer(delay, () => unawaited(_powerOn()));
  }

  /// The TV drops off the network (unplugged, Wi-Fi lost): the API port
  /// refuses connections until [reappear], whatever its power.
  Future<void> vanish() async {
    _vanished = true;
    await _unbind();
  }

  /// Undoes [vanish].
  Future<void> reappear() async {
    _vanished = false;
    if (_power != VizioSimPower.off) await _bind();
  }

  /// Switches the API to [certificate], restarting it on the same port (a
  /// TV whose certificate changed since pairing).
  Future<void> restartWithCertificate(
    VizioSimulatorCertificate certificate,
  ) async {
    _certificate = certificate;
    if (_server != null) {
      await _unbind();
      await _bind();
    }
  }

  /// Stops the API.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wakeTimer?.cancel();
    for (final gate in _gates) {
      gate.release();
    }
    await _unbind();
    await _requestEvents.close();
  }

  // ------------------------------------------------------------- lifecycle

  Future<void> _powerOn() async {
    final wasOff = _power == VizioSimPower.off;
    _power = VizioSimPower.on;
    _effects.add('power:on');
    if (wasOff) await _bind();
  }

  Future<void> _powerOff() async {
    _power = ecoMode ? VizioSimPower.off : VizioSimPower.standby;
    _challenge = null;
    playing = false;
    _effects.add('power:off');
    if (ecoMode) await _unbind();
  }

  Future<void> _bind() async {
    if (_closed || _vanished || _server != null) return;
    _attach(
      await HttpServer.bindSecure(host, activePort, _certificate.context()),
    );
  }

  Future<void> _unbind() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  void _attach(HttpServer server) {
    _server = server;
    server.listen(_handle);
  }

  // ------------------------------------------------------------- handling

  Future<void> _handle(HttpRequest request) async {
    _inFlight++;
    if (_inFlight > _maxInFlight) _maxInFlight = _inFlight;
    final res = request.response;
    try {
      final req = await _record(request);
      final reply = _route(req);
      final gateIndex = _gates.indexWhere((g) => g.matches(req));
      if (gateIndex >= 0) await _gates.removeAt(gateIndex).hold(req);
      res.statusCode = reply.status;
      final body = reply.body;
      if (body is Map<String, Object?>) {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(_spell(body)));
      } else if (body is String && body.isNotEmpty) {
        res.headers.contentType = ContentType.text;
        res.write(body);
      }
      await res.close();
      // The power-off key in Eco mode: the answer goes out, then the port
      // closes.
      if (reply.thenClose) await _unbind();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {
        // The connection is already gone.
      }
    } finally {
      _inFlight--;
    }
  }

  Future<VizioSimRequest> _record(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name] = values.join(', '),
    );
    final req = VizioSimRequest(request.method, request.uri, headers, body);
    _requests.add(req);
    if (!_requestEvents.isClosed) _requestEvents.add(req);
    return req;
  }

  _Reply _route(VizioSimRequest req) {
    final faultIndex = _faults.indexWhere(
      (f) => f.method == req.method && f.path == req.path,
    );
    if (faultIndex >= 0) {
      final fault = _faults.removeAt(faultIndex);
      return _Reply(fault.status, fault.body);
    }
    final m = req.method;
    final path = req.path;
    if (m == 'GET' && path == '/state/device/deviceinfo') return _deviceInfo();
    if (m == 'PUT' && path.startsWith('/pairing/')) return _pairing(req);
    final token = req.header('auth');
    if (token == null || !_tokens.containsKey(token)) {
      // A raw refusal with no envelope (vizaio maps it to an auth error).
      return const _Reply(403, '');
    }
    // Settings paths are matched relative to the settings root, so the
    // cases below are constants: `dynamic:audio/volume`, say.
    final dynamicRoot = '/menu_native/dynamic/$settingsRoot/';
    final staticRoot = '/menu_native/static/$settingsRoot/';
    final route = path.startsWith(dynamicRoot)
        ? 'dynamic:${path.substring(dynamicRoot.length)}'
        : path.startsWith(staticRoot)
        ? 'static:${path.substring(staticRoot.length)}'
        : path;
    return switch ((m, route)) {
      ('GET', '/state/device/power_mode') => _ok(
        path,
        items: [
          {
            'CNAME': 'power_mode',
            'TYPE': 'T_VALUE_V1',
            'VALUE': _power == VizioSimPower.on ? 1 : 0,
          },
        ],
      ),
      ('GET', '/state_extended') => _stateExtended(),
      ('PUT', '/key_command/') => _keyCommand(req),
      ('GET', '/app/current') => _appCurrent(),
      ('PUT', '/app/launch') => _launch(req),
      ('GET', 'static:audio/volume') => _ok(
        path,
        items: [
          {
            'CNAME': 'volume',
            'TYPE': 'T_VALUE_V1',
            'NAME': 'Volume',
            'MINIMUM': 0,
            'MAXIMUM': maxVolume,
            'INCREMENT': 1,
          },
        ],
      ),
      ('GET', 'dynamic:audio') => _ok(
        path,
        // Some firmware omits `volume` from the collection (vizaio
        // protocol-notes #30), which is why clients read the leaf.
        items: [_muteItem()],
      ),
      ('GET', 'dynamic:audio/volume') => _ok(path, items: [_volumeItem()]),
      ('PUT', 'dynamic:audio/volume') => _modifyVolume(req),
      ('GET', 'dynamic:audio/mute') => _ok(path, items: [_muteItem()]),
      ('PUT', 'dynamic:audio/mute') => _modifyMute(req),
      ('GET', 'dynamic:devices/name_input') => _ok(
        path,
        items: [
          for (final i in inputs)
            {
              'CNAME': i.cname,
              'TYPE': 'T_DEVICE_V1',
              'NAME': i.name,
              'VALUE': {'NAME': i.meta, 'METADATA': ''},
              'ENABLED': 'TRUE',
            },
        ],
      ),
      ('GET', 'dynamic:devices/current_input') => _ok(
        path,
        items: [_currentInputItem()],
      ),
      ('PUT', 'dynamic:devices/current_input') => _modifyInput(req),
      ('GET', 'dynamic:system/timers/blank_screen') => _ok(
        path,
        items: [
          {
            'CNAME': 'blank_screen',
            'TYPE': 'T_ACTION_V1',
            'NAME': 'Blank Screen',
            'HASHVAL': _blankHash,
          },
        ],
      ),
      ('PUT', 'dynamic:system/timers/blank_screen') => _blankScreen(req),
      ('GET', '/audio/volume/level') when v2Volume => _ok(
        path,
        item: {
          'TYPE': 'T_JSON_OBJECT_V1',
          'VALUE': {'LEVEL': volume, 'MUTE': muted},
        },
      ),
      ('PUT', '/audio/volume/level') when v2Volume => _flatLevel(req),
      ('GET', '/audio/volume/mute') when v2Volume => _ok(
        path,
        item: {'TYPE': 'T_BOOLEAN_V1', 'VALUE': muted},
      ),
      ('PUT', '/audio/volume/mute') when v2Volume => _flatMute(req),
      ('GET' || 'PUT', '/audio/volume/level' || '/audio/volume/mute') =>
        _status(path, 'URI_NOT_FOUND'),
      _ when route.startsWith('dynamic:system/system_information') =>
        _systemInformation(req),
      // An unknown settings leaf is a clean "not on this firmware".
      _ when path.startsWith('/menu_native/') => _status(path, 'URI_NOT_FOUND'),
      // lighttpd's answer to a path SCPL does not route.
      _ => const _Reply(500, 'Unhandled Exception'),
    };
  }

  // ------------------------------------------------------------ envelopes

  /// Applies [keyCase] to every key of [json].
  Object? _spell(Object? json) {
    final lower = switch (keyCase) {
      VizioSimKeyCase.upper => false,
      VizioSimKeyCase.lower => true,
      VizioSimKeyCase.alternate => _answers.isOdd,
    };
    _answers++;
    return lower ? _lowerKeys(json) : json;
  }

  static Object? _lowerKeys(Object? json) => switch (json) {
    final Map<String, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries)
        key.toLowerCase(): _lowerKeys(value),
    },
    final List<Object?> l => [for (final v in l) _lowerKeys(v)],
    _ => json,
  };

  static _Reply _ok(
    String uri, {
    List<Map<String, Object?>>? items,
    Map<String, Object?>? item,
  }) => _status(uri, 'SUCCESS', items: items, item: item);

  static _Reply _status(
    String uri,
    String result, {
    List<Map<String, Object?>>? items,
    Map<String, Object?>? item,
  }) => _Reply(200, {
    'ITEM': ?item,
    'ITEMS': ?items,
    'STATUS': {'RESULT': result, 'DETAIL': _details[result] ?? result},
    'URI': uri,
  });

  // Synthetic detail texts; the references only quote "Success".
  static const Map<String, String> _details = {
    'SUCCESS': 'Success',
    'BLOCKED': 'Blocked',
    'PAIRING_DENIED': 'Pairing denied',
    'CHALLENGE_INCORRECT': 'Challenge incorrect',
    'MAX_CHALLENGES_EXCEEDED': 'Max challenges exceeded',
    'VALUE_OUT_OF_RANGE': 'Value out of range',
    'TOO_MANY_PAIRED_DEVICES': 'Too many paired devices',
    'INVALID_PARAMETER': 'Invalid parameter',
    'HASHVAL_ERROR': 'Hashval error',
    'URI_NOT_FOUND': 'Uri not found',
    'FAILURE': 'Failure',
    'PROXY_ERROR': 'Proxy error',
    'READ_ONLY_ERROR': 'Read only error',
    'TYPE_ERROR': 'Type error',
  };

  // ----------------------------------------------------------- deviceinfo

  _Reply _deviceInfo() => _ok(
    '/state/device/deviceinfo',
    items: [
      {
        'CNAME': 'deviceinfo',
        'TYPE': 'T_DEVICEINFO_V1', // synthetic type name
        'VALUE': {
          'SETTINGS_ROOT': settingsRoot,
          'SYSTEM_INFO': {
            'MODEL_NAME': modelName,
            'SERIAL_NUMBER': serialNumber,
            'VERSION': firmwareVersion,
            'CHIPSET': 'SIM5',
            'DEVICE_TYPE': settingsRoot == 'tv_settings' ? 'TV' : 'SOUNDBAR',
          },
          'API_VERSION': apiVersion,
          'CAST_NAME': castName,
          // Shape synthetic; the brief only says `state_extended` is listed.
          'SCPL_CAPABILITIES': [if (stateExtended) 'state_extended'],
          'INPUTS': [for (final i in inputs) i.cname],
        },
      },
    ],
  );

  // -------------------------------------------------------------- pairing

  _Reply _pairing(VizioSimRequest req) {
    final path = req.path;
    final body = req.json;
    switch (path) {
      case '/pairing/start':
        if (body
            case {
              'DEVICE_ID': final String id,
              'DEVICE_NAME': final String name,
            }
            when id.isNotEmpty) {
          if (_challenge != null) return _status(path, 'BLOCKED');
          final ids = _tokens.values.toSet();
          if (!ids.contains(id) && ids.length >= maxPairedDevices) {
            return _status(path, 'TOO_MANY_PAIRED_DEVICES');
          }
          final pin =
              fixedPin ?? _random.nextInt(10000).toString().padLeft(4, '0');
          final challenge = _Challenge(
            id,
            100000 + _random.nextInt(900000),
            pin,
          );
          _challenge = challenge;
          _pairingNames.add(name);
          _effects.add('pin:display');
          return _ok(
            path,
            item: {
              'CHALLENGE_TYPE': 1,
              'PAIRING_REQ_TOKEN': challenge.reqToken,
            },
          );
        }
        return _status(path, 'INVALID_PARAMETER');
      case '/pairing/pair':
        if (body case {
          'DEVICE_ID': final String id,
          'CHALLENGE_TYPE': final int type,
          'RESPONSE_VALUE': final String value,
          'PAIRING_REQ_TOKEN': final int reqToken,
        }) {
          final challenge = _challenge;
          if (challenge == null ||
              challenge.deviceId != id ||
              challenge.reqToken != reqToken ||
              type != 1) {
            return _status(path, 'CHALLENGE_INCORRECT');
          }
          if (challenge.locked) return _status(path, 'MAX_CHALLENGES_EXCEEDED');
          if (!RegExp(r'^\d{4}$').hasMatch(value)) {
            return _status(path, 'VALUE_OUT_OF_RANGE');
          }
          if (value != challenge.pin) {
            challenge.wrong++;
            _effects.add('pin:wrong');
            if (challenge.wrong >= maxPinAttempts) {
              challenge.locked = true;
              return _status(path, 'MAX_CHALLENGES_EXCEEDED');
            }
            return _status(path, 'PAIRING_DENIED');
          }
          _challenge = null;
          // Re-pairing with the same DEVICE_ID overwrites the old token.
          _tokens.removeWhere((_, owner) => owner == id);
          final token = List.generate(
            24,
            (_) => _alphabet[_random.nextInt(_alphabet.length)],
          ).join();
          _tokens[token] = id;
          _effects.add('pin:paired');
          return _ok(path, item: {'AUTH_TOKEN': token});
        }
        return _status(path, 'INVALID_PARAMETER');
      case '/pairing/cancel':
        _cancels++;
        // Synthetic: any cancel clears the challenge and its lockout.
        if (_challenge != null) _effects.add('pin:cancel');
        _challenge = null;
        return _ok(path);
      default:
        return const _Reply(500, 'Unhandled Exception');
    }
  }

  // -------------------------------------------------------------- state

  _Reply _stateExtended() {
    if (!stateExtended) return _status('/state_extended', 'URI_NOT_FOUND');
    // Flat, with no STATUS or ITEMS. POWER_MODE is a label that can say
    // "Quick Start" while POWER_STATUS says on: clients must read on/off
    // from POWER_STATUS.
    return _Reply(200, {
      'POWER_STATUS': {'VALUE': _power == VizioSimPower.on ? 1 : 0},
      'POWER_MODE': {'VALUE': ecoMode ? 'Eco Mode' : 'Quick Start'},
      'CURRENT_INPUT': {'VALUE': currentInputValue, 'HASHVAL': _inputHash},
      'APP_CURRENT': {'VALUE': currentApp?.toValue()},
      'MEDIA_STATE': {
        'VALUE': playing ? 'MediaState::Playing' : 'MediaState::Stopped',
      },
      'SCREEN_MODE': {'VALUE': screenBlanked ? 'Blank' : 'Normal'},
    });
  }

  _Reply _appCurrent() {
    final app = currentApp;
    return _ok(
      '/app/current',
      item: {
        'TYPE': 'T_APP_V1',
        if (app != null)
          'VALUE': app.toValue()
        else if (!omitAppValueWhenNone)
          'VALUE': null,
      },
    );
  }

  _Reply _launch(VizioSimRequest req) {
    const path = '/app/launch';
    if (req.json case {
      'VALUE': {
        'APP_ID': final String appId,
        'NAME_SPACE': final int nameSpace,
        'MESSAGE': final String? message,
      },
    }) {
      final app = apps
          .where(
            (a) =>
                a.appId == appId &&
                a.nameSpace == nameSpace &&
                (a.message == null || a.message == message),
          )
          .firstOrNull;
      // Synthetic: what a real TV answers for an app it lacks is
      // undocumented.
      if (app == null || _power != VizioSimPower.on) {
        return _status(path, 'FAILURE');
      }
      currentApp = app;
      currentInput = 'cast';
      _effects.add('launch:${app.name}');
      return _ok(path);
    }
    return _status(path, 'INVALID_PARAMETER');
  }

  // ---------------------------------------------------------------- keys

  _Reply _keyCommand(VizioSimRequest req) {
    const path = '/key_command/';
    final list = switch (req.json) {
      {'KEYLIST': final List<Object?> l} when l.isNotEmpty => l,
      _ => null,
    };
    if (list == null) return _status(path, 'INVALID_PARAMETER');
    final keys = <(int, int)>[];
    for (final entry in list) {
      if (entry case {
        'CODESET': final int codeset,
        'CODE': final int code,
        'ACTION': 'KEYPRESS' || 'KEYDOWN' || 'KEYUP',
      }) {
        keys.add((codeset, code));
      } else {
        return _status(path, 'INVALID_PARAMETER');
      }
    }
    // A tuner-less panel refuses channel keys and digit entry (codeset-0
    // ASCII '0'-'9', how a channel number is typed): vizaio saw per-key
    // FAILURE for digit keys on one (brief §6, §10). Refusing the whole
    // list, with nothing applied, is synthetic.
    if (!hasTuner &&
        keys.any((k) => k.$1 == 8 || (k.$1 == 0 && k.$2 >= 48 && k.$2 <= 57))) {
      return _status(path, 'FAILURE');
    }
    var thenClose = false;
    for (final key in keys) {
      _keys.add(key);
      if (_applyKey(key)) thenClose = true;
    }
    final reply = _ok(path);
    return _Reply(reply.status, reply.body, thenClose: thenClose);
  }

  /// Applies one key; returns true when the port must close after the
  /// answer (power off in Eco mode).
  bool _applyKey((int, int) key) {
    final on = _power == VizioSimPower.on;
    switch (key) {
      case (11, 0):
        if (_power == VizioSimPower.on) {
          _power = ecoMode ? VizioSimPower.off : VizioSimPower.standby;
          _challenge = null;
          playing = false;
          _effects.add('power:off');
          return ecoMode;
        }
      case (11, 1):
        if (_power != VizioSimPower.on) {
          _power = VizioSimPower.on;
          _effects.add('power:on');
        }
      case (11, 2):
        _effects.add('power:toggle');
        if (_power == VizioSimPower.on) {
          _power = ecoMode ? VizioSimPower.off : VizioSimPower.standby;
          return ecoMode;
        }
        _power = VizioSimPower.on;
      case (5, 1):
        _setVolume(volume + 1);
      case (5, 0):
        _setVolume(volume - 1);
      case (5, 2) || (5, 3) || (5, 4):
        // 5/2 and 5/3 behave as toggles on TV firmware (protocol-notes V6).
        if (on) _setMuted(!muted);
      case (2, 3) when on:
        playing = true;
        _effects.add('media:play');
      case (2, 2) when on:
        playing = false;
        _effects.add('media:pause');
      case (4, 3) when on:
        currentApp = apps.where((a) => a.nameSpace == 4).firstOrNull;
        currentInput = 'cast';
        _effects.add('smartcast');
      case (0, final int c) when on:
        typedText += String.fromCharCode(c);
        _effects.add('text:${String.fromCharCode(c)}');
      case (final int cs, final int c) when on:
        _effects.add('key:$cs/$c');
      default:
        // Standby: only power and volume act.
        break;
    }
    return false;
  }

  // ------------------------------------------------------------- settings

  Map<String, Object?> _volumeItem() => {
    'CNAME': 'volume',
    'TYPE': 'T_VALUE_V1',
    'NAME': 'Volume',
    'VALUE': volume,
    'HASHVAL': _volumeHash,
  };

  Map<String, Object?> _muteItem() => {
    'CNAME': 'mute',
    'TYPE': 'T_LIST_V1',
    'NAME': 'Mute',
    'VALUE': muted ? 'On' : 'Off',
    'HASHVAL': _muteHash,
  };

  Map<String, Object?> _currentInputItem() => {
    'CNAME': 'current_input',
    'TYPE': 'T_STRING_V1',
    'NAME': 'Current Input',
    'VALUE': currentInputValue,
    'HASHVAL': _inputHash,
  };

  void _setVolume(int level) {
    final clamped = level.clamp(0, maxVolume);
    if (clamped == volume) return;
    volume = clamped;
    _effects.add('volume:$volume');
  }

  void _setMuted(bool value) {
    if (value == muted) return;
    muted = value;
    _effects.add('mute:${value ? 'on' : 'off'}');
  }

  /// The checks every `MODIFY` shares: the verb, then a `HASHVAL` that
  /// matches [current]. Returns the failure, or `null` with the `VALUE`.
  (_Reply?, Object?) _modify(
    VizioSimRequest req,
    int current, {
    String verb = 'MODIFY',
  }) {
    final path = req.path;
    final body = req.json;
    if (body is! Map<String, Object?>) {
      return (_status(path, 'INVALID_PARAMETER'), null);
    }
    final request = body['REQUEST'];
    if (request != verb) {
      return (
        _status(path, request is String ? 'PROXY_ERROR' : 'INVALID_PARAMETER'),
        null,
      );
    }
    final hash = body['HASHVAL'];
    if (hash is! int) return (_status(path, 'INVALID_PARAMETER'), null);
    if (hash != current) return (_status(path, 'HASHVAL_ERROR'), null);
    return (null, body['VALUE']);
  }

  _Reply _modifyVolume(VizioSimRequest req) {
    final (failure, value) = _modify(req, _volumeHash);
    if (failure != null) return failure;
    if (value is! int) return _status(req.path, 'INVALID_PARAMETER');
    if (value < 0 || value > maxVolume) {
      return _status(req.path, 'VALUE_OUT_OF_RANGE'); // synthetic
    }
    _setVolume(value);
    return _ok(req.path);
  }

  _Reply _modifyMute(VizioSimRequest req) {
    final (failure, value) = _modify(req, _muteHash);
    if (failure != null) return failure;
    if (value != 'On' && value != 'Off') {
      return _status(req.path, 'INVALID_PARAMETER');
    }
    // Mute is inert in standby: acknowledged, nothing changes.
    if (_power == VizioSimPower.on) _setMuted(value == 'On');
    return _ok(req.path);
  }

  _Reply _modifyInput(VizioSimRequest req) {
    final path = req.path;
    final body = req.json;
    if (body is! Map<String, Object?> || body['REQUEST'] != 'MODIFY') {
      return _status(path, 'INVALID_PARAMETER');
    }
    final hash = body['HASHVAL'];
    final value = body['VALUE'];
    if (hash is! int || value is! String) {
      return _status(path, 'INVALID_PARAMETER');
    }
    // A meta name is not an input id at all: the TV reports a HASHVAL
    // error (vizaio protocol-notes V2).
    final byMeta = inputs.where((i) => i.meta.isNotEmpty && i.meta == value);
    if (byMeta.isNotEmpty && _input(value) == null) {
      return _status(path, 'HASHVAL_ERROR');
    }
    if (hash != _inputHash) return _status(path, 'HASHVAL_ERROR');
    final target =
        _input(value) ??
        (legacyFirmware
            ? inputs.where((i) => i.name == value).firstOrNull
            : null);
    // The display name on modern firmware, an unknown value, or the input
    // already current: FAILURE.
    if (target == null || target.cname == currentInput) {
      return _status(path, 'FAILURE');
    }
    currentInput = target.cname;
    if (target.cname != 'cast') currentApp = null;
    _effects.add('input:${target.cname}');
    return _ok(path);
  }

  _Reply _blankScreen(VizioSimRequest req) {
    final (failure, _) = _modify(req, _blankHash, verb: 'ACTION');
    if (failure != null) return failure;
    screenBlanked = true;
    _blankHash = _newHash(_blankHash);
    _effects.add('blank_screen');
    return _ok(req.path);
  }

  _Reply _systemInformation(VizioSimRequest req) {
    final path = req.path;
    if (req.method == 'PUT') return _status(path, 'READ_ONLY_ERROR');
    final base =
        '/menu_native/dynamic/$settingsRoot/system/system_information/'
        'tv_information';
    final fields = {'serial_number': serialNumber, 'version': firmwareVersion};
    Map<String, Object?> item(String cname, String value) => {
      'CNAME': cname,
      'TYPE': 'T_STRING_V1',
      'VALUE': value,
      'HASHVAL': value.hashCode & 0x7fffffff,
    };
    // Modern firmware serves the aggregate and refuses per-field paths;
    // legacy firmware the other way round.
    if (path == base) {
      return legacyFirmware
          ? _status(path, 'URI_NOT_FOUND')
          : _ok(
              path,
              items: [
                for (final MapEntry(:key, :value) in fields.entries)
                  item(key, value),
              ],
            );
    }
    for (final MapEntry(:key, :value) in fields.entries) {
      if (path == '$base/$key') {
        return legacyFirmware
            ? _ok(path, items: [item(key, value)])
            : _status(path, 'URI_NOT_FOUND');
      }
    }
    return _status(path, 'URI_NOT_FOUND');
  }

  _Reply _flatLevel(VizioSimRequest req) {
    final path = req.path;
    return switch (req.json) {
      {'LEVEL': final int level} when level >= 0 && level <= maxVolume => () {
        _setVolume(level);
        return _ok(path);
      }(),
      {'LEVEL': int()} => _status(path, 'VALUE_OUT_OF_RANGE'),
      {'LEVEL': _} => _status(path, 'TYPE_ERROR'),
      _ => _status(path, 'INVALID_PARAMETER'),
    };
  }

  _Reply _flatMute(VizioSimRequest req) {
    final path = req.path;
    return switch (req.json) {
      {'MUTE': final bool value} => () {
        if (_power == VizioSimPower.on) _setMuted(value);
        return _ok(path);
      }(),
      {'MUTE': _} => _status(path, 'TYPE_ERROR'),
      _ => _status(path, 'INVALID_PARAMETER'),
    };
  }

  // -------------------------------------------------------------- helpers

  VizioSimInput? _input(String cname) =>
      inputs.where((i) => i.cname == cname).firstOrNull;

  /// A fresh opaque HASHVAL, different from [old].
  int _newHash([int? old]) {
    while (true) {
      final hash = _random.nextInt(1 << 32);
      if (hash != old) return hash;
    }
  }

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
}

final class _Reply {
  const _Reply(this.status, this.body, {this.thenClose = false});

  final int status;

  /// A JSON object (spelt per key case), a text body, or `''` for none.
  final Object? body;

  /// Close the API port once the answer is out.
  final bool thenClose;
}

final class _Fault {
  _Fault(this.method, this.path, this.status, this.body);

  final String method;
  final String path;
  final int status;
  final Object body;
}

final class _Challenge {
  _Challenge(this.deviceId, this.reqToken, this.pin);

  final String deviceId;
  final int reqToken;
  final String pin;
  int wrong = 0;
  bool locked = false;
}
