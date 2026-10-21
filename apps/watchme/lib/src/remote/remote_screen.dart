import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:watchme_core/watchme_core.dart';

import '../devices_controller.dart';
import '../pairing/pairing_screen.dart';
import '../widgets/command_feedback.dart';
import '../widgets/labels.dart';
import 'apps_sheet.dart';
import 'capability_gate.dart';
import 'remote_button.dart';
import 'remote_shortcuts.dart';

/// The remote control for one device.
///
/// Controls are shown, greyed out or hidden from the device's merged
/// capabilities (see [gateFor]). Results that the user should hear about
/// ([Unsupported], [Failed]) appear in a snackbar; [SentUnconfirmed] is
/// silent. On desktop the keyboard drives the TV (see [remoteShortcuts]).
class RemoteScreen extends StatefulWidget {
  /// Creates the remote for [deviceId].
  const RemoteScreen({super.key, required this.deviceId});

  /// The device controlled.
  final String deviceId;

  @override
  State<RemoteScreen> createState() => _RemoteScreenState();
}

class _RemoteScreenState extends State<RemoteScreen> {
  final FocusNode _remoteFocus = FocusNode(debugLabel: 'TV keyboard control');
  final TextEditingController _text = TextEditingController();

  /// Keyboard keys whose key-down this screen saw.
  final Set<LogicalKeyboardKey> _pressed = {};

  /// Keyboard keys being held, with the remote key sent as key-down.
  final Map<LogicalKeyboardKey, RemoteKey> _held = {};

  late WatchmeClient _client;
  DeviceView? _device;

