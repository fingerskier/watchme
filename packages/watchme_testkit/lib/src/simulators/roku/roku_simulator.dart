import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart' show Endpoint;

import 'roku_sim_models.dart';
import 'roku_sim_xml.dart';

/// A Roku ECP device on loopback, for driver, engine and UI tests.
///
/// Serves ECP over HTTP (`dart:io`) on a random port, keeps its state in
/// memory, and records what clients did. It models the behaviour that
/// matters to a controller and that brs-desktop does not: the
/// "Control by mobile apps" levels with Roku's 403 bodies, the rule that
/// `Host` must be an IP literal, and network standby.
///
/// ```dart
/// final sim = RokuSimulator(controlMode: RokuControlMode.limited);
/// await sim.start();
/// final ep = sim.endpoint; // Endpoint('127.0.0.1', ports: {'ecp': sim.port})
/// // ... drive it ...
/// expect(sim.keyLog, [const RokuSimKeyEvent(RokuSimKeyAction.press, 'Home')]);
/// await sim.stop();
/// ```
///
/// Simulator choices where real behaviour is unverified: unknown key names
/// get 400, unknown apps on `launch` get 404, standby refusals and Host
/// refusals have empty bodies, and the disabled level answers
/// `ECP command not allowed.`
///
/// Test controls: [holdNext] holds one answer back until released (a
/// command caught mid-way), and `stop(force: false)` stops listening while
/// a held answer still goes out (a device that drops off the network right
/// after acting on a request).
class RokuSimulator {
  /// Creates a simulator (not yet listening; call [start]).
  ///
  /// [apps] defaults to [defaultApps] for [device]. With
  /// [limitedAllowsLaunch] (default true, per Roku's description of the
  /// Limited level) `launch` works in Limited mode. With
  /// [standbyAcceptsPowerOn] (default true) the `PowerOn` and `Power` keys
  /// work in standby (`Ready`); false models the report that a TV in
  /// standby refuses everything but device-info. [latency] delays every
  /// HTTP answer.
  RokuSimulator({
    this.device = const RokuSimDevice(),
    this.controlMode = RokuControlMode.enabled,
    this.powerMode = RokuSimPowerMode.powerOn,
    List<RokuSimApp>? apps,
    this.limitedAllowsLaunch = true,
    this.standbyAcceptsPowerOn = true,
    this.enforceIpHost = true,
    this.latency = Duration.zero,
  }) : apps = apps ?? defaultApps(device);

  /// A plausible app list: common channels, Media Assistant, and on a TV
  /// the `tvinput.*` entries for the tuner, HDMI 1-3 and AV.
  static List<RokuSimApp> defaultApps(RokuSimDevice device) => [
    const RokuSimApp('2213', 'Roku Media Player', version: '5.4.27'),
    const RokuSimApp('12', 'Netflix', version: '5.2.98079401'),
    const RokuSimApp('837', 'YouTube', version: '2.21.100005034'),
    const RokuSimApp('13', 'Prime Video', version: '15.4.2024091714'),
    const RokuSimApp('291097', 'Disney+', version: '1.48.2024'),
    const RokuSimApp('782875', 'Media Assistant', version: '2.3.1'),
    if (device.isTv) ...const [
      RokuSimApp('tvinput.dtv', 'Live TV', type: 'tvin'),
      RokuSimApp('tvinput.hdmi1', 'HDMI 1', type: 'tvin'),
      RokuSimApp('tvinput.hdmi2', 'HDMI 2', type: 'tvin'),
      RokuSimApp('tvinput.hdmi3', 'HDMI 3', type: 'tvin'),
      RokuSimApp('tvinput.cvbs', 'AV', type: 'tvin'),
    ],
  ];

  /// The 403 body Roku OS 14.1+ sends in Limited mode.
  static const String limitedModeBody =
      'ECP command not allowed in Limited mode.';

  /// The 403 body the simulator sends while ECP is disabled.
  static const String disabledBody = 'ECP command not allowed.';

  /// Every key name the simulator accepts (besides `Lit_`), matched
  /// case-insensitively.
  static const Set<String> keyNames = {
    'Home', 'Rev', 'Fwd', 'Play', 'Select', 'Left', 'Right', 'Down', 'Up', //
    'Back', 'InstantReplay', 'Info', 'Backspace', 'Search', 'Enter',
    'FindRemote', 'VolumeDown', 'VolumeMute', 'VolumeUp', 'PowerOff',
    'PowerOn', 'Power', 'ChannelUp', 'ChannelDown', 'InputTuner',
    'InputHDMI1', 'InputHDMI2', 'InputHDMI3', 'InputHDMI4', 'InputAV1',
  };

