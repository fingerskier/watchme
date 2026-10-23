@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_panasonic/src/crypto.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fake_viera.dart';
import 'support/io_http_stack.dart';

const String _appId = 'AQIDBAUGBwgJCg==';
const String _keyword = 'ICEiIyQlJicoKSorLC0uLw==';

SharedSecretCredential _credential({
  String appId = _appId,
  String keyword = _keyword,
  String driverId = 'panasonic.viera',
}) => SharedSecretCredential(
  driverId: driverId,
  deviceId: 'tv',
  createdAt: DateTime.utc(2026),
  username: appId,
  secret: keyword,
);

WatchmeError _error(CommandResult r) => (r as Failed).error;

void main() {
  late PanasonicSimulator sim;
  late IoHttpTransports transports;
  final driver = PanasonicDriver(pollInterval: null);

  setUp(() => transports = IoHttpTransports());

  Future<PanasonicSimulator> startSim(PanasonicSimulator s) async {
    await s.start();
    addTearDown(s.stop);
    if (s.encrypted) s.addPairing(_appId, _keyword);
    return sim = s;
  }

  /// Connects (with the stored pairing on an encrypted TV) and clears the
  /// simulator's logs.
  Future<PanasonicSession> connect({
    bool allowWake = true,
    PanasonicDriver? using,
  }) async {
    final session = await (using ?? driver).connect(
      sim.endpoint,
      transports,
      sim.encrypted ? _credential() : null,
      allowWake: allowWake,
    ) as PanasonicSession;
    addTearDown(session.close);
    sim.clearLog();
    return session;
  }

  group('connect', () {
    test('a plain TV needs no credential and nothing is changed', () async {
      await startSim(PanasonicSimulator());
      final session = await driver.connect(sim.endpoint, transports, null);
      addTearDown(session.close);
      expect((session as PanasonicSession).encrypted, isFalse);
      expect(session.driverId, 'panasonic.viera');
      expect(session.model, 'TX-49DX600EA');
      expect(session.state.volume!.value, 20);
      expect(session.state.volume!.confidence, Confidence.reported);
      expect(session.state.muted!.value, isFalse);
      expect(session.state.connections, {
        'panasonic.viera': ConnectionState.connected,
      });
      // Reads only: descriptions, RenderingControl and the app info.
      expect(sim.keyLog, isEmpty);
      expect(sim.effects, isEmpty);
      expect(sim.actions, ['GetVolume', 'GetMute', 'X_GetAppInfo']);
    });

    test('allowWake: false sends the same passive requests', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      await driver.connect(sim.endpoint, transports, _credential());
      final woken = [
        for (final r in sim.requests)
          '${r.method} ${r.path} '
              '${r.effectiveAction}',
      ];
      sim.clearLog();
      final s = await driver.connect(
        sim.endpoint,
        transports,
        _credential(),
        allowWake: false,
      );
      addTearDown(s.close);
      expect([
        for (final r in sim.requests)
          '${r.method} ${r.path} '
              '${r.effectiveAction}',
      ], woken);
      expect(sim.keyLog, isEmpty);
      expect(sim.effects, isEmpty);
    });

    test('connecting to a TV in network standby does not wake it', () async {
      await startSim(
        PanasonicSimulator(
          encrypted: true,
          power: PanasonicSimPower.networkStandby,
        ),
      );
      final s = await connect(allowWake: false);
      expect(sim.power, PanasonicSimPower.networkStandby);
      expect(sim.keyLog, isEmpty);
      expect(s.state.power!.value, PowerMode.standby);
      expect(s.state.power!.confidence, Confidence.inferred);
    });

    test('an encrypted TV opens a session on connect', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      expect(s.encrypted, isTrue);
      expect(s.sessionsOpened, 1);
      expect(sim.sessionIds, hasLength(1));
    });

    test('an encrypted TV without a credential needs pairing', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unauthorized,
          ),
        ),
      );
      expect(sim.sessionsOpened, 0);
    });

    test('a credential of another driver is refused', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      await expectLater(
        driver.connect(
          sim.endpoint,
          transports,
          _credential(driverId: 'other.driver'),
        ),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unauthorized,
          ),
        ),
      );
    });

    test('a malformed stored keyword means pairing again', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      await expectLater(
        driver.connect(sim.endpoint, transports, _credential(keyword: 'x')),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.reauthRequired,
          ),
        ),
      );
    });

    test('a TV that is off the network is unreachable', () async {
      await startSim(PanasonicSimulator(power: PanasonicSimPower.standby));
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unreachable,
          ),
        ),
      );
    });

    test(
      'a deleted pairing is a re-pair only while the TV is known on',
      () async {
        await startSim(PanasonicSimulator(encrypted: true, pac: true));
        sim.forgetPairings();
        await expectLater(
          driver.connect(sim.endpoint, transports, _credential()),
          throwsA(
            isA<WatchmeError>().having(
              (e) => e.code,
              'code',
              WatchmeErrorCode.reauthRequired,
            ),
          ),
        );
        // Without PAC nothing proves the TV on: it may be in standby.
        sim.pac = false;
        await expectLater(
          driver.connect(sim.endpoint, transports, _credential()),
          throwsA(
            isA<WatchmeError>()
                .having((e) => e.code, 'code', WatchmeErrorCode.rejected)
                .having((e) => e.message, 'message', contains('pair again')),
          ),
        );
      },
    );

    test(
      'a session answer the keyword cannot decrypt means pairing again',
      () async {
        await startSim(PanasonicSimulator(encrypted: true));
        sim.respondOnce(
          'X_GetEncryptSessionId',
          status: 200,
          body: panasonicSimSoapAnswer(
            'X_GetEncryptSessionId',
            panasonicSimNrcUrn,
            [('X_EncResult', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')],
          ),
        );
        await expectLater(
          driver.connect(sim.endpoint, transports, _credential()),
          throwsA(
            isA<WatchmeError>().having(
              (e) => e.code,
              'code',
              WatchmeErrorCode.reauthRequired,
            ),
          ),
        );
      },
    );

    test('a client on another subnet is refused with the reason', () async {
      await startSim(PanasonicSimulator(allowedSubnet: '10.0.0.0/8'));
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsA(
          isA<WatchmeError>()
              .having((e) => e.code, 'code', WatchmeErrorCode.rejected)
              .having((e) => e.message, 'message', contains('own subnet')),
        ),
      );
    });
  });

  for (final encrypted in [false, true]) {
    group(encrypted ? 'encrypted TV' : 'plain TV', () {
      late PanasonicSession session;

      setUp(() async {
        await startSim(PanasonicSimulator(encrypted: encrypted, pac: true));
        session = await connect();
      });

      test('keys click NRC_{name}-ONOFF', () async {
        for (final key in [
          RemoteKey.up,
          RemoteKey.select,
          RemoteKey.back,
          RemoteKey.home,
          RemoteKey.guide,
          RemoteKey.red,
          RemoteKey.channelUp,
        ]) {
          expect(await session.execute(PressKey(key)), const Confirmed());
        }
        expect(sim.keyLog, [
          'NRC_UP-ONOFF',
          'NRC_ENTER-ONOFF',
          'NRC_RETURN-ONOFF',
          'NRC_HOME-ONOFF',
          'NRC_EPG-ONOFF',
          'NRC_RED-ONOFF',
          'NRC_CH_UP-ONOFF',
        ]);
        if (encrypted) {
          expect(sim.requests.map((r) => r.action).toSet(), {
            'X_EncryptedCommand',
          });
        }
      });

      test('unmappable keys and power commands are unsupported and send '
          'nothing', () async {
        for (final command in [
          const PressKey(RemoteKey.search),
          const PressKey(RemoteKey.playPause),
          const PressKey(RemoteKey.inputAv1),
          const PressKey(RemoteKey.powerOn),
          const PressKey(RemoteKey.powerOff),
          const PressKey(RemoteKey.power, KeyAction.down),
          const PressKey(RemoteKey.up, KeyAction.down),
          const SetPower(true),
          const SetPower(false, userConfirmed: true),
          const MovePointer(1, 1),
          const ShowToast('hi'),
          CastUrl(Uri.parse('http://example.invalid/a.mp4')),
          const TakeScreenshot(),
          const Media(MediaAction.playPause),
          Media(MediaAction.seek, seekTo: const Duration(seconds: 3)),
          const TuneChannel('7.1'),
          const TuneChannel(''),
          const TypeText('x', replace: true),
          const SelectInput('av1'),
          const SelectInput('bogus'),
          LaunchApp('0010000200000001', deepLink: Uri.parse('x:y')),
          const LaunchApp('not an id!'),
        ]) {
          expect(
            await session.execute(command),
            isA<Unsupported>(),
            reason: '$command',
          );
        }
        expect(sim.requests, isEmpty);
      });

      test('volume and mute go to RenderingControl, plain, and are read '
          'back', () async {
        expect(await session.execute(const SetVolume(30)), const Confirmed());
        expect(sim.volume, 30);
        expect(session.state.volume!.value, 30);
        expect(session.state.volume!.confidence, Confidence.reported);
        expect(await session.execute(const StepVolume(-5)), const Confirmed());
        expect(sim.volume, 25);
        expect(await session.execute(const StepVolume(500)), const Confirmed());
        expect(sim.volume, 100);
        expect(await session.execute(const SetMute(true)), const Confirmed());
        expect(sim.muted, isTrue);
        expect(await session.execute(const SetMute(null)), const Confirmed());
        expect(sim.muted, isFalse);
        expect(session.state.muted!.value, isFalse);
        expect(sim.requests.map((r) => r.path).toSet(), {'/dmr/control_0'});
        expect(sim.keyLog, isEmpty);
        sim.clearLog();
        expect(await session.execute(const StepVolume(0)), const Confirmed());
        expect(sim.requests, isEmpty);
      });

      test('apps: list with icons, launch by product id, foreground', () async {
        final listed = await session.execute(const ListApps());
        final apps = ((listed as Confirmed).payload! as AppListPayload).apps;
        expect(apps.map((a) => a.name), contains('Netflix'));
        final netflix = apps.firstWhere((a) => a.name == 'Netflix');
        expect(netflix.id, '0010000200000001');
        expect(
          netflix.icon.toString(),
          'http://${sim.host}:${sim.port}/nrc/app_icon/0010000200000001',
        );
        expect(session.state.power!.value, PowerMode.on);
        expect(await session.execute(LaunchApp(netflix.id)), const Confirmed());
        expect(sim.foregroundAppId, netflix.id);
        expect(session.state.foregroundApp!.value.name, 'Netflix');
        final launch = sim.requests.lastWhere(
          (r) => r.effectiveAction == 'X_LaunchApp',
        );
        if (!encrypted) {
          expect(
            launch.body,
            contains(
              '<X_LaunchKeyword>product_id=0010000200000001'
              '</X_LaunchKeyword>',
            ),
          );
        }
        final unknown = await session.execute(
          const LaunchApp('9999999999999999'),
        );
        expect(_error(unknown).code, WatchmeErrorCode.rejected);
        expect(_error(unknown).rawDeviceMessage, contains('501'));
      });

      test('an empty app list is standby, not "no apps"', () async {
        await sim.setPower(PanasonicSimPower.networkStandby);
        final r = await session.execute(const ListApps());
        expect(r, isA<Unsupported>());
        expect((r as Unsupported).reason, contains('standby'));
        expect(session.state.power!.value, PowerMode.standby);
        expect(session.state.power!.confidence, Confidence.inferred);
      });

      test('inputs: keys for HDMI and TV, PAC codes on PAC models', () async {
        expect(
          await session.execute(const SelectInput('hdmi2')),
          const Confirmed(),
        );
        expect(sim.input, 'H2');
        expect(session.state.input!.value, 'hdmi2');
        expect(
          await session.execute(const SelectInput('tv')),
          const Confirmed(),
        );
        expect(sim.input, 'TV');
        expect(session.hasPac, isTrue);
        expect(
          await session.execute(const SelectInput('H3')),
          const Confirmed(),
        );
        expect(sim.input, 'H3');
        expect(sim.keyLog, ['NRC_HDMI2-ONOFF', 'NRC_TV-ONOFF']);
        // One input has one id, however it was selected or read: the Pro
        // AV code H3 is the input the key path calls hdmi3.
        expect(session.state.input!.value, 'hdmi3');
        sim.input = 'H2';
        expect((await session.refresh()).input!.value, 'hdmi2');
        expect(
          await session.execute(const SelectInput('hdmi2')),
          const Confirmed(),
        );
        final changes = <StateChanged>[];
        final sub = session.events.listen((e) {
          if (e is StateChanged) changes.add(e);
        });
        await session.refresh();
        await sub.cancel();
        expect(session.state.input!.value, 'hdmi2');
        expect(changes.where((c) => c.state.input?.value == 'H2'), isEmpty);
      });

      test(
        'the input and home keys leave no stale input or app behind',
        () async {
          sim.input = 'H1';
          await session.refresh();
          expect(session.state.input!.confidence, Confidence.reported);
          // NRC_CHG_INPUT cycles to an input watchme cannot know.
          expect(
            await session.execute(const PressKey(RemoteKey.input)),
            const Confirmed(),
          );
          expect(sim.input, 'H2');
          expect(session.state.input!.confidence, Confidence.stale);
          expect(
            await session.execute(const LaunchApp('0010000200000001')),
            const Confirmed(),
          );
          expect(session.state.foregroundApp!.value.id, '0010000200000001');
          // HOME leaves the app for the home screen.
          expect(
            await session.execute(const PressKey(RemoteKey.home)),
            const Confirmed(),
          );
          expect(sim.foregroundAppId, isNull);
          expect(session.state.foregroundApp!.confidence, Confidence.stale);
        },
      );

      test('channel digits, text and media keys', () async {
        expect(
          await session.execute(const TuneChannel('123')),
          const Confirmed(),
        );
        expect(sim.channelDigits, '123');
        sim.keyboardOpen = true;
        expect(
          await session.execute(const TypeText('a<b & "c"')),
          const Confirmed(),
        );
        expect(sim.typedText, 'a<b & "c"');
        expect(
          await session.execute(const Media(MediaAction.pause)),
          const Confirmed(),
        );
        expect(await session.execute(const TypeText('')), const Confirmed());
        expect(sim.keyLog, [
          'NRC_D1-ONOFF',
          'NRC_D2-ONOFF',
          'NRC_D3-ONOFF',
          'NRC_PAUSE-ONOFF',
        ]);
      });

      test('refresh reads volume, mute, input and the foreground app, and '
          'sends no key', () async {
        sim
          ..volume = 44
          ..muted = true
          ..input = 'H4'
          ..foregroundAppId = '0070000200180001';
        final state = await session.refresh();
        expect(state.volume!.value, 44);
        expect(state.muted!.value, isTrue);
        expect(state.input!.value, 'hdmi4');
        expect(state.input!.confidence, Confidence.reported);
        expect(state.foregroundApp!.value.id, '0070000200180001');
        expect(state.foregroundApp!.value.name, 'YouTube');
        expect(state.power!.value, PowerMode.on);
        expect(state.power!.confidence, Confidence.inferred);
        expect(sim.keyLog, isEmpty);
      });
    });
  }

  group('power toggle', () {
    test('a plain TV gets exactly one NRC_POWER-ONOFF', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      expect(
        await s.execute(const PressKey(RemoteKey.power)),
        const Confirmed(),
      );
      expect(sim.keyLog, ['NRC_POWER-ONOFF']);
      expect(sim.powerToggles, 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sim.power, PanasonicSimPower.networkStandby);
    });

    test(
      'an encrypted TV gets a fresh session right before the toggle',
      () async {
        await startSim(PanasonicSimulator(encrypted: true));
        final s = await connect();
        expect(s.sessionsOpened, 1);
        expect(
          await s.execute(const PressKey(RemoteKey.power)),
          const Confirmed(),
        );
        expect(s.sessionsOpened, 2);
        expect(sim.actions, ['X_GetEncryptSessionId', 'X_SendKey']);
        expect(sim.powerToggles, 1);
      },
    );

    test('a session invalidated by the last power change never reaches '
        'the toggle', () async {
      await startSim(
        PanasonicSimulator(encrypted: true, bootDelay: Duration.zero),
      );
      final s = await connect();
      // Switched off and on with the TV's own remote: every session died.
      await sim.pressPowerButton();
      await sim.pressPowerButton();
      expect(sim.sessionIds, isEmpty);
      expect(
        await s.execute(const PressKey(RemoteKey.power)),
        const Confirmed(),
      );
      expect(sim.powerToggles, 1);
      expect(
        sim.requests.where((r) => r.innerAction == 'X_SendKey'),
        hasLength(1),
      );
    });

    test('a refused toggle (500) is rejected and never resent', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim.respondOnce('X_SendKey', status: 500);
      final r = await s.execute(const PressKey(RemoteKey.power));
      expect(_error(r).code, WatchmeErrorCode.rejected);
      expect(_error(r).message, contains('not resent'));
      expect(sim.powerToggles, 0);
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
    });

    test('a toggle that may have reached the TV is a timeout and is not '
        'resent', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim.dropNext('X_SendKey');
      final r = await s.execute(const PressKey(RemoteKey.power));
      expect(_error(r).code, WatchmeErrorCode.timeout);
      expect(sim.powerToggles, 1);
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
    });

    test('a toggle that may have acted leaves no fresh power state behind, '
        'plain or encrypted', () async {
      for (final encrypted in [false, true]) {
        await startSim(PanasonicSimulator(encrypted: encrypted, pac: true));
        final s = await connect();
        expect(s.state.power!.value, PowerMode.on);
        sim.dropNext('X_SendKey');
        final r = await s.execute(const PressKey(RemoteKey.power));
        expect(_error(r).code, WatchmeErrorCode.timeout);
        // The TV may have switched off: "on" from before is no evidence.
        expect(s.state.power!.confidence, Confidence.stale);
      }
    });

    for (final (what, fail) in [
      (
        'refused',
        (PanasonicSimulator s) =>
            s.respondOnce('X_GetEncryptSessionId', status: 500),
      ),
      (
        'dropped',
        (PanasonicSimulator s) => s.dropNext('X_GetEncryptSessionId'),
      ),
    ]) {
      test('a fresh session that is $what keeps the toggle from being '
          'sent, and says nothing was delivered', () async {
        await startSim(PanasonicSimulator(encrypted: true));
        final s = await connect();
        fail(sim);
        final r = await s.execute(const PressKey(RemoteKey.power));
        final e = _error(r);
        expect(e.code, WatchmeErrorCode.rejected);
        expect(e.message, startsWith('The power toggle was not sent'));
        expect(r.partiallyDelivered, isFalse);
        expect(sim.keyLog, isEmpty);
        expect(sim.powerToggles, 0);
      });
    }

    test('after the toggle the next command opens a fresh session', () async {
      await startSim(
        PanasonicSimulator(encrypted: true, bootDelay: Duration.zero),
      );
      final s = await connect();
      await s.execute(const PressKey(RemoteKey.power));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      sim.clearLog();
      expect(
        await s.execute(const PressKey(RemoteKey.home)),
        const Confirmed(),
      );
      expect(sim.actions, ['X_GetEncryptSessionId', 'X_SendKey']);
    });
  });

  group('encrypted sessions', () {
    test('an expired session is reopened and the refused command resent '
        'once', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim.expireAllSessions();
      expect(
        await s.execute(const PressKey(RemoteKey.info)),
        const Confirmed(),
      );
      expect(sim.keyLog, ['NRC_INFO-ONOFF']);
      expect(sim.actions, ['X_SendKey', 'X_GetEncryptSessionId', 'X_SendKey']);
      expect(s.sessionsOpened, 2);
    });

    test('commands are wrapped in X_EncryptedCommand; the first after a '
        'session carries sequence 2', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      await driver.connect(sim.endpoint, transports, _credential());
      // Connecting read the foreground app: the first command (2).
      final sid = sim.sessionIds.single;
      expect(sim.lastSequence(sid), 2);
      final wrapped = sim.requests.lastWhere(
        (r) => r.action == 'X_EncryptedCommand',
      );
      expect(wrapped.innerAction, 'X_GetAppInfo');
      expect(
        wrapped.header('SOAPACTION'),
        '"urn:panasonic-com:service:p00NetworkControl:1#X_EncryptedCommand"',
      );
      expect(
        wrapped.body,
        contains('<X_ApplicationId>$_appId</X_ApplicationId><X_EncInfo>'),
      );
      expect(wrapped.body, isNot(contains('X_GetAppInfo')));
    });

    test('a UPnP 401 inside an encrypted session is a refusal, not a call '
        'to pair', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      for (var i = 0; i < 2; i++) {
        sim.respondOnce(
          'X_SendKey',
          status: 500,
          body: panasonicSimFault(401, 'Invalid Action'),
        );
      }
      final r = await s.execute(const PressKey(RemoteKey.up));
      expect(_error(r).code, WatchmeErrorCode.unsupported);
      expect(sim.keyLog, isEmpty);
    });

    test('a second refusal is rejected; the command did not run', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim
        ..respondOnce('X_SendKey', status: 500)
        ..respondOnce('X_SendKey', status: 500);
      final r = await s.execute(const PressKey(RemoteKey.info));
      expect(_error(r).code, WatchmeErrorCode.rejected);
      expect(sim.keyLog, isEmpty);
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(2));
    });

    test('a command that may have been delivered is never resent', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim.dropNext('X_SendKey');
      final r = await s.execute(const PressKey(RemoteKey.volumeUp));
      expect(_error(r).code, WatchmeErrorCode.timeout);
      expect(sim.keyLog, ['NRC_VOLUP-ONOFF']);
      expect(sim.actions.where((a) => a == 'X_SendKey'), hasLength(1));
    });

    test(
      'sequence numbers only grow; concurrent commands are serialised',
      () async {
        await startSim(
          PanasonicSimulator(
            encrypted: true,
            latency: const Duration(milliseconds: 5),
          ),
        );
        final s = await connect();
        final sid = sim.sessionIds.single;
        final before = sim.lastSequence(sid)!;
        final results = await Future.wait([
          for (var i = 0; i < 8; i++)
            s.execute(const PressKey(RemoteKey.right)),
        ]);
        expect(results, everyElement(const Confirmed()));
        expect(sim.lastSequence(sid), before + 8);
        expect(sim.keyLog, hasLength(8));
      },
    );

    test('answers wrapped in X_OriginalResult, or without the HMAC, still '
        'decode; a missing HMAC is counted', () async {
      await startSim(
        PanasonicSimulator(encrypted: true, wrapEncryptedAnswers: true),
      );
      final s = await connect();
      expect(await s.execute(const ListApps()), isA<Confirmed>());
      sim.encryptedAnswerMac = false;
      expect(s.macFailures, 0);
      expect(await s.execute(const ListApps()), isA<Confirmed>());
      expect(s.macFailures, 1);
    });

    test('an accepted command whose answer cannot be decrypted is a '
        'protocol error: it ran', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      sim.respondOnce(
        'X_SendKey',
        status: 200,
        body: panasonicSimSoapAnswer('X_EncryptedCommand', panasonicSimNrcUrn, [
          ('X_EncResult', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='),
        ]),
      );
      final r = await s.execute(const PressKey(RemoteKey.up));
      expect(_error(r).code, WatchmeErrorCode.protocol);
      expect(r.partiallyDelivered, isFalse);
    });

    test(
      'a pairing deleted while connected: a re-pair, reported once',
      () async {
        await startSim(PanasonicSimulator(encrypted: true, pac: true));
        final s = await connect();
        final events = <DeviceEvent>[];
        s.events.listen(events.add);
        sim
          ..forgetPairings()
          ..expireAllSessions();
        final r = await s.execute(const PressKey(RemoteKey.up));
        expect(_error(r).code, WatchmeErrorCode.reauthRequired);
        final again = await s.execute(const PressKey(RemoteKey.up));
        expect(_error(again).code, WatchmeErrorCode.reauthRequired);
        await Future<void>.delayed(Duration.zero);
        expect(events.whereType<ReauthRequired>(), hasLength(1));
        expect(
          events.whereType<ConnectionChanged>().single.state,
          ConnectionState.failed,
        );
      },
    );
  });

  group('answers that are not an acknowledgement', () {
    /// An encrypted answer whose sealed fragment is [inner].
    String sealed(String inner) => panasonicSimSoapAnswer(
      'X_EncryptedCommand',
      panasonicSimNrcUrn,
      [('X_EncResult', vieraSeal(VieraKeys.forSession(_keyword), inner))],
    );

    test('a plain 200 that is no answer to the action is a protocol error, '
        'never Confirmed', () async {
      await startSim(PanasonicSimulator(pac: true));
      final s = await connect();
      for (final (target, command, body) in [
        ('X_SendKey', const PressKey(RemoteKey.up), '<html>Busy</html>'),
        ('X_SendKey', const PressKey(RemoteKey.up), ''),
        ('X_SendKey', const PressKey(RemoteKey.up), 'OK'),
        (
          'X_SendKey',
          const PressKey(RemoteKey.up),
          panasonicSimSoapAnswer('X_LaunchApp', panasonicSimNrcUrn),
        ),
        (
          'X_LaunchApp',
          const LaunchApp('0010000200000001'),
          '<html>Busy</html>',
        ),
        ('X_SendString', const TypeText('abc'), '<html>Busy</html>'),
        ('SetVolume', const SetVolume(30), '<html>Busy</html>'),
        ('SetMute', const SetMute(true), '<html>Busy</html>'),
        ('X_SendCtrlCmd', const SelectInput('H3'), '<html>Busy</html>'),
      ]) {
        sim.respondOnce(target, status: 200, body: body);
        final r = await s.execute(command);
        expect(_error(r).code, WatchmeErrorCode.protocol, reason: target);
        expect(_error(r).message, contains('not an answer'), reason: target);
        if (body.isNotEmpty) {
          expect(_error(r).rawDeviceMessage, contains(body.substring(0, 2)));
        }
      }
      expect(sim.keyLog, isEmpty);
      expect(sim.effects, isEmpty);
    });

    test('an encrypted answer that decrypts to anything but the answer is a '
        'protocol error, and the command is not resent', () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      final inners = [
        'this is not a SOAP result',
        '',
        '<html>Busy</html>',
        '<u:X_LaunchAppResponse xmlns:u="x"></u:X_LaunchAppResponse>',
      ];
      for (final inner in inners) {
        sim.respondOnce('X_SendKey', status: 200, body: sealed(inner));
        final r = await s.execute(const PressKey(RemoteKey.up));
        expect(_error(r).code, WatchmeErrorCode.protocol, reason: inner);
        expect(r.partiallyDelivered, isFalse);
        // The decrypted text never reaches an error.
        expect(_error(r).rawDeviceMessage, contains('<redacted>'));
        expect('${_error(r)}', isNot(contains('not a SOAP')));
      }
      expect(sim.keyLog, isEmpty);
      expect(sim.actions, List.filled(inners.length, 'X_SendKey'));
      expect(s.sessionsOpened, 1);
    });

    for (final encrypted in [false, true]) {
      test('one stops a multi-key command, which was partly delivered '
          '(${encrypted ? 'encrypted' : 'plain'})', () async {
        await startSim(PanasonicSimulator(encrypted: encrypted));
        final s = await connect();
        final gate = sim.holdNext('X_SendKey');
        final result = s.execute(const TuneChannel('123'));
        await gate.reached;
        sim.respondOnce(
          'X_SendKey',
          status: 200,
          body: encrypted ? sealed('Busy') : '<html>Busy</html>',
        );
        gate.release();
        final e = _error(await result);
        expect(e.code, WatchmeErrorCode.partiallyDelivered);
        expect((e.cause! as WatchmeError).code, WatchmeErrorCode.protocol);
        expect(sim.keyLog, ['NRC_D1-ONOFF']);
        expect(sim.actions, ['X_SendKey', 'X_SendKey']);
      });
    }

    for (final encrypted in [false, true]) {
      test('text that only looks like an acknowledgement (an unterminated '
          'comment, a truncated document, an HTML page, the element outside '
          'the SOAP Body) confirms no digit, and no further digit is sent '
          '(${encrypted ? 'encrypted' : 'plain'})', () async {
        const urn = panasonicSimNrcUrn;
        await startSim(PanasonicSimulator(encrypted: encrypted));
        final s = await connect();
        final keys = VieraKeys.forSession(_keyword);
        final bodies = encrypted
            ? [
                for (final inner in [
                  '<!-- diagnostic example: <X_SendKeyResponse/>',
                  '<X_OriginalResult><u:X_SendKeyResponse xmlns:u="$urn"/>',
                  '<u:X_SendKeyResponse xmlns:u="$urn"></u:X_SendKeyResponse><',
                  '<html><body><X_SendKeyResponse/></body></html>',
                  '<html><body><br><X_SendKeyResponse/></body></html>',
                  // Codex round three: not well-formed XML, though the
                  // parser reads it, and an answer under a Body that is
                  // no SOAP Body.
                  '<u:X_SendKeyResponse xmlns:u="$urn">&</u:X_SendKeyResponse>',
                  '<u:X_SendKeyResponse xmlns:u="$urn">&nbsp;'
                      '</u:X_SendKeyResponse>',
                  '<u:X_SendKeyResponse a="1" a="2" xmlns:u="$urn"/>',
                  '<!-- a -- b --><u:X_SendKeyResponse xmlns:u="$urn"/>',
                  '<u:X_SendKeyResponse xmlns:u="$urn">\u0001'
                      '</u:X_SendKeyResponse>',
                  '<html><diagnostic><Body><X_SendKeyResponse/></Body>'
                      '</diagnostic></html>',
                  // Codex round four: references to characters XML forbids,
                  // and attribute and text grammar the parser lets through.
                  for (final inside in _notXml)
                    '<u:X_SendKeyResponse xmlns:u="$urn">$inside'
                        '</u:X_SendKeyResponse>',
                  for (final attribute in _badAttributes)
                    '<u:X_SendKeyResponse xmlns:u="$urn" $attribute/>',
                  // Codex round five: a malformed XML declaration.
                  for (final declaration in _badDeclarations)
                    '$declaration<u:X_SendKeyResponse xmlns:u="$urn"/>',
                ])
                  sealed(inner),
                // A genuine acknowledgement in a truncated outer answer.
                '<s:Envelope><s:Body><u:X_EncryptedCommandResponse>'
                    '<X_EncResult>'
                    '${vieraSeal(keys, '<u:X_SendKeyResponse xmlns:u="$urn"/>')}'
                    '</X_EncResult>',
              ]
            : [
                '<!-- diagnostic example: <X_SendKeyResponse/>',
                '<s:Envelope><s:Body><u:X_SendKeyResponse/>',
                '<html><body><h1>Error</h1><X_SendKeyResponse/></body></html>',
                '<html><body><br><X_SendKeyResponse/></body></html>',
                '<s:Envelope><s:Header><u:X_SendKeyResponse/></s:Header>'
                    '<s:Body/></s:Envelope>',
                '<s:Envelope><s:Body><u:X_SendKeyResponse/></s:Body>'
                    '</s:Envelope>trailing text',
                // Codex round three: not well-formed XML, though the parser
                // reads it.
                '<s:Envelope><s:Body><u:X_SendKeyResponse>&'
                    '</u:X_SendKeyResponse></s:Body></s:Envelope>',
                '<s:Envelope><s:Body><u:X_SendKeyResponse>&nbsp;'
                    '</u:X_SendKeyResponse></s:Body></s:Envelope>',
                '<s:Envelope a="1" a="2"><s:Body><u:X_SendKeyResponse/>'
                    '</s:Body></s:Envelope>',
                '<!-- a -- b --><s:Envelope><s:Body><u:X_SendKeyResponse/>'
                    '</s:Body></s:Envelope>',
                '<s:Envelope><s:Body><u:X_SendKeyResponse>\u0001'
                    '</u:X_SendKeyResponse></s:Body></s:Envelope>',
                // Codex round four.
                for (final inside in _notXml)
                  '<s:Envelope><s:Body><u:X_SendKeyResponse>$inside'
                      '</u:X_SendKeyResponse></s:Body></s:Envelope>',
                for (final attribute in _badAttributes)
                  '<s:Envelope><s:Body><u:X_SendKeyResponse $attribute/>'
                      '</s:Body></s:Envelope>',
                // Codex round five.
                for (final declaration in _badDeclarations)
                  '$declaration\n<s:Envelope><s:Body><u:X_SendKeyResponse/>'
                      '</s:Body></s:Envelope>',
              ];
        for (final body in bodies) {
          sim.clearLog();
          sim.respondOnce('X_SendKey', status: 200, body: body);
          final r = await s.execute(const TuneChannel('123'));
          expect(_error(r).code, WatchmeErrorCode.protocol, reason: body);
          expect(r.partiallyDelivered, isFalse, reason: body);
          // Digit 1 is unconfirmed, so digits 2 and 3 never go out.
          expect(sim.actions, ['X_SendKey'], reason: body);
          expect(sim.keyLog, isEmpty, reason: body);
        }
        // Never resent on a fresh session either.
        expect(s.sessionsOpened, encrypted ? 1 : 0);
      });
    }

    test('a read takes its value from a well-formed answer only: a '
        'truncated GetVolume reports no level, and no step is sent', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      expect(s.state.volume!.value, 20);
      const truncated =
          '<s:Envelope><s:Body><u:GetVolumeResponse>'
          '<CurrentVolume>55</CurrentVolume>';
      sim.respondOnce('GetVolume', status: 200, body: truncated);
      await s.refresh();
      expect(s.state.volume!.value, 20);
      sim.respondOnce('GetVolume', status: 200, body: truncated);
      final r = await s.execute(const StepVolume(1));
      expect(_error(r).code, WatchmeErrorCode.protocol);
      expect(sim.effects, isEmpty);
    });

    test(
      'an encrypted read needs only its output leaf, anywhere in a '
      'well-formed fragment; an effect still needs its acknowledgement',
      () async {
        await startSim(PanasonicSimulator(encrypted: true));
        final s = await connect();
        const list =
            'vc_app&apos;Stop&apos;product_id=0010000200000001&apos;Netflix'
            '&apos;http://h/i&apos;Unknown';
        for (final inner in [
          '<X_AppList>$list</X_AppList>',
          '<X_OriginalResult><X_AppList>$list</X_AppList></X_OriginalResult>',
          '<X_SessionId>1</X_SessionId>\r\n<X_SequenceNumber>00000002'
              '</X_SequenceNumber>\r\n<X_AppList>$list</X_AppList>',
          '<v:X_Result><v:X_AppList>$list</v:X_AppList></v:X_Result>',
        ]) {
          sim.respondOnce('X_GetAppList', status: 200, body: sealed(inner));
          final r = await s.execute(const ListApps());
          expect(r, isA<Confirmed>(), reason: inner);
          final apps = ((r as Confirmed).payload! as AppListPayload).apps;
          expect(apps.single.id, '0010000200000001', reason: inner);
          expect(apps.single.name, 'Netflix', reason: inner);
        }
        sim.respondOnce(
          'X_GetAppInfo',
          status: 200,
          body: sealed(
            '<X_AppInfo>vc_app:1:product_id=0070000200000001:YouTube'
            '</X_AppInfo>',
          ),
        );
        await s.refresh();
        expect(s.state.foregroundApp!.value.id, '0070000200000001');
        expect(s.state.foregroundApp!.confidence, Confidence.reported);
        // A malformed fragment, the leaf only in a comment, no leaf, a leaf
        // holding elements, or the answer element alone prove nothing.
        for (final inner in [
          '<X_AppList>$list',
          '<!-- <X_AppList>$list</X_AppList> -->',
          '<X_Other>$list</X_Other>',
          '<X_AppList><b>$list</b></X_AppList>',
          '<u:X_GetAppListResponse xmlns:u="x"></u:X_GetAppListResponse>',
        ]) {
          sim.respondOnce('X_GetAppList', status: 200, body: sealed(inner));
          final r = await s.execute(const ListApps());
          expect(_error(r).code, WatchmeErrorCode.protocol, reason: inner);
          expect('${_error(r)}', isNot(contains('Netflix')), reason: inner);
        }
        // An effect's answer must still acknowledge it.
        sim.respondOnce(
          'X_LaunchApp',
          status: 200,
          body: sealed('<X_SessionId>1</X_SessionId>'),
        );
        final launch = await s.execute(const LaunchApp('0010000200000001'));
        expect(_error(launch).code, WatchmeErrorCode.protocol);
        expect(sim.effects, isEmpty);
        expect(s.sessionsOpened, 1);
      },
    );

    test('the documented shapes are accepted: any prefix or none, '
        'self-closing, and an encrypted fragment bare, under a root or in '
        'X_OriginalResult, with or without an envelope', () async {
      const urn = panasonicSimNrcUrn;
      await startSim(PanasonicSimulator());
      var s = await connect();
      for (final body in [
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><m:X_SendKeyResponse xmlns:m="$urn"/></s:Body>'
            '</s:Envelope>',
        '<s:Envelope><s:Body><u:X_SendKeyResponse></u:X_SendKeyResponse>'
            '</s:Body></s:Envelope>',
        '<Envelope><Body>\r\n<X_SendKeyResponse>\r\n</X_SendKeyResponse>'
            '</Body></Envelope>',
      ]) {
        sim.respondOnce('X_SendKey', status: 200, body: body);
        expect(
          await s.execute(const PressKey(RemoteKey.up)),
          const Confirmed(),
          reason: body,
        );
      }
      await startSim(PanasonicSimulator(encrypted: true));
      s = await connect();
      final keys = VieraKeys.forSession(_keyword);
      for (final inner in [
        '<u:X_SendKeyResponse xmlns:u="$urn"></u:X_SendKeyResponse>',
        '<X_OriginalResult><u:X_SendKeyResponse xmlns:u="$urn">'
            '</u:X_SendKeyResponse></X_OriginalResult>',
        '<X_SessionId>1</X_SessionId>\r\n<X_SequenceNumber>00000002'
            '</X_SequenceNumber>\r\n<X_OriginalResult><u:X_SendKeyResponse>'
            '</u:X_SendKeyResponse></X_OriginalResult>',
        '<X_Data><X_SendKeyResponse/></X_Data>',
      ]) {
        for (final body in [
          sealed(inner),
          '<X_EncResult>${vieraSeal(keys, inner)}</X_EncResult>',
        ]) {
          sim.respondOnce('X_SendKey', status: 200, body: body);
          expect(
            await s.execute(const PressKey(RemoteKey.up)),
            const Confirmed(),
            reason: body,
          );
        }
      }
    });
  });

  group('delivery', () {
    test('a multi-key command that fails after a delivered key is '
        'partiallyDelivered and stops', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      final gate = sim.holdNext('X_SendKey');
      final result = s.execute(const TuneChannel('123'));
      await gate.reached;
      sim.dropNext('X_SendKey', execute: false);
      gate.release();
      final r = await result;
      final e = _error(r);
      expect(e.code, WatchmeErrorCode.partiallyDelivered);
      expect((e.cause! as WatchmeError).code, WatchmeErrorCode.timeout);
      expect(sim.channelDigits, '1');
      expect(sim.keyLog, ['NRC_D1-ONOFF']);
    });

    test('a TV that goes away mid-command: partiallyDelivered, cause '
        'unreachable', () async {
      await startSim(PanasonicSimulator(poweredOnByApps: false));
      final s = await connect();
      final gate = sim.holdNext('X_SendKey');
      final result = s.execute(const TuneChannel('42'));
      await gate.reached;
      await sim.setPower(PanasonicSimPower.standby);
      gate.release();
      final e = _error(await result);
      expect(e.code, WatchmeErrorCode.partiallyDelivered);
      expect((e.cause! as WatchmeError).code, WatchmeErrorCode.unreachable);
    });

    test('a command that reached nothing is unreachable', () async {
      await startSim(PanasonicSimulator(poweredOnByApps: false));
      final s = await connect();
      await sim.setPower(PanasonicSimPower.standby);
      final r = await s.execute(const TuneChannel('42'));
      expect(_error(r).code, WatchmeErrorCode.unreachable);
    });

    test('close stops a command before its next request', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      final gate = sim.holdNext('X_SendKey');
      final result = s.execute(const TuneChannel('987'));
      await gate.reached;
      final closing = s.close();
      gate.release();
      await closing;
      final e = _error(await result);
      expect(e.code, WatchmeErrorCode.partiallyDelivered);
      expect((e.cause! as WatchmeError).code, WatchmeErrorCode.cancelled);
      expect(sim.keyLog, ['NRC_D9-ONOFF']);
      expect(
        _error(await s.execute(const PressKey(RemoteKey.up))).code,
        WatchmeErrorCode.cancelled,
      );
      await expectLater(s.refresh(), throwsA(isA<WatchmeError>()));
    });
  });

  group('close while a request is out', () {
    final cancelled = throwsA(
      isA<WatchmeError>().having(
        (e) => e.code,
        'code',
        WatchmeErrorCode.cancelled,
      ),
    );

    test('during a refresh: the late answer is not used and nothing more '
        'is sent, not even the Pro AV read', () async {
      await startSim(PanasonicSimulator(pac: true));
      final s = await connect();
      sim.volume = 55;
      final gate = sim.holdNext('GetVolume');
      final refreshing = expectLater(s.refresh(), cancelled);
      await gate.reached;
      await s.close();
      sim.clearLog();
      gate.release();
      await refreshing;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.requests, isEmpty);
      expect(s.state.volume!.value, 20);
    });

    for (final target in ['GetMute', 'X_SendInquiryCmd']) {
      test('during a refresh at $target: it fails as cancelled, uses no '
          'late answer and sends nothing more', () async {
        await startSim(PanasonicSimulator(pac: true));
        final s = await connect();
        sim.input = 'H4';
        final gate = sim.holdNext(target);
        final refreshing = expectLater(s.refresh(), cancelled);
        await gate.reached;
        await s.close();
        sim.clearLog();
        gate.release();
        await refreshing;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sim.requests, isEmpty);
        expect(s.state.input!.value, 'tv');
      });
    }

    test('during the Pro AV read: its answer is not used', () async {
      await startSim(
        PanasonicSimulator(
          pac: true,
          power: PanasonicSimPower.networkStandby,
          dmrAnswersInStandby: true,
          bootDelay: Duration.zero,
        ),
      );
      final s = await connect(allowWake: false);
      final capabilities = s.capabilities;
      expect(s.hasPac, isFalse);
      await sim.pressPowerButton();
      final gate = sim.holdNext('/pac/ddd.xml');
      final refreshing = expectLater(s.refresh(), cancelled);
      await gate.reached;
      await s.close();
      sim.clearLog();
      gate.release();
      await refreshing;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(s.hasPac, isFalse);
      expect(s.capabilities, capabilities);
      expect(sim.requests, isEmpty);
    });

    test('while the fresh session before a toggle is refused: no Pro AV '
        'read and no toggle follow, and nothing was done', () async {
      await startSim(PanasonicSimulator(encrypted: true, pac: true));
      final s = await connect();
      sim.respondOnce('X_GetEncryptSessionId', status: 500);
      final gate = sim.holdNext('X_GetEncryptSessionId');
      final result = s.execute(const PressKey(RemoteKey.power));
      await gate.reached;
      await s.close();
      sim.clearLog();
      gate.release();
      final r = await result;
      expect(_error(r).code, WatchmeErrorCode.cancelled);
      expect(r.partiallyDelivered, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.requests, isEmpty);
      expect(sim.powerToggles, 0);
    });
  });

  group('errors', () {
    test('403 on RenderingControl: the subnet reason, and no fallback to '
        'volume keys', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      sim.allowedSubnet = '10.0.0.0/8';
      final r = await s.execute(const StepVolume(2));
      expect(_error(r).code, WatchmeErrorCode.rejected);
      expect(_error(r).message, contains('own subnet'));
      expect(_error(r).rawDeviceMessage, 'HTTP 403');
      expect(sim.keyLog, isEmpty);
    });

    test('400 from RenderingControl in standby: rejected, no keys', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      await sim.setPower(PanasonicSimPower.networkStandby);
      final r = await s.execute(const SetVolume(10));
      expect(_error(r).code, WatchmeErrorCode.rejected);
      expect(_error(r).message, contains('standby'));
      expect(sim.keyLog, isEmpty);
    });

    test('an out-of-range volume answer keeps the TV text', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      sim.respondOnce(
        'SetVolume',
        status: 500,
        body: panasonicSimFault(601, 'Argument Value Out of Range'),
      );
      final r = await s.execute(const SetVolume(50));
      expect(_error(r).message, contains('UPnP error 601'));
      expect(_error(r).rawDeviceMessage, contains('Out of Range'));
    });

    test(
      'UPnP 401 on a plain TV: unsupported, or a pairing for X_SendKey',
      () async {
        final tv = FakeViera(encrypted: false);
        tv.handlers['X_SendKey'] = (_) =>
            FakeViera.fault(401, 'Invalid Action');
        tv.handlers['X_GetAppList'] = (_) =>
            FakeViera.fault(401, 'Invalid Action');
        final s = await driver.connect(tv.endpoint, tv.transports, null);
        addTearDown(s.close);
        expect(
          _error(await s.execute(const PressKey(RemoteKey.up))).code,
          WatchmeErrorCode.unauthorized,
        );
        expect(
          _error(await s.execute(const ListApps())).code,
          WatchmeErrorCode.unsupported,
        );
      },
    );
  });

  test('an answer with an impossible character reference is no crash: '
      'connect, refresh and commands fail only with WatchmeError', () async {
    final tv = FakeViera(encrypted: false);
    tv.handlers['GetVolume'] = (_) => HttpResult.text(
      200,
      '<s:Envelope><s:Body><u:GetVolumeResponse>'
      '<CurrentVolume>&#x110000;</CurrentVolume></u:GetVolumeResponse>'
      '</s:Body></s:Envelope><',
    );
    final s = await driver.connect(tv.endpoint, tv.transports, null);
    addTearDown(s.close);
    expect(s.state.volume, isNull);
    await expectLater(s.refresh(), completes);
    final r = await s.execute(const StepVolume(1));
    expect(_error(r).code, WatchmeErrorCode.protocol);
  });

  test(
    'a Pro AV model connected in standby learns PAC once it is on',
    () async {
      await startSim(
        PanasonicSimulator(
          pac: true,
          power: PanasonicSimPower.networkStandby,
          dmrAnswersInStandby: true,
          bootDelay: Duration.zero,
        ),
      );
      // A background reconnect while the TV sleeps: /pac answers 400.
      final s = await connect(allowWake: false);
      expect(s.hasPac, isFalse);
      expect(await s.execute(const SelectInput('H3')), isA<Unsupported>());
      final events = <DeviceEvent>[];
      s.events.listen(events.add);
      await sim.pressPowerButton();
      sim.input = 'H2';
      final state = await s.refresh();
      expect(state.power!.value, PowerMode.on);
      expect(state.power!.confidence, Confidence.inferred);
      expect(state.input!.value, 'hdmi2');
      expect(s.hasPac, isTrue);
      expect(
        s.capabilities.supportFor(Capability.inputSwitch).note,
        contains('PAC'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        events.whereType<CapabilitiesChanged>().single.capabilities,
        s.capabilities,
      );
      expect(await s.execute(const SelectInput('H3')), const Confirmed());
      expect(sim.input, 'H3');
      // Learnt once: a later refresh announces nothing new.
      await s.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<CapabilitiesChanged>(), hasLength(1));
    },
  );

  group('connection and refresh', () {
    test('refresh of a TV in network standby infers standby from '
        "RenderingControl's 400 and reads no NRC", () async {
      await startSim(PanasonicSimulator(encrypted: true));
      final s = await connect();
      await sim.setPower(PanasonicSimPower.networkStandby);
      sim.clearLog();
      final state = await s.refresh();
      expect(state.power!.value, PowerMode.standby);
      expect(state.power!.confidence, Confidence.inferred);
      expect(sim.actions, ['GetVolume']);
    });

    test(
      'a RenderingControl that answers in standby never makes it "on"',
      () async {
        await startSim(PanasonicSimulator(dmrAnswersInStandby: true));
        final s = await connect();
        await sim.setPower(PanasonicSimPower.networkStandby);
        final state = await s.refresh();
        expect(state.power, isNull);
      },
    );

    test(
      'an inferred "on" goes stale once a refresh no longer sees why: '
      'switched off with its own remote, RenderingControl answering',
      () async {
        await startSim(
          PanasonicSimulator(pac: true, dmrAnswersInStandby: true),
        );
        final s = await connect();
        expect(s.state.power!.value, PowerMode.on);
        expect(s.state.power!.confidence, Confidence.inferred);
        final changes = <StateChanged>[];
        s.events.listen((e) {
          if (e is StateChanged) changes.add(e);
        });
        await sim.pressPowerButton();
        final state = await s.refresh();
        // The Pro AV description no longer answers, and a RenderingControl
        // answer proves nothing: no source says "on" any more.
        expect(state.power!.confidence, Confidence.stale);
        await Future<void>.delayed(Duration.zero);
        expect(changes.last.state.power!.confidence, Confidence.stale);
        // Stale stays stale; it is not re-announced on every poll.
        changes.clear();
        await s.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(changes.where((c) => c.state.power != null), isEmpty);
      },
    );

    test('an "on" inferred from the app list goes stale at the next refresh '
        'that cannot confirm it', () async {
      await startSim(PanasonicSimulator(dmrAnswersInStandby: true));
      final s = await connect();
      expect(await s.execute(const ListApps()), isA<Confirmed>());
      expect(s.state.power!.value, PowerMode.on);
      await sim.pressPowerButton();
      final state = await s.refresh();
      expect(state.power!.confidence, Confidence.stale);
    });

    test('refresh of a TV that is gone: stale, disconnected, thrown; back '
        'again: connected', () async {
      await startSim(PanasonicSimulator(poweredOnByApps: false));
      final s = await connect();
      final events = <DeviceEvent>[];
      s.events.listen(events.add);
      await sim.setPower(PanasonicSimPower.standby);
      await expectLater(
        s.refresh(),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unreachable,
          ),
        ),
      );
      expect(s.state.volume!.confidence, Confidence.stale);
      expect(
        s.state.connections['panasonic.viera'],
        ConnectionState.disconnected,
      );
      await sim.setPower(PanasonicSimPower.on);
      await s.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<ConnectionChanged>().map((e) => e.state), [
        ConnectionState.disconnected,
        ConnectionState.connected,
      ]);
    });

    test('one timeout is not a lost TV; three in a row are', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      final events = <DeviceEvent>[];
      s.events.listen(events.add);
      sim.dropNext('GetVolume');
      await expectLater(s.refresh(), throwsA(isA<WatchmeError>()));
      expect(events.whereType<ConnectionChanged>(), isEmpty);
      for (var i = 0; i < 3; i++) {
        sim.dropNext('GetVolume');
        await expectLater(s.refresh(), throwsA(isA<WatchmeError>()));
      }
      await Future<void>.delayed(Duration.zero);
      final lost = events.whereType<ConnectionChanged>().single;
      expect(lost.state, ConnectionState.disconnected);
      expect(lost.error!.code, WatchmeErrorCode.timeout);
    });

    test('the session polls while its events are listened to', () async {
      await startSim(PanasonicSimulator());
      final clock = FakeClock();
      final polling = PanasonicDriver(
        clock: clock,
        pollInterval: const Duration(seconds: 15),
      );
      final s = await connect(using: polling);
      final changes = <StateChanged>[];
      final sub = s.events.listen((e) {
        if (e is StateChanged) changes.add(e);
      });
      sim.volume = 61;
      await clock.advance(const Duration(seconds: 15));
      for (var i = 0; i < 50 && s.state.volume!.value != 61; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(s.state.volume!.value, 61);
      expect(changes.last.state.volume!.value, 61);
      await sub.cancel();
      // Refreshes are serialised: this one waits for the poll to finish.
      await s.refresh();
      sim.clearLog();
      await clock.advance(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(sim.requests, isEmpty);
    });

    test('close emits disconnected', () async {
      await startSim(PanasonicSimulator());
      final s = await connect();
      final done = s.events.toList();
      await s.close();
      final events = await done;
      expect(
        (events.single as ConnectionChanged).state,
        ConnectionState.disconnected,
      );
      expect(
        s.state.connections['panasonic.viera'],
        ConnectionState.disconnected,
      );
    });
  });

  group('key holds (opt-in)', () {
    test('the d-pad and volume hold with -ON and release with -OFF', () async {
      await startSim(PanasonicSimulator());
      final holding = PanasonicDriver(pollInterval: null, allowKeyHolds: true);
      final s = await connect(using: holding);
      expect(
        await s.execute(const PressKey(RemoteKey.up, KeyAction.down)),
        const Confirmed(),
      );
      expect(sim.heldKey, 'UP');
      expect(
        await s.execute(const PressKey(RemoteKey.up, KeyAction.up)),
        const Confirmed(),
      );
      expect(sim.heldKey, isNull);
      expect(
        await s.execute(const PressKey(RemoteKey.home, KeyAction.down)),
        isA<Unsupported>(),
      );
      expect(
        await s.execute(const PressKey(RemoteKey.power, KeyAction.down)),
        isA<Unsupported>(),
      );
      expect(sim.keyLog, ['NRC_UP-ON', 'NRC_UP-OFF']);
    });
  });

  test('an American set uses GUIDE and CC', () async {
    await startSim(PanasonicSimulator(modelNumber: 'TC-50AS650U'));
    final s = await connect();
    await s.execute(const PressKey(RemoteKey.guide));
    await s.execute(const PressKey(RemoteKey.captions));
    expect(sim.keyLog, ['NRC_GUIDE-ONOFF', 'NRC_CC-ONOFF']);
  });
}

/// Answer content that is not XML although the xml package parses it:
/// references to characters XML forbids, and `]]>` in text.
const List<String> _notXml = [
  '&#0;',
  '&#x1F;',
  '&#xD800;',
  '&#x110000;',
  ']]>',
];

/// Attributes that are not XML although the xml package parses them.
const List<String> _badAttributes = ['a=value', 'a', 'a="<"'];

/// XML declarations that break the XML 1.0 grammar.
const List<String> _badDeclarations = [
  '<?xml ?>',
  '<?xml version="1.0" foo="bar"?>',
  '<?xml encoding="utf-8" version="1.0"?>',
  '<?xml version="1.0" standalone="maybe"?>',
  '<?xml version="1.0" encoding="8utf"?>',
  '<?xml version="banana"?>',
  '<?xml version="1.0" version="1.0"?>',
];
