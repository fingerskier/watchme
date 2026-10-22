import 'dart:async';

import 'package:meta/meta.dart';

import 'credentials.dart';
import 'errors.dart';
import 'util/json.dart';

/// Characters a code may contain, for [EnterCode].
enum CodeAlphabet {
  /// `0-9` (Fire TV and Vizio PINs).
  digits,

  /// `0-9a-f`, any case (Android TV 6-hex code).
  hex,

  /// `0-9a-z`, any case (LG keycode).
  alphanumeric,

  /// Anything.
  any;

  /// Whether [value] uses only this alphabet's characters.
  bool accepts(String value) => switch (this) {
    digits => RegExp(r'^[0-9]*$').hasMatch(value),
    hex => RegExp(r'^[0-9a-fA-F]*$').hasMatch(value),
    alphanumeric => RegExp(r'^[0-9a-zA-Z]*$').hasMatch(value),
    any => true,
  };
}

/// Kinds of material the user must supply for [NeedsUserMaterial].
enum MaterialKind {
  /// A vendor client certificate and key (VIDAA).
  clientCertificate,

  /// A bring-your-own OAuth app: client id and secret (SmartThings).
  oauthClient,

  /// Anything else; see the help link.
  other,
}

/// One step of a pairing conversation, shown by the UI.
///
/// A flow emits zero or more interactive steps and then exactly one
/// terminal step: [Paired] or [PairingFailed].
@immutable
sealed class PairingStep {
  const PairingStep();

  /// Decodes the form written by [toJson]. A redacted `paired` step decodes
  /// to [Paired.redacted].
  factory PairingStep.fromJson(JsonMap json) => switch (typeOf(json)) {
    'instruct' => Instruct(
      req<String>(json, 'text'),
      helpUrl: optUri(json, 'helpUrl'),
      requiresAck: opt<bool>(json, 'requiresAck') ?? false,
    ),
    'acceptOnTv' => AcceptOnTv(
      reqMs(json, 'timeoutMs'),
      message: opt<String>(json, 'message'),
    ),
    'enterCode' => EnterCode(
      req<String>(json, 'label'),
      reqInt(json, 'length'),
      reqEnum(json, 'alphabet', CodeAlphabet.values),
    ),
    'enterText' => EnterText(
      req<String>(json, 'label'),
      secret: opt<bool>(json, 'secret') ?? false,
      minLength: optInt(json, 'minLength') ?? 0,
      maxLength: optInt(json, 'maxLength') ?? EnterText.defaultMaxLength,
    ),
    'confirmChange' => ConfirmChange(
      req<String>(json, 'question'),
      detail: opt<String>(json, 'detail'),
      yesLabel: opt<String>(json, 'yesLabel') ?? 'Yes',
      noLabel: opt<String>(json, 'noLabel') ?? 'No',
    ),
    'openUrlFirst' => OpenUrlFirst(
      reqUri(json, 'url'),
      req<String>(json, 'why'),
    ),
    'needsUserMaterial' => NeedsUserMaterial(
      reqEnum(json, 'kind', MaterialKind.values),
      reqUri(json, 'help'),
    ),
    'paired' => switch (optMap(json, 'credential')) {
      null => const Paired.redacted(),
      final c => Paired(Credential.fromJson(c)),
    },
    'pairingFailed' => PairingFailed(
      WatchmeError.fromJson(reqMap(json, 'error')),
    ),
    final other => throw FormatException('Unknown pairing step: $other'),
  };

  /// Whether the flow waits for [PairingFlow.submit] after this step: a code
  /// for [EnterCode], text for [EnterText], [ConfirmChange.yes] or
  /// [ConfirmChange.no] for [ConfirmChange], any value (usually empty) to
  /// acknowledge the others.
  bool get awaitsInput;

  /// Whether this step ends the flow.
  bool get isTerminal => this is Paired || this is PairingFailed;

  /// JSON form. A [Paired] step omits its credential unless
  /// [includeSecrets] is true; UI-facing channels never set it.
  JsonMap toJson({bool includeSecrets = false});
}

/// Tell the user something, e.g. "Enable Settings > System > Advanced >
/// Control by mobile apps".
final class Instruct extends PairingStep {
  /// Creates an instruction; with [requiresAck] the flow waits for a submit.
  const Instruct(this.text, {this.helpUrl, this.requiresAck = false});

  /// What to tell the user.
  final String text;

  /// Where to learn more.
  final Uri? helpUrl;

  /// Whether the flow waits for the user to confirm.
  final bool requiresAck;

