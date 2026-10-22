import '../errors.dart';
import 'network.dart';
import 'peripherals.dart';

/// Capabilities of the runtime's transports. Driver backends declare the
/// features they require, and the engine enables a backend only where all
/// of them are present.
enum TransportFeature {
  /// Read HTTP responses from another origin (always true natively; in a
  /// browser only for CORS-open hosts).
  httpReadCrossOrigin,

  /// Send HTTP without reading the response (browser no-cors).
  httpWriteOnly,

  /// Set arbitrary request headers.
  customHeaders,

  /// Use methods other than GET/POST/HEAD.
  nonSimpleMethods,

  /// Open WebSockets.
  webSocket,

  /// Set headers on the WebSocket handshake.
  webSocketHeaders,

  /// Accept self-signed certificates programmatically (TlsPolicy).
  tlsAcceptSelfSigned,

  /// Present client certificates (mutual TLS).
  tlsClientCertificate,

  /// Read the peer's certificate (fingerprints, TOFU).
  tlsPeerCertificate,

  /// Raw TCP sockets.
  rawTcp,

  /// Unicast UDP.
  udpUnicast,

  /// Broadcast UDP (Wake-on-LAN to 255.255.255.255).
  udpBroadcast,

  /// Multicast UDP (SSDP, mDNS).
  multicast,

  /// Serial ports: libserialport / usb_serial, or Web Serial.
  serialPort,

  /// BLE central: native BLE, or Web Bluetooth.
  bleCentral,

  /// Act as a Bluetooth HID peripheral (Android, BlueZ hub).
  hidPeripheral,

  /// Transmit infrared (Android ConsumerIrManager).
  irTransmit,

  /// Run subprocesses (hub and desktop only; cec-ctl).
  subprocess,

  /// The WAN is reachable; gates cloud drivers and `CapFlag.cloud`.
  internet;

  /// Every network feature: what a `dart:io` stack offers.
  static const Set<TransportFeature> allNetwork = {
    httpReadCrossOrigin,
    httpWriteOnly,
    customHeaders,
    nonSimpleMethods,
    webSocket,
    webSocketHeaders,
    tlsAcceptSelfSigned,
    tlsClientCertificate,
    tlsPeerCertificate,
    rawTcp,
    udpUnicast,
    udpBroadcast,
    multicast,
  };
}

/// Everything a driver may use to reach the outside world.
///
/// Drivers and the engine depend only on this bundle, never on `dart:io`,
/// `package:web` or Flutter. A `null` member means the runtime lacks it.
abstract interface class Transports {
  /// What the runtime can do.
  Set<TransportFeature> get features;

  /// IP networking.
  NetworkStack? get network;

  /// Serial ports.
  SerialPortProvider? get serial;

  /// Bluetooth LE central.
  BleCentral? get ble;

  /// Bluetooth HID peripheral.
  HidPeripheral? get hid;

  /// Infrared emitter.
  IrEmitter? get ir;

  /// Subprocesses.
  ProcessRunner? get process;
}

/// Convenience checks on [Transports].
extension TransportsX on Transports {
  /// Whether every feature in [required] is available.
  bool supportsAll(Iterable<TransportFeature> required) =>
      features.containsAll(required);

  /// The network stack, or a [WatchmeErrorCode.unsupported] error.
  NetworkStack requireNetwork() =>
      network ??
      (throw const WatchmeError.unsupported('No network transport available'));
}
