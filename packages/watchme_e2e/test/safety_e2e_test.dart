@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

/// The safety rules of the M0 review, end to end: the real engine, the real
/// `dart:io` stack and the real drivers against the loopback simulators,
/// with both loopback guards on.
///
/// Some tests use one host that both simulators answer on, so the engine
/// sees one device with a Roku and a Fire TV session: two independent
/// power sources (Roku device-info and the Fire TV API), and two volume
/// routes (Roku first, as the documented protocol).
void main() {
  late Directory dir;

  setUp(() async {
    dir = await tempStateDir();
  });

  Matcher failedWithCause(WatchmeErrorCode code, WatchmeErrorCode cause) =>
      isA<Failed>().having(
        (r) => r.error,
        'error',
        isA<WatchmeError>()
            .having((e) => e.code, 'code', code)
            .having(
              (e) => e.cause,
              'cause',
              isA<WatchmeError>().having((c) => c.code, 'code', cause),
            ),
      );

  /// Adds a Fire TV simulator (and a refusal for the Roku probe) and pairs
  /// it, answering the PIN the simulator shows.
  Future<String> addAndPairFireTv(
    E2eSystem system,
    FireTvSimulator sim, {
    int? ecpPort,
  }) async {
    final view = await system.engine.addManual(
      '127.0.0.1',
      ports: {
        FireTvPorts.dial: sim.dialPort,
        FireTvPorts.api: sim.apiPort,
        rokuEcpPortName: ecpPort ?? await closedPort(),
      },
    );
    final flow = system.engine.pair(view.id, fireTvDriverId);
    final steps = await runPairing(
      flow.steps,
      flow.submit,
      () => sim.displayedPin!,
    );
    expect(steps.last, isA<Paired>());
    return view.id;
  }

  group('Fire TV alone', () {
    late FireTvSimulator sim;
    late E2eSystem system;
    late String id;

    setUp(() async {
      sim = await FireTvSimulator.start();
      addTearDown(sim.close);
      system = await E2eSystem.start(dir);
      id = await addAndPairFireTv(system, sim);
      // Opens the session; the TV is awake and on.
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      sim.clearLog();
    });

    test('#1 the power key asks when the only source infers the state, and '
        "the user's answer turns the TV off without the toggle", () async {
      final engine = system.engine;
      // The Fire TV session is the only power source, and it infers the
      // state (from what it sent and which port answers) rather than
      // reading a report: no guess is made, though its routes are
      // discrete.
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      // Holding a toggle is refused outright.
      for (final action in [KeyAction.down, KeyAction.up]) {
        expect(
          await engine.send(id, PressKey(RemoteKey.power, action)),
          isUnsupported(),
        );
      }
      expect(sim.effects, isEmpty, reason: 'nothing reached the TV');
      expect(sim.awake, isTrue);

      // The app asks "Is the TV on right now?"; the user says it is.
      expect(
        await engine.send(id, const SetPower(false, userConfirmed: true)),
        isDelivered,
      );
      expect(sim.effects, ['sleep'], reason: 'the discrete off, not `power`');
      await eventually(() => !sim.awake, reason: 'the stick to sleep');
    });

    test('#3 forgetting the device stops a volume run after the press in '
        'flight', () async {
      final gate = sim.holdNext('POST', '/v1/FireTV', action: 'volume_up');
      final result = system.engine.send(id, const StepVolume(3));
      await gate.reached;
      final forgetting = system.engine.forget(id);
      gate.release();
      expect(
        await result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.cancelled,
        ),
      );
      await forgetting;
      // Give a runaway loop time to show itself.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(sim.effects, ['volume_up']);
    });

    test('#8 a device error that echoes the client token never shows '
        'it', () async {
      final token = sim.validTokens.single;
      sim.respondOnce(
        'POST',
        '/v1/FireTV',
        401,
        body: jsonEncode({'description': 'token $token was revoked'}),
      );
      final events = record(system.engine.events(id));
      final result = await system.engine.send(
        id,
        const PressKey(RemoteKey.home),
      );
      expect(result, isFailedWith(WatchmeErrorCode.reauthRequired));
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      final view = system.engine.currentDevices.single;
      final shown = [
        '$result',
        jsonEncode(result.toJson()),
        (result as Failed).error.rawDeviceMessage,
        '${result.error.cause}',
        for (final e in events) jsonEncode(e.toJson()),
        jsonEncode(view.toJson()),
      ].join('\n');
      expect(shown, contains('revoked'), reason: 'the device text is kept');
      expect(shown, isNot(contains(token)));
    });

    test('#9 a Fire TV that drops off the network shows as disconnected '
        'with stale state, and background recovery never wakes it', () async {
      // A short backoff, so several passive reconnects run in the test.
      await system.close();
      system = await E2eSystem.start(
        dir,
        config: const EngineConfig(
          probeTimeout: Duration(seconds: 5),
          connectTimeout: Duration(seconds: 10),
          reconnect: Backoff(
            initial: Duration(milliseconds: 40),
            max: Duration(milliseconds: 80),
            maxAttempts: null,
          ),
          power: PowerConfig(broadcastAddress: '127.255.255.255'),
        ),
      );
      final engine = system.engine;
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isDelivered,
      );
      final events = record(engine.events(id));
      DriverView driver() => engine.currentDevices.single.drivers.single;
      expect(driver().connection, ConnectionState.connected);
      expect(
        engine.currentDevices.single.state.power?.confidence,
        isNot(Confidence.stale),
      );
      final wakes = sim.wakeCount;
      sim.clearLog();

      await sim.vanish();
      await engine.refresh(id);

      // Disconnected, or already failed by a passive reconnect attempt.
      expect(driver().connection, isNot(ConnectionState.connected));
      expect(driver().lastError?.code, WatchmeErrorCode.unreachable);
      final power = engine.currentDevices.single.state.power;
      expect(power?.value, PowerMode.on, reason: 'last known');
      expect(power?.confidence, Confidence.stale);
      expect(
        events.whereType<ConnectionChanged>().map((e) => e.state),
        contains(ConnectionState.disconnected),
      );

      // Passive recovery while it is gone, then once it is back but asleep:
      // status reads only, never a DIAL launch.
      system.transports.httpLog.clear();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await sim.reappear();
      final sinceBack = system.transports.httpLog.length;
      await eventually(
        () => system.transports.httpLog.length >= sinceBack + 3,
        reason: 'reconnect attempts against the sleeping stick',
      );
      final attempts = system.transports.httpLog.toList();
      expect(attempts, isNotEmpty);
      for (final call in attempts) {
        expect(call, startsWith('GET '), reason: call);
        expect(call, endsWith('/v1/FireTV/status'), reason: call);
      }
      expect(sim.wakeCount, wakes, reason: 'a background reconnect woke it');
      expect(sim.dialRequests.where((r) => r.method == 'POST'), isEmpty);
      expect(sim.awake, isFalse);
      expect(driver().connection, isNot(ConnectionState.connected));

      // A key the user presses may wake it, as on the real remote.
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.wakeCount, wakes + 1);
      expect(driver().connection, ConnectionState.connected);
    });
  });

  group('Roku TV alone', () {
    late RokuSimulator sim;

    /// The e2e configuration with a short quiet period, so a test can wait
    /// it out.
    const quickQuiet = EngineConfig(
      probeTimeout: Duration(seconds: 5),
      connectTimeout: Duration(seconds: 10),
      power: PowerConfig(
        broadcastAddress: '127.255.255.255',
        wakeTimeout: Duration(seconds: 3),
        wakePollInterval: Duration(milliseconds: 200),
        toggleQuietPeriod: Duration(milliseconds: 500),
      ),
    );

    setUp(() async {
      sim = RokuSimulator();
      await sim.start();
      addTearDown(sim.stop);
    });

    /// Adds the simulator (and refusals for the Fire TV probe).
    Future<String> addRoku(E2eSystem system) async {
      final view = await system.engine.addManual(
        '127.0.0.1',
        ports: {
          rokuEcpPortName: sim.port,
          FireTvPorts.dial: await closedPort(),
          FireTvPorts.api: await closedPort(),
        },
      );
      expect(view.drivers.map((d) => d.driverId), [rokuDriverId]);
      return view.id;
    }

    Iterable<String> rokuKeys() => sim.keyLog.map((k) => k.key);

    test('#1 its own power-mode report is enough for the power key to turn '
        'it off and on with the discrete keys, never the raw toggle', () async {
      final system = await E2eSystem.start(dir, config: quickQuiet);
      final engine = system.engine;
      final id = await addRoku(system);
      sim.clearLogs();

      // One source (device-info and the session are the same driver), but
      // it is the TV's own report and PowerOff is discrete.
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isConfirmed,
      );
      expect(rokuKeys(), ['PowerOff']);
      expect(sim.powerMode, RokuSimPowerMode.ready);

      // Within the quiet period the report may lag: the next press asks.
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(rokuKeys(), ['PowerOff']);

      // After it, the fresh report says standby, and PowerOn is discrete.
      await Future<void>.delayed(quickQuiet.power.toggleQuietPeriod);
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isConfirmed,
      );
      expect(rokuKeys(), ['PowerOff', 'PowerOn']);
      expect(sim.powerMode, RokuSimPowerMode.powerOn);
      expect(rokuKeys(), isNot(contains('Power')), reason: 'no raw toggle');
    });

    test('one slow answer neither drops the session nor makes the device '
        'stale', () async {
      final system = await E2eSystem.start(
        dir,
        rokuRequestTimeout: const Duration(milliseconds: 400),
      );
      final engine = system.engine;
      final id = await addRoku(system);
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      DriverView driver() => engine.currentDevices.single.drivers.single;
      Observed<PowerMode>? power() => engine.currentDevices.single.state.power;
      expect(driver().connection, ConnectionState.connected);
      expect(power()?.confidence, Confidence.reported);
      final events = record(engine.events(id));

      // The Roku acts on the key but answers after the deadline.
      final gate = sim.holdNext('POST', '/keypress/Up');
      expect(
        await engine.send(id, const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.timeout),
      );
      expect(gate.isReached, isTrue);
      gate.release();
      // Give a dropped session's events time to show.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(events.whereType<ConnectionChanged>(), isEmpty);
      expect(driver().connection, ConnectionState.connected);
      expect(driver().lastError?.code, WatchmeErrorCode.timeout);
      expect(power()?.value, PowerMode.on);
      expect(power()?.confidence, Confidence.reported);

      // The same session carries on: no reconnect reads device-info again.
      sim.clearLogs();
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.requests.map((r) => r.path), ['/keypress/Home']);
      expect(events.whereType<ConnectionChanged>(), isEmpty);
    });

    /// The e2e configuration with the Wake-on-LAN rounds far enough apart
    /// for a test to act between them.
    const slowRounds = EngineConfig(
      probeTimeout: Duration(seconds: 5),
      connectTimeout: Duration(seconds: 10),
      power: PowerConfig(
        broadcastAddress: '127.255.255.255',
        wakeTimeout: Duration(seconds: 3),
        wakePollInterval: Duration(milliseconds: 200),
        wakeOnLanInterval: Duration(milliseconds: 300),
      ),
    );

    /// The magic packets of one Wake-on-LAN round for device [id]: each
    /// cached MAC to the loopback broadcast and as unicast, on ports 9
    /// and 7.
    Future<int> roundOf(E2eSystem system, String id) async =>
        (await system.devices.get(id))!.allMacs.length * 2 * 2;

    test('closing the engine between Wake-on-LAN rounds sends no more '
        'packets, and the caller learns some went out', () async {
      final system = await E2eSystem.start(dir, config: slowRounds);
      final id = await addRoku(system);
      final round = await roundOf(system, id);
      expect(round, greaterThan(0));
      // Off the network: the discrete PowerOn fails, so magic packets go
      // to the cached MACs.
      await sim.stop();
      final datagrams = system.transports.datagramLog;
      final result = system.engine.send(id, const SetPower(true));
      await eventually(() => datagrams.length >= round, reason: 'one round');
      final sent = datagrams.length;
      expect(sent, round, reason: 'one round, then a 300 ms gap');

      await system.engine.close();
      // Two more rounds were due within 600 ms.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(datagrams, hasLength(sent));
      expect(
        await result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.cancelled,
        ),
      );
    });

    test('closing the engine while it waits for the woken device ends the '
        'wait without another probe, and the caller learns packets went '
        'out', () async {
      final system = await E2eSystem.start(dir, config: slowRounds);
      final id = await addRoku(system);
      final all = slowRounds.power.wakeOnLanRepeats * await roundOf(system, id);
      await sim.stop();
      final transports = system.transports;
      final result = system.engine.send(id, const SetPower(true));
      // Every round went out, and the wait polls the device every 200 ms.
      await eventually(() => transports.datagramLog.length >= all);
      final probed = transports.httpLog.length;
      await eventually(
        () => transports.httpLog.length > probed,
        reason: 'the first poll',
      );

      final polls = transports.httpLog.length;
      await system.engine.close();
      // The wait had more than two seconds left: about ten polls.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(transports.httpLog, hasLength(polls));
      expect(transports.datagramLog, hasLength(all));
      expect(
        await result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.cancelled,
        ),
      );
    });
  });

  group('one host both drivers recognise', () {
    late RokuSimulator roku;
    late FireTvSimulator fireTv;
    late E2eSystem system;
    late String id;

    setUp(() async {
      roku = RokuSimulator();
      await roku.start();
      addTearDown(roku.stop);
      fireTv = await FireTvSimulator.start();
      addTearDown(fireTv.close);
      system = await E2eSystem.start(dir);
      id = await addAndPairFireTv(system, fireTv, ecpPort: roku.port);
      expect(
        system.engine.currentDevices.single.drivers.map((d) => d.driverId),
        unorderedEquals([rokuDriverId, fireTvDriverId]),
      );
      // Both sessions open; both report the TV on.
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.select)),
        isConfirmed,
      );
      for (final d in system.engine.currentDevices.single.drivers) {
        expect(d.connection, ConnectionState.connected, reason: d.driverId);
      }
      roku.clearLogs();
      fireTv.clearLog();
    });

    Iterable<String> rokuKeys() => roku.keyLog.map((k) => k.key);

    test('#1 with two agreeing sources the power key turns the TV off with '
        'the discrete key, and the next press asks', () async {
      final engine = system.engine;
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isDelivered,
      );
      expect(rokuKeys(), ['PowerOff']);
      expect(roku.powerMode, RokuSimPowerMode.ready);
      expect(fireTv.effects, isEmpty);

      // Within the quiet period the evidence lags: no second guess.
      expect(
        await engine.send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(rokuKeys(), ['PowerOff']);

      // The user says the TV is off now, and asks for on. Either driver's
      // discrete power-on may carry it (they rank equal; latency decides);
      // neither sends a raw toggle.
      expect(
        await engine.send(id, const SetPower(true, userConfirmed: true)),
        isDelivered,
      );
      expect(
        rokuKeys().contains('PowerOn') || fireTv.effects.contains('wake'),
        isTrue,
        reason: 'roku ${roku.keyLog}, fire tv ${fireTv.effects}',
      );
      expect(rokuKeys(), isNot(contains('Power')), reason: 'no raw toggle');
      expect(fireTv.effects, isNot(contains('power')));
    });

    test('#2 power commands sent together run one at a time: one off goes '
        'out, and the power key behind it does not act on old '
        'evidence', () async {
      final engine = system.engine;
      final gate = roku.holdNext('POST', '/keypress/PowerOff');
      final first = engine.send(id, const SetPower(false));
      await gate.reached;
      final again = engine.send(id, const SetPower(false));
      final key = engine.send(id, const PressKey(RemoteKey.power));
      // Let anything that is not waiting its turn reach the simulators.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      gate.release();

      final results = await Future.wait([first, again, key]);
      expect(results[0], isDelivered);
      expect(results[1], same(results[0]), reason: 'joined the first');
      expect(results[2], isUnsupported(Unsupported.needsConfirmation));
      expect(rokuKeys(), ['PowerOff'], reason: 'exactly one off');
      expect(fireTv.effects, isEmpty);
    });

    test('#4 a volume run cut short after one press is not replayed through '
        'the other driver', () async {
      final gate = roku.holdNext('POST', '/keypress/VolumeUp');
      final result = system.engine.send(id, const StepVolume(3));
      await gate.reached;
      // The Roku drops off the network right after its first press. Its
      // port must refuse before the next press, or that press may connect
      // and be reset (a protocol error, not unreachable).
      final stopped = roku.stop(force: false);
      await roku.listenerClosed;
      gate.release();
      expect(
        await result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.unreachable,
        ),
      );
      await stopped;
      expect(rokuKeys(), ['VolumeUp']);
      expect(
        fireTv.effects.where((e) => e.startsWith('volume')),
        isEmpty,
        reason: 'the Fire TV route would press three more times',
      );
    });
  });

  group('#4 a wake sent while connecting', () {
    late FireTvSimulator sim;
    late ToggleOnlyPowerDriver toggle;
    late E2eSystem system;
    late String id;

    /// How long the Fire TV driver waits for its API after a wake.
    const apiStartup = Duration(milliseconds: 500);

    /// A device with two power-on routes: the Fire TV's DIAL wake
    /// (discrete), and a toggle. It is paired, then the engine restarts
    /// with the stick asleep, so the next command connects (and wakes).
    setUp(() async {
      sim = await FireTvSimulator.start();
      addTearDown(sim.close);
      toggle = ToggleOnlyPowerDriver();
      final first = await E2eSystem.start(
        dir,
        extraDrivers: [toggle],
        fireTvApiStartupTimeout: apiStartup,
      );
      id = await addAndPairFireTv(first, sim);
      expect(
        first.engine.currentDevices.single.drivers.map((d) => d.driverId),
        unorderedEquals([fireTvDriverId, ToggleOnlyPowerDriver.id]),
      );
      await first.close();
      await sim.sleep();
      system = await E2eSystem.start(
        dir,
        extraDrivers: [toggle],
        fireTvApiStartupTimeout: apiStartup,
      );
      sim.clearLog();
    });

    Iterable<FireTvSimRequest> wakes() =>
        sim.dialRequests.where((r) => r.method == 'POST');

    test('an acknowledged DIAL wake whose API never opens is a partial '
        'delivery: no toggle follows to undo it', () async {
      // The DIAL server takes the wake, but the API port stays closed (a
      // stick slow to boot, or one whose remote app failed to start).
      sim.respondOnce('POST', '/apps/FireTVRemote', 201);
      final result = await system.engine.send(
        id,
        const SetPower(true, userConfirmed: true),
      );
      expect(
        result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.unreachable,
        ),
      );
      expect(wakes(), hasLength(1));
      expect(
        toggle.toggles,
        isEmpty,
        reason: 'the woken TV would be switched straight back off',
      );
      final fireTv = system.engine.currentDevices.single.drivers.firstWhere(
        (d) => d.driverId == fireTvDriverId,
      );
      expect(fireTv.lastError?.code, WatchmeErrorCode.partiallyDelivered);
      expect(fireTv.needsPairing, isFalse);
      // The wake may still take effect: it starts the quiet period, as a
      // delivered power-on would, so no toggle follows it for a while.
      expect(system.engine.power.lastCommand(id)?.on, isTrue);
    });

    test('a token refused after the wake still asks for pairing, and no '
        'toggle follows', () async {
      sim.revokeTokens();
      final events = record(system.engine.events(id));
      final result = await system.engine.send(
        id,
        const SetPower(true, userConfirmed: true),
      );
      expect(
        result,
        failedWithCause(
          WatchmeErrorCode.partiallyDelivered,
          WatchmeErrorCode.reauthRequired,
        ),
      );
      expect(wakes(), hasLength(1));
      expect(sim.awake, isTrue, reason: 'the wake worked');
      expect(toggle.toggles, isEmpty, reason: 'it would turn the TV off');
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      final fireTv = system.engine.currentDevices.single.drivers.firstWhere(
        (d) => d.driverId == fireTvDriverId,
      );
      expect(fireTv.needsPairing, isTrue);
      expect(fireTv.lastError?.code, WatchmeErrorCode.reauthRequired);
    });
  });

  group('#6 LAN-only destinations', () {
    test('the engine refuses a public or shared-range IP before any driver '
        'runs', () async {
      final system = await E2eSystem.start(dir);
      for (final host in [
        '8.8.8.8',
        '100.64.0.1',
        '::ffff:8.8.8.8',
        '2001:4860:4860::8888',
      ]) {
        await expectLater(
          system.engine.addManual(host),
          throwsWatchmeError(WatchmeErrorCode.destinationRefused),
          reason: host,
        );
      }
      expect(system.transports.httpLog, isEmpty);
      expect(system.engine.currentDevices, isEmpty);
    });

    test('the stack refuses a public IP the engine never checked (a device '
        'record from elsewhere)', () async {
      final roku = RokuSimulator();
      await roku.start();
      addTearDown(roku.stop);
      final first = await E2eSystem.start(dir);
      final added = await first.engine.addManual(
        '127.0.0.1',
        ports: {
          rokuEcpPortName: roku.port,
          FireTvPorts.dial: await closedPort(),
          FireTvPorts.api: await closedPort(),
        },
      );
      await first.close();
      // The stored record now names a public host, as one written by an
      // older version, or edited by hand, would.
      final file = File(E2eSystem.devicesPath(dir));
      file.writeAsStringSync(
        file.readAsStringSync().replaceAll('127.0.0.1', '8.8.8.8'),
      );
      roku.clearLogs();

      // The outer guard lets 8.8.8.8 through to the real stack; the socket
      // guard below it still stops any connection.
      final system = await E2eSystem.start(dir, passThrough: {'8.8.8.8'});
      expect(system.engine.currentDevices.single.host, '8.8.8.8');
      expect(
        await system.engine.send(added.id, const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.destinationRefused,
          message: contains('8.8.8.8'),
        ),
      );
      expect(nativeBlocked, isEmpty, reason: 'refused before connecting');
      expect(roku.requests, isEmpty);
    });

    test('the stack checks what a host name resolves to, every time '
        '(DNS rebinding)', () async {
      final roku = RokuSimulator(enforceIpHost: false);
      await roku.start();
      addTearDown(roku.stop);
      var answer = InternetAddress.loopbackIPv4;
      final system = await E2eSystem.start(
        dir,
        lookup: (host) async => host == 'tv.e2e.test'
            ? [answer]
            : throw SocketException('no such host: $host'),
        passThrough: {'tv.e2e.test'},
      );
      final view = await system.engine.addManual(
        'tv.e2e.test',
        ports: {
          rokuEcpPortName: roku.port,
          FireTvPorts.dial: await closedPort(),
          FireTvPorts.api: await closedPort(),
        },
      );
      expect(
        await system.engine.send(view.id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(roku.keyLog.single.key, 'Home');

      // The name now points at the internet. The open session's next
      // request resolves it again, and is refused before connecting.
      answer = InternetAddress('8.8.8.8');
      roku.clearLogs();
      expect(
        await system.engine.send(view.id, const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.destinationRefused,
          message: contains('8.8.8.8'),
        ),
      );
      expect(nativeBlocked, isEmpty, reason: 'nothing left loopback');
      expect(roku.requests, isEmpty);
    });
  });

  group('#8 pairing secrets', () {
    test('a token the Fire TV returns but watchme cannot use appears in no '
        'step, error or view', () async {
      final sim = await FireTvSimulator.start();
      addTearDown(sim.close);
      final system = await E2eSystem.start(dir);
      final view = await system.engine.addManual(
        '127.0.0.1',
        ports: {
          FireTvPorts.dial: sim.dialPort,
          FireTvPorts.api: sim.apiPort,
          rokuEcpPortName: await closedPort(),
        },
      );
      // A token ending in a newline: not printable, so it is refused, but
      // it is still a token.
      const secret = 'Zq7v9TkW2mRcX4pL';
      sim.respondOnce(
        'POST',
        '/v1/FireTV/pin/verify',
        200,
        body: jsonEncode({'description': '$secret\n'}),
      );
      final flow = system.engine.pair(view.id, fireTvDriverId);
      final steps = await runPairing(
        flow.steps,
        flow.submit,
        () => sim.displayedPin!,
      );
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.protocol));
      final failure = (steps.last as PairingFailed).error;
      final shown = [
        for (final s in steps) ...[
          jsonEncode(s.toJson()),
          jsonEncode(s.toJson(includeSecrets: true)),
          '$s',
        ],
        '$failure',
        failure.message,
        '${failure.rawDeviceMessage}',
        '${failure.cause}',
        jsonEncode(system.engine.currentDevices.single.toJson()),
      ].join('\n');
      expect(shown, isNot(contains(secret)));
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
      expect(await system.credentials.readAll(view.id), isEmpty);
    });
  });
}
