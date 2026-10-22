import 'package:flutter/material.dart';

/// Colour roles for [RemoteButton].
enum RemoteButtonTone {
  /// Most keys.
  standard,

  /// The OK key.
  primary,

  /// Power off.
  danger,
}

/// A large, labelled remote key.
///
/// A tap calls [onPressed]. With [onHoldStart] and [onHoldEnd], a long
/// press calls [onHoldStart] when the hold begins and [onHoldEnd] when it
/// ends: the finger lifts, the system cancels the pointer, the button is
/// disabled, or it disappears mid-hold. The remote maps these to key-down
/// and key-up so the TV repeats the key itself.
class RemoteButton extends StatefulWidget {
  /// Creates a button. [label] is the tooltip and the accessibility label.
  const RemoteButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.onHoldStart,
    this.onHoldEnd,
    this.caption,
    this.width = 64,
    this.height = 64,
    this.circular = false,
    this.tone = RemoteButtonTone.standard,
  });

  /// The icon.
  final IconData icon;

  /// Tooltip and accessibility label.
  final String label;

  /// Tap handler; null disables the button.
  final VoidCallback? onPressed;

  /// Called when a long press starts.
  final VoidCallback? onHoldStart;

  /// Called when that long press ends.
  final VoidCallback? onHoldEnd;

  /// Short text under the icon, e.g. "CH".
  final String? caption;

  /// Width of the hit target.
  final double width;

  /// Height of the hit target.
  final double height;

  /// Round instead of rounded-rectangle.
  final bool circular;

  /// Colour role.
  final RemoteButtonTone tone;

  @override
  State<RemoteButton> createState() => _RemoteButtonState();
}

class _RemoteButtonState extends State<RemoteButton> {
  bool _holding = false;

  void _startHold() {
    _holding = true;
    widget.onHoldStart?.call();
  }

  void _endHold() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd?.call();
  }

  @override
  void didUpdateWidget(RemoteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A key that gets disabled mid-hold must still be released on the TV.
    if (widget.onPressed == null && _holding) {
      _holding = false;
      oldWidget.onHoldEnd?.call();
    }
  }

  @override
  void dispose() {
    _endHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null;
    final canHold =
        enabled && widget.onHoldStart != null && widget.onHoldEnd != null;
    final (background, foreground) = !enabled
        ? (
            scheme.onSurface.withValues(alpha: 0.08),
            scheme.onSurface.withValues(alpha: 0.38),
          )
        : switch (widget.tone) {
            RemoteButtonTone.standard => (
              scheme.secondaryContainer,
              scheme.onSecondaryContainer,
            ),
            RemoteButtonTone.primary => (scheme.primary, scheme.onPrimary),
            RemoteButtonTone.danger => (
              scheme.errorContainer,
              scheme.onErrorContainer,
            ),
          };
    final ShapeBorder shape = widget.circular
        ? const CircleBorder()
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(20));
    final caption = widget.caption;

    // Only the tap is exposed to assistive technology. A semantic long-press
    // has no matching release, so offering the hold would leave the TV
    // repeating the key.
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: Material(
          color: background,
          shape: shape,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: shape,
            excludeFromSemantics: true,
            onTap: widget.onPressed,
            onLongPress: canHold ? _startHold : null,
            onLongPressUp: canHold ? _endHold : null,
            child: Listener(
              // The long-press recognizer reports no end for a cancelled
              // pointer (e.g. the system took the gesture), and the TV
              // would keep repeating the key.
              onPointerCancel: (_) => _endHold(),
              child: SizedBox(
                width: widget.width,
                height: widget.height,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(widget.icon, color: foreground, size: 28),
                    if (caption != null)
                      ExcludeSemantics(
                        child: Text(
                          caption,
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
