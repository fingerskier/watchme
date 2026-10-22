import 'package:flutter/material.dart';
import 'package:watchme_core/watchme_core.dart';

import '../devices_controller.dart';
import '../pairing/pairing_screen.dart';
import '../remote/remote_screen.dart';
import '../widgets/command_feedback.dart';
import 'add_device_dialog.dart';
import 'device_card.dart';

/// The home screen: every known TV, a scan button, and "Add by IP".
class DevicesScreen extends StatefulWidget {
  /// Creates the screen.
  const DevicesScreen({super.key, this.demo = false, this.scanOnStart = false});

  /// Whether the client simulates TVs.
  final bool demo;

  /// Whether to scan once the screen first appears.
  final bool scanOnStart;

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.scanOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scan();
      });
    }
  }

  Future<void> _scan() async {
    try {
      await WatchmeScope.read(context).scan();
    } on WatchmeError catch (error) {
      if (mounted) showErrorFeedback(context, error);
    }
  }

  Future<void> _addByAddress() async {
    final device = await showAddDeviceDialog(context);
    if (device == null || !mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${device.name}')));
  }

  void _openRemote(DeviceView device) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RemoteScreen(deviceId: device.id),
      ),
    );
  }

  void _pair(DeviceView device, DriverView driver) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PairingScreen(deviceId: device.id, driverId: driver.driverId),
      ),
    );
  }

  Future<void> _onMenu(DeviceView device, DeviceMenuAction action) async {
    final client = WatchmeScope.read(context).client;
    try {
      switch (action) {
        case DeviceMenuAction.remote:
          _openRemote(device);
        case DeviceMenuAction.refresh:
          await client.refresh(device.id);
        case DeviceMenuAction.forget:
          if (await _confirmForget(device)) {
            await client.forget(device.id);
            if (mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(content: Text('Forgot ${device.name}')),
                );
            }
          }
      }
    } on WatchmeError catch (error) {
      if (mounted) showErrorFeedback(context, error);
    }
  }

  Future<bool> _confirmForget(DeviceView device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget ${device.name}?'),
        content: const Text(
          'watchme deletes its pairing for this TV. A scan finds it again, '
          'but TVs that pair will need pairing again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = WatchmeScope.of(context);
    final scanning = controller.scanning;
    final devices = controller.devices;
    final error = controller.error;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('watchme'),
            if (widget.demo) ...[const SizedBox(width: 12), const _DemoBadge()],
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.tonalIcon(
              onPressed: scanning ? null : _scan,
              icon: scanning
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.radar),
              label: Text(scanning ? 'Scanning…' : 'Scan'),
            ),
          ),
        ],
        bottom: scanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(
                  semanticsLabel: 'Scanning for TVs',
                ),
              )
            : null,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addByAddress,
        icon: const Icon(Icons.add),
        label: const Text('Add by IP'),
        tooltip: 'Add a TV by IP address',
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _scan,
          child: !controller.loaded
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    _Centered(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (error != null) ...[
                            _ListError(error: error),
                            const SizedBox(height: 12),
                          ],
                          if (devices.isEmpty)
                            _EmptyState(
                              scanning: scanning,
                              onScan: _scan,
                              onAdd: _addByAddress,
                            )
                          else
                            for (final device in devices) ...[
                              DeviceCard(
                                key: ValueKey(device.id),
                                device: device,
                                onOpen: () => _openRemote(device),
                                onPair: (driver) => _pair(device, driver),
                                onMenu: (action) => _onMenu(device, action),
                              ),
                              const SizedBox(height: 12),
                            ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Keeps content readable on wide windows.
class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: child,
    ),
  );
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          'Demo mode: two simulated TVs and no network traffic. The Fire TV '
          'PIN is 1234.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Demo',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: scheme.onTertiaryContainer),
        ),
      ),
    );
  }
}

class _ListError extends StatelessWidget {
  const _ListError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = switch (error) {
      WatchmeError(:final message) => message,
      _ => '$error',
    };
    return Card(
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.error_outline, color: scheme.onErrorContainer),
        title: Text(
          "The device list couldn't be updated",
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: Text(
          message,
          style: TextStyle(color: scheme.onErrorContainer),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.scanning,
    required this.onScan,
    required this.onAdd,
  });

  final bool scanning;
  final VoidCallback onScan;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        Icon(Icons.connected_tv, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text(
          scanning ? 'Looking for TVs…' : 'No TVs yet',
          style: theme.textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'watchme finds TVs on your local network with SSDP and mDNS. Keep '
          'this device on the same network as the TV, turn the TV on, then '
          'scan. If a TV does not show up, add it by its IP address.',
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 12,
          runSpacing: 12,
          children: [
            FilledButton.icon(
              onPressed: scanning ? null : onScan,
              icon: const Icon(Icons.radar),
              label: const Text('Scan for TVs'),
            ),
            OutlinedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add by IP address'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const _Tip(
          icon: Icons.settings_remote,
          title: 'Roku',
          text:
              'Open Settings > System > Advanced system settings > Control by '
              'mobile apps and choose Enabled. In Limited mode, the default on '
              'recent firmware, watchme can see the TV but the TV refuses key '
              'presses.',
        ),
        const SizedBox(height: 12),
        const _Tip(
          icon: Icons.pin_outlined,
          title: 'Fire TV',
          text:
              'Fire TV pairs with a PIN shown on the TV. Keep the TV on while '
              'you pair.',
        ),
        const SizedBox(height: 12),
        const _Tip(
          icon: Icons.pin_outlined,
          title: 'VIZIO',
          text:
              'VIZIO SmartCast TVs pair with a PIN shown on the TV. To turn '
              'the TV on from watchme, set System > Power Mode to Quick '
              'Start.',
        ),
        const SizedBox(height: 12),
        const _Tip(
          icon: Icons.settings_remote,
          title: 'Panasonic VIERA',
          text:
              'Turn on TV Remote in Menu > Network > TV Remote App Settings. '
              'Sets from 2018 on pair with a PIN shown on the TV. The TV '
              'answers only devices on its own subnet.',
        ),
        const SizedBox(height: 12),
        const _Tip(
          icon: Icons.lan_outlined,
          title: 'Sharp AQUOS',
          text:
              'Turn on AQUOS Remote Control (IP Control on some models) in '
              "the TV's network settings. If you set a login there, watchme "
              'asks for it when you pair.',
        ),
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(text),
      isThreeLine: true,
    ),
  );
}