  @override
  void dispose() {
    // Release anything still held so the TV stops repeating.
    for (final key in _held.values) {
      unawaited(_deliver(PressKey(key, KeyAction.up)));
    }
    _remoteFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<CommandResult> _deliver(Command command) async {
    try {
      return await _client.send(widget.deviceId, command);
    } on WatchmeError catch (error) {
      return Failed(error);
    } on Object catch (error) {
      return Failed(WatchmeError.internal('$error', cause: error));
    }
  }

  /// Sends [command] and reports the result under [label].
  Future<CommandResult> _send(Command command, String label) async {
    final result = await _deliver(command);
    if (mounted) showCommandFeedback(context, result, label: label);
    return result;
  }

  Future<void> _sendText() async {
    final text = _text.text;
    if (text.isEmpty) return;
    final result = await _send(TypeText(text), 'Text');
    // Typing can take a while (Roku sends one request per character); the
    // user may have left the remote, and its controller is gone.
    if (!mounted) return;
    // Keep the text after a failure so the user can retry without retyping.
    if (result.delivered && _text.text == text) _text.clear();
  }

  Future<void> _refresh() async {
    try {
      await _client.refresh(widget.deviceId);
    } on WatchmeError catch (error) {
      if (mounted) showErrorFeedback(context, error);
    }
  }

  Future<void> _openApps(DeviceView device) async {
    final app = await showAppsSheet(
      context,
      loadApps: () => _deliver(const ListApps()),
      canLaunch:
          gateFor(device, Capability.appLaunch, optional: true) ==
          ControlGate.enabled,
    );
    if (app == null || !mounted) return;
    await _send(LaunchApp(app.id), 'Open ${app.name}');
  }

  void _pair(DriverView driver) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            PairingScreen(deviceId: widget.deviceId, driverId: driver.driverId),
      ),
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    // A hold always ends on the TV, even if the control was disabled or
    // hidden meanwhile (e.g. a Roku switched to Limited mode) or focus
    // moved; otherwise the TV keeps repeating the key.
    if (event is KeyUpEvent && _held.containsKey(key)) {
      _pressed.remove(key);
      final held = _held.remove(key)!;
      unawaited(
        _send(
          PressKey(held, KeyAction.up),
          remoteShortcutFor(key)?.label ?? held.name,
        ),
      );
      return KeyEventResult.handled;
    }
    if (!node.hasPrimaryFocus) {
      // A focused button or the text field keeps its normal keys; Esc hands
      // the keyboard back to the TV.
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        node.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final shortcut = remoteShortcutFor(key);
    final device = _device;
    if (shortcut == null || device == null) return KeyEventResult.ignored;
    final gate = gateFor(
      device,
      shortcut.capability,
      optional: shortcut.optional,
    );
    if (gate != ControlGate.enabled) {
      _pressed.remove(key);
      return KeyEventResult.handled;
    }
    final hold = shortcut.holdKey;
    switch (event) {
      case KeyDownEvent():
        _pressed.add(key);
        if (hold == null) unawaited(_send(shortcut.command, shortcut.label));
      case KeyRepeatEvent():
        // The first auto-repeat turns a press into a hold; the TV repeats
        // from here until key-up, so later repeats are dropped.
        if (hold != null && _pressed.contains(key) && !_held.containsKey(key)) {
          _held[key] = hold;
          unawaited(_send(PressKey(hold, KeyAction.down), shortcut.label));
        }
      case KeyUpEvent():
        // Held keys were released above; a short press is a click.
        if (_pressed.remove(key) && hold != null) {
          unawaited(_send(shortcut.command, shortcut.label));
        }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final controller = WatchmeScope.of(context);
    _client = controller.client;
    final device = _device = controller.byId(widget.deviceId);
    if (device == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Remote')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'This TV is no longer in your device list.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(device.name),
        actions: [
          const _ShortcutsHelpButton(),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh status',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: Focus(
          focusNode: _remoteFocus,
          autofocus: true,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              final left = _primaryControls(device);
              final right = _secondaryControls(device);
              return SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: wide ? 920 : 440),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ..._notices(device),
                        _StatusLine(device: device),
                        const SizedBox(height: 16),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _column(left)),
                              const SizedBox(width: 32),
                              Expanded(child: _column(right)),
                            ],
                          )
                        else
                          _column([...left, ...right]),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _column(List<Widget> children) => FocusTraversalGroup(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final child in children) ...[child, const SizedBox(height: 24)],
      ],
    ),
  );

  List<Widget> _notices(DeviceView device) {
    final toPair = device.drivers.where((d) => d.needsPairing).firstOrNull;
    if (toPair != null) {
      return [
        _Banner(
          icon: Icons.lock_outline,
          text: 'Pair ${toPair.protocol} before this TV accepts commands.',
          action: FilledButton(
            onPressed: () => _pair(toPair),
            child: const Text('Pair'),
          ),
        ),
        const SizedBox(height: 16),
      ];
    }
    if (device.connected) return const [];
    return [
      for (final driver in device.drivers)
        _Banner(
          icon: Icons.link_off,
          text: [
            '${driver.protocol}: ${connectionLabel(driver.connection)}.',
            ?driver.lastError?.message,
            ...driver.notes,
            for (final step in driver.setup) 'Check on the TV: ${step.title}',
          ].join('\n'),
          raw: driver.lastError?.rawDeviceMessage,
        ),
      const SizedBox(height: 16),
    ];
  }

  /// A remote key for [command], or null when its capability hides it.
  Widget? _key(
    DeviceView device, {
    required Command command,
    required IconData icon,
    required String label,
    bool optional = false,
    RemoteKey? holdKey,
    String? caption,
    double size = 64,
    bool circular = false,
    RemoteButtonTone tone = RemoteButtonTone.standard,
  }) {
    final gate = gateFor(device, command.capability, optional: optional);
    if (!gate.visible) return null;
    final enabled = gate == ControlGate.enabled;
    return RemoteButton(
      icon: icon,
      label: label,
      caption: caption,
      width: size,
      height: size,
      circular: circular,
      tone: tone,
      onPressed: enabled ? () => _send(command, label) : null,
      onHoldStart: holdKey == null
          ? null
          : () => _send(PressKey(holdKey, KeyAction.down), label),
      onHoldEnd: holdKey == null
          ? null
          : () => _send(PressKey(holdKey, KeyAction.up), label),
    );
  }

  Widget? _row(List<Widget?> keys) {
    final visible = keys.nonNulls.toList();
    if (visible.isEmpty) return null;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 16,
      children: visible,
    );
  }

  List<Widget> _primaryControls(DeviceView device) => [
    ?_row([
      _key(
        device,
        command: const SetPower(true),
        icon: Icons.power_settings_new,
        label: 'Power on',
        caption: 'ON',
      ),
      _key(
        device,
        command: const SetPower(false),
        icon: Icons.power_settings_new,
        label: 'Power off',
        caption: 'OFF',
        tone: RemoteButtonTone.danger,
      ),
    ]),
    ?_dpad(device),
    ?_row([
      _key(
        device,
        command: const PressKey(RemoteKey.back),
        icon: Icons.arrow_back,
        // The app bar already has a "Back" that leaves this screen.
        label: 'Back (TV)',
      ),
      _key(
        device,
        command: const PressKey(RemoteKey.home),
        icon: Icons.home_outlined,
        label: 'Home',
      ),
      _key(
        device,
        command: const PressKey(RemoteKey.menu),
        icon: Icons.menu,
        label: 'Menu',
      ),
    ]),
  ];

  Widget? _dpad(DeviceView device) {
    Widget? arrow(RemoteKey key, IconData icon, String label) => _key(
      device,
      command: PressKey(key),
      icon: icon,
      label: label,
      holdKey: key,
      size: 72,
    );
    final up = arrow(RemoteKey.up, Icons.keyboard_arrow_up, 'Up');
    final down = arrow(RemoteKey.down, Icons.keyboard_arrow_down, 'Down');
    final left = arrow(RemoteKey.left, Icons.keyboard_arrow_left, 'Left');
    final right = arrow(RemoteKey.right, Icons.keyboard_arrow_right, 'Right');
    final ok = _key(
      device,
      command: const PressKey(RemoteKey.select),
      icon: Icons.circle_outlined,
      label: 'OK',
      caption: 'OK',
      size: 80,
      circular: true,
      tone: RemoteButtonTone.primary,
    );
    if (up == null || down == null || left == null || right == null) {
      return null;
    }
    const gap = SizedBox.square(dimension: 8);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          up,
          gap,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [left, gap, ?ok, gap, right],
          ),
          gap,
          down,
        ],
      ),
    );
  }

  List<Widget> _secondaryControls(DeviceView device) => [
    ?_row([
      _key(
        device,
        command: const PressKey(RemoteKey.volumeDown),
        icon: Icons.volume_down,
        label: 'Volume down',
      ),
      _key(
        device,
        command: const PressKey(RemoteKey.mute),
        icon: Icons.volume_off,
        label: 'Mute',
      ),
      _key(
        device,
        command: const PressKey(RemoteKey.volumeUp),
        icon: Icons.volume_up,
        label: 'Volume up',
      ),
    ]),
    ?_row([
      _key(
        device,
        command: const PressKey(RemoteKey.channelDown),
        icon: Icons.keyboard_arrow_down,
        label: 'Channel down',
        caption: 'CH',
        optional: true,
      ),
      _key(
        device,
        command: const PressKey(RemoteKey.channelUp),
        icon: Icons.keyboard_arrow_up,
        label: 'Channel up',
        caption: 'CH',
        optional: true,
      ),
    ]),
    ?_row([
      _key(
        device,
        command: const Media(MediaAction.rewind),
        icon: Icons.fast_rewind,
        label: 'Rewind',
      ),
      _key(
        device,
        command: const Media(MediaAction.playPause),
        icon: Icons.play_arrow,
        label: 'Play/pause',
      ),
      _key(
        device,
        command: const Media(MediaAction.fastForward),
        icon: Icons.fast_forward,
        label: 'Fast forward',
      ),
    ]),
    ?_textInput(device),
    ?_appsButton(device),
  ];

  Widget? _textInput(DeviceView device) {
    if (gateFor(device, Capability.textInput, optional: true) !=
        ControlGate.enabled) {
      return null;
    }
    final needsKeyboard = device
        .supportOf(Capability.textInput)
        .has(CapFlag.needsKeyboardOpen);
    return TextField(
      controller: _text,
      autocorrect: false,
      textInputAction: TextInputAction.send,
      decoration: InputDecoration(
        labelText: 'Type on the TV',
        helperText: needsKeyboard
            ? 'Open a search or text box on the TV first.'
            : null,
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: const Icon(Icons.send),
          tooltip: 'Send text',
          onPressed: _sendText,
        ),
      ),
      onSubmitted: (_) => _sendText(),
      onTapOutside: (_) => _remoteFocus.requestFocus(),
    );
  }

  Widget? _appsButton(DeviceView device) {
    if (gateFor(device, Capability.appList, optional: true) !=
        ControlGate.enabled) {
      return null;
    }
    return Center(
      child: FilledButton.tonalIcon(
        style: FilledButton.styleFrom(minimumSize: const Size(160, 56)),
        onPressed: () => _openApps(device),
        icon: const Icon(Icons.apps),
        label: const Text('Apps'),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.text,
    this.action,
    this.raw,
  });

  final IconData icon;
  final String text;
  final Widget? action;
  final String? raw;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raw = this.raw;
    final action = this.action;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.onTertiaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(color: scheme.onTertiaryContainer),
                  ),
                ),
                if (action != null) ...[const SizedBox(width: 12), action],
              ],
            ),
            if (raw != null && raw.isNotEmpty) ...[
              const SizedBox(height: 12),
              RawDeviceMessage(raw),
            ],
          ],
        ),
      ),
    );
  }
}

