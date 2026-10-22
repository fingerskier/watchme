// Runs `bin/sim.dart` the way a developer does, on loopback with free
// ports, and stops it with Ctrl+C.
@TestOn('vm && !windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Starts the CLI with [arguments] and returns it with its stdout lines.
Future<(Process, StreamIterator<String>)> _start(List<String> arguments) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'bin/sim.dart',
    ...arguments,
  ]);
  addTearDown(() => process.kill(ProcessSignal.sigkill));
  unawaited(process.stderr.drain<void>());
  final lines = StreamIterator(
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
  );
  return (process, lines);
}

/// Reads lines until the JSON one, keeping the others in [seen].
Future<Map<String, Object?>> _jsonLine(
  StreamIterator<String> lines,
  List<String> seen,
) async {
  while (await lines.moveNext().timeout(const Duration(seconds: 60))) {
    final line = lines.current;
    if (line.startsWith('{')) return jsonDecode(line) as Map<String, Object?>;
    seen.add(line);
  }
  fail('the simulator printed no JSON line: $seen');
}

/// Stops the CLI with Ctrl+C and expects a clean exit.
Future<void> _stop(Process process) async {
  process.kill(ProcessSignal.sigint);
  expect(await process.exitCode.timeout(const Duration(seconds: 20)), 0);
}

void main() {
  test('--help lists every simulator', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/sim.dart',
      '--help',
    ]);
    expect(result.exitCode, 0);
    for (final name in ['roku', 'firetv', 'vizio', 'panasonic', 'sharp']) {
      expect(result.stdout, contains('sim $name'), reason: name);
    }
  });

  test('a bad option is a usage error', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/sim.dart',
      'sharp',
      '--profile',
      'mars',
    ]);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('unknown --profile "mars"'));
  });

  test('vizio serves its API on the port it prints', () async {
    final (process, lines) = await _start([
      'vizio',
      '--port',
      '0',
      '--legacy-port',
      '0',
      '--pin',
      '1234',
      '--json',
    ]);
    final seen = <String>[];
    final json = await _jsonLine(lines, seen);
    expect(json['simulator'], 'vizio');
    final ports = json['ports']! as Map<String, Object?>;
    // The driver's port names, which no other driver reads.
    expect(ports.keys, {'smartcast', 'smartcastLegacy'});
    expect(json['activePort'], ports['smartcast']);
    expect(seen.join('\n'), contains('VIZIO SmartCast simulator'));
    expect(
      seen.join('\n'),
      contains('{smartcast: ${ports['smartcast']}, smartcastLegacy: '),
    );
    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.https('127.0.0.1:${ports['smartcast']}', '/state/device/deviceinfo'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(await utf8.decodeStream(response), contains('V505-J09'));
    await _stop(process);
  });

  test('panasonic serves its NRC description on the port it prints', () async {
    final (process, lines) = await _start([
      'panasonic',
      '--port',
      '0',
      '--encrypted',
      '--json',
    ]);
    final json = await _jsonLine(lines, []);
    expect(json['simulator'], 'panasonic');
    final port = (json['ports']! as Map<String, Object?>)['nrc'];
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.getUrl(
      Uri.http('127.0.0.1:$port', '/nrc/ddd.xml'),
    );
    final response = await request.close();
    expect(response.statusCode, 200);
    expect(await utf8.decodeStream(response), contains('p00NetworkControl'));
    await _stop(process);
  });

  test('sharp asks for the login it was given', () async {
    final (process, lines) = await _start([
      'sharp',
      '--port',
      '0',
      '--login',
      'admin',
      '--password',
      'pw',
      '--json',
    ]);
    final seen = <String>[];
    final json = await _jsonLine(lines, seen);
    expect(json['simulator'], 'sharp');
    expect(seen.join('\n'), contains('Login: "admin" (enforced)'));
    final port = (json['ports']! as Map<String, Object?>)['ipc']! as int;
    final socket = await Socket.connect('127.0.0.1', port);
    addTearDown(socket.destroy);
    final prompt = await socket
        .map(utf8.decode)
        .first
        .timeout(const Duration(seconds: 10));
    expect(prompt, contains('Login:'));
    await _stop(process);
  });

  test('sharp refuses a standby the profile cannot keep', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      'bin/sim.dart',
      'sharp',
      '--port',
      '0',
      '--profile',
      'eu',
      '--power',
      'standby',
    ]);
    expect(result.exitCode, 64);
    expect(result.stderr, contains('needs network standby'));
  });
}
