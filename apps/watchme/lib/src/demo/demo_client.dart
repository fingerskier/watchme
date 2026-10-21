import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

import 'demo_tvs.dart';

export 'demo_tvs.dart' show demoFireTvHost, demoFireTvPin, demoRokuHost;

/// A [WatchmeClient] with two simulated TVs, so the app is usable without
/// hardware and without touching the network.
///
/// - "Living Room Roku TV" ([demoRokuHost]): Roku ECP, no pairing.
/// - "Bedroom Fire TV Stick" ([demoFireTvHost]): needs PIN pairing; the PIN
///   is [demoFireTvPin]. Until paired, commands fail as unauthorized.
///
/// Both appear after a [scan], or when added by address.
final class DemoWatchmeClient implements WatchmeClient {
  /// Creates the demo. [latency] delays every answer and [scanTime] caps a
  /// scan's duration; tests pass [Duration.zero] for both.
  DemoWatchmeClient({
    Clock clock = const SystemClock(),
    this.latency = const Duration(milliseconds: 150),
    this.scanTime = const Duration(milliseconds: 1500),
  }) : _clock = clock {
    final now = clock.now();
    _tvs = [DemoTv.roku(now), DemoTv.fireTv(now)];
  }

  /// How long each simulated request takes.
  final Duration latency;

  /// The longest a scan runs, whatever window the caller asks for.
  final Duration scanTime;

  final Clock _clock;
  late final List<DemoTv> _tvs;
  final Set<String> _visible = {};
  final StreamController<List<DeviceView>> _changes =
      StreamController.broadcast();
  int _nextPairing = 1;
  bool _closed = false;

  @override
  Stream<List<DeviceView>> watchDevices() => Stream.multi((listener) {
    listener.add(_snapshot());
    final subscription = _changes.stream.listen(
      listener.add,
      onDone: listener.close,
    );
    listener.onCancel = subscription.cancel;
  });

  @override
  Future<void> scan({Duration window = const Duration(seconds: 5)}) async {
    _checkOpen();
    await _wait(window < scanTime ? window : scanTime);
    final now = _clock.now();
    for (final tv in _tvs) {
      tv.lastSeen = now;
      _visible.add(tv.id);
    }
    _emit();
  }

  @override
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  }) async {
    _checkOpen();
    await _wait(latency * 2);
    final wanted = host.trim().toLowerCase();
    for (final tv in _tvs) {
      if (tv.host == wanted) {
        tv.lastSeen = _clock.now();
        _visible.add(tv.id);
        _emit();
        return tv.view();
      }
    }
    throw WatchmeError.unreachable(
      'Nothing answered at $host. The demo has TVs at $demoRokuHost and '
      '$demoFireTvHost.',
    );
  }

  @override
  Future<void> forget(String deviceId) async {
    _checkOpen();
    final tv = _require(deviceId);
    _visible.remove(tv.id);
    tv.paired = false;
    _emit();
  }

  @override
  Future<PairingHandle> pair(String deviceId, String driverId) async {
    _checkOpen();
    final id = 'demo-pairing-${_nextPairing++}';
    final tv = _find(deviceId);
    final PairingFlow flow;
    if (tv == null || tv.driverId != driverId) {
      flow = _failedFlow(
        WatchmeError.internal('No driver $driverId on device $deviceId.'),
      );
    } else if (!tv.requiresPairing) {
      flow = _failedFlow(
        WatchmeError.unsupported(
          '${tv.protocol} needs no pairing. If the TV refuses commands, '
          'enable Control by mobile apps in its settings.',
        ),
      );
    } else {
      flow = PairingFlowController.run((flow) => _pairWithPin(tv, flow));
    }
    return _DemoPairingHandle(id, deviceId, driverId, flow);
  }

  Future<Credential> _pairWithPin(DemoTv tv, PairingFlowController flow) async {
    flow.emit(
      const Instruct('Waking the Fire TV and asking it to show a PIN…'),
    );
    await _wait(latency * 3);
    final pin = await flow.prompt(
      const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
    );
    await _wait(latency);
    if (pin != demoFireTvPin) {
      throw const WatchmeError.unauthorized(
        'The Fire TV did not accept that PIN.',
        rawDeviceMessage: 'HTTP 400: invalid PIN (simulated)',
      );
    }
    final now = _clock.now();
    tv
      ..paired = true
      ..lastSeen = now
      ..stateAt = now;
    _emit();
    return TokenCredential(
      driverId: tv.driverId,
      deviceId: tv.id,
      createdAt: now,
      token: 'demo-token',
    );
  }

  @override
  Future<CommandResult> send(String deviceId, Command command) async {
    if (_closed) {
      return const Failed(WatchmeError.cancelled('The client is closed.'));
    }
    final tv = _find(deviceId);
    if (tv == null) {
      return Failed(WatchmeError.internal('Unknown device $deviceId.'));
    }
    await _wait(latency);
    final result = tv.execute(command, _clock.now());
    if (result.delivered) _emit();
    return result;
  }

  @override
  Future<void> refresh(String deviceId) async {
    _checkOpen();
    final tv = _require(deviceId);
    await _wait(latency);
    tv.lastSeen = _clock.now();
    _emit();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _changes.close();
  }

  List<DeviceView> _snapshot() => [
    for (final tv in _tvs)
      if (_visible.contains(tv.id)) tv.view(),
  ];

  void _emit() {
    if (!_closed) _changes.add(_snapshot());
  }

  DemoTv? _find(String deviceId) {
    for (final tv in _tvs) {
      if (tv.id == deviceId && _visible.contains(tv.id)) return tv;
    }
    return null;
  }

  DemoTv _require(String deviceId) =>
      _find(deviceId) ??
      (throw WatchmeError.internal('Unknown device $deviceId.'));

  void _checkOpen() {
    if (_closed) throw const WatchmeError.cancelled('The client is closed.');
  }

  Future<void> _wait(Duration duration) =>
      duration > Duration.zero ? _clock.delay(duration) : Future.value();

  static PairingFlow _failedFlow(WatchmeError error) =>
      PairingFlowController()..fail(error);
}

final class _DemoPairingHandle implements PairingHandle {
  // Clients never see credentials, so success crosses as Paired.redacted.
  _DemoPairingHandle(this.id, this.deviceId, this.driverId, this._flow)
    : steps = _flow.steps.map(
        (step) => step is Paired ? const Paired.redacted() : step,
      );

  @override
  final String id;

  @override
  final String deviceId;

  @override
  final String driverId;

  final PairingFlow _flow;

  @override
  final Stream<PairingStep> steps;

  @override
  Future<void> submit(String value) async => _flow.submit(value);

  @override
  Future<void> cancel() => _flow.cancel();
}
