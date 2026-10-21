import 'dart:async';

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
    id = await h.add('10.0.2.40');
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

/// The result of a power operation that [PowerOrchestrator.close] cut short
/// after something it sent may have reached the device: not a bare
/// "cancelled", which would say nothing happened.
final Matcher isInterruptedAfterSending = allOf(
  isFailedWith(WatchmeErrorCode.partiallyDelivered),
  isA<Failed>().having(
    (f) => f.error.cause,
    'cause',
    isWatchmeError(WatchmeErrorCode.cancelled),
  ),
);

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
        ('10.0.2.40', wakeOnLanPort, false),
        ('255.255.255.255', 7, true),
        ('10.0.2.40', 7, false),
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

    test('Wake-on-LAN goes through the injected sender when there is one, '
        'once per round', () async {
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
      expect(calls, [(mac, '10.0.2.40')]);
      expect(rig.h.transports.net.sentDatagrams, isEmpty);
      // The orchestrator repeats the round itself, so it can stop between
      // rounds when it is closed.
      await rig.h.clock.advance(const Duration(milliseconds: 200));
      expect(calls, List.filled(3, (mac, '10.0.2.40')));
      await rig.h.clock.advance(const Duration(seconds: 31));
      expect(await result, isSentUnconfirmed);
      expect(calls, hasLength(3));
    });

    test('a sender that sends nothing means no Wake-on-LAN went out', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig(
        [dial],
        mac: mac,
        wakeOnLan: (_, {lastKnownIp}) async => false,
      ).add();
      addTearDown(rig.h.close);
      final result = rig.power(true);
      // Every round is tried, 100 ms apart.
      await rig.h.clock.advance(const Duration(milliseconds: 200));
      expect(await result, isUnsupported(contains('Wake-on-LAN')));
    });

    test('closing the engine stops a wait for the device to wake', () async {
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      rig.online = false;
      final result = rig.power(true);
      await rig.h.clock.advance(const Duration(seconds: 3));
      final probesBefore = dial.probes.length;
      final packets = rig.h.transports.net.sentDatagrams.length;
      await rig.h.close();
      await rig.h.clock.advance(const Duration(seconds: 40));
      // The packets went out before the close: the device may still wake.
      expect(await result, isInterruptedAfterSending);
      expect(dial.probes, hasLength(probesBefore));
      expect(dial.connects, isEmpty);
      expect(rig.h.transports.net.sentDatagrams, hasLength(packets));
    });

    test('closing the engine between Wake-on-LAN rounds sends no more '
        'packets, and the caller learns that some went out', () async {
      // Codex re-review, new finding 1 (Reqall 9365): close() answered
      // "cancelled" while the wake loop went on, and the 4 packets of the
      // first round became 12 a second later.
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      rig.online = false;
      CommandResult? result;
      unawaited(rig.power(true).then((r) => result = r));
      await rig.h.clock.flush();
      final net = rig.h.transports.net;
      expect(net.sentDatagrams, hasLength(4), reason: 'the first round');

      await rig.h.close();
      await rig.h.clock.advance(const Duration(seconds: 1));
      expect(net.sentDatagrams, hasLength(4));
      expect(result, isInterruptedAfterSending);
      await rig.h.clock.advance(const Duration(seconds: 40));
      expect(net.sentDatagrams, hasLength(4));
      expect(dial.connects, isEmpty);
    });

    test('closing the engine while the injected sender is sending: no '
        'further round, and the caller gets a result within a second that '
        'says packets may have gone out', () async {
      var calls = 0;
      final sending = Completer<bool>();
      Future<bool> sender(String m, {String? lastKnownIp}) {
        calls++;
        return sending.future;
      }

      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac, wakeOnLan: sender).add();
      rig.online = false;
      CommandResult? result;
      unawaited(rig.power(true).then((r) => result = r));
      await rig.h.clock.flush();
      expect(calls, 1);

      await rig.h.close();
      expect(result, isNull, reason: 'a packet may be on its way');
      await rig.h.clock.advance(const Duration(seconds: 1));
      expect(result, isInterruptedAfterSending);

      sending.complete(true);
      await rig.h.clock.advance(const Duration(seconds: 40));
      expect(calls, 1);
      expect(dial.probes, hasLength(1), reason: 'only the add probed');
    });

    test('a later request for something else ends the wait after '
        'Wake-on-LAN', () async {
      // Verifier follow-up to Codex finding #2: serialising power commands
      // held an "off" behind the 30 s wait of an earlier "on".
      final dial = FakeDriver('dial');
      final rig = await Rig([dial], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      CommandResult? onResult;
      unawaited(rig.power(true).then((r) => onResult = r));
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(onResult, isNull, reason: 'still waiting for the device');
      final probes = dial.probes.length;

      // Another "on" joins it and does not end the wait.
      unawaited(rig.power(true));
      await rig.h.clock.advance(const Duration(seconds: 2));
      expect(onResult, isNull);

      final off = rig.power(false);
      await rig.h.clock.advance(const Duration(seconds: 2));
      expect(onResult, isSentUnconfirmed);
      expect(
        await off,
        isUnsupported('No driver for this device can turn it off'),
      );
      expect(dial.probes.length, lessThanOrEqualTo(probes + 1));
    });

    for (final (name, interrupt) in [
      ('an off', const SetPower(false)),
      ('the power key', const PressKey(RemoteKey.power)),
    ]) {
      test('$name queued behind the wait ends it at the next poll, even with '
          'an on queued after it', () async {
        // Codex re-review, new finding 2 (Reqall 9366): only the last queued
        // request was checked, so an on queued after the off hid it, and
        // the off waited out the whole 30 s wake timeout.
        final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
        final rig = await Rig([roku], mac: mac).add();
        addTearDown(rig.h.close);
        rig.online = false;
        CommandResult? first;
        unawaited(rig.power(true).then((r) => first = r));
        await rig.h.clock.advance(const Duration(seconds: 3));
        expect(first, isNull, reason: 'still waiting for the device');

        CommandResult? second;
        unawaited(rig.h.engine.send(rig.id, interrupt).then((r) => second = r));
        unawaited(rig.power(true));
        await rig.h.clock.advance(const Duration(seconds: 2));
        expect(first, isSentUnconfirmed);
        expect(second, isNotNull, reason: 'it ran at the next poll');
        if (interrupt is SetPower) {
          expect(second, isConfirmed);
          expect(roku.executed, [const SetPower(false)]);
        }
      });
    }

    test('an on that an off interrupted while it was queued sends no '
        'Wake-on-LAN before the off', () async {
      // Integration adversarial check of Codex re-review finding 2: a
      // queued on, interrupted before it started, still sent a full round
      // of magic packets just before the off ran, so the TV could wake
      // after the off.
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
      final rig = await Rig([roku], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      CommandResult? first;
      unawaited(rig.power(true).then((r) => first = r));
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(first, isNull, reason: 'still waiting for the device');
      final packets = rig.h.transports.net.sentDatagrams.length;

      // Not joined: it asks more firmly than the running on.
      final second = rig.h.engine.send(
        rig.id,
        const SetPower(true, userConfirmed: true),
      );
      final off = rig.power(false);
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(first, isSentUnconfirmed);
      expect(await second, isFailedWith(WatchmeErrorCode.cancelled));
      expect(await off, isConfirmed);
      expect(roku.executed, [const SetPower(false)]);
      expect(rig.h.transports.net.sentDatagrams, hasLength(packets));
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

    test('one source is not enough for a toggle: needs confirmation, and '
        'gathering the evidence connects nothing', () async {
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

  group('the power key is a toggle intent', () {
    const powerKey = PressKey(RemoteKey.power);

    test('with one source and only toggles it needs confirmation and sends '
        'nothing', () async {
      // Replaces the M0 test that let the key through as "the user's own
      // toggle": finding #1 (the raw key bypassed the two-source gate). The
      // source is the device's own report, which settles the state for a
      // discrete command, never for a toggle.
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rig = await Rig([ws]).add();
      addTearDown(rig.h.close);
      for (final mode in [PowerMode.on, PowerMode.standby]) {
        rig.probeSays(ws, mode);
        expect(
          await rig.h.engine.send(rig.id, powerKey),
          isUnsupported(Unsupported.needsConfirmation),
          reason: '$mode',
        );
      }
      expect(ws.executed, isEmpty);
      expect(ws.connects, isEmpty, reason: 'connecting can wake a TV');
      expect(rig.h.engine.power.lastCommand(rig.id), isNull);
    });

    test('one source the device reports settles it when a discrete route '
        'can act: off, then on', () async {
      // A Roku TV alone: its probe and its session are one source, and
      // device-info power-mode is the device's own report.
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff, powerState],
      );
      final rig = await Rig([roku]).add();
      addTearDown(rig.h.close);
      rig.probeSays(roku, PowerMode.on);
      expect(await rig.h.engine.send(rig.id, powerKey), isConfirmed);
      expect(roku.executed, [const SetPower(false)]);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isFalse);
      expect(roku.connects.single.allowWake, isFalse);

      await rig.h.clock.advance(const Duration(seconds: 21));
      roku.lastSession.onRefresh = () =>
          DeviceState(power: rig.says(PowerMode.standby, 'roku.ecp'));
      expect(await rig.h.engine.send(rig.id, powerKey), isConfirmed);
      expect(roku.executed, [const SetPower(false), const SetPower(true)]);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isTrue);
      expect(roku.executed, isNot(contains(powerKey)));
    });

    test('one reported source with a MAC turns it on by Wake-on-LAN, '
        'never by its toggle', () async {
      final ws = FakeDriver(
        'samsung.ws',
        ceiling: const [toggleOn, powerState],
      );
      final rig = await Rig([ws], mac: mac).add();
      addTearDown(rig.h.close);
      rig.probeSays(ws, PowerMode.standby);
      final result = rig.h.engine.send(rig.id, powerKey);
      await rig.h.clock.advance(const Duration(seconds: 3));
      expect(await result, isSentUnconfirmed);
      expect(rig.h.transports.net.sentDatagrams, isNotEmpty);
      expect(ws.executed.where(isPowerCommand), isEmpty);
    });

    test('one inferred source does not settle it, even with discrete '
        'routes', () async {
      // A Fire TV alone: its power state is inferred (a closed API port, a
      // command it accepted), never reported.
      final firetv = FakeDriver(
        'firetv.lightning',
        ceiling: const [discreteOn, discreteOff, powerState],
      );
      final rig = await Rig([firetv], mac: mac).add();
      addTearDown(rig.h.close);
      for (final mode in [PowerMode.on, PowerMode.standby]) {
        rig.probePower['firetv.lightning'] = Observed.inferred(
          mode,
          'firetv.lightning',
          rig.h.clock.now(),
        );
        expect(
          await rig.h.engine.send(rig.id, powerKey),
          isUnsupported(Unsupported.needsConfirmation),
          reason: '$mode',
        );
      }
      expect(firetv.executed, isEmpty);
      expect(firetv.connects, isEmpty);
      expect(rig.h.transports.net.sentDatagrams, isEmpty);
    });

    test('one reported source does not settle it within the quiet '
        'period', () async {
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff, powerState],
      );
      final rig = await Rig([roku]).add();
      addTearDown(rig.h.close);
      expect(await rig.power(false), isConfirmed);
      await rig.h.clock.advance(const Duration(seconds: 5));
      roku.lastSession.onRefresh = () =>
          DeviceState(power: rig.says(PowerMode.standby, 'roku.ecp'));
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(roku.executed, [const SetPower(false)]);
    });

    test('one reported source with partial power-state support does not '
        'settle it: a player reports its own power, not the TV\'s', () async {
      final player = FakeDriver(
        'roku.ecp',
        ceiling: const [
          discreteOn,
          discreteOff,
          CapabilitySupport.partial(Capability.powerState),
        ],
      );
      final rig = await Rig([player]).add();
      addTearDown(rig.h.close);
      for (final mode in [PowerMode.on, PowerMode.standby]) {
        rig.probeSays(player, mode);
        expect(
          await rig.h.engine.send(rig.id, powerKey),
          isUnsupported(Unsupported.needsConfirmation),
          reason: '$mode',
        );
      }
      expect(player.executed, isEmpty);
    });

    test('one reported source whose discrete route fails sends no toggle: '
        'it asks', () async {
      // Limited mode refuses PowerOff/PowerOn; another driver has only the
      // toggle, which one source never justifies.
      const refused = Failed(
        WatchmeError.rejected(
          'Limited mode',
          rawDeviceMessage: 'ECP command not allowed in Limited mode.',
        ),
      );
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff, powerState],
        onExecute: (_) => refused,
      );
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rig = await Rig([ws, roku]).add();
      addTearDown(rig.h.close);

      rig.probeSays(roku, PowerMode.on);
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(roku.executed, [const SetPower(false)]);

      rig.probeSays(roku, PowerMode.standby);
      roku.lastSession.onRefresh = () =>
          DeviceState(power: rig.says(PowerMode.standby, 'roku.ecp'));
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(roku.executed, [const SetPower(false), const SetPower(true)]);
      expect(ws.executed, isEmpty, reason: 'no toggle on one source');
      expect(rig.h.engine.power.lastCommand(rig.id), isNull);
    });

    test('two disagreeing sources: needs confirmation, even with discrete '
        'routes', () async {
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff],
      );
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([roku, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(roku, PowerMode.on)
        ..probeSays(rest, PowerMode.standby);
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(Unsupported.needsConfirmation),
      );
      expect(roku.executed, isEmpty);
      expect(roku.connects, isEmpty);
    });

    test('two sources agreeing it is on turn it off', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      expect(await rig.h.engine.send(rig.id, powerKey), isConfirmed);
      expect(ws.executed, [const SetPower(false)]);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isFalse);
    });

    test(
      'two sources agreeing it is off turn it on, discretely first',
      () async {
        final roku = FakeDriver('roku.ecp', ceiling: const [discreteOn]);
        final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
        final rig = await Rig([ws, roku]).add();
        addTearDown(rig.h.close);
        rig
          ..probeSays(ws, PowerMode.standby)
          ..probeSays(roku, PowerMode.standby);
        expect(await rig.h.engine.send(rig.id, powerKey), isConfirmed);
        expect(roku.executed, [const SetPower(true)]);
        expect(ws.executed, isEmpty);
      },
    );

    test('a quick second press does not toggle back', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      expect(await rig.h.engine.send(rig.id, powerKey), isConfirmed);
      await rig.h.clock.advance(const Duration(seconds: 3));
      rig
        ..probeSays(ws, PowerMode.standby)
        ..probeSays(rest, PowerMode.standby);
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(Unsupported.needsConfirmation),
        reason: 'quiet period',
      );
      expect(ws.executed, [const SetPower(false)]);
    });

    test('holding a power key is refused', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff],
      );
      final rig = await Rig([ws, roku]).add();
      addTearDown(rig.h.close);
      for (final key in [
        RemoteKey.power,
        RemoteKey.powerOn,
        RemoteKey.powerOff,
      ]) {
        for (final action in [KeyAction.down, KeyAction.up]) {
          expect(
            await rig.h.engine.send(rig.id, PressKey(key, action)),
            isUnsupported(contains('not held')),
          );
        }
      }
      expect([...ws.executed, ...roku.executed], isEmpty);
      expect([...ws.connects, ...roku.connects], isEmpty);
    });

    test('the discrete power keys are SetPower, so a driver mapping them to '
        'a toggle cannot bypass the gate', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rig = await Rig([ws]).add();
      addTearDown(rig.h.close);
      rig.probeSays(ws, PowerMode.on);
      for (final key in [RemoteKey.powerOff, RemoteKey.powerOn]) {
        expect(
          await rig.h.engine.send(rig.id, PressKey(key)),
          isUnsupported(Unsupported.needsConfirmation),
        );
      }
      expect(ws.executed, isEmpty);

      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
      final rig2 = await Rig([roku]).add();
      addTearDown(rig2.h.close);
      expect(
        await rig2.h.engine.send(rig2.id, const PressKey(RemoteKey.powerOff)),
        isConfirmed,
      );
      expect(roku.executed, [const SetPower(false)]);
      expect(rig2.h.engine.power.lastCommand(rig2.id)?.on, isFalse);
    });

    test('a device nothing can switch is Unsupported without asking', () async {
      final rig = await Rig([FakeDriver('dial')]).add();
      addTearDown(rig.h.close);
      expect(
        await rig.h.engine.send(rig.id, powerKey),
        isUnsupported(isNot(Unsupported.needsConfirmation)),
      );
    });
  });

  group('SetPower(userConfirmed: true)', () {
    test('counts as agreement: the toggle goes out on one source', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rig = await Rig([ws]).add();
      addTearDown(rig.h.close);
      expect(
        await rig.power(false),
        isUnsupported(Unsupported.needsConfirmation),
      );
      // The UI asked "Is the TV on right now?" and the user said yes.
      expect(
        await rig.h.engine.send(
          rig.id,
          const SetPower(false, userConfirmed: true),
        ),
        isConfirmed,
      );
      expect(ws.executed, [const SetPower(false)]);
      expect(rig.h.engine.power.lastCommand(rig.id)?.on, isFalse);
    });

    test('still prefers a discrete route', () async {
      final roku = FakeDriver('roku.ecp', ceiling: const [discreteOff]);
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
      final rig = await Rig([ws, roku]).add();
      addTearDown(rig.h.close);
      expect(
        await rig.h.engine.send(
          rig.id,
          const SetPower(false, userConfirmed: true),
        ),
        isConfirmed,
      );
      expect(roku.executed, [const SetPower(false)]);
      expect(ws.executed, isEmpty);
    });

    test('still sends no toggle in the quiet period, and does not ask '
        'again', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rig = await Rig([ws]).add();
      addTearDown(rig.h.close);
      const confirmedOff = SetPower(false, userConfirmed: true);
      const confirmedOn = SetPower(true, userConfirmed: true);
      expect(await rig.h.engine.send(rig.id, confirmedOff), isConfirmed);
      await rig.h.clock.advance(const Duration(seconds: 5));
      expect(
        await rig.h.engine.send(rig.id, confirmedOn),
        isUnsupported(PowerOrchestrator.quietPeriodReason),
      );
      expect(ws.executed, [const SetPower(false)]);
      await rig.h.clock.advance(const Duration(seconds: 20));
      expect(await rig.h.engine.send(rig.id, confirmedOn), isConfirmed);
      expect(ws.executed, [const SetPower(false), const SetPower(true)]);
    });

    test('still sends no toggle after Wake-on-LAN', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rig = await Rig([ws], mac: mac).add();
      addTearDown(rig.h.close);
      rig.online = false;
      final result = rig.h.engine.send(
        rig.id,
        const SetPower(true, userConfirmed: true),
      );
      await rig.h.clock.advance(const Duration(seconds: 31));
      expect(await result, isSentUnconfirmed);
      expect(rig.h.transports.net.sentDatagrams, isNotEmpty);
      expect(ws.executed.where(isPowerCommand), isEmpty);
    });
  });

  test('no toggle after a discrete command that may have acted', () async {
    final roku = FakeDriver(
      'roku.ecp',
      ceiling: const [discreteOff],
      onExecute: (_) =>
          const Failed(WatchmeError.timeout('no answer after sending')),
    );
    final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
    final rig = await Rig([ws, roku]).add();
    addTearDown(rig.h.close);
    rig
      ..probeSays(ws, PowerMode.on)
      ..probeSays(roku, PowerMode.on);
    expect(await rig.power(false), isFailedWith(WatchmeErrorCode.timeout));
    expect(roku.executed, [const SetPower(false)]);
    expect(ws.executed, isEmpty, reason: 'the toggle could undo the off');
    expect(
      rig.h.engine.power.lastCommand(rig.id)?.on,
      isFalse,
      reason: 'it may have acted, so the quiet period starts',
    );
    expect(
      await rig.h.engine.send(
        rig.id,
        const SetPower(false, userConfirmed: true),
      ),
      isFailedWith(WatchmeErrorCode.timeout),
    );
    expect(ws.executed, isEmpty);
  });

  group('a connect whose wake may have reached the device', () {
    // Codex re-review of finding #4 (Reqall 9345): a Fire TV's acknowledged
    // DIAL wake switched the TV on, its API never opened, the connect
    // failure counted as "nothing sent", and a confirmed toggle on another
    // driver switched the TV straight back off. The driver now reports
    // such a connect as partiallyDelivered.
    WatchmeError wokeThen(WatchmeError cause) =>
        WatchmeError.partiallyDelivered(
          'The DIAL wake reached the TV, then: ${cause.message}',
          cause: cause,
        );

    test('is not followed by a toggle, even a confirmed one', () async {
      final fire = FakeDriver('firetv.lightning', ceiling: const [discreteOn]);
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rig = await Rig([fire, ws]).add();
      addTearDown(rig.h.close);
      fire.connectError = wokeThen(
        const WatchmeError.unreachable('The API port never opened'),
      );

      expect(
        await rig.h.engine.send(
          rig.id,
          const SetPower(true, userConfirmed: true),
        ),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      expect(fire.connects.single.allowWake, isTrue);
      expect(ws.executed, isEmpty, reason: 'the toggle would undo the wake');
      expect(
        rig.h.engine.power.lastCommand(rig.id)?.on,
        isTrue,
        reason: 'the wake may have acted, so the quiet period starts',
      );
    });

    test('rejecting the credential is still not followed by a toggle, and '
        'the pairing shows as revoked', () async {
      final fire = FakeDriver(
        'firetv.lightning',
        ceiling: const [discreteOn],
        requiresPairing: true,
      );
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rig = await Rig([fire, ws]).add();
      addTearDown(rig.h.close);
      await rig.h.credentials.write(token(rig.id, 'firetv.lightning'));
      final events = <DeviceEvent>[];
      rig.h.engine.events(rig.id).listen(events.add);
      fire.connectError = wokeThen(
        const WatchmeError.unauthorized(
          'The TV rejected the token',
          rawDeviceMessage: '401 Unauthorized',
        ),
      );

      expect(
        await rig.h.engine.send(
          rig.id,
          const SetPower(true, userConfirmed: true),
        ),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      expect(ws.executed, isEmpty);
      await pump();
      expect(events.whereType<ReauthRequired>(), hasLength(1));
      final view = rig.h.driverView(rig.id, 'firetv.lightning');
      expect(view.needsPairing, isTrue);
      expect(
        view.lastError,
        isWatchmeError(
          WatchmeErrorCode.reauthRequired,
          rawDeviceMessage: '401 Unauthorized',
        ),
      );
    });

    test('a command routed through it is not replayed on another '
        'driver', () async {
      const keys = [CapabilitySupport.yes(Capability.systemKeys)];
      final fire = FakeDriver('firetv.lightning', ceiling: keys);
      final roku = FakeDriver('roku.ecp', ceiling: keys);
      final rig = await Rig([fire, roku]).add();
      addTearDown(rig.h.close);
      fire.connectError = wokeThen(
        const WatchmeError.timeout('The status read timed out'),
      );
      expect(
        await rig.h.engine.send(rig.id, const PressKey(RemoteKey.home)),
        isFailedWith(WatchmeErrorCode.partiallyDelivered),
      );
      expect(roku.connects, isEmpty);
    });
  });

  group('one power operation per device at a time', () {
    test('two concurrent offs send one toggle', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      final results = await Future.wait([rig.power(false), rig.power(false)]);
      expect(results, everyElement(isConfirmed));
      expect(ws.executed, [const SetPower(false)]);
    });

    test('a double press of the power key toggles once', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      const key = PressKey(RemoteKey.power);
      final results = await Future.wait([
        rig.h.engine.send(rig.id, key),
        rig.h.engine.send(rig.id, key),
      ]);
      expect(results, everyElement(isConfirmed));
      expect(ws.executed, [const SetPower(false)]);
    });

    test('a power command that never finishes holds later ones until the '
        'engine closes, and no longer', () async {
      // Verifier follow-up to Codex finding #2: the queue waited forever
      // behind a hung session, even after close().
      final hang = Completer<CommandResult>();
      final ws = FakeDriver(
        'samsung.ws',
        ceiling: const [toggleOn, toggleOff],
        onExecute: (c) => c is SetPower ? hang.future : const Confirmed(),
      );
      final rig = await Rig([ws]).add();
      CommandResult? first;
      CommandResult? second;
      unawaited(
        rig.h.engine
            .send(rig.id, const SetPower(false, userConfirmed: true))
            .then((r) => first = r),
      );
      await pump();
      expect(ws.executed, [const SetPower(false)]);
      unawaited(
        rig.h.engine
            .send(rig.id, const SetPower(true, userConfirmed: true))
            .then((r) => second = r),
      );
      await pump();
      expect(second, isNull, reason: 'queued behind the hung one');

      await rig.h.close();
      expect(second, isFailedWith(WatchmeErrorCode.cancelled));
      // The toggle may have reached the TV: its caller is not told that
      // nothing happened, and waits no longer than a second for the session.
      expect(first, isNull);
      await rig.h.clock.advance(const Duration(seconds: 1));
      expect(first, isInterruptedAfterSending);
      expect(ws.executed, [const SetPower(false)]);
    });

    test('off then on: the second waits and decides on fresh evidence, '
        'meeting the quiet period', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      final off = rig.power(false);
      final on = rig.power(true);
      expect(await off, isConfirmed);
      expect(await on, isUnsupported(Unsupported.needsConfirmation));
      expect(ws.executed, [const SetPower(false)]);
    });
  });

  group('PowerOrchestrator serialisation', () {
    late FakeClock clock;
    late PowerOrchestrator orchestrator;
    late _GatedTarget target;

    setUp(() {
      clock = FakeClock(DateTime.utc(2026, 10, 21, 12));
      orchestrator = PowerOrchestrator(
        transports: FakeTransports(),
        clock: clock,
      );
      target = _GatedTarget(clock);
    });

    test('concurrent offs that both see agreeing evidence toggle once, and '
        'the second joins the first', () async {
      target.evidence = [PowerMode.on, PowerMode.on];
      final a = orchestrator.setPower(target, false);
      final b = orchestrator.setPower(target, false);
      await pump();
      target.release();
      expect(await a, isConfirmed);
      expect(await b, isConfirmed);
      expect(target.executed, [const SetPower(false)]);
      expect(target.evidenceReads, 1);
    });

    test(
      'a different request waits for the first, then re-evaluates',
      () async {
        target.evidence = [PowerMode.on, PowerMode.on];
        final off = orchestrator.setPower(target, false);
        final on = orchestrator.setPower(target, true);
        await pump();
        expect(target.evidenceReads, 1, reason: 'the second waits its turn');
        target.release();
        expect(await off, isConfirmed);
        expect(await on, isUnsupported(Unsupported.needsConfirmation));
        expect(target.executed, [const SetPower(false)]);
      },
    );

    test('a confirmed request does not join an unconfirmed one', () async {
      // Only one source: the unconfirmed off needs confirmation.
      target.evidence = [PowerMode.on];
      final asked = orchestrator.setPower(target, false);
      final confirmed = orchestrator.setPower(
        target,
        false,
        userConfirmed: true,
      );
      await pump();
      target.release();
      expect(await asked, isUnsupported(Unsupported.needsConfirmation));
      expect(await confirmed, isConfirmed);
      expect(target.executed, [const SetPower(false)]);
    });

    test('close releases a running request that never finishes and the '
        'requests queued behind it', () async {
      target.evidence = [PowerMode.on, PowerMode.on];
      CommandResult? first;
      CommandResult? second;
      unawaited(orchestrator.setPower(target, false).then((r) => first = r));
      unawaited(orchestrator.setPower(target, true).then((r) => second = r));
      await pump();
      expect(first, isNull);
      expect(second, isNull);
      // The gate is never released: the first request hangs.
      orchestrator.close();
      await pump();
      expect(first, isFailedWith(WatchmeErrorCode.cancelled));
      expect(second, isFailedWith(WatchmeErrorCode.cancelled));
      expect(target.executed, isEmpty);
    });

    test('queued requests fail as cancelled once it is closed', () async {
      target.evidence = [PowerMode.on, PowerMode.on];
      final first = orchestrator.setPower(target, false);
      final second = orchestrator.setPower(target, true);
      await pump();
      orchestrator.close();
      target.release();
      expect(await first, isFailedWith(WatchmeErrorCode.cancelled));
      expect(await second, isFailedWith(WatchmeErrorCode.cancelled));
      expect(target.executed, isEmpty);
    });

    test('a running request sends nothing after close: a command in flight '
        'that turns out not to have been sent ends it as cancelled, with no '
        'Wake-on-LAN after it', () async {
      final transports = FakeTransports();
      orchestrator = PowerOrchestrator(transports: transports, clock: clock);
      final attempt = Completer<RouteAttempt>();
      final target = _ScriptedTarget(
        routes: const [discreteOn],
        macs: const {mac},
        onExecute: (_) => attempt.future,
      );
      CommandResult? result;
      unawaited(orchestrator.setPower(target, true).then((r) => result = r));
      await pump();
      expect(target.executed, [const SetPower(true)]);

      orchestrator.close();
      await pump();
      expect(result, isNull, reason: 'the power-on may be on its way');
      attempt.complete(
        const RouteAttempt(
          Failed(WatchmeError.unreachable('refused')),
          commandSent: false,
        ),
      );
      await pump();
      expect(result, isFailedWith(WatchmeErrorCode.cancelled));
      await clock.advance(const Duration(seconds: 40));
      expect(transports.net.sentDatagrams, isEmpty);
      expect(target.executed, hasLength(1));
      expect(target.evidenceReads, 0);
    });
  });

  group('waking while connecting', () {
    test('turning off and toggling never connect with waking allowed; a '
        'discrete power-on may', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn, toggleOff]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.on)
        ..probeSays(rest, PowerMode.on);
      expect(await rig.power(false), isConfirmed);
      expect(ws.connects.single.allowWake, isFalse);

      final roku = FakeDriver(
        'roku.ecp',
        ceiling: const [discreteOn, discreteOff],
      );
      final rig2 = await Rig([roku]).add();
      addTearDown(rig2.h.close);
      expect(await rig2.power(false), isConfirmed);
      expect(roku.connects.single.allowWake, isFalse);

      final roku2 = FakeDriver('roku.ecp', ceiling: const [discreteOn]);
      final rig3 = await Rig([roku2]).add();
      addTearDown(rig3.h.close);
      expect(await rig3.power(true), isConfirmed);
      expect(roku2.connects.single.allowWake, isTrue);
    });

    test('a toggle to turn it on does not wake it first', () async {
      final ws = FakeDriver('samsung.ws', ceiling: const [toggleOn]);
      final rest = FakeDriver('samsung.rest', ceiling: const [powerState]);
      final rig = await Rig([ws, rest]).add();
      addTearDown(rig.h.close);
      rig
        ..probeSays(ws, PowerMode.standby)
        ..probeSays(rest, PowerMode.standby);
      expect(await rig.power(true), isConfirmed);
      expect(ws.connects.single.allowWake, isFalse);
    });
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

