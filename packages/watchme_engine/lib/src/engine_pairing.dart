import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

/// A pairing flow that has already failed with [error].
PairingFlow failedPairing(WatchmeError error) =>
    PairingFlowController()..fail(error);

/// The engine's side of one pairing.
///
/// It listens to the driver's flow straight away, so the credential is
/// stored even if nobody watches the steps. Interactive steps are forwarded
/// unchanged. On the driver's [Paired], [onPaired] stores the credential
/// and connects, and only then is [Paired.redacted] emitted: the credential
/// never leaves the engine. [onDone] runs once when the flow ends.
final class EnginePairing implements PairingFlow {
  /// Wraps the driver's [inner] flow.
  EnginePairing(
    PairingFlow inner, {
    required this._onPaired,
    required this._onDone,
  }) : _inner = inner {
    _subscription = inner.steps.listen(
      _onStep,
      onError: (Object error, StackTrace _) => _finish(
        PairingFailed(
          error is WatchmeError
              ? error
              : WatchmeError.internal('Pairing failed: $error', cause: error),
        ),
      ),
      onDone: () {
        if (!_terminalSeen) {
          _finish(
            const PairingFailed(
              WatchmeError.internal(
                'The driver ended pairing without a result',
              ),
            ),
          );
        }
      },
    );
  }

  final PairingFlow _inner;
  final Future<void> Function(Credential credential) _onPaired;
  final void Function() _onDone;
  final StreamController<PairingStep> _out = StreamController();
  late final StreamSubscription<PairingStep> _subscription;
  bool _terminalSeen = false;
  bool _done = false;

  /// Whether the flow has ended.
  bool get isDone => _done;

  @override
  Stream<PairingStep> get steps => _out.stream;

  @override
  void submit(String value) {
    if (!_terminalSeen) _inner.submit(value);
  }

  @override
  Future<void> cancel() async {
    // Once the driver reported a result, the pairing is settled.
    if (_terminalSeen) return;
    _terminalSeen = true;
    _finish(const PairingFailed(WatchmeError.cancelled('Pairing cancelled')));
    await _inner.cancel();
  }

  void _onStep(PairingStep step) {
    if (_terminalSeen) return;
    switch (step) {
      case Paired(:final credential):
        _terminalSeen = true;
        unawaited(_store(credential));
      case PairingFailed():
        _terminalSeen = true;
        _finish(step);
      default:
        _out.add(step);
    }
  }

  Future<void> _store(Credential? credential) async {
    if (credential == null) {
      _finish(
        const PairingFailed(
          WatchmeError.internal(
            'The driver reported success without a '
            'credential',
          ),
        ),
      );
      return;
    }
    try {
      await _onPaired(credential);
      _finish(const Paired.redacted());
    } on WatchmeError catch (error) {
      _finish(PairingFailed(error));
    } on Object catch (error) {
      _finish(
        PairingFailed(
          WatchmeError.internal(
            'Could not store the credential: $error',
            cause: error,
          ),
        ),
      );
    }
  }

  void _finish(PairingStep terminal) {
    if (_done) return;
    _done = true;
    _out.add(terminal);
    unawaited(_out.close());
    unawaited(_subscription.cancel());
    _onDone();
  }
}
