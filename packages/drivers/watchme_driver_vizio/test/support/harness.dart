import 'dart:async';
import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';
import 'package:watchme_testkit/vizio_simulator.dart';

/// The pairing context every test uses.
const PairingContext testContext = PairingContext(
  deviceId: 'tv-1',
  clientName: 'watchme test',
);

/// Runs [flow], answering each step that awaits input with the next of
/// [inputs] (a `null` entry means "the PIN the simulator shows"; the flow
/// is cancelled when they run out), and returns every step.
Future<List<PairingStep>> drive(
  PairingFlow flow,
  List<String?> inputs, {
  VizioSimulator? sim,
}) async {
  final queue = [...inputs];
  final steps = <PairingStep>[];
  await for (final step in flow.steps) {
    steps.add(step);
    if (step.awaitsInput) {
      if (queue.isEmpty) {
        unawaited(flow.cancel());
      } else {
        flow.submit(queue.removeAt(0) ?? sim!.displayedPin!);
      }
    }
  }
  return steps;
}

/// Pairs [driver] with [sim] using the PIN it shows and returns the
/// credential.
Future<TokenCredential> pair(
  VizioDriver driver,
  VizioSimulator sim,
  Transports transports,
) async {
  final steps = await drive(
    driver.startPairing(sim.endpoint, transports, testContext)!,
    [null],
    sim: sim,
  );
  final last = steps.last;
  if (last is! Paired) throw StateError('Pairing failed: $last');
  return last.credential! as TokenCredential;
}

/// A driver with short timeouts for loopback tests, and no polling unless
/// [pollInterval] is given.
VizioDriver testDriver({
  Clock clock = const SystemClock(),
  Duration readTimeout = const Duration(seconds: 2),
  Duration writeTimeout = const Duration(seconds: 2),
  Duration? pollInterval,
  int maxPinAttempts = 3,
}) => VizioDriver(
  clock: clock,
  probeTimeout: const Duration(seconds: 2),
  readTimeout: readTimeout,
  writeTimeout: writeTimeout,
  pollInterval: pollInterval,
  maxPinAttempts: maxPinAttempts,
);

/// The `(codeset, code)` pairs of a `/key_command/` body.
List<(int, int)> keysOf(VizioSimRequest request) => [
  for (final k
      in (jsonDecode(request.body) as Map<String, Object?>)['KEYLIST']!
          as List<Object?>)
    if (k case {'CODESET': final int cs, 'CODE': final int c}) (cs, c),
];

/// `METHOD /path` of each request, for compact assertions.
List<String> lines(Iterable<VizioSimRequest> requests) => [
  for (final r in requests) '${r.method} ${r.path}',
];

/// Every text an error can reach: its JSON, its string form, its message,
/// raw text and cause chain.
List<String> errorTexts(WatchmeError error) {
  final texts = <String>[
    jsonEncode(error.toJson()),
    '$error',
    error.message,
    '${error.rawDeviceMessage}',
  ];
  Object? cause = error.cause;
  for (var i = 0; i < 8 && cause != null; i++) {
    texts.add('$cause');
    cause = cause is WatchmeError ? cause.cause : null;
  }
  return texts;
}
