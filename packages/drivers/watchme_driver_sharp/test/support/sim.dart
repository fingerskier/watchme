import 'dart:async';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';
import 'package:watchme_testkit/sharp_simulator.dart';

import 'timings.dart';

/// The pairing context the tests use.
const PairingContext testContext = PairingContext(
  deviceId: 'tv-1',
  clientName: 'watchme test',
);

/// Starts [sim] on loopback and stops it after the test.
Future<SharpSimulator> startSim(SharpSimulator sim) async {
  await sim.start();
  addTearDown(sim.stop);
  return sim;
}

/// A driver with the short test timings and no polling.
SharpDriver testDriver({
  SharpTimings timings = fastTimings,
  Duration? pollInterval,
  Clock clock = const SystemClock(),
}) => SharpDriver(timings: timings, pollInterval: pollInterval, clock: clock);

/// Runs [flow], answering each step that awaits input with the next of
/// [inputs] (an [Instruct] needing an ack gets `''` without using one;
/// the flow is cancelled when they run out), and returns every step.
Future<List<PairingStep>> drive(PairingFlow flow, List<String> inputs) async {
  final queue = [...inputs];
  final steps = <PairingStep>[];
  await for (final step in flow.steps) {
    steps.add(step);
    if (!step.awaitsInput) continue;
    if (step is Instruct) {
      flow.submit('');
    } else if (queue.isEmpty) {
      unawaited(flow.cancel());
    } else {
      flow.submit(queue.removeAt(0));
    }
  }
  return steps;
}

/// Connects [driver] to [sim] with [credential] and closes the session
/// after the test.
Future<SharpSession> open(
  SharpDriver driver,
  SharpSimulator sim,
  Transports transports, {
  Credential? credential,
  Endpoint? endpoint,
}) async {
  final session = await driver.connect(
    endpoint ?? sim.endpoint,
    transports,
    credential,
  ) as SharpSession;
  addTearDown(session.close);
  return session;
}

/// A stored login for the device the tests pair.
SharedSecretCredential login(String username, String password) =>
    SharedSecretCredential(
      driverId: sharpDriverId,
      deviceId: testContext.deviceId,
      createdAt: DateTime.utc(2026, 10, 22),
      username: username,
      secret: password,
    );

/// The stored credential of a TV that asks for no login.
final SharedSecretCredential noLogin = SharedSecretCredential(
  driverId: sharpDriverId,
  deviceId: testContext.deviceId,
  createdAt: DateTime.utc(2026, 10, 22),
  secret: '',
);

/// Every line [sim] received that is not a read (query or information
/// command): what could have changed the TV.
List<String> writes(SharpSimulator sim) => [
  for (final line in sim.lines)
    if (!line.substring(4).startsWith('?') &&
        !const {
          'MNRD1   ',
          'TVNM1   ',
          'SWVN1   ',
          'IPPV1   ',
          'IPPY1   ',
        }.contains(line))
      line,
];
