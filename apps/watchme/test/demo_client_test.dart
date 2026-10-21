import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/app.dart';
import 'package:watchme/src/demo/demo_client.dart';
import 'package:watchme/src/remote/remote_screen.dart';
import 'package:watchme_core/watchme_core.dart';

import 'support/fake_client.dart';

DemoWatchmeClient _demo() =>
    DemoWatchmeClient(latency: Duration.zero, scanTime: Duration.zero);

Future<List<PairingStep>> _pairWith(
  DemoWatchmeClient client,
  String deviceId,
  String driverId, {
  String? pin,
}) async {
  final handle = await client.pair(deviceId, driverId);
  final steps = <PairingStep>[];
  await for (final step in handle.steps) {
    steps.add(step);
    if (step is EnterCode && pin != null) await handle.submit(pin);
  }
  return steps;
}

void main() {
  group('DemoWatchmeClient', () {
    test('starts empty and finds both TVs on a scan', () async {
      final client = _demo();
      expect(await client.watchDevices().first, isEmpty);

      await client.scan();
      final devices = await client.watchDevices().first;

      expect(devices.map((d) => d.id), ['demo-roku', 'demo-firetv']);
      final roku = devices.first;
      expect(roku.host, demoRokuHost);
      expect(roku.connected, isTrue);
      expect(roku.needsPairing, isFalse);
      expect(roku.supportOf(Capability.channel).usable, isTrue);
      final fire = devices.last;
      expect(fire.host, demoFireTvHost);
      expect(fire.needsPairing, isTrue);
      expect(fire.supportOf(Capability.channel).level, Support.no);
      await client.close();
    });

    test('adds a TV by address, rejects unknown addresses', () async {
      final client = _demo();

      final roku = await client.addManual(demoRokuHost);
      expect(roku.id, 'demo-roku');
      expect((await client.watchDevices().first).single.id, 'demo-roku');

      await expectLater(
        client.addManual('192.0.2.99'),
        throwsA(
          isA<WatchmeError>().having(
            (e) => e.code,
            'code',
            WatchmeErrorCode.unreachable,
          ),
        ),
      );
    });

    test('Roku needs no pairing', () async {
      final client = _demo();
      await client.scan();

      final steps = await _pairWith(client, 'demo-roku', 'roku.ecp');

      expect(steps.single, isA<PairingFailed>());
      expect(
        (steps.single as PairingFailed).error.code,
        WatchmeErrorCode.unsupported,
      );
    });

    test('Fire TV refuses commands until paired with the PIN', () async {
      final client = _demo();
      await client.scan();

      final before = await client.send(
        'demo-firetv',
        const PressKey(RemoteKey.up),
      );
      expect(before, isA<Failed>());
      expect((before as Failed).error.code, WatchmeErrorCode.unauthorized);

      final steps = await _pairWith(
        client,
        'demo-firetv',
        'firetv.lightning',
        pin: demoFireTvPin,
      );
      expect(steps[0], isA<Instruct>());
      expect(
        steps[1],
        const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
      );
      // The credential never reaches the client.
      expect(steps[2], const Paired.redacted());

      final fire = (await client.watchDevices().first).last;
      expect(fire.needsPairing, isFalse);
      expect(fire.connected, isTrue);
      expect(
        await client.send('demo-firetv', const PressKey(RemoteKey.up)),
        const Confirmed(),
      );
    });

    test('a wrong PIN fails with the device text', () async {
      final client = _demo();
      await client.scan();

      final steps = await _pairWith(
        client,
        'demo-firetv',
        'firetv.lightning',
        pin: '0000',
      );

      final failed = steps.last as PairingFailed;
      expect(failed.error.code, WatchmeErrorCode.unauthorized);
      expect(failed.rawDeviceMessage, isNotEmpty);
      expect((await client.watchDevices().first).last.needsPairing, isTrue);
    });

    test('cancelling a pairing ends it as cancelled', () async {
      final client = _demo();
      await client.scan();
      final handle = await client.pair('demo-firetv', 'firetv.lightning');
      final steps = handle.steps.toList();

      await handle.cancel();

      final last = (await steps).last as PairingFailed;
      expect(last.error.code, WatchmeErrorCode.cancelled);
    });

    test('simulates Roku apps, launches and quirks', () async {
      final client = _demo();
      await client.scan();

      final list = await client.send('demo-roku', const ListApps());
      final apps = ((list as Confirmed).payload! as AppListPayload).apps;
      expect(apps.map((a) => a.name), contains('Netflix'));
      expect(apps.where((a) => a.kind == AppKind.input), isNotEmpty);

      expect(
        await client.send('demo-roku', const LaunchApp('12')),
        const Confirmed(),
      );
      final roku = (await client.watchDevices().first).first;
      expect(roku.state.foregroundApp?.value.name, 'Netflix');

      expect(
        await client.send('demo-roku', const LaunchApp('nope')),
        isA<Failed>(),
      );
      expect(
        await client.send('demo-roku', const TypeText('hi')),
        const SentUnconfirmed(),
      );
      expect(
        await client.send('demo-roku', const SetVolume(10)),
        isA<Unsupported>(),
      );
      expect(
        await client.send('demo-roku', const PressKey(RemoteKey.red)),
        isA<Unsupported>(),
      );
      expect(
        await client.send('demo-roku', const TakeScreenshot()),
        isA<Unsupported>(),
      );
    });

    test('power and mute change the reported state', () async {
      final client = _demo();
      await client.scan();

      await client.send('demo-roku', const SetPower(false));
      await client.send('demo-roku', const PressKey(RemoteKey.mute));

      final roku = (await client.watchDevices().first).first;
      expect(roku.state.power?.value, PowerMode.standby);
      expect(roku.state.power?.confidence, Confidence.reported);
      expect(roku.state.muted?.value, isTrue);
      expect(roku.state.muted?.confidence, Confidence.inferred);
    });

    test(
      'Fire TV rewind fails with raw text; channels are unsupported',
      () async {
        final client = _demo();
        await client.scan();
        await _pairWith(
          client,
          'demo-firetv',
          'firetv.lightning',
          pin: demoFireTvPin,
        );

        final rewind = await client.send(
          'demo-firetv',
          const Media(MediaAction.rewind),
        );
        expect((rewind as Failed).rawDeviceMessage, contains('400'));
        expect(
          await client.send('demo-firetv', const PressKey(RemoteKey.channelUp)),
          isA<Unsupported>(),
        );
      },
    );

    test('forget removes the TV and its pairing', () async {
      final client = _demo();
      await client.scan();
      await _pairWith(
        client,
        'demo-firetv',
        'firetv.lightning',
        pin: demoFireTvPin,
      );

      await client.forget('demo-firetv');
      expect((await client.watchDevices().first).map((d) => d.id), [
        'demo-roku',
      ]);
      expect(
        await client.send('demo-firetv', const PressKey(RemoteKey.up)),
        isA<Failed>(),
      );

      await client.scan();
      expect((await client.watchDevices().first).last.needsPairing, isTrue);
    });

    test('unknown ids: send fails, refresh and forget throw', () async {
      final client = _demo();

      expect(await client.send('nope', const ListApps()), isA<Failed>());
      await expectLater(client.refresh('nope'), throwsA(isA<WatchmeError>()));
      await expectLater(client.forget('nope'), throwsA(isA<WatchmeError>()));
    });
  });

  testWidgets('the app runs end to end on the demo client', (tester) async {
    final client = _demo();
    addTearDown(client.close);
    useWindowSize(tester, const Size(1200, 1100));
    await tester.pumpWidget(WatchmeApp(client: client, demo: true));
    await tester.pumpAndSettle();
    expect(find.text('Demo'), findsOneWidget);

    await tester.tap(find.text('Scan'));
    await tester.pumpAndSettle();
    expect(find.text('Living Room Roku TV'), findsOneWidget);
    expect(find.text('Bedroom Fire TV Stick'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), demoFireTvPin);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Paired'), findsOneWidget);

    await tester.tap(find.text('Open remote'));
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byTooltip('Channel up'), findsNothing);

    await tester.tap(find.byTooltip('Home'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    await tester.tap(find.byTooltip('Rewind'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rewind failed'), findsOneWidget);
    expect(find.textContaining('TV said: HTTP 400'), findsOneWidget);
  });
}
