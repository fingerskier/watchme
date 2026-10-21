import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:watchme_testkit/firetv_simulator.dart';

/// A minimal dart:io client that trusts exactly one certificate fingerprint,
/// as a pinned watchme stack would.
class _Client {
  _Client(this.sim, {String? pin}) : _pin = pin ?? sim.certificateSha256 {
    _http.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == _pin;
  }

  final FireTvSimulator sim;
  final String _pin;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  Future<(int, String)> wake({String contentType = 'text/plain'}) async {
    final req = await _http.post(sim.host, sim.dialPort, '/apps/FireTVRemote');
    req.headers.set('content-type', contentType);
    req.contentLength = 0;
    return _finish(req);
  }

  Future<(int, String)> api(
    String method,
    String path, {
    Object? json,
    String? rawBody,
    String? token,
    String apiKey = '0987654321',
    String contentType = 'application/json; charset=utf-8',
  }) async {
    final uri = Uri.parse('https://${sim.host}:${sim.apiPort}$path');
    final req = await _http.openUrl(method, uri);
    req.headers.set('x-api-key', apiKey);
    req.headers.set('content-type', contentType);
    if (token != null) req.headers.set('x-client-token', token);
    final body = rawBody ?? (json == null ? '' : jsonEncode(json));
    final bytes = utf8.encode(body);
    req.contentLength = bytes.length;
    req.add(bytes);
    return _finish(req);
  }

  Future<(int, String)> _finish(HttpClientRequest req) async {
    final res = await req.close();
    return (res.statusCode, await utf8.decoder.bind(res).join());
  }

  /// Wakes the simulator and pairs, returning the token.
  Future<String> pair() async {
    await wake();
    await api('POST', '/v1/FireTV/pin/display', json: {'friendlyName': 'x'});
    final (_, body) = await api(
      'POST',
      '/v1/FireTV/pin/verify',
      json: {'pin': sim.displayedPin},
    );
    return (jsonDecode(body) as Map<String, Object?>)['description']! as String;
  }

  void close() => _http.close(force: true);
}

