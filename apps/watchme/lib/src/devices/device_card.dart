import 'package:flutter/material.dart' hide ConnectionState;
import 'package:watchme_core/watchme_core.dart';

import '../widgets/command_feedback.dart';
import '../widgets/labels.dart';

/// Actions a device card offers from its menu.
enum DeviceMenuAction {
  /// Open the remote.
  remote,

  /// Re-read the device's state.
  refresh,

  /// Forget the device.
  forget,
}

/// One device in the list: name, make and model, address, a status, one
/// chip per driver, and anything the user must fix on the TV.
class DeviceCard extends StatelessWidget {
  /// Creates a card.
  const DeviceCard({
    super.key,
    required this.device,
    required this.onOpen,
    required this.onPair,
    required this.onMenu,
  });

  /// The device shown.
  final DeviceView device;

  /// Opens the remote.
  final VoidCallback onOpen;

  /// Starts pairing a driver.
  final ValueChanged<DriverView> onPair;

  /// Runs a menu action.
  final ValueChanged<DeviceMenuAction> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final makeModel = makeAndModel(device);
    final toPair = [
      for (final d in device.drivers)
        if (d.needsPairing) d,
    ];
    final status = deviceStatusLabel(device);
    final statusColor = device.connected
        ? scheme.primary
        : device.needsPairing
        ? scheme.tertiary
        : scheme.outline;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    device.connected ? Icons.tv : Icons.tv_off,
                    color: statusColor,
                    size: 32,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(device.name, style: theme.textTheme.titleMedium),
                        Text(
                          [?makeModel, device.host].join(' · '),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (toPair.isNotEmpty)
                    FilledButton.tonal(
                      onPressed: () => onPair(toPair.first),
                      child: Text(
                        'Pair',
                        semanticsLabel: 'Pair ${device.name}',
                      ),
                    ),
                  _DeviceMenu(device: device, onMenu: onMenu, onPair: onPair),
                ],
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _StatusPill(label: status, color: statusColor),
                    for (final driver in device.drivers)
                      _DriverChip(driver: driver),
                  ],
                ),
              ),
              for (final driver in device.drivers)
                ..._driverNotices(context, driver),
            ],
          ),
        ),
      ),
    );
  }

  /// Notes, the last error and (when the driver is not working) the TV
  /// settings it depends on.
  List<Widget> _driverNotices(BuildContext context, DriverView driver) {
    final error = driver.lastError;
    final raw = error?.rawDeviceMessage;
    final showSetup = !driver.connected && !driver.needsPairing;
    return [
      for (final note in driver.notes)
        _Notice(icon: Icons.info_outline, text: note),
      if (error != null)
        _Notice(
          icon: Icons.error_outline,
          text: '${driver.protocol}: ${error.message}',
          isError: true,
        ),
      if (raw != null && raw.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8, right: 12),
          child: RawDeviceMessage(raw),
        ),
      if (showSetup)
        for (final step in driver.setup)
          _Notice(
            icon: Icons.settings_outlined,
            text: [step.title, ?step.detail].join('\n'),
          ),
    ];
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, size: 10, color: color),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.labelLarge),
    ],
  );
}

class _DriverChip extends StatelessWidget {
  const _DriverChip({required this.driver});

  final DriverView driver;

  @override
  Widget build(BuildContext context) {
    final (icon, detail) = switch (driver) {
      DriverView(connected: true) => (Icons.link, 'connected'),
      DriverView(needsPairing: true) => (Icons.lock_outline, 'needs pairing'),
      DriverView(connection: ConnectionState.failed) => (
        Icons.error_outline,
        'connection failed',
      ),
      DriverView(paired: true) when driver.canPair => (
        Icons.verified_outlined,
        'paired, ${connectionLabel(driver.connection).toLowerCase()}',
      ),
      _ => (Icons.link_off, connectionLabel(driver.connection).toLowerCase()),
    };
    return Tooltip(
      message: '${driver.protocol}: $detail',
      child: Chip(
        avatar: Icon(icon, size: 18),
        label: Text(driver.protocol),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.isError = false});

  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The menu item that starts pairing [driver]: "Pair" for a driver that
/// needs it, "Set up" for one that offers it for optional settings.
String pairMenuLabel(DriverView driver) {
  final verb = driver.requiresPairing ? 'Pair' : 'Set up';
  return driver.paired
      ? '$verb ${driver.protocol} again'
      : '$verb ${driver.protocol}';
}

class _DeviceMenu extends StatelessWidget {
  const _DeviceMenu({
    required this.device,
    required this.onMenu,
    required this.onPair,
  });

  final DeviceView device;
  final ValueChanged<DeviceMenuAction> onMenu;
  final ValueChanged<DriverView> onPair;

  @override
  Widget build(BuildContext context) {
    // Drivers that need pairing, and those that offer it for optional
    // set-up (a Sharp AQUOS's login or network power-on).
    final pairable = [
      for (final d in device.drivers)
        if (d.canPair) d,
    ];
    return PopupMenuButton<Object>(
      tooltip: 'More actions for ${device.name}',
      onSelected: (choice) => switch (choice) {
        final DriverView driver => onPair(driver),
        final DeviceMenuAction action => onMenu(action),
        _ => null,
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: DeviceMenuAction.remote,
          child: ListTile(
            leading: Icon(Icons.settings_remote),
            title: Text('Open remote'),
          ),
        ),
        for (final driver in pairable)
          PopupMenuItem(
            value: driver,
            child: ListTile(
              leading: const Icon(Icons.add_link),
              title: Text(pairMenuLabel(driver)),
            ),
          ),
        const PopupMenuItem(
          value: DeviceMenuAction.refresh,
          child: ListTile(
            leading: Icon(Icons.refresh),
            title: Text('Refresh status'),
          ),
        ),
        const PopupMenuItem(
          value: DeviceMenuAction.forget,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('Forget'),
          ),
        ),
      ],
    );
  }
}
