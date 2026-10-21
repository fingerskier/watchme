import 'package:flutter_test/flutter_test.dart';
import 'package:watchme/src/remote/power_confirmation.dart';
import 'package:watchme/src/widgets/command_feedback.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart' show PowerOrchestrator;

void main() {
  group('describeCommandResult', () {
    test('delivered results need no comment', () {
      expect(describeCommandResult(const Confirmed(), label: 'Up'), isNull);
      expect(
        describeCommandResult(const SentUnconfirmed(), label: 'Up'),
        isNull,
      );
    });

    test('a partly delivered command warns before a retry', () {
      final text = describeCommandResult(
        const Failed(
          WatchmeError.partiallyDelivered(
            'Sent 3 of 8 characters.',
            rawDeviceMessage: 'HTTP 503',
          ),
        ),
        label: 'Text',
      )!;

      expect(text.title, 'Text failed: Sent 3 of 8 characters.');
      expect(
        text.detail,
        'Part of it reached the TV. Check the TV before trying again.\n'
        'TV said: HTTP 503',
      );
    });

    test('other failures show only the TV text, if any', () {
      expect(
        describeCommandResult(
          const Failed(WatchmeError.unreachable('Nothing answered.')),
          label: 'Up',
        )!.detail,
        isNull,
      );
      expect(
        describeCommandResult(
          const Failed(
            WatchmeError.rejected('Refused.', rawDeviceMessage: 'Limited'),
          ),
          label: 'Up',
        )!.detail,
        'TV said: Limited',
      );
    });

    test('a refused toggle explains why', () {
      const refused = Unsupported(Unsupported.needsConfirmation);

      final unconfirmed = describeCommandResult(
        refused,
        label: 'Power',
        command: const PressKey(RemoteKey.power),
      )!;
      expect(unconfirmed.title, 'Power was not sent');
      expect(
        unconfirmed.detail,
        contains("couldn't tell whether the TV is on"),
      );

      // The user already answered: the engine refused within its quiet
      // period, so asking again would not help.
      final confirmed = describeCommandResult(
        refused,
        label: 'Power off',
        command: const SetPower(false, userConfirmed: true),
      )!;
      expect(confirmed.title, 'Power off was not sent');
      expect(confirmed.detail, contains('moments ago'));
    });

    test("the engine's quiet-period refusal reads as not sent, not as "
        'unavailable', () {
      const quiet = Unsupported(PowerOrchestrator.quietPeriodReason);
      expect(isPowerQuietPeriod(quiet), isTrue);
      expect(
        isPowerQuietPeriod(const Unsupported(Unsupported.needsConfirmation)),
        isFalse,
      );
      final text = describeCommandResult(
        quiet,
        label: 'Power off',
        command: const SetPower(false, userConfirmed: true),
      )!;
      expect(text.title, 'Power off was not sent');
      expect(text.detail, contains('moments ago'));
    });
  });

  group('needsPowerConfirmation', () {
    const ask = Unsupported(Unsupported.needsConfirmation);

    test('asks for an unconfirmed power command refused for confirmation', () {
      expect(needsPowerConfirmation(const SetPower(true), ask), isTrue);
      expect(needsPowerConfirmation(const SetPower(false), ask), isTrue);
      expect(
        needsPowerConfirmation(const PressKey(RemoteKey.power), ask),
        isTrue,
      );
    });

    test('never asks twice, or about anything else', () {
      expect(
        needsPowerConfirmation(const SetPower(true, userConfirmed: true), ask),
        isFalse,
      );
      expect(
        needsPowerConfirmation(
          const PressKey(RemoteKey.power, KeyAction.down),
          ask,
        ),
        isFalse,
      );
      expect(
        needsPowerConfirmation(const PressKey(RemoteKey.powerOff), ask),
        isFalse,
      );
      expect(
        needsPowerConfirmation(const SetPower(false), const Confirmed()),
        isFalse,
      );
      expect(
        needsPowerConfirmation(
          const SetPower(false),
          const Unsupported('No driver for this device can turn it off'),
        ),
        isFalse,
      );
    });

    test('the confirmed command is the opposite of what the user saw', () {
      expect(
        confirmedPowerCommand(observedOn: true),
        const SetPower(false, userConfirmed: true),
      );
      expect(
        confirmedPowerCommand(observedOn: false),
        const SetPower(true, userConfirmed: true),
      );
    });

    test('a discrete command sends what was asked, or nothing when the TV '
        'is already there', () {
      expect(wantedPower(const SetPower(true)), isTrue);
      expect(wantedPower(const SetPower(false)), isFalse);
      expect(wantedPower(const PressKey(RemoteKey.power)), isNull);
      expect(
        confirmedPowerCommand(observedOn: false, wanted: true),
        const SetPower(true, userConfirmed: true),
      );
      expect(confirmedPowerCommand(observedOn: true, wanted: true), isNull);
      expect(
        confirmedPowerCommand(observedOn: true, wanted: false),
        const SetPower(false, userConfirmed: true),
      );
      expect(confirmedPowerCommand(observedOn: false, wanted: false), isNull);
    });
  });
}
