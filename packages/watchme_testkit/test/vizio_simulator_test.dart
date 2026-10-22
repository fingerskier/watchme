@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:watchme_testkit/vizio_simulator.dart';

/// One answer: status, the body text and, when it is JSON, the body with
/// every key upper-cased (the simulator spells keys either way).
typedef _Answer = ({int status, String text, Object? json});

/// A minimal dart:io client that trusts exactly one certificate
/// fingerprint, as a pinned watchme stack would.
class _Client {
  _Client(this.sim, {String? pin}) : _pin = pin ?? sim.certificateSha256 {
    _http.badCertificateCallback = (cert, host, port) =>
        sha256.convert(cert.der).toString() == _pin;
  }

  final VizioSimulator sim;
  final String _pin;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 2);

  /// The AUTH token sent with every request, once set.
  String? token;

  Future<_Answer> get(String path, {int? port}) =>
      send('GET', path, port: port);

  Future<_Answer> put(String path, Object json) =>
      send('PUT', path, body: jsonEncode(json));

  Future<_Answer> send(
    String method,
    String path, {
    String? body,
    int? port,
    String? auth,
  }) async {
    final uri = Uri.parse('https://${sim.host}:${port ?? sim.activePort}$path');
    final req = await _http.openUrl(method, uri);
    // A fresh connection each time, so a closed port shows as refused.
    req.persistentConnection = false;
    final tokenValue = auth ?? token;
    if (tokenValue != null) req.headers.set('AUTH', tokenValue);
    if (body != null) req.headers.set('content-type', 'application/json');
    final bytes = utf8.encode(body ?? '');
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await utf8.decoder.bind(res).join();
    Object? json;
    try {
      json = _upper(jsonDecode(text));
    } on FormatException {
      json = null;
    }
    return (status: res.statusCode, text: text, json: json);
  }

  static Object? _upper(Object? json) => switch (json) {
    final Map<String, Object?> m => {
      for (final MapEntry(:key, :value) in m.entries)
        key.toUpperCase(): _upper(value),
    },
    final List<Object?> l => [for (final v in l) _upper(v)],
    _ => json,
  };

  /// Pairs as [deviceId] and keeps the token.
  Future<String> pair({String deviceId = 'ctl-1'}) async {
    final start = await put('/pairing/start', {
      'DEVICE_ID': deviceId,
      'DEVICE_NAME': 'test',
    });
    final req = _item(start)['PAIRING_REQ_TOKEN']! as int;
    final paired = await put('/pairing/pair', {
      'DEVICE_ID': deviceId,
      'CHALLENGE_TYPE': 1,
      'RESPONSE_VALUE': sim.displayedPin,
      'PAIRING_REQ_TOKEN': req,
    });
    return token = _item(paired)['AUTH_TOKEN']! as String;
  }

  void close() => _http.close(force: true);
}

String? _result(_Answer a) => switch (a.json) {
  {'STATUS': {'RESULT': final String r}} => r,
  _ => null,
};

Map<String, Object?> _item(_Answer a) =>
    (a.json! as Map<String, Object?>)['ITEM']! as Map<String, Object?>;

Map<String, Object?> _firstItem(_Answer a) =>
    ((a.json! as Map<String, Object?>)['ITEMS']! as List<Object?>).first!
        as Map<String, Object?>;

const _volume = '/menu_native/dynamic/tv_settings/audio/volume';
const _mute = '/menu_native/dynamic/tv_settings/audio/mute';
const _currentInput = '/menu_native/dynamic/tv_settings/devices/current_input';
const _blank = '/menu_native/dynamic/tv_settings/system/timers/blank_screen';

Map<String, Object?> _keys(List<(int, int)> keys) => {
  'KEYLIST': [
    for (final (cs, c) in keys)
      {'CODESET': cs, 'CODE': c, 'ACTION': 'KEYPRESS'},
  ],
};

