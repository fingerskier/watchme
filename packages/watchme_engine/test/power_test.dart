import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const mac = 'aa:bb:cc:dd:ee:01';
const discreteOn = CapabilitySupport.yes(Capability.powerOn);
const discreteOff = CapabilitySupport.yes(Capability.powerOff);
const toggleOn = CapabilitySupport.yes(
  Capability.powerOn,
  flags: {CapFlag.toggleOnly},
);
const toggleOff = CapabilitySupport.yes(
  Capability.powerOff,
  flags: {CapFlag.toggleOnly},
);
const powerState = CapabilitySupport.yes(Capability.powerState);

bool isPowerCommand(Command c) =>
    c is SetPower || c == const PressKey(RemoteKey.power);

/// A device whose drivers answer probes only while [online] is true. A
/// probe reports the power observation in [probePower] for its driver, as
/// Roku's device-info or a Samsung REST probe would.
class Rig {
  Rig(List<FakeDriver> drivers, {String? mac, WakeOnLanSender? wakeOnLan})
    : h = Harness(drivers: drivers, wakeOnLan: wakeOnLan) {
    for (final d in drivers) {
      d.onProbe = (_) => online
          ? matched(
              name: 'TV',
              mac: mac,
              capabilities: d.descriptor.ceiling,
              power: probePower[d.id],
            )
          : const ProbeResult.notMatched(
              error: WatchmeError.unreachable('no route to host'),
            );
    }
  }

  final Harness h;
  bool online = true;
  final Map<String, Observed<PowerMode>> probePower = {};
  late final String id;

  Future<Rig> add() async {
    id = await h.add('192.0.2.40');
    return this;
  }

  Observed<PowerMode> says(
    PowerMode mode,
    String source, {
    Duration ago = Duration.zero,
  }) => Observed.reported(mode, source, h.clock.now().subtract(ago));

  /// Makes [driver]'s probe report [mode] now.
  void probeSays(FakeDriver driver, PowerMode mode, {Duration? ago}) =>
      probePower[driver.id] = says(mode, driver.id, ago: ago ?? Duration.zero);

  Future<CommandResult> power(bool on) => h.engine.send(id, SetPower(on));
}

const powerOnUnavailable = CapabilitySupport(
  Capability.powerOn,
  Support.no,
  note: 'Control by mobile apps is Limited',
);

