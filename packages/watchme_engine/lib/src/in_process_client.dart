import 'dart:async';

import 'package:watchme_core/watchme_core.dart';

/// A [WatchmeClient] that calls a [WatchmeEngine] in the same process
/// (desktop and mobile apps).
///
/// It never hands out secrets: device views carry none, and a pairing's
/// success arrives as [Paired.redacted] even if the engine passed a
/// credential through.
final class InProcessClient implements WatchmeClient {
  /// Wraps [engine]. With [ownsEngine], [close] also closes the engine.
  InProcessClient(this.engine, {this.ownsEngine = false});

  /// The engine this client talks to.
  final WatchmeEngine engine;

  /// Whether [close] closes [engine].
  final bool ownsEngine;

  static int _nextPairingId = 0;
  final Set<_PairingHandle> _handles = {};
  bool _closed = false;

  @override
  Stream<List<DeviceView>> watchDevices() => engine.devices;

  /// The device's events, merged across its sessions. Events carry no
  /// secrets.
  Stream<DeviceEvent> events(String deviceId) => engine.events(deviceId);

  @override
  Future<void> scan({Duration window = const Duration(seconds: 5)}) {
    _checkOpen();
    return engine.discover(window);
  }

  @override
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  }) {
    _checkOpen();
    return engine.addManual(host, ports: ports);
  }

  @override
  Future<void> forget(String deviceId) {
    _checkOpen();
    return engine.forget(deviceId);
  }

  @override
  Future<PairingHandle> pair(String deviceId, String driverId) async {
    _checkOpen();
    final handle = _PairingHandle(
      'pairing-${++_nextPairingId}',
      deviceId,
      driverId,
      engine.pair(deviceId, driverId),
      onDone: _handles.remove,
    );
    _handles.add(handle);
    return handle;
  }

  @override
  Future<CommandResult> send(String deviceId, Command command) {
    if (_closed) {
      return Future.value(
        const Failed(WatchmeError.cancelled('The client is closed')),
      );
    }
    return engine.send(deviceId, command);
  }

  @override
  Future<void> refresh(String deviceId) {
    _checkOpen();
    return engine.refresh(deviceId);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final handle in [..._handles]) {
      await handle.cancel();
    }
    if (ownsEngine) await engine.close();
  }

  void _checkOpen() {
    if (_closed) throw const WatchmeError.cancelled('The client is closed');
  }
}

final class _PairingHandle implements PairingHandle {
  _PairingHandle(
    this.id,
    this.deviceId,
    this.driverId,
    this._flow, {
    required this._onDone,
  }) {
    steps = _flow.steps.map((step) {
      if (step.isTerminal) _onDone(this);
      return step is Paired ? const Paired.redacted() : step;
    });
  }

  final PairingFlow _flow;
  final void Function(_PairingHandle) _onDone;

  @override
  final String id;

  @override
  final String deviceId;

  @override
  final String driverId;

  @override
  late final Stream<PairingStep> steps;

  @override
  Future<void> submit(String value) async => _flow.submit(value);

  @override
  Future<void> cancel() async {
    _onDone(this);
    await _flow.cancel();
  }
}
