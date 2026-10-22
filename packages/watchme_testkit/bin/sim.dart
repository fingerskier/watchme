import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/roku_simulator.dart';

const String _usage = '''
Runs a watchme protocol simulator on this machine until Ctrl+C.

Usage:
  dart run watchme_testkit:sim roku   [options]
  dart run watchme_testkit:sim firetv [options]

Common options:
  --host <address>   Address to listen on (default 127.0.0.1). Use another
                     loopback address (e.g. 127.0.0.2) for a second
                     simulator: watchme treats one address as one device.
  --json             Also print one JSON line with the address and ports.
  -h, --help         Show this help.

roku:
  --port <n>         ECP port (default 8060, the port watchme uses when you
                     add a device by IP; 0 picks a free port).
  --ssdp-port <n>    Also answer unicast SSDP M-SEARCH on this UDP port
                     (0 picks a free port). Off by default.
  --mode <m>         Control by mobile apps: enabled (default), limited or
                     disabled.
  --player           Simulate a Roku Express 4K+ player instead of a TV.

firetv:
  --port <n>         HTTPS remote-API port (default 8080; 0 picks one).
  --dial-port <n>    DIAL port (default 8009; 0 picks one).
  --pin <dddd>       Show this PIN instead of a random one.
  --awake            Start awake (API port open) instead of asleep.

The simulators speak the real protocols over loopback; nothing is sent to
the network. The Fire TV simulator's certificate is a test-only fixture.''';

Future<void> main(List<String> arguments) async {
  final _Args args;
  try {
    args = _Args.parse(arguments);
  } on FormatException catch (e) {
    stderr
      ..writeln('sim: ${e.message}')
      ..writeln()
      ..writeln(_usage);
    exitCode = 64;
    return;
  }
  if (args.help) {
    stdout.writeln(_usage);
    return;
  }
  try {
    final stop = switch (args.simulator) {
      'roku' => await _runRoku(args),
      'firetv' => await _runFireTv(args),
      _ => throw FormatException('unknown simulator "${args.simulator}"'),
    };
    stdout.writeln('Press Ctrl+C to stop.');
    await ProcessSignal.sigint.watch().first;
    stdout.writeln('Stopping.');
    await stop();
  } on SocketException catch (e) {
    stderr.writeln(
      'sim: cannot listen (${e.message}${e.port == null ? '' : ', port ${e.port}'}'
      '${e.osError == null ? '' : ': ${e.osError!.message}'}). '
      'Is another simulator or service using the port? Try --port 0.',
    );
    exitCode = 69;
  } on FormatException catch (e) {
    stderr.writeln('sim: ${e.message}');
    exitCode = 64;
  }
}

Future<Future<void> Function()> _runRoku(_Args args) async {
  final mode = switch (args.option('mode') ?? 'enabled') {
    'enabled' => RokuControlMode.enabled,
    'limited' => RokuControlMode.limited,
    'disabled' => RokuControlMode.disabled,
    final other => throw FormatException('unknown --mode "$other"'),
  };
  final device = args.flag('player')
      ? RokuSimDevice.player
      : const RokuSimDevice();
  final sim = RokuSimulator(device: device, controlMode: mode);
  final ssdpPort = args.intOption('ssdp-port');
  await sim.start(
    address: args.host,
    port: args.intOption('port') ?? 8060,
    ssdp: ssdpPort != null,
    ssdpPort: ssdpPort ?? 0,
  );
  stdout
    ..writeln(
      'Roku ECP simulator "${device.userDeviceName}" '
      '(${device.vendorName} ${device.modelName}, Roku OS '
      '${device.softwareVersion})',
    )
    ..writeln('  ECP:   ${sim.baseUri}')
    ..writeln('  Control by mobile apps: ${mode.name}');
  if (sim.ssdpPort case final port?) {
    stdout.writeln('  SSDP:  udp ${sim.host}:$port (unicast M-SEARCH only)');
  }
  stdout.writeln(
    sim.port == 8060
        ? 'Add it in watchme by IP: ${sim.host}'
        : 'Engine ports for addManual(${sim.host}): {ecp: ${sim.port}}',
  );
  if (args.flag('json')) {
    stdout.writeln(
      jsonEncode({
        'simulator': 'roku',
        'host': sim.host,
        'ports': {'ecp': sim.port, 'ssdp': ?sim.ssdpPort},
      }),
    );
  }

  // Echo what clients do, so a developer driving the app can see it.
  var keys = 0;
  var launches = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final keyLog = sim.keyLog;
    for (final event in keyLog.skip(keys)) {
      stdout.writeln('  key ${event.action.name} ${event.key}');
    }
    keys = keyLog.length;
    final launchLog = sim.launches;
    for (final launch in launchLog.skip(launches)) {
      stdout.writeln('  launch ${launch.appId} ${launch.params}');
    }
    launches = launchLog.length;
  });
  return () async {
    timer.cancel();
    await sim.stop();
  };
}