  @override
  bool get awaitsInput => requiresAck;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'instruct',
    'text': text,
    if (helpUrl != null) 'helpUrl': helpUrl.toString(),
    if (requiresAck) 'requiresAck': true,
  };

  @override
  bool operator ==(Object other) =>
      other is Instruct &&
      other.text == text &&
      other.helpUrl == helpUrl &&
      other.requiresAck == requiresAck;

  @override
  int get hashCode => Object.hash('instruct', text, helpUrl, requiresAck);

  @override
  String toString() => 'Instruct($text)';
}

/// The TV shows an allow/deny prompt (Samsung, LG); the flow waits
/// up to [timeout] for the device.
final class AcceptOnTv extends PairingStep {
  /// Creates an accept-on-TV step.
  const AcceptOnTv(this.timeout, {this.message});

  /// How long the TV prompt stays up.
  final Duration timeout;

  /// Optional text for the user.
  final String? message;

  @override
  bool get awaitsInput => false;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'acceptOnTv',
    'timeoutMs': timeout.inMilliseconds,
    if (message != null) 'message': message,
  };

  @override
  bool operator ==(Object other) =>
      other is AcceptOnTv &&
      other.timeout == timeout &&
      other.message == message;

  @override
  int get hashCode => Object.hash('acceptOnTv', timeout, message);

  @override
  String toString() => 'AcceptOnTv($timeout)';
}

/// Ask the user for a code shown on the TV; answer with
/// [PairingFlow.submit].
final class EnterCode extends PairingStep {
  /// Creates a code prompt.
  const EnterCode(this.label, this.length, this.alphabet);

  /// Prompt text, e.g. "PIN shown on the TV".
  final String label;

  /// Number of characters expected.
  final int length;

  /// Allowed characters.
  final CodeAlphabet alphabet;

  /// Whether [value] has the right length and characters.
  bool accepts(String value) =>
      value.length == length && alphabet.accepts(value);

  @override
  bool get awaitsInput => true;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'enterCode',
    'label': label,
    'length': length,
    'alphabet': alphabet.name,
  };

  @override
  bool operator ==(Object other) =>
      other is EnterCode &&
      other.label == label &&
      other.length == length &&
      other.alphabet == alphabet;

  @override
  int get hashCode => Object.hash('enterCode', label, length, alphabet);

  @override
  String toString() => 'EnterCode($label, $length ${alphabet.name})';
}

/// Ask the user for free text, such as the login name and password a
/// Sharp AQUOS asks for on its IP-control port; answer with
/// [PairingFlow.submit].
final class EnterText extends PairingStep {
  /// Creates a text prompt.
  const EnterText(
    this.label, {
    this.secret = false,
    this.minLength = 0,
    this.maxLength = defaultMaxLength,
  });

  /// Default for [maxLength].
  static const int defaultMaxLength = 64;

  /// Prompt text, e.g. "Login ID set on the TV".
  final String label;

  /// Whether the value is a secret (a password): the UI hides it as it is
  /// typed and nothing echoes it back.
  final bool secret;

  /// Fewest characters accepted (0 allows an empty answer).
  final int minLength;

  /// Most characters accepted.
  final int maxLength;

  /// Whether [value] fits the length bounds and has no control characters
  /// (a CR or LF would end the field early on a line-based protocol).
  bool accepts(String value) =>
      value.length >= minLength &&
      value.length <= maxLength &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  @override
  bool get awaitsInput => true;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'enterText',
    'label': label,
    if (secret) 'secret': true,
    if (minLength != 0) 'minLength': minLength,
    if (maxLength != defaultMaxLength) 'maxLength': maxLength,
  };

  @override
  bool operator ==(Object other) =>
      other is EnterText &&
      other.label == label &&
      other.secret == secret &&
      other.minLength == minLength &&
      other.maxLength == maxLength;

  @override
  int get hashCode =>
      Object.hash('enterText', label, secret, minLength, maxLength);

  @override
  String toString() => 'EnterText($label${secret ? ', secret' : ''})';
}

/// Ask the user before the driver changes a setting on the TV, e.g. turning
/// on a Sharp AQUOS's network power-on command, which raises its standby
/// power. Answer with [PairingFlow.submit]: [yes] or [no]. A driver treats
/// any other answer as [no].
final class ConfirmChange extends PairingStep {
  /// Creates a yes/no question.
  const ConfirmChange(
    this.question, {
    this.detail,
    this.yesLabel = 'Yes',
    this.noLabel = 'No',
  });

  /// The answer that allows the change.
  static const String yes = 'yes';

  /// The answer that refuses it.
  static const String no = 'no';

