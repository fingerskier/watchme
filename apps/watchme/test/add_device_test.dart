import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/devices/host_input.dart';
import 'package:watchme_core/watchme_core.dart';

import 'support/fake_client.dart';

void main() {
  group('validateHostInput', () {
    test('accepts IPv4, IPv6 and host names', () {
      for (final ok in [
        '192.168.1.20',
        ' 10.0.0.1 ',
        '0.0.0.0',
        '255.255.255.255',
        'fe80::1',
        '[fe80::1]',
        '2001:db8::8:800:200c:417a',
        'roku-living-room',
        'tv.lan',
        'tv.lan.',
      ]) {
        expect(validateHostInput(ok), isNull, reason: ok);
      }
    });

    test('rejects empty input', () {
      expect(validateHostInput(''), "Enter the TV's IP address.");
      expect(validateHostInput('   '), "Enter the TV's IP address.");
      expect(validateHostInput(null), "Enter the TV's IP address.");
    });

    test('rejects bad IPv4 addresses', () {
      for (final bad in ['192.168.1', '192.168.1.256', '1.2.3.4.5', '1..2.3']) {
        expect(
          validateHostInput(bad),
          startsWith('That is not a valid IPv4 address'),
          reason: bad,
        );
      }
    });

    test('rejects ports, URLs, spaces and junk', () {
      expect(validateHostInput('192.168.1.20:8060'), startsWith('Leave out'));
      expect(validateHostInput('[fe80::1]:8060'), startsWith('Leave out'));
      expect(validateHostInput('http://192.168.1.20'), contains('http://'));
      expect(validateHostInput('192.168.1.20/x'), contains('path'));
      expect(validateHostInput('my tv'), contains('spaces'));
      expect(validateHostInput('tv_room'), startsWith('Enter an IP'));
      expect(validateHostInput('-tv'), startsWith('Enter an IP'));
      expect(validateHostInput('fe80::1::2'), contains('IPv6'));
    });

    test('normalizes what the engine receives', () {
      expect(normalizeHostInput(' 192.168.001.020 '), '192.168.1.20');
      expect(normalizeHostInput('[fe80::1]'), 'fe80::1');
      expect(normalizeHostInput('tv.lan.'), 'tv.lan');
    });
  });

  group('Add by IP dialog', () {
    Future<void> openDialog(
      WidgetTester tester,
      FakeWatchmeClient client,
    ) async {
      await pumpApp(tester, client);
      await tester.tap(find.text('Add by IP'));
      await tester.pumpAndSettle();
      expect(find.text('Add a TV by IP address'), findsOneWidget);
    }

    Future<void> submit(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextFormField), text);
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows validation errors and does not probe', (tester) async {
      final client = FakeWatchmeClient();
      await openDialog(tester, client);

      await submit(tester, '');
      expect(find.text("Enter the TV's IP address."), findsOneWidget);

      await submit(tester, '192.168.1.300');
      expect(
        find.textContaining('That is not a valid IPv4 address'),
        findsOneWidget,
      );

      await submit(tester, '192.168.1.20:8060');
      expect(find.textContaining('Leave out the port'), findsOneWidget);

      expect(client.addedHosts, isEmpty);
    });

    testWidgets('adds a valid address and closes', (tester) async {
      final client = FakeWatchmeClient()..onAddManual = (_) => rokuDevice();
      await openDialog(tester, client);

      await submit(tester, ' 192.0.2.10 ');

      expect(client.addedHosts, ['192.0.2.10']);
      expect(find.text('Add a TV by IP address'), findsNothing);
      expect(find.text('Added Living Room Roku'), findsOneWidget);
    });

    testWidgets('Enter in the field submits', (tester) async {
      final client = FakeWatchmeClient()..onAddManual = (_) => rokuDevice();
      await openDialog(tester, client);

      await tester.enterText(find.byType(TextFormField), '192.0.2.10');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(client.addedHosts, ['192.0.2.10']);
    });

    testWidgets('a failed probe keeps the dialog and shows the device text', (
      tester,
    ) async {
      final client = FakeWatchmeClient()
        ..onAddManual = (host) => throw WatchmeError.unreachable(
          'Nothing answered at $host.',
          rawDeviceMessage: 'Connection refused',
        );
      await openDialog(tester, client);

      await submit(tester, '192.0.2.99');

      expect(find.text('Add a TV by IP address'), findsOneWidget);
      expect(find.text("Couldn't reach the TV"), findsOneWidget);
      expect(find.text('Nothing answered at 192.0.2.99.'), findsOneWidget);
      expect(find.text('Connection refused'), findsOneWidget);
    });

    testWidgets('Cancel closes without probing', (tester) async {
      final client = FakeWatchmeClient();
      await openDialog(tester, client);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Add a TV by IP address'), findsNothing);
      expect(client.addedHosts, isEmpty);
    });
  });
}
