import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';
import 'protocol.dart';
import 'redaction.dart';

/// What the login exchange found.
enum SharpLoginOutcome {
  /// The TV did not ask for a login (login disabled on the TV).
  notAsked,

  /// The TV asked for a login and accepted it.
  loggedIn,

  /// The TV showed the prompt but answered the login ID as a command: it
  /// does not enforce the login (the 2015 firmware). The password was not
  /// sent.
  notEnforced,
}

/// The TV turned a login down. [deviceText] is what it sent, unredacted:
/// whoever builds an error from it redacts it first.
final class SharpLoginRefused implements Exception {
  /// Creates a refusal.
  const SharpLoginRefused(this.deviceText);

  /// The TV's answer.
  final String deviceText;

  @override
  String toString() => 'SharpLoginRefused';
}

/// The connection was gone before anything of the current exchange was
/// written, so nothing was delivered and opening a new one is safe.
final class SharpLinkDown implements Exception {
  /// Creates the signal.
  const SharpLinkDown(this.reason);

  /// Why.
  final String reason;

  @override
  String toString() => 'SharpLinkDown($reason)';
}

/// One TCP connection to a TV's IP-control port.
///
/// It reads by the protocol's rules (see [SharpReplyBuffer]): replies end
/// at CR or LF, leading terminators are skipped, an unterminated `OK` or
/// `ERR` is accepted after [SharpTimings.unterminatedQuiet] of silence,
/// and a reply longer than [sharpMaxReplyBytes] is a protocol error.
/// Requests go one at a time: bytes buffered before a request (a late
/// reply, a stray `OK`) are dropped first, never matched to it. After a
/// timeout or a protocol error the link closes itself, so a late reply
/// can never be taken for the next request's; the session reconnects.
///
/// Nothing is ever written once the TV has closed the connection.
final class SharpLink {
  SharpLink._(
    this._socket,
    this._clock,
    this._timings,
    this.target,
    Iterable<String> secrets,
  ) : _secrets = [...secrets] {
    _subscription = _socket.input.listen(
      _onData,
      onError: (Object error, StackTrace _) => _onGone(),
      onDone: _onGone,
    );
    unawaited(
      _socket.done.then((_) => _onGone(), onError: (Object _) => _onGone()),
    );
  }

  /// Opens a connection to [host]:[port]. Device text this link puts in
  /// an error is redacted of [secrets] (and of the login [answerLogin]
  /// sends).
  ///
  /// Throws the network stack's [WatchmeError]:
  /// [WatchmeErrorCode.unreachable] when nothing accepts it.
  static Future<SharpLink> open(
    NetworkStack network,
    String host,
    int port, {
    required Clock clock,
    required SharpTimings timings,
    Iterable<String> secrets = const [],
  }) async {
    final socket = await network.tcp(host, port, timeout: timings.connect);
    return SharpLink._(socket, clock, timings, '$host:$port', secrets);
  }

  final ByteSocket _socket;
  final Clock _clock;
  final SharpTimings _timings;
  final List<String> _secrets;
  late final StreamSubscription<Uint8List> _subscription;
  final SharpReplyBuffer _buffer = SharpReplyBuffer();
  Completer<void>? _signal;
  int _received = 0;
  int _discarded = 0;
  bool _gone = false;
  bool _closing = false;
  bool _wrote = false;
  bool _busy = false;
  DateTime? _goneAt;

  /// `host:port`, for messages.
  final String target;

  /// Whether the connection can still carry a request.
  bool get isOpen => !_gone;

  /// When the connection was found closed (by either side), if it was.
  DateTime? get closedAt => _goneAt;

  /// Unsolicited bytes dropped so far (late replies, stray `OK`s).
  int get discardedBytes => _discarded;

  void _onData(Uint8List chunk) {
    _buffer.add(chunk);
    _received += chunk.length;
    _wake();
  }

  void _onGone() {
    if (!_gone) {
      _gone = true;
      _goneAt = _clock.now();
    }
    _wake();
  }

