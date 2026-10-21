import 'package:flutter/material.dart';
import 'package:watchme_core/watchme_core.dart';

import '../devices_controller.dart';
import '../widgets/command_feedback.dart';
import '../widgets/labels.dart';
import 'host_input.dart';

/// Asks for an address, probes it through the client, and returns the
/// device that answered (null when the user cancels).
Future<DeviceView?> showAddDeviceDialog(BuildContext context) =>
    showDialog<DeviceView>(
      context: context,
      builder: (_) => const AddDeviceDialog(),
    );

/// What to do about an address watchme refused because it is not on the
/// local network (public, carrier-grade NAT or VPN, reserved, broadcast).
const String _offLanHint =
    "Check the address in the TV's network settings. Addresses on a home "
    'network usually start with 192.168., 10. or 172.16. to 172.31.';

/// The "Add by IP address" dialog.
class AddDeviceDialog extends StatefulWidget {
  /// Creates the dialog.
  const AddDeviceDialog({super.key});

  @override
  State<AddDeviceDialog> createState() => _AddDeviceDialogState();
}

class _AddDeviceDialogState extends State<AddDeviceDialog> {
  final _formKey = GlobalKey<FormState>();
  final _host = TextEditingController();
  bool _busy = false;
  String? _probing;
  WatchmeError? _error;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_formKey.currentState?.validate() ?? false)) return;
    final host = normalizeHostInput(_host.text);
    final client = WatchmeScope.read(context).client;
    setState(() {
      _busy = true;
      _probing = host;
      _error = null;
    });
    try {
      final device = await client.addManual(host);
      if (mounted) Navigator.of(context).pop(device);
    } on WatchmeError catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    final raw = error?.rawDeviceMessage;
    return AlertDialog(
      title: const Text('Add a TV by IP address'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Use the address in the TV's network settings. Roku TVs "
                'accept only an IP address, not a host name.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _host,
                autofocus: true,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'IP address or host name',
                  hintText: '192.168.1.20',
                  border: OutlineInputBorder(),
                ),
                validator: validateHostInput,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  semanticsLabel: 'Looking for a TV at $_probing',
                ),
                const SizedBox(height: 8),
                Text('Looking for a TV at $_probing…'),
              ],
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  errorCodeLabel(error.code),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
                const SizedBox(height: 4),
                Text(error.message),
                if (error.code == WatchmeErrorCode.destinationRefused) ...[
                  const SizedBox(height: 8),
                  const Text(_offLanHint),
                ],
                if (raw != null && raw.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  RawDeviceMessage(raw),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        // Cancel stays enabled while probing: a TV that never answers would
        // otherwise hold the dialog until the engine's timeout.
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}
