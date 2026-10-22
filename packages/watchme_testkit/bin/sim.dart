import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:watchme_testkit/firetv_simulator.dart';
import 'package:watchme_testkit/panasonic_simulator.dart';
import 'package:watchme_testkit/roku_simulator.dart';
import 'package:watchme_testkit/sharp_simulator.dart';
import 'package:watchme_testkit/vizio_simulator.dart';

const String _usage = '''
Runs a watchme protocol simulator on this machine until Ctrl+C.

Usage:
  dart run watchme_testkit:sim roku      [options]
  dart run watchme_testkit:sim firetv    [options]
  dart run watchme_testkit:sim vizio     [options]
  dart run watchme_testkit:sim panasonic [options]
  dart run watchme_testkit:sim sharp     [options]

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

vizio (SmartCast TV, HTTPS with PIN pairing):
  --port <n>         API port (default 7345, firmware 4.0 and newer; 0 picks
                     one).
  --legacy-port <n>  API port of older firmware (default 9000; 0 picks one).
  --legacy           Listen on the legacy port instead (firmware before 4.0).
  --pin <dddd>       Show this PIN instead of a random one.
  --power <m>        on (default), standby (Quick Start: the API answers) or
                     off (Eco: the port is closed).
  --eco              The power-off key closes the port (Eco mode).
  --old-firmware     The current input also accepts display names.
  --state-extended   Serve /state_extended.
  --v2-volume        Serve /audio/volume/level and /audio/volume/mute.
  --no-tuner         A panel without a tuner (channel keys fail).
  --soundbar         A sound bar (settings root audio_settings); watchme does
                     not drive sound bars yet.

panasonic (VIERA network remote control, UPnP/SOAP):
  --port <n>         Port (default 55000; 0 picks one).
  --encrypted        A 2018 or later set that needs PIN pairing.
  --pin <dddd>       Show this PIN instead of a random one.
  --pac              The model has Pro AV control (current input, on state).
  --standby <m>      Start in standby: network (Powered On by Apps, the port
                     answers) or off (the port is closed).
  --no-network-standby
                     Powered On by Apps is off: standby closes the port.
  --boot-delay <ms>  How long switching on takes (default 5000).
  --wol-port <n>     Also take Wake-on-LAN magic packets on this UDP port.
  --model <number>   Model number, e.g. TC-50AS650U for US key names.
  --allowed-subnet <cidr>
                     Clients outside it get HTTP 403, as on a real TV
                     (default 127.0.0.0/8 on loopback, otherwise 0.0.0.0/0).

sharp (AQUOS IP control, TCP text protocol):
  --port <n>         Port (default 10002; 0 picks one).
  --profile <p>      us2010, us2011 (default), us2014, us2015limited, us4tb,
                     eu or jp.
  --login <id>       Login ID; with --password, the TV asks for a login.
  --password <pw>    Password.
  --enforce-login    Refuse commands until logged in (the default, except
                     for us2015limited).
  --no-enforce-login Show the prompt but run commands without a login.
  --power <m>        on (default), standby (network standby: needs --rspw 2
                     on us2010/us2011, --quick-start on the others) or off.
  --rspw <n>         Power-on command setting 0 (default), 1 or 2.
  --quick-start      Quick Start Mode on.
  --volume-max <n>   Top of the volume scale, 60 or 100 (default by profile).
  --model <text>     The model the TV reports (default by profile).
  --boot-seconds <n> How long POWR1 takes to boot (default 8).
  --post-login-ok    Send a second OK after a login (a JP variant).
  --missing-cr       OK and ERR without their CR (a JP firmware bug).
  --leading-cr       Frame every reply as CR, reply, CR.
  --stray-ok         An extra OK before the next query's value.
  --standby-silent   Answer nothing, not ERR, to queries in standby.

The simulators speak the real protocols over loopback; nothing is sent to
the network. The Fire TV and VIZIO simulators' certificates are test-only
fixtures.''';

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
      'vizio' => await _runVizio(args),
      'panasonic' => await _runPanasonic(args),
      'sharp' => await _runSharp(args),
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