  /// The question, e.g. "Let watchme turn this TV on over the network?".
  final String question;

  /// What changes and what it costs.
  final String? detail;

  /// Label for the button that answers [yes].
  final String yesLabel;

  /// Label for the button that answers [no].
  final String noLabel;

  @override
  bool get awaitsInput => true;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'confirmChange',
    'question': question,
    if (detail != null) 'detail': detail,
    if (yesLabel != 'Yes') 'yesLabel': yesLabel,
    if (noLabel != 'No') 'noLabel': noLabel,
  };

  @override
  bool operator ==(Object other) =>
      other is ConfirmChange &&
      other.question == question &&
      other.detail == detail &&
      other.yesLabel == yesLabel &&
      other.noLabel == noLabel;

  @override
  int get hashCode =>
      Object.hash('confirmChange', question, detail, yesLabel, noLabel);

  @override
  String toString() => 'ConfirmChange($question)';
}

/// The user must open [url] first (browser-direct certificate
/// click-through), then continue with a submit.
final class OpenUrlFirst extends PairingStep {
  /// Creates an open-URL step.
  const OpenUrlFirst(this.url, this.why);

  /// What to open.
  final Uri url;

  /// Why, in words the user understands.
  final String why;

  @override
  bool get awaitsInput => true;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'openUrlFirst',
    'url': url.toString(),
    'why': why,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenUrlFirst && other.url == url && other.why == why;

  @override
  int get hashCode => Object.hash('openUrlFirst', url, why);

  @override
  String toString() => 'OpenUrlFirst($url)';
}

/// The user must import material watchme cannot provide (VIDAA client
/// certificate, SmartThings OAuth app), then continue with a submit.
final class NeedsUserMaterial extends PairingStep {
  /// Creates a needs-material step.
  const NeedsUserMaterial(this.kind, this.help);

  /// What is needed.
  final MaterialKind kind;

  /// Instructions.
  final Uri help;

  @override
  bool get awaitsInput => true;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'needsUserMaterial',
    'kind': kind.name,
    'help': help.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is NeedsUserMaterial && other.kind == kind && other.help == help;

  @override
  int get hashCode => Object.hash('needsUserMaterial', kind, help);

  @override
  String toString() => 'NeedsUserMaterial(${kind.name})';
}

/// Pairing succeeded. Terminal.
final class Paired extends PairingStep {
  /// Creates a success step carrying the new [credential]. Drivers always
  /// use this constructor.
  const Paired(Credential this.credential);

  /// A success step whose credential was stripped before it crossed to a UI
  /// client.
  const Paired.redacted() : credential = null;

  /// The new credential; `null` only for [Paired.redacted].
  final Credential? credential;

  @override
  bool get awaitsInput => false;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'paired',
    if (includeSecrets && credential != null)
      'credential': credential!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is Paired && other.credential == credential;

  @override
  int get hashCode => Object.hash('paired', credential);

  @override
  String toString() => 'Paired($credential)';
}

/// Pairing failed. Terminal. The error preserves the TV's raw text (LG
/// `403 ... blacklisted certificate`, Samsung `ms.channel.timeOut`, ...).
final class PairingFailed extends PairingStep {
  /// Creates a failure step.
  const PairingFailed(this.error);

  /// What went wrong.
  final WatchmeError error;

  /// The device's own error text, if any.
  String? get rawDeviceMessage => error.rawDeviceMessage;

  @override
  bool get awaitsInput => false;

  @override
  JsonMap toJson({bool includeSecrets = false}) => {
    'type': 'pairingFailed',
    'error': error.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is PairingFailed && other.error == error;

  @override
  int get hashCode => Object.hash('pairingFailed', error);

  @override
  String toString() => 'PairingFailed($error)';
}

/// A live pairing conversation between a driver and the user.
///
/// [steps] is single-subscription and buffers until listened to. It emits
/// exactly one terminal step ([Paired] or [PairingFailed]) and then closes.
abstract interface class PairingFlow {
  /// The conversation.
  Stream<PairingStep> get steps;

  /// Answers the latest step that [PairingStep.awaitsInput]: the code for
  /// [EnterCode], the text for [EnterText], [ConfirmChange.yes] or
  /// [ConfirmChange.no] for [ConfirmChange], any value to acknowledge the
  /// others.
  void submit(String value);

  /// Abandons the pairing. The flow emits [PairingFailed] with
  /// [WatchmeErrorCode.cancelled] (unless already finished) and closes.
  Future<void> cancel();
}

/// What the engine tells a driver when pairing starts.
@immutable
final class PairingContext {
  /// Creates a context.
  const PairingContext({required this.deviceId, this.clientName = 'watchme'});

