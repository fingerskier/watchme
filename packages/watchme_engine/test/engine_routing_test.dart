import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const mute = CapabilitySupport.yes(Capability.mute);
const relativeVolume = CapabilitySupport.yes(
  Capability.volume,
  flags: {CapFlag.relativeOnly},
);

FakeDriver driver(String id, List<CapabilitySupport> caps, {String? mac}) =>
    FakeDriver(
      id,
      ceiling: caps,
      onProbe: (_) => matched(name: 'TV', mac: mac, capabilities: caps),
    );

void main() {
  test('falls back to the next driver when the best is unreachable', () async {
    final cec = driver('cec', [mute]);
    final ir = driver('ir', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.writeOnly}),
    ]);
    final h = Harness(drivers: [ir, cec]);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    cec.connectError = const WatchmeError.unreachable('adapter unplugged');

    expect(await h.engine.send(id, const SetMute(true)), isConfirmed);
    expect(cec.connects, hasLength(1), reason: 'the better route was tried');
    expect(ir.executed, [const SetMute(true)]);
    expect(h.driverView(id, 'cec').lastError?.message, 'adapter unplugged');
  });

  test('cloud routes are used only with internet', () async {
    final cloud = driver('smartthings', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.cloud}),
    ]);
    final local = driver('ir', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.writeOnly}),
    ]);
    final transports = FakeTransports();
    final h = Harness(drivers: [cloud, local], transports: transports);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');

    await h.engine.send(id, const SetMute(true));
    expect(cloud.executed, isEmpty);
    expect(local.executed, hasLength(1));

    transports.extraFeatures.add(TransportFeature.internet);
    await h.engine.send(id, const SetMute(false));
    // Local beats cloud, but write-only ranks below cloud feedback.
    expect(cloud.executed, [const SetMute(false)]);
  });

  test('SetVolume steps a relative-only session from its reported level, '
      'then from the level watchme set', () async {
    final atv = FakeDriver(
      'androidtv.remote2',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
    );
    final h = Harness(drivers: [atv]);
    addTearDown(h.close);
    atv.sessionState = DeviceState(
      volume: Observed.reported(20, 'androidtv.remote2', h.clock.now()),
    );
    final id = await h.add('10.0.2.10');
    await h.clock.advance(const Duration(minutes: 1));

    expect(await h.engine.send(id, const SetVolume(25)), isConfirmed);
    expect(atv.executed, [const StepVolume(5)]);
    final volume = h.view(id).state.volume!;
    expect(volume.value, 25);
    expect(volume.confidence, Confidence.inferred);

    await h.clock.advance(const Duration(seconds: 1));
    await h.engine.send(id, const SetVolume(20));
    expect(atv.executed.last, const StepVolume(-5));
  });

  test('overlapping SetVolume calls step from the level the previous one '
      'left', () async {
    // Codex PR review: two SetVolume(20) from 10 both snapshotted 10 and
    // both stepped +10, leaving the TV at 30.
    final gate = Completer<void>();
    final atv = FakeDriver(
      'androidtv.remote2',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
      onExecute: (_) async {
        await gate.future;
        return const Confirmed();
      },
    );
    final h = Harness(drivers: [atv]);
    addTearDown(h.close);
    atv.sessionState = DeviceState(
      volume: Observed.reported(10, 'androidtv.remote2', h.clock.now()),
    );
    final id = await h.add('10.0.2.10');
    await h.clock.advance(const Duration(minutes: 1));

    final first = h.engine.send(id, const SetVolume(20));
    final second = h.engine.send(id, const SetVolume(20));
    await h.clock.flush();
    gate.complete();
    expect(await first, isConfirmed);
    expect(await second, isConfirmed);
    final stepped = atv.executed.whereType<StepVolume>().fold<int>(
      0,
      (sum, c) => sum + c.steps,
    );
    expect(stepped, 10, reason: '${atv.executed}');
    expect(h.view(id).state.volume!.value, 20);
  });

  test('closing the engine releases queued volume commands while the one '
      'in front never finishes', () async {
    // Codex review of 1a2ec5c: queued callers waited for the hung command
    // even after close, holding an ever longer chain.
    final never = Completer<CommandResult>();
    final atv = FakeDriver(
      'androidtv.remote2',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
      onExecute: (_) => never.future,
    );
    final h = Harness(drivers: [atv]);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    await h.clock.advance(const Duration(minutes: 1));

    unawaited(h.engine.send(id, const StepVolume(1)));
    await h.clock.flush();
    expect(atv.executed, [const StepVolume(1)]);
    final queued = [
      for (var i = 0; i < 3; i++) h.engine.send(id, const StepVolume(1)),
      h.engine.send(id, const SetMute(true)),
    ];
    await h.clock.flush();

    await h.engine.close();
    expect(
      await Future.wait(queued),
      everyElement(isFailedWith(WatchmeErrorCode.cancelled)),
    );
    expect(atv.executed, [const StepVolume(1)]);
  });

  test('volume commands sent just before close are released too', () async {
    // Codex re-review of eae9178: send() yields before queueing, so a
    // command sent just before close() queued itself after close() had
    // released the queue, and waited behind the hung one for ever.
    final never = Completer<CommandResult>();
    final atv = FakeDriver(
      'androidtv.remote2',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
      onExecute: (_) => never.future,
    );
    final h = Harness(drivers: [atv]);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    await h.clock.advance(const Duration(minutes: 1));

    unawaited(h.engine.send(id, const StepVolume(1)));
    await h.clock.flush();
    final queued = [
      for (var i = 0; i < 3; i++) h.engine.send(id, const StepVolume(1)),
      h.engine.send(id, const SetMute(true)),
    ];
    await h.engine.close();
    expect(
      await Future.wait(queued),
      everyElement(isFailedWith(WatchmeErrorCode.cancelled)),
    );
    expect(atv.executed, [const StepVolume(1)]);
  });

  group('partial delivery', () {
    const keysOnly = CapabilitySupport.yes(
      Capability.volume,
      flags: {CapFlag.relativeOnly},
    );
    const stepper = CapabilitySupport.partial(
      Capability.volume,
      flags: {CapFlag.relativeOnly},
    );

    test(
      'SetVolume(13) from 10: one press lands, the route fails; the '
      'command is not replayed elsewhere and the volume goes stale',
      () async {
        // Codex finding #4, reproduced through the engine.
        var presses = 0;
        final keys = FakeDriver(
          'keys',
          ceiling: const [keysOnly],
          onProbe: (_) => matched(capabilities: const [keysOnly]),
          onExecute: (c) => switch (c) {
            StepVolume() => const Unsupported('no StepVolume'),
            _ =>
              ++presses == 1
                  ? const Confirmed()
                  : const Failed(WatchmeError.unreachable('refused')),
          },
        );
        final steps = FakeDriver(
          'steps',
          ceiling: const [stepper],
          onProbe: (_) => matched(capabilities: const [stepper]),
        );
        final h = Harness(drivers: [keys, steps]);
        addTearDown(h.close);
        keys.sessionState = DeviceState(
          volume: Observed.reported(10, 'keys', h.clock.now()),
        );
        final id = await h.add('10.0.2.10');
        final events = <DeviceEvent>[];
        h.engine.events(id).listen(events.add);

        expect(
          await h.engine.send(id, const SetVolume(13)),
          isFailedWith(
            WatchmeErrorCode.partiallyDelivered,
            message: contains('1 of 3'),
          ),
        );
        expect(keys.executed, [
          const StepVolume(3),
          const PressKey(RemoteKey.volumeUp),
          const PressKey(RemoteKey.volumeUp),
        ]);
        expect(steps.executed, isEmpty, reason: 'no replay on another route');
        final volume = h.view(id).state.volume!;
        expect(volume.value, 10);
        expect(volume.confidence, Confidence.stale);
        await pump();
        expect(
          events.whereType<StateChanged>().last.state.volume?.confidence,
          Confidence.stale,
        );

        // Nothing is computed from the stale level.
        expect(
          await h.engine.send(id, const SetVolume(20)),
          isUnsupported(contains('level is unknown')),
        );
        expect(steps.executed, isEmpty);
      },
    );

    test('a session reporting partial delivery is not replayed, and its '
        'volume goes stale', () async {
      final a = FakeDriver(
        'a',
        ceiling: const [keysOnly],
        onProbe: (_) => matched(capabilities: const [keysOnly]),
        onExecute: (_) => const Failed(
          WatchmeError.partiallyDelivered('stepped 2 of 4 times'),
        ),
      );
      final b = FakeDriver(
        'b',
        ceiling: const [stepper],
        onProbe: (_) => matched(capabilities: const [stepper]),
      );
      final h = Harness(drivers: [a, b]);
      addTearDown(h.close);
      a.sessionState = DeviceState(
        volume: Observed.reported(30, 'a', h.clock.now()),
      );
      final id = await h.add('10.0.2.10');
      expect(
        await h.engine.send(id, const SetVolume(34)),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      expect(b.executed, isEmpty);
      expect(h.view(id).state.volume?.confidence, Confidence.stale);
    });

    group('the stale level is not revived by an old report', () {
      // Verifier follow-up to Codex finding #4: a refresh that returned the
      // level the session cached before the command made it "reported"
      // again, and the next SetVolume replayed the steps from it.
      const toggleOff = CapabilitySupport.yes(
        Capability.powerOff,
        flags: {CapFlag.toggleOnly},
      );

      /// A 'keys' route whose second press fails (the device ends at 11)
      /// and whose session reports volume 10 from before the command, plus
      /// a relative 'steps' route. Returns the device id after the partial
      /// delivery.
      Future<(Harness, String, FakeDriver)> partlyDelivered({
        List<CapabilitySupport> extra = const [],
      }) async {
        var presses = 0;
        final keys = FakeDriver(
          'keys',
          ceiling: [keysOnly, ...extra],
          onProbe: (_) => matched(capabilities: [keysOnly, ...extra]),
          onExecute: (c) => switch (c) {
            StepVolume() => const Unsupported('no StepVolume'),
            SetPower() => const Confirmed(),
            _ =>
              ++presses == 2
                  ? const Failed(WatchmeError.unreachable('refused'))
                  : const Confirmed(),
          },
        );
        final steps = FakeDriver(
          'steps',
          ceiling: const [stepper],
          onProbe: (_) => matched(capabilities: const [stepper]),
        );
        final h = Harness(drivers: [keys, steps]);
        addTearDown(h.close);
        keys.sessionState = DeviceState(
          volume: Observed.reported(10, 'keys', h.clock.now()),
        );
        final id = await h.add('10.0.2.10');
        expect(
          await h.engine.send(id, const SetVolume(13)),
          isFailedWith(WatchmeErrorCode.partiallyDelivered),
        );
        expect(h.view(id).state.volume?.confidence, Confidence.stale);
        await h.clock.advance(const Duration(seconds: 1));
        return (h, id, keys);
      }

      int ups(FakeDriver d) => d.executed
          .where((c) => c == const PressKey(RemoteKey.volumeUp))
          .length;

      test('a refresh returning the cached level', () async {
        final (h, id, keys) = await partlyDelivered();
        await h.engine.refresh(id);
        expect(keys.lastSession.refreshes, 1);
        final volume = h.view(id).state.volume!;
        expect(volume.value, 10);
        expect(volume.confidence, Confidence.stale);

        expect(
          await h.engine.send(id, const SetVolume(13)),
          isUnsupported(contains('level is unknown')),
        );
        expect(ups(keys), 2, reason: 'no more presses from the old level');
      });

      test(
        'a power-key evidence read, which refreshes every session',
        () async {
          final (h, id, keys) = await partlyDelivered(extra: const [toggleOff]);
          await h.engine.send(id, const PressKey(RemoteKey.power));
          expect(keys.lastSession.refreshes, greaterThan(0));
          expect(h.view(id).state.volume?.confidence, Confidence.stale);
          expect(
            await h.engine.send(id, const SetVolume(13)),
            isUnsupported(contains('level is unknown')),
          );
          expect(ups(keys), 2);
        },
      );

      test('a reconnect whose session starts from the cached level', () async {
        final (h, id, keys) = await partlyDelivered();
        keys.lastSession.emit(
          const ConnectionChanged(
            ConnectionState.disconnected,
            driverId: 'keys',
          ),
        );
        await h.clock.advance(const Duration(seconds: 2));
        expect(keys.sessions, hasLength(2), reason: 'reconnected');
        expect(h.view(id).state.volume?.confidence, Confidence.stale);
      });

      test('a report made after the failure is believed', () async {
        final (h, id, keys) = await partlyDelivered();
        keys.lastSession.report(
          DeviceState(volume: Observed.reported(11, 'keys', h.clock.now())),
        );
        await pump();
        final volume = h.view(id).state.volume!;
        expect(volume.value, 11);
        expect(volume.confidence, Confidence.reported);
        // The old cached level does not replace it either.
        await h.engine.refresh(id);
        expect(h.view(id).state.volume?.value, 11);

        await h.clock.advance(const Duration(seconds: 1));
        expect(await h.engine.send(id, const SetVolume(13)), isConfirmed);
        expect(ups(keys), 4, reason: 'two more presses, from 11');
      });
    });

    test(
      'a step that times out may have acted: the volume goes stale',
      () async {
        final roku = FakeDriver(
          'roku.ecp',
          ceiling: const [keysOnly],
          onProbe: (_) => matched(capabilities: const [keysOnly]),
          onExecute: (_) => const Failed(WatchmeError.timeout('no answer')),
        );
        final h = Harness(drivers: [roku]);
        addTearDown(h.close);
        roku.sessionState = DeviceState(
          volume: Observed.reported(20, 'roku.ecp', h.clock.now()),
        );
        final id = await h.add('10.0.2.10');
        expect(
          await h.engine.send(id, const StepVolume(2)),
          isFailedWith(WatchmeErrorCode.timeout),
        );
        expect(h.view(id).state.volume?.confidence, Confidence.stale);
      },
    );
  });

  test('connecting to read the level before a SetVolume never wakes the '
      'device', () async {
    final fire = FakeDriver(
      'firetv.lightning',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
    );
    final h = Harness(drivers: [fire]);
    addTearDown(h.close);
    // Asleep: only a waking connect would get through.
    fire.onConnect = (_, _) => fire.connects.last.allowWake
        ? FakeSession('firetv.lightning', capabilities: const [relativeVolume])
        : throw const WatchmeError.unreachable('API port closed');
    final id = await h.add('10.0.2.10');
    expect(
      await h.engine.send(id, const SetVolume(25)),
      isUnsupported(contains('level is unknown')),
    );
    expect(fire.connects.map((c) => c.allowWake), [false]);
  });

  test(
    'SetVolume without a known level is Unsupported, and says why',
    () async {
      final roku = driver('roku.ecp', [relativeVolume]);
      final h = Harness(drivers: [roku]);
      addTearDown(h.close);
      final id = await h.add('10.0.2.10');
      expect(
        await h.engine.send(id, const SetVolume(30)),
        isUnsupported(contains('level is unknown')),
      );
      expect(roku.executed, isEmpty);
      // Relative commands still work.
      expect(await h.engine.send(id, const StepVolume(2)), isConfirmed);
    },
  );

  test('capabilities merge to the best entry per capability, plus '
      'Wake-on-LAN where a MAC is known', () async {
    final roku = driver('roku.ecp', [
      relativeVolume,
      const CapabilitySupport.no(Capability.screenshot),
    ], mac: 'aa:bb:cc:dd:ee:ff');
    final upnp = driver('upnp', [
      const CapabilitySupport.partial(Capability.volume),
    ]);
    final h = Harness(drivers: [roku, upnp]);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    final caps = h.engine.capabilitiesOf(id);
    expect(caps[Capability.volume], relativeVolume);
    expect(caps[Capability.screenshot]?.level, Support.no);
    expect(caps[Capability.powerOn]?.level, Support.partial);
    expect(caps[Capability.powerOn]?.has(CapFlag.writeOnly), isTrue);
    expect(
      h.view(id).supportOf(Capability.powerOn).note,
      contains('Wake-on-LAN'),
    );
  });

  test('no Wake-on-LAN capability without UDP', () async {
    final roku = driver('roku.ecp', const [], mac: 'aa:bb:cc:dd:ee:ff');
    final net = FakeNetworkStack()
      ..features.removeAll({
        TransportFeature.udpBroadcast,
        TransportFeature.udpUnicast,
      });
    final h = Harness(
      drivers: [roku],
      transports: FakeTransports(network: net),
    );
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    expect(h.engine.capabilitiesOf(id)[Capability.powerOn], isNull);
  });

  test('a session that throws is reported as an internal failure', () async {
    final roku = driver('roku.ecp', [mute])
      ..onExecute = (_) => throw StateError('driver bug');
    final h = Harness(drivers: [roku]);
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    expect(
      await h.engine.send(id, const SetMute(null)),
      isFailedWith(WatchmeErrorCode.internal, message: contains('driver bug')),
    );
  });

  test('unknown devices fail without throwing', () async {
    final h = Harness(
      drivers: [
        driver('roku.ecp', [mute]),
      ],
    );
    addTearDown(h.close);
    expect(
      await h.engine.send('nope', const SetMute(true)),
      isFailedWith(WatchmeErrorCode.internal),
    );
    await expectLater(
      h.engine.refresh('nope'),
      throwsWatchmeError(WatchmeErrorCode.internal),
    );
    await expectLater(
      h.engine.forget('nope'),
      throwsWatchmeError(WatchmeErrorCode.internal),
    );
  });

  test('a command no driver supports is Unsupported', () async {
    final h = Harness(
      drivers: [
        driver('roku.ecp', [mute]),
      ],
    );
    addTearDown(h.close);
    final id = await h.add('10.0.2.10');
    expect(await h.engine.send(id, const TakeScreenshot()), isUnsupported());
  });
}
