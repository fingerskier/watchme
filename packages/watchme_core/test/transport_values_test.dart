import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  final pin = 'AB:CD:${'00' * 30}';
  final pinHex = 'abcd${'00' * 30}';

  group('TlsPolicy.allows', () {
    test('platform policy follows chain trust', () {
      expect(
        TlsPolicy.platform.allows(peerSha256: pinHex, platformTrusted: true),
        isTrue,
      );
      expect(
        TlsPolicy.platform.allows(peerSha256: pinHex, platformTrusted: false),
        isFalse,
      );
    });

    test('pins override chain trust in both directions', () {
      final pinned = TlsPolicy.pinned([pin]);
      expect(pinned.pins, {pinHex});
      expect(
        pinned.allows(peerSha256: pinHex.toUpperCase(), platformTrusted: false),
        isTrue,
      );
      expect(
        pinned.allows(peerSha256: 'ff' * 32, platformTrusted: true),
        isFalse,
      );
    });

    test('first use and self-signed accept anything', () {
      expect(
        const TlsPolicy.firstUse().allows(
          peerSha256: 'ff' * 32,
          platformTrusted: false,
        ),
        isTrue,
      );
      expect(
        const TlsPolicy(allowSelfSigned: true)
            .allows(peerSha256: 'ff' * 32, platformTrusted: false),
        isTrue,
      );
    });

    test('normalizeFingerprint', () {
      expect(normalizeFingerprint(pin), pinHex);
      expect(() => normalizeFingerprint('abc'), throwsFormatException);
    });
  });

  group('HttpCall', () {
    test('json() sets the body and content type', () {
      final call = HttpCall.json(
        'post',
        Uri.parse('https://192.0.2.7:8080/v1/FireTV/pin/display'),
        {'friendlyName': 'watchme'},
      );
      expect(call.method, 'POST');
      expect(call.header('content-type'), 'application/json; charset=utf-8');
      expect(jsonDecode(call.bodyText!), {'friendlyName': 'watchme'});
    });

    test('text() keeps a caller content type', () {
      final call = HttpCall.text(
        'POST',
        Uri.parse('http://192.0.2.7:8009/apps/FireTVRemote'),
        '',
        headers: const {'content-type': 'text/plain'},
      );
      expect(call.headers, {'content-type': 'text/plain'});
      expect(call.body, isEmpty);
    });

    test('post() without a body has none', () {
      final call = HttpCall.post(Uri.parse('http://x/keypress/Home'));
      expect(call.body, isNull);
      expect(call.bodyText, isNull);
    });

    test('toString hides headers and body', () {
      final call = HttpCall.get(
        Uri.parse('http://x/'),
        headers: const {'X-Client-Token': 'secret'},
      );
      expect(call.toString(), isNot(contains('secret')));
    });

    test('value equality', () {
      expect(
        HttpCall.post(Uri.parse('http://x/'), body: [1, 2]),
        HttpCall.post(Uri.parse('http://x/'), body: [1, 2]),
      );
    });

    test('carries a per-call response limit', () {
      final limited = HttpCall.get(
        Uri.parse('http://x/desc.xml'),
        maxResponseBytes: 512 * 1024,
      );
      expect(limited.maxResponseBytes, 512 * 1024);
      expect(
        HttpCall.get(Uri.parse('http://x/desc.xml')).maxResponseBytes,
        isNull,
      );
      expect(
        limited,
        isNot(HttpCall.get(Uri.parse('http://x/desc.xml'))),
        reason: 'the limit is part of the request',
      );
    });
  });

  group('ProbeResult', () {
    test('carries the power state the probe saw', () {
      final at = DateTime.utc(2026, 10, 21);
      ProbeResult probe(PowerMode? mode) => ProbeResult.matched(
        info: const DeviceInfo(name: 'TV'),
        capabilities: const [],
        power: mode == null ? null : Observed.reported(mode, 'roku.ecp', at),
      );
      expect(probe(PowerMode.standby).power?.value, PowerMode.standby);
      expect(probe(PowerMode.on), probe(PowerMode.on));
      expect(probe(PowerMode.on), isNot(probe(PowerMode.standby)));
      expect(probe(null).power, isNull);
      expect(const ProbeResult.notMatched().power, isNull);
    });
  });

  group('HttpResult', () {
    test('lower-cases header names', () {
      final r = HttpResult(200, headers: const {'Content-Type': 'text/xml'});
      expect(r.headers, {'content-type': 'text/xml'});
      expect(r.header('CONTENT-TYPE'), 'text/xml');
    });

    test('json helpers', () {
      final r = HttpResult.json(200, {'description': 'token'});
      expect(r.ok, isTrue);
      expect(r.jsonObject(), {'description': 'token'});
      expect(r.header('content-type'), startsWith('application/json'));
    });

    test('bad JSON is a protocol error carrying the body', () {
      final r = HttpResult.text(500, 'Internal error');
      expect(
        r.json,
        throwsA(
          isA<WatchmeError>()
              .having((e) => e.code, 'code', WatchmeErrorCode.protocol)
              .having((e) => e.rawDeviceMessage, 'raw', 'Internal error'),
        ),
      );
      expect(
        HttpResult.json(200, [1]).jsonObject,
        throwsA(isA<WatchmeError>()),
      );
    });

    test('toError preserves the device text', () {
      final r = HttpResult.text(
        403,
        'ECP command not allowed in Limited mode.',
      );
      final e = r.toError(WatchmeErrorCode.rejected, 'Limited mode');
      expect(e.rawDeviceMessage, 'ECP command not allowed in Limited mode.');
      expect(
        HttpResult(401)
            .toError(WatchmeErrorCode.reauthRequired, 'x')
            .rawDeviceMessage,
        'HTTP 401',
      );
      expect(r.ok, isFalse);
    });
  });

  test('Datagram text and equality', () {
    final d = Datagram('192.0.2.1', 1900, utf8.encode('HTTP/1.1 200 OK'));
    expect(d.text, 'HTTP/1.1 200 OK');
    expect(d, Datagram('192.0.2.1', 1900, utf8.encode('HTTP/1.1 200 OK')));
  });

  test('ClientIdentity.pem never prints key material', () {
    final id = ClientIdentity.pem(
      certificateChain: 'CERT',
      privateKey: 'SECRET KEY',
    );
    expect(id.toString(), isNot(contains('SECRET')));
    expect(utf8.decode(id.privateKey), 'SECRET KEY');
  });

  test('requireNetwork and supportsAll', () {
    final t = _NoTransports();
    expect(t.supportsAll(const {}), isTrue);
    expect(t.supportsAll(const {TransportFeature.rawTcp}), isFalse);
    expect(
      t.requireNetwork,
      throwsA(
        isA<WatchmeError>().having(
          (e) => e.code,
          'code',
          WatchmeErrorCode.unsupported,
        ),
      ),
    );
  });

  test('MemoryCredentialStore and MemoryDeviceRepository', () async {
    final store = MemoryCredentialStore();
    final a = TokenCredential(
      driverId: 'd1',
      deviceId: 'dev',
      createdAt: DateTime.utc(2026),
      token: 't1',
    );
    final b = SharedSecretCredential(
      driverId: 'd2',
      deviceId: 'dev',
      createdAt: DateTime.utc(2026),
      secret: 's',
    );
    await store.write(a);
    await store.write(b);
    expect(await store.read('dev', 'd1'), a);
    expect(await store.readAll('dev'), unorderedEquals([a, b]));
    await store.delete('dev', driverId: 'd1');
    expect(await store.read('dev', 'd1'), isNull);
    await store.delete('dev');
    expect(await store.readAll('dev'), isEmpty);

    const record = DeviceRecord(id: 'dev', name: 'TV', host: '192.0.2.1');
    final repo = MemoryDeviceRepository([record]);
    expect(await repo.get('dev'), record);
    await repo.put(record.copyWith(name: 'Bedroom TV'));
    expect((await repo.all()).single.name, 'Bedroom TV');
    await repo.remove('dev');
    expect(await repo.all(), isEmpty);
  });

  test('SystemClock', () async {
    const clock = SystemClock();
    final before = DateTime.now();
    await clock.delay(Duration.zero);
    expect(clock.now().isBefore(before), isFalse);
    var fired = false;
    clock.timer(Duration.zero, () => fired = true);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(fired, isTrue);
  });
}

final class _NoTransports implements Transports {
  @override
  Set<TransportFeature> get features => const {};
  @override
  NetworkStack? get network => null;
  @override
  SerialPortProvider? get serial => null;
  @override
  BleCentral? get ble => null;
  @override
  HidPeripheral? get hid => null;
  @override
  IrEmitter? get ir => null;
  @override
  ProcessRunner? get process => null;
}
