import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

TokenCredential credentialFor(String pin) => TokenCredential(
  driverId: 'firetv.lightning',
  deviceId: 'dev-1',
  createdAt: DateTime.utc(2026),
  token: 'token-for-$pin',
);

void main() {
  test('run() emits prompts, takes input and ends with Paired', () async {
    final flow = PairingFlowController.run((c) async {
      c.emit(const Instruct('Waking the TV'));
      final pin = await c.prompt(
        const EnterCode('PIN shown on the TV', 4, CodeAlphabet.digits),
      );
      return credentialFor(pin);
    });

    final steps = <PairingStep>[];
    final done = Completer<void>();
    flow.steps.listen(steps.add, onDone: done.complete);
    await pumpEventQueue();
    expect(steps.last, isA<EnterCode>());
    flow.submit('1234');
    await done.future;

    expect(steps, hasLength(3));
    expect(steps[0], const Instruct('Waking the TV'));
    expect(steps.last, Paired(credentialFor('1234')));
  });

  test('input submitted before it is asked for is queued', () async {
    final flow = PairingFlowController.run((c) async {
      await Future<void>.delayed(Duration.zero);
      return credentialFor(await c.nextInput());
    });
    flow.submit('9999');
    final steps = await flow.steps.toList();
    expect(steps.single, Paired(credentialFor('9999')));
  });

  test('a WatchmeError from the body becomes PairingFailed', () async {
    final flow = PairingFlowController.run(
      (c) async => throw const WatchmeError.rejected(
        'Wrong PIN',
        rawDeviceMessage: '{"description":"Invalid PIN"}',
      ),
    );
    final steps = await flow.steps.toList();
    final failed = steps.single as PairingFailed;
    expect(failed.error.code, WatchmeErrorCode.rejected);
    expect(failed.rawDeviceMessage, '{"description":"Invalid PIN"}');
  });

  test('other errors become internal failures', () async {
    final flow = PairingFlowController.run((c) async => throw StateError('x'));
    final steps = await flow.steps.toList();
    expect(
      (steps.single as PairingFailed).error.code,
      WatchmeErrorCode.internal,
    );
  });

  test(
    'cancel() ends the flow, fails the pending prompt, runs onCancel',
    () async {
      var onCancelRan = false;
      Object? bodyError;
      final flow = PairingFlowController.run((c) async {
        try {
          await c.prompt(const EnterCode('PIN', 4, CodeAlphabet.digits));
        } catch (e) {
          bodyError = e;
          rethrow;
        }
        return credentialFor('never');
      }, onCancel: () => onCancelRan = true);
      final stepsFuture = flow.steps.toList();
      await pumpEventQueue();
      await flow.cancel();
      final steps = await stepsFuture;
      await pumpEventQueue();

      expect(steps.first, isA<EnterCode>());
      expect(steps.last, isA<PairingFailed>());
      expect(
        (steps.last as PairingFailed).error.code,
        WatchmeErrorCode.cancelled,
      );
      expect(steps.whereType<PairingFailed>(), hasLength(1));
      expect(onCancelRan, isTrue);
      expect(bodyError, isA<WatchmeError>());
      flow.submit('late'); // ignored
      await flow.cancel(); // idempotent
    },
  );

  test('emit rejects terminal steps', () {
    final c = PairingFlowController();
    expect(
      () => c.emit(const PairingFailed(WatchmeError.internal('x'))),
      throwsArgumentError,
    );
  });

  test('steps are buffered until listened to', () async {
    final c = PairingFlowController();
    c.emit(const Instruct('one'));
    c.complete(credentialFor('0000'));
    expect(c.isDone, isTrue);
    final steps = await c.steps.toList();
    expect(steps, [const Instruct('one'), Paired(credentialFor('0000'))]);
  });
}
