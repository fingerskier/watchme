import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:watchme_core/watchme_core.dart';

import '../devices_controller.dart';
import '../remote/remote_screen.dart';
import '../widgets/command_feedback.dart';
import '../widgets/labels.dart';

/// Walks the user through pairing one driver with one device, rendering
/// each [PairingStep] the driver emits.
///
/// Leaving the screen before a terminal step cancels the pairing.
class PairingScreen extends StatefulWidget {
  /// Creates the screen; pairing starts at once.
  const PairingScreen({
    super.key,
    required this.deviceId,
    required this.driverId,
  });

  /// The device being paired.
  final String deviceId;

  /// The driver being paired.
  final String driverId;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairingHandle? _handle;
  StreamSubscription<PairingStep>? _subscription;
  PairingStep? _step;
  bool _waitingForDevice = false;
  int _attempt = 0;

  bool get _finished => _step?.isTerminal ?? false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    await _stop();
    if (!mounted) return;
    setState(() {
      _step = null;
      _waitingForDevice = false;
    });
    final client = WatchmeScope.read(context).client;
    try {
      final handle = await client.pair(widget.deviceId, widget.driverId);
      if (!mounted || attempt != _attempt) {
        unawaited(handle.cancel());
        return;
      }
      _handle = handle;
      _subscription = handle.steps.listen(
        _show,
        onError: (Object error) => _show(PairingFailed(_asWatchmeError(error))),
        onDone: () {
          if (!_finished) {
            _show(
              const PairingFailed(
                WatchmeError.internal('Pairing ended without a result.'),
              ),
            );
          }
        },
      );
    } on Object catch (error) {
      if (mounted) _show(PairingFailed(_asWatchmeError(error)));
    }
  }

  Future<void> _stop() async {
    final handle = _handle;
    final subscription = _subscription;
    final finished = _finished;
    _handle = null;
    _subscription = null;
    // Unsubscribe first so the cancellation's own PairingFailed is not shown;
    // nothing depends on the unsubscribe completing.
    unawaited(subscription?.cancel());
    if (handle != null && !finished) await handle.cancel();
  }

  void _show(PairingStep step) {
    if (!mounted) return;
    setState(() {
      _step = step;
      _waitingForDevice = false;
    });
  }

  Future<void> _submit(String value) async {
    final handle = _handle;
    if (handle == null || _finished) return;
    setState(() => _waitingForDevice = true);
    try {
      await handle.submit(value);
    } on Object catch (error) {
      _show(PairingFailed(_asWatchmeError(error)));
    }
  }

  void _openRemote() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => RemoteScreen(deviceId: widget.deviceId),
      ),
    );
  }

  static WatchmeError _asWatchmeError(Object error) => error is WatchmeError
      ? error
      : WatchmeError.internal('Pairing failed: $error', cause: error);

  @override
  Widget build(BuildContext context) {
    final device = WatchmeScope.of(context).byId(widget.deviceId);
    final driver = device?.drivers
        .where((d) => d.driverId == widget.driverId)
        .firstOrNull;
    final protocol = driver?.protocol;
    final name = device?.name ?? 'TV';
    // A driver that only offers pairing (a Sharp AQUOS's optional login and
    // network power-on) sets the TV up; one that needs it pairs.
    final verb = driver == null || driver.requiresPairing ? 'Pair' : 'Set up';
    final step = _step;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(_finished ? Icons.arrow_back : Icons.close),
          tooltip: _finished ? 'Back' : 'Cancel pairing',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('$verb $name'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (protocol != null) ...[
                    Text(
                      protocol,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 16),
                  ],
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(
                      key: ValueKey(step),
                      child: _stepView(step, name),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepView(PairingStep? step, String name) => switch (step) {
    null => const _Working(text: 'Starting pairing…'),
    Instruct() => _InstructView(
      step: step,
      busy: _waitingForDevice,
      onContinue: () => _submit(''),
    ),
    AcceptOnTv() => _AcceptOnTvView(step: step),
    EnterCode() => _EnterCodeView(
      step: step,
      busy: _waitingForDevice,
      onSubmit: _submit,
    ),
    EnterText() => _EnterTextView(
      step: step,
      busy: _waitingForDevice,
      onSubmit: _submit,
    ),
    ConfirmChange() => _ConfirmChangeView(
      step: step,
      busy: _waitingForDevice,
      onAnswer: _submit,
    ),
    OpenUrlFirst() => _ContinueView(
      icon: Icons.open_in_browser,
      title: 'Open this address first',
      text: step.why,
      url: step.url,
      busy: _waitingForDevice,
      continueLabel: "I've opened it",
      onContinue: () => _submit(''),
    ),
    NeedsUserMaterial() => _ContinueView(
      icon: Icons.key_outlined,
      title: switch (step.kind) {
        MaterialKind.clientCertificate => 'This TV needs a client certificate',
        MaterialKind.oauthClient => 'This TV needs your own OAuth app',
        MaterialKind.other => 'This TV needs something from you',
      },
      text: switch (step.kind) {
        MaterialKind.clientCertificate =>
          'watchme cannot ship the vendor certificate this TV expects. '
              'Follow the guide to import one, then continue.',
        MaterialKind.oauthClient =>
          'Create an OAuth client (id and secret) with the vendor, as the '
              'guide explains, then continue.',
        MaterialKind.other =>
          'Follow the guide to provide what this TV needs, then continue.',
      },
      url: step.help,
      busy: _waitingForDevice,
      continueLabel: 'Continue',
      onContinue: () => _submit(''),
    ),
    Paired() => _PairedView(
      name: name,
      onOpenRemote: _openRemote,
      onDone: () => Navigator.of(context).maybePop(),
    ),
    PairingFailed() => _FailedView(
      step: step,
      onRetry: _start,
      onClose: () => Navigator.of(context).maybePop(),
    ),
  };
}

class _Working extends StatelessWidget {
  const _Working({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const SizedBox(height: 24),
      const CircularProgressIndicator(),
      const SizedBox(height: 16),
      Text(text, textAlign: TextAlign.center),
    ],
  );
}

class _StepHeader extends StatelessWidget {
  const _StepHeader({required this.icon, required this.title, this.color});

  final IconData icon;
  final String title;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(icon, size: 56, color: color ?? theme.colorScheme.primary),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            title,
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// A link the user must open elsewhere. watchme has no browser dependency,
/// so the address is selectable and copyable.
class _LinkBox extends StatelessWidget {
  const _LinkBox({required this.url});

  final Uri url;

  @override
  Widget build(BuildContext context) {
    final text = url.toString();
    return Row(
      children: [
        Expanded(child: SelectableText(text)),
        IconButton(
          icon: const Icon(Icons.content_copy),
          tooltip: 'Copy link',
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(const SnackBar(content: Text('Link copied')));
            }
          },
        ),
      ],
    );
  }
}

class _InstructView extends StatelessWidget {
  const _InstructView({
    required this.step,
    required this.busy,
    required this.onContinue,
  });

  final Instruct step;
  final bool busy;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final helpUrl = step.helpUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHeader(icon: Icons.info_outline, title: 'On your TV'),
        Text(
          step.text,
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        if (helpUrl != null) ...[
          const SizedBox(height: 12),
          _LinkBox(url: helpUrl),
        ],
        const SizedBox(height: 24),
        if (step.requiresAck && !busy)
          FilledButton(onPressed: onContinue, child: const Text('Continue'))
        else
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}

class _AcceptOnTvView extends StatefulWidget {
  const _AcceptOnTvView({required this.step});

  final AcceptOnTv step;

  @override
  State<_AcceptOnTvView> createState() => _AcceptOnTvViewState();
}

class _AcceptOnTvViewState extends State<_AcceptOnTvView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _countdown = AnimationController(
    vsync: this,
    duration: widget.step.timeout,
  )..forward();

  @override
  void dispose() {
    _countdown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _StepHeader(icon: Icons.tv, title: 'Accept on your TV'),
      Text(
        widget.step.message ??
            'Your TV is asking whether to allow watchme. Choose Allow with '
                'the TV remote.',
        style: Theme.of(context).textTheme.bodyLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      AnimatedBuilder(
        animation: _countdown,
        builder: (context, _) {
          final total = widget.step.timeout;
          final left = total * (1 - _countdown.value);
          final seconds = (left.inMilliseconds / 1000).ceil();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(
                value: 1 - _countdown.value,
                semanticsLabel: 'Time left to accept',
              ),
              const SizedBox(height: 8),
              Text(
                seconds > 0
                    ? '$seconds s left'
                    : 'Time is up. Waiting for the TV…',
                textAlign: TextAlign.center,
              ),
            ],
          );
        },
      ),
    ],
  );
}

