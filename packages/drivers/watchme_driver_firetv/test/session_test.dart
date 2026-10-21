import 'dart:async';

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

    test('a wake that does not open the API fails the command as '
        'unreachable', () async {
      tv
        ..sleep()
        ..wakeOnDial = false;
      final result = session.execute(const PressKey(RemoteKey.home));
      await clock.advance(const Duration(seconds: 7));
      expect(await result, isFailedWith(WatchmeErrorCode.unreachable));
      expect(tv.wakes, 2);
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
