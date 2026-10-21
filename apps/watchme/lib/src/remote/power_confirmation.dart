import 'package:flutter/material.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart' show PowerOrchestrator;

/// Whether [result] means the engine wants the user to say whether the TV
/// is on before it sends a power toggle for [command].
///
/// The engine answers `Unsupported(Unsupported.needsConfirmation)` when the
/// only way to carry out [SetPower] is a toggle and its evidence does not
/// agree on the TV's current state, and when its evidence does not settle
/// the current state for the power key (`PressKey(RemoteKey.power)`, a
/// toggle intent). A [SetPower] the user already confirmed is never asked
/// about again: if it is refused too, the refusal is reported instead.
bool needsPowerConfirmation(Command command, CommandResult result) =>
    result is Unsupported &&
    result.reason == Unsupported.needsConfirmation &&
    switch (command) {
      SetPower(userConfirmed: false) => true,
      PressKey(key: RemoteKey.power, action: KeyAction.click) => true,
      _ => false,
    };

/// Whether [result] refused a power command only because another one went
/// out moments ago: the engine sends no toggle within its quiet period
/// (`PowerOrchestrator.quietPeriodReason`), even after the user answered.
/// Asking the user again would not help; waiting does.
bool isPowerQuietPeriod(CommandResult result) =>
    result is Unsupported &&
    result.reason == PowerOrchestrator.quietPeriodReason;

/// The state [command] asks for: `true` or `false` for [SetPower], `null`
/// for the power key (`PressKey(RemoteKey.power)`), which asks for "the
/// other state".
bool? wantedPower(Command command) => switch (command) {
  SetPower(:final on) => on,
  _ => null,
};

/// The command to send once the user has said whether the TV is on
/// ([observedOn]), marked as confirmed so the engine may send a toggle, or
/// `null` when nothing should be sent.
///
/// For the power key ([wanted] is `null`) it is the opposite of what they
/// saw. For a discrete power command ([wanted] is the state it asked for)
/// it is that command while the TV is in the other state, and nothing once
/// the TV is already where the user wants it: "Power on" never turns the
/// TV off.
SetPower? confirmedPowerCommand({required bool observedOn, bool? wanted}) =>
    wanted == observedOn ? null : SetPower(!observedOn, userConfirmed: true);

/// Asks the user whether the TV is on right now, for a power command that
/// asks for [wanted] (`null` for the power key; see [wantedPower]).
///
/// Returns `true` when they say it is on, `false` when they say it is off,
/// and `null` when they cancel.
Future<bool?> askWhetherTvIsOn(BuildContext context, {bool? wanted}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => PowerConfirmationDialog(wanted: wanted),
    );

/// "watchme can't tell whether the TV is on. Is it on right now?"
///
/// Pops `true` when the user says the TV is on, `false` when they say it is
/// off, and `null` for Cancel. The answers name what follows from them:
///
/// * The power key ([wanted] `null`): "It's on, turn it off" and "It's
///   off, turn it on".
/// * Power on ([wanted] `true`): "It's off, turn it on" and "It's already
///   on", which sends nothing.
/// * Power off ([wanted] `false`): "It's on, turn it off" and "It's already
///   off", which sends nothing.
class PowerConfirmationDialog extends StatelessWidget {
  /// Creates the dialog for a power command that asks for [wanted].
  const PowerConfirmationDialog({super.key, this.wanted});

  /// The state the command asks for, or `null` for the power key.
  final bool? wanted;

  @override
  Widget build(BuildContext context) {
    TextButton answer(bool isOn, String label) => TextButton(
      onPressed: () => Navigator.of(context).pop(isOn),
      child: Text(label),
    );
    final on = answer(
      true,
      wanted == true ? "It's already on" : "It's on, turn it off",
    );
    final off = answer(
      false,
      wanted == false ? "It's already off" : "It's off, turn it on",
    );
    return AlertDialog(
      icon: const Icon(Icons.power_settings_new),
      title: const Text('Is the TV on?'),
      content: const Text(
        "watchme can't tell whether the TV is on. Is it on right now?",
      ),
      actions: [
        // What the user asked for comes first.
        if (wanted == true) ...[off, on] else ...[on, off],
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
