import 'dart:async';

/// The simulated TV's power.
enum PanasonicSimPower {
  /// On, picture showing (`X_ScreenState` `on`), unless still booting.
  on,

  /// Standby with the network up ("Powered On by Apps"): the descriptions
  /// answer, RenderingControl answers 400 (or 200), the app list is empty,
  /// keys other than POWER do nothing, and `X_ScreenState` is `off`.
  networkStandby,

  /// Standby with the network down: every connection is refused.
  standby,

  /// No mains power: every connection is refused, and nothing wakes it.
  unplugged,
}

/// How the simulator checks `X_SequenceNumber` in encrypted commands.
/// Whether real TVs check it at all is unknown.
enum PanasonicSimSeqCheck {
  /// Each number must be greater than the last one in the session (the
  /// first command may carry 1, 2 or 3, as the field clients differ).
  strict,

  /// Any number is accepted.
  none,
}

/// An app the simulated TV lists (`X_GetAppList`) and launches.
final class PanasonicSimApp {
  /// Creates an app entry.
  const PanasonicSimApp(this.productId, this.name, {this.state = 'Unknown'});

  /// The 16-character product id, e.g. `0010000200000001` for Netflix.
  final String productId;

  /// Display name.
  final String name;

  /// The state field of the list entry (`Unknown` or `Stop` on real sets).
  final String state;
}

/// One request the simulator received.
final class PanasonicSimRequest {
  /// Creates a record (used by the simulator).
  PanasonicSimRequest({
    required this.method,
    required this.path,
    required this.headerLines,
    required this.body,
    required this.peer,
    this.action,
    this.innerAction,
  });

  /// Upper-case HTTP method.
  final String method;

  /// Request target, e.g. `/nrc/control_0`.
  final String path;

  /// Header lines as received, name case preserved, in order.
  final List<(String, String)> headerLines;

  /// The body as text.
  final String body;

  /// The sender's address.
  final String peer;

  /// The SOAP action (body element local name), if this was a SOAP call.
  final String? action;

  /// For `X_EncryptedCommand`, the action inside it, once decrypted.
  String? innerAction;

  /// The header [name], matched case-insensitively.
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final (n, v) in headerLines) {
      if (n.toLowerCase() == lower) return v;
    }
    return null;
  }

  /// [innerAction] when there is one, otherwise [action].
  String? get effectiveAction => innerAction ?? action;

  @override
  String toString() =>
      'PanasonicSimRequest($method $path'
      '${effectiveAction == null ? '' : ' $effectiveAction'})';
}

/// An answer the simulator holds back (see `PanasonicSimulator.holdNext`).
final class PanasonicSimGate {
  /// Creates a gate for requests whose path, action or inner action is
  /// [target].
  PanasonicSimGate(this.target);

  /// What it waits for.
  final String target;

  final Completer<PanasonicSimRequest> _reached = Completer();
  final Completer<void> _release = Completer();

  /// Completes with the request once it arrived and was handled; its
  /// answer is held until [release].
  Future<PanasonicSimRequest> get reached => _reached.future;

  /// Whether the request arrived.
  bool get isReached => _reached.isCompleted;

  /// Sends the held answer.
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  /// Whether it waits for [request] (used by the simulator).
  bool matches(PanasonicSimRequest request) =>
      !_reached.isCompleted &&
      (request.path == target ||
          request.action == target ||
          request.innerAction == target);

  /// Holds [request] until [release] (used by the simulator).
  Future<void> hold(PanasonicSimRequest request) {
    _reached.complete(request);
    return _release.future;
  }
}

/// One GENA NOTIFY the simulator sent, and how the subscriber answered.
final class PanasonicSimNotify {
  /// Creates a record (used by the simulator).
  PanasonicSimNotify(this.callback, this.sid, this.seq, this.body);

  /// The callback URL it went to.
  final Uri callback;

  /// Subscription id.
  final String sid;

  /// Event sequence number.
  final int seq;

  /// The property-set body.
  final String body;

  /// The subscriber's HTTP status, or `null` if it could not be reached.
  int? status;
}
