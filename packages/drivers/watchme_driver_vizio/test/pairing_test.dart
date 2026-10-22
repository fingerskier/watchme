@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';
import 'package:watchme_testkit/vizio_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';
import 'support/io_http_stack.dart';

/// Waits (briefly, in real time) until [condition] holds.
Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(condition(), isTrue);
}

void main() {
  group('against the simulator', () {
    late VizioSimulator sim;
    final transports = IoHttpTransports();
    final clock = FakeClock(DateTime.utc(2026, 10, 22, 12));

    setUp(() async {
      sim = await VizioSimulator.start(pin: '4321', seed: 11);
    });

    tearDown(() => sim.close());

    PairingFlow start([VizioDriver? driver]) =>
        (driver ?? testDriver(clock: clock)).startPairing(
          sim.endpoint,
          transports,
          testContext,
        )!;

    test('shows a PIN, asks for it and returns a pinned token', () async {
      final steps = await drive(start(), ['4321']);
      expect(steps, hasLength(2));
      expect(
        steps.first,
        const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
      );
      final credential = (steps.last as Paired).credential! as TokenCredential;
      expect(credential.driverId, 'vizio.smartcast');
      expect(credential.deviceId, 'tv-1');
      expect(credential.createdAt, DateTime.utc(2026, 10, 22, 12));
      expect(credential.expiresAt, isNull);
      expect(sim.validTokens, {credential.token});
      expect(credential.peerCertSha256, sim.certificateSha256);
      final controllerId = credential.attributes['controllerId']!;
      expect(controllerId, matches(RegExp(r'^watchme-[0-9a-f]{24}$')));
      expect(sim.pairedTokens[credential.token], controllerId);
      expect(credential.attributes, {
        'controllerId': controllerId,
        'friendlyName': 'watchme test',
        'port': '${sim.apiPort}',
      });
      expect(sim.pairingNames, ['watchme test']);

      expect(lines(sim.requests), [
        'GET /state/device/deviceinfo',
        'PUT /pairing/start',
        'PUT /pairing/pair',
      ]);
      final [_, startReq, pairReq] = sim.requests;
      expect(jsonDecode(startReq.body), {
        'DEVICE_ID': controllerId,
        'DEVICE_NAME': 'watchme test',
      });
      final pairBody = jsonDecode(pairReq.body) as Map<String, Object?>;
      expect(pairBody.keys, [
        'DEVICE_ID',
        'CHALLENGE_TYPE',
        'RESPONSE_VALUE',
        'PAIRING_REQ_TOKEN',
      ]);
      expect(pairBody['CHALLENGE_TYPE'], 1);
      expect(pairBody['RESPONSE_VALUE'], '4321');
      expect(pairBody['PAIRING_REQ_TOKEN'], isA<int>());
      for (final r in sim.requests) {
        expect(r.header('auth'), isNull);
      }
      expect(startReq.header('content-type'), 'application/json');
      expect(sim.cancelCount, 0);
    });

    test('a wrong PIN can be re-entered while the TV shows it', () async {
      final steps = await drive(start(), ['0000', '4321']);
      expect(steps.map((s) => s.runtimeType), [EnterCode, EnterCode, Paired]);
      expect((steps[1] as EnterCode).label, startsWith('Wrong PIN'));
      expect(
        lines(sim.requests).where((l) => l == 'PUT /pairing/start'),
        hasLength(1),
      );
      expect(
        lines(sim.requests).where((l) => l == 'PUT /pairing/pair'),
        hasLength(2),
      );
    });

    test(
      'after maxPinAttempts wrong PINs it fails and cancels on the TV',
      () async {
        final steps = await drive(start(testDriver(maxPinAttempts: 2)), [
          '0000',
          '0001',
        ]);
        expect(
          steps.last,
          isPairingFailedWith(
            WatchmeErrorCode.unauthorized,
            rawDeviceMessage: contains('PAIRING_DENIED'),
          ),
        );
        expect(
          (steps.last as PairingFailed).error.message,
          'Wrong PIN (2 attempts)',
        );
        expect(sim.cancelCount, 1);
        expect(sim.displayedPin, isNull);
      },
    );

    test("the TV's own lockout is terminal and cancelled", () async {
      final steps = await drive(start(testDriver(maxPinAttempts: 9)), [
        '0000',
        '0001',
        '0002',
      ]);
      expect(steps.whereType<EnterCode>(), hasLength(3));
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.unauthorized);
      expect(failed.error.message, contains('too many wrong PINs'));
      expect(failed.rawDeviceMessage, contains('MAX_CHALLENGES_EXCEEDED'));
      expect(sim.cancelCount, 1);
      expect(sim.pairingLocked, isFalse);
    });

    test('a malformed code is asked again without contacting the TV', () async {
      final steps = await drive(start(), ['12', 'abcd', '4321']);
      expect(steps.map((s) => s.runtimeType), [
        EnterCode,
        EnterCode,
        EnterCode,
        Paired,
      ]);
      expect((steps[1] as EnterCode).label, contains('4 digits'));
      expect(
        lines(sim.requests).where((l) => l == 'PUT /pairing/pair'),
        hasLength(1),
      );
    });

    test('cancelling at the PIN prompt cancels pairing on the TV', () async {
      final flow = start();
      final steps = <PairingStep>[];
      final done = Completer<void>();
      flow.steps.listen(steps.add, onDone: done.complete);
      await _eventually(() => steps.isNotEmpty);
      expect(sim.displayedPin, '4321');
      await flow.cancel();
      await done.future;
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      expect(sim.cancelCount, 1);
      expect(sim.displayedPin, isNull);
      final cancel = sim.requests.last;
      expect(lines([cancel]), ['PUT /pairing/cancel']);
      final startBody = jsonDecode(
        sim.requests.firstWhere((r) => r.path == '/pairing/start').body,
      );
      expect(jsonDecode(cancel.body), startBody);
    });

    test('cancelling while the PIN check is in flight cancels on the TV '
        'once and never reports a pairing', () async {
      final gate = sim.holdNext('PUT', '/pairing/pair');
      addTearDown(gate.release);
      final flow = start();
      final steps = <PairingStep>[];
      final done = Completer<void>();
      flow.steps.listen((step) {
        steps.add(step);
        if (step.awaitsInput) flow.submit('4321');
      }, onDone: done.complete);
      await gate.reached;
      await flow.cancel();
      gate.release();
      await done.future;
      expect(steps.whereType<Paired>(), isEmpty);
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      await _eventually(() => sim.cancelCount == 1);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sim.cancelCount, 1);
    });

    test('a pairing cancelled before it starts sends nothing', () async {
      final flow = start();
      await flow.cancel();
      expect(await flow.steps.toList(), [
        isPairingFailedWith(WatchmeErrorCode.cancelled),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sim.requests, isEmpty);
    });

    test(
      "another controller's PIN on screen is BLOCKED and left alone",
      () async {
        final first = start();
        final firstSteps = <PairingStep>[];
        first.steps.listen(firstSteps.add);
        await _eventually(() => firstSteps.isNotEmpty);

        final steps = await drive(start(), ['4321']);
        final failed = steps.single as PairingFailed;
        expect(failed.error.code, WatchmeErrorCode.rejected);
        expect(
          failed.error.message,
          contains('another pairing is in progress'),
        );
        expect(failed.rawDeviceMessage, contains('BLOCKED'));
        // It did not start a pairing, so it cancels none.
        expect(sim.cancelCount, 0);
        expect(sim.displayedPin, '4321');
        await first.cancel();
        expect(sim.cancelCount, 1);
      },
    );

    test('REQUIRES_PAIRING while pairing is unauthorized (brief §5), and '
        'starts nothing to cancel', () async {
      sim.respondOnce(
        'PUT',
        '/pairing/start',
        200,
        json: {
          'STATUS': {'RESULT': 'REQUIRES_PAIRING'},
          'URI': '/pairing/start',
        },
      );
      final steps = await drive(start(), ['4321']);
      expect(
        steps.single,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: contains('REQUIRES_PAIRING'),
        ),
      );
      expect(sim.cancelCount, 0);
    });

    test('a full pairing table is rejected', () async {
      final full = await VizioSimulator.start(maxPairedDevices: 1);
      addTearDown(full.close);
      final driver = testDriver();
      await pair(driver, full, transports);
      final steps = await drive(
        driver.startPairing(full.endpoint, transports, testContext)!,
        [null],
        sim: full,
      );
      final failed = steps.single as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.rejected);
      expect(failed.error.message, contains('paired too many devices'));
      expect(full.cancelCount, 0);
    });

    test('a PIN that expired is unauthorized and cancelled', () async {
      final flow = start();
      final steps = <PairingStep>[];
      final done = Completer<void>();
      flow.steps.listen(steps.add, onDone: done.complete);
      await _eventually(() => steps.isNotEmpty);
      sim.expirePin();
      flow.submit('4321');
      await done.future;
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.unauthorized);
      expect(failed.error.message, contains('no longer on the TV'));
      expect(failed.rawDeviceMessage, contains('CHALLENGE_INCORRECT'));
      expect(sim.cancelCount, 1);
    });

    test('a pairing aborted on the TV is cancelled', () async {
      sim.respondOnce(
        'PUT',
        '/pairing/pair',
        200,
        json: {
          'STATUS': {'RESULT': 'ABORTED', 'DETAIL': 'Aborted'},
          'URI': '/pairing/pair',
        },
      );
      final steps = await drive(start(), ['4321']);
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
      expect(sim.cancelCount, 1);
    });

    test('a TV that does not answer fails as unreachable and is not '
        'cancelled', () async {
      final off = await VizioSimulator.start(power: VizioSimPower.off);
      addTearDown(off.close);
      final steps = await drive(
        testDriver().startPairing(off.endpoint, transports, testContext)!,
        ['1234'],
      );
      expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unreachable));
      expect(off.requests, isEmpty);
    });

    test(
      'a start that timed out may have shown a PIN, so it is cancelled',
      () async {
        final gate = sim.holdNext('PUT', '/pairing/start');
        addTearDown(gate.release);
        final steps = await drive(
          start(testDriver(writeTimeout: const Duration(milliseconds: 300))),
          ['4321'],
        );
        expect(steps.single, isPairingFailedWith(WatchmeErrorCode.timeout));
        await _eventually(() => sim.cancelCount == 1);
      },
    );

    test('pairs on the legacy port and remembers it', () async {
      final legacy = await VizioSimulator.start(servesLegacyPort: true);
      addTearDown(legacy.close);
      final credential = await pair(testDriver(), legacy, transports);
      expect(credential.attributes['port'], '${legacy.legacyPort}');
    });

    test('a sound bar is not paired', () async {
      sim.settingsRoot = 'audio_settings';
      final steps = await drive(start(), ['4321']);
      expect(steps.single, isPairingFailedWith(WatchmeErrorCode.unsupported));
      expect(lines(sim.requests), ['GET /state/device/deviceinfo']);
    });

    test('each pairing without a previous credential uses a new controller '
        'id', () async {
      final driver = testDriver();
      final a = await pair(driver, sim, transports);
      final b = await pair(driver, sim, transports);
      expect(a.attributes['controllerId'], isNot(b.attributes['controllerId']));
      // Different ids, so the first token is not overwritten.
      expect(sim.validTokens, {a.token, b.token});
    });

    test('pairing again reuses the controller id of the previous credential, '
        'so the TV replaces the old token', () async {
      final driver = testDriver();
      final first = await pair(driver, sim, transports);
      final again = PairingContext(
        deviceId: testContext.deviceId,
        clientName: testContext.clientName,
        previousCredential: () async => first,
      );
      final steps = await drive(
        driver.startPairing(sim.endpoint, transports, again)!,
        [null],
        sim: sim,
      );
      final second = (steps.last as Paired).credential! as TokenCredential;
      expect(
        second.attributes['controllerId'],
        first.attributes['controllerId'],
      );
      expect(second.token, isNot(first.token));
      expect(sim.validTokens, {second.token}, reason: 'the old token is gone');
      expect(sim.pairedTokens.values.toSet(), hasLength(1));
    });

    test("a previous credential that is not this driver's, or a store that "
        'fails, gives a new controller id', () async {
      final driver = testDriver();
      final first = await pair(driver, sim, transports);
      for (final previous in <Future<Credential?> Function()>[
        () async => SharedSecretCredential(
          driverId: 'other.driver',
          deviceId: testContext.deviceId,
          createdAt: DateTime.utc(2026),
          secret: 'x',
        ),
        () async => TokenCredential(
          driverId: vizioDriverId,
          deviceId: 'another-tv',
          createdAt: DateTime.utc(2026),
          token: 't',
          attributes: first.attributes,
        ),
        () async => TokenCredential(
          driverId: vizioDriverId,
          deviceId: testContext.deviceId,
          createdAt: DateTime.utc(2026),
          token: 't',
          attributes: const {'controllerId': 'not-ours'},
        ),
        () async => throw StateError('store unreadable'),
      ]) {
        final steps = await drive(
          driver.startPairing(
            sim.endpoint,
            transports,
            PairingContext(
              deviceId: testContext.deviceId,
              previousCredential: previous,
            ),
          )!,
          [null],
          sim: sim,
        );
        final next = (steps.last as Paired).credential! as TokenCredential;
        expect(
          next.attributes['controllerId'],
          allOf(
            isNot(first.attributes['controllerId']),
            matches(RegExp(r'^watchme-[0-9a-f]{24}$')),
          ),
        );
      }
      expect(sim.validTokens, contains(first.token));
    });

    group('a failed PIN check never shows a token', () {
      const token = 'S3cr3t-T0ken-4b2f';

      void expectNoToken(PairingStep step) {
        final failed = step as PairingFailed;
        for (final text in [
          jsonEncode(failed.toJson()),
          jsonEncode(failed.toJson(includeSecrets: true)),
          '$failed',
          ...errorTexts(failed.error),
        ]) {
          // In any case: a status word is shown upper-cased.
          expect(text.toLowerCase(), isNot(contains('s3cr3t')), reason: text);
        }
      }

      test(
        'a refusal that carries a token keeps only the status word',
        () async {
          sim.respondOnce(
            'PUT',
            '/pairing/pair',
            200,
            json: {
              'ITEM': {'AUTH_TOKEN': token},
              'STATUS': {'RESULT': 'FAILURE', 'DETAIL': 'nope $token'},
            },
          );
          final steps = await drive(start(), ['4321']);
          expectNoToken(steps.last);
          final failed = steps.last as PairingFailed;
          expect(failed.error.code, WatchmeErrorCode.rejected);
          expect(failed.rawDeviceMessage, contains('"FAILURE"'));
          expect(failed.rawDeviceMessage, contains('<redacted>'));
        },
      );

      test('a status that is not a known word is never shown', () async {
        // A malformed answer with the token as its status too: the message
        // names no status, and nothing shows the token in any case.
        sim.respondOnce(
          'PUT',
          '/pairing/pair',
          200,
          json: {
            'ITEM': {'AUTH_TOKEN': token},
            'STATUS': {'RESULT': token, 'DETAIL': 'Success'},
          },
        );
        final steps = await drive(start(), ['4321']);
        expectNoToken(steps.last);
        final failed = steps.last as PairingFailed;
        expect(failed.error.code, WatchmeErrorCode.protocol);
        expect(
          failed.error.message,
          'Checking the PIN: unexpected SmartCast status',
        );
        expect(sim.cancelCount, 1);
      });

      test('a non-JSON error body is removed whole', () async {
        sim.respondOnce('PUT', '/pairing/pair', 500, body: 'oops $token');
        final steps = await drive(start(), ['4321']);
        expectNoToken(steps.last);
        expect(
          steps.last,
          isPairingFailedWith(
            WatchmeErrorCode.protocol,
            rawDeviceMessage: '<redacted> (22 characters, not JSON)',
          ),
        );
      });

      test('the PIN is not echoed either', () async {
        sim.respondOnce(
          'PUT',
          '/pairing/pair',
          200,
          json: {
            'STATUS': {'RESULT': 'PAIRING_DENIED', 'DETAIL': 'PIN 4321'},
            'RESPONSE_VALUE': '4321',
          },
        );
        final steps = await drive(start(testDriver(maxPinAttempts: 1)), [
          '4321',
        ]);
        final failed = steps.last as PairingFailed;
        for (final text in errorTexts(failed.error)) {
          expect(text, isNot(contains('4321')), reason: text);
        }
      });

      test(
        'a token that cannot be sent as a header is refused, unseen',
        () async {
          // CR/LF would end the AUTH header (dart:io refuses it), so every
          // later call would fail: no credential, and the token stays hidden.
          sim.respondOnce(
            'PUT',
            '/pairing/pair',
            200,
            json: {
              'ITEM': {'AUTH_TOKEN': 'S3cr3t\r\nX-Other: 1'},
              'STATUS': {'RESULT': 'SUCCESS'},
            },
          );
          final steps = await drive(start(), ['4321']);
          expect(steps.whereType<Paired>(), isEmpty);
          expect(steps.last, isPairingFailedWith(WatchmeErrorCode.protocol));
          expectNoToken(steps.last);
        },
      );

      test('a success without a usable token is a protocol error', () async {
        sim.respondOnce(
          'PUT',
          '/pairing/pair',
          200,
          json: {
            'ITEM': {'AUTH_TOKEN': ' '},
            'STATUS': {'RESULT': 'SUCCESS'},
          },
        );
        final steps = await drive(start(), ['4321']);
        expect(steps.last, isPairingFailedWith(WatchmeErrorCode.protocol));
        expect(sim.cancelCount, 1);
      });
    });
  });

  group('with a scripted network', () {
    test(
      'trusts on first use, then pins the certificate for pairing',
      () async {
        final net = FakeNetworkStack();
        const host = '10.0.0.9';
        final fingerprint = fakeFingerprint('vizio-tv');
        net.serveTls(host, 7345, certificateSha256: fingerprint);
        net.respond(
          'GET',
          '/state/device/deviceinfo',
          HttpResult.json(200, {
            'ITEMS': [
              {
                'VALUE': {'SETTINGS_ROOT': 'tv_settings'},
              },
            ],
            'STATUS': {'RESULT': 'SUCCESS'},
          }),
        );
        net.respond(
          'PUT',
          '/pairing/start',
          HttpResult.json(200, {
            'ITEM': {'CHALLENGE_TYPE': 1, 'PAIRING_REQ_TOKEN': 654321},
            'STATUS': {'RESULT': 'SUCCESS', 'DETAIL': 'Success'},
            'URI': '/pairing/start',
          }),
        );
        net.respond(
          'PUT',
          '/pairing/pair',
          HttpResult.json(200, {
            'ITEM': {'AUTH_TOKEN': 'Zm9vYmFy'},
            'STATUS': {'RESULT': 'SUCCESS', 'DETAIL': 'Success'},
            'URI': '/pairing/pair',
          }),
        );
        final steps = await drive(
          VizioDriver().startPairing(
            const Endpoint(host),
            FakeTransports(network: net),
            testContext,
          )!,
          ['1234'],
        );
        final credential =
            (steps.last as Paired).credential! as TokenCredential;
        expect(credential.token, 'Zm9vYmFy');
        expect(credential.peerCertSha256, fingerprint);
        expect(credential.attributes['port'], '7345');
        final log = net.httpLog;
        expect(log[0].tls, const TlsPolicy.firstUse());
        expect(log[1].tls.pins, {fingerprint});
        expect(log[2].tls.pins, {fingerprint});
        expect(log[2].call.bodyText, contains('"PAIRING_REQ_TOKEN":654321'));
        expect(log[2].call.bodyText, contains('"RESPONSE_VALUE":"1234"'));
      },
    );
  });
}