  static final Map<String, String> _canonicalKeys = {
    for (final k in keyNames) k.toLowerCase(): k,
  };

  // Paths Limited mode refuses (Roku's doc list plus field reports).
  static const Set<String> _limitedPaths = {
    'keypress',
    'keydown',
    'keyup',
    'input',
    'query/apps',
    'query/media-player',
    'query/icon',
    'query/tv-channels',
    'query/tv-active-channel',
  };

  /// The identity served.
  final RokuSimDevice device;

  /// "Control by mobile apps". Mutable while running.
  RokuControlMode controlMode;

  /// `power-mode`. Mutable while running; `PowerOn`/`PowerOff` keys change
  /// it too.
  RokuSimPowerMode powerMode;

  /// Installed apps. Mutable.
  final List<RokuSimApp> apps;

  /// Whether `launch` works in Limited mode.
  bool limitedAllowsLaunch;

  /// Whether `keypress/PowerOn` (and `Power`) work in standby. Field
  /// reports differ: libraries use PowerOn on TVs with Fast TV Start, while
  /// remoku (low evidence weight) reports that standby refuses everything
  /// but device-info with 403. Mutable while running.
  bool standbyAcceptsPowerOn;

  /// Whether a non-IP `Host` header gets an empty 403, as on real firmware.
  bool enforceIpHost;

  /// Delay before every HTTP answer.
  Duration latency;

  /// The foreground app id; `null` is the home screen.
  String? activeAppId;

  /// Media player state.
  RokuSimPlayerState playerState = RokuSimPlayerState.close;

  /// Media position.
  Duration playerPosition = Duration.zero;

  /// Media length; `null` for none.
  Duration? playerDuration;

  /// Whether the media is live.
  bool playerIsLive = false;

  /// Internal volume 0..100, changed by the volume keys (not readable over
  /// ECP, but tests can assert on it).
  int volume = 20;

  /// Internal mute state, toggled by `VolumeMute`.
  bool muted = false;

  /// Text typed with `Lit_` keys since the last [clearLogs], with
  /// `Backspace` applied.
  String get typedText => String.fromCharCodes(_typed);
  final List<int> _typed = [];

  /// Accepted key requests, in order.
  List<RokuSimKeyEvent> get keyLog => List.unmodifiable(_keyLog);
  final List<RokuSimKeyEvent> _keyLog = [];

  /// Accepted launches, in order.
  List<RokuSimLaunch> get launches => List.unmodifiable(_launches);
  final List<RokuSimLaunch> _launches = [];

  /// Every HTTP request answered, in order.
  List<RokuSimRequest> get requests => List.unmodifiable(_requests);
  final List<RokuSimRequest> _requests = [];

  /// M-SEARCH requests the SSDP responder answered.
  int get ssdpReplies => _ssdpReplies;
  int _ssdpReplies = 0;

  HttpServer? _server;
  ServerSocket? _listener;
  Future<void>? _listenerClosed;
  RawDatagramSocket? _ssdp;
  DateTime _startedAt = DateTime.now();

  /// Whether [start] has completed and [stop] has not been called.
  bool get isRunning => _server != null;

  /// The address the HTTP server listens on (`127.0.0.1` by default).
  String get host => _require().address.address;

  /// The HTTP (ECP) port.
  int get port => _require().port;

  /// The SSDP responder's UDP port, or `null` when it is off.
  int? get ssdpPort => _ssdp?.port;

  /// The ECP base URI, as SSDP's `LOCATION` gives it.
  Uri get baseUri => Uri(scheme: 'http', host: host, port: port, path: '/');

  /// An endpoint for the Roku driver: [host] with the `ecp` port.
  Endpoint get endpoint => Endpoint(host, ports: {'ecp': port});

  HttpServer _require() =>
      _server ?? (throw StateError('RokuSimulator is not running'));

