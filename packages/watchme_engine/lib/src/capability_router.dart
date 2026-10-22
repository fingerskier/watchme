import 'package:watchme_core/watchme_core.dart';

/// How healthy a route's session is. Used only to break ties after support
/// level and flags (overview section 2.8).
final class RouteHealth {
  /// Creates a health snapshot.
  const RouteHealth({
    this.connection = ConnectionState.disconnected,
    this.ready = true,
    this.consecutiveFailures = 0,
    this.latency,
  });

  /// The session's connection state.
  final ConnectionState connection;

  /// `false` when the route cannot work without the user (it needs pairing,
  /// or its credential was revoked). Such routes are tried last.
  final bool ready;

  /// Failed attempts since the last success.
  final int consecutiveFailures;

  /// How long the last command took, if measured.
  final Duration? latency;

  int get _connectionRank {
    if (!ready) return 3;
    return switch (connection) {
      ConnectionState.connected => 0,
      ConnectionState.connecting || ConnectionState.disconnected => 1,
      ConnectionState.failed => 2,
    };
  }

  @override
  String toString() =>
      'RouteHealth(${connection.name}, ready: $ready, '
      'failures: $consecutiveFailures)';
}

/// One way to execute a command on a device: a driver's session and how
/// well it supports the command's capability.
final class RouteCandidate {
  /// Creates a candidate.
  const RouteCandidate({
    required this.driverId,
    required this.support,
    this.stability = Stability.documented,
    this.health = const RouteHealth(),
    this.preference = 0,
  });

  /// The driver whose session would run the command.
  final String driverId;

  /// The session's support for the command's capability.
  final CapabilitySupport support;

  /// The driver's protocol stability.
  final Stability stability;

  /// Session health.
  final RouteHealth health;

  /// Final tie-break: lower is preferred (the device's driver order).
  final int preference;

  @override
  String toString() => 'RouteCandidate($driverId, $support)';
}

/// The outcome of running a command on one route.
final class RouteAttempt {
  /// Creates an attempt outcome.
  const RouteAttempt(this.result, {this.commandSent = true});

  /// What the session returned.
  final CommandResult result;

  /// `false` when the attempt failed before the command left watchme
  /// (connecting failed, pairing missing). Falling back is then always
  /// safe, whatever the error.
  ///
  /// A connect that fails [WatchmeErrorCode.partiallyDelivered] is `true`:
  /// a wake it sent may have reached the device, which may have acted.
  final bool commandSent;
}

/// Runs [command] on [route]; supplied by the engine (or a test).
typedef RouteExecutor = Future<RouteAttempt> Function(
  RouteCandidate route,
  Command command,
);

/// One step [CapabilityRouter.route] took, for diagnostics and tests.
typedef RouteStep = ({String driverId, Command command, CommandResult result});

/// The outcome of [CapabilityRouter.route].
final class RoutedResult {
  /// Creates a routed result.
  const RoutedResult(this.result, {this.via, this.sent, this.steps = const []});

  /// The result returned to the caller.
  final CommandResult result;

  /// The route that delivered the command; `null` when none did.
  final RouteCandidate? via;

  /// What was actually executed on [via]: the original command, or the
  /// `StepVolume` a `SetVolume` was translated into.
  final Command? sent;

  /// Every attempt, in order.
  final List<RouteStep> steps;

  @override
  String toString() => 'RoutedResult($result via ${via?.driverId})';
}

/// Ranks a device's sessions for a command and falls back down the list
/// (overview section 2.8).
///
/// Ranking, most important first:
///
/// 1. Support level: yes, partial, unknown. Routes at [Support.no] are
///    dropped.
/// 2. Flags: state feedback over [CapFlag.writeOnly]; local over
///    [CapFlag.cloud]; documented over reverse-engineered
///    ([CapFlag.undocumented] or the driver's [Stability]); absolute over
///    [CapFlag.relativeOnly]; discrete over [CapFlag.toggleOnly].
/// 3. Health: ready and connected first, then fewer recent failures, then
///    lower latency; then the device's driver order.
///
/// [route] tries each route in turn. It moves on after [Unsupported], after
/// any failure that happened before the command was sent, and after
/// [Failed] with one of [fallbackCodes]. Other failures (a timeout, a
/// rejection) may mean the device acted, so retrying elsewhere could repeat
/// a key press; they end the search.
///
/// A partial delivery ([CommandResult.partiallyDelivered]: part of a
/// command made of several requests reached the device) always ends the
/// search, whatever [fallbackCodes] says: another route would replay the
/// part that was delivered.
final class CapabilityRouter {
  /// Creates a router.
  const CapabilityRouter({this.fallbackCodes = defaultFallbackCodes});

