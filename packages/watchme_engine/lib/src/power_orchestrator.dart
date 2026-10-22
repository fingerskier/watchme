import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'capability_router.dart';
import 'util.dart';

/// Sends one round of Wake-on-LAN for the device with [mac]: the magic
/// packet once to each destination, also unicast to [lastKnownIp] when
/// given. Reports whether any packet went out. Never throws.
///
/// The [PowerOrchestrator] repeats the round itself, calling the sender
/// once per MAC per round, [PowerConfig.wakeOnLanRepeats] rounds
/// [PowerConfig.wakeOnLanInterval] apart, and stops between calls once it is
/// closed. A sender should therefore not repeat packets on its own:
/// `WakeOnLan(network, repeats: 1).send` from watchme_io has the right
/// shape, and also sends to every subnet-directed broadcast, which a
/// multi-homed host needs.
///
/// [cancelled] turns `true` once the orchestrator is closed or the
/// operation is interrupted. A sender checks it after finding its
/// destinations and before every packet, and sends nothing more once it
/// is `true`: a round can take a while (interface lookup, several
/// destinations), and shutdown must not wait for it.
typedef WakeOnLanSender = Future<bool> Function(
  String mac, {
  String? lastKnownIp,
  bool Function()? cancelled,
});

/// Tunables for [PowerOrchestrator].
final class PowerConfig {
  /// Creates a power configuration.
  const PowerConfig({
    this.wakeTimeout = const Duration(seconds: 30),
    this.wakePollInterval = const Duration(seconds: 2),
    this.toggleQuietPeriod = const Duration(seconds: 20),
    this.evidenceMaxAge = const Duration(minutes: 2),
    this.wakeOnLanPorts = const [wakeOnLanPort, 7],
    this.wakeOnLanRepeats = 3,
    this.wakeOnLanInterval = const Duration(milliseconds: 100),
    this.broadcastAddress = '255.255.255.255',
    this.closeGrace = const Duration(seconds: 1),
  });

  /// How long to wait for a device to reappear after Wake-on-LAN.
  final Duration wakeTimeout;

  /// How often to probe for the device while waiting.
  final Duration wakePollInterval;

  /// No toggle is sent within this long of the last power command watchme
  /// delivered (Samsung keeps answering for 17-20 s after off), and the
  /// power key does not act on the evidence in that time. A device whose
  /// driver needs longer ([PowerTarget.powerQuietPeriod]) gets the longer
  /// period.
  final Duration toggleQuietPeriod;

  /// Power observations older than this do not count as evidence.
  final Duration evidenceMaxAge;

  /// UDP ports magic packets go to when no [WakeOnLanSender] is given.
  final List<int> wakeOnLanPorts;

  /// How many rounds of magic packets one wake sends (UDP over Wi-Fi is
  /// lossy). A round is one call of the [WakeOnLanSender] per MAC, or,
  /// without one, each packet once to each destination.
  final int wakeOnLanRepeats;

  /// The gap between those rounds.
  final Duration wakeOnLanInterval;

  /// The broadcast address for magic packets when no [WakeOnLanSender] is
  /// given.
  final String broadcastAddress;

  /// How long [PowerOrchestrator.close] waits for a running operation that
  /// may have reached the device to stop on its own before telling its
  /// caller so anyway (a session whose command never returns).
  final Duration closeGrace;
}

/// What the [PowerOrchestrator] needs from one device. The engine
/// implements it for each device; tests can fake it.
abstract interface class PowerTarget {
  /// The engine's device id.
  String get deviceId;

  /// The device's last known host, for unicast Wake-on-LAN.
  String get host;

  /// Cached MAC addresses, for Wake-on-LAN.
  Set<String> get macs;

  /// The quiet period this device's drivers ask for after a power command
  /// (the longest `DriverDescriptor.powerQuietPeriod` among them), or
  /// `null`. The orchestrator uses it when it is longer than
  /// [PowerConfig.toggleQuietPeriod].
  Duration? get powerQuietPeriod;

  /// Routes declaring usable support for [capability] (unranked).
  List<RouteCandidate> routes(Capability capability);

  /// Runs [command] on [route], connecting first if needed.
  Future<RouteAttempt> execute(RouteCandidate route, Command command);

  /// Current power observations, one or more per source. The engine reads
  /// them from its sessions (refreshing them first) and adds its own
  /// reachability evidence.
  Future<List<Observed<PowerMode>>> powerEvidence();