  /// Starts listening on [address] (loopback by default) and [port] (0 picks
  /// a free one). With [ssdp], also answers unicast SSDP M-SEARCH requests
  /// for `roku:ecp` (or `ssdp:all`) on UDP [ssdpPort] (0 picks a free one)
  /// with a `LOCATION` pointing at the HTTP server.
  Future<void> start({
    Object? address,
    int port = 0,
    bool ssdp = false,
    int ssdpPort = 0,
  }) async {
    if (_server != null) throw StateError('RokuSimulator is already running');
    final bind = address ?? InternetAddress.loopbackIPv4;
    // Bound here rather than by HttpServer.bind, so stop() can close the
    // port itself and know when it refuses new connections.
    final listener = await ServerSocket.bind(bind, port);
    final server = HttpServer.listenOn(listener);
    _listener = listener;
    _listenerClosed = null;
    server.defaultResponseHeaders.clear();
    server.autoCompress = false;
    _server = server;
    _startedAt = DateTime.now();
    server.listen(
      (request) => unawaited(_handle(request)),
      onError: (Object _) {},
    );
    if (ssdp) {
      final socket = await RawDatagramSocket.bind(server.address, ssdpPort);
      _ssdp = socket;
      socket.listen((event) {
        if (event == RawSocketEvent.read) _answerSsdp(socket);
      });
    }
  }

  /// Stops listening. Further requests are refused (unreachable) once
  /// [listenerClosed] completes.
  ///
  /// With [force] (the default) open connections are dropped and held
  /// answers released. Without it, connections already open finish first:
  /// a held answer still goes out once released, and the returned future
  /// completes after that.
  Future<void> stop({bool force = true}) async {
    _ssdp?.close();
    _ssdp = null;
    final server = _server;
    _server = null;
    final listener = _listener;
    _listener = null;
    final listenerClosed = _listenerClosed = listener?.close();
    if (force) {
      for (final gate in _gates) {
        gate.release();
      }
      _gates.clear();
    }
    final serverClosed = server?.close(force: force);
    await listenerClosed;
    await serverClosed;
  }

  /// After [stop]: completes once the port refuses new connections.
  ///
  /// Closing a port finishes asynchronously, so a connection attempted
  /// right after [stop] may still be accepted and then reset. A test that
  /// needs the next request refused (unreachable) awaits this first; a
  /// graceful stop's own future also waits for open connections.
  Future<void> get listenerClosed => _listenerClosed ?? Future.value();

  /// Holds the answer to the next request matching [method] and [path]
  /// (exact path, query ignored) until [RokuSimGate.release]. The request
  /// is handled at once, so its effect happens (a key lands in [keyLog]);
  /// only the answer waits, as with a device slow to reply.
  RokuSimGate holdNext(String method, String path) {
    final gate = RokuSimGate._(method.toUpperCase(), path);
    _gates.add(gate);
    return gate;
  }

  final List<RokuSimGate> _gates = [];

  Future<void> _gate(HttpRequest request) {
    for (final gate in _gates) {
      if (gate._matches(request)) {
        _gates.remove(gate);
        return gate._hold();
      }
    }
    return Future.value();
  }

  /// Clears [keyLog], [launches], [requests] and [typedText].
  void clearLogs() {
    _keyLog.clear();
    _launches.clear();
    _requests.clear();
    _typed.clear();
  }

  /// Puts [appId] in the foreground playing media at [position].
  void setPlaying(
    String appId, {
    RokuSimPlayerState state = RokuSimPlayerState.play,
    Duration position = Duration.zero,
    Duration? duration = const Duration(minutes: 42),
    bool isLive = false,
  }) {
    activeAppId = appId;
    playerState = state;
    playerPosition = position;
    playerDuration = duration;
    playerIsLive = isLive;
  }

  RokuSimApp? _app(String? id) =>
      id == null ? null : apps.where((a) => a.id == id).firstOrNull;

  // ------------------------------------------------------------------ HTTP

  Future<void> _handle(HttpRequest request) async {
    _Reply reply;
    try {
      reply = _route(request);
    } on Object catch (e) {
      reply = _Reply(500, e.toString());
    }
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    // Drain any request body before answering.
    await request.drain<void>();
    await _gate(request);
    _send(request, reply);
    try {
      await request.response.close();
    } on Object {
      // The client went away (e.g. it timed out during [latency]).
    }
  }

  void _send(HttpRequest request, _Reply reply) {
    _requests.add(
      RokuSimRequest(
        method: request.method,
        path: request.uri.path,
        query: request.uri.query,
        hostHeader: request.headers.value(HttpHeaders.hostHeader),
        status: reply.status,
      ),
    );
    final response = request.response
      ..statusCode = reply.status
      ..headers.set(
        HttpHeaders.serverHeader,
        'Roku/${device.softwareVersion} UPnP/1.0 Roku/${device.softwareVersion}',
      );
    if (reply.body.isNotEmpty) {
      response.headers.contentType = ContentType.parse(reply.contentType);
    }
    final bytes = reply.bytes ?? utf8.encode(reply.body);
    response
      ..contentLength = bytes.length
      ..add(bytes);
  }

