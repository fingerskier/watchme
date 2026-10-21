import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/pairing/pairing_screen.dart';
import 'package:watchme/src/remote/remote_screen.dart';
import 'package:watchme/src/remote/remote_shortcuts.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart' show PowerOrchestrator;

import 'support/fake_client.dart';

/// Opens the remote for [device] at [size].
Future<FakeWatchmeClient> _openRemote(
  WidgetTester tester,
  DeviceView device, {
  Size size = const Size(1200, 1100),
  FakeWatchmeClient? client,
}) async {
  final fake = client ?? FakeWatchmeClient(devices: [device]);
  await pumpApp(tester, fake, size: size);
  await tester.tap(find.text(device.name));
  await tester.pumpAndSettle();
  expect(find.byType(RemoteScreen), findsOneWidget);
  return fake;
}

Future<void> _press(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip(label));
  await tester.pumpAndSettle();
}

void main() {
  group('buttons send the right command', () {
    final cases = <String, Command>{
      'Up': const PressKey(RemoteKey.up),
      'Down': const PressKey(RemoteKey.down),
      'Left': const PressKey(RemoteKey.left),
      'Right': const PressKey(RemoteKey.right),
      'OK': const PressKey(RemoteKey.select),
      'Back (TV)': const PressKey(RemoteKey.back),
      'Home': const PressKey(RemoteKey.home),
      'Menu': const PressKey(RemoteKey.menu),
      'Volume up': const PressKey(RemoteKey.volumeUp),
      'Volume down': const PressKey(RemoteKey.volumeDown),
      'Mute': const PressKey(RemoteKey.mute),
      'Power': const PressKey(RemoteKey.power),
      'Power on': const SetPower(true),
      'Power off': const SetPower(false),
      'Channel up': const PressKey(RemoteKey.channelUp),
      'Channel down': const PressKey(RemoteKey.channelDown),
      'Rewind': const Media(MediaAction.rewind),
      'Play/pause': const Media(MediaAction.playPause),
      'Fast forward': const Media(MediaAction.fastForward),
    };
    for (final MapEntry(key: label, value: command) in cases.entries) {
      testWidgets(label, (tester) async {
        final client = await _openRemote(tester, rokuDevice());
        await _press(tester, label);
        expect(client.sent, [('roku-1', command)]);
      });
    }
  });

  testWidgets('holding a d-pad key sends key-down then key-up', (tester) async {
    final client = await _openRemote(tester, rokuDevice());

    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Up')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    expect(client.commands, [const PressKey(RemoteKey.up, KeyAction.down)]);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(client.commands, [
      const PressKey(RemoteKey.up, KeyAction.down),
      const PressKey(RemoteKey.up, KeyAction.up),
    ]);
  });

  testWidgets('the text field sends TypeText and clears on delivery', (
    tester,
  ) async {
    final client = await _openRemote(tester, rokuDevice());

    await tester.enterText(find.byType(TextField), 'star trek');
    await tester.tap(find.byTooltip('Send text'));
    await tester.pumpAndSettle();

    expect(client.commands, [const TypeText('star trek')]);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('leaving the remote while text is still being sent is safe', (
    tester,
  ) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()])
      ..sendGate = Completer();
    await _openRemote(tester, rokuDevice(), client: client);

    await tester.enterText(find.byType(TextField), 'a long title');
    await tester.tap(find.byTooltip('Send text'));
    await tester.pump();
    expect(client.commands, [const TypeText('a long title')]);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(RemoteScreen), findsNothing);

    client.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed text stays in the field', (tester) async {
    final client = FakeWatchmeClient(devices: [rokuDevice()])
      ..onSend = (_) =>
          const Failed(WatchmeError.timeout('The TV did not answer.'));
    await _openRemote(tester, rokuDevice(), client: client);

    await tester.enterText(find.byType(TextField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(client.commands, [const TypeText('abc')]);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'abc',
    );
    expect(find.text('Text failed: The TV did not answer.'), findsOneWidget);
  });

  group('capability gating', () {
    testWidgets('unsupported controls are hidden', (tester) async {
      final device = rokuDevice(
        capabilities: allCapabilities({
          Capability.channel: const CapabilitySupport.no(Capability.channel),
          Capability.mediaTransport: const CapabilitySupport.no(
            Capability.mediaTransport,
          ),
          Capability.textInput: const CapabilitySupport.no(
            Capability.textInput,
          ),
          Capability.appList: const CapabilitySupport.no(Capability.appList),
          Capability.powerOn: const CapabilitySupport.no(Capability.powerOn),
        }),
      );
      await _openRemote(tester, device);

      expect(find.byTooltip('Channel up'), findsNothing);
      expect(find.byTooltip('Channel down'), findsNothing);
      expect(find.byTooltip('Play/pause'), findsNothing);
      expect(find.byTooltip('Rewind'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Apps'), findsNothing);
      expect(find.byTooltip('Power on'), findsNothing);
      // Supported controls remain.
      expect(find.byTooltip('Power off'), findsOneWidget);
      expect(find.byTooltip('Up'), findsOneWidget);
      expect(find.byTooltip('Volume up'), findsOneWidget);
    });

    testWidgets('optional controls stay hidden while unknown', (tester) async {
      final device = rokuDevice(capabilities: const []);
      await _openRemote(tester, device);

      expect(find.byTooltip('Channel up'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Apps'), findsNothing);
    });

    testWidgets('core controls are disabled while unknown', (tester) async {
      final client = await _openRemote(
        tester,
        rokuDevice(capabilities: const []),
      );

      expect(find.byTooltip('Up'), findsOneWidget);
      await _press(tester, 'Up');
      await _press(tester, 'Volume up');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();

      expect(client.sent, isEmpty);
    });

    testWidgets('keyboard shortcuts for hidden controls do nothing', (
      tester,
    ) async {
      final device = rokuDevice(
        capabilities: allCapabilities({
          Capability.channel: const CapabilitySupport.no(Capability.channel),
        }),
      );
      final client = await _openRemote(tester, device);

      await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
      await tester.pumpAndSettle();

      expect(client.sent, isEmpty);
    });
  });

  group('result feedback', () {
    testWidgets('Unsupported shows a snackbar with the reason', (tester) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (_) => const Unsupported('Roku ECP has no menu key.');
      await _openRemote(tester, rokuDevice(), client: client);

      await _press(tester, 'Menu');

      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Menu is not available'), findsOneWidget);
      expect(find.text('Roku ECP has no menu key.'), findsOneWidget);
    });

    testWidgets('Failed shows the message and the raw device text', (
      tester,
    ) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (_) => const Failed(
          WatchmeError.rejected(
            'The TV refused the key.',
            rawDeviceMessage: 'ECP command not allowed in Limited mode.',
          ),
        );
      await _openRemote(tester, rokuDevice(), client: client);

      await _press(tester, 'Home');

      expect(find.text('Home failed: The TV refused the key.'), findsOneWidget);
      expect(
        find.text('TV said: ECP command not allowed in Limited mode.'),
        findsOneWidget,
      );
    });

    testWidgets('a toggle refused even after the user answered explains '
        'why, without asking again', (tester) async {
      // Before Codex finding 1 this snackbar was the only answer to
      // needsConfirmation; the remote now asks first (see 'power
      // confirmation' below). The engine still refuses a confirmed toggle
      // right after another power command, with its quiet-period reason.
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (c) => c is SetPower && c.userConfirmed
            ? const Unsupported(PowerOrchestrator.quietPeriodReason)
            : const Unsupported(Unsupported.needsConfirmation);
      await _openRemote(tester, rokuDevice(), client: client);

      await _press(tester, 'Power');
      await tester.tap(find.text("It's on, turn it off"));
      await tester.pumpAndSettle();

      expect(client.commands, [
        const PressKey(RemoteKey.power),
        const SetPower(false, userConfirmed: true),
      ]);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Power off was not sent'), findsOneWidget);
      expect(find.textContaining('moments ago'), findsOneWidget);
    });

    testWidgets('SentUnconfirmed and Confirmed are silent', (tester) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (c) =>
            c is PressKey ? const SentUnconfirmed() : const Confirmed();
      await _openRemote(tester, rokuDevice(), client: client);

      await _press(tester, 'Up');
      await _press(tester, 'Play/pause');

      expect(client.sent, hasLength(2));
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('power confirmation', () {
    // Codex review finding 1: when the engine cannot tell whether the TV
    // is on, it refuses to toggle and the remote asks the user.
    const question =
        "watchme can't tell whether the TV is on. Is it on right now?";

    /// Answers needsConfirmation to the first power command, and confirms
    /// the user-confirmed one.
    FakeWatchmeClient unsureClient() =>
        FakeWatchmeClient(devices: [rokuDevice()])
          ..onSend = (c) => c is SetPower && c.userConfirmed
              ? const Confirmed()
              : const Unsupported(Unsupported.needsConfirmation);

    // The discrete buttons used to offer both answers, so "Power on" on a
    // TV that was in fact on, answered honestly with "It's on, turn it
    // off", turned it off (verifier follow-up to Codex finding #1). Only
    // the power key offers both directions now; Power on and Power off
    // send what was asked, or nothing when the TV is already there.
    for (final (label, sent, answers) in [
      (
        'Power',
        const PressKey(RemoteKey.power),
        [
          ("It's on, turn it off", const SetPower(false, userConfirmed: true)),
          ("It's off, turn it on", const SetPower(true, userConfirmed: true)),
        ],
      ),
      (
        'Power on',
        const SetPower(true),
        [
          ("It's off, turn it on", const SetPower(true, userConfirmed: true)),
          ("It's already on", null),
        ],
      ),
      (
        'Power off',
        const SetPower(false),
        [
          ("It's on, turn it off", const SetPower(false, userConfirmed: true)),
          ("It's already off", null),
        ],
      ),
    ]) {
      for (final (answer, confirmed) in answers) {
        testWidgets('$label, then "$answer"', (tester) async {
          final client = await _openRemote(
            tester,
            rokuDevice(),
            client: unsureClient(),
          );

          await _press(tester, label);
          expect(find.text(question), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextButton),
            ),
            findsNWidgets(3),
            reason: 'two answers and Cancel',
          );
          for (final (other, _) in answers) {
            expect(find.text(other), findsOneWidget);
          }
          expect(client.commands, [sent]);

          await tester.tap(find.text(answer));
          await tester.pumpAndSettle();
          expect(find.text(question), findsNothing);
          expect(client.commands, [sent, ?confirmed]);
          expect(find.byType(SnackBar), findsNothing);
        });
      }
    }

    testWidgets('Power on never offers to turn the TV off, nor Power off to '
        'turn it on', (tester) async {
      await _openRemote(tester, rokuDevice(), client: unsureClient());

      await _press(tester, 'Power on');
      expect(find.text("It's on, turn it off"), findsNothing);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await _press(tester, 'Power off');
      expect(find.text("It's off, turn it on"), findsNothing);
    });

    testWidgets('a slow answer does not ask over another page', (tester) async {
      final client = unsureClient()..sendGate = Completer();
      await _openRemote(tester, rokuDevice(), client: client);

      await tester.tap(find.byTooltip('Power'));
      await tester.pump();
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another page')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      client.sendGate!.complete();
      await tester.pumpAndSettle();

      expect(find.text('Another page'), findsOneWidget);
      expect(find.text(question), findsNothing);
      expect(find.text('Power was not sent'), findsOneWidget);
      expect(client.commands, [const PressKey(RemoteKey.power)]);
    });

    testWidgets('Cancel sends nothing more', (tester) async {
      final client = await _openRemote(
        tester,
        rokuDevice(),
        client: unsureClient(),
      );

      await _press(tester, 'Power');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text(question), findsNothing);
      expect(client.commands, [const PressKey(RemoteKey.power)]);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a power command the engine carried out asks nothing', (
      tester,
    ) async {
      final client = await _openRemote(tester, rokuDevice());

      await _press(tester, 'Power');

      expect(client.commands, [const PressKey(RemoteKey.power)]);
      expect(find.text(question), findsNothing);
    });

    testWidgets('other needsConfirmation results are not power questions', (
      tester,
    ) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (_) => const Unsupported(Unsupported.needsConfirmation);
      await _openRemote(tester, rokuDevice(), client: client);

      await _press(tester, 'Home');

      expect(find.text(question), findsNothing);
      expect(find.text('Home was not sent'), findsOneWidget);
    });

    testWidgets('the remote is gone before the answer comes back', (
      tester,
    ) async {
      final client = unsureClient()..sendGate = Completer();
      await _openRemote(tester, rokuDevice(), client: client);

      await tester.tap(find.byTooltip('Power'));
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      client.sendGate!.complete();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(question), findsNothing);
      expect(client.commands, [const PressKey(RemoteKey.power)]);
    });
  });

  group('keyboard shortcuts', () {
    final cases = <LogicalKeyboardKey, Command>{
      LogicalKeyboardKey.arrowUp: const PressKey(RemoteKey.up),
      LogicalKeyboardKey.arrowDown: const PressKey(RemoteKey.down),
      LogicalKeyboardKey.arrowLeft: const PressKey(RemoteKey.left),
      LogicalKeyboardKey.arrowRight: const PressKey(RemoteKey.right),
      LogicalKeyboardKey.enter: const PressKey(RemoteKey.select),
      LogicalKeyboardKey.backspace: const PressKey(RemoteKey.back),
      LogicalKeyboardKey.escape: const PressKey(RemoteKey.back),
      LogicalKeyboardKey.keyH: const PressKey(RemoteKey.home),
      LogicalKeyboardKey.equal: const PressKey(RemoteKey.volumeUp),
      LogicalKeyboardKey.minus: const PressKey(RemoteKey.volumeDown),
      LogicalKeyboardKey.keyM: const PressKey(RemoteKey.mute),
      LogicalKeyboardKey.space: const Media(MediaAction.playPause),
      LogicalKeyboardKey.pageUp: const PressKey(RemoteKey.channelUp),
      LogicalKeyboardKey.pageDown: const PressKey(RemoteKey.channelDown),
    };
    for (final MapEntry(key: key, value: command) in cases.entries) {
      testWidgets(key.keyLabel, (tester) async {
        final client = await _openRemote(tester, rokuDevice());
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(client.commands, [command]);
      });
    }

    testWidgets('holding an arrow key becomes key-down and key-up', (
      tester,
    ) async {
      final client = await _openRemote(tester, rokuDevice());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(client.commands, [
        const PressKey(RemoteKey.down, KeyAction.down),
        const PressKey(RemoteKey.down, KeyAction.up),
      ]);
    });

    for (final (label, dpad) in [
      ('disabled', const CapabilitySupport.unknown(Capability.dpadNavigation)),
      ('hidden', const CapabilitySupport.no(Capability.dpadNavigation)),
    ]) {
      testWidgets('a held arrow key is released when the d-pad becomes '
          '$label', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        client.setDevices([
          rokuDevice(
            capabilities: allCapabilities({Capability.dpadNavigation: dpad}),
          ),
        ]);
        await tester.pumpAndSettle();
        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();

        expect(client.commands, [
          const PressKey(RemoteKey.down, KeyAction.down),
          const PressKey(RemoteKey.down, KeyAction.up),
        ]);
      });

      testWidgets('a held on-screen key is released when the d-pad becomes '
          '$label', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Up')),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        expect(client.commands, [const PressKey(RemoteKey.up, KeyAction.down)]);
        client.setDevices([
          rokuDevice(
            capabilities: allCapabilities({Capability.dpadNavigation: dpad}),
          ),
        ]);
        await tester.pumpAndSettle();
        expect(client.commands, [
          const PressKey(RemoteKey.up, KeyAction.down),
          const PressKey(RemoteKey.up, KeyAction.up),
        ]);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(client.commands, hasLength(2), reason: 'released only once');
      });
    }

    testWidgets('leaving the remote mid-hold releases the key', (tester) async {
      final client = await _openRemote(tester, rokuDevice());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(RemoteScreen), findsNothing);

      expect(client.commands, [
        const PressKey(RemoteKey.left, KeyAction.down),
        const PressKey(RemoteKey.left, KeyAction.up),
      ]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(client.commands, hasLength(2));
    });

    group('a held key is released when the remote stops getting keys', () {
      // Codex review finding 10: a modal that takes focus swallows the
      // key-up, so the TV kept repeating the key.
      List<PressKey> keys(FakeWatchmeClient client) =>
          client.commands.whereType<PressKey>().toList();

      Future<void> holdArrowDown(WidgetTester tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }

      const held = [
        PressKey(RemoteKey.down, KeyAction.down),
        PressKey(RemoteKey.down, KeyAction.up),
      ];

      testWidgets('the Apps sheet opens (mouse)', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        await holdArrowDown(tester);
        expect(keys(client), [held.first]);
        await tester.tap(find.text('Apps'), kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(keys(client), held, reason: 'released when the sheet opened');

        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(keys(client), held, reason: 'released only once');
      });

      testWidgets('the keyboard help opens (mouse)', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        await holdArrowDown(tester);
        await tester.tap(
          find.bySemanticsLabel('Keyboard shortcuts'),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(keys(client), held);

        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(keys(client), held);

        // Back on the remote, a new press is a click again.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(keys(client), [...held, const PressKey(RemoteKey.down)]);
      });

      testWidgets('focus moves to the app bar', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        await holdArrowDown(tester);
        // Focus the app bar's Refresh button, as Tab would.
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byTooltip('Refresh status'),
              matching: find.byType(Icon),
            ),
          ),
        ).requestFocus();
        await tester.pumpAndSettle();
        expect(keys(client), held);

        await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        expect(keys(client), held, reason: 'released only once');
      });

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        testWidgets('the app becomes ${state.name}', (tester) async {
          final client = await _openRemote(tester, rokuDevice());
          addTearDown(
            () => tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            ),
          );

          await holdArrowDown(tester);
          // Lifecycle changes arrive in order; going to paused passes
          // through inactive and hidden.
          for (final step in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(step);
            if (step == state) break;
          }
          await tester.pumpAndSettle();
          expect(keys(client), held);

          await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
          await tester.pumpAndSettle();
          expect(keys(client), held, reason: 'released only once');
        });
      }

      testWidgets('a dialog covers an on-screen hold', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Up')),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        expect(keys(client), [const PressKey(RemoteKey.up, KeyAction.down)]);

        // A second finger opens the keyboard help on top of the remote.
        await tester.tap(find.bySemanticsLabel('Keyboard shortcuts'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(keys(client), [
          const PressKey(RemoteKey.up, KeyAction.down),
          const PressKey(RemoteKey.up, KeyAction.up),
        ]);

        await gesture.up();
        await tester.pumpAndSettle();
        expect(keys(client), hasLength(2), reason: 'released only once');
      });

      testWidgets('the app goes inactive during an on-screen hold', (
        tester,
      ) async {
        final client = await _openRemote(tester, rokuDevice());
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Left')),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        expect(keys(client), [
          const PressKey(RemoteKey.left, KeyAction.down),
          const PressKey(RemoteKey.left, KeyAction.up),
        ]);

        await gesture.up();
        await tester.pumpAndSettle();
        expect(keys(client), hasLength(2), reason: 'released only once');
      });

      testWidgets('the system cancels an on-screen hold', (tester) async {
        final client = await _openRemote(tester, rokuDevice());

        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Right')),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        await gesture.cancel();
        await tester.pumpAndSettle();

        expect(keys(client), [
          const PressKey(RemoteKey.right, KeyAction.down),
          const PressKey(RemoteKey.right, KeyAction.up),
        ]);
      });
    });

    testWidgets('modifier combinations are left alone', (tester) async {
      final client = await _openRemote(tester, rokuDevice());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(client.sent, isEmpty);
    });

    testWidgets('typing in the text field does not trigger shortcuts', (
      tester,
    ) async {
      final client = await _openRemote(tester, rokuDevice());

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(client.sent, isEmpty);

      // Esc hands the keyboard back to the TV.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(client.sent, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(client.commands, [const PressKey(RemoteKey.left)]);
    });

    testWidgets('the help button lists the shortcuts', (tester) async {
      await _openRemote(tester, rokuDevice());

      await tester.tap(find.bySemanticsLabel('Keyboard shortcuts'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Backspace, Esc'), findsOneWidget);
      expect(find.text('Play/pause'), findsWidgets);
    });
  });

  group('accessibility', () {
    testWidgets('remote keys are labelled buttons with a tap action only', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final client = await _openRemote(tester, rokuDevice());

      expect(
        tester.getSemantics(find.bySemanticsLabel('Up')),
        isSemantics(
          label: 'Up',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
          hasLongPressAction: false,
        ),
      );
      expect(find.bySemanticsLabel('Channel up'), findsOneWidget);
      expect(find.bySemanticsLabel('Back (TV)'), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel('Volume up'));
      await tester.pumpAndSettle();
      expect(client.commands, [const PressKey(RemoteKey.volumeUp)]);
      semantics.dispose();
    });

    testWidgets('a disabled key says so', (tester) async {
      final semantics = tester.ensureSemantics();
      await _openRemote(tester, rokuDevice(capabilities: const []));

      expect(
        tester.getSemantics(find.bySemanticsLabel('Up')),
        isSemantics(isButton: true, isEnabled: false),
      );
      semantics.dispose();
    });

    testWidgets('remote keys are large touch targets', (tester) async {
      await _openRemote(tester, rokuDevice(), size: const Size(360, 740));

      for (final label in ['Up', 'OK', 'Home', 'Mute', 'Power on']) {
        final size = tester.getSize(find.byTooltip(label));
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
      }
    });

    testWidgets('a focused button keeps Enter; Esc returns to TV control', (
      tester,
    ) async {
      final client = await _openRemote(tester, rokuDevice());

      // Focus the Home key as Tab would.
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byTooltip('Home'),
            matching: find.byType(Icon),
          ),
        ),
      ).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(client.commands, [const PressKey(RemoteKey.home)]);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(client.commands, [
        const PressKey(RemoteKey.home),
        const PressKey(RemoteKey.select),
      ]);
    });

    testWidgets('Tab reaches the remote keys', (tester) async {
      await _openRemote(tester, rokuDevice());

      final visited = <String>{};
      for (var i = 0; i < 40; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        final tooltip = focused?.findAncestorWidgetOfExactType<Tooltip>();
        if (tooltip?.message case final message?) visited.add(message);
      }
      expect(visited, containsAll(['Power on', 'Up', 'OK', 'Volume up']));
    });

    test('the shortcut help lists every shortcut', () {
      final help = remoteShortcutsHelp();
      for (final s in remoteShortcuts) {
        expect(help, contains('${s.keysLabel}: ${s.label}'));
      }
    });
  });

  group('apps sheet', () {
    const apps = [
      AppInfo(id: '12', name: 'Netflix'),
      AppInfo(id: '837', name: 'YouTube'),
      AppInfo(id: 'tvinput.hdmi1', name: 'HDMI 1', kind: AppKind.input),
    ];

    testWidgets('lists apps and inputs, and launches the one tapped', (
      tester,
    ) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (c) => c is ListApps
            ? const Confirmed(payload: AppListPayload(apps))
            : const Confirmed();
      await _openRemote(tester, rokuDevice(), client: client);

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();

      expect(client.commands, [const ListApps()]);
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('YouTube'), findsOneWidget);
      expect(find.text('Inputs'), findsOneWidget);
      expect(find.text('HDMI 1'), findsOneWidget);

      await tester.tap(find.text('Netflix'));
      await tester.pumpAndSettle();

      expect(client.commands.last, const LaunchApp('12'));
      expect(find.text('YouTube'), findsNothing);
    });

    testWidgets('a failed list shows the raw device text', (tester) async {
      final client = FakeWatchmeClient(devices: [rokuDevice()])
        ..onSend = (_) => const Failed(
          WatchmeError.rejected(
            'The TV refused the app list.',
            rawDeviceMessage: 'ECP command not allowed in Limited mode.',
          ),
        );
      await _openRemote(tester, rokuDevice(), client: client);

      await tester.tap(find.text('Apps'));
      await tester.pumpAndSettle();

      expect(find.text('Apps could not be listed'), findsOneWidget);
      expect(
        find.text('ECP command not allowed in Limited mode.'),
        findsOneWidget,
      );
    });
  });

  testWidgets('a device that needs pairing offers it', (tester) async {
    final client = await _openRemote(tester, fireTvDevice());

    expect(
      find.text('Pair Fire TV remote API before this TV accepts commands.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Pair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PairingScreen), findsOneWidget);
    expect(client.pairings.single.driverId, 'firetv.lightning');
  });

  testWidgets('shows the device state', (tester) async {
    final at = DateTime.utc(2026, 10, 21);
    final device = rokuDevice(
      state: DeviceState(
        power: Observed.reported(PowerMode.on, 'roku.ecp', at),
        foregroundApp: Observed.reported(
          const AppInfo(id: '12', name: 'Netflix'),
          'roku.ecp',
          at,
        ),
        muted: Observed.inferred(true, 'roku.ecp', at),
      ),
    );
    await _openRemote(tester, device);

    expect(find.text('On'), findsOneWidget);
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('Muted?'), findsOneWidget);
    expect(find.byTooltip('Inferred from roku.ecp'), findsOneWidget);
  });

  testWidgets('a TV that stops answering shows as disconnected and stale', (
    tester,
  ) async {
    // Codex review finding 9: the remote kept showing an unreachable TV as
    // connected and on.
    final at = DateTime.utc(2026, 10, 21);
    final live = DeviceState(
      power: Observed.inferred(PowerMode.on, 'firetv.lightning', at),
      volume: Observed.reported(12, 'firetv.lightning', at),
    );
    DeviceView fireTv(ConnectionState connection, DeviceState state) =>
        fireTvDevice(paired: true).copyWith(
          drivers: [
            DriverView(
              driverId: 'firetv.lightning',
              protocol: 'Fire TV remote API',
              requiresPairing: true,
              paired: true,
              connection: connection,
              lastError: connection == ConnectionState.connected
                  ? null
                  : const WatchmeError.unreachable(
                      'Nothing answered at 192.0.2.20.',
                      rawDeviceMessage: 'Connection refused',
                    ),
            ),
          ],
          state: state,
        );
    final client = await _openRemote(
      tester,
      fireTv(ConnectionState.connected, live),
    );
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('On?'), findsOneWidget);
    expect(find.text('Volume 12'), findsOneWidget);
    expect(find.textContaining('Not connected'), findsNothing);

    client.setDevices([fireTv(ConnectionState.disconnected, live.markStale())]);
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsNothing);
    expect(find.text('Not connected'), findsOneWidget);
    expect(
      find.textContaining(
        'Fire TV remote API: Not connected.\n'
        'Nothing answered at 192.0.2.20.',
      ),
      findsOneWidget,
    );
    expect(find.text('Connection refused'), findsOneWidget);
    expect(find.text('On?'), findsNothing);
    expect(find.text('On (last known)'), findsOneWidget);
    expect(find.text('Volume 12 (last known)'), findsOneWidget);
    expect(
      find.byTooltip('Last reported by firetv.lightning'),
      findsNWidgets(2),
    );
  });

  testWidgets('a failed connection shows as failed', (tester) async {
    await _openRemote(tester, rokuDevice(connection: ConnectionState.failed));

    expect(find.text('Connection failed'), findsOneWidget);
    expect(find.text('Roku ECP: Connection failed.'), findsOneWidget);
  });

  testWidgets('Refresh calls client.refresh', (tester) async {
    final client = await _openRemote(tester, rokuDevice());

    await tester.tap(find.byTooltip('Refresh status'));
    await tester.pumpAndSettle();

    expect(client.refreshed, ['roku-1']);
  });

  testWidgets('a keyboard hold ends when the device leaves the list', (
    tester,
  ) async {
    // Verifier follow-up to Codex finding #10: the remote's body (and its
    // keyboard handler) went away with the device, and the key-up never
    // reached the TV.
    final client = await _openRemote(tester, rokuDevice());

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(client.commands, [const PressKey(RemoteKey.down, KeyAction.down)]);

    client.setDevices([]);
    await tester.pumpAndSettle();
    expect(client.commands, [
      const PressKey(RemoteKey.down, KeyAction.down),
      const PressKey(RemoteKey.down, KeyAction.up),
    ]);

    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(client.commands, hasLength(2), reason: 'released only once');
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a forgotten device leaves an explanation', (tester) async {
    final client = await _openRemote(tester, rokuDevice());

    client.setDevices([]);
    await tester.pumpAndSettle();

    expect(
      find.text('This TV is no longer in your device list.'),
      findsOneWidget,
    );
  });

  testWidgets('fits a phone screen', (tester) async {
    final client = await _openRemote(
      tester,
      rokuDevice(),
      size: const Size(360, 740),
    );

    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(client.commands, [const PressKey(RemoteKey.up)]);
    // Everything is reachable by scrolling.
    await tester.scrollUntilVisible(
      find.text('Apps'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(RemoteScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.text('Apps').hitTestable(), findsOneWidget);
  });
}