Future<Future<void> Function()> _runVizio(_Args args) async {
  final power = switch (args.option('power') ?? 'on') {
    'on' => VizioSimPower.on,
    'standby' => VizioSimPower.standby,
    'off' => VizioSimPower.off,
    final other => throw FormatException('unknown --power "$other"'),
  };
  final pin = args.option('pin');
  if (pin != null && !RegExp(r'^\d{4}$').hasMatch(pin)) {
    throw FormatException('--pin must be four digits, not "$pin"');
  }
  final sim = await VizioSimulator.start(
    host: args.host,
    apiPort: args.intOption('port') ?? 7345,
    legacyPort: args.intOption('legacy-port') ?? 9000,
    servesLegacyPort: args.flag('legacy'),
    power: power,
    pin: pin,
    ecoMode: args.flag('eco'),
    legacyFirmware: args.flag('old-firmware'),
    stateExtended: args.flag('state-extended'),
    v2Volume: args.flag('v2-volume'),
    hasTuner: !args.flag('no-tuner'),
    settingsRoot: args.flag('soundbar') ? 'audio_settings' : 'tv_settings',
  );
  stdout
    ..writeln(
      'VIZIO SmartCast simulator "${sim.castName}" (${sim.modelName}, '
      '${power.name})',
    )
    ..writeln(
      '  API:   https://${sim.host}:${sim.activePort}/ (self-signed'
      '${sim.servesLegacyPort ? ', legacy port' : ''})',
    )
    ..writeln('  Certificate sha256: ${sim.certificateSha256}')
    ..writeln(
      sim.apiPort == 7345 && sim.legacyPort == 9000
          ? 'Add it in watchme by IP: ${sim.host}, then pair; the PIN '
                'appears here.'
          : 'Engine ports for addManual(${sim.host}): '
                '{smartcast: ${sim.apiPort}, '
                'smartcastLegacy: ${sim.legacyPort}}',
    );
  if (args.flag('json')) {
    stdout.writeln(
      jsonEncode({
        'simulator': 'vizio',
        'host': sim.host,
        'ports': {'smartcast': sim.apiPort, 'smartcastLegacy': sim.legacyPort},
        'activePort': sim.activePort,
        'mdnsTxt': sim.mdnsTxt,
      }),
    );
  }

  var effects = 0;
  String? shown;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final pin = sim.displayedPin;
    if (pin != null && pin != shown) {
      stdout.writeln('  PIN shown on the TV: $pin');
    }
    shown = pin;
    final log = sim.effects;
    for (final effect in log.skip(effects)) {
      stdout.writeln('  did $effect');
    }
    effects = log.length;
  });
  return () async {
    timer.cancel();
    await sim.close();
  };
}

Future<Future<void> Function()> _runPanasonic(_Args args) async {
  final power = switch (args.option('standby')) {
    null => PanasonicSimPower.on,
    'network' => PanasonicSimPower.networkStandby,
    'off' => PanasonicSimPower.standby,
    final other => throw FormatException('unknown --standby "$other"'),
  };
  final pin = args.option('pin');
  if (pin != null && !RegExp(r'^\d{4}$').hasMatch(pin)) {
    throw FormatException('--pin must be four digits, not "$pin"');
  }
  final loopback = InternetAddress.tryParse(args.host)?.isLoopback ?? false;
  final sim = PanasonicSimulator(
    encrypted: args.flag('encrypted'),
    pac: args.flag('pac'),
    power: power,
    poweredOnByApps: !args.flag('no-network-standby'),
    fixedPin: pin,
    bootDelay: Duration(
      milliseconds: args.numberOption('boot-delay', max: 600000) ?? 5000,
    ),
    modelNumber: args.option('model'),
    // A real TV answers 403 to clients on another subnet; on a LAN address
    // the simulator would otherwise refuse everyone.
    allowedSubnet:
        args.option('allowed-subnet') ??
        (loopback ? '127.0.0.0/8' : '0.0.0.0/0'),
  );
  await sim.start(
    host: args.host,
    port: args.intOption('port') ?? 55000,
    wolPort: args.intOption('wol-port'),
  );
  stdout
    ..writeln(
      'Panasonic VIERA simulator "${sim.friendlyName}" (${sim.modelNumber}, '
      '${sim.encrypted ? 'encrypted, PIN pairing' : 'plain'}'
      '${sim.pac ? ', Pro AV control' : ''}, ${power.name})',
    )
    ..writeln('  NRC:   http://${sim.host}:${sim.port}/nrc/ddd.xml')
    ..writeln('  MAC:   ${sim.mac}');
  if (sim.wolPort case final port?) {
    stdout.writeln('  Wake-on-LAN: udp ${sim.host}:$port');
  }
  stdout.writeln(
    sim.port == 55000
        ? 'Add it in watchme by IP: ${sim.host}'
              '${sim.encrypted ? ', then pair; the PIN appears here.' : ''}'
        : 'Engine ports for addManual(${sim.host}): {nrc: ${sim.port}}',
  );
  if (args.flag('json')) {
    stdout.writeln(
      jsonEncode({
        'simulator': 'panasonic',
        'host': sim.host,
        'ports': {'nrc': sim.port, 'wol': ?sim.wolPort},
      }),
    );
  }

  final pins = sim.onPinDisplayed.listen(
    (pin) => stdout.writeln('  PIN shown on the TV: $pin'),
  );
  var effects = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final log = sim.effects;
    for (final effect in log.skip(effects)) {
      stdout.writeln('  did $effect');
    }
    effects = log.length;
  });
  return () async {
    timer.cancel();
    await pins.cancel();
    await sim.stop();
  };
}

