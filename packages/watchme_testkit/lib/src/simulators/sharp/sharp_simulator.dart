import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart' show Endpoint;

import 'sharp_sim_models.dart';

// A synthetic Sharp AQUOS IP-control TV, written from the Sharp manuals'
// command tables and the protocol brief's simulator spec (section 11). It
// is NOT a capture of a real TV: where hardware behaviour is unknown (the
// framing of the login-failure text, what follows it, standby answers,
// client limits) the choice made here is marked as the simulator's own.

/// The text a wrong login gets by default: the words come from one US
/// 2012-2013 field report; the CRLF framing is the simulator's choice.
const String sharpSimMismatchText = '\r\nUser Name or Password mismatch\r\n';

/// A Sharp AQUOS TV's IP-control port on loopback, for driver, engine and
/// UI tests without hardware.
///
/// It speaks the text protocol over TCP: 8-character commands ended by CR
/// (an LF straight after the CR is ignored, an LF alone also ends a line),
/// one reply per command (`OK\r`, `ERR\r` or a value), queued in order
/// when a client sends several at once. With a login set it sends the
/// unterminated `Login:` prompt on every connection, then `\r\nPassword:`
/// and a bare `\r\n` on success; credential bytes sent before the prompts
/// (type-ahead) are buffered and answered in order. With none set it sends
/// nothing until the first command.
///
/// ```dart
/// final sim = SharpSimulator(loginId: 'admin', password: 'secret1');
/// await sim.start();
/// final ep = sim.endpoint; // Endpoint('127.0.0.1', ports: {'ipc': sim.port})
/// // ... drive it ...
/// expect(sim.volume, 30);
/// await sim.stop();
/// ```
///
/// Power follows the brief: `POWR0` answers `OK` and then either keeps
/// listening in network standby (RSPW 2 on US 2010-2013 profiles, Quick
/// Start on US 2014, 4T-B and JP) or closes every connection after
/// [standbyCloseDelay] and refuses new ones until [pressPowerButton].
/// `POWR1` boots the TV for [bootDuration]. The POWER and NETFLIX keys
/// (`RCKY12`, `RCKY59`) also wake a TV in network standby ([keyWakes]),
/// so tests can assert a driver never sends them from a probe or refresh.
///
/// Test controls: [failNext] (drop, silence, malformed or late replies),
/// [holdNext] (hold one reply until released), [dropConnections] (the
/// TV's idle cut), [unplug] / [plugIn], [pressPowerButton], and the
/// records [commands], [rawInput], [pipelined], [successfulLogins] and
/// [failedLogins].
class SharpSimulator {
  /// Creates a simulator (not yet listening; call [start]).
  ///
  /// [volumeMax], [modelReply] and [input] default to the [profile]'s
  /// values; [enforceLogin] defaults to false only for the 2015 firmware.
  SharpSimulator({
    this.profile = SharpSimProfile.us2011,
    this.power = SharpSimPower.on,
    this.rspw = 0,
    this.quickStart = false,
    int? volumeMax,
    this.volume = 20,
    this.muted = false,
    int? input,
    this.loginId = '',
    this.password = '',
    this.deviceName = 'Living Room AQUOS',
    String? modelReply,
    this.swvn = '222U1302091',
    this.ippv = '0100',
    this.bootDuration = const Duration(seconds: 8),
    this.postLoginOk = false,
    this.missingCrBug = false,
    this.leadingCr = false,
    this.strayOk = false,
    this.maxClients = 1,
    this.overflow = SharpSimOverflow.acceptThenClose,
    this.minReconnectGap = Duration.zero,
    bool? enforceLogin,
    this.idleTimeout = const Duration(minutes: 3),
    this.loginFailure = SharpSimLoginFailure.close,
    this.mismatchText = sharpSimMismatchText,
    this.strictCase = true,
    this.acceptRightAligned = false,
    this.acceptBlankForX = true,
    this.acceptZeroForBlank = true,
    this.iavdErrWhenCurrent = true,
    this.keyWakes = true,
    this.standbyQueries = SharpSimStandbyQueries.err,
    this.volumeUnmutes = false,
    this.quickStartWindow,
    this.standbyCloseDelay = const Duration(milliseconds: 500),
  }) : volumeMax = volumeMax ?? profile.volumeMax,
       modelReply = modelReply ?? profile.model,
       iavd = input ?? profile.homeInput,
       enforceLogin = enforceLogin ?? !profile.limited;