  _Reply _route(HttpRequest request) {
    if (enforceIpHost && !_hostIsIp(request.headers.value('host'))) {
      return const _Reply(403, '');
    }
    final segments = request.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final method = request.method;
    final base = switch (segments) {
      ['query', final q, ...] => 'query/$q',
      [final first, ...] => first,
      [] => '',
    };
    final isDescription = segments.isEmpty;
    final isDeviceInfo = base == 'query/device-info';

    if (controlMode == RokuControlMode.disabled) {
      return const _Reply(403, disabledBody);
    }
    if (powerMode == RokuSimPowerMode.ready &&
        !isDescription &&
        !isDeviceInfo &&
        !(standbyAcceptsPowerOn &&
            base == 'keypress' &&
            segments.length == 2 &&
            const {'poweron', 'power'}.contains(segments[1].toLowerCase()))) {
      return const _Reply(403, '');
    }
    if (controlMode == RokuControlMode.limited &&
        (_limitedPaths.contains(base) ||
            (base == 'launch' && !limitedAllowsLaunch))) {
      return const _Reply(403, limitedModeBody);
    }

    return switch ((method, segments)) {
      ('GET', []) => _xml(rokuRootDescriptionXml(device)),
      ('GET', ['query', 'device-info']) => _xml(
        rokuDeviceInfoXml(
          device,
          powerMode: powerMode,
          controlMode: controlMode,
          uptime: DateTime.now().difference(_startedAt),
        ),
      ),
      ('GET', ['query', 'apps']) => _xml(rokuAppsXml(apps)),
      ('GET', ['query', 'active-app']) => _xml(
        rokuActiveAppXml(_app(activeAppId)),
      ),
      ('GET', ['query', 'media-player']) => _xml(
        rokuMediaPlayerXml(
          state: playerState,
          app: _app(activeAppId),
          position: playerPosition,
          duration: playerDuration,
          isLive: playerIsLive,
        ),
      ),
      ('GET', ['query', 'icon', final id]) =>
        _app(id) == null ? const _Reply(404, '') : _Reply.png(_onePixelPng),
      ('POST', ['keypress', final key]) => _key(RokuSimKeyAction.press, key),
      ('POST', ['keydown', final key]) => _key(RokuSimKeyAction.down, key),
      ('POST', ['keyup', final key]) => _key(RokuSimKeyAction.up, key),
      ('POST', ['launch', final id]) => _launch(
        id,
        request.uri.queryParameters,
      ),
      ('POST', ['input']) => const _Reply(200, ''),
      _ => const _Reply(404, ''),
    };
  }

  static _Reply _xml(String body) =>
      _Reply(200, body, contentType: 'text/xml; charset="utf-8"');

  _Reply _key(RokuSimKeyAction action, String raw) {
    if (raw.startsWith('Lit_') || raw.startsWith('lit_')) {
      final text = raw.substring(4);
      if (text.runes.length != 1) return const _Reply(400, '');
      _keyLog.add(RokuSimKeyEvent(action, 'Lit_$text'));
      if (action != RokuSimKeyAction.up) _typed.add(text.runes.single);
      return const _Reply(200, '');
    }
    final key = _canonicalKeys[raw.toLowerCase()];
    if (key == null) return const _Reply(400, '');
    _keyLog.add(RokuSimKeyEvent(action, key));
    if (action != RokuSimKeyAction.up) _applyKey(key);
    return const _Reply(200, '');
  }

  void _applyKey(String key) {
    switch (key) {
      case 'PowerOn':
        powerMode = RokuSimPowerMode.powerOn;
      case 'PowerOff' when device.isTv:
        _sleep();
      case 'Power' when device.isTv:
        if (powerMode == RokuSimPowerMode.ready) {
          powerMode = RokuSimPowerMode.powerOn;
        } else {
          _sleep();
        }
      case 'Home':
        activeAppId = null;
        playerState = RokuSimPlayerState.close;
      case 'Play':
        playerState = switch (playerState) {
          RokuSimPlayerState.play ||
          RokuSimPlayerState.buffer => RokuSimPlayerState.pause,
          RokuSimPlayerState.pause => RokuSimPlayerState.play,
          final other => other,
        };
      case 'VolumeUp':
        volume = (volume + 1).clamp(0, 100);
      case 'VolumeDown':
        volume = (volume - 1).clamp(0, 100);
      case 'VolumeMute':
        muted = !muted;
      case 'Backspace':
        if (_typed.isNotEmpty) _typed.removeLast();
      case 'InputTuner' when device.isTv:
        _foreground('tvinput.dtv');
      case 'InputAV1' when device.isTv:
        _foreground('tvinput.cvbs');
      case final k when k.startsWith('InputHDMI') && device.isTv:
        _foreground('tvinput.hdmi${k.substring(9)}');
    }
  }