  /// Error codes that prove the device did not act on the command.
  /// [WatchmeErrorCode.partiallyDelivered] is never one of them.
  static const Set<WatchmeErrorCode> defaultFallbackCodes = {
    WatchmeErrorCode.unreachable,
    WatchmeErrorCode.destinationRefused,
    WatchmeErrorCode.unauthorized,
    WatchmeErrorCode.reauthRequired,
    WatchmeErrorCode.unsupported,
  };

  /// Failure codes after which the next route is tried.
  /// [WatchmeErrorCode.partiallyDelivered] is ignored here: it never falls
  /// back.
  final Set<WatchmeErrorCode> fallbackCodes;

  /// The ranking key of a support entry (lower is better), without health.
  static List<int> supportKey(
    CapabilitySupport support, [
    Stability stability = Stability.documented,
  ]) => [
    _levelRank(support.level),
    support.has(CapFlag.writeOnly) ? 1 : 0,
    support.has(CapFlag.cloud) ? 1 : 0,
    support.has(CapFlag.undocumented)
        ? 2
        : switch (stability) {
            Stability.documented => 0,
            Stability.communityStandard => 1,
            Stability.reverseEngineered || Stability.privateVendorSecret => 2,
          },
    support.has(CapFlag.relativeOnly) ? 1 : 0,
    support.has(CapFlag.toggleOnly) ? 1 : 0,
  ];

  /// Compares two support entries for the same capability (negative when
  /// [a] is better). Used to merge capabilities across sessions.
  static int compareSupport(
    CapabilitySupport a,
    CapabilitySupport b, {
    Stability aStability = Stability.documented,
    Stability bStability = Stability.documented,
  }) => _compareKeys(supportKey(a, aStability), supportKey(b, bStability));

  /// Compares two candidates (negative when [a] ranks first).
  static int compare(RouteCandidate a, RouteCandidate b) =>
      _compareKeys(_routeKey(a), _routeKey(b));

  /// The usable candidates, best first. The sort is stable.
  List<RouteCandidate> rank(Iterable<RouteCandidate> candidates) {
    final indexed = [
      for (final (i, c) in candidates.indexed)
        if (c.support.level != Support.no) (i, c),
    ];
    indexed.sort((x, y) {
      final byRank = compare(x.$2, y.$2);
      return byRank != 0 ? byRank : x.$1.compareTo(y.$1);
    });
    return [for (final (_, c) in indexed) c];
  }

  /// Runs [command] on the best of [candidates], falling back down the
  /// ranked list.
  ///
  /// A `SetVolume` on a [CapFlag.relativeOnly] route is translated into
  /// `StepVolume(level - knownVolume)`, and if the session does not
  /// implement `StepVolume`, into that many volume key presses. Without a
  /// [knownVolume] the route answers [Unsupported]. When a press fails
  /// after an earlier one was delivered, the result is
  /// [WatchmeErrorCode.partiallyDelivered] (with the press's failure as its
  /// cause), and no other route is tried.
  ///
  /// When nothing delivers, the first [Failed] is returned (it carries the
  /// device's words), else the first [Unsupported].
  Future<RoutedResult> route(
    Command command,
    Iterable<RouteCandidate> candidates,
    RouteExecutor execute, {
    int? knownVolume,
  }) async {
    final ranked = rank(candidates);
    if (ranked.isEmpty) {
      return RoutedResult(
        Unsupported(
          'No driver for this device supports ${command.capability.name}',
        ),
      );
    }
    final steps = <RouteStep>[];
    Future<RouteAttempt> run(RouteCandidate route, Command c) async {
      final attempt = await execute(route, c);
      steps.add((driverId: route.driverId, command: c, result: attempt.result));
      return attempt;
    }

    CommandResult? firstFailed;
    CommandResult? firstUnsupported;
    for (final route in ranked) {
      final (attempt, sent) = await _attempt(route, command, run, knownVolume);
      final result = attempt.result;
      if (result.delivered) {
        return RoutedResult(result, via: route, sent: sent, steps: steps);
      }
      if (result is Failed) firstFailed ??= result;
      if (result is Unsupported) firstUnsupported ??= result;
      if (!_shouldFallBack(attempt)) {
        return RoutedResult(result, steps: steps);
      }
    }
    return RoutedResult(firstFailed ?? firstUnsupported!, steps: steps);
  }

