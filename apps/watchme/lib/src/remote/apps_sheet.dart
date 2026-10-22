import 'package:flutter/material.dart';
import 'package:watchme_core/watchme_core.dart';

import '../widgets/command_feedback.dart';

/// Shows the TV's apps and inputs in a bottom sheet and returns the entry
/// the user picked (null when dismissed). The list comes from [loadApps],
/// which sends [ListApps].
///
/// With [canLaunch] false the list is read-only.
Future<AppInfo?> showAppsSheet(
  BuildContext context, {
  required Future<CommandResult> Function() loadApps,
  required bool canLaunch,
}) => showModalBottomSheet<AppInfo>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    minChildSize: 0.3,
    maxChildSize: 0.95,
    builder: (context, scrollController) => AppsSheet(
      loadApps: loadApps,
      canLaunch: canLaunch,
      scrollController: scrollController,
    ),
  ),
);

/// The body of the apps sheet.
class AppsSheet extends StatefulWidget {
  /// Creates the sheet body.
  const AppsSheet({
    super.key,
    required this.loadApps,
    required this.canLaunch,
    this.scrollController,
  });

  /// Sends [ListApps].
  final Future<CommandResult> Function() loadApps;

  /// Whether entries can be launched.
  final bool canLaunch;

  /// The draggable sheet's scroll controller.
  final ScrollController? scrollController;

  @override
  State<AppsSheet> createState() => _AppsSheetState();
}

class _AppsSheetState extends State<AppsSheet> {
  late Future<CommandResult> _result = _load();

  Future<CommandResult> _load() async {
    try {
      return await widget.loadApps();
    } on WatchmeError catch (error) {
      return Failed(error);
    }
  }

  void _reload() => setState(() => _result = _load());

  @override
  Widget build(BuildContext context) => FutureBuilder<CommandResult>(
    future: _result,
    builder: (context, snapshot) {
      final result = snapshot.data;
      if (result == null) {
        return const Center(
          child: CircularProgressIndicator(semanticsLabel: 'Loading apps'),
        );
      }
      return switch (result) {
        Confirmed(payload: AppListPayload(:final apps)) => _list(apps),
        Failed(:final error) => _Problem(
          title: 'Apps could not be listed',
          text: error.message,
          raw: error.rawDeviceMessage,
          onRetry: _reload,
        ),
        Unsupported(:final reason) => _Problem(
          title: 'This TV cannot list its apps',
          text: reason,
        ),
        Confirmed() || SentUnconfirmed() => _Problem(
          title: 'No app list came back',
          text: 'The TV answered without a list of apps.',
          onRetry: _reload,
        ),
      };
    },
  );

  Widget _list(List<AppInfo> entries) {
    final apps = [
      for (final a in entries)
        if (a.kind != AppKind.input) a,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final inputs = [
      for (final a in entries)
        if (a.kind == AppKind.input) a,
    ];
    if (entries.isEmpty) {
      return const _Problem(
        title: 'No apps',
        text: 'The TV reported no installed apps.',
      );
    }
    return ListView(
      controller: widget.scrollController,
      children: [
        if (!widget.canLaunch)
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('This TV lists apps but cannot launch them.'),
          ),
        if (apps.isNotEmpty) const _Header('Apps'),
        for (final app in apps) _tile(app),
        if (inputs.isNotEmpty) const _Header('Inputs'),
        for (final input in inputs) _tile(input),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _tile(AppInfo app) => ListTile(
    leading: Icon(switch (app.kind) {
      AppKind.app => Icons.apps,
      AppKind.input => Icons.input,
      AppKind.other => Icons.widgets_outlined,
    }),
    title: Text(app.name),
    subtitle: app.version == null ? null : Text('Version ${app.version}'),
    enabled: widget.canLaunch,
    onTap: () => Navigator.of(context).pop(app),
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Semantics(
      header: true,
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    ),
  );
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.title,
    required this.text,
    this.raw,
    this.onRetry,
  });

  final String title;
  final String text;
  final String? raw;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final raw = this.raw;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(text),
        if (raw != null && raw.isNotEmpty) ...[
          const SizedBox(height: 12),
          RawDeviceMessage(raw),
        ],
        if (onRetry != null) ...[
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ),
        ],
      ],
    );
  }
}