  /// The command set. Fixed for the simulator's life.
  final SharpSimProfile profile;

  /// The power state. Prefer [pressPowerButton] and the protocol to
  /// change it while running; setting it directly does not open or close
  /// the port.
  SharpSimPower power;

  /// The power-on command setting: 0 refuses, 1 accepts RS-232C, 2
  /// accepts IP (network standby on US 2010-2013 profiles).
  int rspw;

  /// Quick Start Mode (network standby on US 2014, 4T-B and JP profiles).
  bool quickStart;

  /// Top of the volume scale.
  int volumeMax;

  /// Current volume.
  int volume;

  /// Mute.
  bool muted;

  /// The current `IAVD` input, or `null` when the tuner is in front.
  int? iavd;

  /// The tuned channel, as text (`7`, `7.1`, `12345`).
  String channel = '7';

  /// The app the NETFLIX key opened, if any.
  String? foregroundApp;

  /// Login ID; empty with an empty [password] disables the login.
  String loginId;

  /// Password.
  String password;

  /// `TVNM1` answer.
  String deviceName;

  /// `MNRD1` answer; `null` answers `ERR`.
  String? modelReply;

  /// `SWVN1` answer.
  String swvn;

  /// `IPPV1` (EU: `IPPY1`) answer.
  String ippv;

  /// How long `POWR1` takes to boot the TV.
  Duration bootDuration;

  /// Sends `OK\r` as a second chunk after a successful login (a JP
  /// variant).
  bool postLoginOk;

  /// Sends `OK`/`ERR` without CR and the CR at the start of the next
  /// reply (a JP firmware bug).
  bool missingCrBug;

  /// Frames every reply as `\r<reply>\r`.
  bool leadingCr;

  /// After `ITGD`, `CHUP`, `CHDW` or `POWR1`, sends an extra `OK\r` just
  /// before the next query's value.
  bool strayOk;

  /// Connections served at once.
  int maxClients;

  /// What happens to a connection beyond [maxClients].
  SharpSimOverflow overflow;

  /// A connection sooner than this after the last one closed is closed at
  /// once ("too fast and it won't even open the socket").
  Duration minReconnectGap;

  /// Whether the login is enforced; false shows the prompt but runs
  /// commands without a login (the 2015 firmware).
  bool enforceLogin;

  /// A connection that receives nothing for this long is closed.
  Duration idleTimeout;

  /// What follows a wrong login.
  SharpSimLoginFailure loginFailure;

  /// What a wrong login gets (before the close or the new prompt).
  String mismatchText;

  /// Lower-case commands answer `ERR`.
  bool strictCase;

  /// Space-padded, right-aligned numbers (`RCKY  12`) are accepted.
  bool acceptRightAligned;

  /// US profiles accept four blanks where their tables show `x`.
  bool acceptBlankForX;

  /// EU and 4T-B profiles accept `0` where their tables show blanks.
  bool acceptZeroForBlank;

  /// `IAVDn` (and `IDIN`) for the input already in front answers `ERR`.
  bool iavdErrWhenCurrent;

  /// `RCKY12` and `RCKY59` turn a TV in network standby on.
  bool keyWakes;

  /// How queries are answered in network standby.
  SharpSimStandbyQueries standbyQueries;

  /// Whether a volume change unmutes.
  bool volumeUnmutes;

  /// With Quick Start, network standby lasts only this long (the JP "2
  /// hours only" setting); `null` keeps it.
  Duration? quickStartWindow;

  /// How long after `POWR0` a TV without network standby drops its
  /// connections.
  Duration standbyCloseDelay;

