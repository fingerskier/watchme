// Plain `test`s only: `testWidgets` installs HTTP overrides that would stop
// the real network stack from reaching the loopback simulator.
@TestOn('vm')
library;

import 'dart:io' hide Datagram;

import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/bootstrap.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/roku_simulator.dart';

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
      ports: {'ecp': roku.port, 'dial': 1, 'api': 1},
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
}