class _EnterCodeView extends StatefulWidget {
  const _EnterCodeView({
    required this.step,
    required this.busy,
    required this.onSubmit,
  });

  final EnterCode step;
  final bool busy;
  final ValueChanged<String> onSubmit;

  @override
  State<_EnterCodeView> createState() => _EnterCodeViewState();
}

class _EnterCodeViewState extends State<_EnterCodeView> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  bool get _valid => widget.step.accepts(_code.text);

  void _submit() {
    if (_valid && !widget.busy) widget.onSubmit(_code.text);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final theme = Theme.of(context);
    final (allowed, keyboard, what) = switch (step.alphabet) {
      CodeAlphabet.digits => (RegExp('[0-9]'), TextInputType.number, 'digits'),
      CodeAlphabet.hex => (
        RegExp('[0-9a-fA-F]'),
        TextInputType.visiblePassword,
        'characters (0-9, A-F)',
      ),
      CodeAlphabet.alphanumeric => (
        RegExp('[0-9a-zA-Z]'),
        TextInputType.visiblePassword,
        'letters or digits',
      ),
      CodeAlphabet.any => (null, TextInputType.text, 'characters'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _StepHeader(icon: Icons.pin_outlined, title: 'Enter the code'),
        Text(
          'Type the ${step.length} $what your TV shows.',
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _code,
          autofocus: true,
          enabled: !widget.busy,
          keyboardType: keyboard,
          textCapitalization: step.alphabet == CodeAlphabet.digits
              ? TextCapitalization.none
              : TextCapitalization.characters,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.oneTimeCode],
          maxLength: step.length,
          inputFormatters: [
            if (allowed != null) FilteringTextInputFormatter.allow(allowed),
            LengthLimitingTextInputFormatter(step.length),
          ],
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineMedium?.copyWith(letterSpacing: 8),
          decoration: InputDecoration(
            labelText: step.label,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        if (widget.busy)
          const _Working(text: 'Checking the code…')
        else
          FilledButton(
            onPressed: _valid ? _submit : null,
            child: const Text('Pair'),
          ),
      ],
    );
  }
}