  ServerSocket? _server;
  String _host = '127.0.0.1';
  int? _port;
  bool _running = false;
  bool _unplugged = false;
  Future<void> _listenerOp = Future.value();
  final Set<_SharpConn> _conns = {};
  DateTime? _lastClose;
  int _accepted = 0;
  int _pipelined = 0;
  int _successfulLogins = 0;
  int _failedLogins = 0;
  int _quickRefusals = 0;
  int _overflowClosed = 0;
  final List<SharpSimCommand> _commands = [];
  final List<StringBuffer> _rawInput = [];
  final List<_Fault> _faults = [];
  final List<SharpSimGate> _gates = [];
  final Map<SharpSimGate, int> _gateSkips = {};
  Timer? _bootTimer;
  Timer? _quickStartTimer;
  DateTime? _bootStarted;
  int? _pendingCableMajor;

  /// Whether [start] has completed and [stop] has not been called.
  bool get isRunning => _running;

  /// Whether the port accepts connections right now.
  bool get isListening => _server != null;

  /// The address it listens on.
  String get host => _host;

  /// The IP-control port (stable while running, also while it refuses).
  int get port => _port ?? (throw StateError('SharpSimulator is not running'));

  /// An endpoint for the Sharp driver: [host] with the `ipc` port.
  Endpoint get endpoint => Endpoint(host, ports: {'ipc': port});

  /// Whether a login is set.
  bool get loginEnabled => loginId.isNotEmpty || password.isNotEmpty;

  /// Whether a TV in standby keeps listening.
  bool get networkStandbyEnabled => switch (profile) {
    SharpSimProfile.us2010 || SharpSimProfile.us2011 => rspw == 2,
    SharpSimProfile.eu => false,
    _ => quickStart,
  };

  /// Connections accepted (and served) so far.
  int get connectionsAccepted => _accepted;

  /// Connections open now.
  int get openConnections => _conns.length;

  /// Command lines that arrived while an earlier one was unanswered.
  int get pipelined => _pipelined;

  /// Logins accepted.
  int get successfulLogins => _successfulLogins;

  /// Logins refused.
  int get failedLogins => _failedLogins;

  /// Connections closed at once for coming sooner than [minReconnectGap].
  int get quickRefusals => _quickRefusals;

  /// Connections closed at once for exceeding [maxClients].
  int get overflowClosed => _overflowClosed;

  /// Every command line received after login, in order.
  List<SharpSimCommand> get commands => List.unmodifiable(_commands);

  /// The lines of [commands].
  List<String> get lines => [for (final c in _commands) c.line];

  /// Everything each served connection sent, in order of acceptance,
  /// login bytes included.
  List<String> get rawInput => [for (final b in _rawInput) b.toString()];

  /// Clears [commands], [rawInput] and the counters.
  void clearLog() {
    _commands.clear();
    _rawInput.clear();
    _accepted = 0;
    _pipelined = 0;
    _successfulLogins = 0;
    _failedLogins = 0;
    _quickRefusals = 0;
    _overflowClosed = 0;
  }

  // ------------------------------------------------------------ lifecycle

  /// Starts listening on [host] (loopback by default) and [port] (0 picks
  /// a free one). A TV that is [SharpSimPower.off] keeps the port number
  /// but refuses connections.
  Future<void> start({String host = '127.0.0.1', int port = 0}) async {
    if (_running) throw StateError('SharpSimulator is already running');
    final server = await ServerSocket.bind(host, port);
    _host = host;
    _port = server.port;
    _running = true;
    _attach(server);
    if (!_shouldListen) await _updateListener();
  }

  /// Stops listening and drops every connection.
  Future<void> stop() async {
    _running = false;
    _bootTimer?.cancel();
    _quickStartTimer?.cancel();
    for (final gate in _gates) {
      gate.release();
    }
    _gates.clear();
    await _updateListener();
    for (final c in [..._conns]) {
      c.destroy();
    }
  }

  /// The TV drops off the network: connections are dropped and refused
  /// until [plugIn].
  Future<void> unplug() async {
    _unplugged = true;
    for (final c in [..._conns]) {
      c.destroy();
    }
    await _updateListener();
  }

  /// Undoes [unplug].
  Future<void> plugIn() async {
    _unplugged = false;
    await _updateListener();
  }

  /// Closes every open connection with a FIN, as the TV's idle cut does.
  Future<void> dropConnections() async {
    for (final c in [..._conns]) {
      await c.close();
    }
  }

