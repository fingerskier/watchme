@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/io_http_stack.dart';

const _context = PairingContext(deviceId: 'sim-1', clientName: 'watchme e2e');

/// Pairs with [sim], answering each PIN prompt from [pins] (or the PIN the
/// simulator shows when [pins] is empty), and returns every step.
Future<List<PairingStep>> _pair(
  FireTvDriver driver,
  FireTvSimulator sim,
  Transports transports, {
  List<String> pins = const [],
}) async {
  final queue = [...pins];
  final flow = driver.startPairing(sim.endpoint, transports, _context)!;
  final steps = <PairingStep>[];
  await for (final step in flow.steps) {
    steps.add(step);
    if (step is EnterCode) {
      flow.submit(queue.isEmpty ? sim.displayedPin! : queue.removeAt(0));
    }
  }
  return steps;
}

void main() {
  late FireTvSimulator sim;
  final transports = IoHttpTransports();
  final driver = FireTvDriver(
    apiStartupTimeout: const Duration(seconds: 2),
    apiPollInterval: const Duration(milliseconds: 50),
  );

  setUp(() async {
    sim = await FireTvSimulator.start(seed: 42);
  });

  tearDown(() => sim.close());

  Future<TokenCredential> pair() async {
    final steps = await _pair(driver, sim, transports);
    return (steps.last as Paired).credential! as TokenCredential;
  }

  test('probe is passive against a sleeping device', () async {
    // Added by address: the closed API port says nothing, but the DIAL
    // status of FireTVRemote (a passive GET) identifies the device.
    final unadvertised = await driver.probe(sim.endpoint, transports);
    expect(unadvertised.matched, isTrue);
    expect(unadvertised.notes.single, contains('asleep'));

    final advertised = await driver.probe(
      sim.endpoint.withAttributes({
        DiscoveryAttr.manufacturer: 'Amazon',
        DiscoveryAttr.modelName: 'AFTMA08C15',
      }),
      transports,
    );
    expect(advertised.matched, isTrue);
    expect(advertised.power?.value, PowerMode.standby);
    expect(sim.wakeCount, 0);
    expect(sim.awake, isFalse);
    // The advertised device is asked too: an advertisement only names it.
    expect(sim.requests.map((r) => '${r.server.name} ${r.method} ${r.path}'), [
      'dial GET /apps/FireTVRemote',
      'dial GET /apps/FireTVRemote',
    ]);
  });

  test('an advertised device that answers nothing does not match', () async {
    final dialPort = sim.dialPort;
    final apiPort = sim.apiPort;
    await sim.close();
    final result = await driver.probe(
      Endpoint(
        '127.0.0.1',
        ports: {'dial': dialPort, 'api': apiPort},
      ).withAttributes({
        DiscoveryAttr.manufacturer: 'Amazon',
        DiscoveryAttr.modelName: 'AFTKA',
      }),
      transports,
    );
    expect(result.matched, isFalse);
    expect(result.error?.code, WatchmeErrorCode.unreachable);
  });

  test('probe of an awake device reads status without a token', () async {
    await sim.wake();
    final result = await driver.probe(sim.endpoint, transports);
    expect(result.matched, isTrue);
    final request = sim.requests.single;
    expect('${request.method} ${request.path}', 'GET /v1/FireTV/status');
    expect(request.header('x-client-token'), isNull);
  });

  test('pairs over real HTTPS and records the certificate', () async {
    final steps = await _pair(driver, sim, transports);
    expect(steps.map((s) => s.runtimeType), [EnterCode, Paired]);
    final credential = (steps.last as Paired).credential! as TokenCredential;
    expect(credential.peerCertSha256, sim.certificateSha256);
    expect(sim.validTokens, {credential.token});
    expect(sim.pinDisplayNames, ['watchme e2e']);
    expect(sim.dialRequests.single.header('content-type'), 'text/plain');
    expect(sim.dialRequests.single.body, isEmpty);
  });

  test('malformed codes are re-asked; three wrong PINs fail', () async {
    final steps = await _pair(driver, sim, transports, pins: ['abcd', '----']);
    // Two malformed codes are re-asked locally; the third prompt gets the
    // simulator's PIN.
    expect(steps.whereType<EnterCode>(), hasLength(3));
    expect(steps.last, isA<Paired>());

    final wrong = await _pair(
      driver,
      sim,
      transports,
      pins: ['9999', '9998', '9997'],
    );
    expect(
      wrong.last,
      isPairingFailedWith(
        WatchmeErrorCode.unauthorized,
        rawDeviceMessage: '{"description":""}',
      ),
    );
  });

  test('drives keys, holds, text, apps and media', () async {
    final credential = await pair();
    await sim.sleep();
    final session = await driver.connect(sim.endpoint, transports, credential);
    expect(sim.awake, isTrue, reason: 'connect woke it through DIAL');
    sim
      ..clearLog()
      ..keyboardOpen = true;

    for (final command in <Command>[
      const PressKey(RemoteKey.up),
      const PressKey(RemoteKey.select),
      const PressKey(RemoteKey.right, KeyAction.down),
      const PressKey(RemoteKey.right, KeyAction.up),
      const PressKey(RemoteKey.back),
      const PressKey(RemoteKey.menu),
      const PressKey(RemoteKey.power),
      const StepVolume(2),
      const SetMute(null),
      const TypeText('hello'),
      const Media(MediaAction.playPause),
      const Media(MediaAction.fastForward),
      const Media(MediaAction.rewind),
      const LaunchApp('com.netflix.ninja'),
      const PressKey(RemoteKey.home),
    ]) {
      expect(await session.execute(command), isConfirmed, reason: '$command');
    }
    expect(sim.effects, [
      'dpad_up',
      'select',
      'dpad_right:keyDown',
      'dpad_right:keyUp',
      'back',
      'menu',
      'power',
      'volume_up',
      'volume_up',
      'mute',
      'text:hello',
      'media:play',
      'scan:forward',
      'scan:back',
      'launch:com.netflix.ninja',
      'home',
    ]);
    expect(sim.typedText, 'hello');
    expect(sim.volumeSteps, 2);

    final apps = await session.execute(const ListApps());
    final payload = (apps as Confirmed).payload! as AppListPayload;
    expect(payload.apps.map((a) => a.id), [
      'com.netflix.ninja',
      'com.amazon.firebat',
    ]);

    for (final r in sim.apiRequests) {
      expect(r.header('x-api-key'), '0987654321');
      expect(r.header('x-client-token'), credential.token);
    }
    // Only the two hold edges carry a body; every other key, media toggle
    // and app launch POST has none.
    final keyPosts = sim.apiRequests.where(
      (r) =>
          r.method == 'POST' &&
          (r.path == '/v1/FireTV' ||
              r.path.startsWith('/v1/FireTV/app/') ||
              r.action == 'play'),
    );
    expect(keyPosts, hasLength(13));
    expect(sim.displayPowered, isFalse, reason: 'the power key toggled it');
    expect(
      [
        for (final r in keyPosts)
          if (r.body.isNotEmpty) r.body,
      ],
      ['{"keyActionType":"keyDown"}', '{"keyActionType":"keyUp"}'],
    );
    await session.close();
  });

  test('sleep closes the API; SetPower(true) wakes it again', () async {
    final session = await driver.connect(
      sim.endpoint,
      transports,
      await pair(),
    );
    expect(await session.execute(const SetPower(false)), isConfirmed);
    await _until(() => !sim.awake);
    // Turning off what is already asleep does not wake it.
    final wakes = sim.wakeCount;
    expect(await session.execute(const SetPower(false)), isConfirmed);
    expect(sim.wakeCount, wakes);
    expect(sim.awake, isFalse);
    expect(await session.execute(const SetPower(true)), isConfirmed);
    expect(sim.awake, isTrue);
    expect(await session.execute(const PressKey(RemoteKey.home)), isConfirmed);
  });

  test('a device that sleeps under an open session is woken by the next '
      'key', () async {
    final session = await driver.connect(
      sim.endpoint,
      transports,
      await pair(),
    );
    final events = <DeviceEvent>[];
    session.events.listen(events.add);
    expect(await session.execute(const PressKey(RemoteKey.home)), isConfirmed);
    final wakes = sim.wakeCount;
    // Its own inactivity timer: the API port closes.
    await sim.sleep();
    expect((await session.refresh()).power?.value, PowerMode.standby);
    expect(sim.wakeCount, wakes, reason: 'refresh is passive');
    expect(await session.execute(const PressKey(RemoteKey.home)), isConfirmed);
    expect(sim.wakeCount, wakes + 1);
    expect(sim.awake, isTrue);
    expect(sim.effects.where((e) => e == 'home'), hasLength(2));
    expect(await session.execute(const PressKey(RemoteKey.home)), isConfirmed);
    expect(sim.wakeCount, wakes + 1);
    await session.close();
  });

  test('a revoked token emits ReauthRequired', () async {
    final session = await driver.connect(
      sim.endpoint,
      transports,
      await pair(),
    );
    final reauth = session.events.firstWhere((e) => e is ReauthRequired);
    sim.revokeTokens();
    expect(
      await session.execute(const PressKey(RemoteKey.home)),
      isFailedWith(
        WatchmeErrorCode.reauthRequired,
        rawDeviceMessage: '{"description":"authn error"}',
      ),
    );
    expect(await reauth, isA<ReauthRequired>());
  });

  test('a changed certificate fails the pin until paired again', () async {
    final credential = await pair();
    await sim.restartWithCertificate(FireTvSimulatorCertificate.alternate);
    await expectLater(
      driver.connect(sim.endpoint, transports, credential),
      throwsWatchmeError(WatchmeErrorCode.protocol),
    );
    final again = await pair();
    expect(
      again.peerCertSha256,
      FireTvSimulatorCertificate.alternate.sha256Fingerprint,
    );
    await driver.connect(sim.endpoint, transports, again);
  });
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue);
}