  void _wake() {
    final signal = _signal;
    _signal = null;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Closes the connection. Safe to call more than once.
  Future<void> close() async {
    _onGone();
    if (_closing) return;
    _closing = true;
    try {
      await _subscription.cancel();
    } on Object {
      // Already gone.
    }
    try {
      await _socket.close();
    } on Object {
      // Closing a broken socket is not an error for the caller.
    }
  }

  // ------------------------------------------------------------------ login

  /// Waits up to [wait] for the unterminated `Login:` prompt; `true` when
  /// it came. A TV with login disabled sends nothing at all.
  ///
  /// Throws [SharpLinkDown] when the TV closed the connection before
  /// anything was written (a reset right after accept, or a client limit),
  /// and [WatchmeErrorCode.protocol] when something other than a Sharp TV
  /// greets the connection.
  Future<bool> awaitPrompt(Duration wait) async {
    final prompted = await _waitUntil(
      () => _buffer.text.contains(sharpLoginPrompt),
      wait,
    );
    if (prompted) return true;
    if (_gone && !_wrote) {
      throw const SharpLinkDown('The TV closed the connection at once');
    }
    final greeting = _buffer.takeAll();
    final rest = greeting.replaceAll(RegExp(r'[\r\n]'), '').trim();
    if (rest.isNotEmpty && rest != sharpOk) {
      await close();
      throw WatchmeError.protocol(
        'Something on $target greeted the connection, but not like a Sharp '
        'TV',
        rawDeviceMessage: _raw(greeting),
      );
    }
    _discarded += greeting.length;
    return false;
  }

  /// Answers the prompt with [username] and [password], after
  /// [awaitPrompt] returned `true`. Each field is sent only once the TV
  /// asked for it, ended by CR.
  ///
  /// Success is a bare CRLF after the password, optionally followed by a
  /// single `OK` (a JP variant); both are dropped, and so is anything else
  /// that arrives before [SharpTimings.loginQuiet] of silence.
  ///
  /// Throws [SharpLoginRefused] when the TV turns the login down (its
  /// mismatch text, a new `Login:`, or closing the connection),
  /// [WatchmeErrorCode.timeout] when it stops answering, and
  /// [WatchmeErrorCode.protocol] (with the TV's text, unredacted) for an
  /// answer that fits nothing.
  Future<SharpLoginOutcome> answerLogin(
    String username,
    String password,
  ) async {
    _secrets.addAll([username, password]);
    _buffer.clear();
    _write('$username\r');
    await _waitUntil(
      () =>
          _gone ||
          _buffer.text.contains(sharpPasswordPrompt) ||
          isSharpLoginRefusal(_buffer.text) ||
          _buffer.hasReply,
      _timings.loginStep,
    );
    final asked = _buffer.text;
    if (!asked.contains(sharpPasswordPrompt)) {
      if (isSharpLoginRefusal(asked) || _gone) {
        await close();
        throw SharpLoginRefused(asked);
      }
      if (_buffer.hasReply) {
        // The login ID was answered as a command: this firmware shows the
        // prompt but does not enforce it. The password is not sent, so it
        // cannot be taken for a command too.
        _discarded += _buffer.takeAll().length;
        return SharpLoginOutcome.notEnforced;
      }
      await close();
      throw WatchmeError.timeout(
        'The TV did not ask for the password after the login ID',
      );
    }
    _buffer.clear();
    final sentAt = _clock.now();
    _write('$password\r');
    final answered = await _waitUntil(
      () => _gone || _buffer.isNotEmpty,
      _timings.loginAnswer,
    );
    if (!answered) {
      await close();
      throw WatchmeError.timeout('The TV did not answer the login');
    }
    await _waitQuiet(
      _timings.loginQuiet,
      sentAt.add(_timings.loginAnswer + _timings.loginQuiet),
    );
    final answer = _buffer.takeAll();
    if (isSharpLoginRefusal(answer) || _gone) {
      await close();
      throw SharpLoginRefused(answer);
    }
    final rest = answer.replaceAll(RegExp(r'[\r\n]'), '').trim();
    if (rest.isEmpty || rest == sharpOk) return SharpLoginOutcome.loggedIn;
    await close();
    throw WatchmeError.protocol(
      'The TV answered the login with something unexpected',
      rawDeviceMessage: _raw(answer),
    );
  }

  // --------------------------------------------------------------- requests

  /// Sends [frame] and returns the TV's reply, trimmed.
  ///
  /// With [skipOk] (for reads: a value is never `OK`), one stray `OK`
  /// before the value is dropped (a late acknowledgement some firmware
  /// sends after an input or power change).
  ///
  /// Throws [SharpLinkDown] when the connection was gone before [frame]
  /// was written (nothing was delivered); once written, a lost connection
  /// or a missing reply is [WatchmeErrorCode.timeout] (the TV may have
  /// acted), and a reply that breaks the framing is
  /// [WatchmeErrorCode.protocol]. Either closes the link.
  Future<String> request(
    String frame, {
    required Duration timeout,
    bool skipOk = false,
  }) async {
    if (_busy) throw StateError('SharpLink carries one request at a time');
    if (_gone) {
      throw const SharpLinkDown('The connection to the TV is closed');
    }
    _busy = true;
    final what = frame.trim();
    try {
      _discarded += _buffer.takeAll().length;
      _write(frame);
      final deadline = _clock.now().add(timeout);
      var skip = skipOk;
      while (true) {
        final reply = _buffer.takeReply();
        if (reply != null) {
          if (reply.length > sharpMaxReplyBytes) {
            throw _fail(
              WatchmeError.protocol(
                'The TV answered $what with more than $sharpMaxReplyBytes '
                'bytes',
                rawDeviceMessage: _raw(reply),
              ),
            );
          }
          if (skip && reply == sharpOk) {
            skip = false;
            _discarded += reply.length;
            continue;
          }
          return reply;
        }
        final pending = _buffer.pending;
        if (pending.length > sharpMaxReplyBytes) {
          throw _fail(
            WatchmeError.protocol(
              'The TV answered $what with more than $sharpMaxReplyBytes bytes '
              'and no line end',
              rawDeviceMessage: _raw(pending),
            ),
          );
        }
        if (pending.contains(sharpLoginPrompt)) {
          throw _fail(
            WatchmeError.protocol(
              'The TV asked for a login instead of answering $what (it may '
              'have dropped and re-accepted the connection)',
              rawDeviceMessage: sharpLoginPrompt,
            ),
          );
        }
        if (pending == sharpOk || pending == sharpErr) {
          // Some firmware sends the CR only at the start of the next reply.
          final seen = _received;
          await _waitUntil(
            () => _received != seen || _gone,
            _timings.unterminatedQuiet,
          );
          if (_received == seen) {
            _buffer.clear();
            if (skip && pending == sharpOk) {
              skip = false;
              continue;
            }
            return pending;
          }
          continue;
        }
        if (_gone) {
          throw _fail(
            WatchmeError.timeout(
              'The connection to the TV closed before it answered $what; '
              'the TV may have acted on it',
            ),
          );
        }
        final left = deadline.difference(_clock.now());
        if (left <= Duration.zero) {
          throw _fail(
            WatchmeError.timeout(
              'No answer from the TV to $what within ${timeout.inMilliseconds} '
              'ms; it may have acted on it',
            ),
          );
        }
        final seen = _received;
        await _waitUntil(() => _received != seen || _gone, left);
      }
    } finally {
      _busy = false;
    }
  }

  WatchmeError _fail(WatchmeError error) {
    unawaited(close());
    return error;
  }

  void _write(String text) {
    if (_gone) throw const SharpLinkDown('The connection to the TV is closed');
    try {
      _socket.send(utf8.encode(text));
    } on Object catch (e) {
      _onGone();
      throw SharpLinkDown('Sending failed: $e');
    }
    _wrote = true;
    unawaited(_socket.flush().then((_) {}, onError: (Object _) {}));
  }

  /// Waits until [test] holds, the connection closes, or [timeout]
  /// passes; returns [test]'s final value.
  Future<bool> _waitUntil(bool Function() test, Duration timeout) async {
    final deadline = _clock.now().add(timeout);
    while (!test()) {
      if (_gone) return test();
      final left = deadline.difference(_clock.now());
      if (left <= Duration.zero) return false;
      final signal = _signal ??= Completer<void>();
      final timer = _clock.timer(left, () {
        if (!signal.isCompleted) signal.complete();
      });
      await signal.future;
      timer.cancel();
      if (identical(_signal, signal)) _signal = null;
    }
    return true;
  }

  /// Waits until nothing has arrived for [quiet], or until [until].
  Future<void> _waitQuiet(Duration quiet, DateTime until) async {
    while (!_gone) {
      final left = until.difference(_clock.now());
      final window = left < quiet ? left : quiet;
      if (window <= Duration.zero) return;
      final seen = _received;
      final more = await _waitUntil(() => _received != seen || _gone, window);
      if (!more) return;
    }
  }

  /// [text] as an error carries it: redacted of every secret this link
  /// knows, in the whole text, and only then cut to 80 characters, so the
  /// cut can never leave a fragment of a secret behind.
  String _raw(String text) {
    final clean = redactSharpSecrets(text, _secrets);
    return clean.length <= 80 ? clean : '${clean.substring(0, 80)}...';
  }

  @override
  String toString() => 'SharpLink($target)';
}

/// Whether [credential] means "this TV asks for no login": no login ID
/// (`null`, not an empty one) and an empty password, as pairing stores for
/// a TV with login disabled.
///
/// An empty login ID and password typed at a prompt are a login all the
/// same: the 2015 firmware shows the prompt without enforcing it, so its
/// users leave both empty, and its sessions must answer the prompt rather
/// than take it for a TV that started asking for a login.
bool isSharpNoLogin(SharedSecretCredential credential) =>
    credential.username == null && credential.secret.isEmpty;

/// The secrets of [credential], for redaction.
List<String> sharpSecrets(SharedSecretCredential? credential) => [
  if (credential != null) ...[?credential.username, credential.secret],
];

/// Opens a link to [host]:[port] and logs in as [credential] demands.
///
/// * No prompt within the wait: the TV asks for no login, whatever
///   [credential] holds.
/// * A prompt and no [credential]: [WatchmeErrorCode.unauthorized], and
///   nothing is sent.
/// * A prompt and a "no login" credential ([isSharpNoLogin]): the TV has
///   asked for a login since pairing: [WatchmeErrorCode.reauthRequired],
///   and nothing is sent.
/// * A refused login: [WatchmeErrorCode.reauthRequired], with the TV's
///   text redacted.
///
/// A connection the TV closes at once is tried once more after
/// [SharpTimings.reconnectGap], then fails as unreachable: nothing was
/// sent on either.
Future<SharpLink> openSharpLink({
  required NetworkStack network,
  required String host,
  required int port,
  required Clock clock,
  required SharpTimings timings,
  SharedSecretCredential? credential,
}) async {
  final hasLogin = credential != null && !isSharpNoLogin(credential);
  final secrets = sharpSecrets(credential);
  for (var attempt = 1; ; attempt++) {
    final link = await SharpLink.open(
      network,
      host,
      port,
      clock: clock,
      timings: timings,
      secrets: secrets,
    );
    try {
      final prompted = await link.awaitPrompt(
        hasLogin ? timings.promptWaitWithLogin : timings.promptWait,
      );
      if (!prompted) return link;
      if (credential == null) {
        throw const WatchmeError.unauthorized(
          'The TV asks for a login ID and password; pair with it to enter '
          'them',
        );
      }
      if (!hasLogin) {
        throw const WatchmeError.reauthRequired(
          'The TV asks for a login ID and password now; pair with it again',
        );
      }
      try {
        await link.answerLogin(credential.username ?? '', credential.secret);
      } on SharpLoginRefused catch (e) {
        throw WatchmeError.reauthRequired(
          'The TV refused the stored login ID and password (login refused); '
          'pair with it again',
          rawDeviceMessage: redactSharpSecrets(e.deviceText, secrets),
        );
      }
      return link;
    } on SharpLinkDown {
      await link.close();
      if (attempt >= 2) {
        throw WatchmeError.unreachable(
          'The TV at $host:$port closed the connection as soon as it was '
          'opened, twice (another client may be connected)',
        );
      }
      await clock.delay(timings.reconnectGap);
    } on WatchmeError catch (e) {
      await link.close();
      throw redactSharpError(e, secrets);
    } on Object {
      await link.close();
      rethrow;
    }
  }
}
