@TestOn('linux || mac-os')
library;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

void main() {
  const runner = IoProcessRunner();

  test('runs to completion and captures output', () async {
    final result = await runner.run('sh', [
      '-c',
      'echo out; echo err >&2; exit 3',
    ]);
    expect(result.exitCode, 3);
    expect(result.stdout, 'out\n');
    expect(result.stderr, 'err\n');
  });

  test('kills a process that outlives its timeout', () async {
    final stopwatch = Stopwatch()..start();
    await expectLater(
      runner.run('sleep', ['10'], timeout: const Duration(milliseconds: 200)),
      throwsWatchmeError(WatchmeErrorCode.timeout),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('a missing program is unsupported', () async {
    await expectLater(
      runner.run('watchme-no-such-program', []),
      throwsWatchmeError(WatchmeErrorCode.unsupported),
    );
  });

  test('a line process echoes stdin lines and exits', () async {
    final process = await runner.start('cat', []);
    final lines = process.stdoutLines.take(2).toList();
    process
      ..writeLine('tx 10:04')
      ..writeLine('tx 10:36');
    expect(await lines, ['tx 10:04', 'tx 10:36']);
    await process.kill();
    expect(await process.exitCode, isNot(0));
  });

  test('IoTransports reports what it has', () {
    final t = IoTransports();
    expect(t.features, containsAll(TransportFeature.allNetwork));
    expect(t.features, contains(TransportFeature.subprocess));
    expect(t.features, isNot(contains(TransportFeature.internet)));
    expect(t.features, isNot(contains(TransportFeature.serialPort)));
    expect(t.serial, isNull);
    expect(t.ble, isNull);
    expect(t.hid, isNull);
    expect(t.ir, isNull);
    expect(t.requireNetwork(), same(t.network));
    expect(
      IoTransports(internet: true).features,
      contains(TransportFeature.internet),
    );
    final restricted = IoTransports(
      network: IoNetworkStack(multicastAllowed: false),
    );
    expect(restricted.features, isNot(contains(TransportFeature.multicast)));
    expect(restricted.supportsAll({TransportFeature.webSocket}), isTrue);
  });
}
