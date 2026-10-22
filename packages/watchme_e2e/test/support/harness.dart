import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_firetv/watchme_driver_firetv.dart';
import 'package:watchme_driver_panasonic/watchme_driver_panasonic.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_io/watchme_io.dart';

/// The destination policy of every e2e stack and engine: LAN-only, plus
/// loopback, where the simulators run. Tests opt into loopback explicitly;
/// the defaults refuse it.
const DestinationPolicy e2ePolicy = DestinationPolicy(allowLoopback: true);

/// The real `dart:io` transports, wrapped so that nothing can leave the
/// machine: every destination must be a loopback address. A blocked attempt
/// fails like an unreachable host and is recorded in [blocked], which each
/// test checks is empty.
///
/// A second guard sits below the stack, at the `dart:io` socket API (see
/// [nativeBlocked]), so even a stack that ignored its own policy could not
/// open a TCP connection beyond loopback.
final class LoopbackTransports implements Transports {
  /// Wraps a fresh [IoTransports] whose multicast stays on `lo` with TTL 0,
  /// enforcing [e2ePolicy]. [lookup] replaces the stack's resolver.
  LoopbackTransports({HostLookup? lookup})
    : io = IoTransports(
        network: IoNetworkStack(
          multicastInterfaces: [InternetAddress.loopbackIPv4],
          multicastHops: 0,
          destinationPolicy: e2ePolicy,
          lookup: lookup,
        ),
      ) {
    network = _LoopbackOnlyStack(
      io.network,
      blocked,
      passThrough,
      httpLog,
      datagramLog,
    );
  }

  /// The wrapped transports.
  final IoTransports io;

  /// Destinations the guard refused, as `host:port`.
  final List<String> blocked = [];

  /// Hosts this guard hands to the real stack unchecked, for a test that
  /// proves the stack's own policy refuses them. The socket guard below the
  /// stack still stops any connection they would open.
  final Set<String> passThrough = {};

  /// Every HTTP request the engine asked for, as `METHOD uri`, whether it
  /// connected or not (a refused port leaves no trace in a simulator).
  final List<String> httpLog = [];

  /// Every datagram the engine asked to send (magic packets), as
  /// `host:port`, whether it went out or not.
  final List<String> datagramLog = [];

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
  _LoopbackOnlyStack(
    this._inner,
    this._blocked,
    this._passThrough,
    this._httpLog,
    this._datagramLog,
  );

  final NetworkStack _inner;
  final List<String> _blocked;
  final Set<String> _passThrough;
  final List<String> _httpLog;
  final List<String> _datagramLog;

  void _check(String host, int port) {
    if (_isLoopback(host) || _passThrough.contains(host)) return;
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
    _httpLog.add('${call.method} ${call.uri}');
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
    _datagramLog.add('$host:$port');
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

/// TCP connections the socket guard refused, as `host:port`. Checked
/// empty when each [E2eSystem] closes.
final List<String> nativeBlocked = [];

/// The `dart:io` half of the loopback guard: every `Socket.connect` and
/// `Socket.startConnect` in this isolate (simulators and stacks alike)
/// must name a loopback address. Anything else is recorded in
/// [nativeBlocked] and refused before a packet is sent.
final class _LoopbackSockets extends IOOverrides {
  static bool _installed = false;

  /// Installs the guard for the rest of this isolate (one test file).
  static void install() {
    if (_installed) return;
    _installed = true;
    IOOverrides.global = _LoopbackSockets();
  }

  static void _check(Object? host, int port) {
    final loopback = switch (host) {
      final InternetAddress a => a.isLoopback,
      final String h => _isLoopback(h),
      _ => false,
    };
    if (loopback) return;
    final name = host is InternetAddress ? host.address : '$host';
    nativeBlocked.add('$name:$port');
    throw SocketException(
      'e2e socket guard: refusing to connect to $name:$port',
      port: port,
    );
  }

  @override
  Future<Socket> socketConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
    Duration? timeout,
  }) {
    _check(host, port);
    return super.socketConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
      timeout: timeout,
    );
  }

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    _check(host, port);
    return super.socketStartConnect(
      host,
      port,
      sourceAddress: sourceAddress,
      sourcePort: sourcePort,
    );
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

/// Every port name the registered drivers read: Roku `ecp`, Fire TV `dial`
/// and `api`, VIZIO `smartcast` and `smartcastLegacy`, Panasonic `nrc`,
/// Sharp `ipc`.
const List<String> driverPortNames = [
  'ecp',
  'dial',
  'api',
  'smartcast',
  'smartcastLegacy',
  'nrc',
  'ipc',
];

