@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

void main() {
  late FireTvSimulator sim;
  late Directory dir;
  late E2eSystem system;
  late Map<String, int> ports;

  setUp(() async {
    // Asleep, as a real stick usually is: the API port refuses connections
    // until a DIAL wake.
    sim = await FireTvSimulator.start();
    addTearDown(sim.close);
    dir = await tempStateDir();
    system = await E2eSystem.start(dir);
    ports = {
      FireTvPorts.dial: sim.dialPort,
      FireTvPorts.api: sim.apiPort,
      // The Roku driver probes too; point it at a refusal.
      'ecp': await closedPort(),
    };
  });

  Future<DeviceView> addFireTv([E2eSystem? on]) =>
      (on ?? system).engine.addManual('127.0.0.1', ports: ports);

  /// Pairs through the engine, answering the PIN the simulator shows.
  Future<List<PairingStep>> pair(String deviceId, [E2eSystem? on]) {
    final flow = (on ?? system).engine.pair(deviceId, fireTvDriverId);
    return runPairing(flow.steps, flow.submit, () => sim.displayedPin!);
  }

  Future<String> addAndPair() async {
    final id = (await addFireTv()).id;
    final steps = await pair(id);
    expect(steps.last, isA<Paired>());
    return id;
  }

  Iterable<FireTvSimRequest> apiPosts(String path) =>
      sim.apiRequests.where((r) => r.method == 'POST' && r.path == path);

  group('manual add', () {
    test('recognises a sleeping Fire TV without waking it', () async {
      final view = await addFireTv();
      expect(view.drivers.map((d) => d.driverId), [fireTvDriverId]);
      expect(view.manufacturer, 'Amazon');
      expect(view.needsPairing, isTrue);
      expect(view.drivers.single.notes.join(' '), contains('asleep'));
      expect(sim.wakeCount, 0);
      expect(sim.dialRequests.where((r) => r.method != 'GET'), isEmpty);
      expect(sim.awake, isFalse);
    });

    test('recognises an awake Fire TV by its API', () async {
      await sim.wake();
      final view = await addFireTv();
      expect(view.drivers.single.notes.join(' '), contains('answered'));
      expect(sim.wakeCount, 0);
    });

    test('commands before pairing ask for pairing and wake nothing', () async {
      final id = (await addFireTv()).id;
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.unauthorized),
      );
      expect(sim.wakeCount, 0);
    });
  });

  group('pairing through engine.pair', () {
    test('PIN pairing stores a pinned token in a 0600 file', () async {
      final id = (await addFireTv()).id;
      sim.clearLog();
      final steps = await pair(id);

      expect(steps.first, isA<EnterCode>());
      expect(steps.last, const Paired.redacted());
      expect(sim.pinDisplayNames, ['watchme']);
      // The DIAL wake preceded the first API request.
      expect(sim.requests.first.server, FireTvSimServer.dial);
      expect(sim.requests.first.method, 'POST');
      expect(sim.requests[1].path, '/v1/FireTV/pin/display');

      final stored = await system.credentials.read(id, fireTvDriverId);
      expect(stored, isA<TokenCredential>());
      final token = stored! as TokenCredential;
      expect(sim.validTokens, {token.token});
      expect(token.peerCertSha256, sim.certificateSha256);

      final file = File(E2eSystem.credentialsPath(dir));
      expect(file.statSync().mode & 0x1ff, 0x180, reason: 'mode 0600');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      expect(jsonEncode(json), contains(token.token));

      final view = system.engine.currentDevices.single;
      expect(view.needsPairing, isFalse);
      expect(view.drivers.single.paired, isTrue);
      expect(view.drivers.single.connection, ConnectionState.connected);
      // Nothing the client sees carries the token.
      expect(jsonEncode(view.toJson()), isNot(contains(token.token)));
    });

    test('a wrong PIN can be corrected', () async {
      final id = (await addFireTv()).id;
      final flow = system.engine.pair(id, fireTvDriverId);
      var attempts = 0;
      final steps = await runPairing(
        flow.steps,
        flow.submit,
        () => attempts++ == 0
            ? (sim.displayedPin == '0000' ? '1111' : '0000')
            : sim.displayedPin!,
      );
      final codes = steps.whereType<EnterCode>().toList();
      expect(codes, hasLength(2));
      expect(codes.last.label, contains('Wrong PIN'));
      expect(steps.last, const Paired.redacted());
    });

    test('three wrong PINs fail with the device text', () async {
      final id = (await addFireTv()).id;
      final flow = system.engine.pair(id, fireTvDriverId);
      final steps = await runPairing(
        flow.steps,
        flow.submit,
        () => sim.displayedPin == '0000' ? '1111' : '0000',
      );
      expect(steps.last, isPairingFailedWith(WatchmeErrorCode.unauthorized));
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
    });
  });

  group('commands after pairing', () {
    late String id;

    setUp(() async {
      id = await addAndPair();
      sim.clearLog();
    });

    test('keys, text, apps and media reach the simulator', () async {
      final engine = system.engine;
      expect(await engine.send(id, const PressKey(RemoteKey.up)), isConfirmed);
      expect(
        await engine.send(id, const PressKey(RemoteKey.select)),
        isConfirmed,
      );
      expect(
        await engine.send(id, const PressKey(RemoteKey.volumeUp)),
        isDelivered,
      );
      sim.keyboardOpen = true;
      expect(await engine.send(id, const TypeText('hello')), isDelivered);
      expect(sim.typedText, 'hello');

      final apps = await engine.send(id, const ListApps());
      final list = ((apps as Confirmed).payload! as AppListPayload).apps;
      expect(list, isNotEmpty);
      expect(await engine.send(id, LaunchApp(list.first.id)), isDelivered);
      expect(sim.foregroundApp, list.first.id);

      expect(
        await engine.send(id, const Media(MediaAction.playPause)),
        isDelivered,
      );
      expect(
        await engine.send(id, const Media(MediaAction.fastForward)),
        isDelivered,
      );
      expect(
        await engine.send(id, const Media(MediaAction.play)),
        isUnsupported(),
        reason: 'the API has only a play/pause toggle',
      );
      expect(sim.effects, [
        'dpad_up',
        'select',
        'volume_up',
        'text:hello',
        'launch:${list.first.id}',
        'media:play',
        'scan:forward',
      ]);
    });

    test('key and launch POSTs carry no body', () async {
      await system.engine.send(id, const PressKey(RemoteKey.home));
      await system.engine.send(id, const PressKey(RemoteKey.back));
      await system.engine.send(id, const LaunchApp('com.netflix.ninja'));
      await system.engine.send(id, const Media(MediaAction.playPause));
      final posts = [
        ...apiPosts('/v1/FireTV'),
        ...sim.apiRequests.where(
          (r) => r.path.startsWith('/v1/FireTV/app/') || r.path == '/v1/media',
        ),
      ];
      expect(posts, hasLength(4));
      for (final r in posts) {
        expect(r.body, isEmpty, reason: '$r');
      }
    });

    test('a hold sends keyDown then keyUp bodies', () async {
      await system.engine.send(
        id,
        const PressKey(RemoteKey.right, KeyAction.down),
      );
      expect(sim.heldAction, 'dpad_right');
      await system.engine.send(
        id,
        const PressKey(RemoteKey.right, KeyAction.up),
      );
      expect(sim.heldAction, isNull);
      expect(sim.effects, ['dpad_right:keyDown', 'dpad_right:keyUp']);
    });

    test('power off sleeps the stick and power on wakes it via DIAL', () async {
      expect(await system.engine.send(id, const SetPower(false)), isDelivered);
      await eventually(() => !sim.awake, reason: 'the API to close');
      final wakesBefore = sim.wakeCount;
      expect(await system.engine.send(id, const SetPower(true)), isDelivered);
      expect(sim.awake, isTrue);
      expect(sim.wakeCount, wakesBefore + 1);
    });

    test('a stick that sleeps under an open session is woken by the next '
        'key', () async {
      final engine = system.engine;
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      final wakes = sim.wakeCount;
      // Its own inactivity timer closes the API port.
      await sim.sleep();
      expect(
        await engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.wakeCount, wakes + 1);
      expect(sim.effects.where((e) => e == 'home'), hasLength(2));
      expect(
        engine.currentDevices.single.drivers.single.connection,
        ConnectionState.connected,
      );
    });
  });

  group('restarts and trust', () {
    test('a restarted engine reuses the credential, waking first', () async {
      final id = await addAndPair();
      final token = sim.validTokens.single;
      await system.close();
      await sim.sleep();
      sim.clearLog();

      final restarted = await E2eSystem.start(dir);
      expect(
        restarted.engine.currentDevices.single.drivers.single.paired,
        true,
      );
      expect(
        await restarted.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(sim.pinDisplayNames, hasLength(1), reason: 'no second pairing');
      expect(sim.validTokens, {token});

      final first = sim.requests.first;
      expect(first.server, FireTvSimServer.dial);
      expect(first.method, 'POST');
      expect(first.path, '/apps/FireTVRemote');
      final api = sim.apiRequests.toList();
      expect(api.first.path, '/v1/FireTV/status');
      expect(api.first.header('x-client-token'), token);
      expect(api.last.action, 'home');
    });

    test(
      'power off of a sleeping stick with no session does not wake it',
      () async {
        final id = await addAndPair();
        await system.close();
        await sim.sleep();
        final wakes = sim.wakeCount;

        final restarted = await E2eSystem.start(dir);
        expect(
          await restarted.engine.send(id, const SetPower(false)),
          isConfirmed,
        );
        expect(sim.wakeCount, wakes, reason: 'waking it would wake the TV');
        expect(sim.awake, isFalse);
        expect(
          restarted.engine.currentDevices.single.state.power?.value,
          PowerMode.standby,
        );
      },
    );

    test('a changed certificate fails the pinned connection', () async {
      final id = await addAndPair();
      await system.close();
      await sim.restartWithCertificate(FireTvSimulatorCertificate.alternate);
      sim.clearLog();

      final restarted = await E2eSystem.start(dir);
      final result = await restarted.engine.send(
        id,
        const PressKey(RemoteKey.home),
      );
      expect(
        result,
        isFailedWith(
          WatchmeErrorCode.protocol,
          message: contains('does not match the pin'),
        ),
      );
      // The TLS check fails before any request: the token never reached
      // the impostor.
      expect(sim.apiRequests, isEmpty);
      final driver = restarted.engine.currentDevices.single.drivers.single;
      expect(driver.lastError?.code, WatchmeErrorCode.protocol);
      expect(driver.connection, ConnectionState.failed);
    });

    test('a revoked token surfaces ReauthRequired', () async {
      final id = await addAndPair();
      final events = record(system.engine.events(id));
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      sim.revokeTokens();

      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isFailedWith(
          WatchmeErrorCode.reauthRequired,
          rawDeviceMessage: contains('authn error'),
        ),
      );
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);

      // The revoked credential is not used again until the user re-pairs.
      sim.clearLog();
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      expect(sim.apiRequests, isEmpty);

      expect((await pair(id)).last, const Paired.redacted());
      expect(
        await system.engine.send(id, const PressKey(RemoteKey.home)),
        isConfirmed,
      );
      expect(system.engine.currentDevices.single.needsPairing, isFalse);
    });

    test('forget deletes the credential and the record', () async {
      final id = await addAndPair();
      await system.engine.forget(id);
      expect(await system.credentials.readAll(id), isEmpty);
      expect(await system.devices.get(id), isNull);
      expect(system.engine.currentDevices, isEmpty);
    });
  });
}