  /// Probes the device passively; `true` when it answers. Answering is not
  /// proof of power: a Roku TV in standby still answers device-info.
  Future<bool> answers();
}

/// The last power command watchme delivered to a device.
typedef PowerCommandRecord = ({bool on, DateTime at});

/// What one power operation asks for: a state ([on]), or `null` for the
/// power key's "the other state".
typedef _Intent = ({bool? on, bool userConfirmed});

/// One power operation, queued or running.
final class _PowerOp {
  _PowerOp(this.intent);

  final _Intent intent;
  final Completer<CommandResult> _done = Completer();

  /// What its callers get.
  Future<CommandResult> get result => _done.future;

  /// Whether it has started: every operation queued in front of it ended.
  bool started = false;

  /// Set once a later request asks for something other than "on" (off, or
  /// the power key): the user changed their mind, so a wait for this
  /// operation's Wake-on-LAN to take effect ends, and an "on" sends no
  /// magic packet, remote command or toggle it has not sent yet. A request
  /// after that one never clears it, whatever it asks for.
  bool interrupted = false;

  /// Whether something this operation sent may have reached the device: a
  /// magic packet went out, or a command was delivered or may have been.
  bool sent = false;

  /// Sends and commands started and not finished.
  int inFlight = 0;

  /// Tells the callers what happened, [PowerConfig.closeGrace] after
  /// [PowerOrchestrator.close], if the operation has not stopped by then.
  Timer? grace;

  /// Whether the device may have received something from this operation,
  /// counting what is still on its way.
  bool get mayHaveSent => sent || inFlight > 0;

  /// Whether a caller asking for [other] gets what it wants from this
  /// operation: the same state, asked for at least as firmly.
  bool covers(_Intent other) =>
      intent.on == other.on && (intent.userConfirmed || !other.userConfirmed);

  /// Gives the callers [result], unless they already have one.
  void complete(CommandResult result) {
    grace?.cancel();
    grace = null;
    if (!_done.isCompleted) _done.complete(result);
  }
}

/// [_target] as one operation sees it: once the orchestrator is closed it
/// sends and reads nothing (a command comes back cancelled and not sent,
/// evidence is empty, the device does not answer), and every command it
/// sends is counted in [_op], so [PowerOrchestrator.close] knows whether
/// the operation may have reached the device.
final class _OpTarget implements PowerTarget {
  _OpTarget(this._power, this._target, this._op);

  final PowerOrchestrator _power;
  final PowerTarget _target;
  final _PowerOp _op;

  @override
  String get deviceId => _target.deviceId;

  @override
  String get host => _target.host;

  @override
  Set<String> get macs => _target.macs;

  @override
  Duration? get powerQuietPeriod => _target.powerQuietPeriod;

  @override
  List<RouteCandidate> routes(Capability capability) =>
      _target.routes(capability);

  @override
  Future<RouteAttempt> execute(RouteCandidate route, Command command) {
    if (_power._closed) {
      return Future.value(
        const RouteAttempt(PowerOrchestrator._closedResult, commandSent: false),
      );
    }
    return _power._effect(
      _op,
      () => _target.execute(route, command),
      (attempt) => attempt.result.delivered || mayHaveActed(attempt.result),
    );
  }

  @override
  Future<List<Observed<PowerMode>>> powerEvidence() async =>
      _power._closed ? const [] : await _target.powerEvidence();

  @override
  Future<bool> answers() async => !_power._closed && await _target.answers();
}

