@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/sharp_simulator.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/harness.dart';

/// The Sharp AQUOS IP-control driver end to end: the real engine, the real
/// `dart:io` TCP stack and the app's drivers against the loopback
/// simulator, with both loopback guards on.
void main() {
  late SharpSimulator sim;
  late Directory dir;
  late E2eSystem system;
  late Map<String, int> ports;

  /// Every query the probe may send; none of them changes the TV.
  const probeQueries = {
    'POWR?   ',
    'MNRD1   ',
    'TVNM1   ',
    'SWVN1   ',
    'IPPV1   ',
    'IPPY1   ',
  };

  /// Quick power settling, so a test can wait the quiet period out.
  const quickQuiet = EngineConfig(
    probeTimeout: Duration(seconds: 5),
    connectTimeout: Duration(seconds: 10),
    power: PowerConfig(
      broadcastAddress: '127.255.255.255',
      wakeTimeout: Duration(seconds: 3),
      wakePollInterval: Duration(milliseconds: 200),
      toggleQuietPeriod: Duration(milliseconds: 500),
    ),
  );

  Future<E2eSystem> startSystem({EngineConfig config = e2eConfig}) =>
      E2eSystem.start(dir, drivers: appDrivers(), config: config);

  Future<void> useSim(SharpSimulator next) async {
    await next.start();
    addTearDown(next.stop);
    sim = next;
    ports = await portsWith({SharpPorts.ipc: sim.port});
  }

  setUp(() async {
    dir = await tempStateDir();
    await useSim(SharpSimulator(rspw: 2));
    system = await startSystem();
  });

  Future<DeviceView> addSharp() =>
      system.engine.addManual('127.0.0.1', ports: ports);

  Future<List<PairingStep>> pair(String id, List<String> answers) {
    final flow = system.engine.pair(id, sharpDriverId);
    return runScriptedPairing(flow.steps, flow.submit, flow.cancel, answers);
  }

  DriverView driver() => system.engine.currentDevices.single.drivers.single;

  Future<CommandResult> send(String id, Command command) =>
      system.engine.send(id, command);

  /// The command lines sent since the log was last cleared, without the
  /// queries.
  List<String> writes() => [
    for (final line in sim.lines)
      if (!line.contains('?') && !probeQueries.contains(line)) line,
  ];

  group('manual add', () {
    test('a TV without a login is recognised by queries alone, works at '
        'once, and still offers pairing', () async {
      final view = await addSharp();
      expect(view.drivers.map((d) => d.driverId), [sharpDriverId]);
      expect(view.manufacturer, 'Sharp');
      expect(view.needsPairing, isFalse);
      expect(driver().canPair, isTrue, reason: 'login and network power-on');
      expect(sim.lines, isNotEmpty);
      expect(sim.lines, everyElement(isIn(probeQueries)));
      expect(view.state.power?.value, PowerMode.on);
      expect(view.state.power?.confidence, Confidence.reported);

      sim.clearLog();
      expect(await send(view.id, const PressKey(RemoteKey.up)), isConfirmed);
      expect(writes(), ['RCKY41  ']);
    });

    test('a TV that asks for a login needs pairing, and the probe sends '
        'it nothing', () async {
      await useSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 2),
      );
      final view = await addSharp();
      expect(view.needsPairing, isTrue);
      expect(sim.successfulLogins + sim.failedLogins, 0);
      expect(sim.rawInput.join(), isEmpty);
      expect(
        await send(view.id, const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.unauthorized),
      );
      expect(sim.lines, isEmpty);
    });

    test('refreshes never wake a TV in network standby', () async {
      await useSim(
        SharpSimulator(
          profile: SharpSimProfile.us2014,
          quickStart: true,
          power: SharpSimPower.networkStandby,
        ),
      );
      final view = await addSharp();
      expect(view.state.power?.value, PowerMode.standby);
      for (var i = 0; i < 3; i++) {
        await system.engine.refresh(view.id);
      }
      expect(sim.power, SharpSimPower.networkStandby);
      expect(sim.lines, everyElement(isIn(probeQueries)));
    });
  });

  group('pairing through engine.pair', () {
    test('the login is collected with EnterText, checked, and stored; the '
        'network power-on setting is changed only on yes', () async {
      await useSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 0),
      );
      final id = (await addSharp()).id;
      final events = record(system.engine.events(id));
      final steps = await pair(id, ['admin', 'secret1', ConfirmChange.yes]);
      expect(steps.whereType<EnterText>().map((s) => s.secret), [false, true]);
      final confirm = steps.whereType<ConfirmChange>().single;
      expect(confirm.question, contains('over the network'));
      expect(steps.last, const Paired.redacted());
      expect(sim.rspw, 2);
      expect(writes(), ['RSPW2   ']);

      final stored = await system.credentials.read(id, sharpDriverId);
      final credential = stored! as SharedSecretCredential;
      expect(credential.username, 'admin');
      expect(credential.secret, 'secret1');
      final file = File(E2eSystem.credentialsPath(dir));
      expect(file.statSync().mode & 0x1ff, 0x180, reason: 'mode 0600');

      expect(driver().paired, isTrue);
      expect(driver().connection, ConnectionState.connected);
      final shown = [
        jsonEncode(system.engine.currentDevices.single.toJson()),
        for (final s in steps) ...[jsonEncode(s.toJson()), '$s'],
        for (final e in events) jsonEncode(e.toJson()),
      ].join('\n');
      expect(shown, isNot(contains('secret1')));

      sim.clearLog();
      expect(await send(id, const PressKey(RemoteKey.up)), isConfirmed);
      expect(writes(), ['RCKY41  ']);
    });

    test('no leaves the setting alone', () async {
      await useSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 0),
      );
      final id = (await addSharp()).id;
      final steps = await pair(id, ['admin', 'secret1', ConfirmChange.no]);
      expect(steps.last, const Paired.redacted());
      expect(sim.rspw, 0);
      expect(writes(), isEmpty);
    });

    test('a TV without a login can be paired for network power-on '
        'alone', () async {
      await useSim(SharpSimulator(rspw: 0));
      final id = (await addSharp()).id;
      final steps = await pair(id, [ConfirmChange.yes]);
      expect(steps.whereType<EnterText>(), isEmpty);
      expect(steps.last, const Paired.redacted());
      expect(sim.rspw, 2);
      final stored =
          (await system.credentials.read(id, sharpDriverId))!
              as SharedSecretCredential;
      expect(isSharpNoLogin(stored), isTrue);
      expect(driver().paired, isTrue);
      expect(driver().needsPairing, isFalse);
    });

    test('a wrong login is asked again; three fail as unauthorized and '
        'show no secret', () async {
      await useSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 2),
      );
      final id = (await addSharp()).id;
      var steps = await pair(id, ['admin', 'wrong', 'admin', 'secret1']);
      expect(steps.whereType<EnterText>(), hasLength(4));
      expect(
        steps.whereType<EnterText>().elementAt(2).label,
        contains('was wrong'),
      );
      expect(steps.last, const Paired.redacted());

      sim.mismatchText =
          '\r\nUser Name or Password mismatch (admin/hunter2)\r\n';
      steps = await pair(id, [
        for (var i = 0; i < 3; i++) ...['admin', 'hunter2'],
      ]);
      expect(
        steps.last,
        isPairingFailedWith(
          WatchmeErrorCode.unauthorized,
          rawDeviceMessage: contains('User Name or Password mismatch'),
        ),
      );
      final failure = (steps.last as PairingFailed).error;
      expect(
        '${jsonEncode(failure.toJson())} $failure ${failure.cause}',
        isNot(contains('hunter2')),
      );
    });

    test('a changed password surfaces ReauthRequired, and the old login is '
        'not tried again until the user pairs', () async {
      await useSim(
        SharpSimulator(loginId: 'admin', password: 'secret1', rspw: 2),
      );
      final id = (await addSharp()).id;
      expect(
        (await pair(id, ['admin', 'secret1'])).last,
        const Paired.redacted(),
      );
      final events = record(system.engine.events(id));
      sim.password = 'secret2';
      await sim.dropConnections();
      expect(
        await send(id, const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      await eventually(() => events.whereType<ReauthRequired>().isNotEmpty);
      expect(system.engine.currentDevices.single.needsPairing, isTrue);
      final logins = sim.failedLogins;
      expect(
        await send(id, const PressKey(RemoteKey.up)),
        isFailedWith(WatchmeErrorCode.reauthRequired),
      );
      expect(sim.failedLogins, logins);

      expect(
        (await pair(id, ['admin', 'secret2'])).last,
        const Paired.redacted(),
      );
      sim.clearLog();
      expect(await send(id, const PressKey(RemoteKey.up)), isConfirmed);
      expect(writes(), ['RCKY41  ']);
    });
  });

  group('commands', () {
    late String id;

    setUp(() async {
      id = (await addSharp()).id;
      sim.clearLog();
    });

    test('keys, volume, mute, input and Netflix', () async {
      for (final key in [RemoteKey.up, RemoteKey.select, RemoteKey.back]) {
        expect(await send(id, PressKey(key)), isConfirmed);
      }
      expect(await send(id, const SetVolume(50)), isConfirmed);
      expect(sim.volume, 30, reason: 'this model counts 0-60');
      expect(await send(id, const SetMute(true)), isConfirmed);
      expect(sim.muted, isTrue);
      expect(await send(id, const SelectInput('hdmi2')), isConfirmed);
      expect(sim.iavd, 2);
      expect(await send(id, const LaunchApp('netflix')), isConfirmed);
      expect(sim.foregroundApp, isNotNull);
      expect(writes(), [
        'RCKY41  ',
        'RCKY40  ',
        'RCKY45  ',
        'VOLM30  ',
        'MUTE1   ',
        'IAVD2   ',
        'RCKY59  ',
      ]);
    });

    test('a refresh reads the volume back on the 0-100 scale', () async {
      expect(await send(id, const PressKey(RemoteKey.up)), isConfirmed);
      sim.volume = 45;
      await system.engine.refresh(id);
      final volume = system.engine.currentDevices.single.state.volume;
      expect(volume?.value, 75);
      expect(volume?.confidence, Confidence.reported);
    });

    test('a channel cut short after its first part is a partial delivery, '
        'and nothing falls back', () async {
      sim.failNext('DC2L', SharpSimFault.drop);
      expect(
        await send(id, const TuneChannel('123.45')),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(writes(), ['DC2U123 ', 'DC2L045 ']);
    });
  });

  group('power', () {
    test('its own POWR? report lets the power key switch off and on with '
        'the discrete commands, never the POWER key', () async {
      await useSim(
        SharpSimulator(
          profile: SharpSimProfile.us2014,
          quickStart: true,
          bootDuration: const Duration(milliseconds: 200),
        ),
      );
      await system.close();
      system = await startSystem(config: quickQuiet);
      final id = (await addSharp()).id;
      sim.clearLog();

      expect(await send(id, const PressKey(RemoteKey.power)), isConfirmed);
      expect(writes(), ['POWR0   ']);
      expect(sim.power, SharpSimPower.networkStandby);

      // Within the quiet period the report may lag: the next press asks.
      expect(
        await send(id, const PressKey(RemoteKey.power)),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(writes(), ['POWR0   ']);

      await Future<void>.delayed(quickQuiet.power.toggleQuietPeriod);
      expect(await send(id, const PressKey(RemoteKey.power)), isConfirmed);
      expect(writes(), ['POWR0   ', 'POWR1   ']);
      expect(sim.lines, isNot(contains('RCKY12  ')));
      await eventually(() => sim.power == SharpSimPower.on);

      // The state is read back once the TV has settled.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await system.engine.refresh(id);
      final power = system.engine.currentDevices.single.state.power;
      expect(power?.value, PowerMode.on);
      expect(power?.confidence, Confidence.reported);
    });

    test('a TV without network standby that closed its port is '
        'unreachable, not off', () async {
      await useSim(
        SharpSimulator(standbyCloseDelay: const Duration(milliseconds: 20)),
      );
      final id = (await addSharp()).id;
      expect(await send(id, const SetPower(false)), isConfirmed);
      // Off without network standby: the port closes, then, a moment
      // later, the open connection.
      await eventually(
        () => !sim.isListening && sim.openConnections == 0,
        reason: 'the TV to close its port and connection',
      );

      await system.engine.refresh(id);
      final power = system.engine.currentDevices.single.state.power;
      expect(power?.value, isNot(PowerMode.off));
      expect(power?.confidence, Confidence.stale);
      expect(driver().lastError?.code, WatchmeErrorCode.unreachable);

      // Added by IP: no MAC, so no Wake-on-LAN; and no toggle exists.
      sim.clearLog();
      expect(
        await send(id, const SetPower(true)),
        isFailedWith(WatchmeErrorCode.unreachable),
      );
      expect(system.transports.datagramLog, isEmpty);
      expect(sim.lines, isEmpty);
      expect(sim.power, isNot(SharpSimPower.on));
    });
  });

  // Codex re-review of 7b4855f (Reqall 9526): the engine waited for the
  // session's close, but that close did not wait for the connection a
  // failed send was still closing, so pairing connected while the old
  // connection held the TV's only client slot, and failed as unreachable.
  test('pairing waits for the connection a failed send left closing, then '
      'gets the TV\'s only client slot', () async {
    final gated = _GatedSharpDriver();
    await system.close();
    system = await E2eSystem.start(dir, drivers: [gated]);
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    final id = (await addSharp()).id;
    expect(await send(id, const PressKey(RemoteKey.up)), isConfirmed);
    gated
      ..failAfterSending = 'RCKY33'
      ..holdCloseUntil = release.future;
    expect(
      await send(id, const PressKey(RemoteKey.volumeUp)),
      isFailedWith(WatchmeErrorCode.timeout),
    );
    expect(sim.openConnections, 1, reason: 'still closing');

    final connects = gated.connects;
    final pairing = pair(id, const []);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(gated.connects, connects, reason: 'the old connection holds it');
    expect(sim.overflowClosed, 0);

    release.complete();
    final steps = await pairing;
    expect(steps.last, const Paired.redacted());
    expect(driver().connection, ConnectionState.connected);
    expect(sim.lines.where((l) => l == 'RCKY33  '), hasLength(1));
  });
}

/// The app's Sharp driver on sockets that fail one send after handing its
/// bytes over ([failAfterSending]), and whose close then waits for
/// [holdCloseUntil], as a close that waits for the TV can: until then the
/// connection holds the TV's client slot.
final class _GatedSharpDriver implements Driver {
  final SharpDriver _inner = SharpDriver(
    timings: e2eSharpTimings,
    pollInterval: null,
  );

  /// The next send that starts with this text goes out, then throws.
  String? failAfterSending;

  /// What the close of that send's socket waits for.
  Future<void>? holdCloseUntil;

  /// TCP connections opened so far.
  int connects = 0;

  Transports _gate(Transports transports) => _GatedTransports(this, transports);

  @override
  DriverDescriptor get descriptor => _inner.descriptor;

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) =>
      _inner.probe(endpoint, _gate(transports));

  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) => _inner.startPairing(endpoint, _gate(transports), context);

  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  }) => _inner.connect(
    endpoint,
    _gate(transports),
    credential,
    allowWake: allowWake,
  );
}

