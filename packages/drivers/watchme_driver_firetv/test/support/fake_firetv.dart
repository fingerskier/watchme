import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

/// A scripted Fire TV on a [FakeNetworkStack]: asleep (API port refusing
/// connections) until a DIAL wake, PIN pairing, token checks, and the
/// "no body on key presses" rule. Its DIAL server answers the passive
/// application-status `GET` whether or not the API is up.
class FakeFireTv {
  FakeFireTv(
    this.net, {
    this.host = '10.0.0.7',
    this.dialPort = 8009,
    this.apiPort = 8080,
    this.pin = '1234',
    this.token = 'tok-abc123',
    this.wakeOnDial = true,
  }) : fingerprint = fakeFingerprint('firetv:$host') {
    net.serveTls(host, apiPort, certificateSha256: fingerprint);
    net.setUnreachable(host, port: apiPort);
    net.onHttp(
      'POST',
      '/apps/FireTVRemote',
      (call) {
        wakes++;
        if (wakeOnDial) wakeUp();
        return HttpResult(201);
      },
      host: host,
      port: dialPort,
    );
    net.onHttp(
      'GET',
      '/apps/FireTVRemote',
      (call) => HttpResult.text(
        200,
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<service xmlns="urn:dial-multiscreen-org:schemas:dial">'
        '<name>FireTVRemote</name>'
        '<state>${awake ? 'running' : 'stopped'}</state></service>',
        contentType: 'text/xml',
      ),
      host: host,
      port: dialPort,
    );
    net.onHttp('*', RegExp('^/v1/'), _api, host: host, port: apiPort);
  }

  final FakeNetworkStack net;
  final String host;
  final int dialPort;
  final int apiPort;
  final String pin;
  final String token;

  /// Whether a DIAL wake opens the API port.
  bool wakeOnDial;

  /// SHA-256 of the certificate the API presents.
  String fingerprint;

  int wakes = 0;
  bool tokenValid = true;
  bool keyboardOpen = true;
  final List<String> friendlyNames = [];

  /// Endpoint with the default ports (no overrides).
  Endpoint get endpoint => Endpoint(host);

  /// Whether the API port is open.
  bool awake = false;

  /// The API answers again (already awake, no DIAL needed).
  void wakeUp() {
    awake = true;
    net.setReachable(host, port: apiPort);
  }

  /// The device goes to sleep on its own: the API port closes.
  void sleep() {
    awake = false;
    net.setUnreachable(host, port: apiPort);
  }

  /// Presents a different certificate (device reset, or an impostor).
  void changeCertificate() {
    fingerprint = fakeFingerprint('impostor:$host');
    net.serveTls(host, apiPort, certificateSha256: fingerprint);
  }

  TokenCredential credential({String deviceId = 'dev-1'}) => TokenCredential(
    driverId: 'firetv.lightning',
    deviceId: deviceId,
    createdAt: DateTime.utc(2026),
    token: token,
    peerCertSha256: fingerprint,
  );

  /// Calls to the API port, in order.
  List<RecordedHttpCall> get apiLog => [
    for (final r in net.httpLog)
      if (r.call.uri.port == apiPort) r,
  ];

  HttpResult _api(HttpCall call) {
    if (call.header('X-Api-Key') != '0987654321' ||
        !(call.header('Content-Type') ?? '').startsWith('application/json')) {
      return HttpResult.json(400, {
        'description': 'Bad arguments supplied. Please check inputs.',
      });
    }
    final body = call.bodyText;
    final json = body == null || body.isEmpty ? null : jsonDecode(body);
    final path = call.uri.path;
    final action = call.uri.queryParameters['action'];
    switch ((call.method, path)) {
      case ('POST', '/v1/FireTV/pin/display'):
        friendlyNames.add((json as Map)['friendlyName'] as String);
        return HttpResult.json(200, {'description': 'OK'});
      case ('POST', '/v1/FireTV/pin/verify'):
        final ok = (json as Map)['pin'] == pin;
        return HttpResult.json(200, {'description': ok ? token : ''});
    }
    if (!tokenValid || call.header('X-Client-Token') != token) {
      return HttpResult.json(401, {'description': 'authn error'});
    }
    switch ((call.method, path)) {
      case ('GET', '/v1/FireTV/status'):
        return HttpResult.json(200, {
          'osVersion': 'fire-os-8',
          'platformType': 'android',
          'turnstileVersion': '0.1',
        });
      case ('GET', '/v1/FireTV/keyboard'):
        return HttpResult.json(200, {
          'state': keyboardOpen ? 'visible' : 'hidden',
          'mode': keyboardOpen ? 'keyboard' : null,
          'text': keyboardOpen ? '' : null,
        });
      case ('POST', '/v1/FireTV/keyboard'):
        return HttpResult.json(200, {'description': 'OK'});
      case ('GET', '/v1/FireTV/appsV2'):
        return HttpResult.json(200, [
          {
            'appId': 'com.netflix.ninja',
            'name': 'Netflix',
            'tvIconArt': 'https://example.invalid/n.png',
            'isShortcutApp': false,
            'isInstalled': true,
          },
          {'appId': 'com.amazon.tile', 'name': 'Tile', 'isShortcutApp': true},
          {'appId': 'com.gone', 'name': 'Gone', 'isInstalled': false},
          {'appId': 'org.noname'},
        ]);
      case ('POST', '/v1/FireTV' || '/v1/media'):
        final isHoldEdge =
            json is Map &&
            const {'keyDown', 'keyUp'}.contains(json['keyActionType']);
        final isScan = path == '/v1/media' && action == 'scan';
        if (json != null && !isHoldEdge && !isScan) {
          return HttpResult.json(500, {'description': 'Internal Server Error'});
        }
        if (action == 'sleep') sleep();
        return HttpResult.json(200, {'description': 'OK'});
      case ('POST', _) when path.startsWith('/v1/FireTV/app/'):
        if (json != null) return HttpResult(500);
        return HttpResult.json(200, {'description': 'OK'});
    }
    return HttpResult(404);
  }
}
