import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/pairing/pairing_screen.dart';
import 'package:watchme/src/remote/remote_screen.dart';
import 'package:watchme_core/watchme_core.dart';

import 'support/fake_client.dart';

void main() {
  testWidgets('lists each device with make, model, drivers and status', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [rokuDevice(), fireTvDevice()]);
    await pumpApp(tester, client);

    expect(find.text('Living Room Roku'), findsOneWidget);
    expect(find.text('TCL 55S455 · 192.0.2.10'), findsOneWidget);
    expect(find.text('Roku ECP'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);

    expect(find.text('Bedroom Fire TV'), findsOneWidget);
    expect(find.text('Amazon AFTKA · 192.0.2.20'), findsOneWidget);
    expect(find.text('Fire TV remote API'), findsOneWidget);
    expect(find.text('Needs pairing'), findsOneWidget);
    expect(find.byTooltip('Fire TV remote API: needs pairing'), findsOneWidget);
    expect(find.byTooltip('Roku ECP: connected'), findsOneWidget);
    // Only the Fire TV needs pairing.
    expect(find.widgetWithText(FilledButton, 'Pair'), findsOneWidget);
  });

  testWidgets('a paired driver shows as paired', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice(paired: true)]);
    await pumpApp(tester, client);

    expect(find.text('Connected'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pair'), findsNothing);
    expect(find.byTooltip('Fire TV remote API: connected'), findsOneWidget);
  });

  testWidgets('Scan calls client.scan and shows progress until done', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()])
      ..scanGate = Completer<void>();
    await pumpApp(tester, client);

    await tester.tap(find.text('Scan'));
    await tester.pump();

    expect(client.scanCalls, 1);
    expect(find.text('Scanning…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // A second tap while scanning does nothing.
    await tester.tap(find.text('Scanning…'));
    await tester.pump();
    expect(client.scanCalls, 1);

    client.scanGate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Scan'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a failed scan shows the error', (tester) async {
    final client = FakeWatchmeClient()
      ..scanError = const WatchmeError.unsupported('No network available');
    await pumpApp(tester, client);

    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();

    expect(find.text('No network available'), findsOneWidget);
  });

  testWidgets('scanOnStart scans once the screen appears', (tester) async {
    final client = FakeWatchmeClient();
    await pumpApp(tester, client, scanOnStart: true);

    expect(client.scanCalls, 1);
  });

  testWidgets('empty state explains discovery and the Roku setting', (
    tester,
  ) async {
    final client = FakeWatchmeClient();
    await pumpApp(tester, client, size: const Size(400, 1400));

    expect(find.text('No TVs yet'), findsOneWidget);
    expect(find.textContaining('SSDP and mDNS'), findsOneWidget);
    expect(find.textContaining('Control by mobile apps'), findsOneWidget);

    await tester.tap(find.text('Scan for TVs'));
    await tester.pumpAndSettle();
    expect(client.scanCalls, 1);
  });

  testWidgets('the list follows the client', (tester) async {
    final client = FakeWatchmeClient();
    await pumpApp(tester, client);
    expect(find.text('No TVs yet'), findsOneWidget);

    client.setDevices([rokuDevice()]);
    await tester.pumpAndSettle();

    expect(find.text('No TVs yet'), findsNothing);
    expect(find.text('Living Room Roku'), findsOneWidget);
  });

  testWidgets('a driver error shows the raw device message', (tester) async {
    final device = rokuDevice(connection: ConnectionState.failed);
    final client = FakeWatchmeClient(
      devices: [
        device.copyWith(
          drivers: [
            const DriverView(
              driverId: 'roku.ecp',
              protocol: 'Roku ECP',
              connection: ConnectionState.failed,
              lastError: WatchmeError.rejected(
                'The TV refused key presses.',
                rawDeviceMessage: 'ECP command not allowed in Limited mode.',
              ),
              setup: [
                SetupStep(
                  id: 'roku.controlByMobileApps',
                  title: 'Control by mobile apps = Enabled',
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await pumpApp(tester, client);

    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Roku ECP: The TV refused key presses.'), findsOneWidget);
    expect(
      find.text('ECP command not allowed in Limited mode.'),
      findsOneWidget,
    );
    expect(find.text('Control by mobile apps = Enabled'), findsOneWidget);
  });

  testWidgets('tapping a device opens its remote', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()]);
    await pumpApp(tester, client);

    await tester.tap(find.text('Living Room Roku'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteScreen), findsOneWidget);
  });

  testWidgets('Pair opens pairing for the driver that needs it', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    await pumpApp(tester, client);

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    // The pairing screen spins until the first step, so it never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(client.pairings.single.deviceId, 'firetv-1');
    expect(client.pairings.single.driverId, 'firetv.lightning');
  });

  testWidgets('Forget asks first, then forgets', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()]);
    await pumpApp(tester, client);

    await tester.tap(find.byTooltip('More actions for Living Room Roku'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text('Forget Living Room Roku?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(client.forgotten, ['roku-1']);
    expect(find.text('Living Room Roku'), findsNothing);
    expect(find.text('Forgot Living Room Roku'), findsOneWidget);
  });

  testWidgets('Refresh status calls client.refresh', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()]);
    await pumpApp(tester, client);

    await tester.tap(find.byTooltip('More actions for Living Room Roku'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh status'));
    await tester.pumpAndSettle();

    expect(client.refreshed, ['roku-1']);
  });

  testWidgets('works at phone width without overflow', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice(), fireTvDevice()]);
    await pumpApp(tester, client, size: const Size(360, 740));

    expect(tester.takeException(), isNull);
    expect(find.text('Bedroom Fire TV'), findsOneWidget);
  });

  testWidgets('dark theme renders', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()]);
    useWindowSize(tester, const Size(800, 800));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await pumpApp(tester, client, size: const Size(800, 800));

    final context = tester.element(find.text('Living Room Roku'));
    expect(Theme.of(context).brightness, Brightness.dark);
  });
}