  /// The physical remote's POWER key: boots a TV that is off or in
  /// standby, sends one that is on (or booting) to standby.
  Future<void> pressPowerButton() async {
    if (power == SharpSimPower.on || power == SharpSimPower.booting) {
      _enterStandby();
    } else {
      _startBoot();
    }
    await _updateListener();
  }

  /// Makes the next command line starting with [prefix] (e.g. `POWR1`,
  /// `VOLM`) meet [fault] after it took effect, letting [skip] matching
  /// lines through first. [delay] is the wait of [SharpSimFault.late].
  void failNext(
    String prefix,
    SharpSimFault fault, {
    Duration delay = const Duration(seconds: 1),
    int skip = 0,
  }) => _faults.add(_Fault(prefix, fault, delay, skip));

  /// Holds the reply to the next command line starting with [prefix] until
  /// [SharpSimGate.release], letting [skip] matching lines through first;
  /// the command takes effect at once.
  SharpSimGate holdNext(String prefix, {int skip = 0}) {
    final gate = SharpSimGate(prefix);
    _gates.add(gate);
    _gateSkips[gate] = skip;
    return gate;
  }

  bool get _shouldListen =>
      _running &&
      !_unplugged &&
      power != SharpSimPower.off &&
      !(overflow == SharpSimOverflow.refuse && _conns.length >= maxClients);

  Future<void> _updateListener() {
    final op = _listenerOp.then((_) async {
      if (_shouldListen && _server == null && _port != null) {
        _attach(await ServerSocket.bind(_host, _port!));
      } else if (!_shouldListen && _server != null) {
        final server = _server!;
        _server = null;
        await server.close();
      }
    });
    _listenerOp = op.then((_) {}, onError: (Object _) {});
    return op;
  }

  void _attach(ServerSocket server) {
    _server = server;
    server.listen(_accept, onError: (Object _) {});
  }

  void _accept(Socket socket) {
    final now = DateTime.now();
    final last = _lastClose;
    if (!_shouldListen) {
      socket.destroy();
      return;
    }
    if (minReconnectGap > Duration.zero &&
        last != null &&
        now.difference(last) < minReconnectGap) {
      _quickRefusals++;
      socket.destroy();
      return;
    }
    if (_conns.length >= maxClients) {
      _overflowClosed++;
      unawaited(socket.close().then((_) => socket.destroy(), onError: (_) {}));
      return;
    }
    // Small writes go out as written, so chunk boundaries (the JP
    // post-login OK, a missing CR) reach the client as the TV sends them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    final raw = StringBuffer();
    _rawInput.add(raw);
    final conn = _SharpConn(this, socket, ++_accepted, raw);
    _conns.add(conn);
    if (overflow == SharpSimOverflow.refuse) unawaited(_updateListener());
    conn.begin();
  }

  void _closed(_SharpConn conn) {
    if (!_conns.remove(conn)) return;
    _lastClose = DateTime.now();
    if (overflow == SharpSimOverflow.refuse) unawaited(_updateListener());
  }

  // ------------------------------------------------------------------ power

  void _enterStandby() {
    _bootTimer?.cancel();
    _bootStarted = null;
    foregroundApp = null;
    if (networkStandbyEnabled) {
      power = SharpSimPower.networkStandby;
      final window = quickStartWindow;
      _quickStartTimer?.cancel();
      if (window != null && quickStart) {
        _quickStartTimer = Timer(window, () {
          if (power != SharpSimPower.networkStandby) return;
          _goOff();
        });
      }
    } else {
      _goOff();
    }
  }

  void _goOff() {
    power = SharpSimPower.off;
    Timer(standbyCloseDelay, () {
      if (power != SharpSimPower.off) return;
      for (final c in [..._conns]) {
        unawaited(c.close());
      }
    });
    unawaited(_updateListener());
  }

  void _startBoot() {
    _quickStartTimer?.cancel();
    power = SharpSimPower.booting;
    _bootStarted = DateTime.now();
    _bootTimer?.cancel();
    _bootTimer = Timer(bootDuration, () {
      if (power == SharpSimPower.booting) power = SharpSimPower.on;
    });
  }

  String _bootPowerReading() {
    final started = _bootStarted;
    if (started == null) return '0';
    final half = bootDuration ~/ 2;
    return DateTime.now().difference(started) < half ? '0' : '1';
  }

