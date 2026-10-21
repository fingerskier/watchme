import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:watchme_core/watchme_core.dart' show Endpoint;

import 'test_certificates.dart';

// A synthetic Fire TV remote-API receiver ("Lightning"). It is written from
// the community protocol notes, cross-checked against LibreControl/fire-tv
// (MIT: docs/protocol.md, tests/helpers/native-server.ts) and
// hms-homelab/hms-firetv (MIT: src/clients/LightningClient.cpp, README). No
// code was copied. It is NOT a capture of real device traffic: status codes
// and bodies for error cases the references do not document are invented and
// marked as such below.

/// The static API key every Fire TV remote-API request carries. A public
/// protocol identifier taken from the official app, not a secret.
const String fireTvSimulatorApiKey = '0987654321';

/// Body of the 400 answer for malformed requests. This text is what real
/// devices returned in the Home Assistant community thread "REST commands
/// for Fire TV".
const String fireTvBadArguments =
    '{"description":"Bad arguments supplied. Please check inputs."}';

/// Which certificate the simulator's HTTPS API presents.
///
/// Both are self-signed, TEST-ONLY certificates for `127.0.0.1`, `::1` and
/// `localhost`. Switching between them with
/// [FireTvSimulator.restartWithCertificate] simulates a device whose
/// certificate changed after pairing (trust-on-first-use pin mismatch).
enum FireTvSimulatorCertificate {
  /// The default identity.
  primary(primaryCertificatePem, primaryPrivateKeyPem),

  /// A second identity, for pin-mismatch tests.
  alternate(alternateCertificatePem, alternatePrivateKeyPem);

  const FireTvSimulatorCertificate(this.certificatePem, this.privateKeyPem);

  /// The certificate, PEM.
  final String certificatePem;

  /// The private key, PKCS#8 PEM. Test-only.
  final String privateKeyPem;

