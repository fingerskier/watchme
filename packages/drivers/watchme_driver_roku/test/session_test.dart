import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fixtures.dart';

void main() {
  late FakeRoku roku;
  late FakeClock clock;
  late RokuSession session;

  Future<RokuSession> open({
    String deviceInfo = tclTvDeviceInfo,
    Duration? pollInterval,
    int replaceBackspaces = 4,
  }) async {
    roku = FakeRoku(deviceInfo: deviceInfo);
    clock = FakeClock(DateTime.utc(2026, 10, 21, 12));
    final driver = RokuDriver(
      clock: clock,
      pollInterval: pollInterval,
      replaceBackspaces: replaceBackspaces,
    );
    final s = await driver.connect(roku.endpoint, roku.transports, null);
    addTearDown(s.close);
    return s as RokuSession;
  }

  /// Runs [command] and returns the POSTs it made.
  Future<(CommandResult, List<String>)> run(Command command) async {
    final mark = roku.mark();
    final result = await session.execute(command);
    return (result, roku.postsSince(mark));
  }

  group('keys', () {
    setUp(() async => session = await open());

    test('every mapped RemoteKey posts its ECP key', () async {
      for (final MapEntry(:key, :value) in rokuKeyNames.entries) {
        final (result, posts) = await run(PressKey(key));
        expect(result, isConfirmed, reason: key.name);
        expect(posts, ['/keypress/$value'], reason: key.name);
      }
    });

    test('the Power toggle cannot be held', () async {
      for (final action in [KeyAction.down, KeyAction.up]) {
        final (result, posts) = await run(PressKey(RemoteKey.power, action));
        expect(result, isUnsupported(contains('toggle')), reason: '$action');
        expect(posts, isEmpty);
      }
      expect((await run(const PressKey(RemoteKey.power))).$2, [
        '/keypress/Power',
      ]);
    });

    test('keydown and keyup', () async {
      final (down, downPosts) = await run(
        const PressKey(RemoteKey.right, KeyAction.down),
      );
      final (up, upPosts) = await run(
        const PressKey(RemoteKey.right, KeyAction.up),
      );
      expect(down, isConfirmed);
      expect(up, isConfirmed);
      expect([...downPosts, ...upPosts], ['/keydown/Right', '/keyup/Right']);
    });

    test('unmapped keys are Unsupported and send nothing', () async {
      for (final key in RemoteKey.values.where(
        (k) =>
            !rokuKeyNames.containsKey(k) &&
            k != RemoteKey.play &&
            k != RemoteKey.pause,
      )) {
        final (result, posts) = await run(PressKey(key));
        expect(result, isUnsupported(contains(key.name)), reason: key.name);
        expect(posts, isEmpty);
      }
    });

    test('every request carries the IP Host header', () async {
      await session.execute(const PressKey(RemoteKey.home));
      for (final call in roku.net.httpCalls) {
        expect(call.header('Host'), '192.0.2.10:8060');
        if (call.method == 'POST') expect(call.body, isEmpty);
      }
    });

    test('commands reach the device in the order given', () async {
      final mark = roku.mark();
      final results = await Future.wait([
        session.execute(const PressKey(RemoteKey.up)),
        session.execute(const TypeText('ab')),
        session.execute(const PressKey(RemoteKey.select)),
      ]);
      expect(results, everyElement(isConfirmed));
      expect(roku.postsSince(mark), [
        '/keypress/Up',
        '/keypress/Lit_a',
        '/keypress/Lit_b',
        '/keypress/Select',
      ]);
    });
  });

  group('text', () {
    setUp(() async => session = await open(replaceBackspaces: 3));

    test('one Lit_ key per character, URL-encoded', () async {
      final (result, posts) = await run(const TypeText('a b/€'));
      expect(result, isConfirmed);
      expect(posts, [
        '/keypress/Lit_a',
        '/keypress/Lit_%20',
        '/keypress/Lit_b',
        '/keypress/Lit_%2F',
        '/keypress/Lit_%E2%82%AC',
      ]);
    });

    test('replace sends backspaces first', () async {
      final (result, posts) = await run(const TypeText('hi', replace: true));
      expect(result, isConfirmed);
      expect(posts, [
        '/keypress/Backspace',
        '/keypress/Backspace',
        '/keypress/Backspace',
        '/keypress/Lit_h',
        '/keypress/Lit_i',
      ]);
    });

    test(
      'text longer than the limit is refused before anything is sent',
      () async {
        final (result, posts) = await run(
          TypeText('x' * (rokuMaxTextRunes + 1)),
        );
        expect(result, isUnsupported(contains('$rokuMaxTextRunes')));
        expect(posts, isEmpty);
        final (ok, okPosts) = await run(TypeText('é' * rokuMaxTextRunes));
        expect(ok, isConfirmed);
        expect(okPosts, hasLength(rokuMaxTextRunes));
      },
    );

    // Was `cancelled`: with two characters typed, the core contract (Codex
    // finding #4) makes the failure a partial delivery, with the
    // cancellation as its cause.
    test('closing the session stops a typing run', () async {
      final gate = Completer<void>();
      var sent = 0;
      roku.net.onHttp('POST', RegExp(r'^/keypress/Lit_'), (_) async {
        if (++sent == 2) await gate.future;
        return HttpResult(200);
      });
      final typing = session.execute(const TypeText('abcdef'));
      for (var i = 0; i < 100 && sent < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await session.close();
      gate.complete();
      final failed = await typing;
      expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        (failed as Failed).error.cause,
        isWatchmeError(WatchmeErrorCode.cancelled),
      );
      expect(sent, 2);
    });

    test('a refusal after the backspaces is a partial delivery', () async {
      roku.net.respond(
        'POST',
        RegExp(r'^/keypress/Lit_'),
        HttpResult.text(403, limitedBody),
      );
      final (result, posts) = await run(const TypeText('hi', replace: true));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        (result as Failed).error.cause,
        isWatchmeError(WatchmeErrorCode.rejected),
      );
      expect(result.error.rawDeviceMessage, limitedBody);
      expect(posts, [
        '/keypress/Backspace',
        '/keypress/Backspace',
        '/keypress/Backspace',
        '/keypress/Lit_h',
      ]);
    });

    test('empty text sends nothing', () async {
      final (result, posts) = await run(const TypeText(''));
      expect(result, isConfirmed);
      expect(posts, isEmpty);
    });
  });

  group('apps', () {
    setUp(() async => session = await open());

    test('LaunchApp posts launch with deep-link params', () async {
      final (result, posts) = await run(
        const LaunchApp(
          '12',
          params: {'contentId': '80057281', 'mediaType': 'movie'},
        ),
      );
      expect(result, isConfirmed);
      expect(posts, ['/launch/12?contentId=80057281&mediaType=movie']);
      expect(session.state.foregroundApp!.value.id, '12');
      expect(session.state.foregroundApp!.confidence, Confidence.inferred);
    });

    test('LaunchApp with a deepLink URI is Unsupported', () async {
      final (result, posts) = await run(
        LaunchApp('12', deepLink: Uri.parse('https://netflix.com/title/1')),
      );
      expect(result, isUnsupported(contains('contentId')));
      expect(posts, isEmpty);
    });

    test('launching an unknown app fails with the device answer', () async {
      roku.net.respond('POST', '/launch/999', HttpResult(404));
      final (result, _) = await run(const LaunchApp('999'));
      expect(
        result,
        isFailedWith(WatchmeErrorCode.rejected, rawDeviceMessage: 'HTTP 404'),
      );
    });

    test('ListApps returns the app list with icons', () async {
      final result = await session.execute(const ListApps());
      expect(result, isConfirmed);
      final apps = ((result as Confirmed).payload! as AppListPayload).apps;
      expect(apps.map((a) => a.id), contains('12'));
      expect(
        apps.firstWhere((a) => a.id == 'tvinput.hdmi1').kind,
        AppKind.input,
      );
      expect(
        apps.first.icon.toString(),
        'http://192.0.2.10:8060/query/icon/tvinput.dtv',
      );
      // A later launch uses the listed name.
      await session.execute(const LaunchApp('837'));
      expect(session.state.foregroundApp!.value.name, 'YouTube');
    });
  });

  group('Limited mode', () {
    setUp(() async => session = await open());

    test('403 becomes Failed(rejected) with the raw body, and capabilities '
        'change', () async {
      final events = <DeviceEvent>[];
      final sub = session.events.listen(events.add);
      addTearDown(sub.cancel);
      roku.limited = true;

      final result = await session.execute(const PressKey(RemoteKey.home));
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.rejected,
          message: contains('Limited'),
          rawDeviceMessage: limitedBody,
        ),
      );
      expect(session.access, RokuEcpAccess.limited);
      final keys = session.capabilities.supportFor(Capability.dpadNavigation);
      expect(keys.level, Support.no);
      expect(keys.has(CapFlag.userSetupRequired), isTrue);
      await pumpEventQueue();
      expect(events.whereType<CapabilitiesChanged>(), hasLength(1));

      // The user enables the setting; the next key works and capabilities
      // recover.
      roku.limited = false;
      expect(await session.execute(const PressKey(RemoteKey.up)), isConfirmed);
      expect(session.access, RokuEcpAccess.enabled);
      expect(
        session.capabilities.supportFor(Capability.dpadNavigation).level,
        Support.yes,
      );
      await pumpEventQueue();
      expect(events.whereType<CapabilitiesChanged>(), hasLength(2));
    });

    test('ListApps and text are refused too', () async {
      roku.limited = true;
      expect(
        await session.execute(const ListApps()),
        isFailedWith(WatchmeErrorCode.rejected, rawDeviceMessage: limitedBody),
      );
      expect(
        await session.execute(const TypeText('x')),
        isFailedWith(WatchmeErrorCode.rejected, rawDeviceMessage: limitedBody),
      );
    });
  });

  group('volume, power, inputs, channels', () {
    setUp(() async => session = await open());

    test('SetVolume is Unsupported (relative only)', () async {
      final (result, posts) = await run(const SetVolume(30));
      expect(result, isUnsupported(contains('StepVolume')));
      expect(posts, isEmpty);
      expect(
        session.capabilities
            .supportFor(Capability.volume)
            .has(CapFlag.relativeOnly),
        isTrue,
      );
    });

    test('StepVolume repeats the step key', () async {
      expect((await run(const StepVolume(3))).$2, [
        '/keypress/VolumeUp',
        '/keypress/VolumeUp',
        '/keypress/VolumeUp',
      ]);
      expect((await run(const StepVolume(-2))).$2, [
        '/keypress/VolumeDown',
        '/keypress/VolumeDown',
      ]);
      expect((await run(const StepVolume(0))).$2, isEmpty);
      expect((await run(const StepVolume(500))).$1, isUnsupported());
    });

    test('StepVolume closed mid-way: first answer paused, session closed, '
        'answer released', () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      var presses = 0;
      roku.net.onHttp('POST', '/keypress/VolumeUp', (_) async {
        if (++presses == 1) {
          reached.complete();
          await release.future;
        }
        return HttpResult(200);
      });
      final result = session.execute(const StepVolume(3));
      await reached.future;
      await session.close();
      release.complete();
      final failed = await result;
      expect(presses, 1, reason: 'steps 2 and 3 never sent');
      expect(failed, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        (failed as Failed).error.cause,
        isWatchmeError(WatchmeErrorCode.cancelled),
      );
    });

    test('StepVolume failing at step 2 is a partial delivery', () async {
      var presses = 0;
      roku.net.onHttp(
        'POST',
        '/keypress/VolumeDown',
        (_) => ++presses == 2 ? HttpResult.text(500, 'boom') : HttpResult(200),
      );
      final (result, posts) = await run(const StepVolume(-3));
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.partiallyDelivered,
          rawDeviceMessage: 'boom',
          message: contains('1 of its requests'),
        ),
      );
      expect(posts, hasLength(2));
      expect(result.partiallyDelivered, isTrue);
    });

    test('a Roku that vanishes after a step is a partial delivery, never '
        'unreachable', () async {
      var presses = 0;
      roku.net.onHttp('POST', '/keypress/VolumeUp', (_) {
        if (++presses == 1) roku.net.setUnreachable(roku.host);
        return HttpResult(200);
      });
      final (result, _) = await run(const StepVolume(3));
      expect(result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(
        (result as Failed).error.cause,
        isWatchmeError(WatchmeErrorCode.unreachable),
      );
    });

    test('a first step that reaches nothing stays unreachable', () async {
      roku.net.setUnreachable(roku.host);
      expect(
        (await run(const StepVolume(3))).$1,
        isFailedWith(WatchmeErrorCode.unreachable),
      );
    });

    test('SetMute toggles only', () async {
      expect((await run(const SetMute(null))).$2, ['/keypress/VolumeMute']);
      final (result, posts) = await run(const SetMute(true));
      expect(result, isUnsupported(contains('toggle')));
      expect(posts, isEmpty);
    });

    test('SetPower uses the discrete keys and infers state', () async {
      expect((await run(const SetPower(false))).$2, ['/keypress/PowerOff']);
      expect(session.state.power!.value, PowerMode.standby);
      expect(session.state.power!.confidence, Confidence.inferred);
      expect((await run(const SetPower(true))).$2, ['/keypress/PowerOn']);
      expect(session.state.power!.value, PowerMode.on);
    });

    test('SelectInput by short id, app id, and the home screen', () async {
      expect((await run(const SelectInput('hdmi2'))).$2, [
        '/keypress/InputHDMI2',
      ]);
      expect(session.state.input!.value, 'hdmi2');
      expect((await run(const SelectInput('tvinput.dtv'))).$2, [
        '/keypress/InputTuner',
      ]);
      expect(session.state.input!.value, 'tuner');
      expect((await run(const SelectInput('tvinput.hdmi7'))).$2, [
        '/launch/tvinput.hdmi7',
      ]);
      expect((await run(const SelectInput('roku'))).$2, ['/keypress/Home']);
      expect(session.state.input!.value, rokuAppsInputId);
      expect((await run(const SelectInput('vga'))).$1, isUnsupported());
    });

    test('TuneChannel launches the tuner with ch', () async {
      final (result, posts) = await run(const TuneChannel('7.1'));
      expect(result, isConfirmed);
      expect(posts, ['/launch/tvinput.dtv?ch=7.1']);
    });
  });

  group('players', () {
    setUp(
      () async => session = await open(deviceInfo: expressPlayerDeviceInfo),
    );

    test('have no inputs, tuner or (here) volume', () async {
      for (final command in const <Command>[
        SelectInput('hdmi1'),
        PressKey(RemoteKey.inputHdmi1),
        TuneChannel('5'),
        PressKey(RemoteKey.channelUp),
        StepVolume(1),
        PressKey(RemoteKey.volumeUp),
      ]) {
        final (result, posts) = await run(command);
        expect(result, isUnsupported(), reason: '$command');
        expect(posts, isEmpty);
      }
      expect(session.state.input, isNull);
    });

    test('still power the TV through CEC', () async {
      expect((await run(const SetPower(false))).$1, isConfirmed);
    });
  });

  group('media', () {
    setUp(() async => session = await open());

    test('playPause, rewind, fast forward, instant replay', () async {
      expect((await run(const Media(MediaAction.playPause))).$2, [
        '/keypress/Play',
      ]);
      expect((await run(const Media(MediaAction.rewind))).$2, [
        '/keypress/Rev',
      ]);
      expect((await run(const Media(MediaAction.fastForward))).$2, [
        '/keypress/Fwd',
      ]);
      expect((await run(const Media(MediaAction.instantReplay))).$2, [
        '/keypress/InstantReplay',
      ]);
    });

    test('pause and play check the player before toggling', () async {
      roku.mediaPlayer = mediaPlayerIn('play');
      expect((await run(const Media(MediaAction.play))).$2, isEmpty);
      expect((await run(const Media(MediaAction.pause))).$2, [
        '/keypress/Play',
      ]);
      roku.mediaPlayer = mediaPlayerIn('pause');
      expect((await run(const Media(MediaAction.pause))).$2, isEmpty);
      expect((await run(const Media(MediaAction.play))).$2, ['/keypress/Play']);
      expect(session.state.nowPlaying!.value.state, PlaybackState.paused);
      roku.mediaPlayer = mediaPlayerClosed;
      final (result, posts) = await run(const Media(MediaAction.pause));
      expect(result, isUnsupported(contains('close')));
      expect(posts, isEmpty);
    });

    test(
      'the play and pause keys are discrete too: a pause never resumes',
      () async {
        roku.mediaPlayer = mediaPlayerIn('pause');
        final (paused, pausePosts) = await run(const PressKey(RemoteKey.pause));
        expect(paused, isConfirmed);
        expect(pausePosts, isEmpty, reason: 'already paused');
        expect((await run(const PressKey(RemoteKey.play))).$2, [
          '/keypress/Play',
        ]);
        roku.mediaPlayer = mediaPlayerIn('play');
        expect((await run(const PressKey(RemoteKey.play))).$2, isEmpty);
        expect((await run(const PressKey(RemoteKey.pause))).$2, [
          '/keypress/Play',
        ]);
        // The toggle itself is still there.
        expect((await run(const PressKey(RemoteKey.playPause))).$2, [
          '/keypress/Play',
        ]);
        for (final action in [KeyAction.down, KeyAction.up]) {
          final (held, heldPosts) = await run(
            PressKey(RemoteKey.pause, action),
          );
          expect(held, isUnsupported(contains('toggle')));
          expect(heldPosts, isEmpty);
        }
      },
    );

    test('stop, next, previous and seek are Unsupported', () async {
      for (final action in [
        MediaAction.stop,
        MediaAction.next,
        MediaAction.previous,
        MediaAction.seek,
      ]) {
        final (result, posts) = await run(
          Media(action, seekTo: const Duration(seconds: 5)),
        );
        expect(result, isUnsupported(), reason: action.name);
        expect(posts, isEmpty);
      }
    });

    test('CastUrl launches the receiver channel', () async {
      final (result, posts) = await run(
        CastUrl(Uri.parse('http://192.0.2.5/movie.mp4'), mimeType: 'video/mp4'),
      );
      expect(result, isConfirmed);
      expect(posts, [
        '/launch/782875?u=http%3A%2F%2F192.0.2.5%2Fmovie.mp4&t=v',
      ]);
    });
  });

  group('unsupported commands', () {
    setUp(() async => session = await open());

    test('pointer, toast and screenshot send nothing', () async {
      for (final command in const <Command>[
        MovePointer(1, 1),
        ShowToast('hello'),
        TakeScreenshot(),
      ]) {
        final (result, posts) = await run(command);
        expect(result, isUnsupported(), reason: '$command');
        expect(posts, isEmpty);
      }
    });
  });

  group('state', () {
    test('refresh reads power, app, input and player', () async {
      session = await open();
      roku
        ..activeApp = activeAppHdmi1
        ..mediaPlayer = mediaPlayerClosed;
      final state = await session.refresh();
      expect(state.foregroundApp!.value.id, 'tvinput.hdmi1');
      expect(state.input!.value, 'hdmi1');
      expect(state.nowPlaying!.value.state, PlaybackState.stopped);
    });

    test('standby keeps app and player but marks them stale', () async {
      session = await open();
      roku.deviceInfo = tvDeviceInfoIn('Ready');
      final mark = roku.mark();
      final state = await session.refresh();
      expect(state.power!.value, PowerMode.standby);
      expect(state.foregroundApp!.confidence, Confidence.stale);
      expect(state.nowPlaying!.confidence, Confidence.stale);
      // Only device-info is asked in standby.
      expect(roku.net.httpCalls.skip(mark).map((c) => c.uri.path), [
        '/query/device-info',
      ]);
    });

    test('a 403 in standby says so', () async {
      session = await open();
      roku.deviceInfo = tvDeviceInfoIn('Ready');
      await session.refresh();
      roku.net.respond('POST', '/keypress/Up', HttpResult(403));
      expect(
        await session.execute(const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.rejected, message: contains('standby')),
      );
    });

    test('polls while listened to and emits StateChanged', () async {
      session = await open(pollInterval: const Duration(seconds: 5));
      final events = <DeviceEvent>[];
      final sub = session.events.listen(events.add);

      roku.deviceInfo = tvDeviceInfoIn('Ready');
      await clock.advance(const Duration(seconds: 5));
      await pumpEventQueue();
      final change = events.whereType<StateChanged>().single;
      expect(change.state.power!.value, PowerMode.standby);
      expect(change.driverId, 'roku.ecp');

      // No change, no event.
      await clock.advance(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(events.whereType<StateChanged>(), hasLength(1));

      // Polling stops when nobody listens.
      await sub.cancel();
      final mark = roku.mark();
      await clock.advance(const Duration(seconds: 30));
      expect(roku.net.httpCalls.skip(mark), isEmpty);
      expect(clock.pendingTimers, 0);
    });

    test('no polling without an interval', () async {
      session = await open();
      final sub = session.events.listen((_) {});
      addTearDown(sub.cancel);
      expect(clock.pendingTimers, 0);
    });

    test('losing and regaining the device emits ConnectionChanged', () async {
      session = await open(pollInterval: const Duration(seconds: 5));
      final events = <DeviceEvent>[];
      final sub = session.events.listen(events.add);
      addTearDown(sub.cancel);

      roku.net.setUnreachable('192.0.2.10');
      await clock.advance(const Duration(seconds: 5));
      await pumpEventQueue();
      final lost = events.whereType<ConnectionChanged>().single;
      expect(lost.state, ConnectionState.disconnected);
      expect(lost.error, isWatchmeError(WatchmeErrorCode.unreachable));
      expect(session.state.power!.confidence, Confidence.stale);
      expect(
        session.state.connections['roku.ecp'],
        ConnectionState.disconnected,
      );
      expect(
        () => session.refresh(),
        throwsWatchmeError(WatchmeErrorCode.unreachable),
      );
      final failed = await session.execute(const PressKey(RemoteKey.home));
      expect(failed, isFailedWith(WatchmeErrorCode.unreachable));

      roku.net.setReachable('192.0.2.10');
      await clock.advance(const Duration(seconds: 5));
      await pumpEventQueue();
      expect(events.whereType<ConnectionChanged>().map((e) => e.state), [
        ConnectionState.disconnected,
        ConnectionState.connected,
      ]);
      expect(session.state.power!.confidence, Confidence.reported);
    });
  });

  test('close ends events and later commands fail', () async {
    session = await open();
    final done = Completer<void>();
    final events = <DeviceEvent>[];
    session.events.listen(events.add, onDone: done.complete);
    await session.close();
    await done.future;
    expect(
      events.single,
      isA<ConnectionChanged>().having(
        (e) => e.state,
        'state',
        ConnectionState.disconnected,
      ),
    );
    expect(
      await session.execute(const PressKey(RemoteKey.home)),
      isFailedWith(WatchmeErrorCode.cancelled),
    );
    expect(
      () => session.refresh(),
      throwsWatchmeError(WatchmeErrorCode.cancelled),
    );
    await session.close();
  });
}
