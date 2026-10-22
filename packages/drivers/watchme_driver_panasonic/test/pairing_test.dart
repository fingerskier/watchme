@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/src/crypto.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';

import 'support/io_http_stack.dart';

const _context = PairingContext(deviceId: 'tv-1', clientName: 'watchme & co');

void main() {
  late PanasonicSimulator sim;
  late IoHttpTransports transports;
  final driver = PanasonicDriver(pollInterval: null);

  Future<PanasonicSimulator> startSim(PanasonicSimulator s) async {
    await s.start();
    addTearDown(s.stop);
    return sim = s;
  }

  setUp(() => transports = IoHttpTransports());

  /// Pairs, answering each PIN prompt with [answer] (the PIN on screen by
  /// default), and returns every step.
  Future<List<PairingStep>> pair({
    FutureOr<String> Function(EnterCode step, int index)? answer,
    Endpoint? endpoint,
  }) async {
    final flow = driver.startPairing(
      endpoint ?? sim.endpoint,
      transports,
      _context,
    )!;
    final steps = <PairingStep>[];
    var prompts = 0;
    await for (final step in flow.steps) {
      steps.add(step);
      if (step is EnterCode) {
        final index = prompts++;
        flow.submit(
          answer == null ? sim.displayedPin! : await answer(step, index),
        );
      }
    }
    return steps;
  }

  test('pairs an encrypted TV; the credential opens a session', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    final steps = await pair();
    expect(steps.map((s) => s.runtimeType), [Instruct, EnterCode, Paired]);
    expect((steps.first as Instruct).text, contains('dismiss it'));
    final code = steps[1] as EnterCode;
    expect((code.length, code.alphabet), (4, CodeAlphabet.digits));
    final credential =
        (steps.last as Paired).credential! as SharedSecretCredential;
    expect(credential.driverId, 'panasonic.viera');
    expect(credential.deviceId, 'tv-1');
    expect(credential.expiresAt, isNull);
    expect(credential.peerCertSha256, isNull);
    expect(sim.pairings, {credential.username!: credential.secret});
    // The device name is escaped on the wire and shown as given.
    expect(sim.pinDeviceNames, ['watchme & co']);
    // The new credential was verified by opening a session.
    expect(sim.sessionsOpened, 1);
    expect(sim.actions, [
      'GetVolume',
      'X_DisplayPinCode',
      'X_RequestAuth',
      'X_GetEncryptSessionId',
    ]);
    final session = await driver.connect(sim.endpoint, transports, credential);
    addTearDown(session.close);
    expect(
      await session.execute(const PressKey(RemoteKey.home)),
      const Confirmed(),
    );
    expect(sim.keyLog, ['NRC_HOME-ONOFF']);
  });

  test('pairing requests carry the field-proven headers, in plaintext '
      'envelopes', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    await pair();
    final show = sim.requests.firstWhere((r) => r.action == 'X_DisplayPinCode');
    expect(show.path, '/nrc/control_0');
    expect(
      show.header('SOAPACTION'),
      '"urn:panasonic-com:service:p00NetworkControl:1#X_DisplayPinCode"',
    );
    expect(show.header('Accept'), 'text/xml');
    expect(show.header('Content-Type'), 'text/xml; charset="utf-8"');
    expect(show.header('User-Agent'), isNull);
    expect(
      show.body,
      contains('<X_DeviceName>watchme &amp; co</X_DeviceName>'),
    );
    expect(show.body, isNot(contains('\n')));
    // The driver hands the stack exactly these headers, in this order (the
    // stack adds Host and Content-Length; dart:io reorders on the wire).
    final call = transports.network.calls.firstWhere(
      (c) => c.header('SOAPACTION')?.contains('X_DisplayPinCode') ?? false,
    );
    expect(call.headers.keys, [
      'Accept',
      'Cache-Control',
      'Pragma',
      'SOAPACTION',
      'Content-Type',
    ]);
    final names = {for (final (n, _) in show.headerLines) n.toLowerCase()};
    expect(names, {
      'accept',
      'cache-control',
      'pragma',
      'soapaction',
      'content-type',
      'content-length',
      'host',
    });
  });

  test('a wrong PIN shows a new PIN and prompts again', () async {
    await startSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
    final steps = await pair(answer: (_, i) => i == 0 ? '1111' : '4410');
    expect(steps.map((s) => s.runtimeType), [
      Instruct,
      EnterCode,
      EnterCode,
      Paired,
    ]);
    expect((steps[2] as EnterCode).label, contains('Wrong PIN'));
    // A new PIN (and challenge) was shown before asking again.
    expect(sim.pinDeviceNames, hasLength(2));
    expect(
      sim.effects,
      containsAllInOrder([
        'pin:display',
        'pin:wrong',
        'pin:display',
        'pin:paired',
      ]),
    );
  });

  test('three wrong PINs fail as unauthorized', () async {
    await startSim(PanasonicSimulator(encrypted: true, fixedPin: '4410'));
    final steps = await pair(answer: (_, _) => '0000');
    final failed = steps.last as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.unauthorized);
    expect(failed.error.message, 'Wrong PIN (3 attempts)');
    expect(failed.rawDeviceMessage, contains('<errorCode>600</errorCode>'));
    expect(sim.pinDeviceNames, hasLength(3));
    expect(sim.pairings, isEmpty);
  });

  test('malformed codes are asked again without contacting the TV', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    final steps = await pair(
      answer: (_, i) => switch (i) {
        0 => 'abcd',
        1 => '123',
        _ => sim.displayedPin!,
      },
    );
    expect(steps.whereType<EnterCode>(), hasLength(3));
    expect(steps.last, isA<Paired>());
    expect(sim.actions.where((a) => a == 'X_RequestAuth'), hasLength(1));
  });

  test('an expired PIN is replaced by a new one', () async {
    await startSim(
      PanasonicSimulator(
        encrypted: true,
        pinTimeout: const Duration(milliseconds: 100),
      ),
    );
    final steps = await pair(
      answer: (_, i) async {
        if (i == 0) {
          final pin = sim.displayedPin!;
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return pin;
        }
        return sim.displayedPin!;
      },
    );
    expect(steps.last, isA<Paired>());
    expect(sim.effects, contains('pin:expired'));
  });

  test(
    'a TV that locks out after a wrong PIN fails with its refusal',
    () async {
      await startSim(
        PanasonicSimulator(encrypted: true, fixedPin: '4410', maxWrongPins: 1),
      );
      final steps = await pair(answer: (_, _) => '0000');
      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.rejected);
      expect(failed.error.message, contains('Showing the PIN'));
      expect(failed.rawDeviceMessage, contains('Too many'));
    },
  );

  test('cancelled before it starts, pairing sends nothing', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    final flow = driver.startPairing(sim.endpoint, transports, _context)!;
    await flow.cancel();
    final steps = await flow.steps.toList();
    expect(
      (steps.single as PairingFailed).error.code,
      WatchmeErrorCode.cancelled,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sim.requests, isEmpty);
  });

  test(
    'cancelled while the PIN is shown, pairing sends nothing more',
    () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final flow = driver.startPairing(sim.endpoint, transports, _context)!;
      final steps = <PairingStep>[];
      await for (final step in flow.steps) {
        steps.add(step);
        if (step is EnterCode) await flow.cancel();
      }
      expect(steps.map((s) => s.runtimeType), [
        Instruct,
        EnterCode,
        PairingFailed,
      ]);
      expect(
        (steps.last as PairingFailed).error.code,
        WatchmeErrorCode.cancelled,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sim.actions.last, 'X_DisplayPinCode');
      expect(sim.pairings, isEmpty);
    },
  );

  test(
    'a TV in standby is not woken: the user is told to switch it on',
    () async {
      await startSim(
        PanasonicSimulator(
          encrypted: true,
          power: PanasonicSimPower.networkStandby,
        ),
      );
      final steps = await pair();
      final failed = steps.single as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.rejected);
      expect(failed.error.message, startsWith('Turn the TV on first'));
      expect(sim.actions, ['GetVolume']);
      expect(sim.power, PanasonicSimPower.networkStandby);
      expect(sim.keyLog, isEmpty);
    },
  );

  test('a plain TV needs no pairing', () async {
    await startSim(PanasonicSimulator());
    final probe = await driver.probe(sim.endpoint, transports);
    expect(driver.startPairing(probe.endpoint!, transports, _context), isNull);
    // Without the probe's attribute the flow finds out and shows no PIN.
    final steps = await pair();
    final failed = steps.single as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.unsupported);
    expect(sim.pinDeviceNames, isEmpty);
  });

  test('a client on another subnet is told why', () async {
    await startSim(
      PanasonicSimulator(encrypted: true, allowedSubnet: '10.1.0.0/16'),
    );
    final failed = (await pair()).single as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.rejected);
    expect(failed.error.message, contains('own subnet'));
  });

  test('a credential the TV then refuses to use is a protocol error, not a '
      're-pair', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    sim.respondOnce('X_GetEncryptSessionId', status: 500);
    final failed = (await pair()).last as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.protocol);
    expect(failed.error.message, contains('refused a session'));
  });

  test('an unreadable X_AuthResult is a protocol error', () async {
    await startSim(PanasonicSimulator(encrypted: true));
    sim.respondOnce(
      'X_RequestAuth',
      status: 200,
      body: panasonicSimSoapAnswer('X_RequestAuth', panasonicSimNrcUrn, [
        ('X_AuthResult', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
      ]),
    );
    final failed = (await pair()).last as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.protocol);
    expect(failed.error.message, contains('no pairing key'));
  });

  group('a truncated or escaped pairing answer shows no secret', () {
    /// Fails if any 10 characters in a row of [secret] are in [text].
    void expectNoPiece(String text, String secret) {
      for (var i = 0; i + 10 <= secret.length; i++) {
        expect(
          text,
          isNot(contains(secret.substring(i, i + 10))),
          reason: 'leaked part of $secret',
        );
      }
    }

    String shown(PairingFailed failed) =>
        '${failed.error} ${failed.error.cause} ${jsonEncode(failed.toJson())}';

    test('X_ChallengeKey cut off before its closing tag', () async {
      const challenge = 'mUQdS7/RyJTMsiojPz9i1Q==';
      final full = panasonicSimSoapAnswer(
        'X_DisplayPinCode',
        panasonicSimNrcUrn,
        [('X_ChallengeKey', challenge)],
      );
      await startSim(PanasonicSimulator(encrypted: true));
      sim.respondOnce(
        'X_DisplayPinCode',
        status: 200,
        body: full.substring(0, full.indexOf(challenge) + 20),
      );
      final failed = (await pair()).single as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.protocol);
      expect(failed.rawDeviceMessage, endsWith('<X_ChallengeKey><redacted>'));
      expectNoPiece(shown(failed), challenge);
    });

    test('X_AuthResult cut off, or echoed escaped without its end', () async {
      final blob = vieraSeal(
        VieraKeys.forPairing('mUQdS7/RyJTMsiojPz9i1Q=='),
        '<X_ApplicationId>AQIDBAUGBwgJCg==</X_ApplicationId>\n'
        '<X_Keyword>ICEiIyQlJicoKSorLC0uLw==</X_Keyword>',
        header: List.filled(12, 7),
      );
      final full = panasonicSimSoapAnswer('X_RequestAuth', panasonicSimNrcUrn, [
        ('X_AuthResult', blob),
      ]);
      final at = full.indexOf(blob);
      for (final body in [
        '<X_AuthResult>$blob',
        full.substring(0, at + blob.length ~/ 2),
        full.substring(0, at + blob.length + '</X_AuthRes'.length),
        'Bad request: &lt;X_AuthResult&gt;$blob',
      ]) {
        await startSim(PanasonicSimulator(encrypted: true));
        sim.respondOnce('X_RequestAuth', status: 200, body: body);
        final failed = (await pair()).last as PairingFailed;
        expect(failed.error.code, WatchmeErrorCode.protocol, reason: body);
        expect(failed.error.message, contains('no pairing key'));
        expect(failed.rawDeviceMessage, endsWith('<redacted>'), reason: body);
        expectNoPiece(shown(failed), blob);
        expect(sim.pairings, isEmpty);
      }
    });
  });

  test('a TV that is gone fails pairing as unreachable', () async {
    await startSim(PanasonicSimulator(power: PanasonicSimPower.standby));
    final failed = (await pair()).single as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.unreachable);
  });
}