/// Turns devices on and off without guessing (overview section 2.8).
///
/// Power-on chain:
///
/// 1. Discrete power-on through a local session with feedback (Roku
///    `PowerOn`, Sony `setPowerStatus`, ...).
/// 2. Wake-on-LAN to every cached MAC: broadcast and unicast to the last
///    IP. Then wait for the device to answer a passive probe and, once it
///    does, retry step 1. There is no power-key retry after Wake-on-LAN.
///    The result is [Confirmed] only when the retry is delivered or a fresh
///    observation (newer than the wake) reports the device on; otherwise
///    it is [SentUnconfirmed], because a device that answers may still be
///    in standby.
/// 3. Remaining discrete routes: write-only (IR) or cloud.
/// 4. A power toggle, only if no Wake-on-LAN went out and at least two
///    independent sources agree that the device is off. Otherwise the
///    result is `Unsupported('needs confirmation')` and the UI asks the
///    user.
///
/// Power-off prefers a discrete off; a toggle follows the same two-source
/// rule (two sources agree the device is on).
///
/// The rules for every toggle:
///
/// * The user's own answer counts as agreement: `SetPower(on,
///   userConfirmed: true)` means the user just saw the device in the other
///   state ([setPower]'s `userConfirmed`).
/// * No toggle within [PowerConfig.toggleQuietPeriod] (or the device's
///   longer [PowerTarget.powerQuietPeriod]) of the last power command
///   watchme delivered, confirmed or not.
/// * No toggle after a discrete command that may have reached the device
///   (it timed out, say): the device may already have acted, and the toggle
///   would undo it.
///
/// The power key is a toggle intent, not a key: [pressPowerKey] turns it
/// into `SetPower(!current)` when the evidence settles the current state:
/// two independent sources agree on it, or the only source is the device's
/// own report, from a driver with full power-state support (a player's
/// report of its own power does not count), and the action it implies has a
/// discrete route. A discrete
/// on or off is idempotent, so a wrong direction does nothing harmful; any
/// toggle that `SetPower` falls back to still needs the two-source rule.
///
/// Operations on one device run one at a time, from evidence collection to
/// confirmation, so two callers can never both decide to toggle. A caller
/// asking for what the operation in front of it already asks for joins it
/// and gets its result; any other caller waits, then decides on fresh
/// evidence (and meets the quiet period if a toggle just went out). A wait
/// for a device to answer after Wake-on-LAN ends at its next poll once a
/// later caller asks for something other than "on" (off, or the power
/// key), even when another "on" is queued after that caller. An "on" such a
/// caller interrupted before its Wake-on-LAN went out (it was queued, say)
/// sends none, and nothing after it: magic packets sent just before the
/// "off" could wake the device after it.
///
/// [close] stops every operation before its next effect (a magic packet, a
/// command, an evidence read or probe) and releases its callers; see there.
final class PowerOrchestrator {
  /// Creates an orchestrator.
  ///
  /// Magic packets go through [wakeOnLan] when given, one call per MAC per
  /// round; otherwise the orchestrator sends them itself through the
  /// transports' network stack, to [PowerConfig.broadcastAddress] and the
  /// last known IP on [PowerConfig.wakeOnLanPorts]. Either way there are
  /// [PowerConfig.wakeOnLanRepeats] rounds.
  PowerOrchestrator({
    required this._transports,
    required this._clock,
    this.config = const PowerConfig(),
    this.router = const CapabilityRouter(),
    this._wakeOnLan,
  });

  final Transports _transports;
  final Clock _clock;
  final WakeOnLanSender? _wakeOnLan;
  bool _closed = false;

  /// The operations not finished yet, queued or running.
  final Set<_PowerOp> _ops = {};

  /// Waits in progress ([_sleep]), each with its timer; [close] ends them.
  final Map<Completer<void>, Timer> _sleeps = {};

  /// Tunables.
  final PowerConfig config;

  /// Ranks the power routes.
  final CapabilityRouter router;

  final Map<String, PowerCommandRecord> _last = {};

  /// Per device, the operations queued, oldest (the running one) first.
  final Map<String, List<_PowerOp>> _queues = {};

  /// The reason a confirmed toggle is refused within the quiet period. It
  /// is not [Unsupported.needsConfirmation]: asking the user again would
  /// not help.
  static const String quietPeriodReason =
      'A power command went out moments ago; wait a few seconds and try '
      'again';

  /// The last power command delivered to [deviceId], if any.
  PowerCommandRecord? lastCommand(String deviceId) => _last[deviceId];

  /// Forgets what was recorded for [deviceId].
  void forget(String deviceId) => _last.remove(deviceId);

