import 'package:flutter/material.dart';
import 'package:watchme_core/watchme_core.dart';

/// What the user should be told about a [CommandResult], or null when the
/// result needs no comment.
///
/// [label] names the control, e.g. "Volume up".
({String title, String? detail})? describeCommandResult(
  CommandResult result, {
  required String label,
}) => switch (result) {
  // A write-only path (IR, no-cors) cannot confirm anything, so silence is
  // the honest answer; a snackbar per key press would be noise.
  Confirmed() || SentUnconfirmed() => null,
  Unsupported(reason: Unsupported.needsConfirmation) => (
    title: '$label was not sent',
    detail:
        "watchme couldn't confirm whether the TV is on, so it did not send a "
        'power toggle that might do the opposite. Check the TV and try again.',
  ),
  Unsupported(:final reason) => (
    title: '$label is not available',
    detail: reason,
  ),
  Failed(:final error) => (
    title: '$label failed: ${error.message}',
    detail: switch (error.rawDeviceMessage) {
      null || '' => null,
      final raw => 'TV said: $raw',
    },
  ),
};

/// Shows a snackbar for [result] when it is [Unsupported] or [Failed],
/// replacing any snackbar still on screen so rapid presses do not queue.
void showCommandFeedback(
  BuildContext context,
  CommandResult result, {
  required String label,
}) {
  final text = describeCommandResult(result, label: label);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (text == null || messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: FeedbackText(title: text.title, detail: text.detail),
        duration: Duration(seconds: result is Failed ? 6 : 4),
      ),
    );
}

/// Shows a snackbar for an error thrown by the client (scan, add, forget).
void showErrorFeedback(BuildContext context, WatchmeError error) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: FeedbackText(
          title: error.message,
          detail: switch (error.rawDeviceMessage) {
            null || '' => null,
            final raw => 'TV said: $raw',
          },
        ),
        duration: const Duration(seconds: 6),
      ),
    );
}

/// A snackbar body: a title line and an optional detail line.
class FeedbackText extends StatelessWidget {
  /// Creates the body.
  const FeedbackText({super.key, required this.title, this.detail});

  /// The main line.
  final String title;

  /// A second, smaller line (the reason or the device's raw text).
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final detail = this.detail;
    if (detail == null) return Text(title);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        const SizedBox(height: 4),
        Text(detail, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}

/// The device's own words for an error, in a selectable monospace box so
/// the user can copy them into a bug report.
class RawDeviceMessage extends StatelessWidget {
  /// Creates the box.
  const RawDeviceMessage(this.message, {super.key});

  /// The raw text.
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('The TV said:', style: theme.textTheme.labelMedium),
          const SizedBox(height: 4),
          SelectableText(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontFamilyFallback: const ['Courier New', 'Courier'],
            ),
          ),
        ],
      ),
    );
  }
}
