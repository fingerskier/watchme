import 'package:watchme_core/watchme_core.dart';

import 'fake_network.dart';

/// A [Transports] bundle for tests.
///
/// [features] is derived: the network stack's features, plus one feature
/// per non-null peripheral, plus [extraFeatures] (e.g.
/// [TransportFeature.internet]).
///
/// ```dart
/// final t = FakeTransports();               // full fake network
/// t.net.onHttp('GET', '/', (_) => HttpResult(200));
/// final offline = FakeTransports.offline(); // no network at all
/// ```
class FakeTransports implements Transports {
  /// Creates a bundle around [network] (a fresh [FakeNetworkStack] by
  /// default).
  FakeTransports({
    FakeNetworkStack? network,
    this.serial,
    this.ble,
    this.hid,
    this.ir,
    this.process,
    Set<TransportFeature> extraFeatures = const {},
  }) : network = network ?? FakeNetworkStack(),
       extraFeatures = {...extraFeatures};

  /// A bundle with no network stack.
  FakeTransports.offline({
    this.serial,
    this.ble,
    this.hid,
    this.ir,
    this.process,
    Set<TransportFeature> extraFeatures = const {},
  }) : network = null,
       extraFeatures = {...extraFeatures};

  @override
  final FakeNetworkStack? network;

  @override
  final SerialPortProvider? serial;

  @override
  final BleCentral? ble;

  @override
  final HidPeripheral? hid;

  @override
  final IrEmitter? ir;

  @override
  final ProcessRunner? process;

  /// Features added on top of the derived ones. Mutable.
  final Set<TransportFeature> extraFeatures;

  /// The fake network stack; throws [StateError] for an offline bundle.
  FakeNetworkStack get net =>
      network ?? (throw StateError('FakeTransports has no network'));

  @override
  Set<TransportFeature> get features => {
    ...?network?.features,
    if (serial != null) TransportFeature.serialPort,
    if (ble != null) TransportFeature.bleCentral,
    if (hid != null) TransportFeature.hidPeripheral,
    if (ir != null) TransportFeature.irTransmit,
    if (process != null) TransportFeature.subprocess,
    ...extraFeatures,
  };
}