Future<Future<void> Function()> _runFireTv(_Args args) async {
  final sim = await FireTvSimulator.start(
    host: args.host,
    dialPort: args.intOption('dial-port') ?? 8009,
    apiPort: args.intOption('port') ?? 8080,
    pin: args.option('pin'),
    awake: args.flag('awake'),
  );
  stdout
    ..writeln('Fire TV simulator (${sim.awake ? 'awake' : 'asleep'})')
    ..writeln('  DIAL:  http://${sim.host}:${sim.dialPort}/apps/FireTVRemote')
    ..writeln('  API:   https://${sim.host}:${sim.apiPort}/ (self-signed)')
    ..writeln('  Certificate sha256: ${sim.certificateSha256}');
  stdout.writeln(
    sim.dialPort == 8009 && sim.apiPort == 8080
        ? 'Add it in watchme by IP: ${sim.host}, then pair; the PIN '
              'appears here.'
        : 'Engine ports for addManual(${sim.host}): '
              '{dial: ${sim.dialPort}, api: ${sim.apiPort}}',
  );
  if (args.flag('json')) {
    stdout.writeln(
      jsonEncode({
        'simulator': 'firetv',
        'host': sim.host,
        'ports': {'dial': sim.dialPort, 'api': sim.apiPort},
      }),
    );
  }

  var effects = 0;
  final subscription = sim.onRequest.listen((request) async {
    if (request.path != '/v1/FireTV/pin/display') return;
    // The PIN is chosen while the request is answered, just after this
    // event; wait for it briefly.
    for (var i = 0; i < 50 && sim.displayedPin == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (sim.displayedPin case final pin?) {
      stdout.writeln('  PIN shown on the TV: $pin');
    }
  });
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final log = sim.effects;
    for (final effect in log.skip(effects)) {
      stdout.writeln('  did $effect');
    }
    effects = log.length;
  });
  return () async {
    timer.cancel();
    await subscription.cancel();
    await sim.close();
  };
}

final class _Args {
  _Args(this.simulator, this._options, this._flags);

  static const Set<String> _valued = {
    'host',
    'port',
    'ssdp-port',
    'dial-port',
    'mode',
    'pin',
  };
  static const Set<String> _boolean = {'json', 'player', 'awake', 'help'};

  factory _Args.parse(List<String> arguments) {
    String? simulator;
    final options = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg == '-h' || arg == '--help') {
        flags.add('help');
        continue;
      }
      if (!arg.startsWith('--')) {
        if (simulator != null) {
          throw FormatException('unexpected argument "$arg"');
        }
        simulator = arg;
        continue;
      }
      final eq = arg.indexOf('=');
      final name = arg.substring(2, eq < 0 ? arg.length : eq);
      if (_boolean.contains(name) && eq < 0) {
        flags.add(name);
      } else if (_valued.contains(name)) {
        if (eq >= 0) {
          options[name] = arg.substring(eq + 1);
        } else if (i + 1 < arguments.length) {
          options[name] = arguments[++i];
        } else {
          throw FormatException('--$name needs a value');
        }
      } else {
        throw FormatException('unknown option "$arg"');
      }
    }
    if (simulator == null && !flags.contains('help')) {
      throw const FormatException('name a simulator: roku or firetv');
    }
    return _Args(simulator ?? '', options, flags);
  }

  final String simulator;
  final Map<String, String> _options;
  final Set<String> _flags;

  bool get help => _flags.contains('help');

  String get host => option('host') ?? '127.0.0.1';

  bool flag(String name) => _flags.contains(name);

  String? option(String name) => _options[name];

  int? intOption(String name) {
    final value = _options[name];
    if (value == null) return null;
    final n = int.tryParse(value);
    if (n == null || n < 0 || n > 65535) {
      throw FormatException('--$name must be a port number, not "$value"');
    }
    return n;
  }
}
