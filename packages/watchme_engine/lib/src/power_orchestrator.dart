import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'capability_router.dart';
import 'util.dart';

/// Sends Wake-on-LAN for the device with [mac] (also unicast to
/// [lastKnownIp] when given) and reports whether any packet went out. Never
/// throws.
///
/// `WakeOnLan(network).send` from watchme_io has this shape: it also sends
/// to every subnet-directed broadcast and repeats each packet, which a
/// multi-homed host and a lossy Wi-Fi link need.
typedef WakeOnLanSender = Future<bool> Function(
  String mac, {
  String? lastKnownIp,
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
  });

  /// How long to wait for a device to reappear after Wake-on-LAN.
  final Duration wakeTimeout;

  /// How often to probe for the device while waiting.
  final Duration wakePollInterval;

  /// No toggle is sent within this long of the last power command watchme
  /// delivered (Samsung keeps answering for 17-20 s after off).
  final Duration toggleQuietPeriod;

  /// Power observations older than this do not count as evidence.
  final Duration evidenceMaxAge;

  /// UDP ports magic packets go to when no [WakeOnLanSender] is given.
  final List<int> wakeOnLanPorts;

  /// How many times each magic packet is sent (UDP over Wi-Fi is lossy)
  /// when no [WakeOnLanSender] is given.
  final int wakeOnLanRepeats;

  /// The gap between those repeats.
  final Duration wakeOnLanInterval;

  /// The broadcast address for magic packets when no [WakeOnLanSender] is
  /// given.
  final String broadcastAddress;
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
  late final Future<CommandResult> result;

  /// Whether a caller asking for [other] gets what it wants from this
  /// operation: the same state, asked for at least as firmly.
  bool covers(_Intent other) =>
      intent.on == other.on && (intent.userConfirmed || !other.userConfirmed);
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
/// * No toggle within [PowerConfig.toggleQuietPeriod] of the last power
///   command watchme delivered, confirmed or not.
/// * No toggle after a discrete command that may have reached the device
///   (it timed out, say): the device may already have acted, and the toggle
///   would undo it.
///
/// The power key is a toggle intent, not a key: [pressPowerKey] turns it
/// into `SetPower(!current)` when the evidence agrees on the current state.
///
/// Operations on one device run one at a time, from evidence collection to
/// confirmation, so two callers can never both decide to toggle. A caller
/// asking for what the operation in front of it already asks for joins it
/// and gets its result; any other caller waits, then decides on fresh
/// evidence (and meets the quiet period if a toggle just went out). A wait
/// for a device to answer after Wake-on-LAN ends early when a later caller
/// asks for something other than "on", and [close] releases every caller
/// at once.
final class PowerOrchestrator {
  /// Creates an orchestrator.
  ///
  /// Magic packets go through [wakeOnLan] when given; otherwise the
  /// orchestrator sends them itself through the transports' network stack,
  /// to [PowerConfig.broadcastAddress] and the last known IP on
  /// [PowerConfig.wakeOnLanPorts], [PowerConfig.wakeOnLanRepeats] times.
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

  /// The results of the operations not finished yet, completed by [close]
  /// if they are still pending then.
  final Set<Completer<CommandResult>> _pending = {};

  /// Tunables.
  final PowerConfig config;

  /// Ranks the power routes.
  final CapabilityRouter router;

  final Map<String, PowerCommandRecord> _last = {};

  /// Per device, the last operation queued (running or waiting).
  final Map<String, _PowerOp> _tail = {};

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

  /// Stops work in flight: a wait for a device to wake ends at its next
  /// poll, no toggle goes out after it, and running, queued and later calls
  /// complete at once with [WatchmeErrorCode.cancelled], even when the
  /// operation in front of them never finishes (a session that hangs).
  void close() {
    _closed = true;
    for (final done in [..._pending]) {
      if (!done.isCompleted) done.complete(_closedResult);
    }
    _pending.clear();
  }

