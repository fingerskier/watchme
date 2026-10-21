import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/src/api.dart' show untilListening;
import 'package:watchme_driver_firetv/src/session.dart' show FireTvSession;
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fake_firetv.dart';

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

  group('connect', () {
    test('wakes through DIAL before calling the API', () async {
      final session = await driver.connect(
        tv.endpoint,
        transports,
        tv.credential(),
      );
      expect(session.driverId, 'firetv.lightning');
      final calls = net.httpCalls;
      expect(
        [for (final c in calls) '${c.method} ${c.uri}'],
        [
          'POST http://10.0.0.7:8009/apps/FireTVRemote',
          'GET https://10.0.0.7:8080/v1/FireTV/status',
        ],
      );
      expect(calls[0].header('Content-Type'), 'text/plain');
      expect(calls[0].body, isNull);
      expect(calls[1].header('X-Api-Key'), '0987654321');
      expect(calls[1].header('X-Client-Token'), tv.token);
      expect(session.state.power?.value, PowerMode.on);
      expect(session.state.power?.confidence, Confidence.inferred);
      expect(session.state.connections, {
        'firetv.lightning': ConnectionState.connected,
      });
      expect(session.capabilities, fireTvDescriptor.ceiling);
    });

    test('wakes again on every connect', () async {
      await driver.connect(tv.endpoint, transports, tv.credential());
      await driver.connect(tv.endpoint, transports, tv.credential());
      expect(tv.wakes, 2);
    });

    test('pins the certificate recorded at pairing', () async {
      await driver.connect(tv.endpoint, transports, tv.credential());
      final status = tv.apiLog.single;
      expect(status.tls.pins, {tv.fingerprint});
      expect(status.tls.trustOnFirstUse, isFalse);
    });

    test('a changed certificate fails the pin as a protocol error', () async {
      final credential = tv.credential();
      tv.changeCertificate();
      await expectLater(
        driver.connect(tv.endpoint, transports, credential),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
    });

    test(
      'without a credential it asks for pairing and sends nothing',
      () async {
        await expectLater(
          driver.connect(tv.endpoint, transports, null),
          throwsWatchmeError(WatchmeErrorCode.unauthorized),
        );
        final other = SharedSecretCredential(
          driverId: 'sony.rest',
          deviceId: 'dev-1',
          createdAt: DateTime.utc(2026),
          secret: 'x',
        );
        await expectLater(
          driver.connect(tv.endpoint, transports, other),
          throwsWatchmeError(WatchmeErrorCode.unauthorized),
        );
        final unpinned = TokenCredential(
          driverId: 'firetv.lightning',
          deviceId: 'dev-1',
          createdAt: DateTime.utc(2026),
          token: tv.token,
        );
        await expectLater(
          driver.connect(tv.endpoint, transports, unpinned),
          throwsWatchmeError(WatchmeErrorCode.reauthRequired),
        );
        expect(net.httpCalls, isEmpty);
      },
    );

    test('a revoked token is reported as reauthRequired', () async {
      tv.tokenValid = false;
      await expectLater(
        driver.connect(tv.endpoint, transports, tv.credential()),
        throwsWatchmeError(
          WatchmeErrorCode.reauthRequired,
          rawDeviceMessage: '{"description":"authn error"}',
        ),
      );
    });

    test('tolerates a failed DIAL wake when the API already listens', () async {
      tv.wakeUp();
      net.respond('POST', '/apps/FireTVRemote', HttpResult(403));
      final session = await driver.connect(
        tv.endpoint,
        transports,
        tv.credential(),
      );
      expect(
        session.state.connections.values.single,
        ConnectionState.connected,
      );
    });

    test('tolerates firmware without the status endpoint', () async {
      net.respond('GET', '/v1/FireTV/status', HttpResult(404));
      final session = await driver.connect(
        tv.endpoint,
        transports,
        tv.credential(),
      ) as FireTvSession;
      expect(session.status, isNull);
      // The token is checked by the first command, which reaches the device.
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(net.callsTo('POST', '/v1/FireTV').single.uri.query, 'action=home');
      tv.tokenValid = false;
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
    });

    test('a host that never answers costs about the startup timeout, not a '
        'request timeout per attempt', () async {
      final budgets = <Duration>[];
      final started = clock.now();
      final waiting = untilListening<void>(
        (budget) async {
          budgets.add(budget);
          // Each attempt hangs for its whole budget, then fails.
          await clock.delay(budget);
          throw const WatchmeError.unreachable('No answer to connect');
        },
        clock: clock,
        timeout: const Duration(seconds: 6),
        interval: const Duration(milliseconds: 500),
      );
      final expectation = expectLater(
        waiting,
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      await clock.advance(const Duration(seconds: 10));
      await expectation;
      expect(budgets, [const Duration(seconds: 6)]);
      expect(
        clock.now().difference(started),
        lessThanOrEqualTo(const Duration(seconds: 10)),
      );
    });

    test('later attempts get only the time that is left', () async {
      final budgets = <Duration>[];
      final waiting = untilListening<void>(
        (budget) async {
          budgets.add(budget);
          await clock.delay(const Duration(seconds: 2));
          throw const WatchmeError.unreachable('refused');
        },
        clock: clock,
        timeout: const Duration(seconds: 6),
        interval: const Duration(milliseconds: 500),
      );
      final expectation = expectLater(
        waiting,
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      await clock.advance(const Duration(seconds: 12));
      await expectation;
      expect(budgets, [
        const Duration(seconds: 6),
        const Duration(milliseconds: 3500),
        const Duration(seconds: 1),
      ]);
    });

    test('allowWake: false sends no DIAL launch and fails at once while the '
        'API port is closed', () async {
      final started = clock.now();
      await expectLater(
        driver.connect(
          tv.endpoint,
          transports,
          tv.credential(),
          allowWake: false,
        ),
        throwsWatchmeError(
          WatchmeErrorCode.unreachable,
          message: contains('without waking'),
        ),
      );
      expect(net.callsTo('POST', '/apps/FireTVRemote'), isEmpty);
      expect(tv.wakes, 0);
      expect(tv.awake, isFalse);
      expect(
        net.callsTo('GET', '/v1/FireTV/status'),
        hasLength(1),
        reason: 'no waiting for the port to open',
      );
      expect(clock.now(), started);
    });

    test('allowWake: false connects to an awake device without a DIAL '
        'launch', () async {
      tv.wakeUp();
      final session = await driver.connect(
        tv.endpoint,
        transports,
        tv.credential(),
        allowWake: false,
      );
      expect(
        session.state.connections.values.single,
        ConnectionState.connected,
      );
      expect(tv.wakes, 0);
      expect(
        [for (final c in net.httpCalls) '${c.method} ${c.uri.path}'],
        ['GET /v1/FireTV/status'],
      );
    });

    test('a refusal that echoes the token does not repeat it', () async {
      net.respond(
        'GET',
        '/v1/FireTV/status',
        HttpResult.json(401, {
          'description': 'bad token ${tv.token}',
          'clientToken': tv.token,
        }),
      );
      Object? error;
      try {
        await driver.connect(tv.endpoint, transports, tv.credential());
      } on WatchmeError catch (e) {
        error = e;
      }
      expect(error, isWatchmeError(WatchmeErrorCode.reauthRequired));
      final e = error! as WatchmeError;
      expect(
        e.rawDeviceMessage,
        '{"description":"bad token <redacted>","clientToken":"<redacted>"}',
      );
      for (final text in ['$e', jsonEncode(e.toJson())]) {
        expect(text, isNot(contains(tv.token)));
      }
    });

    test('a DIAL wake that timed out is not reported as unreachable: it may '
        'have reached the device', () async {
      // Verifier follow-up to Codex finding #4.
      tv.sleep();
      net.onHttp('POST', '/apps/FireTVRemote', (_) {
        tv.wakes++;
        throw const WatchmeError.timeout('No answer from DIAL');
      });
      final result = driver.connect(tv.endpoint, transports, tv.credential());
      final expectation = expectLater(
        result,
        throwsWatchmeError(
          WatchmeErrorCode.timeout,
          message: contains('DIAL wake may have reached the device'),
        ),
      );
      await clock.advance(const Duration(seconds: 7));
      await expectation;
      expect(tv.wakes, 1);
    });

    test('a refusal echoing the client token JSON-escaped does not show '
        'it', () async {
      // Verifier follow-up to Codex finding #8: Android's org.json writes
      // `/` as `\/`, which the verbatim match missed.
      final slashed = FakeFireTv(FakeNetworkStack(), token: 'abc/tok/9');
      slashed.wakeUp();
      slashed.net.respond(
        'GET',
        '/v1/FireTV/status',
        HttpResult.text(403, r'{"msg":"token abc\/tok\/9 revoked"}'),
      );
      Object? error;
      try {
        await driver.connect(
          slashed.endpoint,
          FakeTransports(network: slashed.net),
          slashed.credential(),
        );
      } on WatchmeError catch (e) {
        error = e;
      }
      final e = error! as WatchmeError;
      expect(e.code, WatchmeErrorCode.reauthRequired);
      expect(e.rawDeviceMessage, '{"msg":"token <redacted> revoked"}');
    });

    test('reports both failures when the device stays unreachable', () async {
      net.setUnreachable(tv.host);
      final result = driver.connect(tv.endpoint, transports, tv.credential());
      final expectation = expectLater(
        result,
        throwsWatchmeError(
          WatchmeErrorCode.unreachable,
          message: contains('DIAL wake failed too'),
        ),
      );
      await clock.advance(const Duration(seconds: 7));
      await expectation;
    });
  });

  group('session', () {
    late DriverSession session;
    late List<DeviceEvent> events;

    setUp(() async {
      session = await driver.connect(tv.endpoint, transports, tv.credential());
      events = [];
      session.events.listen(events.add);
    });

    List<HttpCall> commandCalls() => [
      for (final c in net.httpCalls)
        if (c.uri.path != '/v1/FireTV/status' &&
            c.uri.path != '/apps/FireTVRemote')
          c,
    ];

    test('key presses POST the mapped action with no body', () async {
      const keys = {
        RemoteKey.up: 'dpad_up',
        RemoteKey.down: 'dpad_down',
        RemoteKey.left: 'dpad_left',
        RemoteKey.right: 'dpad_right',
        RemoteKey.select: 'select',
        RemoteKey.home: 'home',
        RemoteKey.back: 'back',
        RemoteKey.menu: 'menu',
        RemoteKey.volumeUp: 'volume_up',
        RemoteKey.volumeDown: 'volume_down',
        RemoteKey.mute: 'mute',
      };
      for (final key in keys.keys) {
        expect(await session.execute(PressKey(key)), isConfirmed);
      }
      final calls = commandCalls();
      expect(
        [for (final c in calls) c.uri.queryParameters['action']],
        [...keys.values],
      );
      for (final call in calls) {
        expect(call.method, 'POST');
        expect(call.uri.path, '/v1/FireTV');
        expect(call.body, isNull, reason: 'a {} body makes the device fail');
        expect(call.header('X-Api-Key'), '0987654321');
        expect(call.header('X-Client-Token'), tv.token);
        expect(call.header('Content-Type'), 'application/json; charset=utf-8');
      }
      for (final r in tv.apiLog) {
        expect(r.tls.pins, {tv.fingerprint});
      }
    });

    test('a {} body would fail, which is why none is sent', () async {
      // The fake mirrors the device rule; prove it is enforced.
      final result = await net.http(
        HttpCall.json(
          'POST',
          Uri.parse('https://10.0.0.7:8080/v1/FireTV?action=home'),
          <String, Object?>{},
          headers: {'X-Api-Key': '0987654321', 'X-Client-Token': tv.token},
        ),
        tls: TlsPolicy.pinned([tv.fingerprint]),
      );
      expect(result.status, 500);
    });

    test('hold sends keyDown and keyUp bodies in order', () async {
      final down = session.execute(
        const PressKey(RemoteKey.down, KeyAction.down),
      );
      final up = session.execute(const PressKey(RemoteKey.down, KeyAction.up));
      expect(await down, isConfirmed);
      expect(await up, isConfirmed);
      expect(
        [for (final c in commandCalls()) c.bodyText],
        ['{"keyActionType":"keyDown"}', '{"keyActionType":"keyUp"}'],
      );
    });

    test('commands run one at a time even when the device is slow', () async {
      final order = <String>[];
      net.onHttp('POST', '/v1/FireTV', (call) async {
        final action = call.uri.queryParameters['action']!;
        order.add('start $action');
        await Future<void>.delayed(
          Duration(milliseconds: action == 'dpad_up' ? 30 : 0),
        );
        order.add('end $action');
        return HttpResult.json(200, {'description': 'OK'});
      });
      await Future.wait([
        session.execute(const PressKey(RemoteKey.up, KeyAction.down)),
        session.execute(const PressKey(RemoteKey.up, KeyAction.up)),
      ]);
      // Both edges go to dpad_up; the second may only start after the first.
      expect(order, [
        'start dpad_up',
        'end dpad_up',
        'start dpad_up',
        'end dpad_up',
      ]);
    });

    group('the end of a hold never wakes the device', () {
      // Verifier follow-up to Codex finding #9: apps send the key-up on
      // their own, and it woke a sleeping Fire TV through DIAL.
      test(
        'asleep: nothing is held, so it is released without a wake',
        () async {
          tv.sleep();
          expect(
            await session.execute(const PressKey(RemoteKey.down, KeyAction.up)),
            isConfirmed,
          );
          expect(tv.wakes, 1, reason: 'only the connect');
          expect(tv.awake, isFalse);
          expect(session.state.power?.value, PowerMode.standby);
        },
      );

      test('gone: unreachable, still without a wake', () async {
        net.setUnreachable(tv.host);
        expect(
          await session.execute(const PressKey(RemoteKey.down, KeyAction.up)),
          isFailedWith(WatchmeErrorCode.unreachable),
        );
        expect(net.callsTo('POST', '/apps/FireTVRemote'), hasLength(1));
      });

      test('the start of a hold still wakes it', () async {
        tv.sleep();
        final down = session.execute(
          const PressKey(RemoteKey.down, KeyAction.down),
        );
        await clock.advance(const Duration(seconds: 1));
        expect(await down, isConfirmed);
        expect(tv.wakes, 2);
      });
    });

    test('hold is refused for keys other than the d-pad and select', () async {
      expect(
        await session.execute(const PressKey(RemoteKey.home, KeyAction.down)),
        isUnsupported(contains('d-pad')),
      );
      expect(commandCalls(), isEmpty);
    });

    test('unmapped keys are unsupported and send nothing', () async {
      for (final key in [
        RemoteKey.info,
        RemoteKey.guide,
        RemoteKey.channelUp,
        RemoteKey.digit1,
        RemoteKey.red,
        RemoteKey.inputHdmi1,
        RemoteKey.backspace,
        RemoteKey.enter,
        RemoteKey.stop,
        RemoteKey.play,
        RemoteKey.pause,
      ]) {
        expect(
          await session.execute(PressKey(key)),
          isUnsupported(),
          reason: '$key',
        );
      }
      expect(commandCalls(), isEmpty);
    });

    test(
      'the power key toggles the TV through action=power, no body',
      () async {
        expect(
          await session.execute(const PressKey(RemoteKey.power)),
          isConfirmed,
        );
        final call = commandCalls().single;
        expect(call.uri.path, '/v1/FireTV');
        expect(call.uri.queryParameters, {'action': 'power'});
        expect(call.body, isNull);
        expect(
          await session.execute(
            const PressKey(RemoteKey.power, KeyAction.down),
          ),
          isUnsupported(contains('d-pad')),
          reason: 'a power toggle cannot be held',
        );
        expect(commandCalls(), hasLength(1));
      },
    );

    test('commands the API cannot express are unsupported', () async {
      final commands = <Command>[
        const SetVolume(20),
        const SetMute(true),
        const SetMute(false),
        const SelectInput('hdmi1'),
        const TuneChannel('5'),
        const MovePointer(1, 1),
        const ShowToast('hi'),
        CastUrl(Uri.parse('https://example.invalid/a.mp4')),
        const TakeScreenshot(),
        const Media(MediaAction.play),
        const Media(MediaAction.pause),
        const Media(MediaAction.stop),
        const Media(MediaAction.seek, seekTo: Duration(seconds: 3)),
        const Media(MediaAction.next),
        const TypeText('x', replace: true),
        LaunchApp('com.netflix.ninja', deepLink: Uri.parse('nflx://title/1')),
        const LaunchApp('com.netflix.ninja', params: {'contentId': '1'}),
        const LaunchApp('../../etc'),
        const StepVolume(101),
      ];
      for (final command in commands) {
        expect(
          await session.execute(command),
          isUnsupported(),
          reason: '$command',
        );
      }
      expect(commandCalls(), isEmpty);
      expect(tv.wakes, 1, reason: 'only the connect wake');
    });

    test('StepVolume presses volume keys and SetMute(null) toggles', () async {
      expect(await session.execute(const StepVolume(3)), isConfirmed);
      expect(await session.execute(const StepVolume(-2)), isConfirmed);
      expect(await session.execute(const StepVolume(0)), isConfirmed);
      expect(await session.execute(const SetMute(null)), isConfirmed);
      expect(
        [for (final c in commandCalls()) c.uri.queryParameters['action']],
        [
          'volume_up',
          'volume_up',
          'volume_up',
          'volume_down',
          'volume_down',
          'mute',
        ],
      );
    });

    test(
      'SetPower(false) sleeps and SetPower(true) wakes through DIAL',
      () async {
        expect(await session.execute(const SetPower(false)), isConfirmed);
        expect(commandCalls().single.uri.queryParameters['action'], 'sleep');
        expect(commandCalls().single.body, isNull);
        expect(session.state.power?.value, PowerMode.standby);

        expect(await session.execute(const SetPower(true)), isConfirmed);
        expect(tv.wakes, 2);
        expect(
          [for (final c in net.httpCalls.reversed.take(2)) c.uri.path],
          ['/v1/FireTV/status', '/apps/FireTVRemote'],
          reason: 'waits for the API after the DIAL wake',
        );
        expect(session.state.power?.value, PowerMode.on);

        await clock.flush();
        final powers = [
          for (final e in events.whereType<StateChanged>())
            e.state.power?.value,
        ];
        expect(powers, [PowerMode.standby, PowerMode.on]);

        expect(
          await session.execute(const PressKey(RemoteKey.powerOff)),
          isConfirmed,
        );
        expect(
          await session.execute(const PressKey(RemoteKey.powerOn)),
          isConfirmed,
        );
        expect(tv.wakes, 3);
      },
    );

    test('SetPower(true) waits for the API port to open', () async {
      await session.execute(const SetPower(false));
      tv.wakeOnDial = false;
      final result = session.execute(const SetPower(true));
      await clock.advance(const Duration(milliseconds: 1200));
      tv.wakeUp();
      await clock.advance(const Duration(milliseconds: 500));
      expect(await result, isConfirmed);
      expect(net.callsTo('GET', '/v1/FireTV/status'), hasLength(1 + 4));
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isConfirmed,
      );
    });

    test('SetPower(true) is confirmed even if the API stays closed', () async {
      await session.execute(const SetPower(false));
      tv.wakeOnDial = false;
      final result = session.execute(const SetPower(true));
      await clock.advance(const Duration(seconds: 7));
      expect(await result, isConfirmed);
    });

    test('a refused DIAL wake fails with the device text', () async {
      net.respond('POST', '/apps/FireTVRemote', HttpResult.text(403, 'nope'));
      expect(
        await session.execute(const SetPower(true)),
        isFailedWith(WatchmeErrorCode.rejected, rawDeviceMessage: 'nope'),
      );
    });

    test('a key press after sleep wakes the device through DIAL and is sent '
        'once more', () async {
      await session.execute(const SetPower(false));
      final wakes = tv.wakes;
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(tv.wakes, wakes + 1);
      final homes = [
        for (final r in net.httpLog)
          if (r.call.uri.queryParameters['action'] == 'home') r,
      ];
      expect(homes, hasLength(2));
      expect(homes.first.error, isA<WatchmeError>(), reason: 'port closed');
      expect(homes.last.result?.status, 200);
      expect(session.state.power?.value, PowerMode.on);
    });

    test(
      'a device that fell asleep by itself is woken by the next command',
      () async {
        tv.sleep();
        expect(
          await session.execute(const Media(MediaAction.playPause)),
          isConfirmed,
        );
        expect(tv.wakes, 2, reason: 'connect, then the command');
        expect(
          await session.execute(const PressKey(RemoteKey.home)),
          isConfirmed,
        );
        expect(tv.wakes, 2, reason: 'awake again');
      },
    );

    // Was `unreachable`, which Codex finding #4 makes wrong: the DIAL wake
    // was delivered (and may be turning the TV on), so the command must not
    // be replayed through another route.
    test('a wake that does not open the API fails the command as partly '
        'delivered, not unreachable', () async {
      tv
        ..sleep()
        ..wakeOnDial = false;
      final result = session.execute(const PressKey(RemoteKey.home));
      await clock.advance(const Duration(seconds: 7));
      final failed = await result;
      expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(failed.partiallyDelivered, isTrue);
      expect(
        (failed as Failed).error.cause,
        isWatchmeError(WatchmeErrorCode.unreachable),
      );
      expect(tv.wakes, 2);
    });

    group('a DIAL wake that timed out may have reached the device', () {
      // Verifier follow-up to Codex finding #4: it came back as
      // `unreachable`, which promises nothing reached the device, while the
      // launch may have woken it (and the TV over HDMI-CEC).
      void wakeTimesOut() {
        tv.sleep();
        net.onHttp('POST', '/apps/FireTVRemote', (_) {
          tv.wakes++;
          tv.wakeUp();
          throw const WatchmeError.timeout('No answer from DIAL');
        });
      }

      test('a key press fails as a timeout, and the power observation goes '
          'stale', () async {
        wakeTimesOut();
        final failed = await session.execute(const PressKey(RemoteKey.home));
        expect(
          failed,
          isFailedWith(
            WatchmeErrorCode.timeout,
            message: contains('DIAL wake may have reached the device'),
          ),
        );
        expect(tv.awake, isTrue);
        expect(session.state.power?.confidence, Confidence.stale);
        await clock.flush();
        expect(
          events.whereType<ConnectionChanged>(),
          isEmpty,
          reason: 'the device is not lost',
        );
      });

      test('after an earlier step it is a partial delivery', () async {
        net.onHttp('POST', '/v1/FireTV', (_) {
          // The first step lands, then the device falls asleep.
          tv.sleep();
          return HttpResult.json(200, {'description': 'OK'});
        });
        net.onHttp('POST', '/apps/FireTVRemote', (_) {
          tv.wakes++;
          throw const WatchmeError.timeout('No answer from DIAL');
        });
        final failed = await session.execute(const StepVolume(2));
        expect(
          failed,
          isFailedWith(
            WatchmeErrorCode.partiallyDelivered,
            message: contains('1 of its requests'),
          ),
        );
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.timeout),
        );
        expect(tv.wakes, 2);
      });
    });

    test('a command whose wake failed too is unreachable: nothing was '
        'delivered', () async {
      tv.sleep();
      net.respond('POST', '/apps/FireTVRemote', HttpResult(403));
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.unreachable,
          message: contains('DIAL wake failed too'),
        ),
      );
    });

    test('SetPower(false) on a device that is already asleep does not wake '
        'it', () async {
      tv.sleep();
      expect(await session.execute(const SetPower(false)), isConfirmed);
      expect(tv.wakes, 1, reason: 'only the connect');
      expect(session.state.power?.value, PowerMode.standby);
      expect(net.callsTo('GET', '/apps/FireTVRemote'), hasLength(1));
    });

    test(
      'SetPower(false) on a device that is gone fails as unreachable',
      () async {
        net.setUnreachable(tv.host);
        expect(
          await session.execute(const SetPower(false)),
          isFailedWith(WatchmeErrorCode.unreachable),
        );
      },
    );

    test('TypeText checks the keyboard, then posts the whole string', () async {
      expect(await session.execute(const TypeText('héllo world')), isConfirmed);
      final calls = commandCalls();
      expect(
        [for (final c in calls) '${c.method} ${c.uri.path}'],
        ['GET /v1/FireTV/keyboard', 'POST /v1/FireTV/keyboard'],
      );
      expect(calls.last.bodyText, '{"text":"héllo world"}');
    });

    test(
      'TypeText into a closed keyboard is rejected before sending',
      () async {
        tv.keyboardOpen = false;
        expect(
          await session.execute(const TypeText('abc')),
          isFailedWith(
            WatchmeErrorCode.rejected,
            rawDeviceMessage: contains('hidden'),
          ),
        );
        expect(net.callsTo('POST', '/v1/FireTV/keyboard'), isEmpty);
      },
    );

    test(
      'TypeText still writes when the keyboard state is unavailable',
      () async {
        net.respond('GET', '/v1/FireTV/keyboard', HttpResult(404));
        expect(await session.execute(const TypeText('abc')), isConfirmed);
        expect(net.callsTo('POST', '/v1/FireTV/keyboard'), hasLength(1));
      },
    );

    test('ListApps returns launchable installed apps', () async {
      final result = await session.execute(const ListApps());
      expect(
        result,
        isConfirmedWith(
          AppListPayload([
            AppInfo(
              id: 'com.netflix.ninja',
              name: 'Netflix',
              icon: Uri.parse('https://example.invalid/n.png'),
            ),
            const AppInfo(id: 'org.noname', name: 'org.noname'),
          ]),
        ),
      );
      expect(commandCalls().single.uri.path, '/v1/FireTV/appsV2');
    });

    test('ListApps rejects a body that is not an app list', () async {
      net.respond('GET', '/v1/FireTV/appsV2', HttpResult.json(200, {'x': 1}));
      expect(
        await session.execute(const ListApps()),
        isFailedWith(WatchmeErrorCode.protocol, rawDeviceMessage: '{"x":1}'),
      );
    });

    test('LaunchApp posts the package with no body', () async {
      await session.execute(const ListApps());
      expect(
        await session.execute(const LaunchApp('com.netflix.ninja')),
        isConfirmed,
      );
      final launch = commandCalls().last;
      expect(launch.uri.path, '/v1/FireTV/app/com.netflix.ninja');
      expect(launch.body, isNull);
      expect(session.state.foregroundApp?.value.name, 'Netflix');
      await clock.flush();
      expect(
        events.whereType<StateChanged>().last.state.foregroundApp,
        isNotNull,
      );
    });

    test('media maps to the play toggle and scans', () async {
      expect(
        await session.execute(const Media(MediaAction.playPause)),
        isConfirmed,
      );
      expect(
        await session.execute(const Media(MediaAction.fastForward)),
        isConfirmed,
      );
      expect(
        await session.execute(const PressKey(RemoteKey.rewind)),
        isConfirmed,
      );
      expect(
        await session.execute(const PressKey(RemoteKey.playPause)),
        isConfirmed,
      );
      final calls = commandCalls();
      expect(
        [for (final c in calls) c.uri.toString()],
        [
          'https://10.0.0.7:8080/v1/media?action=play',
          'https://10.0.0.7:8080/v1/media?action=scan',
          'https://10.0.0.7:8080/v1/media?action=scan&direction=back',
          'https://10.0.0.7:8080/v1/media?action=play',
        ],
      );
      expect(calls[0].body, isNull);
      expect(
        calls[1].bodyText,
        '{"direction":"forward","durationInSeconds":"10","speed":"1"}',
      );
      // `back`, as the official app sends it; `backward` was refused with
      // HTTP 400 on hardware.
      expect(
        calls[2].bodyText,
        '{"direction":"back","durationInSeconds":"10","speed":"1"}',
      );
    });

    test(
      '401 emits ReauthRequired once and fails with reauthRequired',
      () async {
        tv.tokenValid = false;
        final first = await session.execute(const PressKey(RemoteKey.home));
        final second = await session.execute(const ListApps());
        for (final result in [first, second]) {
          expect(
            result,
            isFailedWith(
              WatchmeErrorCode.reauthRequired,
              rawDeviceMessage: '{"description":"authn error"}',
            ),
          );
        }
        await clock.flush();
        expect(events.whereType<ReauthRequired>(), hasLength(1));
        final changed = events.whereType<ConnectionChanged>().single;
        expect(changed.state, ConnectionState.failed);
        expect(changed.error?.code, WatchmeErrorCode.reauthRequired);
        expect(session.state.connections.values.single, ConnectionState.failed);
      },
    );

    test('403 is a revoked token too', () async {
      net.respond(
        'POST',
        '/v1/FireTV',
        HttpResult.json(403, {'description': 'x'}),
      );
      expect(
        await session.execute(const PressKey(RemoteKey.back)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await clock.flush();
      expect(events.whereType<ReauthRequired>(), hasLength(1));
    });

    test('other device errors keep the raw text', () async {
      net.respond(
        'POST',
        '/v1/media',
        HttpResult.json(400, {'description': 'Bad arguments supplied.'}),
      );
      expect(
        await session.execute(const Media(MediaAction.rewind)),
        isFailedWith(
          WatchmeErrorCode.rejected,
          rawDeviceMessage: contains('Bad arguments'),
        ),
      );
      net.respond('POST', '/v1/FireTV', HttpResult.text(500, 'boom'));
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.protocol, rawDeviceMessage: 'boom'),
      );
      net.respond('POST', RegExp('^/v1/FireTV/app/'), HttpResult(404));
      expect(
        await session.execute(const LaunchApp('com.x.y')),
        isFailedWith(
          WatchmeErrorCode.unsupported,
          rawDeviceMessage: 'HTTP 404',
        ),
      );
      expect(events.whereType<ReauthRequired>(), isEmpty);
    });

    test('refresh re-reads status and surfaces a revoked token', () async {
      final state = await session.refresh();
      expect(state.power?.value, PowerMode.on);
      tv.tokenValid = false;
      await expectLater(
        session.refresh(),
        throwsWatchmeError(WatchmeErrorCode.reauthRequired),
      );
      await clock.flush();
      expect(events.whereType<ReauthRequired>(), hasLength(1));
    });

    test(
      'refresh of a sleeping device reports standby without waking it',
      () async {
        tv.sleep();
        final state = await session.refresh();
        expect(state.power?.value, PowerMode.standby);
        expect(state.power?.confidence, Confidence.inferred);
        expect(tv.wakes, 1, reason: 'only the connect');
      },
    );

    test('refresh of a device that is gone fails as unreachable', () async {
      net.setUnreachable(tv.host);
      await expectLater(
        session.refresh(),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('refresh accepts firmware without the status endpoint', () async {
      net.respond('GET', '/v1/FireTV/status', HttpResult(404));
      expect((await session.refresh()).power?.value, PowerMode.on);
      net.respond('GET', '/v1/FireTV/status', HttpResult.text(500, 'x'));
      await expectLater(
        session.refresh(),
        throwsWatchmeError(WatchmeErrorCode.protocol, rawDeviceMessage: 'x'),
      );
    });

    test('a device error echoing the token in escaped form does not repeat '
        'it', () async {
      // Verifier follow-up to Codex finding #8: only the verbatim form was
      // removed, and a JSON decoder recovers the token from `\u0074ok...`.
      final escaped = r'{"e":"bad \u0074ok-abc123"}';
      expect(tv.token, 'tok-abc123');
      net.respond('POST', '/v1/FireTV', HttpResult.text(500, escaped));
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.protocol,
          rawDeviceMessage: '{"e":"bad <redacted>"}',
        ),
      );
      net.respond('POST', '/v1/FireTV', HttpResult.text(401, escaped));
      final refused = await session.execute(const PressKey(RemoteKey.home));
      expect(
        refused,
        isFailedWith(
          WatchmeErrorCode.reauthRequired,
          rawDeviceMessage: '{"e":"bad <redacted>"}',
        ),
      );
      await clock.flush();
      for (final event in events) {
        expect(jsonEncode(event.toJson()), isNot(contains('u0074ok')));
      }
    });

    test('device errors and events never repeat the token or the API '
        'key', () async {
      net.respond(
        'POST',
        '/v1/FireTV',
        HttpResult.text(500, 'boom ${tv.token} 0987654321'),
      );
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.protocol,
          rawDeviceMessage: 'boom <redacted> <redacted>',
        ),
      );
      net.respond(
        'POST',
        '/v1/FireTV',
        HttpResult.json(401, {'description': 'authn error', 'token': tv.token}),
      );
      final refused = await session.execute(const PressKey(RemoteKey.home));
      expect(refused, isFailedWith(WatchmeErrorCode.reauthRequired));
      net.respond(
        'GET',
        '/v1/FireTV/appsV2',
        HttpResult.text(200, 'not json, ${tv.token}'),
      );
      final malformed = await session.execute(const ListApps());
      expect(malformed, isFailedWith(WatchmeErrorCode.protocol));
      await clock.flush();
      expect(events.whereType<ReauthRequired>(), hasLength(1));
      for (final text in [
        '$refused',
        jsonEncode(refused.toJson()),
        '$malformed',
        '${(malformed as Failed).error.cause}',
        for (final e in events) ...['$e', jsonEncode(e.toJson())],
      ]) {
        expect(text, isNot(contains(tv.token)));
      }
    });

    group('close stops a command in progress', () {
      /// Holds the answer to the [nth] request matching [method] [path]
      /// until [release] completes; [reached] completes when it arrives.
      ({Completer<void> reached, Completer<void> release, List<HttpCall> seen})
      hold(String method, String path, {int nth = 1}) {
        final reached = Completer<void>();
        final release = Completer<void>();
        final seen = <HttpCall>[];
        net.onHttp(method, path, (call) async {
          seen.add(call);
          if (seen.length == nth) {
            reached.complete();
            await release.future;
          }
          return path == '/apps/FireTVRemote'
              ? HttpResult(201)
              : HttpResult.json(200, {'description': 'OK'});
        });
        return (reached: reached, release: release, seen: seen);
      }

      test('StepVolume(3): first answer paused, session closed, answer '
          'released: no more presses, and not Confirmed', () async {
        // Codex finding #3, reproduced as reported.
        final gate = hold('POST', '/v1/FireTV');
        final result = session.execute(const StepVolume(3));
        await gate.reached.future;
        await session.close();
        gate.release.complete();
        final failed = await result;
        expect(gate.seen, hasLength(1), reason: 'steps 2 and 3 never sent');
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.cancelled),
        );
        expect(failed.error.message, contains('1 of its requests'));
      });

      test('a command queued behind the closing one sends nothing', () async {
        final gate = hold('POST', '/v1/FireTV');
        final first = session.execute(const PressKey(RemoteKey.up));
        final second = session.execute(const PressKey(RemoteKey.down));
        await gate.reached.future;
        await session.close();
        gate.release.complete();
        expect(await first, isConfirmed, reason: 'fully sent before close');
        expect(await second, isFailedWith(WatchmeErrorCode.cancelled));
        expect(gate.seen, hasLength(1));
      });

      test(
        'TypeText closed while reading the keyboard sends no text',
        () async {
          final gate = hold('GET', '/v1/FireTV/keyboard');
          final result = session.execute(const TypeText('abc'));
          await gate.reached.future;
          await session.close();
          gate.release.complete();
          expect(await result, isFailedWith(WatchmeErrorCode.cancelled));
          expect(net.callsTo('POST', '/v1/FireTV/keyboard'), isEmpty);
        },
      );

      test('the wake-and-resend path stops before the resend', () async {
        tv.sleep();
        final gate = hold('POST', '/apps/FireTVRemote');
        final result = session.execute(const LaunchApp('com.netflix.ninja'));
        await gate.reached.future;
        await session.close();
        gate.release.complete();
        await clock.advance(const Duration(seconds: 7));
        final failed = await result;
        // The wake was delivered; the launch was not resent.
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.cancelled),
        );
        expect(net.callsTo('POST', RegExp('^/v1/FireTV/app/')), hasLength(1));
        expect(
          net.callsTo('GET', '/v1/FireTV/status'),
          hasLength(1),
          reason: 'only the connect: no wait for the API after close',
        );
      });

      test('a session closed before a wake sends no wake', () async {
        // The keyboard read finds the port closed, so the session would wake
        // the device; the session is closed while that read is under way.
        net.onHttp('GET', '/v1/FireTV/keyboard', (_) async {
          await session.close();
          throw const WatchmeError.unreachable('refused');
        });
        expect(
          await session.execute(const TypeText('abc')),
          isFailedWith(WatchmeErrorCode.cancelled),
        );
        expect(tv.wakes, 1, reason: 'only the connect');
        expect(net.callsTo('POST', '/v1/FireTV/keyboard'), isEmpty);
      });
    });

    group('partial delivery', () {
      test('StepVolume failing at step 2 is partly delivered', () async {
        var presses = 0;
        net.onHttp('POST', '/v1/FireTV', (_) {
          if (++presses == 2) return HttpResult.text(500, 'boom');
          return HttpResult.json(200, {'description': 'OK'});
        });
        final failed = await session.execute(const StepVolume(3));
        expect(
          failed,
          isFailedWith(
            WatchmeErrorCode.partiallyDelivered,
            rawDeviceMessage: 'boom',
          ),
        );
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.protocol),
        );
        expect(presses, 2);
      });

      test('a device that vanishes after a step is partly delivered, never '
          'unreachable', () async {
        var presses = 0;
        net.onHttp('POST', '/v1/FireTV', (_) {
          if (++presses == 1) net.setUnreachable(tv.host);
          return HttpResult.json(200, {'description': 'OK'});
        });
        final failed = await session.execute(const StepVolume(3));
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.unreachable),
        );
        expect(failed.delivered, isFalse);
      });

      test('a timeout after a step is partly delivered', () async {
        var presses = 0;
        net.onHttp('POST', '/v1/FireTV', (_) {
          if (++presses == 2) {
            throw const WatchmeError.timeout('No answer');
          }
          return HttpResult.json(200, {'description': 'OK'});
        });
        final failed = await session.execute(const StepVolume(-3));
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.timeout),
        );
      });

      test('a 401 after a step is partly delivered and still emits '
          'ReauthRequired', () async {
        var presses = 0;
        net.onHttp(
          'POST',
          '/v1/FireTV',
          (_) => ++presses == 2
              ? HttpResult.json(401, {'description': 'authn error'})
              : HttpResult.json(200, {'description': 'OK'}),
        );
        final failed = await session.execute(const StepVolume(3));
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          (failed as Failed).error.cause,
          isWatchmeError(WatchmeErrorCode.reauthRequired),
        );
        await clock.flush();
        expect(events.whereType<ReauthRequired>(), hasLength(1));
      });

      test('a first step that reaches nothing stays unreachable', () async {
        net.setUnreachable(tv.host);
        expect(
          await session.execute(const StepVolume(3)),
          isFailedWith(WatchmeErrorCode.unreachable),
        );
      });
    });

    group('a device that is gone', () {
      test('refresh marks observations stale and reports disconnected, '
          'without waking', () async {
        await session.execute(const LaunchApp('com.netflix.ninja'));
        net.setUnreachable(tv.host);
        final mark = net.httpCalls.length;
        Object? thrown;
        try {
          await session.refresh();
        } on WatchmeError catch (e) {
          thrown = e;
        }
        expect(thrown, isWatchmeError(WatchmeErrorCode.unreachable));
        expect(
          [for (final c in net.httpCalls.skip(mark)) '${c.method} ${c.uri}'],
          [
            'GET https://10.0.0.7:8080/v1/FireTV/status',
            'GET http://10.0.0.7:8009/apps/FireTVRemote',
          ],
          reason: 'passive: no DIAL launch',
        );
        expect(session.state.power?.confidence, Confidence.stale);
        expect(session.state.foregroundApp?.confidence, Confidence.stale);
        expect(
          session.state.connections['firetv.lightning'],
          ConnectionState.disconnected,
        );
        await clock.flush();
        final changed = events.whereType<ConnectionChanged>().single;
        expect(changed.state, ConnectionState.disconnected);
        expect(changed.error, same(thrown));
        // Reported once.
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
        await clock.flush();
        expect(events.whereType<ConnectionChanged>(), hasLength(1));
      });

      test('an answer after that reports it connected again', () async {
        net.setUnreachable(tv.host);
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
        net.setReachable(tv.host);
        tv.sleep();
        expect((await session.refresh()).power?.value, PowerMode.standby);
        await clock.flush();
        expect(events.whereType<ConnectionChanged>().map((e) => e.state), [
          ConnectionState.disconnected,
          ConnectionState.connected,
        ]);
        expect(
          session.state.connections['firetv.lightning'],
          ConnectionState.connected,
        );
      });

      test('a refresh that only times out does not disconnect', () async {
        net.onHttp(
          'GET',
          '/v1/FireTV/status',
          (_) => throw const WatchmeError.timeout('slow'),
        );
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.timeout),
        );
        await clock.flush();
        expect(events.whereType<ConnectionChanged>(), isEmpty);
      });
    });

    test('close emits disconnected and later commands fail', () async {
      await session.close();
      await clock.flush();
      expect(
        events.whereType<ConnectionChanged>().single.state,
        ConnectionState.disconnected,
      );
      expect(
        await session.execute(const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.cancelled),
      );
      await expectLater(
        session.refresh(),
        throwsWatchmeError(WatchmeErrorCode.cancelled),
      );
      await session.close();
    });
  });
}
