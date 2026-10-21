@TestOn('vm')
library;

import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

/// The flows the app drives, through [InProcessClient] as the app uses it.
void main() {
  late RokuSimulator roku;
  late FireTvSimulator fireTv;
  late E2eSystem system;
  late InProcessClient client;
  late List<List<DeviceView>> lists;
  late Map<String, int> rokuPorts;
  late Map<String, int> fireTvPorts;

  setUp(() async {
    roku = RokuSimulator();
    await roku.start(ssdp: true);
    addTearDown(roku.stop);
    // A second loopback address, so the two devices do not share a host
    // (the engine would rightly treat one address as one device).
    fireTv = await FireTvSimulator.start(host: '127.0.0.2');
    addTearDown(fireTv.close);
    system = await E2eSystem.start(
      await tempStateDir(),
      discovery: (network) => [
        SsdpDiscovery(
          network,
          group: '127.0.0.1',
          port: roku.ssdpPort!,
          // The simulator answers from loopback, which LAN-only refuses.
          destinationPolicy: e2ePolicy,
          mx: 1,
          attempts: 1,
        ),
      ],
    );
    client = InProcessClient(system.engine);
    lists = record(client.watchDevices());
    final closed = await closedPort();
    rokuPorts = {rokuEcpPortName: roku.port, 'dial': closed, 'api': closed};
    fireTvPorts = {
      FireTvPorts.dial: fireTv.dialPort,
      FireTvPorts.api: fireTv.apiPort,
      rokuEcpPortName: closed,
    };
  });

  Future<List<PairingStep>> pairFireTv(String deviceId) async {
    final handle = await client.pair(deviceId, fireTvDriverId);
    expect(handle.deviceId, deviceId);
    expect(handle.driverId, fireTvDriverId);
    return runPairing(handle.steps, handle.submit, () => fireTv.displayedPin!);
  }

  test('scan, add, pair and control two TVs like the app does', () async {
    await client.scan(window: const Duration(milliseconds: 800));
    // Lists are delivered asynchronously, coalesced per microtask.
    await eventually(() => lists.last.isNotEmpty, reason: 'the scan result');
    final rokuView = lists.last.single;
    expect(rokuView.name, 'Simulated Roku TV');

    final added = await client.addManual('127.0.0.2', ports: fireTvPorts);
    expect(added.needsPairing, isTrue);
    await eventually(() => lists.last.length == 2, reason: 'two devices');

    expect(
      await client.send(rokuView.id, const PressKey(RemoteKey.home)),
      isConfirmed,
    );
    expect(roku.keyLog.single.key, 'Home');

    final steps = await pairFireTv(added.id);
    expect(steps.last, const Paired.redacted());
    expect(
      await client.send(added.id, const PressKey(RemoteKey.select)),
      isConfirmed,
    );
    expect(fireTv.effects.last, 'select');

    await eventually(
      () => lists.last.any((d) => d.id == added.id && !d.needsPairing),
      reason: 'the Fire TV to show as paired',
    );
    final token = fireTv.validTokens.single;
    final everything = jsonEncode({
      'lists': [
        for (final list in lists) [for (final d in list) d.toJson()],
      ],
      'steps': [for (final s in steps) s.toJson(includeSecrets: true)],
    });
    expect(everything, isNot(contains(token)));
  });

  test('a cancelled pairing leaves the device unpaired', () async {
    final added = await client.addManual('127.0.0.2', ports: fireTvPorts);
    final handle = await client.pair(added.id, fireTvDriverId);
    final steps = <PairingStep>[];
    await for (final step in handle.steps) {
      steps.add(step);
      if (step is EnterCode) await handle.cancel();
    }
    expect(steps.last, isPairingFailedWith(WatchmeErrorCode.cancelled));
    expect(fireTv.validTokens, isEmpty);
    expect(
      await client.send(added.id, const PressKey(RemoteKey.home)),
      isFailedWith(WatchmeErrorCode.unauthorized),
    );
  });

  test('pairing a driver that needs none fails as unsupported', () async {
    final added = await client.addManual('127.0.0.1', ports: rokuPorts);
    final handle = await client.pair(added.id, rokuDriverId);
    expect(
      await handle.steps.last,
      isPairingFailedWith(WatchmeErrorCode.unsupported),
    );
  });

  test('forget and refresh through the client', () async {
    final added = await client.addManual('127.0.0.1', ports: rokuPorts);
    await client.refresh(added.id);
    await client.forget(added.id);
    await eventually(() => lists.last.isEmpty, reason: 'the device to go');
    expect(
      await client.send(added.id, const PressKey(RemoteKey.home)),
      isFailedWith(WatchmeErrorCode.internal),
    );
  });

  test('closing a client that owns the engine closes it', () async {
    final owning = InProcessClient(system.engine, ownsEngine: true);
    await owning.close();
    expect(system.engine.isClosed, isTrue);
    expect(
      await owning.send('any', const PressKey(RemoteKey.home)),
      isFailedWith(WatchmeErrorCode.cancelled),
    );
  });
}
