@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:xml/xml.dart';

typedef _Response = ({int status, String body, HttpHeaders headers});

void main() {
  late RokuSimulator sim;
  late HttpClient client;

  setUp(() {
    client = HttpClient();
    addTearDown(() => client.close(force: true));
  });

  Future<RokuSimulator> startSim([RokuSimulator? s]) async {
    final started = s ?? RokuSimulator();
    await started.start();
    addTearDown(started.stop);
    return started;
  }

  Future<_Response> call(
    String method,
    String path, {
    String? hostHeader,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://${sim.host}:${sim.port}$path'),
    );
    if (hostHeader != null) request.headers.set('host', hostHeader);
    if (method == 'POST') request.contentLength = 0;
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    return (status: response.statusCode, body: body, headers: response.headers);
  }

  Future<_Response> get(String path, {String? hostHeader}) =>
      call('GET', path, hostHeader: hostHeader);
  Future<_Response> post(String path) => call('POST', path);

  XmlElement root(_Response r) => XmlDocument.parse(r.body).rootElement;
  String? field(_Response r, String name) =>
      root(r).findElements(name).firstOrNull?.innerText;

  group('lifecycle', () {
    test('listens on a random loopback port and stops', () async {
      sim = await startSim();
      expect(sim.isRunning, isTrue);
      expect(sim.host, '127.0.0.1');
      expect(sim.port, greaterThan(0));
      expect(sim.baseUri.toString(), 'http://127.0.0.1:${sim.port}/');
      expect(sim.endpoint.port('ecp', 8060), sim.port);
      final port = sim.port;
      await sim.stop();
      expect(sim.isRunning, isFalse);
      await expectLater(
        client.getUrl(Uri.parse('http://127.0.0.1:$port/query/device-info')),
        throwsA(isA<SocketException>()),
      );
    });

    test('holdNext acts on the request at once but holds its answer', () async {
      sim = await startSim();
      final gate = sim.holdNext('POST', '/keypress/VolumeUp');
      var answered = false;
      final response = post('/keypress/VolumeUp').then((r) {
        answered = true;
        return r;
      });
      await gate.reached;
      expect(gate.isReached, isTrue);
      expect(sim.keyLog.single.key, 'VolumeUp');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(answered, isFalse);
      gate.release();
      expect((await response).status, 200);
      // Only the next matching request is held.
      expect((await post('/keypress/VolumeUp')).status, 200);
    });

    test('a graceful stop refuses new connections but sends a held '
        'answer', () async {
      sim = await startSim();
      final port = sim.port;
      final gate = sim.holdNext('POST', '/keypress/VolumeUp');
      final response = post('/keypress/VolumeUp');
      await gate.reached;
      final stopped = sim.stop(force: false);
      expect(sim.isRunning, isFalse);
      await sim.listenerClosed;
      await expectLater(
        client.getUrl(Uri.parse('http://127.0.0.1:$port/query/device-info')),
        throwsA(isA<SocketException>()),
      );
      gate.release();
      expect((await response).status, 200);
      await stopped;
    });

    test('a forced stop releases held answers', () async {
      sim = await startSim();
      final gate = sim.holdNext('POST', '/keypress/Home');
      final response = post('/keypress/Home')
          .then<Object?>((r) => r, onError: (Object e) => e);
      await gate.reached;
      await sim.stop();
      // The connection was dropped; the call ends either way.
      await response;
    });

    test('can serve on IPv6 loopback', () async {
      final s = RokuSimulator();
      try {
        await s.start(address: InternetAddress.loopbackIPv6);
      } on SocketException {
        markTestSkipped('IPv6 loopback unavailable');
        return;
      }
      addTearDown(s.stop);
      sim = s;
      expect(sim.host, '::1');
      final r = await client
          .getUrl(Uri.parse('http://[::1]:${sim.port}/query/device-info'))
          .then((req) => req.close());
      expect(r.statusCode, 200);
      await r.drain<void>();
    });
  });

  group('queries', () {
    setUp(() async => sim = await startSim());

    test('device-info describes the device', () async {
      final r = await get('/query/device-info');
      expect(r.status, 200);
      expect(r.headers.contentType?.mimeType, 'text/xml');
      expect(r.headers.value('server'), startsWith('Roku/14.1.4'));
      expect(root(r).name.local, 'device-info');
      expect(field(r, 'serial-number'), 'X01900SIM001');
      expect(field(r, 'is-tv'), 'true');
      expect(field(r, 'power-mode'), 'PowerOn');
      expect(field(r, 'wifi-mac'), '02:00:5e:00:00:01');
      expect(field(r, 'ecp-setting-mode'), isNull);
    });

    test('device-info follows the configured device and mode', () async {
      await sim.stop();
      sim = await startSim(
        RokuSimulator(
          device: const RokuSimDevice(reportEcpSettingMode: true),
          controlMode: RokuControlMode.limited,
        ),
      );
      expect(
        field(await get('/query/device-info'), 'ecp-setting-mode'),
        'limited',
      );
      await sim.stop();
      sim = await startSim(RokuSimulator(device: RokuSimDevice.player));
      final r = await get('/query/device-info');
      expect(field(r, 'is-tv'), 'false');
      expect(field(r, 'tuner-type'), isNull);
      expect(field(r, 'supports-tv-power-control'), 'true');
    });

    test('root description advertises ECP and DIAL', () async {
      final r = await get('/');
      expect(r.status, 200);
      final xml = root(r);
      expect(
        xml.findAllElements('deviceType').single.innerText,
        'urn:roku-com:device:player:1-0',
      );
      expect(
        xml.findAllElements('serviceType').map((e) => e.innerText),
        contains('urn:dial-multiscreen-org:service:dial:1'),
      );
      expect(
        xml.findAllElements('serialNumber').single.innerText,
        'X01900SIM001',
      );
    });

    test('apps, active app and media player', () async {
      final apps = root(await get('/query/apps')).findElements('app');
      expect(apps.map((a) => a.getAttribute('id')), contains('tvinput.hdmi1'));
      expect(
        apps.firstWhere((a) => a.getAttribute('id') == '12').innerText,
        'Netflix',
      );

      final home = root(await get('/query/active-app'));
      expect(home.findElements('app').single.innerText, 'Roku');
      expect(home.findElements('app').single.getAttribute('id'), isNull);

      expect(
        root(await get('/query/media-player')).getAttribute('state'),
        'close',
      );

      sim.setPlaying(
        '12',
        position: const Duration(seconds: 12),
        duration: const Duration(minutes: 30),
      );
      final active = root(await get('/query/active-app'));
      expect(active.findElements('app').single.getAttribute('id'), '12');
      final player = root(await get('/query/media-player'));
      expect(player.getAttribute('state'), 'play');
      expect(player.findElements('plugin').single.getAttribute('id'), '12');
      expect(player.findElements('position').single.innerText, '12000 ms');
      expect(player.findElements('duration').single.innerText, '1800000 ms');
    });

    test('icons for installed apps only', () async {
      final r = await client
          .getUrl(Uri.parse('${sim.baseUri}query/icon/12'))
          .then((req) => req.close());
      expect(r.statusCode, 200);
      expect(r.headers.contentType?.mimeType, 'image/png');
      await r.drain<void>();
      expect((await get('/query/icon/nope')).status, 404);
    });

    test('unknown paths are 404', () async {
      expect((await get('/query/nothing')).status, 404);
      expect((await post('/search/browse')).status, 404);
      expect((await get('/keypress/Home')).status, 404);
    });
  });

  group('keys', () {
    setUp(() async => sim = await startSim());

    test('presses are logged and change state', () async {
      expect((await post('/keypress/VolumeUp')).status, 200);
      expect((await post('/keypress/volumeup')).status, 200);
      expect((await post('/keypress/VolumeMute')).status, 200);
      expect(sim.volume, 22);
      expect(sim.muted, isTrue);
      expect(sim.keyLog, const [
        RokuSimKeyEvent(RokuSimKeyAction.press, 'VolumeUp'),
        RokuSimKeyEvent(RokuSimKeyAction.press, 'VolumeUp'),
        RokuSimKeyEvent(RokuSimKeyAction.press, 'VolumeMute'),
      ]);
    });

    test('keydown and keyup are logged separately', () async {
      await post('/keydown/Right');
      await post('/keyup/Right');
      expect(sim.keyLog.map((e) => '$e'), ['down Right', 'up Right']);
    });

    test('unknown keys are 400 and not logged', () async {
      expect((await post('/keypress/Teleport')).status, 400);
      expect(sim.keyLog, isEmpty);
    });

    test('Lit_ text, URL-decoded, with Backspace', () async {
      for (final key in [
        'Lit_h',
        'Lit_%20',
        'Lit_%E2%82%AC',
        'Lit_%2F',
        'Lit_x',
        'Backspace',
      ]) {
        expect((await post('/keypress/$key')).status, 200, reason: key);
      }
      expect(sim.typedText, 'h €/');
      expect(sim.keyLog[2].key, 'Lit_€');
      expect((await post('/keypress/Lit_ab')).status, 400);
    });

    test('Home, inputs, Play and power keys', () async {
      sim.setPlaying('12');
      await post('/keypress/Play');
      expect(sim.playerState, RokuSimPlayerState.pause);
      await post('/keypress/Play');
      expect(sim.playerState, RokuSimPlayerState.play);
      await post('/keypress/Home');
      expect(sim.activeAppId, isNull);
      await post('/keypress/InputHDMI2');
      expect(sim.activeAppId, 'tvinput.hdmi2');
      await post('/keypress/InputTuner');
      expect(sim.activeAppId, 'tvinput.dtv');
      await post('/keypress/PowerOff');
      expect(sim.powerMode, RokuSimPowerMode.ready);
      await post('/keypress/PowerOn');
      expect(sim.powerMode, RokuSimPowerMode.powerOn);
    });

    test('launch records params and changes the foreground app', () async {
      final r = await post('/launch/12?contentId=80057281&mediaType=movie');
      expect(r.status, 200);
      expect(sim.launches.single.appId, '12');
      expect(sim.launches.single.params, {
        'contentId': '80057281',
        'mediaType': 'movie',
      });
      expect(sim.activeAppId, '12');
      expect(sim.playerState, RokuSimPlayerState.play);
      expect((await post('/launch/999999')).status, 404);
      expect(sim.launches, hasLength(1));
    });

    test('clearLogs', () async {
      await post('/keypress/Lit_a');
      sim.clearLogs();
      expect(sim.keyLog, isEmpty);
      expect(sim.requests, isEmpty);
      expect(sim.typedText, isEmpty);
    });
  });

  group('access rules', () {
    test('a host-name Host header is refused with an empty 403', () async {
      sim = await startSim();
      final named = await get(
        '/query/device-info',
        hostHeader: 'roku.local:${sim.port}',
      );
      expect(named.status, 403);
      expect(named.body, isEmpty);
      final ip = await get(
        '/query/device-info',
        hostHeader: '127.0.0.1:${sim.port}',
      );
      expect(ip.status, 200);
      expect(sim.requests.map((r) => r.hostHeader), [
        'roku.local:${sim.port}',
        '127.0.0.1:${sim.port}',
      ]);
      expect(sim.requests.map((r) => r.status), [403, 200]);

      sim.enforceIpHost = false;
      expect(
        (await get(
          '/query/device-info',
          hostHeader: 'roku.local:${sim.port}',
        )).status,
        200,
      );
    });

    test('an IPv6 literal Host is accepted', () async {
      sim = await startSim();
      expect(
        (await get(
          '/query/device-info',
          hostHeader: '[::1]:${sim.port}',
        )).status,
        200,
      );
    });

    test(
      'Limited mode refuses the gated endpoints with Roku\'s body',
      () async {
        sim = await startSim(
          RokuSimulator(controlMode: RokuControlMode.limited),
        );
        for (final (method, path) in const [
          ('POST', '/keypress/Home'),
          ('POST', '/keydown/Up'),
          ('POST', '/keyup/Up'),
          ('POST', '/keypress/Lit_a'),
          ('GET', '/query/apps'),
          ('GET', '/query/media-player'),
          ('GET', '/query/icon/12'),
          ('POST', '/input?foo=bar'),
        ]) {
          final r = await call(method, path);
          expect(r.status, 403, reason: path);
          expect(r.body, RokuSimulator.limitedModeBody, reason: path);
        }
        expect((await get('/query/device-info')).status, 200);
        expect((await get('/query/active-app')).status, 200);
        expect((await post('/launch/12')).status, 200);
        expect(sim.keyLog, isEmpty);

        sim.limitedAllowsLaunch = false;
        expect((await post('/launch/12')).body, RokuSimulator.limitedModeBody);

        sim.controlMode = RokuControlMode.enabled;
        expect((await post('/keypress/Home')).status, 200);
      },
    );

    test('disabled refuses everything', () async {
      sim = await startSim(
        RokuSimulator(controlMode: RokuControlMode.disabled),
      );
      for (final (method, path) in const [
        ('GET', '/query/device-info'),
        ('GET', '/query/active-app'),
        ('POST', '/keypress/Home'),
        ('POST', '/launch/12'),
      ]) {
        final r = await call(method, path);
        expect(r.status, 403, reason: path);
        expect(r.body, RokuSimulator.disabledBody, reason: path);
      }
    });

    test('standby answers device-info and PowerOn only', () async {
      sim = await startSim(RokuSimulator(powerMode: RokuSimPowerMode.ready));
      final info = await get('/query/device-info');
      expect(info.status, 200);
      expect(field(info, 'power-mode'), 'Ready');
      expect((await get('/query/active-app')).status, 403);
      expect((await post('/keypress/Home')).status, 403);
      expect((await post('/keypress/PowerOn')).status, 200);
      expect(sim.powerMode, RokuSimPowerMode.powerOn);
      expect((await post('/keypress/Home')).status, 200);
    });

    test(
      'a TV that refuses PowerOn in standby answers only device-info',
      () async {
        sim = await startSim(
          RokuSimulator(
            powerMode: RokuSimPowerMode.ready,
            standbyAcceptsPowerOn: false,
          ),
        );
        expect((await get('/query/device-info')).status, 200);
        expect((await post('/keypress/PowerOn')).status, 403);
        expect((await post('/keypress/Power')).status, 403);
        expect(sim.powerMode, RokuSimPowerMode.ready);
      },
    );

    test('latency delays answers', () async {
      sim = await startSim(
        RokuSimulator(latency: const Duration(milliseconds: 150)),
      );
      final watch = Stopwatch()..start();
      await get('/query/device-info');
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 140)),
      );
    });
  });

  group('SSDP', () {
    Future<List<String>> search(String st, {required int port}) async {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(socket.close);
      final replies = <String>[];
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = socket.receive();
        if (d != null) replies.add(utf8.decode(d.data));
      });
      addTearDown(sub.cancel);
      socket.send(
        utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'Host: 239.255.255.250:1900\r\n'
          'Man: "ssdp:discover"\r\n'
          'ST: $st\r\n'
          'MX: 1\r\n\r\n',
        ),
        InternetAddress.loopbackIPv4,
        port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return replies;
    }

    test('answers M-SEARCH for roku:ecp with a LOCATION', () async {
      sim = RokuSimulator();
      await sim.start(ssdp: true);
      addTearDown(sim.stop);
      expect(sim.ssdpPort, isNotNull);
      final reply = (await search('roku:ecp', port: sim.ssdpPort!)).single;
      expect(reply, startsWith('HTTP/1.1 200 OK\r\n'));
      expect(reply, contains('ST: roku:ecp\r\n'));
      expect(reply, contains('USN: uuid:roku:ecp:X01900SIM001\r\n'));
      expect(reply, contains('LOCATION: http://127.0.0.1:${sim.port}/\r\n'));
      expect(reply, endsWith('\r\n\r\n'));
      expect(sim.ssdpReplies, 1);

      expect(await search('ssdp:all', port: sim.ssdpPort!), hasLength(1));
      expect(
        await search(
          'urn:dial-multiscreen-org:service:dial:1',
          port: sim.ssdpPort!,
        ),
        isEmpty,
      );
    });

    test('is off unless asked for', () async {
      sim = await startSim();
      expect(sim.ssdpPort, isNull);
    });
  });
}