final class _GatedTransports implements Transports {
  _GatedTransports(_GatedSharpDriver driver, this._inner)
    : network = _GatedStack(driver, _inner.requireNetwork());

  final Transports _inner;

  @override
  final NetworkStack network;

  @override
  Set<TransportFeature> get features => _inner.features;

  @override
  SerialPortProvider? get serial => _inner.serial;

  @override
  BleCentral? get ble => _inner.ble;

  @override
  HidPeripheral? get hid => _inner.hid;

  @override
  IrEmitter? get ir => _inner.ir;

  @override
  ProcessRunner? get process => _inner.process;
}

final class _GatedStack implements NetworkStack {
  _GatedStack(this._driver, this._inner);

  final _GatedSharpDriver _driver;
  final NetworkStack _inner;

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    final socket = await _inner.tcp(
      host,
      port,
      tls: tls,
      identity: identity,
      timeout: timeout,
    );
    _driver.connects++;
    return _GatedSocket(_driver, socket);
  }

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) => _inner.http(call, tls: tls, identity: identity);

  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) => _inner.webSocket(
    uri,
    protocols: protocols,
    headers: headers,
    tls: tls,
    identity: identity,
    timeout: timeout,
  );

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) => _inner.sendDatagram(host, port, bytes, broadcast: broadcast);

  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) => _inner.multicastQuery(group, port, query, window);
}

final class _GatedSocket implements ByteSocket {
  _GatedSocket(this._driver, this._inner);

  final _GatedSharpDriver _driver;
  final ByteSocket _inner;
  Future<void>? _holdClose;

  @override
  void send(List<int> bytes) {
    _inner.send(bytes);
    final fail = _driver.failAfterSending;
    if (fail != null && String.fromCharCodes(bytes).startsWith(fail)) {
      _driver.failAfterSending = null;
      _holdClose = _driver.holdCloseUntil;
      throw StateError('send failed after queueing');
    }
  }

  @override
  Future<void> close() async {
    final hold = _holdClose;
    if (hold != null) await hold;
    await _inner.close();
  }

  @override
  Stream<Uint8List> get input => _inner.input;

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> get done => _inner.done;

  @override
  String? get peerCertificateSha256 => _inner.peerCertificateSha256;

  @override
  Uint8List? get peerCertificateDer => _inner.peerCertificateDer;
}
