import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fake_firetv.dart';

const _context = PairingContext(deviceId: 'dev-1', clientName: 'watchme test');

/// Runs [flow], answering each step that awaits input with the next of
/// [inputs] (cancelling when they run out), and returns every step.
Future<List<PairingStep>> _drive(PairingFlow flow, List<String> inputs) async {
  final queue = [...inputs];
  final steps = <PairingStep>[];
  await for (final step in flow.steps) {
    steps.add(step);
    if (step.awaitsInput) {
      if (queue.isEmpty) {
        unawaited(flow.cancel());
      } else {
        flow.submit(queue.removeAt(0));
      }
    }
  }
  return steps;
}

void main() {
  late FakeNetworkStack net;
  late FakeTransports transports;
  late FakeFireTv tv;
  late FakeClock clock;
  late FireTvDriver driver;

  setUp(() {
    net = FakeNetworkStack();
    transports = FakeTransports(network: net);
    tv = FakeFireTv(net);
    clock = FakeClock(DateTime.utc(2026, 10, 21, 12));
    driver = FireTvDriver(clock: clock);
  });

  PairingFlow start() =>
      driver.startPairing(tv.endpoint, transports, _context)!;

  test(
    'wakes, shows the PIN, asks for it and returns a pinned token',
    () async {
      final steps = await _drive(start(), ['1234']);

      expect(steps, hasLength(2));
      expect(
        steps.first,
        const EnterCode(
          'Enter the PIN shown on the TV',
          4,
          CodeAlphabet.digits,
        ),
      );
      final credential = (steps.last as Paired).credential! as TokenCredential;
      expect(credential.driverId, 'firetv.lightning');
      expect(credential.deviceId, 'dev-1');
      expect(credential.token, tv.token);
      expect(credential.peerCertSha256, tv.fingerprint);
      expect(credential.createdAt, DateTime.utc(2026, 10, 21, 12));
      expect(credential.attributes, {'friendlyName': 'watchme test'});
      expect(tv.friendlyNames, ['watchme test']);

      final calls = net.httpCalls;
      expect(
        [for (final c in calls) '${c.method} ${c.uri.path}'],
        [
          'POST /apps/FireTVRemote',
          'POST /v1/FireTV/pin/display',
          'POST /v1/FireTV/pin/verify',
        ],
      );
      final wake = calls[0];
      expect(wake.uri.toString(), 'http://10.0.0.7:8009/apps/FireTVRemote');
      expect(wake.header('Content-Type'), 'text/plain');
      expect(wake.body, isNull);
      for (final call in calls.skip(1)) {
        expect(call.uri.scheme, 'https');
        expect(call.uri.port, 8080);
        expect(call.header('X-Api-Key'), '0987654321');
        expect(call.header('Content-Type'), 'application/json; charset=utf-8');
        expect(call.header('X-Client-Token'), isNull);
      }
      expect(calls[2].bodyText, '{"pin":"1234"}');
    },
  );

  test('trusts on first use, then pins the recorded certificate', () async {
    await _drive(start(), ['1234']);
    final api = tv.apiLog;
    expect(api[0].tls, const TlsPolicy.firstUse());
    expect(api[1].tls.pins, {tv.fingerprint});
    expect(api[1].result!.peerCertificateSha256, tv.fingerprint);
  });

  test('a wrong PIN can be re-entered while the TV still shows it', () async {
    final steps = await _drive(start(), ['0000', '1234']);
    expect(steps.map((s) => s.runtimeType), [EnterCode, EnterCode, Paired]);
    expect((steps[1] as EnterCode).label, startsWith('Wrong PIN'));
    expect(net.callsTo('POST', '/v1/FireTV/pin/verify'), hasLength(2));
    expect(net.callsTo('POST', '/v1/FireTV/pin/display'), hasLength(1));
  });

  test('too many wrong PINs fail with the device text', () async {
    final steps = await _drive(start(), ['0000', '1111', '2222']);
    expect(steps.whereType<EnterCode>(), hasLength(3));
    expect(
      steps.last,
      isPairingFailedWith(
        WatchmeErrorCode.unauthorized,
        rawDeviceMessage: '{"description":""}',
      ),
    );
  });

  test('a malformed code is asked again without contacting the TV', () async {
    final steps = await _drive(start(), ['12', 'abcd', '1234']);
    expect(steps.map((s) => s.runtimeType), [
      EnterCode,
      EnterCode,
      EnterCode,
      Paired,
    ]);
    expect(net.callsTo('POST', '/v1/FireTV/pin/verify'), hasLength(1));
  });

  test('a refused verify fails with the raw device text', () async {
    net.respond(
      'POST',
      '/v1/FireTV/pin/verify',
      HttpResult.text(400, 'PIN expired'),
    );
    final steps = await _drive(start(), ['1234']);
    expect(
      steps.last,
      isPairingFailedWith(
        WatchmeErrorCode.rejected,
        rawDeviceMessage: 'PIN expired',
      ),
    );
  });

  test('a description of "OK" without a token is a protocol failure', () async {
    net.respond(
      'POST',
      '/v1/FireTV/pin/verify',
      HttpResult.json(200, {'description': 'OK'}),
    );
    final steps = await _drive(start(), ['1234']);
    expect(
      steps.last,
      isPairingFailedWith(
        WatchmeErrorCode.protocol,
        rawDeviceMessage: '{"description":"OK"}',
      ),
    );
  });

  group('a failed PIN check never shows a token', () {
    // Codex finding #8: a synthetic token ending in a newline.
    const token = 'S3cr3t-T0ken-4b2f\n';

    /// Every text the step reaches: its JSON (as the hub serialises it),
    /// its string form, and the error's message, raw text and cause, which
    /// the pairing screen shows or logs.
    void expectNoToken(PairingStep step) {
      final failed = step as PairingFailed;
      for (final text in [
        jsonEncode(failed.toJson()),
        jsonEncode(failed.toJson(includeSecrets: true)),
        '$failed',
        '${failed.error}',
        failed.error.message,
        '${failed.rawDeviceMessage}',
        '${failed.error.cause}',
      ]) {
        expect(text, isNot(contains('S3cr3t-T0ken')), reason: text);
      }
    }

    Future<PairingStep> verifyAnswers(HttpResult answer) async {
      net.respond('POST', '/v1/FireTV/pin/verify', answer);
      return (await _drive(start(), ['1234'])).last;
    }

    test('a token refused for a non-printable character', () async {
      final step = await verifyAnswers(
        HttpResult.json(200, {'description': token}),
      );
      expect(
        step,
        isPairingFailedWith(
          WatchmeErrorCode.protocol,
          rawDeviceMessage: '{"description":"<redacted>"}',
        ),
      );
      expect(
        (step as PairingFailed).error.message,
        contains('no usable token'),
      );
      expectNoToken(step);
    });

    test('a token outside the description field', () async {
      final step = await verifyAnswers(
        HttpResult.json(200, {'clientToken': 'S3cr3t-T0ken-4b2f', 'n': 1}),
      );
      // `"n":1` was kept before; numbers are redacted too now, since a
      // numeric token stayed in the error (verifier follow-up to #8).
      expect(
        step,
        isPairingFailedWith(
          WatchmeErrorCode.protocol,
          rawDeviceMessage: '{"clientToken":"<redacted>","n":"<redacted>"}',
        ),
      );
      expectNoToken(step);
    });

    test('a 2xx answer that is not JSON', () async {
      final step = await verifyAnswers(
        HttpResult.text(200, 'S3cr3t-T0ken-4b2f'),
      );
      expect(step, isPairingFailedWith(WatchmeErrorCode.protocol));
      expectNoToken(step);
    });

    // Verifier follow-up to Codex finding #8: a refusal (any non-2xx
    // status) kept `description`, the field this endpoint puts the token
    // in, and a non-JSON body whole.
    for (final (name, answer) in [
      ('HTTP 400', HttpResult.json(400, {'description': 'S3cr3t-T0ken-4b2f'})),
      ('HTTP 401', HttpResult.json(401, {'description': 'S3cr3t-T0ken-4b2f'})),
      ('HTTP 500', HttpResult.json(500, {'description': 'S3cr3t-T0ken-4b2f'})),
      ('HTTP 302', HttpResult.json(302, {'description': 'S3cr3t-T0ken-4b2f'})),
      ('HTTP 500, not JSON', HttpResult.text(500, 'S3cr3t-T0ken-4b2f')),
      (
        'HTTP 500, nested',
        HttpResult.json(500, {
          'error': {'detail': 'S3cr3t-T0ken-4b2f'},
        }),
      ),
    ]) {
      test('a refusal carrying the token: $name', () async {
        final step = await verifyAnswers(answer);
        expect(step, isA<PairingFailed>());
        expect(
          (step as PairingFailed).error.message,
          contains('HTTP ${answer.status}'),
        );
        expectNoToken(step);
      });
    }

    test('a numeric description', () async {
      final step = await verifyAnswers(
        HttpResult.text(200, '{"description": 987654321777}'),
      );
      expect(step, isPairingFailedWith(WatchmeErrorCode.protocol));
      for (final text in [
        jsonEncode((step as PairingFailed).toJson()),
        '$step',
        '${step.rawDeviceMessage}',
      ]) {
        expect(text, isNot(contains('987654321777')), reason: text);
      }
    });

    test('wrong PINs whose answers carry a token elsewhere', () async {
      net.respond(
        'POST',
        '/v1/FireTV/pin/verify',
        HttpResult.json(200, {
          'description': '',
          'session': 'S3cr3t-T0ken-4b2f',
        }),
      );
      final step = (await _drive(start(), ['0000', '1111', '2222'])).last;
      expect(
        step,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: '{"description":"","session":"<redacted>"}',
        ),
      );
      expectNoToken(step);
    });

    test('a refusal keeps its words but not a token field', () async {
      final step = await verifyAnswers(
        HttpResult.json(400, {
          'description': 'PIN expired',
          'clientToken': 'S3cr3t-T0ken-4b2f',
        }),
      );
      expect(
        step,
        isPairingFailedWith(
          WatchmeErrorCode.rejected,
          rawDeviceMessage:
              '{"description":"PIN expired","clientToken":"<redacted>"}',
        ),
      );
      expectNoToken(step);
    });
  });

  test('waits for the API port to open after the wake', () async {
    tv.wakeOnDial = false;
    final stepsFuture = _drive(start(), ['1234']);
    await clock.advance(const Duration(milliseconds: 1200));
    expect(net.callsTo('POST', '/v1/FireTV/pin/display'), hasLength(3));
    tv.wakeUp();
    await clock.advance(const Duration(milliseconds: 500));
    final steps = await stepsFuture;
    expect(steps.last, isA<Paired>());
  });

  test('an unreachable device fails as unreachable after the wait', () async {
    tv.wakeOnDial = false;
    net.setUnreachable(tv.host, port: tv.dialPort);
    final stepsFuture = _drive(start(), []);
    await clock.advance(const Duration(seconds: 7));
    final steps = await stepsFuture;
    expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unreachable));
    expect(
      (steps.single as PairingFailed).error.message,
      contains('DIAL wake failed too'),
    );
  });

  test('cancel ends the flow with PairingFailed(cancelled)', () async {
    final steps = await _drive(start(), []);
    expect(steps.first, isA<EnterCode>());
    expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
    expect(net.callsTo('POST', '/v1/FireTV/pin/verify'), isEmpty);
  });

  test(
    'cancelling before the flow starts wakes nothing and shows no PIN',
    () async {
      final flow = start();
      final steps = <PairingStep>[];
      final done = flow.steps.listen(steps.add).asFuture<void>();
      await flow.cancel();
      await clock.advance(const Duration(seconds: 10));
      await done;
      expect(steps, [isPairingFailedWith(WatchmeErrorCode.cancelled)]);
      expect(net.httpCalls, isEmpty);
      expect(tv.wakes, 0);
    },
  );

  test(
    'cancelling while the device wakes stops before the PIN is shown',
    () async {
      tv.wakeOnDial = false;
      final flow = start();
      final steps = <PairingStep>[];
      final done = flow.steps.listen(steps.add).asFuture<void>();
      await clock.advance(const Duration(milliseconds: 700));
      final shown = net.callsTo('POST', '/v1/FireTV/pin/display').length;
      expect(shown, greaterThan(0), reason: 'still waiting for the API');
      await flow.cancel();
      tv.wakeUp();
      await clock.advance(const Duration(seconds: 10));
      await done;
      expect(steps, [isPairingFailedWith(WatchmeErrorCode.cancelled)]);
      expect(tv.wakes, 1);
      expect(
        net.callsTo('POST', '/v1/FireTV/pin/display'),
        hasLength(shown),
        reason: 'no PIN shown once cancelled',
      );
      expect(tv.friendlyNames, isEmpty);
    },
  );

  test('uses endpoint ports for both DIAL and the API', () async {
    final other = FakeFireTv(
      net,
      host: '127.0.0.1',
      dialPort: 40009,
      apiPort: 40080,
    );
    final flow = driver.startPairing(
      Endpoint('127.0.0.1', ports: {'dial': 40009, 'api': 40080}),
      transports,
      _context,
    )!;
    final steps = await _drive(flow, ['1234']);
    expect(steps.last, isA<Paired>());
    expect(other.wakes, 1);
  });

  test('fails cleanly without a network transport', () async {
    final flow = driver.startPairing(
      tv.endpoint,
      FakeTransports.offline(),
      _context,
    )!;
    final steps = await _drive(flow, []);
    expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unsupported));
  });
}
