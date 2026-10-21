import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

import 'network/io_network_stack.dart';
import 'process/io_process_runner.dart';

/// The `dart:io` [Transports] bundle: an [IoNetworkStack], plus an
/// [IoProcessRunner] on desktop platforms. Serial, BLE, HID and IR are not
/// available here (they come from platform packages).
///
/// [features] is derived from what is actually present: the network
/// stack's features (without multicast and broadcast where the platform
/// forbids them), `subprocess` only with a process runner, and
/// `internet` only when the caller says the WAN is reachable, since this
/// bundle does not probe for it.
final class IoTransports implements Transports {
  /// Creates a bundle. [process] defaults to an [IoProcessRunner] on Linux,
  /// macOS and Windows, and to none elsewhere.
  IoTransports({
    IoNetworkStack? network,
    ProcessRunner? process,
    this.internet = false,
  }) : network = network ?? IoNetworkStack(),
       process = process ?? (_isDesktop ? const IoProcessRunner() : null);

  static bool get _isDesktop =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Whether the caller knows the WAN is reachable; adds
  /// [TransportFeature.internet].
  final bool internet;

  @override
  final IoNetworkStack network;

  @override
  final ProcessRunner? process;

  @override
  SerialPortProvider? get serial => null;

  @override
  BleCentral? get ble => null;

  @override
  HidPeripheral? get hid => null;

  @override
  IrEmitter? get ir => null;

  @override
  Set<TransportFeature> get features => {
    ...network.features,
    if (process != null) TransportFeature.subprocess,
    if (internet) TransportFeature.internet,
  };
}