  // --------------------------------------------------------------- commands

  /// The reply to [line], after its effect; `null` for no reply.
  String? _execute(String line) {
    if (line.length != 8) return 'ERR';
    if (strictCase && line != line.toUpperCase()) return 'ERR';
    final cmd = line.substring(0, 4).toUpperCase();
    final param = _Param.parse(line.substring(4), acceptRightAligned);
    if (param.kind == _ParamKind.invalid) return 'ERR';

    // Information commands answer in every state where the port listens.
    final info = _info(cmd, param);
    if (info != null) return info;

    switch (power) {
      case SharpSimPower.off:
        return 'ERR';
      case SharpSimPower.networkStandby:
        return _standby(cmd, param);
      case SharpSimPower.booting:
        return _booting(cmd, param);
      case SharpSimPower.on:
        return _on(cmd, param);
    }
  }

  String? _info(String cmd, _Param param) {
    if (param.number != 1 || param.kind != _ParamKind.number) {
      return null;
    }
    String? answer(String? value) =>
        profile.limited || value == null ? 'ERR' : value;
    return switch (cmd) {
      'TVNM' => answer(deviceName),
      'MNRD' => answer(modelReply),
      'SWVN' => answer(swvn),
      'IPPV' => profile.isEu ? 'ERR' : answer(ippv),
      'IPPY' => profile.isEu ? answer(ippv) : 'ERR',
      _ => null,
    };
  }

  String? _standby(String cmd, _Param param) {
    if (cmd == 'POWR') {
      return switch (param.kind) {
        _ParamKind.query => '0',
        _ParamKind.number when param.number == 1 => _powerOn(),
        _ParamKind.number when param.number == 0 => 'OK',
        _ => 'ERR',
      };
    }
    if (cmd == 'RSPW' && param.kind == _ParamKind.query) {
      return profile.rspw ? '$rspw' : 'ERR';
    }
    if (cmd == 'RCKY' &&
        param.kind == _ParamKind.number &&
        keyWakes &&
        (param.number == 12 || param.number == 59) &&
        profile.rcky.contains(param.number)) {
      _startBoot();
      if (param.number == 59) foregroundApp = 'netflix';
      return 'OK';
    }
    if (param.kind == _ParamKind.query &&
        standbyQueries == SharpSimStandbyQueries.silent) {
      return null;
    }
    return 'ERR';
  }

  String? _booting(String cmd, _Param param) {
    if (cmd == 'POWR') {
      return switch (param.kind) {
        _ParamKind.query => profile.limited ? 'ERR' : _bootPowerReading(),
        _ParamKind.number when param.number == 1 => 'OK',
        _ParamKind.number when param.number == 0 => _powerOff(),
        _ => 'ERR',
      };
    }
    return 'ERR';
  }

  String _powerOn() {
    if (profile.isEu) return 'ERR';
    _startBoot();
    return 'OK';
  }

  String _powerOff() {
    // The reply goes out first; the effect follows at once.
    scheduleMicrotask(() {
      _enterStandby();
      unawaited(_updateListener());
    });
    return 'OK';
  }