  void _sleep() {
    powerMode = RokuSimPowerMode.ready;
    playerState = RokuSimPlayerState.close;
  }

  void _foreground(String appId) {
    activeAppId = appId;
    playerState = RokuSimPlayerState.close;
  }

  _Reply _launch(String id, Map<String, String> params) {
    final app = _app(id);
    if (app == null) return const _Reply(404, '');
    _launches.add(RokuSimLaunch(id, Map.unmodifiable(params)));
    activeAppId = id;
    if (params.containsKey('contentId') || params.containsKey('u')) {
      playerState = RokuSimPlayerState.play;
      playerPosition = Duration.zero;
      playerDuration = const Duration(minutes: 42);
    } else {
      playerState = RokuSimPlayerState.close;
    }
    return const _Reply(200, '');
  }

  static bool _hostIsIp(String? hostHeader) {
    if (hostHeader == null || hostHeader.isEmpty) return false;
    var h = hostHeader.trim();
    if (h.startsWith('[')) {
      final end = h.indexOf(']');
      if (end < 0) return false;
      h = h.substring(1, end);
    } else if (h.indexOf(':') == h.lastIndexOf(':') && h.contains(':')) {
      h = h.substring(0, h.indexOf(':'));
    }
    return InternetAddress.tryParse(h) != null;
  }

  // ------------------------------------------------------------------ SSDP

  void _answerSsdp(RawDatagramSocket socket) {
    final datagram = socket.receive();
    if (datagram == null) return;
    final text = utf8.decode(datagram.data, allowMalformed: true);
    final lines = text.split(RegExp(r'\r?\n'));
    if (!lines.first.toUpperCase().startsWith('M-SEARCH')) return;
    final headers = {
      for (final line in lines.skip(1))
        if (line.indexOf(':') case final i when i > 0)
          line.substring(0, i).trim().toLowerCase(): line
              .substring(i + 1)
              .trim(),
    };
    final st = headers['st']?.toLowerCase();
    if (st != 'roku:ecp' && st != 'ssdp:all') return;
    final location = Uri(scheme: 'http', host: host, port: port, path: '/');
    final reply = [
      'HTTP/1.1 200 OK',
      'Cache-Control: max-age=3600',
      'ST: roku:ecp',
      'USN: uuid:roku:ecp:${device.serialNumber}',
      'Ext: ',
      'Server: Roku/${device.softwareVersion} UPnP/1.0 '
          'Roku/${device.softwareVersion}',
      'LOCATION: $location',
      'device-group.roku.com: 1F4C2E7D9A3B5C6D7E8F',
      '',
      '',
    ].join('\r\n');
    socket.send(utf8.encode(reply), datagram.address, datagram.port);
    _ssdpReplies++;
  }
}

final class _Reply {
  const _Reply(this.status, this.body, {this.contentType = 'text/plain'})
    : bytes = null;

  _Reply.png(List<int> png)
    : status = 200,
      body = 'png',
      contentType = 'image/png',
      bytes = Uint8List.fromList(png);

  final int status;
  final String body;
  final String contentType;
  final Uint8List? bytes;
}

// A 1x1 transparent PNG, standing in for channel icons.
const List<int> _onePixelPng = [
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];

/// An answer the simulator holds back (see [RokuSimulator.holdNext]).
final class RokuSimGate {
  RokuSimGate._(this.method, this.path);

  /// The method it waits for.
  final String method;

  /// The exact path it waits for.
  final String path;

  final Completer<void> _reached = Completer();
  final Completer<void> _release = Completer();

  /// Completes once the request arrived and was handled; its answer is
  /// then held until [release].
  Future<void> get reached => _reached.future;

  /// Whether the request arrived.
  bool get isReached => _reached.isCompleted;

  /// Sends the held answer (at once if the request already arrived,
  /// otherwise as soon as it does).
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  bool _matches(HttpRequest request) =>
      !_reached.isCompleted &&
      request.method == method &&
      request.uri.path == path;

  Future<void> _hold() {
    _reached.complete();
    return _release.future;
  }
}