  /// The certificate, DER.
  Uint8List get der {
    final body = certificatePem
        .replaceAll(RegExp('-----[A-Z ]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    return base64.decode(body);
  }

  /// SHA-256 of [der], 64 lower-case hex digits: the value a TLS client
  /// records for trust-on-first-use pinning.
  String get sha256Fingerprint => sha256.convert(der).toString();

  SecurityContext _context() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

/// Which simulator server received a request.
enum FireTvSimServer {
  /// The plain-HTTP DIAL server (port name `dial`, default 8009).
  dial,

  /// The HTTPS remote API (port name `api`, default 8080).
  api,
}

/// One request the simulator received.
final class FireTvSimRequest {
  FireTvSimRequest._(
    this.server,
    this.method,
    this.uri,
    this.headers,
    this.body,
  );

  /// The server that received it.
  final FireTvSimServer server;

  /// Upper-case HTTP method.
  final String method;

  /// Request URI (path and query).
  final Uri uri;

  /// Request headers with lower-case names; repeated values joined by `, `.
  final Map<String, String> headers;

  /// The raw body as text (empty when there was none).
  final String body;

  /// The URI path.
  String get path => uri.path;

  /// The `action` query parameter, if any.
  String? get action => uri.queryParameters['action'];

  /// The header [name], case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  @override
  String toString() => 'FireTvSimRequest(${server.name} $method $uri)';
}

/// An app the simulator reports from `GET /v1/FireTV/appsV2`.
final class FireTvSimApp {
  /// Creates an app entry.
  const FireTvSimApp(
    this.appId,
    this.name, {
    this.iconUrl,
    this.isShortcut = false,
    this.isInstalled = true,
  });

  /// Android package name, e.g. `com.netflix.ninja`.
  final String appId;

  /// Display name.
  final String name;

  /// Icon art URL (`tvIconArt`).
  final String? iconUrl;

  /// Launcher shortcut tile rather than an installed package.
  final bool isShortcut;

  /// Whether the package is installed.
  final bool isInstalled;

  /// Whether `POST /v1/FireTV/app/<appId>` can start it.
  bool get launchable => isInstalled && !isShortcut;

  /// The appsV2 entry. Field names follow hms-firetv's AppSyncService.
  Map<String, Object?> toJson() => {
    'appId': appId,
    'name': name,
    if (iconUrl != null) 'tvIconArt': iconUrl,
    'isShortcutApp': isShortcut,
    'isInstalled': isInstalled,
  };
}

/// A Fire TV remote-API simulator on loopback: a DIAL server and an HTTPS
/// API on random ports.
///
/// The API port refuses connections while the simulated device is asleep,
/// as a real Fire TV's port 8080 does. A DIAL `POST /apps/FireTVRemote`
/// (Content-Type `text/plain`, empty body) wakes it and answers 201;
/// `POST /v1/FireTV?action=sleep` puts it back to sleep.
///
/// ```dart
/// final sim = await FireTvSimulator.start();
/// final endpoint = sim.endpoint; // 127.0.0.1 with 'dial' and 'api' ports
/// // ... wake, POST pin/display, read sim.displayedPin, POST pin/verify ...
/// await sim.close();
/// ```
///
/// Behaviour of the API (all bodies JSON):
/// * Every request needs `X-Api-Key: 0987654321` and a JSON Content-Type,
///   otherwise 400 with [fireTvBadArguments].
/// * `POST /v1/FireTV/pin/display {friendlyName}` shows a 4-digit PIN
///   ([displayedPin]) and answers `{"description":"OK"}`.
/// * `POST /v1/FireTV/pin/verify {pin}` answers `{"description":"<token>"}`
///   for the right PIN and `{"description":""}` for a wrong one; after
///   `maxPinAttempts` wrong PINs, or with no PIN on screen, it answers 400.
/// * Everything else needs a valid `X-Client-Token`, otherwise
///   `authFailureStatus` (401 by default) with `{"description":"authn
///   error"}` (synthetic body).
/// * Key and app-launch POSTs must have no body. A body that is not a
///   `{"keyActionType": "keyDown"|"keyUp"}` hold edge on a d-pad or select
///   action, including `{}`, answers 500.
class FireTvSimulator {
  FireTvSimulator._(
    this.host,
    this._dial,
    this.apiPort,
    this._certificate, {
    required this.fixedPin,
    required this.maxPinAttempts,
    required this.authFailureStatus,
    required List<FireTvSimApp> apps,
    required Map<String, String> status,
    required this._random,
  }) : apps = List.of(apps),
       status = Map.of(status) {
    _dial.listen(_handleDial);
  }

  /// Starts a simulator on [host] (loopback by default).
  ///
  /// [dialPort] and [apiPort] default to 0 (free ports); pass 8009 and 8080
  /// to stand in for a device a client reaches on the standard ports.
  /// [awake] starts it awake (API port listening). [pin] fixes the PIN shown
  /// by every `pin/display` (default: random per display). [seed] makes
  /// random PINs and tokens reproducible.
  static Future<FireTvSimulator> start({
    String host = '127.0.0.1',
    int dialPort = 0,
    int apiPort = 0,
    bool awake = false,
    String? pin,
    FireTvSimulatorCertificate certificate = FireTvSimulatorCertificate.primary,
    List<FireTvSimApp> apps = defaultApps,
    Map<String, String> status = defaultStatus,
    int maxPinAttempts = 3,
    int authFailureStatus = 401,
    int? seed,
  }) async {
    if (pin != null && !RegExp(r'^\d{4}$').hasMatch(pin)) {
      throw ArgumentError.value(pin, 'pin', 'must be four digits');
    }
    final dial = await HttpServer.bind(host, dialPort);
    // Reserve the API port by binding it once; a sleeping simulator then
    // closes it so connections are refused, and rebinds the same port on
    // wake.
    final HttpServer api;
    try {
      api = await HttpServer.bindSecure(host, apiPort, certificate._context());
    } on Object {
      await dial.close(force: true);
      rethrow;
    }
    final sim = FireTvSimulator._(
      host,
      dial,
      api.port,
      certificate,
      fixedPin: pin,
      maxPinAttempts: maxPinAttempts,
      authFailureStatus: authFailureStatus,
      apps: apps,
      status: status,
      random: seed == null ? Random.secure() : Random(seed),
    );
    if (awake) {
      sim._attachApi(api);
    } else {
      await api.close(force: true);
    }
    return sim;
  }

  /// Apps reported by default: two installed apps, one shortcut tile and
  /// one uninstalled entry.
  static const List<FireTvSimApp> defaultApps = [
    FireTvSimApp(
      'com.netflix.ninja',
      'Netflix',
      iconUrl: 'https://example.invalid/netflix.png',
    ),
    FireTvSimApp(
      'com.amazon.firebat',
      'Prime Video',
      iconUrl: 'https://example.invalid/prime.png',
    ),
    FireTvSimApp('com.amazon.shortcut.music', 'Music', isShortcut: true),
    FireTvSimApp('com.example.removed', 'Removed', isInstalled: false),
  ];

  /// `GET /v1/FireTV/status` by default (field names as validated by
  /// LibreControl; values synthetic).
  static const Map<String, String> defaultStatus = {
    'osVersion': 'simulated-fire-os-8',
    'platformType': 'android',
    'turnstileVersion': 'simulated-0.1',
  };

  /// The address both servers listen on.
  final String host;

  /// The HTTPS API port. Stable across sleep, wake and certificate restarts.
  final int apiPort;

  /// The fixed PIN, if one was given to [start].
  final String? fixedPin;

  /// Wrong PINs allowed per displayed PIN before it is withdrawn.
  final int maxPinAttempts;

  /// Status for a missing or revoked client token (401 or 403).
  int authFailureStatus;

  /// Apps reported by appsV2 and accepted by app launch. Mutable.
  final List<FireTvSimApp> apps;

  /// Body of `GET /v1/FireTV/status`. Mutable.
  final Map<String, String> status;

  final HttpServer _dial;
  final Random _random;
  HttpServer? _api;
  FireTvSimulatorCertificate _certificate;
  final List<FireTvSimRequest> _requests = [];
  final StreamController<FireTvSimRequest> _requestEvents =
      StreamController.broadcast(sync: true);
  final List<String> _effects = [];
  final List<String> _pinDisplayNames = [];
  final Set<String> _tokens = {};
  final List<_Fault> _faults = [];
  String? _displayedPin;
  int _wrongPins = 0;
  int _wakeCount = 0;
  bool _closed = false;

  /// The DIAL port.
  int get dialPort => _dial.port;

  /// The endpoint a driver uses: [host] with ports `dial` and `api`.
  Endpoint get endpoint =>
      Endpoint(host, ports: {'dial': dialPort, 'api': apiPort});

  /// Whether the API port is listening.
  bool get awake => _api != null;

  /// How many DIAL wakes were accepted.
  int get wakeCount => _wakeCount;

  /// The certificate the API presents (or will present once woken).
  FireTvSimulatorCertificate get certificate => _certificate;

  /// SHA-256 of the current certificate, lower-case hex.
  String get certificateSha256 => _certificate.sha256Fingerprint;

  /// The PIN currently shown on the simulated screen, or `null`.
  String? get displayedPin => _displayedPin;

  /// The `friendlyName` of every `pin/display` request, in order.
  List<String> get pinDisplayNames => List.unmodifiable(_pinDisplayNames);

  /// Client tokens that are currently accepted.
  Set<String> get validTokens => Set.unmodifiable(_tokens);

  /// Every request received, in order.
  List<FireTvSimRequest> get requests => List.unmodifiable(_requests);

  /// Requests the API server received.
  List<FireTvSimRequest> get apiRequests =>
      _requests.where((r) => r.server == FireTvSimServer.api).toList();

  /// Requests the DIAL server received.
  List<FireTvSimRequest> get dialRequests =>
      _requests.where((r) => r.server == FireTvSimServer.dial).toList();

  /// Every request as it arrives (broadcast).
  Stream<FireTvSimRequest> get onRequest => _requestEvents.stream;

  /// What the simulated device did, in order, e.g. `dpad_up`,
  /// `select:keyDown`, `text:abc`, `launch:com.netflix.ninja`,
  /// `media:play`, `scan:forward`, `sleep`, `wake`.
  List<String> get effects => List.unmodifiable(_effects);

  /// Whether the on-screen keyboard is open. Tests set it to allow text.
  bool keyboardOpen = false;

  /// Text typed into the on-screen keyboard.
  String typedText = '';

  /// The action currently held down by a `keyDown`, if any.
  String? heldAction;

  /// Whether media is playing (toggled by `media?action=play`).
  bool playing = false;

  /// Package of the app last launched, cleared by `home`.
  String? foregroundApp;

  /// Net volume steps sent over the simulated HDMI-CEC link.
  int volumeSteps = 0;

  /// Mute state toggled by `action=mute`.
  bool muted = false;

  /// The connected TV's power, toggled by `action=power` (CEC).
  bool displayPowered = true;

  /// Clears the request log and effects (state is kept).
  void clearLog() {
    _requests.clear();
    _effects.clear();
  }

  /// Revokes every issued client token: later calls get
  /// [authFailureStatus], as after a token reset on a real device.
  void revokeTokens() => _tokens.clear();

  /// Answers the next API or DIAL request matching [method] and [path]
  /// (exact path, query ignored) with [status] and [body] instead of the
  /// normal handling.
  void respondOnce(
    String method,
    String path,
    int status, {
    String body = '',
  }) => _faults.add(_Fault(method.toUpperCase(), path, status, body));

  /// Wakes the simulated device as a DIAL launch would (test control).
  Future<void> wake() async {
    if (_closed || _api != null) return;
    _attachApi(
      await HttpServer.bindSecure(host, apiPort, _certificate._context()),
    );
  }

  /// Puts the simulated device to sleep: the API port stops listening and
  /// open connections are dropped.
  Future<void> sleep() async {
    final api = _api;
    _api = null;
    _displayedPin = null;
    heldAction = null;
    await api?.close(force: true);
  }

  /// Switches the API to [certificate], restarting it on the same port if
  /// awake (a device whose certificate changed since pairing).
  Future<void> restartWithCertificate(
    FireTvSimulatorCertificate certificate,
  ) async {
    final wasAwake = awake;
    await sleep();
    _certificate = certificate;
    if (wasAwake) await wake();
  }

  /// Stops both servers.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await sleep();
    await _dial.close(force: true);
    await _requestEvents.close();
  }

  void _attachApi(HttpServer api) {
    _api = api;
    api.listen(_handleApi);
  }

  // ------------------------------------------------------------------ DIAL

  Future<void> _handleDial(HttpRequest request) async {
    final req = await _record(FireTvSimServer.dial, request);
    final res = request.response;
    try {
      final (status, body) = await _routeDial(req, request.headers);
      if (status == 201) {
        res.headers.set(
          HttpHeaders.locationHeader,
          'http://$host:$dialPort/apps/FireTVRemote/run',
        );
      } else if (status == 200 && body.startsWith('<?xml')) {
        res.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      }
      await _send(res, status, body);
    } catch (_) {
      await _safeClose(res);
    }
  }

  Future<_Reply> _routeDial(FireTvSimRequest req, HttpHeaders headers) async {
    if (_fault(req) case final fault?) return (fault.status, fault.body);
    if (req.path != '/apps/FireTVRemote') return (404, '');
    switch (req.method) {
      case 'POST':
        if (headers.contentType?.mimeType != 'text/plain' ||
            req.body.isNotEmpty) {
          return (400, '');
        }
        _wakeCount++;
        _effects.add('wake');
        await wake();
        return (201, '');
      case 'GET':
        // DIAL application status (synthetic; not observed on hardware).
        return (
          200,
          '<?xml version="1.0" encoding="UTF-8"?>'
              '<service xmlns="urn:dial-multiscreen-org:schemas:dial" '
              'dialVer="2.1"><name>FireTVRemote</name>'
              '<options allowStop="false"/>'
              '<state>${awake ? 'running' : 'stopped'}</state></service>',
        );
      default:
        return (405, '');
    }
  }

  // ------------------------------------------------------------------- API

  Future<void> _handleApi(HttpRequest request) async {
    final req = await _record(FireTvSimServer.api, request);
    final res = request.response;
    try {
      final (status, body) = _routeApi(req, request.headers);
      res.headers.contentType = ContentType.json;
      await _send(res, status, body);
      if (status == 200 && req.path == '/v1/FireTV' && req.action == 'sleep') {
        await sleep();
      }
    } catch (_) {
      await _safeClose(res);
    }
  }

  _Reply _routeApi(FireTvSimRequest req, HttpHeaders headers) {
    if (_fault(req) case final fault?) return (fault.status, fault.body);
    if (req.header('x-api-key') != fireTvSimulatorApiKey ||
        headers.contentType?.mimeType != 'application/json') {
      return (400, fireTvBadArguments);
    }
    final path = req.path;
    if (req.method == 'POST' && path == '/v1/FireTV/pin/display') {
      return _pinDisplay(req);
    }
    if (req.method == 'POST' && path == '/v1/FireTV/pin/verify') {
      return _pinVerify(req);
    }
    final token = req.header('x-client-token');
    if (token == null || !_tokens.contains(token)) {
      return (authFailureStatus, '{"description":"authn error"}');
    }
    return switch ((req.method, path)) {
      ('GET', '/v1/FireTV/status') => (200, jsonEncode(status)),
      ('GET', '/v1/FireTV/properties') => (
        200,
        jsonEncode({'volumeSupport': 'Supported', 'powerSupport': 'Supported'}),
      ),
      ('GET', '/v1/FireTV/keyboard') => (200, _keyboardState()),
      ('POST', '/v1/FireTV/keyboard') => _typeText(req),
      ('GET', '/v1/FireTV/appsV2') => (
        200,
        jsonEncode([for (final a in apps) a.toJson()]),
      ),
      ('POST', '/v1/FireTV') => _action(req),
      ('POST', '/v1/media') => _media(req),
      ('POST', _) when path.startsWith('/v1/FireTV/app/') => _launch(req),
      _ => (404, '{"description":"Not found"}'),
    };
  }

  _Reply _pinDisplay(FireTvSimRequest req) {
    final name = switch (_jsonBody(req)) {
      {'friendlyName': final String n} when n.isNotEmpty => n,
      _ => null,
    };
    if (name == null) return (400, fireTvBadArguments);
    _pinDisplayNames.add(name);
    _displayedPin =
        fixedPin ?? _random.nextInt(10000).toString().padLeft(4, '0');
    _wrongPins = 0;
    _effects.add('pin:display');
    return _ok;
  }

  _Reply _pinVerify(FireTvSimRequest req) {
    final pin = switch (_jsonBody(req)) {
      {'pin': final String p} => p,
      _ => null,
    };
    final shown = _displayedPin;
    if (pin == null || shown == null) return (400, fireTvBadArguments);
    if (pin != shown) {
      if (++_wrongPins >= maxPinAttempts) _displayedPin = null;
      _effects.add('pin:wrong');
      return (200, '{"description":""}');
    }
    _displayedPin = null;
    final token = List.generate(
      16,
      (_) => _alphabet[_random.nextInt(_alphabet.length)],
    ).join();
    _tokens.add(token);
    _effects.add('pin:paired');
    return (200, jsonEncode({'description': token}));
  }

  String _keyboardState() => jsonEncode({
    'state': keyboardOpen ? (typedText.isEmpty ? 'visible' : 'text') : 'hidden',
    'mode': keyboardOpen ? 'keyboard' : null,
    'text': keyboardOpen ? typedText : null,
  });

  _Reply _typeText(FireTvSimRequest req) {
    final text = switch (_jsonBody(req)) {
      {'text': final String t} => t,
      _ => null,
    };
    if (text == null || !keyboardOpen) return (400, fireTvBadArguments);
    typedText += text;
    _effects.add('text:$text');
    return _ok;
  }

  _Reply _action(FireTvSimRequest req) {
    final action = req.action;
    if (req.body.isNotEmpty) return _holdEdge(req, action);
    switch (action) {
      case 'dpad_up' || 'dpad_down' || 'dpad_left' || 'dpad_right':
      case 'select' || 'back' || 'menu':
        break;
      case 'home':
        foregroundApp = null;
        keyboardOpen = false;
      case 'sleep':
        break;
      case 'power':
        displayPowered = !displayPowered;
      case 'volume_up':
        volumeSteps++;
      case 'volume_down':
        volumeSteps--;
      case 'mute':
        muted = !muted;
      default:
        return (400, fireTvBadArguments);
    }
    _effects.add(action!);
    return _ok;
  }

  _Reply _holdEdge(FireTvSimRequest req, String? action) {
    // Only a well-formed hold edge may carry a body. Anything else,
    // including `{}`, is what makes real receivers answer HTTP 500.
    if (!_holdable.contains(action)) return _internalError;
    final edge = switch (_jsonBody(req)) {
      {'keyActionType': final String e} when e == 'keyDown' || e == 'keyUp' =>
        e,
      _ => null,
    };
    if (edge == null) return _internalError;
    if (edge == 'keyDown') {
      heldAction = action;
    } else if (heldAction == action) {
      heldAction = null;
    }
    _effects.add('$action:$edge');
    return _ok;
  }

  _Reply _media(FireTvSimRequest req) {
    switch (req.action) {
      case 'play':
        if (req.body.isNotEmpty) return _internalError;
        playing = !playing;
        _effects.add('media:play');
        return _ok;
      case 'scan':
        // Directions the references saw accepted: `forward` (LibreControl,
        // on hardware) and `back` (hms-firetv, from the official app's
        // request log). `backward` answered 400 on hardware (LibreControl),
        // so it is refused here too. The direction comes in the JSON body
        // (LibreControl) or the query (hms-firetv, no body); when both are
        // present they must agree.
        final query = req.uri.queryParameters['direction'];
        final String? direction;
        if (req.body.isEmpty) {
          direction = query;
        } else if (_jsonBody(req)
            case {
              'direction': final String d,
              'durationInSeconds': final String duration,
              'speed': '1',
            }
            when (num.tryParse(duration) ?? 0) > 0 &&
                (query == null || query == d)) {
          direction = d;
        } else {
          direction = null;
        }
        if (direction != 'forward' && direction != 'back') {
          return (400, fireTvBadArguments);
        }
        _effects.add('scan:$direction');
        return _ok;
      default:
        return (400, fireTvBadArguments);
    }
  }

  _Reply _launch(FireTvSimRequest req) {
    if (req.body.isNotEmpty) return _internalError;
    final package = req.path.substring('/v1/FireTV/app/'.length);
    final app = apps.where((a) => a.appId == package).firstOrNull;
    // Unknown packages: synthetic 400; real behaviour is undocumented.
    if (app == null || !app.launchable) return (400, fireTvBadArguments);
    foregroundApp = package;
    keyboardOpen = false;
    _effects.add('launch:$package');
    return _ok;
  }

  // --------------------------------------------------------------- helpers

  static const _Reply _ok = (200, '{"description":"OK"}');

  // Synthetic body; the references report only the status.
  static const _Reply _internalError = (
    500,
    '{"description":"Internal Server Error"}',
  );

  static const Set<String?> _holdable = {
    'dpad_up',
    'dpad_down',
    'dpad_left',
    'dpad_right',
    'select',
  };

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  Future<FireTvSimRequest> _record(
    FireTvSimServer server,
    HttpRequest request,
  ) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name] = values.join(', '),
    );
    final req = FireTvSimRequest._(
      server,
      request.method,
      request.uri,
      headers,
      body,
    );
    _requests.add(req);
    if (!_requestEvents.isClosed) _requestEvents.add(req);
    return req;
  }

  _Fault? _fault(FireTvSimRequest req) {
    final i = _faults.indexWhere(
      (f) => f.method == req.method && f.path == req.path,
    );
    return i < 0 ? null : _faults.removeAt(i);
  }

  static Object? _jsonBody(FireTvSimRequest req) {
    try {
      return jsonDecode(req.body);
    } on FormatException {
      return null;
    }
  }

  static Future<void> _send(HttpResponse res, int status, String body) async {
    res.statusCode = status;
    res.write(body);
    await res.close();
  }

  static Future<void> _safeClose(HttpResponse res) async {
    try {
      await res.close();
    } catch (_) {
      // The connection is already gone.
    }
  }
}

typedef _Reply = (int status, String body);

final class _Fault {
  _Fault(this.method, this.path, this.status, this.body);

  final String method;
  final String path;
  final int status;
  final String body;
}