void main() {
  late VizioSimulator sim;
  late _Client client;

  setUp(() async {
    sim = await VizioSimulator.start(pin: '1234', seed: 7);
    client = _Client(sim);
  });

  tearDown(() async {
    client.close();
    await sim.close();
  });

  group('transport', () {
    test(
      'serves HTTPS with the test certificate on the api port only',
      () async {
        final info = await client.get('/state/device/deviceinfo');
        expect(info.status, 200);
        expect(sim.activePort, sim.apiPort);
        await expectLater(
          client.get('/state/device/deviceinfo', port: sim.legacyPort),
          throwsA(isA<SocketException>()),
        );
        expect(sim.endpoint.ports, {
          'smartcast': sim.apiPort,
          'smartcastLegacy': sim.legacyPort,
        });
      },
    );

    test('pre-4.0 firmware answers on the legacy port only', () async {
      final legacy = await VizioSimulator.start(servesLegacyPort: true);
      addTearDown(legacy.close);
      final c = _Client(legacy);
      addTearDown(c.close);
      expect(legacy.activePort, legacy.legacyPort);
      expect((await c.get('/state/device/deviceinfo')).status, 200);
      await expectLater(
        c.get('/state/device/deviceinfo', port: legacy.apiPort),
        throwsA(isA<SocketException>()),
      );
    });

    test('a client pinning another certificate fails the handshake', () async {
      final wrong = _Client(sim, pin: 'f' * 64);
      addTearDown(wrong.close);
      await expectLater(
        wrong.get('/state/device/deviceinfo'),
        throwsA(isA<HandshakeException>()),
      );
      await sim.restartWithCertificate(VizioSimulatorCertificate.alternate);
      await expectLater(
        client.get('/state/device/deviceinfo'),
        throwsA(isA<HandshakeException>()),
      );
    });

    test('keys come in alternating case across answers', () async {
      final first = await client.get('/state/device/deviceinfo');
      final second = await client.get('/state/device/deviceinfo');
      expect(first.text, contains('"STATUS"'));
      expect(second.text, contains('"status"'));
      expect(second.text, contains('"settings_root"'));
      // Values are not re-cased.
      expect(second.text, contains('"SUCCESS"'));
    });

    test('an unknown path is HTTP 500, an unknown settings leaf '
        'URI_NOT_FOUND', () async {
      await client.pair();
      final unknown = await client.get('/nope');
      expect(unknown.status, 500);
      expect(unknown.text, 'Unhandled Exception');
      final leaf = await client.get('/menu_native/dynamic/tv_settings/nope');
      expect(leaf.status, 200);
      expect(_result(leaf), 'URI_NOT_FOUND');
    });

    test('records requests and the most concurrent ones', () async {
      await Future.wait([
        for (var i = 0; i < 4; i++) client.get('/state/device/deviceinfo'),
      ]);
      expect(sim.requests, hasLength(4));
      expect(sim.maxConcurrentRequests, greaterThanOrEqualTo(1));
      sim.clearLog();
      await client.get('/state/device/deviceinfo');
      expect(sim.maxConcurrentRequests, 1);
    });
  });

  group('deviceinfo', () {
    test('needs no token and describes the TV', () async {
      final info = await client.get('/state/device/deviceinfo');
      final value = _firstItem(info)['VALUE']! as Map<String, Object?>;
      expect(value['SETTINGS_ROOT'], 'tv_settings');
      expect(value['SYSTEM_INFO'], containsPair('MODEL_NAME', 'V505-J09'));
      expect(value['SYSTEM_INFO'], containsPair('SERIAL_NUMBER', isNotEmpty));
      expect(value['CAST_NAME'], 'Living Room TV');
      expect(value['SCPL_CAPABILITIES'], isEmpty);
    });

    test('mDNS TXT carries a room name, the REST port and the MAC', () {
      final txt = sim.mdnsTxt;
      expect(txt['name'], 'Living Room');
      expect(txt['hsp'], '${sim.activePort}');
      expect(txt['hp'], '7346');
      expect(txt['wifi'], 'f04fe02d6e20');
      expect(sim.mdnsHit.serviceType, '_viziocast._tcp');
      expect(sim.mdnsHit.attributes['mdns.service'], '_viziocast._tcp');
    });
  });

  group('auth', () {
    test('everything but deviceinfo and pairing is a raw 403 without a '
        'token, power_mode included', () async {
      for (final path in [
        '/state/device/power_mode',
        _volume,
        '/app/current',
      ]) {
        final a = await client.get(path);
        expect(a.status, 403, reason: path);
        expect(a.text, isEmpty, reason: path);
      }
      final keys = await client.put('/key_command/', _keys([(5, 1)]));
      expect(keys.status, 403);
      expect(sim.keyPresses, isEmpty);
      final wrong = await client.send(
        'GET',
        '/state/device/power_mode',
        auth: 'not-a-token',
      );
      expect(wrong.status, 403);
    });
  });

  group('pairing', () {
    Future<_Answer> start([String id = 'ctl-1']) =>
        client.put('/pairing/start', {'DEVICE_ID': id, 'DEVICE_NAME': 'test'});

    Future<_Answer> pairWith(String pin, int req, {String id = 'ctl-1'}) =>
        client.put('/pairing/pair', {
          'DEVICE_ID': id,
          'CHALLENGE_TYPE': 1,
          'RESPONSE_VALUE': pin,
          'PAIRING_REQ_TOKEN': req,
        });

    test('start shows a PIN and answers the challenge', () async {
      final a = await start();
      expect(_result(a), 'SUCCESS');
      expect(_item(a)['CHALLENGE_TYPE'], 1);
      expect(_item(a)['PAIRING_REQ_TOKEN'], isA<int>());
      expect(sim.displayedPin, '1234');
      expect(sim.pairingNames, ['test']);
    });

    test('the right PIN answers a token that unlocks the API', () async {
      final token = await client.pair();
      expect(sim.validTokens, {token});
      expect(sim.displayedPin, isNull);
      final power = await client.get('/state/device/power_mode');
      expect(power.status, 200);
      expect(_firstItem(power)['VALUE'], 1);
    });

    test('a second start while a PIN is shown is BLOCKED', () async {
      await start();
      expect(_result(await start('ctl-2')), 'BLOCKED');
    });

    test('wrong PINs are denied, the last one locks until cancel', () async {
      final req = _item(await start())['PAIRING_REQ_TOKEN']! as int;
      expect(_result(await pairWith('0000', req)), 'PAIRING_DENIED');
      expect(_result(await pairWith('0001', req)), 'PAIRING_DENIED');
      expect(_result(await pairWith('0002', req)), 'MAX_CHALLENGES_EXCEEDED');
      expect(sim.pairingLocked, isTrue);
      // Locked: even the right PIN is refused now.
      expect(_result(await pairWith('1234', req)), 'MAX_CHALLENGES_EXCEEDED');
      final cancel = await client.put('/pairing/cancel', {
        'DEVICE_ID': 'ctl-1',
        'DEVICE_NAME': 'test',
      });
      expect(_result(cancel), 'SUCCESS');
      expect(sim.cancelCount, 1);
      expect(sim.displayedPin, isNull);
      expect(_result(await start()), 'SUCCESS');
    });

    test('a malformed PIN is VALUE_OUT_OF_RANGE', () async {
      final req = _item(await start())['PAIRING_REQ_TOKEN']! as int;
      expect(_result(await pairWith('12', req)), 'VALUE_OUT_OF_RANGE');
    });

    test('a wrong or expired challenge is CHALLENGE_INCORRECT', () async {
      final req = _item(await start())['PAIRING_REQ_TOKEN']! as int;
      expect(_result(await pairWith('1234', req + 1)), 'CHALLENGE_INCORRECT');
      expect(
        _result(await pairWith('1234', req, id: 'ctl-2')),
        'CHALLENGE_INCORRECT',
      );
      sim.expirePin();
      expect(_result(await pairWith('1234', req)), 'CHALLENGE_INCORRECT');
    });

    test(
      'pairing again with the same DEVICE_ID revokes the old token',
      () async {
        final first = await client.pair();
        final second = await client.pair();
        expect(second, isNot(first));
        expect(sim.validTokens, {second});
        final old = await client.send(
          'GET',
          '/state/device/power_mode',
          auth: first,
        );
        expect(old.status, 403);
        // Another controller id keeps its own token.
        final other = await client.pair(deviceId: 'ctl-2');
        expect(sim.validTokens, {second, other});
      },
    );

    test('a full pairing table refuses new controllers', () async {
      final full = await VizioSimulator.start(maxPairedDevices: 1);
      addTearDown(full.close);
      final c = _Client(full);
      addTearDown(c.close);
      await c.pair(deviceId: 'a');
      final refused = await c.put('/pairing/start', {
        'DEVICE_ID': 'b',
        'DEVICE_NAME': 'x',
      });
      expect(_result(refused), 'TOO_MANY_PAIRED_DEVICES');
    });

    test('malformed bodies are INVALID_PARAMETER', () async {
      expect(
        _result(await client.put('/pairing/start', {'x': 1})),
        'INVALID_PARAMETER',
      );
      expect(
        _result(await client.put('/pairing/pair', {'x': 1})),
        'INVALID_PARAMETER',
      );
    });
  });

  group('keys', () {
    setUp(() => client.pair());

    test('a KEYLIST is applied in order in one request', () async {
      final a = await client.put(
        '/key_command/',
        _keys([(5, 1), (5, 1), (5, 1), (0, 72), (0, 105)]),
      );
      expect(_result(a), 'SUCCESS');
      expect(sim.volume, 18);
      expect(sim.typedText, 'Hi');
      expect(sim.keyPresses, [(5, 1), (5, 1), (5, 1), (0, 72), (0, 105)]);
    });

    test('discrete power keys, and the toggle is recorded', () async {
      await client.put('/key_command/', _keys([(11, 0)]));
      expect(sim.power, VizioSimPower.standby);
      await client.put('/key_command/', _keys([(11, 0)]));
      expect(sim.power, VizioSimPower.standby);
      await client.put('/key_command/', _keys([(11, 1)]));
      expect(sim.power, VizioSimPower.on);
      await client.put('/key_command/', _keys([(11, 2)]));
      expect(sim.effects, contains('power:toggle'));
    });

    test('power off in Eco mode closes the port after answering', () async {
      sim.ecoMode = true;
      final a = await client.put('/key_command/', _keys([(11, 0)]));
      expect(_result(a), 'SUCCESS');
      expect(sim.power, VizioSimPower.off);
      await expectLater(
        client.get('/state/device/power_mode'),
        throwsA(isA<SocketException>()),
      );
      await sim.wake();
      expect(sim.power, VizioSimPower.on);
      expect((await client.get('/state/device/power_mode')).status, 200);
    });

    test('a tuner-less panel refuses channel keys', () async {
      sim.hasTuner = false;
      expect(
        _result(await client.put('/key_command/', _keys([(8, 1)]))),
        'FAILURE',
      );
      expect(sim.keyPresses, isEmpty);
    });

    test(
      'a tuner-less panel refuses digit entry too (brief §6, §10)',
      () async {
        sim.hasTuner = false;
        // '7', '.', '1': how a channel number is typed.
        expect(
          _result(await client.put('/key_command/', _keys([(0, 55), (0, 46)]))),
          'FAILURE',
        );
        expect(sim.keyPresses, isEmpty);
        expect(sim.typedText, isEmpty);
        // Letters still type.
        expect(
          _result(
            await client.put('/key_command/', _keys([(0, 72), (0, 105)])),
          ),
          'SUCCESS',
        );
        expect(sim.typedText, 'Hi');
      },
    );

    test('malformed key lists are INVALID_PARAMETER', () async {
      expect(
        _result(await client.put('/key_command/', {'KEYLIST': []})),
        'INVALID_PARAMETER',
      );
      expect(
        _result(
          await client.put('/key_command/', {
            'KEYLIST': [
              {'CODESET': 3, 'CODE': 2, 'ACTION': 'TAP'},
            ],
          }),
        ),
        'INVALID_PARAMETER',
      );
    });
  });

  group('settings', () {
    setUp(() => client.pair());

    Future<(Object?, int)> leaf(String path) async {
      final item = _firstItem(await client.get(path));
      return (item['VALUE'], item['HASHVAL']! as int);
    }

    test('MODIFY with the current HASHVAL sets the volume and rotates the '
        'HASHVAL', () async {
      final (value, hash) = await leaf(_volume);
      expect(value, 15);
      final a = await client.put(_volume, {
        'REQUEST': 'MODIFY',
        'VALUE': 40,
        'HASHVAL': hash,
      });
      expect(_result(a), 'SUCCESS');
      expect(sim.volume, 40);
      final (_, newHash) = await leaf(_volume);
      expect(newHash, isNot(hash));
      // The old HASHVAL is stale now: nothing is applied.
      final stale = await client.put(_volume, {
        'REQUEST': 'MODIFY',
        'VALUE': 10,
        'HASHVAL': hash,
      });
      expect(_result(stale), 'HASHVAL_ERROR');
      expect(sim.volume, 40);
    });

    test('a value changed outside the API (the physical remote, a test) '
        'rotates its HASHVAL too', () async {
      final (_, volumeHash) = await leaf(_volume);
      sim.volume = 40;
      final staleVolume = await client.put(_volume, {
        'REQUEST': 'MODIFY',
        'VALUE': 10,
        'HASHVAL': volumeHash,
      });
      expect(_result(staleVolume), 'HASHVAL_ERROR');
      expect(sim.volume, 40);

      final (_, muteHash) = await leaf(_mute);
      sim.muted = true;
      final staleMute = await client.put(_mute, {
        'REQUEST': 'MODIFY',
        'VALUE': 'Off',
        'HASHVAL': muteHash,
      });
      expect(_result(staleMute), 'HASHVAL_ERROR');
      expect(sim.muted, isTrue);

      // Writing the value it already has changes nothing, HASHVAL included.
      final (_, same) = await leaf(_volume);
      sim.volume = 40;
      expect((await leaf(_volume)).$2, same);
    });

    test('a missing HASHVAL is INVALID_PARAMETER, a wrong verb '
        'PROXY_ERROR', () async {
      expect(
        _result(await client.put(_volume, {'REQUEST': 'MODIFY', 'VALUE': 3})),
        'INVALID_PARAMETER',
      );
      final (_, hash) = await leaf(_blank);
      expect(
        _result(
          await client.put(_blank, {'REQUEST': 'MODIFY', 'HASHVAL': hash}),
        ),
        'PROXY_ERROR',
      );
      expect(
        _result(
          await client.put(_blank, {'REQUEST': 'ACTION', 'HASHVAL': hash}),
        ),
        'SUCCESS',
      );
      expect(sim.screenBlanked, isTrue);
    });

    test('mute is inert in standby, volume is not', () async {
      await sim.pressPowerOnRemote();
      expect(sim.power, VizioSimPower.standby);
      final (_, hash) = await leaf(_mute);
      final a = await client.put(_mute, {
        'REQUEST': 'MODIFY',
        'VALUE': 'On',
        'HASHVAL': hash,
      });
      expect(_result(a), 'SUCCESS');
      expect(sim.muted, isFalse);
      await client.put('/key_command/', _keys([(5, 1)]));
      expect(sim.volume, 16);
      final power = await client.get('/state/device/power_mode');
      expect(_firstItem(power)['VALUE'], 0);
    });

    test('system information is read-only; modern firmware serves the '
        'aggregate only', () async {
      const base =
          '/menu_native/dynamic/tv_settings/system/system_information/'
          'tv_information';
      expect(_result(await client.get(base)), 'SUCCESS');
      expect(_result(await client.get('$base/serial_number')), 'URI_NOT_FOUND');
      expect(
        _result(await client.put(base, {'REQUEST': 'MODIFY'})),
        'READ_ONLY_ERROR',
      );
      sim.legacyFirmware = true;
      expect(_result(await client.get(base)), 'URI_NOT_FOUND');
      expect(_result(await client.get('$base/serial_number')), 'SUCCESS');
    });

    test('the volume range comes from the static tree', () async {
      final a = await client.get(
        '/menu_native/static/tv_settings/audio/volume',
      );
      expect(_firstItem(a)['MAXIMUM'], 100);
    });

    test('the audio collection omits the volume leaf', () async {
      final a = await client.get('/menu_native/dynamic/tv_settings/audio');
      final items = (a.json! as Map<String, Object?>)['ITEMS']! as List;
      expect(
        [for (final i in items) (i as Map<String, Object?>)['CNAME']],
        ['mute'],
      );
    });
  });

  group('inputs', () {
    setUp(() => client.pair());

    Future<_Answer> select(String value, {int? hash}) async {
      final current = _firstItem(await client.get(_currentInput));
      return client.put(_currentInput, {
        'REQUEST': 'MODIFY',
        'VALUE': value,
        'HASHVAL': hash ?? current['HASHVAL'],
      });
    }

    test('current_input reports the meta name for cast and the display '
        'name for HDMI', () async {
      expect(_firstItem(await client.get(_currentInput))['VALUE'], 'SMARTCAST');
      expect(_result(await select('hdmi2')), 'SUCCESS');
      expect(sim.currentInput, 'hdmi2');
      expect(_firstItem(await client.get(_currentInput))['VALUE'], 'HDMI-2');
    });

    test('modern firmware takes only the lowercase cname', () async {
      expect(_result(await select('HDMI-1')), 'FAILURE');
      expect(_result(await select('Game Console')), 'HASHVAL_ERROR');
      expect(_result(await select('cast')), 'FAILURE'); // already current
      expect(_result(await select('hdmi1', hash: 1)), 'HASHVAL_ERROR');
      expect(sim.currentInput, 'cast');
    });

    test('legacy firmware also takes the display name', () async {
      sim.legacyFirmware = true;
      expect(_result(await select('HDMI-1')), 'SUCCESS');
      expect(sim.currentInput, 'hdmi1');
    });

    test('the HASHVAL rotates whenever the input changes, however it '
        'changes', () async {
      expect(_result(await select('hdmi1')), 'SUCCESS');
      Future<int> hash() async =>
          _firstItem(await client.get(_currentInput))['HASHVAL']! as int;

      // An app launch moves the TV to the cast input: a HASHVAL read on
      // HDMI-1 is stale afterwards, as on a real TV.
      var before = await hash();
      await client.put('/app/launch', {
        'VALUE': {'APP_ID': '1', 'NAME_SPACE': 3, 'MESSAGE': null},
      });
      expect(sim.currentInput, 'cast');
      expect(_result(await select('hdmi2', hash: before)), 'HASHVAL_ERROR');
      expect(sim.currentInput, 'cast');

      // So does the SmartCast key.
      expect(_result(await select('hdmi1')), 'SUCCESS');
      before = await hash();
      await client.put('/key_command/', _keys([(4, 3)]));
      expect(sim.currentInput, 'cast');
      expect(_result(await select('hdmi2', hash: before)), 'HASHVAL_ERROR');

      // And a test that switches the input itself (the physical remote).
      before = await hash();
      sim.currentInput = 'hdmi3';
      expect(_result(await select('hdmi2', hash: before)), 'HASHVAL_ERROR');
      expect(sim.currentInput, 'hdmi3');
    });

    test('name_input lists cnames, display and meta names', () async {
      final a = await client.get(
        '/menu_native/dynamic/tv_settings/devices/name_input',
      );
      final items = (a.json! as Map<String, Object?>)['ITEMS']! as List;
      final first = items.first! as Map<String, Object?>;
      expect(first['CNAME'], 'cast');
      expect(first['NAME'], 'CAST');
      expect(first['VALUE'], containsPair('NAME', 'SMARTCAST'));
    });
  });

  group('apps', () {
    setUp(() => client.pair());

    test('launch sets the current app; unknown apps fail', () async {
      final none = await client.get('/app/current');
      expect(_item(none), containsPair('VALUE', isNull));
      final a = await client.put('/app/launch', {
        'VALUE': {'APP_ID': '1', 'NAME_SPACE': 3, 'MESSAGE': null},
      });
      expect(_result(a), 'SUCCESS');
      expect(sim.currentApp?.name, 'Netflix');
      final current = _item(await client.get('/app/current'));
      expect(current['TYPE'], 'T_APP_V1');
      expect(current['VALUE'], {
        'APP_ID': '1',
        'NAME_SPACE': 3,
        'MESSAGE': null,
      });
      final unknown = await client.put('/app/launch', {
        'VALUE': {'APP_ID': '3001', 'NAME_SPACE': 4, 'MESSAGE': 'x'},
      });
      expect(_result(unknown), 'FAILURE');
    });

    test('no app may omit VALUE entirely', () async {
      sim.omitAppValueWhenNone = true;
      final current = _item(await client.get('/app/current'));
      expect(current.containsKey('VALUE'), isFalse);
    });
  });

  group('firmware variants', () {
    setUp(() => client.pair());

    test('state_extended is flat and reads power from POWER_STATUS', () async {
      expect(_result(await client.get('/state_extended')), 'URI_NOT_FOUND');
      sim.stateExtended = true;
      final a = await client.get('/state_extended');
      final json = a.json! as Map<String, Object?>;
      expect(json.containsKey('STATUS'), isFalse);
      expect(json['POWER_STATUS'], {'VALUE': 1});
      // On, but labelled with the configured power mode.
      expect(json['POWER_MODE'], {'VALUE': 'Quick Start'});
      expect(json['MEDIA_STATE'], {'VALUE': 'MediaState::Stopped'});
      final info = _firstItem(await client.get('/state/device/deviceinfo'));
      expect((info['VALUE']! as Map<String, Object?>)['SCPL_CAPABILITIES'], [
        'state_extended',
      ]);
    });

    test('flat V2 volume endpoints type-check their bodies', () async {
      expect(_result(await client.get('/audio/volume/level')), 'URI_NOT_FOUND');
      sim.v2Volume = true;
      expect(
        _result(await client.put('/audio/volume/level', {'LEVEL': 9})),
        'SUCCESS',
      );
      expect(sim.volume, 9);
      final level = _item(await client.get('/audio/volume/level'));
      expect(level['VALUE'], {'LEVEL': 9, 'MUTE': false});
      expect(
        _result(await client.put('/audio/volume/mute', {'MUTE': 'yes'})),
        'TYPE_ERROR',
      );
      expect(
        _result(await client.put('/audio/volume/mute', {'VALUE': true})),
        'INVALID_PARAMETER',
      );
      expect(
        _result(await client.put('/audio/volume/mute', {'MUTE': true})),
        'SUCCESS',
      );
      expect(sim.muted, isTrue);
    });
  });

  group('power and network', () {
    test(
      'an Eco-off TV refuses connections until woken, after a delay',
      () async {
        final off = await VizioSimulator.start(power: VizioSimPower.off);
        addTearDown(off.close);
        final c = _Client(off);
        addTearDown(c.close);
        await expectLater(
          c.get('/state/device/deviceinfo'),
          throwsA(isA<SocketException>()),
        );
        await off.wake(delay: const Duration(milliseconds: 100));
        expect(off.listening, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(off.listening, isTrue);
        expect(off.power, VizioSimPower.on);
        expect((await c.get('/state/device/deviceinfo')).status, 200);
      },
    );

    test('vanish and reappear', () async {
      await sim.vanish();
      await expectLater(
        client.get('/state/device/deviceinfo'),
        throwsA(isA<SocketException>()),
      );
      await sim.reappear();
      expect((await client.get('/state/device/deviceinfo')).status, 200);
    });
  });

  group('test controls', () {
    test('respondOnce replaces one answer', () async {
      sim.respondOnce('GET', '/state/device/deviceinfo', 503, body: 'busy');
      final a = await client.get('/state/device/deviceinfo');
      expect((a.status, a.text), (503, 'busy'));
      expect((await client.get('/state/device/deviceinfo')).status, 200);
    });

    test('holdNext holds the answer, not the effect', () async {
      await client.pair();
      final gate = sim.holdNext('PUT', '/key_command/');
      final answer = client.put('/key_command/', _keys([(5, 1)]));
      await gate.reached;
      expect(sim.volume, 16);
      var answered = false;
      unawaited(answer.then((_) => answered = true));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(answered, isFalse);
      gate.release();
      expect(_result(await answer), 'SUCCESS');
    });
  });
}
