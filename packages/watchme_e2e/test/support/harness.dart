import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_io/watchme_io.dart';

/// The real `dart:io` transports, wrapped so that nothing can leave the
/// machine: every destination must be a loopback address. A blocked attempt
/// fails like an unreachable host and is recorded in [blocked], which each
/// test checks is empty.
final class LoopbackTransports implements Transports {
  /// Wraps a fresh [IoTransports] whose multicast stays on `lo` with TTL 0.
  LoopbackTransports()
    : io = IoTransports(
        network: IoNetworkStack(
          multicastInterfaces: [InternetAddress.loopbackIPv4],
          multicastHops: 0,
        ),
      ) {
    network = _LoopbackOnlyStack(io.network, blocked);
  }

  /// The wrapped transports.
  final IoTransports io;

  /// Destinations the guard refused, as `host:port`.
  final List<String> blocked = [];

  @override
  late final NetworkStack network;

  @override
  Set<TransportFeature> get features => io.features;

  @override
  SerialPortProvider? get serial => null;

  @override
  BleCentral? get ble => null;

  @override
  HidPeripheral? get hid => null;

  @override
  IrEmitter? get ir => null;

  @override
  ProcessRunner? get process => null;
}

bool _isLoopback(String host) {
  var h = host.trim();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h == 'localhost') return true;
  final address = InternetAddress.tryParse(h);
  return address != null && address.isLoopback;
}

final class _LoopbackOnlyStack implements NetworkStack {
  _LoopbackOnlyStack(this._inner, this._blocked);

  final NetworkStack _inner;
  final List<String> _blocked;

  void _check(String host, int port) {
    if (_isLoopback(host)) return;
    _blocked.add('$host:$port');
    throw WatchmeError.unreachable(
      'e2e loopback guard: refusing to contact $host:$port',
    );
  }

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) async {
    _check(call.uri.host, call.uri.port);
    return _inner.http(call, tls: tls, identity: identity);
  }

  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    _check(uri.host, uri.port);
    return _inner.webSocket(
      uri,
      protocols: protocols,
      headers: headers,
      tls: tls,
      identity: identity,
      timeout: timeout,
    );
  }

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    _check(host, port);
    return _inner.tcp(
      host,
      port,
      tls: tls,
      identity: identity,
      timeout: timeout,
    );
  }

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) async {
    _check(host, port);
    return _inner.sendDatagram(host, port, bytes, broadcast: broadcast);
  }

  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) {
    if (!_isLoopback(group)) {
      _blocked.add('$group:$port');
      return Stream.error(
        WatchmeError.unreachable('e2e loopback guard: refusing $group:$port'),
      );
    }
    return _inner.multicastQuery(group, port, query, window);
  }
}

/// A TCP port on loopback that nothing listens on (bound, then released),
/// for pointing the drivers a test does not exercise at a refusal instead
/// of whatever may run on the standard port of the machine.
Future<int> closedPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// A temporary state directory, deleted after the test.
Future<Directory> tempStateDir() async {
  final dir = await Directory.systemTemp.createTemp('watchme_e2e_');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

/// The engine configuration the e2e tests use: real timeouts, but magic
/// packets addressed to loopback rather than the LAN broadcast address.
const EngineConfig e2eConfig = EngineConfig(
  probeTimeout: Duration(seconds: 5),
  connectTimeout: Duration(seconds: 10),
  power: PowerConfig(
    broadcastAddress: '127.255.255.255',
    wakeTimeout: Duration(seconds: 3),
    wakePollInterval: Duration(milliseconds: 200),
  ),
);

/// Everything one engine instance needs, built the way the app builds it,
/// but on [LoopbackTransports] and file stores in [stateDir].
final class E2eSystem {
  E2eSystem._(this.engine, this.transports, this.credentials, this.devices);

  /// Builds and starts an engine with the Roku and Fire TV drivers.
  static Future<E2eSystem> start(
    Directory stateDir, {
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
    Duration? rokuPollInterval,
  }) async {
    final transports = LoopbackTransports();
    final credentials = FileCredentialStore(credentialsPath(stateDir));
    final devices = FileDeviceRepository(devicesPath(stateDir));
    final engine = Engine(
      drivers: [
        RokuDriver(pollInterval: rokuPollInterval),
        FireTvDriver(apiPollInterval: const Duration(milliseconds: 50)),
      ],
      transports: transports,
      discoveryProviders: discovery?.call(transports.network) ?? const [],
      credentials: credentials,
      repository: devices,
      config: e2eConfig,
    );
    await engine.start();
    final system = E2eSystem._(engine, transports, credentials, devices);
    addTearDown(system.close);
    return system;
  }

  /// The engine under test.
  final Engine engine;

  /// The guarded real transports.
  final LoopbackTransports transports;

  /// The credential file store.
  final FileCredentialStore credentials;

  /// The device file store.
  final FileDeviceRepository devices;

  /// Closes the engine and checks that nothing tried to leave loopback.
  Future<void> close() async {
    await engine.close();
    expect(
      transports.blocked,
      isEmpty,
      reason: 'the system tried to reach a non-loopback host',
    );
  }

  /// The credential file in [dir].
  static String credentialsPath(Directory dir) =>
      '${dir.path}${Platform.pathSeparator}credentials.json';

  /// The device file in [dir].
  static String devicesPath(Directory dir) =>
      '${dir.path}${Platform.pathSeparator}devices.json';
}

/// Collects [stream] into a list until the test ends.
List<T> record<T>(Stream<T> stream) {
  final out = <T>[];
  final subscription = stream.listen(out.add);
  addTearDown(subscription.cancel);
  return out;
}

/// Waits until [condition] holds, polling every few milliseconds, or fails
/// after [timeout].
Future<void> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting${reason == null ? '' : ' for $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Answers a pairing flow: submits [pin] (computed when the code step
/// arrives) to every [EnterCode] step and returns every step seen.
Future<List<PairingStep>> runPairing(
  Stream<PairingStep> steps,
  FutureOr<void> Function(String value) submit,
  String Function() pin,
) async {
  final seen = <PairingStep>[];
  await for (final step in steps) {
    seen.add(step);
    if (step is EnterCode) await submit(pin());
    if (step.isTerminal) break;
  }
  return seen;
}