Future<Future<void> Function()> _runSharp(_Args args) async {
  final profile = switch (args.option('profile') ?? 'us2011') {
    'us2010' => SharpSimProfile.us2010,
    'us2011' => SharpSimProfile.us2011,
    'us2014' => SharpSimProfile.us2014,
    'us2015limited' => SharpSimProfile.us2015Limited,
    'us4tb' => SharpSimProfile.us4tb,
    'eu' => SharpSimProfile.eu,
    'jp' => SharpSimProfile.jp,
    final other => throw FormatException('unknown --profile "$other"'),
  };
  final power = switch (args.option('power') ?? 'on') {
    'on' => SharpSimPower.on,
    'standby' => SharpSimPower.networkStandby,
    'off' => SharpSimPower.off,
    final other => throw FormatException('unknown --power "$other"'),
  };
  final volumeMax = args.numberOption('volume-max', max: 100);
  if (volumeMax != null && volumeMax != 60 && volumeMax != 100) {
    throw FormatException('--volume-max must be 60 or 100, not $volumeMax');
  }
  if (args.flag('enforce-login') && args.flag('no-enforce-login')) {
    throw const FormatException(
      'give --enforce-login or --no-enforce-login, not both',
    );
  }
  final sim = SharpSimulator(
    profile: profile,
    power: power,
    rspw: args.numberOption('rspw', max: 2) ?? 0,
    quickStart: args.flag('quick-start'),
    volumeMax: volumeMax,
    loginId: args.option('login') ?? '',
    password: args.option('password') ?? '',
    modelReply: args.option('model'),
    bootDuration: Duration(
      seconds: args.numberOption('boot-seconds', max: 600) ?? 8,
    ),
    postLoginOk: args.flag('post-login-ok'),
    missingCrBug: args.flag('missing-cr'),
    leadingCr: args.flag('leading-cr'),
    strayOk: args.flag('stray-ok'),
    standbyQueries: args.flag('standby-silent')
        ? SharpSimStandbyQueries.silent
        : SharpSimStandbyQueries.err,
    enforceLogin: args.flag('enforce-login')
        ? true
        : args.flag('no-enforce-login')
        ? false
        : null,
  );
  if (power == SharpSimPower.networkStandby && !sim.networkStandbyEnabled) {
    throw const FormatException(
      '--power standby needs network standby: --rspw 2 on us2010 and us2011, '
      '--quick-start on us2014, us2015limited, us4tb and jp (eu has none)',
    );
  }
  await sim.start(host: args.host, port: args.intOption('port') ?? 10002);
  stdout
    ..writeln(
      'Sharp AQUOS simulator "${sim.deviceName}" (${profile.name}, model '
      '${sim.modelReply ?? 'unreported'}, ${power.name})',
    )
    ..writeln('  IP control: tcp ${sim.host}:${sim.port}')
    ..writeln(
      sim.loginEnabled
          ? '  Login: "${sim.loginId}" '
                '(${sim.enforceLogin ? 'enforced' : 'prompt only'})'
          : '  Login: none',
    )
    ..writeln(
      sim.port == 10002
          ? 'Add it in watchme by IP: ${sim.host}'
          : 'Engine ports for addManual(${sim.host}): {ipc: ${sim.port}}',
    );
  if (args.flag('json')) {
    stdout.writeln(
      jsonEncode({
        'simulator': 'sharp',
        'host': sim.host,
        'ports': {'ipc': sim.port},
      }),
    );
  }

  var commands = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final log = sim.commands;
    for (final command in log.skip(commands)) {
      stdout.writeln('  got "${command.line.trimRight()}" -> ${command.reply}');
    }
    commands = log.length;
  });
  return () async {
    timer.cancel();
    await sim.stop();
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
    'legacy-port',
    'power',
    'standby',
    'boot-delay',
    'wol-port',
    'model',
    'allowed-subnet',
    'profile',
    'login',
    'password',
    'rspw',
    'volume-max',
    'boot-seconds',
  };
  static const Set<String> _boolean = {
    'json',
    'player',
    'awake',
    'help',
    'legacy',
    'eco',
    'old-firmware',
    'state-extended',
    'v2-volume',
    'no-tuner',
    'soundbar',
    'encrypted',
    'pac',
    'no-network-standby',
    'enforce-login',
    'no-enforce-login',
    'quick-start',
    'post-login-ok',
    'missing-cr',
    'leading-cr',
    'stray-ok',
    'standby-silent',
  };

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
      throw const FormatException(
        'name a simulator: roku, firetv, vizio, panasonic or sharp',
      );
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

  /// A whole number from 0 to [max].
  int? numberOption(String name, {required int max}) {
    final value = _options[name];
    if (value == null) return null;
    final n = int.tryParse(value);
    if (n == null || n < 0 || n > max) {
      throw FormatException(
        '--$name must be a number from 0 to $max, not '
        '"$value"',
      );
    }
    return n;
  }
}