/// What watchme knows about the TV right now, with each value's source in a
/// tooltip.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.device});

  final DeviceView device;

  @override
  Widget build(BuildContext context) {
    final state = device.state;
    final playing = state.nowPlaying?.value.state;
    final items = <(IconData, String, Observed<Object?>?)>[
      if (makeAndModel(device) case final model?) (Icons.tv, model, null),
      if (state.power case final power?)
        (Icons.power_settings_new, powerModeLabel(power.value), power),
      if (state.foregroundApp case final app?)
        (Icons.apps, app.value.name, app),
      if (state.volume case final volume?)
        (Icons.volume_up, 'Volume ${volume.value}', volume),
      if (state.muted case final muted? when muted.value)
        (Icons.volume_off, 'Muted', muted),
      if (playing == PlaybackState.playing || playing == PlaybackState.paused)
        (
          playing == PlaybackState.playing ? Icons.play_arrow : Icons.pause,
          [
            playing == PlaybackState.playing ? 'Playing' : 'Paused',
            ?state.nowPlaying?.value.title,
          ].join(': '),
          state.nowPlaying,
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: [
        for (final (icon, text, observed) in items)
          _StatusChip(icon: icon, text: text, observed: observed),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.text, this.observed});

  final IconData icon;
  final String text;
  final Observed<Object?>? observed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final observed = this.observed;
    final certain =
        observed == null || observed.confidence == Confidence.reported;
    final chip = Chip(
      avatar: Icon(icon, size: 18),
      label: Text(certain ? text : '$text?'),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: theme.colorScheme.outlineVariant),
    );
    if (observed == null) return chip;
    final how = switch (observed.confidence) {
      Confidence.reported => 'Reported by',
      Confidence.inferred => 'Inferred from',
      Confidence.stale => 'Last reported by',
    };
    return Tooltip(message: '$how ${observed.source}', child: chip);
  }
}

class _ShortcutsHelpButton extends StatelessWidget {
  const _ShortcutsHelpButton();

  @override
  Widget build(BuildContext context) => Tooltip(
    message: remoteShortcutsHelp(),
    excludeFromSemantics: true,
    child: IconButton(
      icon: const Icon(
        Icons.keyboard_outlined,
        semanticLabel: 'Keyboard shortcuts',
      ),
      onPressed: () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Keyboard shortcuts'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final s in remoteShortcuts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: Text(
                          s.keysLabel,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      Expanded(child: Text(s.label)),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                'Hold an arrow key to repeat it on the TV. Tab moves between '
                'buttons, and Esc returns the keyboard to TV control. '
                'Shortcuts for controls this TV lacks do nothing.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    ),
  );
}
