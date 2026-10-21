// Attached-hardware and platform transports. M0 declares these so drivers
// can be written against them; implementations arrive with the CEC, IR, HID
// and BLE milestones.

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'network.dart';

/// Serial ports: libserialport / usb_serial natively, Web Serial in a
/// secure-context page.
abstract interface class SerialPortProvider {
  /// Known ports. In a browser, only ports the user previously granted.
  Future<List<SerialPortInfo>> list();

  /// Asks the user to pick a port (browser: a picker after a user gesture;
  /// native: may return the first match). `null` when nothing was chosen.
  Future<SerialPortInfo?> request({List<UsbFilter> filters = const []});

  /// Opens [port] at [baudRate].
  Future<ByteSocket> open(SerialPortInfo port, {int baudRate = 9600});
}

/// A serial port.
@immutable
final class SerialPortInfo {
  /// Creates a port description.
  const SerialPortInfo(
    this.id, {
    this.name,
    this.vendorId,
    this.productId,
    this.description,
  });

  /// Platform identifier (device path, Web Serial index).
  final String id;

  /// Display name.
  final String? name;

  /// USB vendor id, if USB.
  final int? vendorId;

  /// USB product id, if USB.
  final int? productId;

  /// Free-form description.
  final String? description;

  @override
  bool operator ==(Object other) =>
      other is SerialPortInfo &&
      other.id == id &&
      other.name == name &&
      other.vendorId == vendorId &&
      other.productId == productId &&
      other.description == description;

  @override
  int get hashCode => Object.hash(id, name, vendorId, productId, description);

  @override
  String toString() => 'SerialPortInfo($id)';
}

/// A USB vendor/product filter for [SerialPortProvider.request].
@immutable
final class UsbFilter {
  /// Creates a filter; `null` fields match anything.
  const UsbFilter({this.vendorId, this.productId});

  /// USB vendor id.
  final int? vendorId;

  /// USB product id.
  final int? productId;

  @override
  bool operator ==(Object other) =>
      other is UsbFilter &&
      other.vendorId == vendorId &&
      other.productId == productId;

  @override
  int get hashCode => Object.hash(vendorId, productId);
}

/// Bluetooth LE central role: native BLE, or Web Bluetooth.
abstract interface class BleCentral {
  /// Finds a device offering [services] (browser: chooser; native: scan).
  Future<BleDevice?> request({List<String> services = const []});

  /// Connects to [device].
  Future<GattConnection> connect(BleDevice device);
}

/// A BLE peripheral seen by a [BleCentral].
@immutable
final class BleDevice {
  /// Creates a device handle.
  const BleDevice(this.id, {this.name});

  /// Platform identifier.
  final String id;

  /// Advertised name.
  final String? name;

  @override
  bool operator ==(Object other) =>
      other is BleDevice && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'BleDevice($id, $name)';
}

/// A GATT connection to a [BleDevice]. Service and characteristic ids are
/// UUID strings.
abstract interface class GattConnection {
  /// The connected device.
  BleDevice get device;

  /// Reads a characteristic.
  Future<Uint8List> read(String service, String characteristic);

  /// Writes a characteristic.
  Future<void> write(
    String service,
    String characteristic,
    List<int> value, {
    bool withResponse = true,
  });

  /// Subscribes to notifications from a characteristic.
  Stream<Uint8List> notifications(String service, String characteristic);

  /// Disconnects.
  Future<void> disconnect();
}

/// Ways a [HidPeripheral] can present itself to a TV.
enum HidTransport {
  /// Bluetooth Classic HID.
  classic,

  /// BLE HID over GATT (HOGP).
  bleHogp,
}

/// What a [HidPeripheral] advertises.
@immutable
final class HidProfile {
  /// Creates a profile.
  const HidProfile({
    this.name = 'watchme remote',
    this.keyboard = true,
    this.consumerControl = true,
    this.mouse = false,
  });

  /// Advertised device name.
  final String name;

  /// Include a keyboard collection.
  final bool keyboard;

  /// Include a consumer-control collection (media and volume keys).
  final bool consumerControl;

  /// Include a mouse collection.
  final bool mouse;

  @override
  bool operator ==(Object other) =>
      other is HidProfile &&
      other.name == name &&
      other.keyboard == keyboard &&
      other.consumerControl == consumerControl &&
      other.mouse == mouse;

  @override
  int get hashCode => Object.hash(name, keyboard, consumerControl, mouse);
}

/// Kinds of [HidHostEvent].
enum HidHostEventKind {
  /// Advertising started.
  advertising,

