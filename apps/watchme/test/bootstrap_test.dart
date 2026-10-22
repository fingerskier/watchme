// Plain `test`s only: `testWidgets` installs HTTP overrides that would stop
// the real network stack from reaching the loopback simulator.
@TestOn('vm')
library;

import 'dart:io' hide Datagram;

import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/bootstrap.dart';
import 'package:watchme/src/destination_policy.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:watchme_testkit/sharp_simulator.dart';

/// Port 1 on loopback, where nothing listens: every driver a test does not
/// exercise probes it instead of its standard port on this machine.
const Map<String, int> _refused = {
  'ecp': 1,
  'dial': 1,
  'api': 1,
  'legacy': 1,
  'nrc': 1,
  'ipc': 1,
};

void main() {
  late Directory state;

  setUp(() async {
    state = await Directory.systemTemp.createTemp('watchme_app_');
    addTearDown(() => state.delete(recursive: true));
  });

  test('the demo is off unless WATCHME_DEMO is defined', () {
    expect(demoRequested, isFalse);
  });

  test('the engine client controls a Roku and persists it', () async {
    final roku = RokuSimulator();
    await roku.start();
    addTearDown(roku.stop);

    final client = await createEngineClient(stateDirectory: state.path);
    final lists = <List<DeviceView>>[];
    final subscription = client.watchDevices().listen(lists.add);
    final view = await client.addManual(
      '127.0.0.1',
      ports: {..._refused, 'ecp': roku.port},
    );
    expect(view.name, 'Simulated Roku TV');
    expect(
      await client.send(view.id, const PressKey(RemoteKey.home)),
      isA<Confirmed>(),
    );
    expect(roku.keyLog.single.key, 'Home');
    await subscription.cancel();
    await client.close();

    final devices = File('${state.path}/devices.json');
    expect(devices.existsSync(), isTrue);
    if (Platform.isLinux || Platform.isMacOS) {
      expect(devices.statSync().mode & 0x1ff, 0x180, reason: 'mode 0600');
    }

    final reopened = await createEngineClient(stateDirectory: state.path);
    addTearDown(reopened.close);
    final first = await reopened.watchDevices().first;
    expect(first.map((d) => d.id), [view.id]);
  });

  test('the app registers every driver', () {
    expect(
      [for (final d in appDrivers()) d.descriptor.id],
      [
        'roku.ecp',
        'firetv.lightning',
        'vizio.smartcast',
        'panasonic.viera',
        'sharp.aquos',
      ],
    );
  });

  test('the engine client finds a Sharp AQUOS, which offers pairing though '
      'it needs none', () async {
    final sharp = SharpSimulator();
    await sharp.start();
    addTearDown(sharp.stop);
    final client = await createEngineClient(stateDirectory: state.path);
    addTearDown(client.close);
    final view = await client.addManual(
      '127.0.0.1',
      ports: {..._refused, 'ipc': sharp.port},
    );
    final driver = view.drivers.single;
    expect(driver.driverId, 'sharp.aquos');
    expect(driver.needsPairing, isFalse);
    expect(driver.canPair, isTrue);
    expect(
      await client.send(view.id, const PressKey(RemoteKey.up)),
      isA<Confirmed>(),
    );
    expect(sharp.lines.last, 'RCKY41  ');
  });

  test('the app allows loopback but nothing else off the LAN', () {
    // The simulators on 127.0.0.1 need loopback (the test above); the
    // non-private escape hatch stays shut.
    expect(appDestinationPolicy.allowLoopback, isTrue);
    expect(appDestinationPolicy.allowNonPrivate, isFalse);
  });

  test('the engine client refuses an address off the LAN up front', () async {
    final client = await createEngineClient(stateDirectory: state.path);
    addTearDown(client.close);

    // Documentation and benchmarking ranges: nothing real answers there,
    // even if a refusal were missing.
    for (final host in ['203.0.113.5', '198.18.0.1', '2001:db8::5']) {
      await expectLater(
        client.addManual(host),
        throwsA(
          isA<WatchmeError>()
              .having(
                (e) => e.code,
                'code',
                WatchmeErrorCode.destinationRefused,
              )
              .having((e) => e.message, 'message', contains(host)),
        ),
        reason: host,
      );
    }
    expect(await client.watchDevices().first, isEmpty);
  });
}