  String? _on(String cmd, _Param param) {
    final q = param.kind == _ParamKind.query;
    final n = param.kind == _ParamKind.number ? param.number : null;
    if (profile.limited) return _limited(cmd, param);
    switch (cmd) {
      case 'POWR':
        if (q) return '1';
        if (n == 1) return profile.isEu ? 'ERR' : 'OK';
        if (n == 0) return _powerOff();
        return 'ERR';
      case 'RSPW':
        if (!profile.rspw) return 'ERR';
        if (q) return '$rspw';
        if (n != null && n >= 0 && n <= 2) {
          rspw = n;
          return 'OK';
        }
        return 'ERR';
      case 'VOLM':
        if (q) return '$volume';
        if (n != null && n >= 0 && n <= volumeMax) {
          volume = n;
          if (volumeUnmutes) muted = false;
          return 'OK';
        }
        return 'ERR';
      case 'MUTE':
        if (q) return muted ? '1' : '2';
        switch (n) {
          case 0:
            muted = !muted;
          case 1:
            muted = true;
          case 2:
            muted = false;
          default:
            return 'ERR';
        }
        return 'OK';
      case 'IAVD':
        if (q) {
          final current = iavd;
          if (current == null) {
            return profile == SharpSimProfile.us4tb ? '0' : 'ERR';
          }
          return '$current';
        }
        final (low, high) = profile.iavd;
        if (n == null || n < low || n > high) return 'ERR';
        final target = profile == SharpSimProfile.us4tb && n == 0 ? null : n;
        if (iavdErrWhenCurrent && target == iavd) return 'ERR';
        _select(target);
        return 'OK';
      case 'ITVD':
        if (profile == SharpSimProfile.jp || !_argumentless(param)) {
          return 'ERR';
        }
        _select(null);
        return 'OK';
      case 'IDTV':
        if (!profile.isEu || !_argumentless(param)) return 'ERR';
        _select(null);
        return 'OK';
      case 'ITGD':
        if (!_argumentless(param)) return 'ERR';
        _cycleInput();
        return 'OK';
      case 'IDIN':
        if (profile.isEu || profile == SharpSimProfile.jp || n == null) {
          return 'ERR';
        }
        final target = switch (n) {
          >= 50 && <= 53 => n - 49,
          >= 11 && <= 15 => n - 10,
          _ => -1,
        };
        if (target < 0) return 'ERR';
        if (iavdErrWhenCurrent && target == iavd) return 'ERR';
        _select(target);
        return 'OK';
      case 'CHUP' || 'CHDW':
        if (!_argumentless(param)) return 'ERR';
        _select(null);
        final ch = int.tryParse(channel);
        if (ch != null) channel = '${ch + (cmd == 'CHUP' ? 1 : -1)}';
        return 'OK';
      case 'DCCH':
        if (q) {
          final ch = int.tryParse(channel);
          return ch != null && iavd == null ? '$ch' : 'ERR';
        }
        if (n == null || n < 1 || n > (profile.isEu ? 99 : 135)) return 'ERR';
        return _tune('$n');
      case 'DA2P':
        if (profile.isEu || n == null || param.digits.length != 4) {
          return 'ERR';
        }
        final major = n ~/ 100;
        final minor = n % 100;
        if (major < 1) return 'ERR';
        return _tune('$major.$minor');
      case 'DC2U':
        if (profile.isEu || n == null || n < 1 || n > 999) return 'ERR';
        _pendingCableMajor = n;
        return 'OK';
      case 'DC2L':
        final major = _pendingCableMajor;
        if (profile.isEu || n == null || n > 999 || major == null) {
          return 'ERR';
        }
        _pendingCableMajor = null;
        return _tune('$major.$n');
      case 'DC10':
        if (profile.isEu || n == null || n > 9999) return 'ERR';
        return _tune('$n');
      case 'DC11':
        if (profile.isEu || n == null || n > 6383) return 'ERR';
        return _tune('${n + 10000}');
      case 'DTVD':
        if (!profile.isEu || n == null || n < 1 || n > 999) return 'ERR';
        return _tune('$n');
      case 'ACHA' || 'CLCP':
        return _argumentless(param) ? 'OK' : 'ERR';
      case 'RCKY':
        if (n == null || !profile.rcky.contains(n)) return 'ERR';
        _key(n);
        return 'OK';
      default:
        return 'ERR';
    }
  }

  /// The 2015 firmware (S10 transcript; `POWR0` and `IAVDn` untested, the
  /// guesses here are the simulator's).
  String _limited(String cmd, _Param param) {
    if (param.kind == _ParamKind.query) return 'ERR';
    final n = param.kind == _ParamKind.number ? param.number : null;
    switch (cmd) {
      case 'POWR' when n == 1:
        return 'OK';
      case 'POWR' when n == 0:
        return _powerOff();
      case 'MUTE' when n == 0:
        muted = !muted;
        return 'OK';
      case 'RCKY' when n != null && profile.rcky.contains(n):
        _key(n);
        return 'OK';
      default:
        return 'ERR';
    }
  }

  /// Whether [param] fits an argument-less command in this profile.
  bool _argumentless(_Param param) {
    final blank = param.kind == _ParamKind.blank;
    final zero = param.kind == _ParamKind.number && param.number == 0;
    if (profile.blankArguments) return blank || (zero && acceptZeroForBlank);
    return zero || (blank && acceptBlankForX);
  }