  /// The engine's id for the device; goes into [Credential.deviceId].
  final String deviceId;

  /// How watchme names itself on the TV (Fire TV `friendlyName`, LG
  /// manifest, Samsung `name`).
  final String clientName;

  @override
  bool operator ==(Object other) =>
      other is PairingContext &&
      other.deviceId == deviceId &&
      other.clientName == clientName;

  @override
  int get hashCode => Object.hash(deviceId, clientName);
}

/// A ready-made [PairingFlow] for drivers.
///
/// Most drivers write pairing as one async function with [run]:
///
/// ```dart
/// PairingFlow startPairing(Endpoint ep, Transports t, PairingContext ctx) =>
///     PairingFlowController.run((flow) async {
///       await wake(ep, t);
///       await showPin(ep, t, ctx.clientName);
///       final pin = await flow.prompt(
///           const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits));
///       final token = await verifyPin(ep, t, pin);
///       return TokenCredential(driverId: id, deviceId: ctx.deviceId,
///           createdAt: clock.now(), token: token);
///     });
/// ```
///
/// A [WatchmeError] thrown by the body becomes [PairingFailed]; any other
/// error becomes [PairingFailed] with [WatchmeErrorCode.internal].
final class PairingFlowController implements PairingFlow {
  /// Creates a controller. [onCancel] runs once when the user cancels, e.g.
  /// to close a socket the body is waiting on.
  PairingFlowController({this._onCancel});

  /// Runs [body] as a pairing flow and returns the flow immediately.
  static PairingFlow run(
    Future<Credential> Function(PairingFlowController flow) body, {
    FutureOr<void> Function()? onCancel,
  }) {
    final flow = PairingFlowController(onCancel: onCancel);
    Future(() => body(flow)).then(
      flow.complete,
      onError: (Object error, StackTrace stack) => flow.fail(
        error is WatchmeError
            ? error
            : WatchmeError.internal('Pairing failed: $error', cause: error),
      ),
    );
    return flow;
  }

  final FutureOr<void> Function()? _onCancel;
  final StreamController<PairingStep> _steps = StreamController();
  final List<String> _queuedInputs = [];
  final Completer<void> _cancelled = Completer();
  Completer<String>? _pendingInput;
  bool _done = false;

  @override
  Stream<PairingStep> get steps => _steps.stream;

  /// Whether a terminal step has been emitted (or the flow was cancelled).
  bool get isDone => _done;

  /// Whether the user cancelled.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the user cancels, so a body can race a device wait
  /// against it.
  Future<void> get whenCancelled => _cancelled.future;

  /// Emits a non-terminal step. Ignored once the flow is done.
  void emit(PairingStep step) {
    if (step.isTerminal) {
      throw ArgumentError.value(step, 'step', 'use complete() or fail()');
    }
    if (!_done) _steps.add(step);
  }

  /// Emits [step] and waits for the user's answer.
  Future<String> prompt(PairingStep step) {
    emit(step);
    return nextInput();
  }

  /// The next value passed to [submit]. Throws [WatchmeError]
  /// ([WatchmeErrorCode.cancelled]) if the flow is cancelled first.
  Future<String> nextInput() {
    if (isCancelled) {
      return Future.error(const WatchmeError.cancelled('Pairing cancelled'));
    }
    if (_queuedInputs.isNotEmpty) {
      return Future.value(_queuedInputs.removeAt(0));
    }
    return (_pendingInput ??= Completer<String>()).future;
  }

  @override
  void submit(String value) {
    if (_done) return;
    final pending = _pendingInput;
    if (pending != null) {
      _pendingInput = null;
      pending.complete(value);
    } else {
      _queuedInputs.add(value);
    }
  }

  /// Emits [Paired] with [credential] and closes. Ignored once done.
  void complete(Credential credential) => _finish(Paired(credential));

  /// Emits [PairingFailed] with [error] and closes. Ignored once done.
  void fail(WatchmeError error) => _finish(PairingFailed(error));

  @override
  Future<void> cancel() async {
    if (_done) return;
    _cancelled.complete();
    _pendingInput?.completeError(
      const WatchmeError.cancelled('Pairing cancelled'),
    );
    _pendingInput = null;
    _finish(const PairingFailed(WatchmeError.cancelled('Pairing cancelled')));
    await _onCancel?.call();
  }

  void _finish(PairingStep terminal) {
    if (_done) return;
    _done = true;
    _steps.add(terminal);
    // Not awaited: close() completes only once a listener drains the stream.
    unawaited(_steps.close());
  }
}
