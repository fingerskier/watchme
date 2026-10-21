import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_engine/watchme_engine.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

RouteCandidate route(
  String id,
  Support level, {
  Set<CapFlag> flags = const {},
  Capability capability = Capability.volume,
  Stability stability = Stability.documented,
  RouteHealth health = const RouteHealth(),
  int preference = 0,
}) => RouteCandidate(
  driverId: id,
  support: CapabilitySupport(capability, level, flags: flags),
  stability: stability,
  health: health,
  preference: preference,
);

/// Records calls and answers from a per-driver script.
class Script {
  Script(this.answers);

  final Map<String, RouteAttempt Function(Command)> answers;
  final List<(String, Command)> calls = [];

  Future<RouteAttempt> call(RouteCandidate r, Command c) async {
    calls.add((r.driverId, c));
    return answers[r.driverId]?.call(c) ?? const RouteAttempt(Confirmed());
  }
}

void main() {
  const router = CapabilityRouter();
  List<String> ids(List<RouteCandidate> l) => [for (final c in l) c.driverId];

  group('rank', () {
    test('orders by support level and drops "no"', () {
      expect(
        ids(
          router.rank([
            route('unknown', Support.unknown),
            route('no', Support.no),
            route('partial', Support.partial),
            route('yes', Support.yes),
          ]),
        ),
        ['yes', 'partial', 'unknown'],
      );
    });

    test('orders flags as the overview lists them', () {
      expect(
        ids(
          router.rank([
            route('toggle', Support.yes, flags: {CapFlag.toggleOnly}),
            route('relative', Support.yes, flags: {CapFlag.relativeOnly}),
            route(
              'reverse',
              Support.yes,
              stability: Stability.reverseEngineered,
            ),
            route('undocumented', Support.yes, flags: {CapFlag.undocumented}),
            route('cloud', Support.yes, flags: {CapFlag.cloud}),
            route('writeOnly', Support.yes, flags: {CapFlag.writeOnly}),
            route('clean', Support.yes),
          ]),
        ),
        [
          'clean',
          'toggle',
          'relative',
          'reverse',
          'undocumented',
          'cloud',
          'writeOnly',
        ],
      );
    });

    test('state feedback beats every lesser flag combined', () {
      expect(
        ids(
          router.rank([
            route('writeOnly', Support.yes, flags: {CapFlag.writeOnly}),
            route(
              'relativeCloudToggle',
              Support.yes,
              flags: {CapFlag.relativeOnly, CapFlag.toggleOnly},
              stability: Stability.reverseEngineered,
            ),
          ]),
        ),
        ['relativeCloudToggle', 'writeOnly'],
      );
    });

    test('health breaks ties, then the device driver order', () {
      expect(
        ids(
          router.rank([
            route('second', Support.yes, preference: 1),
            route('first', Support.yes, preference: 0),
            route(
              'flaky',
              Support.yes,
              health: const RouteHealth(consecutiveFailures: 3),
            ),
            route(
              'unpaired',
              Support.yes,
              health: const RouteHealth(ready: false),
            ),
            route(
              'connected',
              Support.yes,
              preference: 9,
              health: const RouteHealth(connection: ConnectionState.connected),
            ),
          ]),
        ),
        ['connected', 'first', 'second', 'flaky', 'unpaired'],
      );
    });
  });

  group('route', () {
    test('uses the best route and stops when it delivers', () async {
      final s = Script({});
      final r = await router.route(const PressKey(RemoteKey.volumeUp), [
        route('relative', Support.yes, flags: {CapFlag.relativeOnly}),
        route('absolute', Support.yes),
      ], s.call);
      expect(r.result, isConfirmed);
      expect(r.via?.driverId, 'absolute');
      expect(s.calls, hasLength(1));
    });

    test('falls back after Unsupported and Failed(unreachable)', () async {
      final s = Script({
        'a': (_) => const RouteAttempt(Unsupported('unmapped')),
        'b': (_) =>
            const RouteAttempt(Failed(WatchmeError.unreachable('refused'))),
      });
      final r = await router.route(const StepVolume(1), [
        route('a', Support.yes),
        route('b', Support.yes, preference: 1),
        route('c', Support.partial),
      ], s.call);
      expect(r.result, isConfirmed);
      expect(r.via?.driverId, 'c');
      expect([for (final (id, _) in s.calls) id], ['a', 'b', 'c']);
      expect(r.steps, hasLength(3));
    });

    test('falls back after any failure before the command was sent', () async {
      final s = Script({
        'a': (_) => const RouteAttempt(
          Failed(WatchmeError.timeout('connect timed out')),
          commandSent: false,
        ),
      });
      final r = await router.route(const StepVolume(1), [
        route('a', Support.yes),
        route('b', Support.partial),
      ], s.call);
      expect(r.via?.driverId, 'b');
    });

    test(
      'does not repeat a command that may have reached the device',
      () async {
        final s = Script({
          'a': (_) => const RouteAttempt(
            Failed(WatchmeError.timeout('no answer after sending')),
          ),
        });
        final r = await router.route(const StepVolume(1), [
          route('a', Support.yes),
          route('b', Support.partial),
        ], s.call);
        expect(r.result, isFailedWith(WatchmeErrorCode.timeout));
        expect(s.calls, hasLength(1));
      },
    );

    test('returns the first failure in preference to Unsupported', () async {
      final s = Script({
        'a': (_) => const RouteAttempt(Unsupported('unmapped')),
        'b': (_) => const RouteAttempt(
          Failed(WatchmeError.unreachable('down', rawDeviceMessage: 'raw')),
        ),
      });
      final r = await router.route(const StepVolume(1), [
        route('a', Support.yes),
        route('b', Support.partial),
      ], s.call);
      expect(
        r.result,
        isFailedWith(WatchmeErrorCode.unreachable, rawDeviceMessage: 'raw'),
      );
      expect(r.via, isNull);
    });

    test('is Unsupported when no route supports the capability', () async {
      final r = await router.route(const SetVolume(5), [
        route('a', Support.no),
      ], Script({}).call);
      expect(r.result, isUnsupported(contains('volume')));
    });
  });

  group('relative volume fallback', () {
    final relative = route('roku', Support.yes, flags: {CapFlag.relativeOnly});

    test('turns SetVolume into StepVolume from the known level', () async {
      final s = Script({});
      final r = await router.route(
        const SetVolume(30),
        [relative],
        s.call,
        knownVolume: 25,
      );
      expect(r.result, isConfirmed);
      expect(s.calls.single.$2, const StepVolume(5));
      expect(r.sent, const StepVolume(5));
    });

    test('presses volume keys when the session has no StepVolume', () async {
      final s = Script({
        'roku': (c) => c is StepVolume
            ? const RouteAttempt(Unsupported('no steps'))
            : const RouteAttempt(SentUnconfirmed()),
      });
      final r = await router.route(
        const SetVolume(17),
        [relative],
        s.call,
        knownVolume: 20,
      );
      expect(r.result, isSentUnconfirmed);
      expect(
        [for (final (_, c) in s.calls) c],
        [
          const StepVolume(-3),
          const PressKey(RemoteKey.volumeDown),
          const PressKey(RemoteKey.volumeDown),
          const PressKey(RemoteKey.volumeDown),
        ],
      );
    });

    test('is Unsupported without a known level', () async {
      final s = Script({});
      final r = await router.route(const SetVolume(30), [relative], s.call);
      expect(r.result, isUnsupported(contains('unknown')));
      expect(s.calls, isEmpty);
    });

    test('prefers an absolute route and needs no level for it', () async {
      final s = Script({});
      final r = await router.route(const SetVolume(30), [
        relative,
        route('upnp', Support.partial),
      ], s.call);
      // Support level ranks first: the relative "yes" route is tried, cannot
      // help without a level, and the absolute route takes over.
      expect(r.via?.driverId, 'upnp');
      expect(s.calls.single, ('upnp', const SetVolume(30)));
    });

    test('a press failing after one was delivered is a partial delivery, '
        'and no other route replays it', () async {
      // Codex finding #4: SetVolume(13) from 10, one press delivered, then
      // the route fails as unreachable; the next route stepped +3 more.
      var presses = 0;
      final s = Script({
        'keys': (c) => switch (c) {
          StepVolume() => const RouteAttempt(Unsupported('no steps')),
          _ =>
            ++presses == 1
                ? const RouteAttempt(Confirmed())
                : const RouteAttempt(
                    Failed(
                      WatchmeError.unreachable(
                        'refused',
                        rawDeviceMessage: 'ECONNREFUSED',
                      ),
                    ),
                  ),
        },
      });
      final r = await router.route(
        const SetVolume(13),
        [
          route('keys', Support.yes, flags: {CapFlag.relativeOnly}),
          route('stepper', Support.partial, flags: {CapFlag.relativeOnly}),
        ],
        s.call,
        knownVolume: 10,
      );
      expect(r.result.partiallyDelivered, isTrue);
      expect(
        r.result,
        isFailedWith(
          WatchmeErrorCode.partiallyDelivered,
          message: contains('1 of 3'),
          rawDeviceMessage: 'ECONNREFUSED',
        ),
      );
      final error = (r.result as Failed).error;
      expect((error.cause! as WatchmeError).code, WatchmeErrorCode.unreachable);
      expect(r.via, isNull);
      expect(s.calls, [
        ('keys', const StepVolume(3)),
        ('keys', const PressKey(RemoteKey.volumeUp)),
        ('keys', const PressKey(RemoteKey.volumeUp)),
      ]);
    });

    test('an unmapped press after a delivered one is a partial delivery '
        'too', () async {
      var presses = 0;
      final s = Script({
        'roku': (c) => switch (c) {
          StepVolume() => const RouteAttempt(Unsupported('no steps')),
          _ =>
            ++presses == 1
                ? const RouteAttempt(SentUnconfirmed())
                : const RouteAttempt(Unsupported('gone')),
        },
      });
      final r = await router.route(
        const SetVolume(8),
        [relative, route('other', Support.partial)],
        s.call,
        knownVolume: 10,
      );
      expect(r.result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(s.calls.where((c) => c.$1 == 'other'), isEmpty);
    });

    test('a first press that fails delivered nothing: fallback as '
        'before', () async {
      final s = Script({
        'roku': (c) => switch (c) {
          StepVolume() => const RouteAttempt(Unsupported('no steps')),
          _ => const RouteAttempt(Failed(WatchmeError.unreachable('down'))),
        },
      });
      final r = await router.route(
        const SetVolume(12),
        [relative, route('upnp', Support.partial)],
        s.call,
        knownVolume: 10,
      );
      expect(r.result, isConfirmed);
      expect(r.via?.driverId, 'upnp');
    });

    test('a zero step is confirmed without sending anything', () async {
      final s = Script({});
      final r = await router.route(
        const SetVolume(40),
        [relative],
        s.call,
        knownVolume: 40,
      );
      expect(r.result, isConfirmed);
      expect(s.calls, isEmpty);
    });
  });

  group('partial delivery', () {
    test('is never in the default fallback codes', () {
      expect(
        CapabilityRouter.defaultFallbackCodes,
        isNot(contains(WatchmeErrorCode.partiallyDelivered)),
      );
    });

    test('ends the search even when the fallback codes list it', () async {
      final s = Script({
        'a': (_) => const RouteAttempt(
          Failed(WatchmeError.partiallyDelivered('2 of 5 characters')),
        ),
      });
      final permissive = CapabilityRouter(
        fallbackCodes: {
          ...CapabilityRouter.defaultFallbackCodes,
          WatchmeErrorCode.partiallyDelivered,
        },
      );
      final r = await permissive.route(const StepVolume(5), [
        route('a', Support.yes),
        route('b', Support.partial),
      ], s.call);
      expect(r.result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
      expect(s.calls, hasLength(1));
    });

    test(
      'ends the search even if the attempt claims nothing was sent',
      () async {
        final s = Script({
          'a': (_) => const RouteAttempt(
            Failed(WatchmeError.partiallyDelivered('1 of 3')),
            commandSent: false,
          ),
        });
        final r = await router.route(const StepVolume(3), [
          route('a', Support.yes),
          route('b', Support.partial),
        ], s.call);
        expect(r.result, isFailedWith(WatchmeErrorCode.partiallyDelivered));
        expect(s.calls, hasLength(1));
      },
    );

    test('a refused destination falls back: nothing was sent', () async {
      final s = Script({
        'a': (_) => const RouteAttempt(
          Failed(WatchmeError.destinationRefused('public address')),
        ),
      });
      final r = await router.route(const StepVolume(1), [
        route('a', Support.yes),
        route('b', Support.partial),
      ], s.call);
      expect(r.via?.driverId, 'b');
    });
  });
}