  String _tune(String ch) {
    _select(null);
    channel = ch;
    return 'OK';
  }

  void _select(int? input) {
    iavd = input;
    foregroundApp = null;
  }

  void _cycleInput() {
    final (low, high) = profile.iavd;
    final first = low == 0 ? 1 : low;
    final current = iavd;
    _select(
      current == null
          ? first
          : current >= high
          ? null
          : current + 1,
    );
  }

  void _key(int code) {
    switch (code) {
      case 12:
        _powerOff();
      case 31:
        muted = !muted;
      case 32:
        volume = (volume - 1).clamp(0, volumeMax);
        if (volumeUnmutes) muted = false;
      case 33:
        volume = (volume + 1).clamp(0, volumeMax);
        if (volumeUnmutes) muted = false;
      case 34 || 35:
        _select(null);
        final ch = int.tryParse(channel);
        if (ch != null) channel = '${ch + (code == 34 ? 1 : -1)}';
      case 36:
        _cycleInput();
      case 59:
        foregroundApp = 'netflix';
    }
  }

  (SharpSimFault, Duration)? _takeFault(String line) {
    final i = _faults.indexWhere((f) => line.startsWith(f.prefix));
    if (i < 0) return null;
    final f = _faults[i];
    if (f.skip > 0) {
      f.skip--;
      return null;
    }
    _faults.removeAt(i);
    return (f.fault, f.delay);
  }

  SharpSimGate? _takeGate(String line) {
    final i = _gates.indexWhere((g) => g.matches(line));
    if (i < 0) return null;
    final gate = _gates[i];
    final skip = _gateSkips[gate] ?? 0;
    if (skip > 0) {
      _gateSkips[gate] = skip - 1;
      return null;
    }
    _gateSkips.remove(gate);
    return _gates.removeAt(i);
  }
}

final class _Fault {
  _Fault(this.prefix, this.fault, this.delay, this.skip);

  final String prefix;
  final SharpSimFault fault;
  final Duration delay;
  int skip;
}

enum _ParamKind { query, blank, number, invalid }

final class _Param {
  const _Param(this.kind, [this.number = 0, this.digits = '']);

  /// Parses a 4-character parameter: `?` and three blanks or `????` is a
  /// query, four blanks are blank, digits (with an optional minus)
  /// aligned left and filled with blanks, or zero-padded, are a number.
  factory _Param.parse(String p, bool acceptRightAligned) {
    if (p == '?   ' || p == '????') return const _Param(_ParamKind.query);
    if (p == '    ') return const _Param(_ParamKind.blank);
    final left = RegExp(r'^(-?\d+) *$').firstMatch(p);
    final right = acceptRightAligned
        ? RegExp(r'^ +(-?\d+)$').firstMatch(p)
        : null;
    final m = left ?? right;
    if (m == null) return const _Param(_ParamKind.invalid);
    return _Param(_ParamKind.number, int.parse(m.group(1)!), m.group(1)!);
  }

  final _ParamKind kind;
  final int number;
  final String digits;
}

enum _LoginState { user, password, commands }

/// One client connection.
final class _SharpConn {
  _SharpConn(this.sim, this.socket, this.id, this.raw);

  final SharpSimulator sim;
  final Socket socket;
  final int id;
  final StringBuffer raw;
  final List<int> _partial = [];
  final List<String> _lines = [];
  bool _lastCr = false;
  bool _processing = false;
  bool _awaitingReply = false;
  bool _closed = false;
  bool _crOwed = false;
  bool _strayArmed = false;
  _LoginState _state = _LoginState.commands;
  String _user = '';
  Timer? _idle;

