import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const mute = CapabilitySupport.yes(Capability.mute);
const relativeVolume = CapabilitySupport.yes(
  Capability.volume,
  flags: {CapFlag.relativeOnly},
);

FakeDriver driver(String id, List<CapabilitySupport> caps, {String? mac}) =>
    FakeDriver(
      id,
      ceiling: caps,
      onProbe: (_) => matched(name: 'TV', mac: mac, capabilities: caps),
    );

void main() {
  test('falls back to the next driver when the best is unreachable', () async {
    final cec = driver('cec', [mute]);
    final ir = driver('ir', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.writeOnly}),
    ]);
    final h = Harness(drivers: [ir, cec]);
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');
    cec.connectError = const WatchmeError.unreachable('adapter unplugged');

    expect(await h.engine.send(id, const SetMute(true)), isConfirmed);
    expect(cec.connects, hasLength(1), reason: 'the better route was tried');
    expect(ir.executed, [const SetMute(true)]);
    expect(h.driverView(id, 'cec').lastError?.message, 'adapter unplugged');
  });

  test('cloud routes are used only with internet', () async {
    final cloud = driver('smartthings', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.cloud}),
    ]);
    final local = driver('ir', [
      const CapabilitySupport.yes(Capability.mute, flags: {CapFlag.writeOnly}),
    ]);
    final transports = FakeTransports();
    final h = Harness(drivers: [cloud, local], transports: transports);
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');

    await h.engine.send(id, const SetMute(true));
    expect(cloud.executed, isEmpty);
    expect(local.executed, hasLength(1));

    transports.extraFeatures.add(TransportFeature.internet);
    await h.engine.send(id, const SetMute(false));
    // Local beats cloud, but write-only ranks below cloud feedback.
    expect(cloud.executed, [const SetMute(false)]);
  });

  test('SetVolume steps a relative-only session from its reported level, '
      'then from the level watchme set', () async {
    final atv = FakeDriver(
      'androidtv.remote2',
      ceiling: const [relativeVolume],
      onProbe: (_) => matched(capabilities: const [relativeVolume]),
    );
    final h = Harness(drivers: [atv]);
    addTearDown(h.close);
    atv.sessionState = DeviceState(
      volume: Observed.reported(20, 'androidtv.remote2', h.clock.now()),
    );
    final id = await h.add('192.0.2.10');
    await h.clock.advance(const Duration(minutes: 1));

    expect(await h.engine.send(id, const SetVolume(25)), isConfirmed);
    expect(atv.executed, [const StepVolume(5)]);
    final volume = h.view(id).state.volume!;
    expect(volume.value, 25);
    expect(volume.confidence, Confidence.inferred);

    await h.clock.advance(const Duration(seconds: 1));
    await h.engine.send(id, const SetVolume(20));
    expect(atv.executed.last, const StepVolume(-5));
  });

  test(
    'SetVolume without a known level is Unsupported, and says why',
    () async {
      final roku = driver('roku.ecp', [relativeVolume]);
      final h = Harness(drivers: [roku]);
      addTearDown(h.close);
      final id = await h.add('192.0.2.10');
      expect(
        await h.engine.send(id, const SetVolume(30)),
        isUnsupported(contains('level is unknown')),
      );
      expect(roku.executed, isEmpty);
      // Relative commands still work.
      expect(await h.engine.send(id, const StepVolume(2)), isConfirmed);
    },
  );

  test('capabilities merge to the best entry per capability, plus '
      'Wake-on-LAN where a MAC is known', () async {
    final roku = driver('roku.ecp', [
      relativeVolume,
      const CapabilitySupport.no(Capability.screenshot),
    ], mac: 'aa:bb:cc:dd:ee:ff');
    final upnp = driver('upnp', [
      const CapabilitySupport.partial(Capability.volume),
    ]);
    final h = Harness(drivers: [roku, upnp]);
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');
    final caps = h.engine.capabilitiesOf(id);
    expect(caps[Capability.volume], relativeVolume);
    expect(caps[Capability.screenshot]?.level, Support.no);
    expect(caps[Capability.powerOn]?.level, Support.partial);
    expect(caps[Capability.powerOn]?.has(CapFlag.writeOnly), isTrue);
    expect(
      h.view(id).supportOf(Capability.powerOn).note,
      contains('Wake-on-LAN'),
    );
  });

  test('no Wake-on-LAN capability without UDP', () async {
    final roku = driver('roku.ecp', const [], mac: 'aa:bb:cc:dd:ee:ff');
    final net = FakeNetworkStack()
      ..features.removeAll({
        TransportFeature.udpBroadcast,
        TransportFeature.udpUnicast,
      });
    final h = Harness(
      drivers: [roku],
      transports: FakeTransports(network: net),
    );
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');
    expect(h.engine.capabilitiesOf(id)[Capability.powerOn], isNull);
  });

  test('a session that throws is reported as an internal failure', () async {
    final roku = driver('roku.ecp', [mute])
      ..onExecute = (_) => throw StateError('driver bug');
    final h = Harness(drivers: [roku]);
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');
    expect(
      await h.engine.send(id, const SetMute(null)),
      isFailedWith(WatchmeErrorCode.internal, message: contains('driver bug')),
    );
  });

  test('unknown devices fail without throwing', () async {
    final h = Harness(
      drivers: [
        driver('roku.ecp', [mute]),
      ],
    );
    addTearDown(h.close);
    expect(
      await h.engine.send('nope', const SetMute(true)),
      isFailedWith(WatchmeErrorCode.internal),
    );
    await expectLater(
      h.engine.refresh('nope'),
      throwsWatchmeError(WatchmeErrorCode.internal),
    );
    await expectLater(
      h.engine.forget('nope'),
      throwsWatchmeError(WatchmeErrorCode.internal),
    );
  });

  test('a command no driver supports is Unsupported', () async {
    final h = Harness(
      drivers: [
        driver('roku.ecp', [mute]),
      ],
    );
    addTearDown(h.close);
    final id = await h.add('192.0.2.10');
    expect(await h.engine.send(id, const TakeScreenshot()), isUnsupported());
  });
}