/// A port map that points every driver's port names ([driverPortNames]) at
/// loopback ports nothing listens on, with [ports] on top: a manual add
/// then probes only the simulator the test runs, never whatever runs on a
/// standard port of the machine.
Future<Map<String, int>> portsWith(Map<String, int> ports) async => {
  for (final name in driverPortNames) name: await closedPort(),
  ...ports,
};

/// The Sharp driver's waits, shortened for a loopback simulator that
/// answers at once (the defaults wait a second for a login prompt that a
/// TV without a login never sends).
const SharpTimings e2eSharpTimings = SharpTimings(
  connect: Duration(seconds: 2),
  promptWait: Duration(milliseconds: 200),
  promptWaitWithLogin: Duration(milliseconds: 400),
  loginStep: Duration(milliseconds: 800),
  loginAnswer: Duration(milliseconds: 800),
  loginQuiet: Duration(milliseconds: 80),
  unterminatedQuiet: Duration(milliseconds: 80),
  reply: Duration(seconds: 1),
  powerReply: Duration(milliseconds: 1500),
  probeReply: Duration(seconds: 1),
  probeBudget: Duration(seconds: 3),
  reconnectGap: Duration(milliseconds: 20),
  idleClose: Duration(seconds: 30),
  powerOnSettle: Duration(milliseconds: 600),
  powerOffSettle: Duration(milliseconds: 300),
  bootRetryInterval: Duration(milliseconds: 40),
);

/// The drivers the app registers (see apps/watchme bootstrap), in its
/// order, set up for loopback tests: no polling, short Sharp waits, Fire
/// TV's API polled every 50 ms after a wake. [fireTv] false leaves the
/// Fire TV driver out, for a test that names its simulator's port `api`,
/// which Fire TV's probe would also read.
List<Driver> appDrivers({bool fireTv = true}) => [
  const RokuDriver(),
  if (fireTv) FireTvDriver(apiPollInterval: const Duration(milliseconds: 50)),
  VizioDriver(pollInterval: null),
  PanasonicDriver(pollInterval: null),
  SharpDriver(timings: e2eSharpTimings, pollInterval: null),
];

/// A [WakeOnLanSender] that records each round and runs [onWake] for it,
/// as a TV taking the magic packet would.
final class RecordingWakeOnLan {
  /// Creates a sender; [onWake] stands in for the TV.
  RecordingWakeOnLan({this.onWake});

  /// What the "TV" does with a round of magic packets.
  Future<void> Function(String mac)? onWake;

  /// Each MAC a round went to, in order.
  final List<String> sent = [];

  /// The sender to give the engine.
  Future<bool> send(
    String mac, {
    String? lastKnownIp,
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() ?? false) return false;
    sent.add(mac);
    await onWake?.call(mac);
    return true;
  }
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