  /// Stops work in flight. Nothing more is sent: every operation checks
  /// before each magic packet, command, evidence read and probe, and a wait
  /// (for the device to wake, or between Wake-on-LAN rounds) ends at once.
  ///
  /// Callers learn what may have happened:
  ///
  /// * Later calls, queued calls, and a running operation that has sent
  ///   nothing complete at once with [WatchmeErrorCode.cancelled].
  /// * A running operation that may have reached the device (a magic
  ///   packet went out, a command was or may have been delivered) keeps its
  ///   result when it was delivered or may have acted; otherwise its caller
  ///   gets [WatchmeErrorCode.partiallyDelivered], caused by
  ///   [WatchmeErrorCode.cancelled], never a bare "cancelled", which would
  ///   say nothing happened. It completes when the operation stops, or
  ///   after [PowerConfig.closeGrace] if a command it sent never returns (a
  ///   session that hangs).
  void close() {
    if (_closed) return;
    _closed = true;
    for (final MapEntry(key: woken, value: timer) in [..._sleeps.entries]) {
      timer.cancel();
      woken.complete();
    }
    _sleeps.clear();
    for (final op in [..._ops]) {
      if (op.started && op.mayHaveSent) {
        op.grace ??= _clock.timer(
          config.closeGrace,
          () => op.complete(_interrupted(op)),
        );
      } else {
        op.complete(_closedResult);
      }
    }
  }

  static const WatchmeError _shutDown = WatchmeError.cancelled(
    'Power control was shut down',
  );

  static const Failed _closedResult = Failed(_shutDown);

  /// What an "on" ends with when a later request interrupted it before it
  /// sent anything (see [_PowerOp.interrupted]).
  static const Failed _replacedResult = Failed(
    WatchmeError.cancelled(
      'A later power request (off, or the power key) replaced this one',
    ),
  );

  /// What the callers of [op] learn when [close] cut it short.
  static CommandResult _interrupted(_PowerOp op) => op.mayHaveSent
      ? const Failed(
          WatchmeError.partiallyDelivered(
            'Power control was shut down after a power command or '
            'Wake-on-LAN went out; the device may still act on it',
            cause: _shutDown,
          ),
        )
      : _closedResult;

  /// Turns [target] on or off. Never throws.
  ///
  /// [userConfirmed]: the user has just looked and says the device is in
  /// the other state (`SetPower.userConfirmed`). It stands in for the two
  /// agreeing sources a toggle needs; discrete routes still come first, and
  /// the quiet period still applies.
  Future<CommandResult> setPower(
    PowerTarget target,
    bool on, {
    bool userConfirmed = false,
  }) => _serialized(
    target,
    (on: on, userConfirmed: userConfirmed),
    (target, op) => on
        ? _powerOn(target, op, userConfirmed: userConfirmed)
        : _powerOff(target, userConfirmed: userConfirmed),
  );

  /// The power key, `PressKey(RemoteKey.power)`: switch [target] to the
  /// other state. Never throws.
  ///
  /// When no power command went out in the quiet period and the evidence
  /// settles the current state, this is [setPower] with the other state,
  /// run in the same turn. The evidence settles it when:
  ///
  /// * at least two independent, fresh sources agree on it; or
  /// * exactly one fresh source knows it, that source is the device's own
  ///   report ([Confidence.reported]; an inferred state never counts), and
  ///   the action it implies has a discrete route: a power-off route that
  ///   is not [CapFlag.toggleOnly] to turn it off, or a discrete power-on
  ///   route or a MAC for Wake-on-LAN to turn it on.
  ///
  /// A single source is enough for a discrete command because on and off
  /// are idempotent: if the source is wrong, the command changes nothing.
  /// It is never enough for a toggle: when the discrete route fails and
  /// only a toggle is left, [setPower]'s two-source rule applies and the
  /// result is `needsConfirmation`, with no toggle sent.
  ///
  /// Otherwise the result is `Unsupported(Unsupported.needsConfirmation)`:
  /// the UI asks "Is the TV on right now?" and sends `SetPower(!isOn,
  /// userConfirmed: true)`.
  Future<CommandResult> pressPowerKey(PowerTarget target) => _serialized(
    target,
    (on: null, userConfirmed: false),
    (target, op) async {
      if (target.routes(Capability.powerOff).isEmpty &&
          target.routes(Capability.powerOn).isEmpty &&
          target.macs.isEmpty) {
        return const Unsupported(
          'No driver for this device can switch it on or off',
        );
      }
      final isOn = await _powerKeyState(target);
      if (_closed) return _closedResult;
      if (isOn == null) return const Unsupported(Unsupported.needsConfirmation);
      return isOn ? _powerOff(target) : _powerOn(target, op);
    },
  );