void main() {
  group('power on', () {
    test('a discrete power-on is preferred over a toggle', () async {
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOn]);
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rig = await Rig([ws, roku]).add();
      addTearDown(rig.h.close);

      expect(await rig.power(true), isConfirmed);
      expect(roku.executed, [const SetPower(true)]);
      expect(ws.executed, isEmpty);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isTrue);
      expect(rig.h.transports.net.sentDatagrams, isEmpty);
    });

    test('Wake-on-LAN goes to the cached MAC on ports 9 and 7, repeated; '
        'once the TV answers, the discrete power-on is retried', () async {
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOn]);
      final rig = await Rig([roku], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      roku.connectError = const WatchmeError.unreachable('no route to host');

      final result = rig.power(true);
      await rig.h.clock.flush();
      final net = rig.h.transports.net;
      // The first round: limited broadcast and unicast to the last IP, on
      // both conventional ports.
      expect(net.sentDatagrams.map((d) => (d.host, d.port, d.broadcast)), [
        ('255.255.255.255', wakeOnLanPort, true),
        ('192.0.2.40', wakeOnLanPort, false),
        ('255.255.255.255', 7, true),
        ('192.0.2.40', 7, false),
      ]);
      for (final d in net.sentDatagrams) {
        expect(d.bytes, magicPacket(mac));
      }

      rig.online = true;
      roku.connectError = null;
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(await result, isConfirmed);
      expect(roku.executed, [const SetPower(true)]);
      // Three rounds in all, Wi-Fi being lossy.
      expect(net.sentDatagrams, hasLength(12));
    });

    test('Wake-on-LAN for a TV with no discrete power-on is confirmed when '
        'it then reports itself on', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 4));
      rig
        ..online = true
        ..probeSays(dial, PowerMode.on);
      await rig.h.clock.advance(const Duration(seconds: 2));
      expect(await result, isConfirmed);
    });

    test('a device that answers after Wake-on-LAN without saying it is on is '
        'not confirmed', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 4));
      rig.online = true;
      await rig.h.clock.advance(const Duration(seconds: 2));
      expect(await result, isSentUnconfirmed);
    });

    test('a Roku TV in standby (Limited mode) answering device-info does not '
        'confirm Wake-on-LAN', () async {
      // Limited mode: PowerOn is unusable, so Wake-on-LAN is the route, and
      // device-info keeps answering "Ready" whether or not the TV woke.
      final roku = FakeDriver('roku.ecp', ceiling: const [powerOnUnavailable]);
      final rig = await Rig([roku], mac: mac).add();
      addTearDown(rig.h.close);
      rig.probeSays(roku, PowerMode.standby);

      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(await result, isSentUnconfirmed);
      expect(rig.h.transports.net.sentDatagrams, isNotEmpty);
      expect(roku.executed, isEmpty);
    });

    test('a refused discrete power-on is retried after Wake-on-LAN but a '
        'device that answers all along is not confirmed', () async {
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn],
        onExecute: (_) => const Failed(
          WatchmeError.rejected(
            'Limited mode',
            rawDeviceMessage: 'ECP command not allowed in Limited mode.',
          ),
        ),
      );
      final rig = await Rig([roku], mac: mac).add();
      addTearDown(rig.h.close);
      rig.probeSays(roku, PowerMode.standby);

      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(await result, isSentUnconfirmed);
      expect(roku.executed, [const SetPower(true), const SetPower(true)]);
    });

    test('a refused retry is still confirmed by a fresh "on" report', () async {
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn],
        onExecute: (_) => const Failed(WatchmeError.rejected('refused')),
      );
      final rig = await Rig([roku], mac: mac).add();
      addTearDown(rig.h.close);
      // An "on" from before the wake does not count...
      rig.probeSays(roku, PowerMode.on, ago: const Duration(seconds: 1));
      final stale = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 1));
      // ...but the probe after the wake reports the TV on.
      rig.probeSays(roku, PowerMode.on);
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(await stale, isConfirmed);
    });

    test(
      'Wake-on-LAN goes through the injected sender when there is one',
      () async {
        final calls = <(String, String?)>[];
        Future<bool> sender(String m, {String? lastKnownIp}) async {
          calls.add((m, lastKnownIp));
          return true;
        }

        final dial = FakeDriver('dial');
        final rig = await Rig([dial], mac: mac, wakeOnLan: sender).add();
        addTearDown(rig.h.close);
        rig.online = false;
        final result = rig.power(true);
        await rig.h.clock.flush();
        expect(calls, [(mac, '192.0.2.40')]);
        expect(rig.h.transports.net.sentDatagrams, isEmpty);
        await rig.h.clock.advance(const Duration(seconds: 31));
        expect(await result, isSentUnconfirmed);
      },
    );

    test('a sender that sends nothing means no Wake-on-LAN went out', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig(
        [dial],
        mac: mac,
        wakeOnLan: (_, {lastKnownIp}) async => false,
      ).add();
      addTearDown(rig.h.close);
      expect(await rig.power(true), isUnsupported(contains('Wake-on-LAN')));
    });

    test('closing the engine stops a wait for the device to wake', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      rig.online = false;
      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 3));
      final probesBefore = dial.probes.length;
      await rig.h.close();
      await rig.h.clock.advance(const Duration(seconds: 40));
      expect(await result, isFailedWith(WatchmeErrorCode.cancelled));
      expect(dial.probes, hasLength(probesBefore));
      expect(dial.connects, isEmpty);
    });

    test('no toggle after Wake-on-LAN, even with agreeing sources', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest], mac: mac).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.standby)
        ..probeSays(rest, PowerMode.standby)
        ..online = false;

      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 31));
      expect(await result, isSentUnconfirmed);
      expect(rig.h.transports.net.sentDatagrams, isNotEmpty);
      expect(ws.executed.where(isPowerCommand), isEmpty);
    });

    test(
      'a toggle is sent when two independent sources agree it is off',
      () async {
        final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
        final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
        final rig = await Rig([ws, rest]).add();
        addTearDown(rig.h.close);
        rig
          ..probeSays(ws, PowerMode.standby)
          ..probeSays(rest, PowerMode.off);

        expect(await rig.power(true), isConfirmed);
        expect(ws.executed, [const SetPower(true)]);
      },
    );

    test('one source is not enough: needs confirmation, and gathering the '
        'evidence connects nothing', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rig = await Rig([ws]).add();
      addTearDown(rig.h.close);
      rig.probeSays(ws, PowerMode.standby);

      expect(
        await rig.power(true),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(ws.executed, isEmpty);
      expect(ws.connects, isEmpty, reason: 'connecting can wake a TV');
    });

    test('an open session is refreshed for evidence', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.standby)
        ..probeSays(rest, PowerMode.standby);
      expect(await rig.power(true), isConfirmed);
      final session = ws.lastSession;
      final refreshes = session.refreshes;

      await rig.h.clock.advance(const Duration(seconds: 30));
      // With a session open, its refreshed state is the WebSocket's evidence
      // (its probe still says standby and is not consulted).
      session.onRefresh = () =>
          DeviceState(power: rig.says(PowerMode.on, 'samsung.ws'));
      rig.probeSays(rest, PowerMode.on);
      expect(await rig.power(false), isConfirmed);
      expect(session.refreshes, greaterThan(refreshes));
      expect(ws.connects, hasLength(1));
      expect(ws.executed, [const SetPower(true), const SetPower(false)]);
    });

    test('disagreeing, stale or old sources: needs confirmation', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig.probeSays(ws, PowerMode.standby);

      // Samsung answers for ~20 s after off: one source still says on.
      rig.probeSays(rest, PowerMode.on);
      expect(
        await rig.power(true),
        isUnsupported(Unsupported.needsConfirmation),
      );

      rig.probePower['samsung.rest'] = Observed(
        PowerMode.standby,
        'samsung.rest',
        rig.h.clock.now(),
        Confidence.stale,
      );
      expect(
        await rig.power(true),
        isUnsupported(Unsupported.needsConfirmation),
      );

      // A report from long ago does not count either (PowerState stuck at
      // standby after a wake, HA #187048).
      rig
        ..probeSays(ws, PowerMode.standby, ago: const Duration(minutes: 3))
        ..probeSays(rest, PowerMode.standby);
      await rig.h.clock.advance(const Duration(minutes: 3));
      rig.probeSays(rest, PowerMode.standby);
      expect(
        await rig.power(true),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(ws.executed.where(isPowerCommand), isEmpty);
    });

    test('an unreachable device counts as one source', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig.probeSays(rest, PowerMode.standby);
      // The WebSocket is down (TV in standby), REST still answers.
      ws.onProbe = (_) => const ProbeResult.notMatched(
        error: WatchmeError.unreachable('refused'),
      );
      ws.connectError = const WatchmeError.unreachable('refused');
      expect(
        await rig.power(true),
        isFailedWith(WatchmeErrorCode.unreachable),
        reason: 'agreed, so the toggle was attempted, but its route is down',
      );
      expect(ws.connects, isNotEmpty);
    });

    test('no toggle within the quiet period after a power command', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      expect(await rig.power(false), isConfirmed);
      expect(ws.executed, [const SetPower(false)]);

      await rig.h.clock.advance(const Duration(seconds: 5));
      ws.lastSession.report(
        DeviceState(power: rig.says(PowerMode.standby, 'samsung.ws')),
      );
      rig.probeSays(rest, PowerMode.standby);
      expect(
        await rig.power(true),
        isUnsupported(Unsupported.needsConfirmation),
      );

      await rig.h.clock.advance(const Duration(seconds: 20));
      ws.lastSession.onRefresh = () =>
          DeviceState(power: rig.says(PowerMode.standby, 'samsung.ws'));
      rig.probeSays(rest, PowerMode.standby);
      expect(await rig.power(true), isConfirmed);
      expect(ws.executed, [const SetPower(false), const SetPower(true)]);
    });

    test(
      'a toggle falls back to the power key when SetPower is unmapped',
      () async {
        final ws = FakeDriver(
          'samsung.ws',
          ceiling: const [toggleOn],
          onExecute: (c) => c is SetPower
              ? const Unsupported('no SetPower')
              : const SentUnconfirmed(),
        );
        final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
        final rig = await Rig([ws, rest]).add();
        addTearDown(rig.h.close);
        rig
          ..probeSays(ws, PowerMode.standby)
          ..probeSays(rest, PowerMode.standby);
        expect(await rig.power(true), isSentUnconfirmed);
        expect(ws.executed, [
          const SetPower(true),
          const PressKey(RemoteKey.power),
        ]);
      },
    );

    test('nothing to turn it on with', () async {
      final rig = await Rig([FakeDriver('dial')]).add();
      addTearDown(rig.h.close);
      expect(await rig.power(true), isUnsupported(contains('Wake-on-LAN')));
    });
  });

  group('power off', () {
    test('a discrete power-off is preferred', () async {
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
      final rig = await Rig([ws, roku]).add();
      addTearDown(rig.h.close);
      expect(await rig.power(false), isConfirmed);
      expect(roku.executed, [const SetPower(false)]);
      expect(ws.executed, isEmpty);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isFalse);
    });

    test('a device a passive probe sees asleep is not woken to be turned '
        'off', () async {
      final firetv = FakeDriver(
        'firetv.lightning',
        ceiling: const [discreteOff],
      );
      final rig = await Rig([firetv]).add();
      addTearDown(rig.h.close);
      rig.probePower['firetv.lightning'] = Observed.inferred(
        PowerMode.standby,
        'firetv.lightning',
        rig.h.clock.now(),
      );
      expect(await rig.power(false), isConfirmed);
      expect(firetv.connects, isEmpty, reason: 'connecting wakes a Fire TV');
      expect(firetv.executed, isEmpty);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isFalse);
      expect(rig.h.view(rig.id).state.power?.value, PowerMode.standby);
    });

    test('an open session is used without probing first', () async {
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
      final rig = await Rig([roku]).add();
      addTearDown(rig.h.close);
      expect(await rig.power(false), isConfirmed);
      final probes = roku.probes.length;
      rig.probeSays(roku, PowerMode.standby);
      expect(await rig.power(false), isConfirmed);
      expect(roku.probes, hasLength(probes));
      expect(roku.executed, [const SetPower(false), const SetPower(false)]);
    });

    test('a toggle needs two sources agreeing it is on', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig.probeSays(ws, PowerMode.on);
      expect(
        await rig.power(false),
        isUnsupported(Unsupported.needsConfirmation),
      );
      rig.probeSays(rest, PowerMode.on);
      expect(await rig.power(false), isConfirmed);
      expect(ws.executed, [const SetPower(false)]);
    });

    test('a failed discrete power-off returns the device error', () async {
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOff],
        onExecute: (_) => const Failed(
          WatchmeError.rejected(
            'Limited mode',
            rawDeviceMessage: 'ECP command not allowed in Limited mode.',
          ),
        ),
      );
      final rig = await Rig([roku]).add();
      addTearDown(rig.h.close);
      expect(
        await rig.power(false),
        isFailedWith(
          WatchmeErrorCode.rejected,
          rawDeviceMessage: contains('Limited mode'),
        ),
      );
      expect(rig.h.engine.power.lastCommand(rig.id), isNull);
    });
  });

  test('an explicit power key press is the user\'s own toggle', () async {
    final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
    final rig = await Rig([ws]).add();
    addTearDown(rig.h.close);
    expect(
      await rig.h.engine.send(rig.id, const PressKey(RemoteKey.power)),
      isConfirmed,
    );
    expect(ws.executed, [const PressKey(RemoteKey.power)]);
  });

  test('PowerOrchestrator never throws', () async {
    final orchestrator = PowerOrchestrator(
      transports: FakeTransports(),
      clock: FakeClock(),
    );
    expect(
      await orchestrator.setPower(_ThrowingTarget(), true),
      isFailedWith(WatchmeErrorCode.internal),
    );
  });
}

class _ThrowingTarget implements PowerTarget {
  @override
  String get deviceId => 'x';

  @override
  String get host => '192.0.2.1';

  @override
  Set<String> get macs => const {};

  @override
  List<RouteCandidate> routes(Capability capability) =>
      throw StateError('boom');

  @override
  Future<RouteAttempt> execute(RouteCandidate route, Command command) =>
      throw StateError('boom');

  @override
  Future<List<Observed<PowerMode>>> powerEvidence() async => const [];

  @override
  Future<bool> answers() async => false;
}