  /// A host (TV) connected.
  connected,

  /// The host disconnected.
  disconnected,

  /// Something failed; see [HidHostEvent.message].
  error,
}

/// A change in the HID peripheral's relationship with a host.
@immutable
final class HidHostEvent {
  /// Creates an event.
  const HidHostEvent(this.kind, {this.hostAddress, this.message});

  /// What happened.
  final HidHostEventKind kind;

  /// The host's Bluetooth address, when known.
  final String? hostAddress;

  /// Detail for [HidHostEventKind.error].
  final String? message;

  @override
  bool operator ==(Object other) =>
      other is HidHostEvent &&
      other.kind == kind &&
      other.hostAddress == hostAddress &&
      other.message == message;

  @override
  int get hashCode => Object.hash(kind, hostAddress, message);
}

/// One HID input report.
@immutable
final class HidReport {
  /// Creates a report.
  HidReport(this.reportId, List<int> data) : data = Uint8List.fromList(data);

  /// Report id within the profile's descriptor.
  final int reportId;

  /// Report payload.
  final Uint8List data;

  @override
  bool operator ==(Object other) {
    if (other is! HidReport || other.reportId != reportId) return false;
    if (other.data.length != data.length) return false;
    for (var i = 0; i < data.length; i++) {
      if (other.data[i] != data[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(reportId, Object.hashAll(data));
}

/// Act as a Bluetooth keyboard/remote: Android `BluetoothHidDevice` or BLE
/// HOGP, BlueZ on a Linux hub.
abstract interface class HidPeripheral {
  /// Which HID transports this platform offers.
  Set<HidTransport> get transports;

  /// Starts advertising [profile]; events report advertising and host
  /// connections. Cancelling the subscription stops advertising.
  Stream<HidHostEvent> advertise(HidProfile profile);

  /// Sends a report to the connected host.
  Future<void> send(HidReport report);
}

/// An inclusive integer range.
@immutable
final class IntRange {
  /// Creates `[min, max]`.
  const IntRange(this.min, this.max) : assert(min <= max);

  /// Lower bound, inclusive.
  final int min;

  /// Upper bound, inclusive.
  final int max;

  /// Whether [value] lies within the range.
  bool contains(int value) => value >= min && value <= max;

  @override
  bool operator ==(Object other) =>
      other is IntRange && other.min == min && other.max == max;

  @override
  int get hashCode => Object.hash(min, max);

  @override
  String toString() => '[$min, $max]';
}

/// An infrared emitter (Android `ConsumerIrManager`).
abstract interface class IrEmitter {
  /// Supported carrier frequency ranges in Hz.
  List<IntRange> get carrierFrequencies;

  /// Transmits [pattern] (alternating on/off durations in microseconds) on a
  /// [carrierHz] carrier.
  Future<void> transmit(int carrierHz, List<int> pattern);
}

/// The outcome of [ProcessRunner.run].
@immutable
final class ProcessRunResult {
  /// Creates a result.
  const ProcessRunResult(this.exitCode, {this.stdout = '', this.stderr = ''});

  /// Process exit code.
  final int exitCode;

  /// Captured standard output.
  final String stdout;

  /// Captured standard error.
  final String stderr;

  @override
  bool operator ==(Object other) =>
      other is ProcessRunResult &&
      other.exitCode == exitCode &&
      other.stdout == stdout &&
      other.stderr == stderr;

  @override
  int get hashCode => Object.hash(exitCode, stdout, stderr);

  @override
  String toString() => 'ProcessRunResult($exitCode)';
}

/// A long-running subprocess with line-oriented I/O (e.g.
/// `cec-ctl --monitor`).
abstract interface class LineProcess {
  /// Standard output, split into lines.
  Stream<String> get stdoutLines;

  /// Standard error, split into lines.
  Stream<String> get stderrLines;

  /// Writes [line] plus a newline to standard input.
  void writeLine(String line);

  /// Completes with the exit code.
  Future<int> get exitCode;

  /// Terminates the process.
  Future<void> kill();
}

/// Runs subprocesses (hub and desktop only; e.g. `cec-ctl`).
abstract interface class ProcessRunner {
  /// Runs [exe] to completion. Throws `WatchmeError` with
  /// `WatchmeErrorCode.timeout` if it outlives [timeout].
  Future<ProcessRunResult> run(
    String exe,
    List<String> args, {
    Duration timeout = const Duration(seconds: 10),
  });

  /// Starts a long-running [exe].
  Future<LineProcess> start(String exe, List<String> args);
}