  static const Failed _closedResult = Failed(
    WatchmeError.cancelled('Power control was shut down'),
  );

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
    (op) => on
        ? _powerOn(target, op, userConfirmed: userConfirmed)
        : _powerOff(target, userConfirmed: userConfirmed),
  );

  /// The power key, `PressKey(RemoteKey.power)`: switch [target] to the
  /// other state. Never throws.
  ///
  /// When at least two independent, fresh sources agree on the current
  /// state (and no power command went out in the quiet period), this is
  /// [setPower] with the other state, run in the same turn. Otherwise the
  /// result is `Unsupported(Unsupported.needsConfirmation)`: the UI asks
  /// "Is the TV on right now?" and sends `SetPower(!isOn, userConfirmed:
  /// true)`.
  Future<CommandResult> pressPowerKey(PowerTarget target) => _serialized(
    target,
    (on: null, userConfirmed: false),
    (op) async {
      if (target.routes(Capability.powerOff).isEmpty &&
          target.routes(Capability.powerOn).isEmpty &&
          target.macs.isEmpty) {
        return const Unsupported(
          'No driver for this device can switch it on or off',
        );
      }
      final isOn = await _agreement(target);
      if (_closed) return _closedResult;
      if (isOn == null) return const Unsupported(Unsupported.needsConfirmation);
      return isOn ? _powerOff(target) : _powerOn(target, op);
    },
  );

  /// Runs [run] once every earlier operation on [target] has finished, or
  /// joins the last queued operation when it covers [intent].
  ///
  /// [close] ends the wait and the run: an operation that never finishes
  /// (a hung session) holds the queue until then, and no longer.
  Future<CommandResult> _serialized(
    PowerTarget target,
    _Intent intent,
    Future<CommandResult> Function(_PowerOp op) run,
  ) {
    if (_closed) return Future.value(_closedResult);
    final id = target.deviceId;
    final previous = _tail[id];
    if (previous != null && previous.covers(intent)) return previous.result;
    final op = _PowerOp(intent);
    final done = Completer<CommandResult>();
    op.result = done.future;
    _tail[id] = op;
    _pending.add(done);
    unawaited(() async {
      CommandResult result;
      try {
        // The previous operation's result never throws: every operation
        // ends in a result, and close() completes it if it hangs.
        if (previous != null) await previous.result;
        result = _closed ? _closedResult : await run(op);
      } on Object catch (error) {
        result = Failed(
          WatchmeError.internal('Power control failed: $error', cause: error),
        );
      } finally {
        if (identical(_tail[id], op)) _tail.remove(id);
      }
      _pending.remove(done);
      if (!done.isCompleted) done.complete(result);
    }());
    return op.result;
  }

  /// Whether a request queued behind [op] asks for something other than
  /// turning the device on (off, or the power key): the user changed their
  /// mind, so a wait for [op]'s Wake-on-LAN to take effect should end.
  bool _overtaken(PowerTarget target, _PowerOp op) {
    final last = _tail[target.deviceId];
    return last != null && !identical(last, op) && last.intent.on != true;
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

    // 1. Discrete, local.
    if (local.isNotEmpty) {
      final r = await router.route(command, local, target.execute);
      if (r.result.delivered) return _delivered(target, true, r.result);
      _failed(target, true, r.result, failures);
    }

    // 2. Wake-on-LAN, then wait and retry the discrete command.
    final wokeAt = _clock.now();
    if (await _sendWakeOnLan(target)) {
      _record(target, true);
      if (await _waitForDevice(target, () => _overtaken(target, op))) {
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
      if (_overtaken(target, op)) return const SentUnconfirmed();
      if (remote.isNotEmpty) {
        final r = await router.route(command, remote, target.execute);
        if (r.result.delivered) return _delivered(target, true, r.result);
      }
      // No toggle after Wake-on-LAN: the packet may still be waking it.
      return const SentUnconfirmed();
    }

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
    final r = await _toggle(target, toggles, command);
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
    final now = _clock.now();
    final latest = <String, Observed<PowerMode>>{};
    for (final o in await target.powerEvidence()) {
      if (o.confidence == Confidence.stale) continue;
      if (o.value == PowerMode.unknown) continue;
      if (now.difference(o.at) > config.evidenceMaxAge) continue;
      if (o.supersedes(latest[o.source])) latest[o.source] = o;
    }
    if (latest.length < 2) return null;
    bool all(bool Function(PowerMode mode) test) =>
        latest.values.every((o) => test(o.value));
    if (all((m) => m == PowerMode.on)) return true;
    if (all((m) => m == PowerMode.off || m == PowerMode.standby)) return false;
    return null;
  }

  bool _inQuietPeriod(PowerTarget target) {
    final last = _last[target.deviceId];
    return last != null &&
        _clock.now().difference(last.at) < config.toggleQuietPeriod;
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

  /// Sends magic packets for every cached MAC; `true` if any went out.
  Future<bool> _sendWakeOnLan(PowerTarget target) async {
    if (target.macs.isEmpty) return false;
    final macs = target.macs.toList()..sort();
    final sender = _wakeOnLan;
    if (sender != null) {
      var sent = false;
      for (final mac in macs) {
        sent |= await sender(
          mac,
          lastKnownIp: target.host.isEmpty ? null : target.host,
        );
      }
      return sent;
    }
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
    var sent = false;
    for (var round = 0; round < config.wakeOnLanRepeats; round++) {
      if (round > 0) await _clock.delay(config.wakeOnLanInterval);
      for (final packet in packets) {
        for (final port in config.wakeOnLanPorts) {
          if (canBroadcast) {
            sent |= await _trySend(
              () => net.sendDatagram(
                config.broadcastAddress,
                port,
                packet,
                broadcast: true,
              ),
            );
          }
          if (canUnicast) {
            sent |= await _trySend(
              () => net.sendDatagram(target.host, port, packet),
            );
          }
        }
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
  /// [PowerConfig.wakeTimeout], [close], or [stop] returns true.
  Future<bool> _waitForDevice(PowerTarget target, bool Function() stop) async {
    final deadline = _clock.now().add(config.wakeTimeout);
    while (!_closed && !stop() && _clock.now().isBefore(deadline)) {
      await _clock.delay(config.wakePollInterval);
      if (_closed || stop()) return false;
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
