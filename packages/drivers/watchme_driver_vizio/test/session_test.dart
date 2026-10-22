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

const _volume = '/menu_native/dynamic/tv_settings/audio/volume';
const _volumeRange = '/menu_native/static/tv_settings/audio/volume';
const _mute = '/menu_native/dynamic/tv_settings/audio/mute';
const _currentInput = '/menu_native/dynamic/tv_settings/devices/current_input';
const _nameInput = '/menu_native/dynamic/tv_settings/devices/name_input';

void main() {
  late VizioSimulator sim;
  final transports = IoHttpTransports();
  final driver = testDriver();

  setUp(() async {
    sim = await VizioSimulator.start(seed: 5);
  });

  tearDown(() => sim.close());

  group('connect', () {
    test(
      'reads deviceinfo and power_mode with the token, nothing else',
      () async {
        final credential = await pair(driver, sim, transports);
        sim.clearLog();
        final session = await driver.connect(
          sim.endpoint,
          transports,
          credential,
        );
        addTearDown(session.close);
        expect(session.driverId, 'vizio.smartcast');
        expect(session.capabilities, vizioDescriptor.ceiling);
        expect(lines(sim.requests), [
          'GET /state/device/deviceinfo',
          'GET /state/device/power_mode',
        ]);
        expect(sim.requests[1].header('auth'), credential.token);
        expect(session.state.power?.value, PowerMode.on);
        expect(session.state.power?.confidence, Confidence.reported);
        expect(session.state.connections, {
          'vizio.smartcast': ConnectionState.connected,
        });
        expect((session as VizioSession).port, sim.apiPort);
      },
    );

    for (final allowWake in [false, true]) {
      test('allowWake: $allowWake never wakes a TV in standby', () async {
        final credential = await pair(driver, sim, transports);
        await sim.pressPowerOnRemote();
        sim.clearLog();
        final session = await driver.connect(
          sim.endpoint,
          transports,
          credential,
          allowWake: allowWake,
        );
        addTearDown(session.close);
        expect(session.state.power?.value, PowerMode.standby);
        expect(session.state.power?.confidence, Confidence.reported);
        expect(sim.power, VizioSimPower.standby);
        expect(sim.requests.every((r) => r.method == 'GET'), isTrue);
        expect(sim.effects, isEmpty);
      });

      test('allowWake: $allowWake fails fast on an Eco-off TV', () async {
        final credential = await pair(driver, sim, transports);
        sim
          ..ecoMode = true
          ..clearLog();
        await sim.pressPowerOnRemote();
        expect(sim.listening, isFalse);
        await expectLater(
          driver.connect(
            sim.endpoint,
            transports,
            credential,
            allowWake: allowWake,
          ),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
        expect(sim.requests, isEmpty);
        expect(sim.power, VizioSimPower.off);
      });
    }

    test('without a credential, or with another driver\'s, it is '
        'unauthorized', () async {
      await expectLater(
        driver.connect(sim.endpoint, transports, null),
        throwsWatchmeError(WatchmeErrorCode.unauthorized),
      );
      await expectLater(
        driver.connect(
          sim.endpoint,
          transports,
          TokenCredential(
            driverId: 'firetv.lightning',
            deviceId: 'tv-1',
            createdAt: DateTime.utc(2026),
            token: 'x',
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.unauthorized),
      );
      expect(sim.requests, isEmpty);
    });

    test('a credential without a valid pin needs pairing again', () async {
      await expectLater(
        driver.connect(
          sim.endpoint,
          transports,
          TokenCredential(
            driverId: 'vizio.smartcast',
            deviceId: 'tv-1',
            createdAt: DateTime.utc(2026),
            token: 'x',
          ),
        ),
        throwsWatchmeError(WatchmeErrorCode.reauthRequired),
      );
    });

    test('a changed certificate fails the pin as a protocol error', () async {
      final credential = await pair(driver, sim, transports);
      await sim.restartWithCertificate(VizioSimulatorCertificate.alternate);
      sim.clearLog();
      await expectLater(
        driver.connect(sim.endpoint, transports, credential),
        throwsWatchmeError(WatchmeErrorCode.protocol),
      );
      expect(sim.requests, isEmpty);
    });

    test('a revoked token needs pairing again, without showing it', () async {
      final credential = await pair(driver, sim, transports);
      sim.revokeTokens();
      Object? error;
      try {
        await driver.connect(sim.endpoint, transports, credential);
      } on WatchmeError catch (e) {
        error = e;
      }
      expect(error, isWatchmeError(WatchmeErrorCode.reauthRequired));
      for (final text in errorTexts(error! as WatchmeError)) {
        expect(text, isNot(contains(credential.token)));
      }
    });

    test('PAIRING_DENIED on power_mode is a revoked token too', () async {
      final credential = await pair(driver, sim, transports);
      sim.respondOnce(
        'GET',
        '/state/device/power_mode',
        200,
        json: {
          'STATUS': {'RESULT': 'PAIRING_DENIED'},
        },
      );
      await expectLater(
        driver.connect(sim.endpoint, transports, credential),
        throwsWatchmeError(WatchmeErrorCode.reauthRequired),
      );
    });

    test('tries the port remembered at pairing first', () async {
      final legacy = await VizioSimulator.start(servesLegacyPort: true);
      addTearDown(legacy.close);
      final credential = await pair(driver, legacy, transports);
      legacy.clearLog();
      final before = transports.network.calls.length;
      // The address alone, as a reconnect after an IP change might know it;
      // the closed primary port stands in for 9000 here so the test never
      // touches a real port on this machine.
      final session = await driver.connect(
        Endpoint('127.0.0.1', ports: {'smartcastLegacy': legacy.apiPort}),
        transports,
        credential,
      );
      addTearDown(session.close);
      expect((session as VizioSession).port, legacy.legacyPort);
      expect(transports.network.calls[before].uri.port, legacy.legacyPort);
    });
  });

  group('session', () {
    late VizioSession session;
    late TokenCredential credential;
    late List<DeviceEvent> events;

    Future<VizioSession> open([VizioDriver? d]) async {
      final s = await (d ?? driver).connect(
        sim.endpoint,
        transports,
        credential,
      ) as VizioSession;
      addTearDown(s.close);
      return s;
    }

    setUp(() async {
      credential = await pair(driver, sim, transports);
      session = await open();
      events = [];
      session.events.listen(events.add);
      sim.clearLog();
    });

    List<(int, int)> sentKeys() => [
      for (final r in sim.requests)
        if (r.path == '/key_command/') ...keysOf(r),
    ];

    group('keys', () {
      test('presses carry the token and the exact KEYLIST', () async {
        expect(
          await session.execute(const PressKey(RemoteKey.select)),
          isConfirmed,
        );
        final request = sim.requests.single;
        expect(lines([request]), ['PUT /key_command/']);
        expect(request.header('auth'), credential.token);
        expect(request.header('content-type'), 'application/json');
        expect(
          request.body,
          '{"KEYLIST":[{"CODESET":3,"CODE":2,"ACTION":"KEYPRESS"}]}',
        );
      });

      test('every mapped key sends its code', () async {
        const keys = [
          RemoteKey.up,
          RemoteKey.down,
          RemoteKey.left,
          RemoteKey.right,
          RemoteKey.back,
          RemoteKey.home,
          RemoteKey.menu,
          RemoteKey.info,
          RemoteKey.exit,
          RemoteKey.captions,
          RemoteKey.channelUp,
          RemoteKey.digit7,
          RemoteKey.play,
          RemoteKey.rewind,
          RemoteKey.input,
        ];
        for (final key in keys) {
          expect(
            await session.execute(PressKey(key)),
            isConfirmed,
            reason: '$key',
          );
        }
        expect(sentKeys(), [
          for (final key in keys)
            (vizioKeys[key]!.codeset, vizioKeys[key]!.code),
        ]);
      });

      test(
        'holding, the power toggle and unmapped keys send nothing',
        () async {
          for (final command in [
            const PressKey(RemoteKey.up, KeyAction.down),
            const PressKey(RemoteKey.up, KeyAction.up),
            const PressKey(RemoteKey.power),
            const PressKey(RemoteKey.guide),
            const PressKey(RemoteKey.settings),
            const PressKey(RemoteKey.playPause),
            const PressKey(RemoteKey.red),
            const PressKey(RemoteKey.backspace),
          ]) {
            expect(
              await session.execute(command),
              isUnsupported(),
              reason: '$command',
            );
          }
          expect(sim.requests, isEmpty);
        },
      );

      test('commands the API cannot express are unsupported', () async {
        for (final command in [
          const MovePointer(1, 1),
          const ShowToast('hi'),
          CastUrl(Uri.parse('http://example.invalid/a.mp4')),
          const TakeScreenshot(),
          const Media(MediaAction.playPause),
          const Media(MediaAction.stop),
          const Media(MediaAction.seek, seekTo: Duration(seconds: 3)),
        ]) {
          expect(
            await session.execute(command),
            isUnsupported(),
            reason: '$command',
          );
        }
        expect(sim.requests, isEmpty);
      });

      test('media keys are discrete', () async {
        for (final action in [
          MediaAction.play,
          MediaAction.pause,
          MediaAction.fastForward,
          MediaAction.rewind,
        ]) {
          expect(await session.execute(Media(action)), isConfirmed);
        }
        expect(sentKeys(), [(2, 3), (2, 2), (2, 0), (2, 1)]);
        expect(sim.playing, isFalse);
      });
    });

    group('power', () {
      test('SetPower sends the discrete keys, never the toggle', () async {
        expect(await session.execute(const SetPower(false)), isConfirmed);
        expect(sim.power, VizioSimPower.standby);
        expect(session.state.power?.value, PowerMode.standby);
        expect(session.state.power?.confidence, Confidence.inferred);
        expect(await session.execute(const SetPower(true)), isConfirmed);
        expect(sim.power, VizioSimPower.on);
        expect(session.state.power?.value, PowerMode.on);
        expect(
          await session.execute(const PressKey(RemoteKey.powerOff)),
          isConfirmed,
        );
        expect(
          await session.execute(const PressKey(RemoteKey.powerOn)),
          isConfirmed,
        );
        expect(sentKeys(), [(11, 0), (11, 1), (11, 0), (11, 1)]);
        expect(sim.effects, isNot(contains('power:toggle')));
      });

      test(
        'off in Eco mode drops the TV; the session reports it lost',
        () async {
          sim.ecoMode = true;
          expect(await session.execute(const SetPower(false)), isConfirmed);
          expect(sim.listening, isFalse);
          await expectLater(
            session.refresh(),
            throwsWatchmeError(WatchmeErrorCode.unreachable),
          );
          await pumpEventQueue();
          expect(
            events.whereType<ConnectionChanged>().last.state,
            ConnectionState.disconnected,
          );
          expect(session.state.power?.confidence, Confidence.stale);
          // On is unreachable now: the engine's Wake-on-LAN takes over.
          expect(
            await session.execute(const SetPower(true)),
            isFailedWith(WatchmeErrorCode.unreachable),
          );
        },
      );
    });

    group('volume', () {
      test('SetVolume reads the HASHVAL, then MODIFYs once', () async {
        expect(await session.execute(const SetVolume(42)), isConfirmed);
        expect(sim.volume, 42);
        expect(lines(sim.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
        ]);
        final body = jsonDecode(sim.requests[2].body) as Map<String, Object?>;
        expect(body['REQUEST'], 'MODIFY');
        expect(body['VALUE'], 42);
        expect(body['HASHVAL'], isA<int>());
        expect(session.state.volume?.value, 42);
        expect(session.state.volume?.confidence, Confidence.inferred);
      });

      test('a volume already at the target is not written', () async {
        await session.execute(SetVolume(sim.volume));
        expect(lines(sim.requests), ['GET $_volumeRange', 'GET $_volume']);
        expect(session.state.volume?.confidence, Confidence.reported);
      });

      /// A session with a simulator whose volume tops out at [maxVolume].
      Future<(VizioSimulator, VizioSession)> openWithMax(int maxVolume) async {
        final tv = await VizioSimulator.start(seed: 6, maxVolume: maxVolume);
        addTearDown(tv.close);
        final paired = await pair(driver, tv, transports);
        final s = await driver.connect(
          tv.endpoint,
          transports,
          paired,
        ) as VizioSession;
        addTearDown(s.close);
        tv.clearLog();
        return (tv, s);
      }

      test('a TV whose maximum is below 100 is set to at most that; the '
          'range is read once per session', () async {
        final (tv, s) = await openWithMax(40);
        expect(s.maxVolume, isNull);
        expect(await s.execute(const SetVolume(80)), isConfirmed);
        expect(tv.volume, 40);
        expect(lines(tv.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
        ]);
        final body = jsonDecode(tv.requests[2].body) as Map<String, Object?>;
        expect(body['VALUE'], 40);
        expect(s.maxVolume, 40);
        expect(s.state.volume?.value, 40);
        // At the maximum already: read, nothing written, and the range is
        // not read again.
        tv.clearLog();
        expect(await s.execute(const SetVolume(100)), isConfirmed);
        expect(lines(tv.requests), ['GET $_volume']);
        expect(s.state.volume?.value, 40);
        expect(s.state.volume?.confidence, Confidence.reported);
        expect(await s.execute(const SetVolume(25)), isConfirmed);
        expect(tv.volume, 25);
        expect(s.state.volume?.value, 25);
      });

      test('a maximum above 100 is bounded by the TV scale', () async {
        final (tv, s) = await openWithMax(150);
        expect(await s.execute(const SetVolume(100)), isConfirmed);
        expect(tv.volume, 100);
        expect(s.maxVolume, 100);
      });

      test('a TV that gives no range has the TV scale, and is not asked '
          'again', () async {
        sim.respondOnce(
          'GET',
          _volumeRange,
          200,
          json: {
            'STATUS': {'RESULT': 'URI_NOT_FOUND'},
          },
        );
        expect(await session.execute(const SetVolume(100)), isConfirmed);
        expect(sim.volume, 100);
        expect(session.maxVolume, 100);
        sim.clearLog();
        expect(await session.execute(const SetVolume(90)), isConfirmed);
        expect(lines(sim.requests), ['GET $_volume', 'PUT $_volume']);
      });

      test('a range read that fails leaves the volume as it was, and is '
          'tried again', () async {
        final slow = await open(
          testDriver(readTimeout: const Duration(milliseconds: 300)),
        );
        sim.clearLog();
        final gate = sim.holdNext('GET', _volumeRange);
        addTearDown(gate.release);
        expect(
          await slow.execute(const SetVolume(30)),
          isFailedWith(WatchmeErrorCode.timeout),
        );
        expect(sim.requests.where((r) => r.method == 'PUT'), isEmpty);
        expect(slow.maxVolume, isNull);
        gate.release();
        expect(await slow.execute(const SetVolume(30)), isConfirmed);
        expect(sim.volume, 30);
        expect(slow.maxVolume, 100);
      });

      test('a range read the TV could not answer (BUSY, HTTP 500, a '
          'malformed body) writes nothing and assumes no maximum: the next '
          'SetVolume asks again', () async {
        final (tv, s) = await openWithMax(40);
        final before = tv.volume;
        for (final (status, body, code) in <(int, Object, WatchmeErrorCode)>[
          (
            200,
            {
              'STATUS': {'RESULT': 'BUSY'},
            },
            WatchmeErrorCode.rejected,
          ),
          (500, 'Unhandled Exception', WatchmeErrorCode.protocol),
          (200, '<html>oops</html>', WatchmeErrorCode.protocol),
          (
            200,
            {
              'ITEMS': [
                {'CNAME': 'volume', 'MAXIMUM': 40},
              ],
            },
            WatchmeErrorCode.protocol,
          ),
          (
            200,
            {
              'ITEMS': [
                {'CNAME': 'volume', 'MAXIMUM': 'forty'},
              ],
              'STATUS': {'RESULT': 'SUCCESS'},
            },
            WatchmeErrorCode.protocol,
          ),
          (
            200,
            {
              'ITEMS': [
                {'CNAME': 'volume', 'MAXIMUM': 0},
              ],
              'STATUS': {'RESULT': 'SUCCESS'},
            },
            WatchmeErrorCode.protocol,
          ),
        ]) {
          tv
            ..clearLog()
            ..respondOnce(
              'GET',
              _volumeRange,
              status,
              body: body is String ? body : '',
              json: body is Map<String, Object?> ? body : null,
            );
          expect(
            await s.execute(const SetVolume(80)),
            isFailedWith(code),
            reason: '$status $body',
          );
          expect(lines(tv.requests), ['GET $_volumeRange'], reason: '$body');
          expect(tv.volume, before, reason: '$body');
          expect(s.maxVolume, isNull, reason: '$body');
        }
        tv.clearLog();
        expect(await s.execute(const SetVolume(80)), isConfirmed);
        expect(lines(tv.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
        ]);
        expect(tv.volume, 40);
        expect(s.maxVolume, 40);
      });

      test(
        'a TV that says it has no range (URI_NOT_FOUND, HTTP 404, or an '
        'answer without MAXIMUM) keeps the TV scale for the session',
        () async {
          for (final (status, json) in <(int, Map<String, Object?>?)>[
            (
              200,
              {
                'STATUS': {'RESULT': 'URI_NOT_FOUND'},
              },
            ),
            (404, null),
            (
              200,
              {
                'ITEMS': [
                  {'CNAME': 'volume', 'MINIMUM': 0},
                ],
                'STATUS': {'RESULT': 'SUCCESS'},
              },
            ),
            (
              200,
              {
                'STATUS': {'RESULT': 'SUCCESS'},
              },
            ),
          ]) {
            final (tv, s) = await openWithMax(40);
            tv.respondOnce('GET', _volumeRange, status, json: json);
            expect(
              await s.execute(const SetVolume(30)),
              isConfirmed,
              reason: '$status $json',
            );
            expect(tv.volume, 30, reason: '$json');
            expect(s.maxVolume, 100, reason: '$json');
            tv.clearLog();
            expect(await s.execute(const SetVolume(20)), isConfirmed);
            expect(lines(tv.requests), [
              'GET $_volume',
              'PUT $_volume',
            ], reason: '$json');
          }
        },
      );

      test('a stale HASHVAL is read again and written once more', () async {
        sim.respondOnce(
          'PUT',
          _volume,
          200,
          json: {
            'STATUS': {'RESULT': 'HASHVAL_ERROR'},
          },
        );
        expect(await session.execute(const SetVolume(30)), isConfirmed);
        expect(sim.volume, 30);
        expect(lines(sim.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
          'GET $_volume',
          'PUT $_volume',
        ]);
      });

      test('a stale HASHVAL never applies twice: a fresh read already at '
          'the target writes nothing', () async {
        sim.respondOnce(
          'PUT',
          _volume,
          200,
          json: {
            'STATUS': {'RESULT': 'HASHVAL_ERROR'},
          },
        );
        // Someone else sets the target level between the read and the
        // write (which is why the HASHVAL went stale).
        late StreamSubscription<VizioSimRequest> sub;
        sub = sim.onRequest.listen((r) {
          if (r.method == 'PUT' && r.path == _volume) {
            sim.volume = 30;
            unawaited(sub.cancel());
          }
        });
        expect(await session.execute(const SetVolume(30)), isConfirmed);
        expect(lines(sim.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
          'GET $_volume',
        ]);
      });

      test('a change made on the TV between the read and the write makes the '
          'HASHVAL stale; the write is redone once on fresh values', () async {
        // The physical remote changes the volume, and switches the input,
        // just before the driver's write arrives: the TV refuses the stale
        // HASHVAL, nothing is applied twice.
        late StreamSubscription<VizioSimRequest> sub;
        sub = sim.onRequest.listen((r) {
          if (r.method != 'PUT') return;
          if (r.path == _volume) sim.volume = 50;
          unawaited(sub.cancel());
        });
        expect(await session.execute(const SetVolume(30)), isConfirmed);
        expect(sim.volume, 30);
        expect(lines(sim.requests), [
          'GET $_volumeRange',
          'GET $_volume',
          'PUT $_volume',
          'GET $_volume',
          'PUT $_volume',
        ]);
        expect(sim.effects, ['volume:30']);

        sim.clearLog();
        sub = sim.onRequest.listen((r) {
          if (r.method != 'PUT') return;
          if (r.path == _currentInput) sim.currentInput = 'hdmi3';
          unawaited(sub.cancel());
        });
        expect(await session.execute(const SelectInput('hdmi2')), isConfirmed);
        expect(sim.currentInput, 'hdmi2');
        expect(
          lines(sim.requests).where((l) => l == 'PUT $_currentInput'),
          hasLength(2),
        );
        expect(sim.effects, ['input:hdmi2']);
      });

      test('a second stale HASHVAL is rejected, with no third write', () async {
        for (var i = 0; i < 2; i++) {
          sim.respondOnce(
            'PUT',
            _volume,
            200,
            json: {
              'STATUS': {'RESULT': 'HASHVAL_ERROR'},
            },
          );
        }
        expect(
          await session.execute(const SetVolume(30)),
          isFailedWith(
            WatchmeErrorCode.rejected,
            rawDeviceMessage: contains('HASHVAL_ERROR'),
          ),
        );
        expect(
          lines(sim.requests).where((l) => l.startsWith('PUT')),
          hasLength(2),
        );
      });

      test('a write that timed out is not retried', () async {
        final slow = await open(
          testDriver(writeTimeout: const Duration(milliseconds: 300)),
        );
        final slowEvents = <DeviceEvent>[];
        slow.events.listen(slowEvents.add);
        sim.clearLog();
        final gate = sim.holdNext('PUT', _volume);
        addTearDown(gate.release);
        expect(
          await slow.execute(const SetVolume(30)),
          isFailedWith(WatchmeErrorCode.timeout),
        );
        expect(
          lines(sim.requests).where((l) => l.startsWith('PUT')),
          hasLength(1),
        );
        // One slow answer does not drop the session.
        expect(slowEvents.whereType<ConnectionChanged>(), isEmpty);
      });

      test('StepVolume is one KEYLIST; long ones are chunked', () async {
        expect(await session.execute(const StepVolume(3)), isConfirmed);
        expect(sim.volume, 18);
        expect(sim.requests, hasLength(1));
        expect(await session.execute(const StepVolume(-2)), isConfirmed);
        expect(sim.volume, 16);
        expect(await session.execute(const StepVolume(0)), isConfirmed);
        expect(sim.requests, hasLength(2));
        sim.clearLog();
        expect(await session.execute(const StepVolume(80)), isConfirmed);
        expect([for (final r in sim.requests) keysOf(r).length], [50, 30]);
        expect(sim.volume, 96);
        expect(await session.execute(const StepVolume(101)), isUnsupported());
      });
    });

    group('mute', () {
      test('discrete mute through the settings tree', () async {
        expect(await session.execute(const SetMute(true)), isConfirmed);
        expect(sim.muted, isTrue);
        expect(lines(sim.requests), ['GET $_mute', 'PUT $_mute']);
        expect(jsonDecode(sim.requests[1].body), containsPair('VALUE', 'On'));
        sim.clearLog();
        expect(await session.execute(const SetMute(true)), isConfirmed);
        expect(lines(sim.requests), ['GET $_mute']);
        expect(await session.execute(const SetMute(false)), isConfirmed);
        expect(sim.muted, isFalse);
      });

      test(
        'in Quick Start standby the TV acknowledges a mute change it '
        'ignores: the state stays inferred until a read says otherwise',
        () async {
          await sim.pressPowerOnRemote();
          expect(sim.power, VizioSimPower.standby);
          expect(await session.execute(const SetMute(true)), isConfirmed);
          expect(sim.muted, isFalse);
          expect(session.state.muted?.value, isTrue);
          expect(session.state.muted?.confidence, Confidence.inferred);
          final state = await session.refresh();
          expect(state.muted?.value, isFalse);
          expect(state.muted?.confidence, Confidence.reported);
        },
      );

      test('SetMute(null) presses the mute toggle', () async {
        expect(await session.execute(const SetMute(null)), isConfirmed);
        expect(sentKeys(), [(5, 4)]);
        expect(sim.muted, isTrue);
      });
    });

    group('inputs', () {
      test('selects by cname with the current input\'s HASHVAL', () async {
        expect(await session.execute(const SelectInput('hdmi2')), isConfirmed);
        expect(sim.currentInput, 'hdmi2');
        expect(lines(sim.requests), [
          'GET $_nameInput',
          'GET $_currentInput',
          'PUT $_currentInput',
        ]);
        expect(
          jsonDecode(sim.requests[2].body),
          containsPair('VALUE', 'hdmi2'),
        );
        expect(session.state.input?.value, 'hdmi2');
      });

      test(
        'a display name resolves to the cname; the list is read once',
        () async {
          expect(
            await session.execute(const SelectInput('HDMI-1')),
            isConfirmed,
          );
          expect(sim.currentInput, 'hdmi1');
          sim.clearLog();
          expect(
            await session.execute(const PressKey(RemoteKey.inputHdmi3)),
            isConfirmed,
          );
          expect(sim.currentInput, 'hdmi3');
          expect(lines(sim.requests), isNot(contains('GET $_nameInput')));
          expect(
            await session.execute(const PressKey(RemoteKey.inputAv1)),
            isConfirmed,
          );
          expect(sim.currentInput, 'comp');
        },
      );

      test('the input already in front is not written', () async {
        expect(await session.execute(const SelectInput('cast')), isConfirmed);
        expect(lines(sim.requests), ['GET $_nameInput', 'GET $_currentInput']);
        expect(session.state.input?.confidence, Confidence.reported);
      });

      test('an unknown input is unsupported and sends no write', () async {
        expect(
          await session.execute(const SelectInput('hdmi9')),
          isUnsupported(contains('hdmi1')),
        );
        expect(sim.requests.where((r) => r.method == 'PUT'), isEmpty);
      });

      test(
        'older firmware that refuses the cname gets the display name',
        () async {
          sim.legacyFirmware = true;
          sim.respondOnce(
            'PUT',
            _currentInput,
            200,
            json: {
              'STATUS': {'RESULT': 'FAILURE'},
            },
          );
          expect(
            await session.execute(const SelectInput('hdmi2')),
            isConfirmed,
          );
          expect(sim.currentInput, 'hdmi2');
          final puts = sim.requests.where((r) => r.method == 'PUT').toList();
          expect(
            [for (final p in puts) (jsonDecode(p.body) as Map)['VALUE']],
            ['hdmi2', 'HDMI-2'],
          );
          // Both carry the current input's HASHVAL, unchanged by FAILURE.
          expect(
            (jsonDecode(puts[0].body) as Map)['HASHVAL'],
            (jsonDecode(puts[1].body) as Map)['HASHVAL'],
          );
        },
      );

      test('a refusal of both names is rejected', () async {
        for (var i = 0; i < 2; i++) {
          sim.respondOnce(
            'PUT',
            _currentInput,
            200,
            json: {
              'STATUS': {'RESULT': 'FAILURE'},
            },
          );
        }
        expect(
          await session.execute(const SelectInput('hdmi2')),
          isFailedWith(WatchmeErrorCode.rejected),
        );
        expect(sim.currentInput, 'cast');
      });
    });

    group('apps, text and channels', () {
      test('launches from the built-in table', () async {
        expect(await session.execute(const LaunchApp('netflix')), isConfirmed);
        expect(sim.currentApp?.name, 'Netflix');
        expect(
          sim.requests.single.body,
          '{"VALUE":{"APP_ID":"1","NAME_SPACE":3,"MESSAGE":null}}',
        );
        expect(session.state.foregroundApp?.value.id, 'netflix');
      });

      test('unknown apps, raw ids and deep links send nothing', () async {
        for (final command in [
          const LaunchApp('hulu'),
          const LaunchApp('3001'),
          LaunchApp('netflix', deepLink: Uri.parse('nflx://title/1')),
          const LaunchApp('youtube', params: {'v': 'x'}),
        ]) {
          expect(
            await session.execute(command),
            isUnsupported(),
            reason: '$command',
          );
        }
        expect(sim.requests, isEmpty);
      });

      test('ListApps returns the launch table without asking the TV', () async {
        final result = await session.execute(const ListApps());
        final apps = ((result as Confirmed).payload! as AppListPayload).apps;
        expect(apps.map((a) => a.id), ['netflix', 'youtube', 'smartcast-home']);
        expect(sim.requests, isEmpty);
      });

      test(
        'TypeText sends ASCII keys in one KEYLIST, chunked when long',
        () async {
          expect(await session.execute(const TypeText('Hi 5')), isConfirmed);
          expect(sim.typedText, 'Hi 5');
          expect(sim.requests, hasLength(1));
          sim.clearLog();
          expect(await session.execute(TypeText('x' * 120)), isConfirmed);
          expect(
            [for (final r in sim.requests) keysOf(r).length],
            [50, 50, 20],
          );
          for (final command in [
            const TypeText('café'),
            const TypeText('a', replace: true),
            TypeText('y' * 257),
          ]) {
            expect(
              await session.execute(command),
              isUnsupported(),
              reason: '$command',
            );
          }
          expect(sim.requests, hasLength(3));
        },
      );

      test('a tuner-less TV refuses channel entry: rejected, nothing '
          'typed', () async {
        sim.hasTuner = false;
        expect(
          await session.execute(const TuneChannel('7.1')),
          isFailedWith(
            WatchmeErrorCode.rejected,
            rawDeviceMessage: contains('FAILURE'),
          ),
        );
        expect(
          await session.execute(const PressKey(RemoteKey.channelUp)),
          isFailedWith(WatchmeErrorCode.rejected),
        );
        expect(sim.keyPresses, isEmpty);
      });

      test('TuneChannel types the number as ASCII', () async {
        expect(await session.execute(const TuneChannel('7.1')), isConfirmed);
        expect(sentKeys(), [(0, 55), (0, 46), (0, 49)]);
        expect(
          await session.execute(const TuneChannel('abc')),
          isUnsupported(),
        );
        expect(sim.requests, hasLength(1));
      });
    });

    group('failures', () {
      test(
        'a TV that left the network: unreachable, lost, then back',
        () async {
          await sim.vanish();
          expect(
            await session.execute(const PressKey(RemoteKey.up)),
            isFailedWith(WatchmeErrorCode.unreachable),
          );
          await pumpEventQueue();
          final lost = events.whereType<ConnectionChanged>().single;
          expect(lost.state, ConnectionState.disconnected);
          expect(lost.error?.code, WatchmeErrorCode.unreachable);
          expect(session.state.power?.confidence, Confidence.stale);
          await sim.reappear();
          expect(
            await session.execute(const PressKey(RemoteKey.up)),
            isConfirmed,
          );
          await pumpEventQueue();
          expect(
            events.whereType<ConnectionChanged>().last.state,
            ConnectionState.connected,
          );
        },
      );

      test('three timeouts in a row drop the session; one does not', () async {
        final slow = await open(
          testDriver(writeTimeout: const Duration(milliseconds: 200)),
        );
        final slowEvents = <DeviceEvent>[];
        slow.events.listen(slowEvents.add);
        final gates = <VizioSimGate>[];
        for (var i = 0; i < 3; i++) {
          final gate = sim.holdNext('PUT', '/key_command/');
          gates.add(gate);
          addTearDown(gate.release);
          expect(
            await slow.execute(const PressKey(RemoteKey.up)),
            isFailedWith(WatchmeErrorCode.timeout),
          );
          await pumpEventQueue();
          expect(
            slowEvents.whereType<ConnectionChanged>(),
            i < 2 ? isEmpty : hasLength(1),
          );
        }
        await pumpEventQueue();
        expect(
          slowEvents.whereType<ConnectionChanged>().single.state,
          ConnectionState.disconnected,
        );
      });

      test('a chunk refused after an earlier one was delivered is a partial '
          'delivery', () async {
        final gate = sim.holdNext('PUT', '/key_command/');
        final result = session.execute(const StepVolume(80));
        await gate.reached;
        sim.respondOnce('PUT', '/key_command/', 500, body: 'boom');
        gate.release();
        final failed = await result;
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(failed.partiallyDelivered, isTrue);
        final cause = (failed as Failed).error.cause! as WatchmeError;
        expect(cause.code, WatchmeErrorCode.protocol);
        expect(cause.rawDeviceMessage, 'boom');
      });

      test('close stops a command before its next request', () async {
        final gate = sim.holdNext('PUT', '/key_command/');
        final result = session.execute(const StepVolume(80));
        final queued = session.execute(const PressKey(RemoteKey.up));
        await gate.reached;
        await session.close();
        gate.release();
        final failed = await result;
        expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(
          ((failed as Failed).error.cause! as WatchmeError).code,
          WatchmeErrorCode.cancelled,
        );
        expect(await queued, isFailedWith(WatchmeErrorCode.cancelled));
        expect(
          sim.requests.where((r) => r.path == '/key_command/'),
          hasLength(1),
        );
        expect(
          await session.execute(const PressKey(RemoteKey.up)),
          isFailedWith(WatchmeErrorCode.cancelled),
        );
      });

      test(
        'a revoked token fails as reauthRequired and is reported once',
        () async {
          sim.revokeTokens();
          expect(
            await session.execute(const PressKey(RemoteKey.up)),
            isFailedWith(WatchmeErrorCode.reauthRequired),
          );
          expect(
            await session.execute(const SetVolume(10)),
            isFailedWith(WatchmeErrorCode.reauthRequired),
          );
          await pumpEventQueue();
          expect(events.whereType<ReauthRequired>(), hasLength(1));
          await pumpEventQueue();
          expect(
            events.whereType<ConnectionChanged>().single.state,
            ConnectionState.failed,
          );
          await expectLater(
            session.refresh(),
            throwsWatchmeError(WatchmeErrorCode.reauthRequired),
          );
        },
      );

      test('a PAIRING_DENIED envelope on a read is a revoked token: refresh '
          'and polling report it, not a stale power reading', () async {
        sim.respondOnce(
          'GET',
          '/state/device/power_mode',
          200,
          json: {
            'STATUS': {'RESULT': 'PAIRING_DENIED'},
            'URI': '/state/device/power_mode',
          },
        );
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.reauthRequired),
        );
        await pumpEventQueue();
        expect(events.whereType<ReauthRequired>(), hasLength(1));
        expect(
          events.whereType<ConnectionChanged>().single.state,
          ConnectionState.failed,
        );
        // Nothing after the refused read: the token is not sent again.
        expect(lines(sim.requests), ['GET /state/device/power_mode']);
      });

      test('a REQUIRES_PAIRING envelope is a revoked token too', () async {
        sim.respondOnce(
          'PUT',
          '/app/launch',
          200,
          json: {
            'STATUS': {'RESULT': 'REQUIRES_PAIRING'},
          },
        );
        expect(
          await session.execute(const LaunchApp('youtube')),
          isFailedWith(WatchmeErrorCode.reauthRequired),
        );
        await pumpEventQueue();
        expect(events.whereType<ReauthRequired>(), hasLength(1));
      });

      test('PAIRING_DENIED on a control call is a revoked token, not a '
          'wrong PIN', () async {
        sim.respondOnce(
          'PUT',
          '/key_command/',
          200,
          json: {
            'STATUS': {'RESULT': 'PAIRING_DENIED'},
          },
        );
        expect(
          await session.execute(const PressKey(RemoteKey.up)),
          isFailedWith(WatchmeErrorCode.reauthRequired),
        );
        await pumpEventQueue();
        expect(events.whereType<ReauthRequired>(), hasLength(1));
      });

      test(
        'device status words map to codes and keep the device text',
        () async {
          Future<CommandResult> launchAnswering(int status, Object body) {
            sim.respondOnce(
              'PUT',
              '/app/launch',
              status,
              body: body is String ? body : '',
              json: body is Map<String, Object?> ? body : null,
            );
            return session.execute(const LaunchApp('youtube'));
          }

          Map<String, Object?> envelope(String result) => {
            'STATUS': {'RESULT': result},
            'URI': '/app/launch',
          };
          expect(
            await launchAnswering(200, envelope('URI_NOT_FOUND')),
            isFailedWith(
              WatchmeErrorCode.unsupported,
              rawDeviceMessage: contains('URI_NOT_FOUND'),
            ),
          );
          expect(
            await launchAnswering(200, envelope('FAILURE')),
            isFailedWith(WatchmeErrorCode.rejected),
          );
          expect(
            await launchAnswering(200, envelope('BUSY')),
            isFailedWith(WatchmeErrorCode.rejected),
          );
          expect(
            await launchAnswering(200, envelope('PROXY_ERROR')),
            isFailedWith(WatchmeErrorCode.protocol),
          );
          expect(
            await launchAnswering(200, envelope('REQUIRES_SYSTEM_PIN')),
            isFailedWith(WatchmeErrorCode.rejected),
          );
          expect(
            await launchAnswering(500, 'Unhandled Exception'),
            isFailedWith(
              WatchmeErrorCode.protocol,
              rawDeviceMessage: 'Unhandled Exception',
            ),
          );
          expect(
            await launchAnswering(200, 'not json'),
            isFailedWith(WatchmeErrorCode.protocol),
          );
          await pumpEventQueue();
          expect(events.whereType<ReauthRequired>(), isEmpty);
        },
      );

      test('device errors and events never repeat the token', () async {
        final token = credential.token;
        sim.respondOnce(
          'PUT',
          '/app/launch',
          200,
          json: {
            'STATUS': {'RESULT': 'FAILURE', 'DETAIL': 'bad AUTH $token'},
            'AUTH': token,
            'escaped': jsonEncode(jsonEncode(token)),
            'url': Uri.encodeComponent('x$token'),
          },
        );
        final failed = await session.execute(const LaunchApp('youtube'));
        expect(failed, isFailedWith(WatchmeErrorCode.rejected));
        for (final text in errorTexts((failed as Failed).error)) {
          expect(text, isNot(contains(token)), reason: text);
        }
        sim.revokeTokens();
        await session.execute(const PressKey(RemoteKey.up));
        await pumpEventQueue();
        for (final event in events) {
          expect('$event', isNot(contains(token)));
        }
      });

      test('a status word is shown only when it is a known one', () async {
        // A TV that echoes the token as its status: the token, which the
        // message would show upper-cased, is never shown.
        final token = credential.token;
        sim.respondOnce(
          'PUT',
          '/key_command/',
          200,
          json: {
            'STATUS': {'RESULT': token},
          },
        );
        final failed = await session.execute(const PressKey(RemoteKey.up));
        expect(
          failed,
          isFailedWith(
            WatchmeErrorCode.protocol,
            message: 'Key up: unexpected SmartCast status',
          ),
        );
        for (final text in errorTexts((failed as Failed).error)) {
          expect(
            text.toLowerCase(),
            isNot(contains(token.toLowerCase())),
            reason: text,
          );
        }
        // A known word is shown, so the user can tell what happened.
        sim.respondOnce(
          'PUT',
          '/key_command/',
          200,
          json: {
            'STATUS': {'RESULT': 'BUSY'},
          },
        );
        expect(
          await session.execute(const PressKey(RemoteKey.up)),
          isFailedWith(
            WatchmeErrorCode.rejected,
            message: 'Key up: the TV is busy (BUSY)',
          ),
        );
      });

      test('requests never overlap, whoever sends them', () async {
        sim.clearLog();
        await Future.wait([
          session.execute(const SetVolume(20)),
          session.refresh(),
          session.execute(const SelectInput('hdmi1')),
          session.execute(const StepVolume(2)),
          session.refresh(),
        ]);
        expect(sim.maxConcurrentRequests, 1);
        expect(sim.volume, 22);
      });
    });

    group('refresh', () {
      test('reads power, volume, mute, input and app, reported', () async {
        sim
          ..volume = 33
          ..muted = true;
        await session.execute(const LaunchApp('youtube'));
        sim.clearLog();
        await pumpEventQueue();
        events.clear();
        final state = await session.refresh();
        expect(lines(sim.requests), [
          'GET /state/device/power_mode',
          'GET $_volume',
          'GET $_mute',
          'GET $_currentInput',
          'GET $_nameInput',
          'GET /app/current',
        ]);
        expect(state.power?.value, PowerMode.on);
        expect(state.volume?.value, 33);
        expect(state.muted?.value, isTrue);
        expect(state.input?.value, 'cast');
        expect(state.foregroundApp?.value.id, 'youtube');
        for (final o in [
          state.power,
          state.volume,
          state.muted,
          state.input,
          state.foregroundApp,
        ]) {
          expect(o?.confidence, Confidence.reported);
        }
        await pumpEventQueue();
        expect(events.whereType<StateChanged>(), hasLength(1));
        // Nothing changed: no event, and the input list is not read again.
        await pumpEventQueue();
        events.clear();
        sim.clearLog();
        await session.refresh();
        await pumpEventQueue();
        expect(events, isEmpty);
        expect(lines(sim.requests), isNot(contains('GET $_nameInput')));
        // Passive: reads only.
        expect(sim.requests.every((r) => r.method == 'GET'), isTrue);
      });

      test(
        'an HDMI input reports its cname; an unknown app a generic id',
        () async {
          await session.execute(const SelectInput('hdmi2'));
          sim.currentApp = const VizioSimApp('Pluto', '77', 6);
          final state = await session.refresh();
          expect(state.input?.value, 'hdmi2');
          expect(state.foregroundApp?.value.id, 'vizio:6:77');
        },
      );

      test('no app in front makes the last one stale', () async {
        await session.execute(const LaunchApp('netflix'));
        await session.refresh();
        sim
          ..currentApp = null
          ..omitAppValueWhenNone = true;
        final state = await session.refresh();
        expect(state.foregroundApp?.confidence, Confidence.stale);
      });

      test('standby reports standby and stales the input and app', () async {
        await session.refresh();
        await sim.pressPowerOnRemote();
        final state = await session.refresh();
        expect(state.power?.value, PowerMode.standby);
        expect(state.power?.confidence, Confidence.reported);
        expect(state.input?.confidence, Confidence.stale);
        expect(state.volume?.confidence, Confidence.reported);
      });

      test('a TV that is gone throws unreachable and goes stale', () async {
        await session.refresh();
        await sim.vanish();
        await expectLater(
          session.refresh(),
          throwsWatchmeError(WatchmeErrorCode.unreachable),
        );
        expect(session.state.power?.confidence, Confidence.stale);
        expect(
          session.state.connections['vizio.smartcast'],
          ConnectionState.disconnected,
        );
      });

      test('polls while someone listens, and stops after', () async {
        final polled = await open(
          testDriver(pollInterval: const Duration(milliseconds: 50)),
        );
        final changed = Completer<int>();
        final sub = polled.events.listen((event) {
          if (event case StateChanged(state: DeviceState(:final volume?))
              when volume.value == 61 && !changed.isCompleted) {
            changed.complete(volume.value);
          }
        });
        sim.volume = 61;
        expect(await changed.future.timeout(const Duration(seconds: 5)), 61);
        await sub.cancel();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        sim.clearLog();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(sim.requests, isEmpty);
      });

      test('close reports disconnected and ends the events', () async {
        final done = Completer<void>();
        final closing = await open();
        final seen = <DeviceEvent>[];
        closing.events.listen(seen.add, onDone: done.complete);
        await closing.close();
        await done.future;
        await pumpEventQueue();
        expect(
          seen.whereType<ConnectionChanged>().single.state,
          ConnectionState.disconnected,
        );
        await expectLater(
          closing.refresh(),
          throwsWatchmeError(WatchmeErrorCode.cancelled),
        );
      });

      test('a TV lost during the optional reads stays lost: the refresh '
          'throws and commits nothing', () async {
        final slow = await open(
          testDriver(readTimeout: const Duration(milliseconds: 200)),
        );
        final seen = <DeviceEvent>[];
        slow.events.listen(seen.add);
        await slow.refresh();
        sim.clearLog();
        // power_mode answers; then three reads in a row time out.
        final gates = [
          for (final path in [_volume, _mute, _currentInput, '/app/current'])
            sim.holdNext('GET', path),
        ];
        addTearDown(() {
          for (final gate in gates) {
            gate.release();
          }
        });
        await expectLater(
          slow.refresh(),
          throwsWatchmeError(WatchmeErrorCode.timeout),
        );
        expect(slow.state.connections, {
          'vizio.smartcast': ConnectionState.disconnected,
        });
        expect(slow.state.power?.confidence, Confidence.stale);
        await pumpEventQueue();
        expect(seen.whereType<ConnectionChanged>().map((e) => e.state), [
          ConnectionState.disconnected,
        ]);
      });

      test('a refresh whose read is in flight when the session closes '
          'commits nothing: the session stays disconnected', () async {
        final gate = sim.holdNext('GET', '/app/current');
        addTearDown(gate.release);
        final refreshing = session.refresh();
        await gate.reached;
        await session.close();
        expect(session.state.connections, {
          'vizio.smartcast': ConnectionState.disconnected,
        });
        gate.release();
        await expectLater(
          refreshing,
          throwsWatchmeError(WatchmeErrorCode.cancelled),
        );
        expect(session.state.connections, {
          'vizio.smartcast': ConnectionState.disconnected,
        });
      });
    });
  });

  group('with a scripted network', () {
    late FakeNetworkStack net;
    late FakeTransports fake;
    const host = '10.0.0.9';
    final fingerprint = fakeFingerprint('vizio-scripted');
    final credential = TokenCredential(
      driverId: 'vizio.smartcast',
      deviceId: 'tv-1',
      createdAt: DateTime.utc(2026),
      token: 'tok-scripted-123',
      peerCertSha256: fingerprint,
    );
    final success = HttpResult.json(200, {
      'STATUS': {'RESULT': 'SUCCESS', 'DETAIL': 'Success'},
    });

    setUp(() {
      net = FakeNetworkStack();
      fake = FakeTransports(network: net);
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
        'GET',
        '/state/device/power_mode',
        HttpResult.json(200, {
          'ITEMS': [
            {'CNAME': 'power_mode', 'TYPE': 'T_VALUE_V1', 'VALUE': 1},
          ],
          'STATUS': {'RESULT': 'SUCCESS'},
        }),
      );
    });

    Future<DriverSession> open() async {
      final session = await VizioDriver(pollInterval: null)
          .connect(const Endpoint(host), fake, credential);
      addTearDown(session.close);
      return session;
    }

    test('every call pins the certificate and sends the AUTH header', () async {
      net.respond('PUT', '/key_command/', success);
      final session = await open();
      await session.execute(const PressKey(RemoteKey.back));
      expect(net.httpLog, hasLength(3));
      for (final record in net.httpLog) {
        expect(record.tls.pins, {fingerprint});
      }
      expect(net.httpCalls[0].header('AUTH'), isNull); // deviceinfo
      expect(net.httpCalls[1].header('AUTH'), 'tok-scripted-123');
      expect(net.httpCalls[2].header('AUTH'), 'tok-scripted-123');
      expect(
        net.httpCalls[2].uri.toString(),
        'https://$host:7345/key_command/',
      );
    });

    test('a chunk that found the TV gone after an earlier one was '
        'delivered is partial, never unreachable', () async {
      var puts = 0;
      net.onHttp('PUT', '/key_command/', (_) {
        if (++puts == 1) return success;
        throw const WatchmeError.unreachable('Connection refused');
      });
      final session = await open();
      final result = await session.execute(TypeText('z' * 60));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        ((result as Failed).error.cause! as WatchmeError).code,
        WatchmeErrorCode.unreachable,
      );
      expect(puts, 2);
    });

    test('a first chunk that reached nothing is unreachable, and nothing '
        'more is sent', () async {
      var puts = 0;
      net.onHttp('PUT', '/key_command/', (_) {
        puts++;
        throw const WatchmeError.unreachable('Connection refused');
      });
      final session = await open();
      expect(
        await session.execute(const StepVolume(80)),
        isFailedWith(WatchmeErrorCode.unreachable),
      );
      expect(puts, 1);
    });

    test('a timeout after an earlier chunk is partial too', () async {
      var puts = 0;
      net.onHttp('PUT', '/key_command/', (_) {
        if (++puts == 1) return success;
        throw const WatchmeError.timeout('No answer');
      });
      final session = await open();
      final result = await session.execute(const StepVolume(-60));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(puts, 2);
    });

    test('a 200 without an envelope is a protocol error', () async {
      net.respond('PUT', '/key_command/', HttpResult(200));
      final session = await open();
      expect(
        await session.execute(const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.protocol, rawDeviceMessage: 'HTTP 200'),
      );
    });
  });
}