void main() {
  late FireTvSimulator sim;
  late _Client client;

  setUp(() async {
    sim = await FireTvSimulator.start(seed: 7);
    client = _Client(sim);
  });

  tearDown(() async {
    client.close();
    await sim.close();
  });

  test('API port refuses connections until the DIAL wake', () async {
    expect(sim.awake, isFalse);
    await expectLater(
      client.api('GET', '/v1/FireTV/status'),
      throwsA(isA<SocketException>()),
    );
    final (status, _) = await client.wake();
    expect(status, 201);
    expect(sim.awake, isTrue);
    expect(sim.wakeCount, 1);
    expect(sim.dialRequests.single.header('content-type'), 'text/plain');
    final (apiStatus, _) = await client.api('GET', '/v1/FireTV/status');
    expect(apiStatus, 401, reason: 'awake but no token');
  });

  test('DIAL wake needs text/plain and an empty body', () async {
    final (status, _) = await client.wake(contentType: 'application/json');
    expect(status, 400);
    expect(sim.awake, isFalse);
  });

  test('presents the selected test certificate', () async {
    await client.wake();
    final seen = <String>[];
    final http = HttpClient()
      ..badCertificateCallback = (cert, _, _) {
        seen.add(sha256.convert(cert.der).toString());
        return true;
      };
    addTearDown(() => http.close(force: true));
    final req = await http.getUrl(
      Uri.parse('https://${sim.host}:${sim.apiPort}/v1/FireTV/status'),
    );
    await (await req.close()).drain<void>();
    expect(seen, [FireTvSimulatorCertificate.primary.sha256Fingerprint]);
    expect(sim.certificateSha256, seen.single);
  });

  test('PIN pairing issues a token that authorises calls', () async {
    await client.wake();
    var (status, body) = await client.api(
      'POST',
      '/v1/FireTV/pin/display',
      json: {'friendlyName': 'watchme test'},
    );
    expect((status, body), (200, '{"description":"OK"}'));
    expect(sim.pinDisplayNames, ['watchme test']);
    final pin = sim.displayedPin!;
    expect(pin, matches(RegExp(r'^\d{4}$')));

    (status, body) = await client.api(
      'POST',
      '/v1/FireTV/pin/verify',
      json: {'pin': pin},
    );
    expect(status, 200);
    final token =
        (jsonDecode(body) as Map<String, Object?>)['description']! as String;
    expect(token, isNotEmpty);
    expect(sim.validTokens, {token});
    expect(sim.displayedPin, isNull);

    (status, body) = await client.api('GET', '/v1/FireTV/status', token: token);
    expect(status, 200);
    expect(jsonDecode(body), FireTvSimulator.defaultStatus);
  });

  test(
    'a wrong PIN answers an empty description until attempts run out',
    () async {
      await client.wake();
      await client.api(
        'POST',
        '/v1/FireTV/pin/display',
        json: {'friendlyName': 'x'},
      );
      final wrong = sim.displayedPin == '0000' ? '1111' : '0000';
      for (var i = 0; i < sim.maxPinAttempts; i++) {
        final reply = await client.api(
          'POST',
          '/v1/FireTV/pin/verify',
          json: {'pin': wrong},
        );
        expect(reply, (200, '{"description":""}'));
      }
      expect(sim.displayedPin, isNull);
      final (status, body) = await client.api(
        'POST',
        '/v1/FireTV/pin/verify',
        json: {'pin': wrong},
      );
      expect((status, body), (400, fireTvBadArguments));
    },
  );

  test('requests need the static API key and a JSON content type', () async {
    await client.wake();
    expect(
      await client.api(
        'POST',
        '/v1/FireTV/pin/display',
        json: {'friendlyName': 'x'},
        apiKey: 'nope',
      ),
      (400, fireTvBadArguments),
    );
    expect(
      await client.api(
        'POST',
        '/v1/FireTV/pin/display',
        json: {'friendlyName': 'x'},
        contentType: 'text/plain',
      ),
      (400, fireTvBadArguments),
    );
  });

  group('when paired', () {
    late String token;

    setUp(() async {
      token = await client.pair();
      sim.clearLog();
    });

    Future<(int, String)> post(String path, {String? rawBody, Object? json}) =>
        client.api('POST', path, token: token, rawBody: rawBody, json: json);

    test('body-less key presses succeed; a {} body answers 500', () async {
      for (final action in [
        'dpad_up',
        'dpad_down',
        'dpad_left',
        'dpad_right',
        'select',
        'home',
        'back',
        'menu',
      ]) {
        expect(await post('/v1/FireTV?action=$action'), (
          200,
          '{"description":"OK"}',
        ));
      }
      expect((await post('/v1/FireTV?action=home', rawBody: '{}')).$1, 500);
      expect((await post('/v1/FireTV?action=select', rawBody: '{}')).$1, 500);
      expect((await post('/v1/FireTV?action=bogus')).$1, 400);
      expect(sim.effects, [
        'dpad_up',
        'dpad_down',
        'dpad_left',
        'dpad_right',
        'select',
        'home',
        'back',
        'menu',
      ]);
    });

    test('keyDown and keyUp hold d-pad and select keys', () async {
      await post(
        '/v1/FireTV?action=dpad_down',
        json: {'keyActionType': 'keyDown'},
      );
      expect(sim.heldAction, 'dpad_down');
      await post(
        '/v1/FireTV?action=dpad_down',
        json: {'keyActionType': 'keyUp'},
      );
      expect(sim.heldAction, isNull);
      expect(sim.effects, ['dpad_down:keyDown', 'dpad_down:keyUp']);
      expect(
        (await post(
          '/v1/FireTV?action=home',
          json: {'keyActionType': 'keyDown'},
        )).$1,
        500,
      );
    });

    test('volume and mute actions are recorded', () async {
      await post('/v1/FireTV?action=volume_up');
      await post('/v1/FireTV?action=volume_up');
      await post('/v1/FireTV?action=volume_down');
      await post('/v1/FireTV?action=mute');
      expect(sim.volumeSteps, 1);
      expect(sim.muted, isTrue);
    });

    test('keyboard text needs the keyboard open', () async {
      expect((await post('/v1/FireTV/keyboard', json: {'text': 'hi'})).$1, 400);
      sim.keyboardOpen = true;
      var (status, body) = await client.api(
        'GET',
        '/v1/FireTV/keyboard',
        token: token,
      );
      expect(jsonDecode(body), {
        'state': 'visible',
        'mode': 'keyboard',
        'text': '',
      });
      (status, _) = await post('/v1/FireTV/keyboard', json: {'text': 'hi'});
      expect(status, 200);
      expect(sim.typedText, 'hi');
    });

    test('appsV2 lists apps and app launch starts installed ones', () async {
      final (status, body) = await client.api(
        'GET',
        '/v1/FireTV/appsV2',
        token: token,
      );
      expect(status, 200);
      final apps = jsonDecode(body) as List<Object?>;
      expect(apps, hasLength(FireTvSimulator.defaultApps.length));
      expect(apps.first, {
        'appId': 'com.netflix.ninja',
        'name': 'Netflix',
        'tvIconArt': 'https://example.invalid/netflix.png',
        'isShortcutApp': false,
        'isInstalled': true,
      });
      expect((await post('/v1/FireTV/app/com.netflix.ninja')).$1, 200);
      expect(sim.foregroundApp, 'com.netflix.ninja');
      expect(
        (await post('/v1/FireTV/app/com.netflix.ninja', rawBody: '{}')).$1,
        500,
      );
      expect((await post('/v1/FireTV/app/com.example.removed')).$1, 400);
    });

    test('media play toggles and scan validates its body', () async {
      expect((await post('/v1/media?action=play')).$1, 200);
      expect(sim.playing, isTrue);
      expect((await post('/v1/media?action=play', rawBody: '{}')).$1, 500);
      final scan = {
        'direction': 'forward',
        'durationInSeconds': '10',
        'speed': '1',
      };
      expect((await post('/v1/media?action=scan', json: scan)).$1, 200);
      expect((await post('/v1/media?action=scan', json: {})).$1, 400);
      // `backward` was refused on hardware; `back` is what the official app
      // sends, in the body or (hms-firetv) the query.
      expect(
        (await post(
          '/v1/media?action=scan',
          json: {...scan, 'direction': 'backward'},
        )).$1,
        400,
      );
      expect(
        (await post(
          '/v1/media?action=scan&direction=back',
          json: {...scan, 'direction': 'back'},
        )).$1,
        200,
      );
      expect((await post('/v1/media?action=scan&direction=back')).$1, 200);
      expect(
        (await post(
          '/v1/media?action=scan&direction=forward',
          json: {...scan, 'direction': 'back'},
        )).$1,
        400,
        reason: 'query and body disagree',
      );
      expect(sim.effects, [
        'media:play',
        'scan:forward',
        'scan:back',
        'scan:back',
      ]);
    });

    test(
      'sleep answers, then the API port closes until the next wake',
      () async {
        expect(await post('/v1/FireTV?action=sleep'), (
          200,
          '{"description":"OK"}',
        ));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sim.awake, isFalse);
        await expectLater(
          client.api('GET', '/v1/FireTV/status', token: token),
          throwsA(isA<SocketException>()),
        );
        await client.wake();
        expect(
          (await client.api('GET', '/v1/FireTV/status', token: token)).$1,
          200,
        );
      },
    );

    test('revokeTokens makes calls answer the auth failure status', () async {
      sim.revokeTokens();
      expect(await client.api('GET', '/v1/FireTV/status', token: token), (
        401,
        '{"description":"authn error"}',
      ));
      sim.authFailureStatus = 403;
      expect(
        (await client.api('GET', '/v1/FireTV/status', token: token)).$1,
        403,
      );
    });

    test(
      'restartWithCertificate swaps the certificate on the same port',
      () async {
        final port = sim.apiPort;
        await sim.restartWithCertificate(FireTvSimulatorCertificate.alternate);
        expect(sim.apiPort, port);
        expect(sim.awake, isTrue);
        expect(
          sim.certificateSha256,
          FireTvSimulatorCertificate.alternate.sha256Fingerprint,
        );
        // The old pin no longer matches...
        final pinned = _Client(
          sim,
          pin: FireTvSimulatorCertificate.primary.sha256Fingerprint,
        );
        addTearDown(pinned.close);
        await expectLater(
          pinned.api('GET', '/v1/FireTV/status', token: token),
          throwsA(isA<HandshakeException>()),
        );
        // ...and a client trusting the new certificate gets through.
        final fresh = _Client(sim);
        addTearDown(fresh.close);
        expect(
          (await fresh.api('GET', '/v1/FireTV/status', token: token)).$1,
          200,
        );
      },
    );

    test('respondOnce overrides one request', () async {
      sim.respondOnce('POST', '/v1/FireTV', 503, body: 'busy');
      expect(await post('/v1/FireTV?action=home'), (503, 'busy'));
      expect((await post('/v1/FireTV?action=home')).$1, 200);
    });

    test('logs requests with headers and bodies', () async {
      await post('/v1/FireTV?action=select');
      final req = sim.apiRequests.single;
      expect(req.method, 'POST');
      expect(req.action, 'select');
      expect(req.body, isEmpty);
      expect(req.header('X-Api-Key'), fireTvSimulatorApiKey);
      expect(req.header('x-client-token'), token);
    });
  });

  test('starts awake when asked and validates a fixed PIN', () async {
    final awake = await FireTvSimulator.start(awake: true, pin: '1234');
    addTearDown(awake.close);
    expect(awake.awake, isTrue);
    final c = _Client(awake);
    addTearDown(c.close);
    await c.api('POST', '/v1/FireTV/pin/display', json: {'friendlyName': 'x'});
    expect(awake.displayedPin, '1234');
    expect(
      () => FireTvSimulator.start(pin: '12'),
      throwsA(isA<ArgumentError>()),
    );
  });
}