  /// Runs [run] once every earlier operation on [target] has finished, or
  /// joins the last queued operation when it covers [intent].
  ///
  /// [run] gets [target] wrapped for its operation (see [_OpTarget]): it
  /// must reach the device only through that.
  ///
  /// A request for anything but "on" interrupts every operation queued in
  /// front of it (see [_PowerOp.interrupted]).
  ///
  /// [close] ends the wait and the run: an operation that never finishes
  /// (a hung session) holds the queue until then, and no longer.
  Future<CommandResult> _serialized(
    PowerTarget target,
    _Intent intent,
    Future<CommandResult> Function(PowerTarget target, _PowerOp op) run,
  ) {
    if (_closed) return Future.value(_closedResult);
    final id = target.deviceId;
    final queue = _queues.putIfAbsent(id, () => []);
    final previous = queue.lastOrNull;
    if (previous != null && previous.covers(intent)) return previous.result;
    if (intent.on != true) {
      for (final earlier in queue) {
        earlier.interrupted = true;
      }
    }
    final op = _PowerOp(intent);
    queue.add(op);
    _ops.add(op);
    unawaited(() async {
      CommandResult result;
      try {
        // The previous operation's result never throws: every operation
        // ends in a result, and close() completes it if it hangs.
        if (previous != null) await previous.result;
        if (_closed) {
          result = _closedResult;
        } else {
          op.started = true;
          result = await run(_OpTarget(this, target, op), op);
        }
      } on Object catch (error) {
        result = Failed(
          WatchmeError.internal('Power control failed: $error', cause: error),
        );
      } finally {
        queue.remove(op);
        if (queue.isEmpty && identical(_queues[id], queue)) _queues.remove(id);
        _ops.remove(op);
      }
      // Cut short by close(): a result saying nothing happened must not
      // hide what the operation may already have sent.
      final cutShort = _closed && !result.delivered && !mayHaveActed(result);
      op.complete(cutShort ? _interrupted(op) : result);
    }());
    return op.result;
  }

  /// Runs [send], one effect of [op] (a magic packet, a command), counting
  /// it while it runs and noting in [_PowerOp.sent] when [reached] says the
  /// device may have got it. A send that throws may have.
  Future<T> _effect<T>(
    _PowerOp op,
    Future<T> Function() send,
    bool Function(T value) reached,
  ) async {
    op.inFlight++;
    var finished = false;
    try {
      final value = await send();
      finished = true;
      if (reached(value)) op.sent = true;
      return value;
    } finally {
      if (!finished) op.sent = true;
      op.inFlight--;
    }
  }

  /// Waits [duration], or until [close].
  Future<void> _sleep(Duration duration) {
    if (_closed) return Future.value();
    final woken = Completer<void>();
    _sleeps[woken] = _clock.timer(duration, () {
      _sleeps.remove(woken);
      woken.complete();
    });
    return woken.future;
  }

  Future<CommandResult> _powerOn(
    PowerTarget target,
    _PowerOp op, {
    bool userConfirmed = false,
  }) async {
    const command = SetPower(true);
    final routes = target.routes(Capability.powerOn);
    final discrete = [
      for (final r in routes)
        if (!r.support.has(CapFlag.toggleOnly)) r,
    ];
    bool lastResort(RouteCandidate r) =>
        r.support.has(CapFlag.writeOnly) || r.support.has(CapFlag.cloud);
    final local = discrete.where((r) => !lastResort(r)).toList();
    final remote = discrete.where(lastResort).toList();
    final toggles = [
      for (final r in routes)
        if (r.support.has(CapFlag.toggleOnly)) r,
    ];
    final failures = <CommandResult>[];

    // A later request asked for something else while this one was queued:
    // turning the device on now would undo it.
    if (op.interrupted) return _replacedResult;

    // 1. Discrete, local.
    if (local.isNotEmpty) {
      final r = await router.route(command, local, target.execute);
      if (r.result.delivered) return _delivered(target, true, r.result);
      _failed(target, true, r.result, failures);
    }

    // 2. Wake-on-LAN, then wait and retry the discrete command.
    if (_closed) return _bestFailure(failures) ?? _closedResult;
    // A later request asked for something else: magic packets now could
    // wake the device after that request turned it off.
    if (op.interrupted) return _bestFailure(failures) ?? _replacedResult;
    final wokeAt = _clock.now();
    if (await _sendWakeOnLan(target, op)) {
      _record(target, true);
      if (await _waitForDevice(target, op)) {
        if (_closed) return _closedResult;
        if (local.isNotEmpty) {
          final retry = await router.route(command, local, target.execute);
          if (retry.result.delivered) {
            return _delivered(target, true, retry.result);
          }
        }
        // Answering a probe does not prove the device turned on: a Roku TV
        // in standby answers device-info and a sleeping Fire TV its DIAL
        // server. Only a fresh "on" confirms the wake.
        return await _reportsOnSince(target, wokeAt)
            ? const Confirmed()
            : const SentUnconfirmed();
      }
      if (_closed) return _closedResult;
      // A later request wants something else: the packets went out, and
      // nothing more is sent to turn the device on.
      if (op.interrupted) return const SentUnconfirmed();
      if (remote.isNotEmpty) {
        final r = await router.route(command, remote, target.execute);
        if (r.result.delivered) return _delivered(target, true, r.result);
      }
      // No toggle after Wake-on-LAN: the packet may still be waking it.
      return const SentUnconfirmed();
    }
    if (_closed) return _bestFailure(failures) ?? _closedResult;
    if (op.interrupted) return _bestFailure(failures) ?? _replacedResult;

    // 3. Discrete, write-only or cloud.
    if (remote.isNotEmpty) {
      final r = await router.route(command, remote, target.execute);
      if (r.result.delivered) return _delivered(target, true, r.result);
      _failed(target, true, r.result, failures);
    }

    // 4. A toggle, only on agreed state.
    if (toggles.isNotEmpty) {
      return _guardedToggle(
        target,
        toggles,
        command,
        failures,
        userConfirmed: userConfirmed,
      );
    }

    return _bestFailure(failures) ??
        const Unsupported(
          'No way to turn this device on: no discrete power-on and no MAC '
          'address for Wake-on-LAN',
        );
  }