  void begin() {
    if (sim.loginEnabled) {
      _write('Login:');
      if (sim.enforceLogin) _state = _LoginState.user;
    }
    _touch();
    // A client that resets the connection (one that closes with a reply
    // unread) fails the write side too; that is the client leaving, not an
    // error of the test.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    socket.listen(
      _onData,
      onError: (Object _) => destroy(),
      onDone: () => unawaited(close()),
    );
  }

  void _touch() {
    _idle?.cancel();
    _idle = Timer(sim.idleTimeout, () => unawaited(close()));
  }

  void _onData(Uint8List data) {
    raw.write(latin1.decode(data));
    _touch();
    for (final b in data) {
      if (b == 0x0d) {
        _emitLine();
        _lastCr = true;
      } else if (b == 0x0a) {
        if (!_lastCr) _emitLine();
        _lastCr = false;
      } else {
        _partial.add(b);
        _lastCr = false;
      }
    }
    unawaited(_pump());
  }

  void _emitLine() {
    final line = latin1.decode(_partial);
    _partial.clear();
    if (_state == _LoginState.commands &&
        (_awaitingReply || _lines.isNotEmpty)) {
      sim._pipelined++;
    }
    _lines.add(line);
  }

  Future<void> _pump() async {
    if (_processing) return;
    _processing = true;
    try {
      while (_lines.isNotEmpty && !_closed) {
        await _handle(_lines.removeAt(0));
      }
    } finally {
      _processing = false;
    }
  }

  Future<void> _handle(String line) async {
    switch (_state) {
      case _LoginState.user:
        _user = line;
        _write('\r\nPassword:');
        _state = _LoginState.password;
        return;
      case _LoginState.password:
        if (_user == sim.loginId && line == sim.password) {
          sim._successfulLogins++;
          _write('\r\n');
          _state = _LoginState.commands;
          if (sim.postLoginOk) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            _write('OK\r');
          }
        } else {
          sim._failedLogins++;
          _write(sim.mismatchText);
          if (sim.loginFailure == SharpSimLoginFailure.close) {
            await close();
          } else {
            _write('Login:');
            _state = _LoginState.user;
          }
        }
        return;
      case _LoginState.commands:
        await _command(line);
    }
  }

  Future<void> _command(String line) async {
    _awaitingReply = true;
    final isQuery = line.length == 8 && line.substring(4).startsWith('?');
    final reply = sim._execute(line);
    final fault = sim._takeFault(line);
    sim._commands.add(SharpSimCommand(id, line, reply, fault: fault?.$1));
    final gate = sim._takeGate(line);
    if (gate != null) await gate.hold();
    final stray = _strayArmed && isQuery && reply != null;
    if (isQuery) _strayArmed = false;
    if (sim.strayOk &&
        reply == 'OK' &&
        const {'ITGD', 'CHUP', 'CHDW', 'POWR'}.contains(line.substring(0, 4)) &&
        (line.substring(0, 4) != 'POWR' || line.substring(4, 5) == '1')) {
      _strayArmed = true;
    }
    if (_closed) return;
    switch (fault?.$1) {
      case SharpSimFault.drop:
        _awaitingReply = false;
        destroy();
        return;
      case SharpSimFault.silent:
        _awaitingReply = false;
        return;
      case SharpSimFault.malformed:
        _awaitingReply = false;
        _write('OKR\r');
        return;
      case SharpSimFault.junk:
        _awaitingReply = false;
        _write('Z' * 300);
        return;
      case SharpSimFault.late:
        _awaitingReply = false;
        await Future<void>.delayed(fault!.$2);
        if (reply != null) _reply(reply);
        return;
      case null:
        break;
    }
    if (reply == null) {
      _awaitingReply = false;
      return;
    }
    if (stray) _write('OK\r');
    _reply(reply);
    _awaitingReply = false;
  }

  void _reply(String value) {
    var out = value;
    if (_crOwed) {
      out = '\r$out';
      _crOwed = false;
    }
    if (sim.leadingCr) out = '\r$out';
    if (sim.missingCrBug && (value == 'OK' || value == 'ERR')) {
      _write(out);
      _crOwed = true;
    } else {
      _write('$out\r');
    }
  }

  void _write(String text) {
    if (_closed) return;
    try {
      socket.add(latin1.encode(text));
    } on Object {
      destroy();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _idle?.cancel();
    sim._closed(this);
    try {
      await socket.flush();
      await socket.close();
    } on Object {
      // The peer is gone already.
    }
    socket.destroy();
  }

  void destroy() {
    if (!_closed) {
      _closed = true;
      _idle?.cancel();
      sim._closed(this);
    }
    socket.destroy();
  }
}
