import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/pairing/pairing_screen.dart';
import 'package:watchme/src/remote/remote_screen.dart';
import 'package:watchme_core/watchme_core.dart';

import 'support/fake_client.dart';

const _pinStep = EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits);

/// Opens pairing for the Fire TV and returns the handle the screen got.
Future<FakePairingHandle> _startPairing(
  WidgetTester tester,
  FakeWatchmeClient client,
) async {
  await pumpApp(tester, client);
  await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
  await _settleSteps(tester);
  expect(find.byType(PairingScreen), findsOneWidget);
  return client.pairings.last;
}

/// Spinners keep animating, so pump a fixed time instead of settling.
Future<void> _settleSteps(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _emit(
  WidgetTester tester,
  FakePairingHandle handle,
  PairingStep step,
) async {
  handle.emit(step);
  await _settleSteps(tester);
}

void main() {
  testWidgets('shows progress until the first step', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    await _startPairing(tester, client);

    expect(find.text('Pair Bedroom Fire TV'), findsOneWidget);
    expect(find.text('Fire TV remote API'), findsOneWidget);
    expect(find.text('Starting pairing…'), findsOneWidget);
  });

  testWidgets('EnterCode honours length and alphabet, then submits', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, _pinStep);

    expect(find.text('Type the 4 digits your TV shows.'), findsOneWidget);
    final field = find.byType(TextField);
    final pairButton = find.widgetWithText(FilledButton, 'Pair');

    await tester.enterText(field, '12');
    await tester.pump();
    expect(tester.widget<FilledButton>(pairButton).onPressed, isNull);

    // Letters are filtered out and the length is capped.
    await tester.enterText(field, 'ab1234567');
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, '1234');
    expect(tester.widget<FilledButton>(pairButton).onPressed, isNotNull);

    await tester.tap(pairButton);
    await tester.pump();

    expect(handle.submitted, ['1234']);
    expect(find.text('Checking the code…'), findsOneWidget);

    await _emit(tester, handle, const Paired.redacted());

    expect(find.text('Paired'), findsOneWidget);
    expect(
      find.text('watchme can now control Bedroom Fire TV.'),
      findsOneWidget,
    );
  });

  testWidgets('a hex code accepts letters A-F only', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(
      tester,
      handle,
      const EnterCode('Code on the TV', 6, CodeAlphabet.hex),
    );

    await tester.enterText(find.byType(TextField), 'a1g2Zf9c');
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'a12f9c',
    );
  });

  testWidgets('Enter in the code field submits a valid code', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, _pinStep);

    await tester.enterText(find.byType(TextField), '4321');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(handle.submitted, ['4321']);
  });

  testWidgets('Paired offers the remote', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice(paired: true)]);
    await pumpApp(tester, client);
    await tester.tap(find.byTooltip('More actions for Bedroom Fire TV'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pair Fire TV remote API again'));
    await _settleSteps(tester);
    final handle = client.pairings.single;

    await _emit(tester, handle, const Paired.redacted());
    await tester.tap(find.text('Open remote'));
    await tester.pumpAndSettle();

    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.byType(PairingScreen), findsNothing);
  });

  testWidgets('PairingFailed shows the raw device message and retries', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, _pinStep);
    await _emit(
      tester,
      handle,
      const PairingFailed(
        WatchmeError.unauthorized(
          'The Fire TV did not accept that PIN.',
          rawDeviceMessage: '{"description":"Invalid PIN"}',
        ),
      ),
    );

    expect(find.text('Pairing failed'), findsOneWidget);
    expect(find.text('The TV did not accept watchme'), findsOneWidget);
    expect(find.text('The Fire TV did not accept that PIN.'), findsOneWidget);
    expect(find.text('The TV said:'), findsOneWidget);
    expect(find.text('{"description":"Invalid PIN"}'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await _settleSteps(tester);

    expect(client.pairings, hasLength(2));
    // The finished attempt is not cancelled again.
    expect(handle.cancelled, isFalse);
    expect(find.text('Starting pairing…'), findsOneWidget);

    await _emit(tester, client.pairings.last, _pinStep);
    expect(find.text('PIN shown on the TV'), findsOneWidget);
  });

  testWidgets('an unsupported pairing offers no retry', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(
      tester,
      handle,
      const PairingFailed(WatchmeError.unsupported('No pairing needed.')),
    );

    expect(find.text('No pairing needed.'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('AcceptOnTv counts down', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    handle.emit(
      const AcceptOnTv(Duration(seconds: 30), message: 'Choose Allow.'),
    );
    await tester.pump();

    expect(find.text('Choose Allow.'), findsOneWidget);
    expect(find.text('30 s left'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    expect(find.text('20 s left'), findsOneWidget);

    await tester.pump(const Duration(seconds: 25));
    expect(find.text('Time is up. Waiting for the TV…'), findsOneWidget);
  });

  testWidgets('Instruct with requiresAck waits for Continue', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(
      tester,
      handle,
      Instruct(
        'Enable Control by mobile apps.',
        helpUrl: Uri.parse('https://support.example/roku'),
        requiresAck: true,
      ),
    );

    expect(find.text('Enable Control by mobile apps.'), findsOneWidget);
    expect(find.text('https://support.example/roku'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(handle.submitted, ['']);
  });

  testWidgets('Instruct without ack shows progress only', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, const Instruct('Waking the TV…'));

    expect(find.text('Waking the TV…'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('OpenUrlFirst and NeedsUserMaterial continue on request', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(
      tester,
      handle,
      OpenUrlFirst(
        Uri.parse('https://192.0.2.20:8080/'),
        'Accept the TV certificate in your browser.',
      ),
    );

    expect(find.text('Open this address first'), findsOneWidget);
    expect(find.text('https://192.0.2.20:8080/'), findsOneWidget);
    expect(find.byTooltip('Copy link'), findsOneWidget);
    await tester.tap(find.text("I've opened it"));
    await tester.pump();
    expect(handle.submitted, ['']);

    await _emit(
      tester,
      handle,
      NeedsUserMaterial(
        MaterialKind.clientCertificate,
        Uri.parse('https://docs.example/vidaa'),
      ),
    );
    expect(find.text('This TV needs a client certificate'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(handle.submitted, ['', '']);
  });

  testWidgets('leaving before the end cancels the pairing', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, _pinStep);

    await tester.tap(find.byTooltip('Cancel pairing'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
    expect(handle.cancelled, isTrue);
  });

  testWidgets('leaving after success does not cancel', (tester) async {
    final client = FakeWatchmeClient(devices: [fireTvDevice()]);
    final handle = await _startPairing(tester, client);
    await _emit(tester, handle, const Paired.redacted());

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingScreen), findsNothing);
    expect(handle.cancelled, isFalse);
  });
}
