import 'package:flutter/services.dart';
import 'package:watchme_core/watchme_core.dart';

/// A desktop keyboard shortcut on the Remote screen.
final class RemoteShortcut {
  /// Creates a shortcut.
  const RemoteShortcut({
    required this.keys,
    required this.keysLabel,
    required this.label,
    required this.command,
    this.holdKey,
    this.optional = false,
  });

  /// Keyboard keys that trigger it.
  final List<LogicalKeyboardKey> keys;

  /// How the help lists the keys, e.g. "Backspace, Esc".
  final String keysLabel;

  /// What it does, e.g. "Back"; also the label in result messages.
  final String label;

  /// The command a press sends.
  final Command command;

  /// For keys that repeat on the TV while held: the remote key to send as
  /// key-down when the keyboard starts auto-repeating, and key-up on release.
  final RemoteKey? holdKey;

  /// Whether the matching on-screen control is optional (see `gateFor`).
  final bool optional;

  /// The capability that must be usable for the shortcut to act.
  Capability get capability => command.capability;
}

/// Every Remote screen shortcut, in the order the help lists them.
///
/// Esc means Back because desktop users reach for it to "go back"; Home has
/// its own keys (H and the Home key). Escape on a focused button or the text
/// field first returns keyboard control to the remote.
const List<RemoteShortcut> remoteShortcuts = [
  RemoteShortcut(
    keys: [LogicalKeyboardKey.arrowUp],
    keysLabel: '↑',
    label: 'Up',
    command: PressKey(RemoteKey.up),
    holdKey: RemoteKey.up,
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.arrowDown],
    keysLabel: '↓',
    label: 'Down',
    command: PressKey(RemoteKey.down),
    holdKey: RemoteKey.down,
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.arrowLeft],
    keysLabel: '←',
    label: 'Left',
    command: PressKey(RemoteKey.left),
    holdKey: RemoteKey.left,
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.arrowRight],
    keysLabel: '→',
    label: 'Right',
    command: PressKey(RemoteKey.right),
    holdKey: RemoteKey.right,
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter],
    keysLabel: 'Enter',
    label: 'OK',
    command: PressKey(RemoteKey.select),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.backspace, LogicalKeyboardKey.escape],
    keysLabel: 'Backspace, Esc',
    label: 'Back',
    command: PressKey(RemoteKey.back),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.keyH, LogicalKeyboardKey.home],
    keysLabel: 'H, Home',
    label: 'Home',
    command: PressKey(RemoteKey.home),
  ),
  RemoteShortcut(
    keys: [
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.add,
      LogicalKeyboardKey.numpadAdd,
    ],
    keysLabel: '+',
    label: 'Volume up',
    command: PressKey(RemoteKey.volumeUp),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.minus, LogicalKeyboardKey.numpadSubtract],
    keysLabel: '−',
    label: 'Volume down',
    command: PressKey(RemoteKey.volumeDown),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.keyM],
    keysLabel: 'M',
    label: 'Mute',
    command: PressKey(RemoteKey.mute),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.space],
    keysLabel: 'Space',
    label: 'Play/pause',
    command: Media(MediaAction.playPause),
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.pageUp],
    keysLabel: 'Page Up',
    label: 'Channel up',
    command: PressKey(RemoteKey.channelUp),
    optional: true,
  ),
  RemoteShortcut(
    keys: [LogicalKeyboardKey.pageDown],
    keysLabel: 'Page Down',
    label: 'Channel down',
    command: PressKey(RemoteKey.channelDown),
    optional: true,
  ),
];

/// The shortcut for [key], or null.
RemoteShortcut? remoteShortcutFor(LogicalKeyboardKey key) {
  for (final shortcut in remoteShortcuts) {
    if (shortcut.keys.contains(key)) return shortcut;
  }
  return null;
}

/// The help text for the shortcuts tooltip and dialog.
String remoteShortcutsHelp() => [
  'Keyboard shortcuts',
  for (final s in remoteShortcuts) '${s.keysLabel}: ${s.label}',
  'Hold an arrow key to repeat it on the TV.',
  'Tab moves between buttons; Esc returns to TV control.',
].join('\n');