  Future<CommandResult> _powerOff(
    PowerTarget target, {
    bool userConfirmed = false,
  }) async {
    const command = SetPower(false);
    final routes = target.routes(Capability.powerOff);
    final discrete = [
      for (final r in routes)
        if (!r.support.has(CapFlag.toggleOnly)) r,
    ];
    final toggles = [
      for (final r in routes)
        if (r.support.has(CapFlag.toggleOnly)) r,
    ];
    final failures = <CommandResult>[];

    if (discrete.isNotEmpty) {
      final r = await router.route(command, discrete, target.execute);
      if (r.result.delivered) return _delivered(target, false, r.result);
      _failed(target, false, r.result, failures);
    }

    if (toggles.isNotEmpty) {
      return _guardedToggle(
        target,
        toggles,
        command,
        failures,
        userConfirmed: userConfirmed,
      );
    }

    return _bestFailure(failures) ??
        const Unsupported('No driver for this device can turn it off');
  }

  /// Sends a toggle for [command] if every toggle rule allows it.
  Future<CommandResult> _guardedToggle(
    PowerTarget target,
    List<RouteCandidate> toggles,
    SetPower command,
    List<CommandResult> failures, {
    required bool userConfirmed,
  }) async {
    // A discrete command that may have reached the device may have acted:
    // toggling now could undo it.
    for (final f in failures) {
      if (mayHaveActed(f)) return f;
    }
    if (userConfirmed) {
      if (_inQuietPeriod(target)) return const Unsupported(quietPeriodReason);
    } else if (!await _stateAgreed(target, wantOn: command.on)) {
      return const Unsupported(Unsupported.needsConfirmation);
    }
    if (_closed) return _closedResult;
    // The command carries the user's answer, so the route knows the user
    // has just seen the device in the other state (the engine then does not
    // let a passive probe's guess turn the toggle into a no-op).
    final r = await _toggle(
      target,
      toggles,
      SetPower(command.on, userConfirmed: userConfirmed),
    );
    if (r.delivered) return _delivered(target, command.on, r);
    _failed(target, command.on, r, failures);
    return r;
  }

  /// Sends the toggle: `SetPower` first (the driver maps it to its power
  /// key), then the power key itself if the session has no `SetPower`.
  Future<CommandResult> _toggle(
    PowerTarget target,
    List<RouteCandidate> toggles,
    SetPower command,
  ) async {
    Future<RouteAttempt> exec(RouteCandidate route, Command c) async {
      final attempt = await target.execute(route, c);
      if (attempt.result is Unsupported) {
        return target.execute(route, const PressKey(RemoteKey.power));
      }
      return attempt;
    }

    return (await router.route(command, toggles, exec)).result;
  }