  /// Builds and starts an engine with the Roku and Fire TV drivers, with
  /// [e2ePolicy] on the engine and the stack and the socket guard
  /// installed. [lookup] replaces the stack's name resolver; [passThrough]
  /// seeds [LoopbackTransports.passThrough]; [config] defaults to
  /// [e2eConfig]; [rokuRequestTimeout], when given, replaces the Roku
  /// driver's per-request deadline; [fireTvApiStartupTimeout], when given,
  /// replaces how long the Fire TV driver waits for its API after a wake.
  /// [extraDrivers] are registered after those two (see
  /// [ToggleOnlyPowerDriver]). [drivers], when given, replaces the Roku and
  /// Fire TV pair (see [appDrivers]); the Roku and Fire TV options then do
  /// nothing. [wakeOnLan] replaces the engine's own magic packets.
  static Future<E2eSystem> start(
    Directory stateDir, {
    Iterable<DiscoveryProvider> Function(NetworkStack network)? discovery,
    Duration? rokuPollInterval,
    Duration? rokuRequestTimeout,
    Duration? fireTvApiStartupTimeout,
    HostLookup? lookup,
    Set<String> passThrough = const {},
    EngineConfig config = e2eConfig,
    List<Driver>? drivers,
    List<Driver> extraDrivers = const [],
    WakeOnLanSender? wakeOnLan,
  }) async {
    _LoopbackSockets.install();
    addTearDown(nativeBlocked.clear);
    final transports = LoopbackTransports(lookup: lookup)
      ..passThrough.addAll(passThrough);
    final credentials = FileCredentialStore(credentialsPath(stateDir));
    final devices = FileDeviceRepository(devicesPath(stateDir));
    final engine = Engine(
      drivers: [
        if (drivers != null)
          ...drivers
        else if (rokuRequestTimeout == null)
          RokuDriver(pollInterval: rokuPollInterval)
        else
          RokuDriver(
            pollInterval: rokuPollInterval,
            requestTimeout: rokuRequestTimeout,
          ),
        if (drivers == null)
          if (fireTvApiStartupTimeout == null)
            FireTvDriver(apiPollInterval: const Duration(milliseconds: 50))
          else
            FireTvDriver(
              apiPollInterval: const Duration(milliseconds: 50),
              apiStartupTimeout: fireTvApiStartupTimeout,
            ),
        ...extraDrivers,
      ],
      transports: transports,
      discoveryProviders: discovery?.call(transports.network) ?? const [],
      credentials: credentials,
      repository: devices,
      config: config,
      destinationPolicy: e2ePolicy,
      wakeOnLan: wakeOnLan,
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

  /// Closes the engine and checks that nothing tried to leave loopback,
  /// at the stack or at the socket API.
  Future<void> close() async {
    await engine.close();
    expect(
      transports.blocked,
      isEmpty,
      reason: 'the system tried to reach a non-loopback host',
    );
    expect(
      nativeBlocked,
      isEmpty,
      reason: 'a socket was opened to a non-loopback host',
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
/// arrives) to every [EnterCode] step and returns every step seen. Other
/// steps that wait for input are acknowledged with an empty answer.
Future<List<PairingStep>> runPairing(
  Stream<PairingStep> steps,
  FutureOr<void> Function(String value) submit,
  String Function() pin,
) async {
  final seen = <PairingStep>[];
  await for (final step in steps) {
    seen.add(step);
    if (step is EnterCode) {
      await submit(pin());
    } else if (step.awaitsInput) {
      await submit('');
    }
    if (step.isTerminal) break;
  }
  return seen;
}

/// Answers a pairing flow from a script: each step that waits for input
/// gets the next of [answers] (an [Instruct] that waits gets `''` without
/// using one); the flow is cancelled when they run out. Returns every step
/// seen.
Future<List<PairingStep>> runScriptedPairing(
  Stream<PairingStep> steps,
  FutureOr<void> Function(String value) submit,
  Future<void> Function() cancel,
  List<String> answers,
) async {
  final queue = [...answers];
  final seen = <PairingStep>[];
  await for (final step in steps) {
    seen.add(step);
    if (step.isTerminal) break;
    if (!step.awaitsInput) continue;
    if (step is Instruct) {
      await submit('');
    } else if (queue.isEmpty) {
      await cancel();
    } else {
      await submit(queue.removeAt(0));
    }
  }
  return seen;
}

/// A second power route that can only toggle (an IR blaster's power key,
/// say), for the power rules: it recognises every device it is asked
/// about and never touches the network. [toggles] counts what reached it.
final class ToggleOnlyPowerDriver implements Driver {
  /// Creates the driver; give the same instance to each [E2eSystem] that
  /// shares the state directory, so [toggles] counts across restarts.
  ToggleOnlyPowerDriver();

  /// The driver id.
  static const String id = 'e2e-toggle';

  /// Power on and off, both through the one toggle.
  static const List<CapabilitySupport> ceiling = [
    CapabilitySupport.yes(
      Capability.powerOn,
      flags: {CapFlag.toggleOnly, CapFlag.writeOnly},
    ),
    CapabilitySupport.yes(
      Capability.powerOff,
      flags: {CapFlag.toggleOnly, CapFlag.writeOnly},
    ),
  ];

  @override
  final DriverDescriptor descriptor = const DriverDescriptor(
    id: id,
    vendor: 'Test',
    protocol: 'e2e power toggle',
    ceiling: ceiling,
    backends: [],
    stability: Stability.documented,
    provenance: 'e2e fake',
  );

  /// Every command that reached the "device" through this driver: each one
  /// is a press of the power toggle.
  final List<Command> toggles = [];

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async =>
      const ProbeResult.matched(info: DeviceInfo(), capabilities: ceiling);

  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) => null;

  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  }) async => _ToggleSession(toggles);
}

final class _ToggleSession implements DriverSession {
  _ToggleSession(this._toggles);

  final List<Command> _toggles;
  final StreamController<DeviceEvent> _events = StreamController.broadcast();

  @override
  String get driverId => ToggleOnlyPowerDriver.id;

  @override
  List<CapabilitySupport> get capabilities => ToggleOnlyPowerDriver.ceiling;

  @override
  DeviceState get state => DeviceState.empty;

  @override
  Stream<DeviceEvent> get events => _events.stream;

  @override
  Future<CommandResult> execute(Command command) async {
    switch (command) {
      case SetPower() || PressKey(key: RemoteKey.power):
        _toggles.add(command);
        return const Confirmed();
      default:
        return Unsupported('${command.capability.name} is not a toggle');
    }
  }

  @override
  Future<DeviceState> refresh() async => state;

  @override
  Future<void> close() => _events.close();
}