class _EnterTextView extends StatefulWidget {
  const _EnterTextView({
    required this.step,
    required this.busy,
    required this.onSubmit,
  });

  final EnterText step;
  final bool busy;
  final ValueChanged<String> onSubmit;

  @override
  State<_EnterTextView> createState() => _EnterTextViewState();
}

class _EnterTextViewState extends State<_EnterTextView> {
  final _text = TextEditingController();
  bool _shown = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _valid => widget.step.accepts(_text.text);

  void _submit() {
    if (_valid && !widget.busy) widget.onSubmit(_text.text);
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final hidden = step.secret && !_shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: step.secret ? Icons.password : Icons.badge_outlined,
          title: step.label,
        ),
        Text(
          step.minLength == 0
              ? 'Type it as it is set on the TV. Leave it empty if the TV '
                    'has none.'
              : 'Type it as it is set on the TV.',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _text,
          autofocus: true,
          enabled: !widget.busy,
          obscureText: hidden,
          keyboardType: step.secret
              ? TextInputType.visiblePassword
              : TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: step.secret
              ? const [AutofillHints.password]
              : const [AutofillHints.username],
          maxLength: step.maxLength,
          inputFormatters: [
            FilteringTextInputFormatter.deny(RegExp(r'[\x00-\x1f\x7f]')),
            LengthLimitingTextInputFormatter(step.maxLength),
          ],
          decoration: InputDecoration(
            labelText: step.label,
            border: const OutlineInputBorder(),
            suffixIcon: step.secret
                ? IconButton(
                    icon: Icon(
                      hidden ? Icons.visibility : Icons.visibility_off,
                    ),
                    tooltip: hidden ? 'Show' : 'Hide',
                    onPressed: () => setState(() => _shown = !_shown),
                  )
                : null,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        if (widget.busy)
          const _Working(text: 'Checking with the TV…')
        else
          FilledButton(
            onPressed: _valid ? _submit : null,
            child: const Text('Continue'),
          ),
      ],
    );
  }
}

