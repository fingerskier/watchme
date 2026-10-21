import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

import 'support/fakes.dart';
import 'support/harness.dart';

const secret = 'SUPER-SECRET-TOKEN-0042';

void main() {
  late FakeDriver fire;
  late FakeDiscoveryProvider ssdp;
  late Harness h;
  late InProcessClient client;

  setUp(() {
    fire = FakeDriver(
      'firetv.lightning',
      ceiling: const [CapabilitySupport.yes(Capability.systemKeys)],
      requiresPairing: true,
      matchers: const [
        DiscoveryMatcher(
          provider: DiscoveryProviderId.ssdp,
          serviceType: 'urn:dial-multiscreen-org:service:dial:1',
          portName: 'dial',
        ),
      ],
      onProbe: (_) => matched(
        name: 'Fire TV',
        mac: 'aa:bb:cc:dd:ee:ff',
        requiresPairing: true,
      ),
      onPair: (_, ctx) => PairingFlowController.run((flow) async {
        await flow.prompt(const EnterCode('PIN', 4, CodeAlphabet.digits));
        return TokenCredential(
          driverId: 'firetv.lightning',
          deviceId: ctx.deviceId,
          createdAt: DateTime.utc(2026),
          token: secret,
          refreshToken: '$secret-refresh',
        );
      }),
    );
    ssdp = FakeDiscoveryProvider(
      DiscoveryProviderId.ssdp,
      hits: const [
        DiscoveryHit(
          host: '192.0.2.7',
          provider: DiscoveryProviderId.ssdp,
          port: 8009,
          serviceType: 'urn:dial-multiscreen-org:service:dial:1',
        ),
      ],
    );
    h = Harness(drivers: [fire], providers: [ssdp]);
    client = InProcessClient(h.engine);
  });
  tearDown(() async {
    await client.close();
    await h.close();
  });

  test('scan, watch, pair and send through the client', () async {
    final lists = <List<DeviceView>>[];
    final sub = client.watchDevices().listen(lists.add);
    await client.scan(window: const Duration(seconds: 2));
    expect(ssdp.scans.single.window, const Duration(seconds: 2));
    await pump();
    final device = lists.last.single;
    expect(device.needsPairing, isTrue);

    final handle = await client.pair(device.id, 'firetv.lightning');
    expect(handle.id, startsWith('pairing-'));
    expect(handle.deviceId, device.id);
    final steps = <PairingStep>[];
    await handle.steps.forEach((s) {
      steps.add(s);
      if (s is EnterCode) unawaited(handle.submit('1234'));
    });
    expect(steps.last, isA<Paired>());
    expect((steps.last as Paired).credential, isNull);

    expect(
      await client.send(device.id, const PressKey(RemoteKey.home)),
      isConfirmed,
    );
    await pump();
    expect(lists.last.single.needsPairing, isFalse);
    expect(lists.last.single.connected, isTrue);
    await sub.cancel();
  });

  test('nothing the client returns contains a secret', () async {
    final events = <DeviceEvent>[];
    final view = await client.addManual('192.0.2.7');
    client.events(view.id).listen(events.add);
    final handle = await client.pair(view.id, 'firetv.lightning');
    final steps = await handle.steps.map((s) {
      if (s is EnterCode) unawaited(handle.submit('1234'));
      return s;
    }).toList();
    await client.send(view.id, const PressKey(RemoteKey.home));
    await client.refresh(view.id);
    await pump();

    // The engine did store it.
    final stored = await h.credentials.read(view.id, 'firetv.lightning');
    expect(jsonEncode(stored!.toJson()), contains(secret));

    final everything = jsonEncode({
      'devices': [
        for (final d in await client.watchDevices().first) d.toJson(),
      ],
      'steps': [for (final s in steps) s.toJson(includeSecrets: true)],
      'events': [for (final e in events) e.toJson()],
    });
    expect(everything, isNot(contains(secret)));
    expect(everything, contains('"paired":true'));
  });

  test('redacts a credential even if the engine passed one through', () async {
    final leaky = InProcessClient(_LeakyEngine());
    addTearDown(leaky.close);
    final handle = await leaky.pair('tv', 'drv');
    final last = await handle.steps.last;
    expect(last, isA<Paired>());
    expect((last as Paired).credential, isNull);
    expect(
      jsonEncode(last.toJson(includeSecrets: true)),
      isNot(contains(secret)),
    );
  });

  test('pairing ids are unique and close cancels open pairings', () async {
    final view = await client.addManual('192.0.2.7');
    final a = await client.pair(view.id, 'firetv.lightning');
    final steps = a.steps.toList();
    final b = await client.pair('other', 'firetv.lightning');
    expect(a.id, isNot(b.id));
    await client.close();
    expect((await steps).last, isPairingFailedWith(WatchmeErrorCode.cancelled));
    expect(
      await client.send(view.id, const PressKey(RemoteKey.home)),
      isFailedWith(WatchmeErrorCode.cancelled),
    );
    expect(h.engine.isClosed, isFalse, reason: 'the client does not own it');
  });

  test('a client that owns the engine closes it', () async {
    final owning = InProcessClient(h.engine, ownsEngine: true);
    await owning.close();
    expect(h.engine.isClosed, isTrue);
  });

  test('forget goes through to the engine', () async {
    final view = await client.addManual('192.0.2.7');
    await client.forget(view.id);
    expect(h.engine.currentDevices, isEmpty);
  });
}

/// An engine that (wrongly) forwards the driver's credential.
class _LeakyEngine implements WatchmeEngine {
  @override
  PairingFlow pair(String deviceId, String driverId) =>
      PairingFlowController.run(
        (_) async => TokenCredential(
          driverId: driverId,
          deviceId: deviceId,
          createdAt: DateTime.utc(2026),
          token: secret,
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