  /// Whether at least two independent, fresh sources agree on the current
  /// state ([wantOn] true: all say off or standby; false: all say on), none
  /// disagrees, and no power command went out in the quiet period.
  Future<bool> _stateAgreed(PowerTarget target, {required bool wantOn}) async =>
      await _agreement(target) == !wantOn;

  /// The current state at least two independent, fresh sources agree on:
  /// `true` when they all say on, `false` when they all say off or standby.
  /// `null` when fewer than two count, any of them disagrees, or a power
  /// command went out in the quiet period (Samsung keeps answering for
  /// 17-20 s after off, so the evidence lags).
  Future<bool?> _agreement(PowerTarget target) async {
    if (_inQuietPeriod(target)) return null;
    return _agreed(await _freshEvidence(target));
  }

  /// The current state the power key acts on (see [pressPowerKey]): the
  /// two-source [_agreement] when there is one, otherwise the state a
  /// single reported source gives when the action it implies has a
  /// discrete route. `null` in the quiet period, and whenever neither
  /// holds.
  Future<bool?> _powerKeyState(PowerTarget target) async {
    if (_inQuietPeriod(target)) return null;
    final latest = await _freshEvidence(target);
    final agreed = _agreed(latest);
    if (agreed != null || latest.length != 1) return agreed;
    final only = latest.values.single;
    // An inferred state (a Fire TV's, say: from what watchme sent or how
    // the device answered) is a guess, and a guess never decides.
    if (only.confidence != Confidence.reported) return null;
    // A player (a Roku stick, say) reports its own power, not the TV's: only
    // a driver with full power-state support speaks for the screen.
    if (!target
        .routes(Capability.powerState)
        .any(
          (r) => r.driverId == only.source && r.support.level == Support.yes,
        )) {
      return null;
    }
    final isOn = _isOn(only.value);
    if (isOn == null) return null;
    return _hasDiscreteRoute(target, on: !isOn) ? isOn : null;
  }

  /// Whether [target] can be switched [on] without a toggle: a power route
  /// that is not toggle-only, or, to turn it on, a MAC for Wake-on-LAN.
  static bool _hasDiscreteRoute(PowerTarget target, {required bool on}) {
    final capability = on ? Capability.powerOn : Capability.powerOff;
    if (target
        .routes(capability)
        .any((r) => !r.support.has(CapFlag.toggleOnly))) {
      return true;
    }
    return on && target.macs.isNotEmpty;
  }

  /// The latest usable observation of each source: not stale, not
  /// [PowerMode.unknown], and no older than [PowerConfig.evidenceMaxAge].
  Future<Map<String, Observed<PowerMode>>> _freshEvidence(
    PowerTarget target,
  ) async {
    final now = _clock.now();
    final latest = <String, Observed<PowerMode>>{};
    for (final o in await target.powerEvidence()) {
      if (o.confidence == Confidence.stale) continue;
      if (o.value == PowerMode.unknown) continue;
      if (now.difference(o.at) > config.evidenceMaxAge) continue;
      if (o.supersedes(latest[o.source])) latest[o.source] = o;
    }
    return latest;
  }

  /// The state every source in [latest] agrees on, when there are at least
  /// two of them (see [_agreement]).
  static bool? _agreed(Map<String, Observed<PowerMode>> latest) {
    if (latest.length < 2) return null;
    bool all(bool Function(PowerMode mode) test) =>
        latest.values.every((o) => test(o.value));
    if (all((m) => m == PowerMode.on)) return true;
    if (all((m) => m == PowerMode.off || m == PowerMode.standby)) return false;
    return null;
  }

  /// `true` for on, `false` for off or standby, `null` for a state that
  /// says neither (screen off, art mode, unknown).
  static bool? _isOn(PowerMode mode) => switch (mode) {
    PowerMode.on => true,
    PowerMode.off || PowerMode.standby => false,
    PowerMode.screenOff || PowerMode.artMode || PowerMode.unknown => null,
  };

  bool _inQuietPeriod(PowerTarget target) {
    final last = _last[target.deviceId];
    return last != null &&
        _clock.now().difference(last.at) < quietPeriodFor(target);
  }

  /// The quiet period for [target]: [PowerConfig.toggleQuietPeriod], or the
  /// device's own [PowerTarget.powerQuietPeriod] when that is longer.
  Duration quietPeriodFor(PowerTarget target) {
    final own = target.powerQuietPeriod;
    return own != null && own > config.toggleQuietPeriod
        ? own
        : config.toggleQuietPeriod;
  }