/// A device with one toggle route for each direction whose evidence is
/// held at a gate until [release], so two calls can interleave.
class _GatedTarget implements PowerTarget {
  _GatedTarget(this.clock);

  final FakeClock clock;
  final List<Command> executed = [];
  Completer<void> _gate = Completer();
  List<PowerMode> evidence = const [];
  int evidenceReads = 0;

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  String get deviceId => 'tv';

  @override
  String get host => '10.0.2.50';

  @override
  Set<String> get macs => const {};

  @override
  List<RouteCandidate> routes(Capability capability) => [
    RouteCandidate(
      driverId: 'samsung.ws',
      support: CapabilitySupport.yes(capability, flags: {CapFlag.toggleOnly}),
    ),
  ];

  @override
  Future<RouteAttempt> execute(RouteCandidate route, Command command) async {
    executed.add(command);
    return const RouteAttempt(Confirmed());
  }

  @override
  Future<List<Observed<PowerMode>>> powerEvidence() async {
    evidenceReads++;
    await _gate.future;
    _gate = Completer()..complete();
    return [
      for (final (i, mode) in evidence.indexed)
        Observed.reported(mode, 'source$i', clock.now()),
    ];
  }

  @override
  Future<bool> answers() async => false;
}

/// A device whose power routes are [routes] and whose commands are answered
/// by [onExecute]; it never answers a probe.
class _ScriptedTarget implements PowerTarget {
  _ScriptedTarget({
    required this._routes,
    required this.onExecute,
    this.macs = const {},
  });

  final List<CapabilitySupport> _routes;
  final Future<RouteAttempt> Function(Command command) onExecute;
  final List<Command> executed = [];
  int evidenceReads = 0;

  @override
  final Set<String> macs;

  @override
  String get deviceId => 'tv';

  @override
  String get host => '10.0.2.60';

  @override
  List<RouteCandidate> routes(Capability capability) => [
    for (final s in _routes)
      if (s.capability == capability)
        RouteCandidate(driverId: 'driver', support: s),
  ];

  @override
  Future<RouteAttempt> execute(RouteCandidate route, Command command) {
    executed.add(command);
    return onExecute(command);
  }

  @override
  Future<List<Observed<PowerMode>>> powerEvidence() async {
    evidenceReads++;
    return const [];
  }

  @override
  Future<bool> answers() async => false;
}

class _ThrowingTarget implements PowerTarget {
  @override
  String get deviceId => 'x';

  @override
  String get host => '10.0.2.1';

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