class _ConfirmChangeView extends StatelessWidget {
  const _ConfirmChangeView({
    required this.step,
    required this.busy,
    required this.onAnswer,
  });

  final ConfirmChange step;
  final bool busy;
  final ValueChanged<String> onAnswer;

  @override
  Widget build(BuildContext context) {
    final detail = step.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(icon: Icons.tune, title: step.question),
        if (detail != null)
          Text(
            detail,
            style: Theme.of(context).textTheme.bodyLarge,
            textAlign: TextAlign.center,
          ),
        const SizedBox(height: 24),
        if (busy)
          const Center(child: CircularProgressIndicator())
        else ...[
          FilledButton(
            onPressed: () => onAnswer(ConfirmChange.yes),
            child: Text(step.yesLabel),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => onAnswer(ConfirmChange.no),
            child: Text(step.noLabel),
          ),
        ],
      ],
    );
  }
}

class _ContinueView extends StatelessWidget {
  const _ContinueView({
    required this.icon,
    required this.title,
    required this.text,
    required this.url,
    required this.busy,
    required this.continueLabel,
    required this.onContinue,
  });

  final IconData icon;
  final String title;
  final String text;
  final Uri url;
  final bool busy;
  final String continueLabel;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _StepHeader(icon: icon, title: title),
      Text(
        text,
        style: Theme.of(context).textTheme.bodyLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 12),
      _LinkBox(url: url),
      const SizedBox(height: 24),
      if (busy)
        const Center(child: CircularProgressIndicator())
      else
        FilledButton(onPressed: onContinue, child: Text(continueLabel)),
    ],
  );
}

class _PairedView extends StatelessWidget {
  const _PairedView({
    required this.name,
    required this.onOpenRemote,
    required this.onDone,
  });

  final String name;
  final VoidCallback onOpenRemote;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _StepHeader(icon: Icons.check_circle_outline, title: 'Paired'),
      Text(
        'watchme can now control $name.',
        style: Theme.of(context).textTheme.bodyLarge,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: onOpenRemote,
        icon: const Icon(Icons.settings_remote),
        label: const Text('Open remote'),
      ),
      const SizedBox(height: 8),
      TextButton(onPressed: onDone, child: const Text('Done')),
    ],
  );
}

class _FailedView extends StatelessWidget {
  const _FailedView({
    required this.step,
    required this.onRetry,
    required this.onClose,
  });

  final PairingFailed step;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final error = step.error;
    final raw = step.rawDeviceMessage;
    final theme = Theme.of(context);
    final canRetry = error.code != WatchmeErrorCode.unsupported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepHeader(
          icon: error.code == WatchmeErrorCode.cancelled
              ? Icons.cancel_outlined
              : Icons.error_outline,
          title: 'Pairing failed',
          color: theme.colorScheme.error,
        ),
        Text(
          errorCodeLabel(error.code),
          style: theme.textTheme.titleMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          error.message,
          style: theme.textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        if (raw != null && raw.isNotEmpty) ...[
          const SizedBox(height: 16),
          RawDeviceMessage(raw),
        ],
        const SizedBox(height: 24),
        if (canRetry)
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        const SizedBox(height: 8),
        TextButton(onPressed: onClose, child: const Text('Close')),
      ],
    );
  }
}