  /// Whether a non-stale observation made at or after [since] reports the
  /// device on, and none reports it off or in standby.
  Future<bool> _reportsOnSince(PowerTarget target, DateTime since) async {
    if (_closed) return false;
    var on = false;
    for (final o in await target.powerEvidence()) {
      if (o.confidence == Confidence.stale || o.at.isBefore(since)) continue;
      switch (o.value) {
        case PowerMode.on:
          on = true;
        case PowerMode.off || PowerMode.standby:
          return false;
        case PowerMode.screenOff || PowerMode.artMode || PowerMode.unknown:
          break;
      }
    }
    return on;
  }

  /// Sends magic packets for every cached MAC, [PowerConfig.wakeOnLanRepeats]
  /// rounds [PowerConfig.wakeOnLanInterval] apart; `true` if any went out.
  ///
  /// One round is a call of the [WakeOnLanSender] per MAC, or, without
  /// one, each packet once to each destination. [close] is checked before
  /// every send, and ends the gap between rounds: nothing goes out after
  /// it. Nor does anything once [op] is interrupted ([_PowerOp.interrupted]).
  Future<bool> _sendWakeOnLan(PowerTarget target, _PowerOp op) async {
    if (target.macs.isEmpty) return false;
    final macs = target.macs.toList()..sort();
    final List<Future<bool> Function()> round;
    final sender = _wakeOnLan;
    if (sender != null) {
      final ip = target.host.isEmpty ? null : target.host;
      bool cancelled() => _closed || op.interrupted;
      round = [
        for (final mac in macs)
          () => sender(mac, lastKnownIp: ip, cancelled: cancelled),
      ];
    } else {
      final net = _transports.network;
      if (net == null) return false;
      final features = _transports.features;
      final canBroadcast = features.contains(TransportFeature.udpBroadcast);
      final canUnicast =
          features.contains(TransportFeature.udpUnicast) &&
          target.host.isNotEmpty;
      final packets = <List<int>>[];
      for (final mac in macs) {
        try {
          packets.add(magicPacket(mac));
        } on FormatException {
          continue;
        }
      }
      round = [
        for (final packet in packets)
          for (final port in config.wakeOnLanPorts) ...[
            if (canBroadcast)
              () => _trySend(
                () => net.sendDatagram(
                  config.broadcastAddress,
                  port,
                  packet,
                  broadcast: true,
                ),
              ),
            if (canUnicast)
              () => _trySend(() => net.sendDatagram(target.host, port, packet)),
          ],
      ];
    }
    var sent = false;
    for (var i = 0; i < config.wakeOnLanRepeats; i++) {
      if (i > 0) await _sleep(config.wakeOnLanInterval);
      for (final send in round) {
        if (_closed || op.interrupted) return sent;
        sent |= await _effect(op, send, (bool went) => went);
      }
    }
    return sent;
  }

  static Future<bool> _trySend(Future<void> Function() send) async {
    try {
      await send();
      return true;
    } on WatchmeError {
      return false;
    }
  }

  /// Waits for [target] to answer after Wake-on-LAN, polling until
  /// [PowerConfig.wakeTimeout], until [close] (at once), or until [op] is
  /// interrupted (at the next poll).
  Future<bool> _waitForDevice(PowerTarget target, _PowerOp op) async {
    final deadline = _clock.now().add(config.wakeTimeout);
    while (!_closed && !op.interrupted && _clock.now().isBefore(deadline)) {
      await _sleep(config.wakePollInterval);
      if (_closed || op.interrupted) return false;
      if (await target.answers()) return true;
    }
    return false;
  }

  CommandResult _delivered(PowerTarget target, bool on, CommandResult r) {
    _record(target, on);
    return r;
  }

  /// Notes a failed attempt. One that may still have acted starts the quiet
  /// period as a delivered one would.
  void _failed(
    PowerTarget target,
    bool on,
    CommandResult r,
    List<CommandResult> failures,
  ) {
    failures.add(r);
    if (mayHaveActed(r)) _record(target, on);
  }

  void _record(PowerTarget target, bool on) =>
      _last[target.deviceId] = (on: on, at: _clock.now());

  static CommandResult? _bestFailure(List<CommandResult> results) =>
      results.whereType<Failed>().firstOrNull ?? results.firstOrNull;
}
