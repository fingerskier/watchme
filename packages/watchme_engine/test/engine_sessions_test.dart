import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const keys = [
  CapabilitySupport.yes(Capability.dpadNavigation),
  CapabilitySupport.yes(Capability.systemKeys),
  CapabilitySupport.yes(Capability.powerOff),
];

const home = PressKey(RemoteKey.home);

/// A Fire TV-like driver: needs pairing, PIN flow.
FakeDriver pinDriver({String id = 'firetv.lightning'}) {
  late final FakeDriver driver;
  driver = FakeDriver(
    id,
    ceiling: keys,
    requiresPairing: true,
    onProbe: (_) => matched(name: 'Fire TV', requiresPairing: true),
    onPair: (endpoint, context) => PairingFlowController.run((flow) async {
      flow.emit(const Instruct('A PIN is shown on the TV'));
      final pin = await flow.prompt(
        const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
      );
      if (pin != '1234') {
        throw const WatchmeError.unauthorized(
          'Wrong PIN',
          rawDeviceMessage: '{"description":"Invalid PIN"}',
        );
      }
      return token(context.deviceId, driver.id, secret: 'token-for-$pin');
    }),
  );
  return driver;
}

void main() {
  group('sessions', () {
    late FakeDriver roku;
    late Harness h;
    late String id;

    setUp(() async {
      roku = FakeDriver(
        'roku.ecp',
        ceiling: keys,
        onProbe: (_) => matched(name: 'Roku', capabilities: keys),
      );
      h = Harness(drivers: [roku]);
      id = await h.add('10.0.2.10');
    });
    tearDown(() => h.close());

    test('connect lazily on the first command and reuse the session', () async {
      expect(roku.connects, isEmpty);
      expect(
        h.driverView(id, 'roku.ecp').connection,
        ConnectionState.disconnected,
      );

      expect(await h.engine.send(id, home), isConfirmed);
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.up)),
        isConfirmed,
      );
      expect(roku.connects, hasLength(1));
      expect(roku.lastSession.executed, [home, const PressKey(RemoteKey.up)]);
      expect(h.driverView(id, 'roku.ecp').connected, isTrue);
    });

    test('concurrent commands share one connect', () async {
      final gate = Completer<void>();
      roku.onConnect = (ep, cred) async {
        await gate.future;
        final s = FakeSession('roku.ecp', capabilities: keys);
        roku.sessions.add(s);
        return s;
      };
      final a = h.engine.send(id, home);
      final b = h.engine.send(id, home);
      await pump();
      gate.complete();
      expect(await a, isConfirmed);
      expect(await b, isConfirmed);
      expect(roku.connects, hasLength(1));
    });

    test('session state and events reach the device', () async {
      final events = <DeviceEvent>[];
      h.engine.events(id).listen(events.add);
      await h.engine.send(id, home);
      roku.lastSession.report(
        DeviceState(power: h.reported(PowerMode.on, 'roku.ecp')),
      );
      await pump();
      expect(h.view(id).state.power?.value, PowerMode.on);
      expect(h.view(id).state.connections, {
        'roku.ecp': ConnectionState.connected,
      });
      expect(events.whereType<ConnectionChanged>().map((e) => e.state), [
        ConnectionState.connecting,
        ConnectionState.connected,
      ]);
      expect(
        events.whereType<StateChanged>().last.state.power?.value,
        PowerMode.on,
      );
    });

    test('CapabilitiesChanged updates the device', () async {
      await h.engine.send(id, home);
      roku.lastSession.emit(
        const CapabilitiesChanged([
          CapabilitySupport.no(Capability.dpadNavigation),
        ], driverId: 'roku.ecp'),
      );
      await pump();
      expect(
        h.engine.capabilitiesOf(id)[Capability.dpadNavigation]?.level,
        Support.no,
      );
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.up)),
        isUnsupported(),
      );
    });

    test('a dropped session reconnects with backoff', () async {
      await h.engine.send(id, home);
      roku.connectError = const WatchmeError.unreachable('refused');
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await pump();
      expect(
        h.driverView(id, 'roku.ecp').connection,
        ConnectionState.disconnected,
      );
      expect(roku.connects, hasLength(1));

      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects, hasLength(2), reason: 'first retry after 1 s');
      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects, hasLength(2), reason: 'second retry waits 2 s');
      roku.connectError = null;
      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects, hasLength(3));
      expect(h.driverView(id, 'roku.ecp').connected, isTrue);

      // Success resets the backoff.
      await h.clock.advance(const Duration(minutes: 5));
      expect(roku.connects, hasLength(3));
    });

    test('background reconnects never wake the device; a command the user '
        'sends may', () async {
      await h.engine.send(id, home);
      roku.connectError = const WatchmeError.unreachable('asleep');
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await h.clock.advance(const Duration(seconds: 3));
      expect(roku.connects.map((c) => c.allowWake), [true, false, false]);
      roku.connectError = null;
      expect(await h.engine.send(id, home), isConfirmed);
      expect(roku.connects.last.allowWake, isTrue);
    });

    test('the end of a hold never wakes the device; its start may', () async {
      // Verifier follow-up to Codex finding #9: apps send the key-up on
      // their own (focus loss, the app going to the background), and it
      // woke a sleeping Fire TV through DIAL.
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.down, KeyAction.up)),
        isConfirmed,
      );
      expect(roku.connects.single.allowWake, isFalse);
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await pump();
      expect(
        await h.engine.send(id, const PressKey(RemoteKey.down, KeyAction.down)),
        isConfirmed,
      );
      expect(roku.connects.map((c) => c.allowWake), [false, true]);
    });

    test('a refresh that reaches nothing shows the device stale and '
        'disconnected, and recovery is passive', () async {
      await h.engine.send(id, home);
      final session = roku.lastSession;
      session.report(
        DeviceState(
          power: Observed.inferred(PowerMode.on, 'roku.ecp', h.clock.now()),
        ),
      );
      await pump();
      expect(h.view(id).state.power?.confidence, Confidence.inferred);

      // Codex finding #9: the session's refresh finds nothing answering,
      // and (unlike the contract asks) does not say so itself.
      session.onRefresh = () =>
          throw const WatchmeError.unreachable('no route to host');
      roku.connectError = const WatchmeError.unreachable('no route to host');
      await h.engine.refresh(id);
      final view = h.view(id);
      expect(view.state.power?.value, PowerMode.on);
      expect(view.state.power?.confidence, Confidence.stale);
      final driver = h.driverView(id, 'roku.ecp');
      expect(driver.connection, ConnectionState.disconnected);
      expect(driver.lastError?.code, WatchmeErrorCode.unreachable);
      expect(session.closed, isTrue);

      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects, hasLength(2));
      expect(roku.connects.last.allowWake, isFalse);
    });

    test(
      'a session saying its own observation went stale is believed',
      () async {
        await h.engine.send(id, home);
        final at = h.clock.now();
        final session = roku.lastSession
          ..report(
            DeviceState(power: Observed.inferred(PowerMode.on, 'roku.ecp', at)),
          );
        await pump();
        // Another source going quiet says nothing about this observation.
        session.emit(
          StateChanged(
            DeviceState(
              power: Observed(PowerMode.on, 'upnp', at, Confidence.stale),
            ),
            driverId: 'roku.ecp',
          ),
        );
        await pump();
        expect(h.view(id).state.power?.confidence, Confidence.inferred);

        // DeviceState.merge keeps a live observation over a stale one from
        // the same instant; the engine must not.
        session.emit(
          StateChanged(
            DeviceState(
              power: Observed(PowerMode.on, 'roku.ecp', at, Confidence.stale),
            ),
            driverId: 'roku.ecp',
          ),
        );
        await pump();
        expect(h.view(id).state.power?.confidence, Confidence.stale);
      },
    );

    test('a command that joins a passive reconnect finding the device '
        'asleep connects again, waking it', () async {
      await h.engine.send(id, home);
      final asleep = Completer<void>();
      roku.onConnect = (_, _) async {
        if (!roku.connects.last.allowWake) {
          await asleep.future;
          throw const WatchmeError.unreachable('API port closed');
        }
        final s = FakeSession('roku.ecp', capabilities: keys);
        roku.sessions.add(s);
        return s;
      };
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects.last.allowWake, isFalse);
      final result = h.engine.send(id, home);
      await pump();
      asleep.complete();
      expect(await result, isConfirmed);
      expect(roku.connects.map((c) => c.allowWake), [true, false, true]);
    });

    test('no background reconnect to a refused destination', () async {
      await h.engine.send(id, home);
      roku.connectError = const WatchmeError.destinationRefused(
        'Refused to contact 8.8.8.8: it is a public internet address.',
      );
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await h.clock.advance(const Duration(seconds: 1));
      expect(roku.connects, hasLength(2));
      await h.clock.advance(const Duration(minutes: 10));
      expect(roku.connects, hasLength(2), reason: 'retrying cannot help');
    });

    test('no background reconnect after watchme turned the TV off', () async {
      expect(await h.engine.send(id, const SetPower(false)), isConfirmed);
      roku.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await h.clock.advance(const Duration(minutes: 10));
      expect(roku.connects, hasLength(1));
      // The next command still connects on demand.
      expect(await h.engine.send(id, home), isConfirmed);
      expect(roku.connects, hasLength(2));
    });

    test('no background reconnect while a source says the TV is off', () async {
      final upnp = FakeDriver(
        'upnp',
        onProbe: (_) => matched(),
        sessionState: DeviceState(
          power: Observed.reported(PowerMode.standby, 'upnp', h.clock.now()),
        ),
      );
      final h2 = Harness(drivers: [roku, upnp]);
      addTearDown(h2.close);
      final id2 = await h2.add('10.0.2.11');
      await h2.engine.refresh(id2);
      await h2.engine.send(id2, home);
      // upnp has no session yet; connect it so its state counts.
      await h2.engine.send(id2, const ListApps());
      final before = roku.connects.length;
      roku.sessions.last.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'roku.ecp',
        ),
      );
      await h2.clock.advance(const Duration(minutes: 10));
      expect(roku.connects, hasLength(before));
    });

    test('closing the engine closes sessions and stops timers', () async {
      await h.engine.send(id, home);
      final session = roku.lastSession;
      await h.engine.close();
      expect(session.closed, isTrue);
      expect(h.clock.pendingTimers, 0);
      expect(
        await h.engine.send(id, home),
        isFailedWith(WatchmeErrorCode.cancelled),
      );
    });

    test('refresh probes passively without a session, and re-reads an open '
        'one', () async {
      final probes = roku.probes.length;
      await h.clock.advance(const Duration(minutes: 1));
      await h.engine.refresh(id);
      expect(roku.probes, hasLength(probes + 1));
      expect(roku.connects, isEmpty, reason: 'refresh never connects');
      expect(h.view(id).lastSeen, h.clock.now());

      await h.engine.send(id, home);
      roku.lastSession.onRefresh = () =>
          DeviceState(volume: Observed.reported(12, 'roku.ecp', h.clock.now()));
      await h.engine.refresh(id);
      expect(roku.lastSession.refreshes, 1);
      expect(roku.probes, hasLength(probes + 1));
      expect(h.view(id).state.volume?.value, 12);
    });

    test(
      'forget closes sessions and deletes the record and credentials',
      () async {
        await h.credentials.write(token(id, 'roku.ecp'));
        await h.engine.send(id, home);
        final session = roku.lastSession;
        await h.engine.forget(id);
        expect(session.closed, isTrue);
        expect(h.engine.currentDevices, isEmpty);
        expect(await h.repository.get(id), isNull);
        expect(await h.credentials.readAll(id), isEmpty);
        expect(
          await h.engine.send(id, home),
          isFailedWith(WatchmeErrorCode.internal),
        );
        expect(
          () => h.engine.events(id),
          throwsWatchmeError(WatchmeErrorCode.internal),
        );
        expect(
          () => h.engine.capabilitiesOf(id),
          throwsWatchmeError(WatchmeErrorCode.internal),
        );
      },
    );
  });

  test('close waits for a device-record write in progress and starts no '
      'more', () async {
    // CI flake on main: a background lastSeen write landed in the state
    // directory after Engine.close returned, while the test deleted it.
    final repository = _HeldWrites();
    const keys = [CapabilitySupport.yes(Capability.systemKeys)];
    final roku = FakeDriver(
      'roku.ecp',
      ceiling: keys,
      onProbe: (_) => matched(capabilities: keys),
    );
    final engine = Engine(
      drivers: [roku],
      transports: FakeTransports(),
      credentials: MemoryCredentialStore(),
      repository: repository,
      clock: FakeClock(DateTime.utc(2026, 10, 22, 12)),
    );
    final id = (await engine.addManual('10.0.2.10')).id;
    await pump();
    repository.holdNext = true;
    expect(await engine.send(id, const PressKey(RemoteKey.home)), isConfirmed);
    await pump();
    final release = repository.held;
    expect(release, isNotNull, reason: 'connecting writes lastSeen');

    var closed = false;
    final closing = engine.close().then((_) => closed = true);
    await pump();
    expect(closed, isFalse, reason: 'the write is still on its way');
    release!.complete();
    await closing;
    final writes = repository.writes;
    await pump();
    expect(repository.writes, writes, reason: 'nothing is written after');
  });

  group('connect timeouts and races', () {
    late FakeDriver roku;
    late Harness h;
    late String id;
    late GatedCredentialStore store;

    setUp(() async {
      store = GatedCredentialStore();
      roku = FakeDriver(
        'roku.ecp',
        ceiling: keys,
        onProbe: (_) =>
            matched(name: 'Roku', mac: 'aa:bb:cc:dd:ee:10', capabilities: keys),
      );
      h = Harness(drivers: [roku], credentials: store);
      id = await h.add('10.0.2.10');
    });
    tearDown(() => h.close());

    test('a connect that times out fails the command, and the session that '
        'arrives late is closed', () async {
      final pending = Completer<DriverSession>();
      roku.onConnect = (_, _) => pending.future;
      final result = h.engine.send(id, home);
      await h.clock.advance(
        h.engine.config.connectTimeout + const Duration(seconds: 1),
      );
      expect(await result, isFailedWith(WatchmeErrorCode.timeout));
      expect(h.driverView(id, 'roku.ecp').connection, ConnectionState.failed);

      final late = FakeSession('roku.ecp', capabilities: keys);
      pending.complete(late);
      await pump();
      expect(late.closed, isTrue);
      expect(h.driverView(id, 'roku.ecp').connected, isFalse);
    });

    test('a refresh that hangs times out and is recorded', () async {
      await h.engine.send(id, home);
      final hang = Completer<DeviceState>();
      roku.lastSession.onRefresh = () => hang.future;
      final refreshing = h.engine.refresh(id);
      await h.clock.advance(
        h.engine.config.refreshTimeout + const Duration(seconds: 1),
      );
      await refreshing;
      expect(
        h.driverView(id, 'roku.ecp').lastError?.code,
        WatchmeErrorCode.timeout,
      );
      hang.complete(DeviceState.empty);
    });

    test('a device that moves while a connect reads its credential is '
        'connected at the new address', () async {
      store.gate = Completer();
      final result = h.engine.send(id, home);
      await pump();
      expect(store.reads, 1);
      // Same MAC at a new address: the slot is reset mid-connect.
      expect(await h.add('10.0.2.11'), id);
      store.gate!.complete();
      expect(await result, isConfirmed);
      expect(roku.connects.map((c) => c.endpoint.host), ['10.0.2.11']);
      expect(h.driverView(id, 'roku.ecp').connected, isTrue);
    });

    test('forgetting a device mid-connect closes the late session and keeps '
        'no credential', () async {
      await store.write(token(id, 'roku.ecp'));
      final pending = Completer<DriverSession>();
      roku.onConnect = (_, _) => pending.future;
      final result = h.engine.send(id, home);
      await pump();
      await h.engine.forget(id);
      final late = FakeSession('roku.ecp', capabilities: keys);
      pending.complete(late);
      expect(await result, isFailedWith(WatchmeErrorCode.cancelled));
      await pump();
      expect(late.closed, isTrue);
      expect(await store.readAll(id), isEmpty);
    });

    test('closing the engine mid-connect sends nothing afterwards', () async {
      store.gate = Completer();
      final result = h.engine.send(id, home);
      await pump();
      await h.engine.close();
      store.gate!.complete();
      expect(await result, isFailedWith(WatchmeErrorCode.cancelled));
      expect(roku.connects, isEmpty, reason: 'no connect after close');
    });
  });

  group('pairing', () {
    late FakeDriver fire;
    late Harness h;
    late String id;

    setUp(() async {
      fire = pinDriver();
      h = Harness(drivers: [fire]);
      id = await h.add('10.0.2.20');
    });
    tearDown(() => h.close());

    test('a driver that needs pairing is not connected before it', () async {
      expect(h.view(id).needsPairing, isTrue);
      expect(
        await h.engine.send(id, home),
        isFailedWith(WatchmeErrorCode.unauthorized),
      );
      expect(fire.connects, isEmpty);
      expect(
        h.driverView(id, 'firetv.lightning').connection,
        ConnectionState.disconnected,
        reason: 'nothing was attempted, so nothing failed',
      );
    });

    test(
      'pairing forwards steps, stores the credential and connects',
      () async {
        final flow = h.engine.pair(id, 'firetv.lightning');
        final steps = <PairingStep>[];
        final done = Completer<void>();
        flow.steps.listen((s) {
          steps.add(s);
          if (s is EnterCode) flow.submit('1234');
        }, onDone: done.complete);
        await done.future;

        expect(steps[0], isA<Instruct>());
        expect(steps[1], isA<EnterCode>());
        expect(
          steps.last,
          isPairedWith(isNull),
          reason: 'the credential never leaves the engine',
        );
        expect(fire.pairings.single.deviceId, id);
        expect(fire.pairings.single.clientName, 'watchme');

        final stored = await h.credentials.read(id, 'firetv.lightning');
        expect(stored, isA<TokenCredential>());
        expect((stored! as TokenCredential).token, 'token-for-1234');
        expect(fire.connects.single.credential, stored);
        final view = h.driverView(id, 'firetv.lightning');
        expect(view.paired, isTrue);
        expect(view.connected, isTrue);
        expect(await h.engine.send(id, home), isConfirmed);
      },
    );

    test('a wrong PIN fails with the device text and stores nothing', () async {
      final flow = h.engine.pair(id, 'firetv.lightning');
      final last = flow.steps.map((s) {
        if (s is EnterCode) flow.submit('9999');
        return s;
      }).last;
      expect(
        await last,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: contains('Invalid PIN'),
        ),
      );
      expect(await h.credentials.read(id, 'firetv.lightning'), isNull);
      // The slot is free again.
      final again = h.engine.pair(id, 'firetv.lightning');
      expect(await again.steps.first, isA<Instruct>());
      await again.cancel();
    });

    test('only one pairing per device and driver at a time', () async {
      final first = h.engine.pair(id, 'firetv.lightning');
      final second = h.engine.pair(id, 'firetv.lightning');
      expect(
        await second.steps.single,
        isPairingFailedWith(WatchmeErrorCode.rejected),
      );
      expect(fire.pairings, hasLength(1));
      await first.cancel();
      expect(
        await first.steps.last,
        isPairingFailedWith(WatchmeErrorCode.cancelled),
      );
      final third = h.engine.pair(id, 'firetv.lightning');
      expect(await third.steps.first, isA<Instruct>());
      await third.cancel();
    });

    test('cancelling stores nothing', () async {
      final flow = h.engine.pair(id, 'firetv.lightning');
      await pump();
      await flow.cancel();
      expect(
        await flow.steps.last,
        isPairingFailedWith(WatchmeErrorCode.cancelled),
      );
      expect(await h.credentials.read(id, 'firetv.lightning'), isNull);
    });

    test(
      'a credential for the wrong ids is stored under the right ones',
      () async {
        fire.onPair = (_, _) => PairingFlowController.run(
          (_) async => token('someone-else', 'other.driver'),
        );
        await h.engine.pair(id, 'firetv.lightning').steps.last;
        expect(await h.credentials.read(id, 'firetv.lightning'), isNotNull);
        expect(await h.credentials.readAll('someone-else'), isEmpty);
      },
    );

    test('the driver can read the credential it stored before, and only '
        'when it asks', () async {
      final old = token(id, 'firetv.lightning', secret: 'OLD-TOKEN');
      await h.credentials.write(old);
      Credential? seen;
      fire.onPair = (_, context) => PairingFlowController.run((_) async {
        seen = await context.previousCredential!();
        return token(id, 'firetv.lightning', secret: 'NEW-TOKEN');
      });
      final flow = h.engine.pair(id, 'firetv.lightning');
      expect(await flow.steps.last, isPairedWith(isNull));
      expect(seen, old);
      expect(
        ((await h.credentials.read(id, 'firetv.lightning'))! as TokenCredential)
            .token,
        'NEW-TOKEN',
      );

      // None stored: the reader gives null.
      await h.credentials.delete(id);
      seen = old;
      expect(
        await h.engine.pair(id, 'firetv.lightning').steps.last,
        isPairedWith(isNull),
      );
      expect(seen, isNull);
    });

    test('pairing again first closes the session the driver has open, for '
        'devices that serve one client at a time', () async {
      Future<PairingStep> pairWith(String pin) {
        final flow = h.engine.pair(id, 'firetv.lightning');
        return flow.steps.map((s) {
          if (s is EnterCode) flow.submit(pin);
          return s;
        }).last;
      }

      expect(await pairWith('1234'), isPairedWith(isNull));
      expect(h.driverView(id, 'firetv.lightning').connected, isTrue);
      final open = fire.lastSession;
      final pairing = fire.onPair!;
      bool? closedWhenPairing;
      fire.onPair = (endpoint, context) {
        closedWhenPairing = open.closed;
        return pairing(endpoint, context);
      };
      expect(await pairWith('1234'), isPairedWith(isNull));
      expect(closedWhenPairing, isTrue);
      expect(fire.sessions, hasLength(2));
      expect(h.driverView(id, 'firetv.lightning').connected, isTrue);

      // A pairing that fails leaves the driver to reconnect on the next
      // command, with the credential it had.
      expect(
        await pairWith('9999'),
        isPairingFailedWith(WatchmeErrorCode.unauthorized),
      );
      expect(fire.sessions.last.closed, isTrue);
      expect(await h.engine.send(id, home), isConfirmed);
      expect(fire.sessions, hasLength(3));
    });

    group('a device that serves one client at a time', () {
      late Completer<void> release;
      late List<PairingStep> steps;
      late Completer<void> done;

      setUp(() async {
        await h.credentials.write(token(id, 'firetv.lightning'));
        release = Completer<void>();
        steps = [];
        done = Completer<void>();
      });

      /// Pairs with the right PIN, recording the steps.
      void startPairing() {
        final flow = h.engine.pair(id, 'firetv.lightning');
        flow.steps.listen((s) {
          steps.add(s);
          if (s is EnterCode) flow.submit('1234');
        }, onDone: done.complete);
      }

      /// A session whose close lasts until [release] completes.
      SlowCloseSession slowSession() {
        final s = SlowCloseSession(release.future, capabilities: keys);
        fire.sessions.add(s);
        return s;
      }

      test('pairing starts only once the open session has finished '
          'closing, and nothing connects the driver meanwhile', () async {
        fire.onConnect = (_, _) => slowSession();
        expect(await h.engine.send(id, home), isConfirmed);
        final open = fire.lastSession as SlowCloseSession;
        startPairing();
        await pump();
        expect(open.closeStarted, isTrue);
        expect(fire.pairings, isEmpty, reason: 'the old session holds it');
        expect(
          await h.engine.send(id, home),
          isFailedWith(WatchmeErrorCode.rejected, message: contains('Pairing')),
        );
        expect(fire.connects, hasLength(1));

        release.complete();
        await done.future;
        expect(fire.pairings, hasLength(1));
        expect(steps.last, isPairedWith(isNull));
        expect(fire.connects, hasLength(2), reason: 'connected once paired');
        expect(await h.engine.send(id, home), isConfirmed);
      });

      test('a session the device dropped holds pairing back while it closes, '
          'and its reconnect never comes', () async {
        fire.onConnect = (_, _) => slowSession();
        expect(await h.engine.send(id, home), isConfirmed);
        final open = fire.lastSession as SlowCloseSession;
        open.emit(
          const ConnectionChanged(
            ConnectionState.disconnected,
            driverId: 'firetv.lightning',
          ),
        );
        await pump();
        expect(open.closeStarted, isTrue);
        startPairing();
        // Past the first reconnect's delay, within the connect timeout.
        await h.clock.advance(const Duration(seconds: 3));
        await pump();
        expect(fire.pairings, isEmpty, reason: 'still closing');
        expect(fire.connects, hasLength(1), reason: 'no reconnect');

        release.complete();
        await done.future;
        expect(fire.pairings, hasLength(1));
        expect(steps.last, isPairedWith(isNull));
        expect(fire.connects, hasLength(2), reason: 'connected once paired');
      });

      test('pairing waits for a connect in flight to settle and for the '
          'session it opened, which nobody will use, to close', () async {
        final gate = Completer<void>();
        fire.onConnect = (_, _) async {
          await gate.future;
          return slowSession();
        };
        final command = h.engine.send(id, home);
        await pump();
        expect(fire.connects, hasLength(1));
        startPairing();
        await pump();
        expect(fire.pairings, isEmpty, reason: 'a connect is in flight');

        gate.complete();
        await pump();
        final opened = fire.lastSession as SlowCloseSession;
        expect(opened.closeStarted, isTrue);
        expect(fire.pairings, isEmpty, reason: 'it is still closing');
        expect(await command, isA<Failed>());
        expect(fire.connects, hasLength(1));

        release.complete();
        await done.future;
        expect(fire.pairings, hasLength(1));
        expect(steps.last, isPairedWith(isNull));
        expect(opened.executed, isEmpty);
      });

      // Codex re-review of 7b4855f (Reqall 9526): the wait used to end in
      // the driver's pairing all the same, which then found the device
      // still held and failed as unreachable.
      test('a close that outlasts the connect timeout fails the pairing as a '
          'timeout, without starting the driver\'s pairing', () async {
        fire.onConnect = (_, _) => slowSession();
        expect(await h.engine.send(id, home), isConfirmed);
        final open = fire.lastSession as SlowCloseSession;
        startPairing();
        await pump();
        expect(fire.pairings, isEmpty);
        await h.clock.advance(
          const EngineConfig().connectTimeout - const Duration(seconds: 1),
        );
        await pump();
        expect(steps, isEmpty, reason: 'still waiting for the close');
        await h.clock.advance(const Duration(seconds: 1));
        await done.future;
        expect(steps.single, isPairingFailedWith(WatchmeErrorCode.timeout));
        expect(fire.pairings, isEmpty, reason: 'the device may still be held');
        expect(open.closed, isFalse);

        // The close ending later starts nothing; the slot is free again.
        release.complete();
        await pump();
        expect(fire.pairings, isEmpty);
        expect(steps, hasLength(1));
        expect(await h.engine.send(id, home), isConfirmed);
      });

      test('a pairing cancelled while it waits for the close never starts, '
          'and the wait running out later changes nothing', () async {
        fire.onConnect = (_, _) => slowSession();
        expect(await h.engine.send(id, home), isConfirmed);
        final flow = h.engine.pair(id, 'firetv.lightning');
        final seen = <PairingStep>[];
        final ended = Completer<void>();
        flow.steps.listen(seen.add, onDone: ended.complete);
        await pump();
        flow.submit('1234');
        await flow.cancel();
        await ended.future;
        expect(seen.single, isPairingFailedWith(WatchmeErrorCode.cancelled));

        await h.clock.advance(const EngineConfig().connectTimeout);
        await pump();
        release.complete();
        await pump();
        expect(fire.pairings, isEmpty);
        expect(seen, hasLength(1));
        expect(await h.credentials.read(id, 'firetv.lightning'), isNotNull);
      });

      test('a failed pairing frees the driver for the next command', () async {
        fire.onConnect = (_, _) => slowSession();
        expect(await h.engine.send(id, home), isConfirmed);
        final flow = h.engine.pair(id, 'firetv.lightning');
        release.complete();
        final last = flow.steps.map((s) {
          if (s is EnterCode) flow.submit('9999');
          return s;
        }).last;
        expect(await last, isPairingFailedWith(WatchmeErrorCode.unauthorized));
        expect(await h.engine.send(id, home), isConfirmed);
        expect(fire.connects, hasLength(2));
      });
    });

    test('a driver that offers optional pairing shows as pairable', () async {
      final sharp = FakeDriver(
        'sharp.aquos',
        offersPairing: true,
        onProbe: (_) => matched(name: 'AQUOS'),
      );
      final h2 = Harness(drivers: [sharp]);
      addTearDown(h2.close);
      final sharpId = await h2.add('10.0.2.31');
      final view = h2.driverView(sharpId, 'sharp.aquos');
      expect(view.offersPairing, isTrue);
      expect(view.canPair, isTrue);
      expect(view.needsPairing, isFalse);
      expect(h.driverView(id, 'firetv.lightning').offersPairing, isFalse);
      expect(h.driverView(id, 'firetv.lightning').canPair, isTrue);
    });

    test(
      'drivers without pairing, unknown devices and unknown drivers fail',
      () async {
        final roku = FakeDriver('roku.ecp', onProbe: (_) => matched(name: 'R'));
        final h2 = Harness(drivers: [roku]);
        addTearDown(h2.close);
        final rokuId = await h2.add('10.0.2.30');
        expect(
          await h2.engine.pair(rokuId, 'roku.ecp').steps.single,
          isPairingFailedWith(WatchmeErrorCode.unsupported),
        );
        expect(
          await h2.engine.pair('nope', 'roku.ecp').steps.single,
          isPairingFailedWith(WatchmeErrorCode.internal),
        );
        expect(
          await h2.engine.pair(rokuId, 'firetv.lightning').steps.single,
          isPairingFailedWith(WatchmeErrorCode.unsupported),
        );
      },
    );
  });

  group('re-authentication', () {
    late FakeDriver fire;
    late Harness h;
    late String id;

    setUp(() async {
      fire = pinDriver();
      h = Harness(drivers: [fire]);
      id = await h.add('10.0.2.20');
      await h.credentials.write(token(id, 'firetv.lightning'));
      expect(await h.engine.send(id, home), isConfirmed);
    });
    tearDown(() => h.close());

    Future<void> expectInvalidated(List<DeviceEvent> events) async {
      await pump();
      final reauth = events.whereType<ReauthRequired>();
      expect(reauth, hasLength(1));
      expect(reauth.single.error.rawDeviceMessage, '401 token revoked');
      final view = h.driverView(id, 'firetv.lightning');
      expect(view.paired, isFalse);
      expect(view.needsPairing, isTrue);
      expect(view.lastError?.code, WatchmeErrorCode.reauthRequired);

      final connects = fire.connects.length;
      expect(
        await h.engine.send(id, home),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      expect(
        fire.connects,
        hasLength(connects),
        reason: 'the revoked credential is not used again',
      );
    }

    test('a ReauthRequired event marks the pairing invalid', () async {
      final events = <DeviceEvent>[];
      h.engine.events(id).listen(events.add);
      final session = fire.lastSession;
      session.emit(
        const ReauthRequired(
          WatchmeError.reauthRequired(
            'Token revoked',
            rawDeviceMessage: '401 token revoked',
          ),
          driverId: 'firetv.lightning',
        ),
      );
      await expectInvalidated(events);
      expect(session.closed, isTrue);
    });

    test('Failed(reauthRequired) from a command does the same', () async {
      final events = <DeviceEvent>[];
      h.engine.events(id).listen(events.add);
      fire.lastSession.onExecute = (_) => const Failed(
        WatchmeError.reauthRequired(
          'Token revoked',
          rawDeviceMessage: '401 token revoked',
        ),
      );
      expect(
        await h.engine.send(id, home),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await expectInvalidated(events);
    });

    test('a connect rejecting the credential does the same', () async {
      final events = <DeviceEvent>[];
      h.engine.events(id).listen(events.add);
      fire.lastSession.emit(
        const ConnectionChanged(
          ConnectionState.disconnected,
          driverId: 'firetv.lightning',
        ),
      );
      fire.connectError = const WatchmeError.reauthRequired(
        'Token revoked',
        rawDeviceMessage: '401 token revoked',
      );
      await h.clock.advance(const Duration(seconds: 1));
      await expectInvalidated(events);
    });

    // A connect whose wake may have reached the device reports
    // partiallyDelivered, whatever failed after it, the credential's
    // rejection included (Codex re-review of finding #4, Reqall 9345). The
    // revocation is in its cause, and must still be noticed.
    for (final cause in const [
      WatchmeError.reauthRequired(
        'Token revoked',
        rawDeviceMessage: '401 token revoked',
      ),
      WatchmeError.unauthorized(
        'Token rejected',
        rawDeviceMessage: '401 token revoked',
      ),
    ]) {
      test('a connect that woke the device, then had the credential rejected '
          '(${cause.code.name}), does the same', () async {
        final events = <DeviceEvent>[];
        h.engine.events(id).listen(events.add);
        fire.lastSession.emit(
          const ConnectionChanged(
            ConnectionState.disconnected,
            driverId: 'firetv.lightning',
          ),
        );
        await pump();
        fire.connectError = WatchmeError.partiallyDelivered(
          'The DIAL wake reached the TV, then: ${cause.message}',
          cause: cause,
        );
        expect(
          await h.engine.send(id, home),
          isFailedWith(WatchmeErrorCode.partiallyDelivered),
        );
        expect(fire.connects.last.allowWake, isTrue);
        await expectInvalidated(events);
      });
    }

    test('a command partly delivered before the credential was revoked does '
        'the same', () async {
      final events = <DeviceEvent>[];
      h.engine.events(id).listen(events.add);
      fire.lastSession.onExecute = (_) => const Failed(
        WatchmeError.partiallyDelivered(
          'Typed 3 of 8 characters, then the token was revoked',
          cause: WatchmeError.reauthRequired(
            'Token revoked',
            rawDeviceMessage: '401 token revoked',
          ),
        ),
      );
      expect(
        await h.engine.send(id, home),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      await expectInvalidated(events);
    });

    test('pairing again restores the driver', () async {
      fire.lastSession.emit(
        const ReauthRequired(
          WatchmeError.reauthRequired('revoked'),
          driverId: 'firetv.lightning',
        ),
      );
      await pump();
      final flow = h.engine.pair(id, 'firetv.lightning');
      final last = flow.steps.map((s) {
        if (s is EnterCode) flow.submit('1234');
        return s;
      }).last;
      expect(await last, isPairedWith());
      final view = h.driverView(id, 'firetv.lightning');
      expect(view.paired, isTrue);
      expect(view.connected, isTrue);
      expect(
        (fire.connects.last.credential! as TokenCredential).token,
        'token-for-1234',
      );
      expect(await h.engine.send(id, home), isConfirmed);
    });
  });
}

/// A device repository whose next write, once [holdNext] is set, waits
/// until [held] is completed.
final class _HeldWrites implements DeviceRepository {
  final MemoryDeviceRepository _records = MemoryDeviceRepository();
  bool holdNext = false;
  Completer<void>? held;
  int writes = 0;

  @override
  Future<List<DeviceRecord>> all() => _records.all();

  @override
  Future<DeviceRecord?> get(String id) => _records.get(id);

  @override
  Future<void> put(DeviceRecord record) async {
    if (holdNext) {
      holdNext = false;
      await (held = Completer<void>()).future;
    }
    await _records.put(record);
    writes++;
  }

  @override
  Future<void> remove(String id) => _records.remove(id);
}

/// A [FakeSession] whose close lasts until [release] completes, as the
/// close of a connection that waits for the device can.
class SlowCloseSession extends FakeSession {
  SlowCloseSession(this.release, {super.capabilities})
    : super('firetv.lightning');

  /// Completes when the close may finish.
  final Future<void> release;

  /// Whether [close] was called.
  bool closeStarted = false;

  @override
  Future<void> close() async {
    closeStarted = true;
    await release;
    await super.close();
  }
}