  bool _shouldFallBack(RouteAttempt attempt) => switch (attempt.result) {
    Unsupported() => true,
    Failed(:final error) =>
      error.code != WatchmeErrorCode.partiallyDelivered &&
          (!attempt.commandSent || fallbackCodes.contains(error.code)),
    _ => false,
  };

  Future<(RouteAttempt, Command)> _attempt(
    RouteCandidate route,
    Command command,
    RouteExecutor run,
    int? knownVolume,
  ) async {
    if (command is! SetVolume || !route.support.has(CapFlag.relativeOnly)) {
      return (await run(route, command), command);
    }
    if (knownVolume == null) {
      return (
        RouteAttempt(
          Unsupported(
            '${route.driverId} can only step the volume, and the current '
            'level is unknown',
          ),
          commandSent: false,
        ),
        command,
      );
    }
    final delta = command.level - knownVolume;
    final step = StepVolume(delta);
    if (delta == 0) return (const RouteAttempt(Confirmed()), step);
    final stepped = await run(route, step);
    if (stepped.result is! Unsupported) return (stepped, step);

    final key = PressKey(delta > 0 ? RemoteKey.volumeUp : RemoteKey.volumeDown);
    final presses = delta.abs();
    var allConfirmed = true;
    for (var i = 0; i < presses; i++) {
      final press = await run(route, key);
      if (!press.result.delivered) {
        if (i == 0) return (press, step);
        return (_partial(route, key, i, presses, press.result), step);
      }
      if (press.result is! Confirmed) allConfirmed = false;
    }
    return (
      RouteAttempt(allConfirmed ? const Confirmed() : const SentUnconfirmed()),
      step,
    );
  }

  /// The result of a key-press series that stopped at press [delivered] + 1
  /// of [total] with [failure]: the first [delivered] presses reached the
  /// device.
  static RouteAttempt _partial(
    RouteCandidate route,
    PressKey key,
    int delivered,
    int total,
    CommandResult failure,
  ) {
    final cause = switch (failure) {
      Failed(:final error) => error,
      Unsupported(:final reason) => WatchmeError.unsupported(reason),
      _ => WatchmeError.internal('Unexpected result: $failure'),
    };
    return RouteAttempt(
      Failed(
        WatchmeError.partiallyDelivered(
          '${route.driverId} pressed ${key.key.name} $delivered of $total '
          'times, then failed: ${cause.message}',
          rawDeviceMessage: cause.rawDeviceMessage,
          cause: cause,
        ),
      ),
    );
  }

  static int _levelRank(Support level) => switch (level) {
    Support.yes => 0,
    Support.partial => 1,
    Support.unknown => 2,
    Support.no => 3,
  };

  static List<int> _routeKey(RouteCandidate c) => [
    ...supportKey(c.support, c.stability),
    c.health._connectionRank,
    c.health.consecutiveFailures,
    c.health.latency?.inMilliseconds ?? 0,
    c.preference,
  ];

  static int _compareKeys(List<int> a, List<int> b) {
    for (var i = 0; i < a.length && i < b.length; i++) {
      final d = a[i].compareTo(b[i]);
      if (d != 0) return d;
    }
    return a.length.compareTo(b.length);
  }
}
