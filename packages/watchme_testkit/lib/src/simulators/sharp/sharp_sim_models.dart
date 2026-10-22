import 'dart:async';

/// Which command set the simulated TV speaks, after the Sharp manuals'
/// tables (see the protocol brief, section 6.9).
enum SharpSimProfile {
  /// US 2010 (LE830U family): `VOLM` 0-60, `IAVD` 1-7, no `RCKY`, `RSPW`.
  us2010(
    volumeMax: 60,
    iavd: (1, 7),
    rcky: {},
    rspw: true,
    model: 'LE830U',
    homeInput: 1,
  ),

  /// US 2011-2013: `VOLM` 0-60, `IAVD` 1-8, `RCKY` 0-59, `RSPW`.
  us2011(
    volumeMax: 60,
    iavd: (1, 8),
    rcky: _rcky2011,
    rspw: true,
    model: 'C6400UA',
    homeInput: 1,
  ),

  /// US 2014: `VOLM` 0-100, `IAVD` 1-8, `RCKY` 0-61, `RSPW`; network
  /// standby comes from Quick Start Mode.
  us2014(
    volumeMax: 100,
    iavd: (1, 8),
    rcky: _rcky2014,
    rspw: true,
    model: 'UD27U',
    homeInput: 1,
  ),

  /// US 2015 "ULI" firmware: every query, `MNRD1`, `SWVN1`, `MUTE1/2`,
  /// `VOLMn` and `IAVDn` answer `ERR`; power, `MUTE0` and `RCKY` work. It
  /// shows `Login:` without enforcing it by default.
  us2015Limited(
    volumeMax: 100,
    iavd: (1, 8),
    rcky: _rcky2014,
    model: null,
    homeInput: 1,
  ),

  /// US 4T-B (2021): `VOLM` 0-100, `IAVD` 0-5 (0 = TV), a reduced `RCKY`
  /// set; network standby from Quick Start Mode.
  us4tb(
    volumeMax: 100,
    iavd: (0, 5),
    rcky: _rcky4tb,
    model: '4T-B60BN1U',
    homeInput: 1,
  ),

  /// EU 2011-2013: `POWR1` refused, no `RSPW`, `IAVD` 1-8 with HDMI at
  /// 4-7, `IDTV`, `DTVD`, `IPPY`; the port closes in standby.
  eu(volumeMax: 60, iavd: (1, 8), rcky: {}, model: 'LE830E', homeInput: 4),

  /// JP: `VOLM` 0-100, `IAVD` 1-6; network standby from Quick Start.
  jp(volumeMax: 100, iavd: (1, 6), rcky: {}, model: 'LC-40W35', homeInput: 1);

  const SharpSimProfile({
    required this.volumeMax,
    required this.iavd,
    required this.rcky,
    required this.model,
    required this.homeInput,
    this.rspw = false,
  });

  /// Default top of the `VOLM` scale.
  final int volumeMax;

  /// Lowest and highest `IAVD` number.
  final (int, int) iavd;

  /// `RCKY` codes it accepts.
  final Set<int> rcky;

  /// Whether it has the `RSPW` setting.
  final bool rspw;

  /// Default `MNRD1` answer (made up in the shape real sets use), or `null`
  /// when `MNRD1` answers `ERR`.
  final String? model;

  /// The `IAVD` number of HDMI 1, the input it starts on.
  final int homeInput;

  /// Whether this is an EU command set.
  bool get isEu => this == eu;

  /// Whether this is the write-only 2015 firmware.
  bool get limited => this == us2015Limited;

  /// Whether argument-less commands take four blanks in its manual.
  bool get blankArguments => this == eu || this == us4tb;
}

/// The simulated TV's power.
enum SharpSimPower {
  /// On: every command works.
  on,

  /// Starting after a power-on: `POWR?` reads `0` for the first half of
  /// the boot, then `1`; everything else but power and information
  /// commands answers `ERR`.
  booting,

  /// Standby with IP control listening (RSPW 2 or Quick Start): `POWR?`
  /// reads `0`, `POWR1` and the wake keys turn it on, other commands
  /// answer `ERR` (or nothing, see [SharpSimStandbyQueries]).
  networkStandby,

  /// Off, or standby without network standby: connections are refused.
  off,
}

/// How a TV in network standby answers queries other than `POWR?` and
/// `RSPW?`.
enum SharpSimStandbyQueries {
  /// `ERR` (seen on an LC-70UD27U).
  err,

  /// No answer at all, the connection kept (reported for some models).
  silent,
}

/// What the simulator does with a connection beyond `maxClients`.
enum SharpSimOverflow {
  /// Accepts it and closes it at once.
  acceptThenClose,

  /// Stops listening while the limit is reached, so it is refused.
  refuse,
}

/// What the simulator does after a wrong login.
enum SharpSimLoginFailure {
  /// Sends the mismatch text and closes the connection.
  close,

  /// Sends the mismatch text and `Login:` again.
  reprompt,
}

/// A fault the next matching command meets (see
/// `SharpSimulator.failNext`). The command still takes effect.
enum SharpSimFault {
  /// The connection drops before the reply (the command may have acted).
  drop,

  /// No reply; the connection stays open.
  silent,

  /// The reply is `OKR`.
  malformed,

  /// 300 bytes of junk with no line end instead of the reply.
  junk,

  /// The reply comes after the fault's delay.
  late,
}

/// One command line the simulator received after login.
final class SharpSimCommand {
  /// Creates a record.
  const SharpSimCommand(this.connection, this.line, this.reply, {this.fault});

  /// Which accepted connection (1-based) carried it.
  final int connection;

  /// The line as received, without its terminator.
  final String line;

  /// The reply the TV computed (`null`: none, as in standby silence).
  final String? reply;

  /// The fault it met, if any.
  final SharpSimFault? fault;

  /// The four command characters.
  String get command => line.length >= 4 ? line.substring(0, 4) : line;

  @override
  String toString() => 'SharpSimCommand(#$connection "$line" -> $reply)';
}

/// A reply the simulator holds back (see `SharpSimulator.holdNext`).
final class SharpSimGate {
  /// Creates a gate for lines starting with [prefix].
  SharpSimGate(this.prefix);

  /// The line prefix it waits for.
  final String prefix;

  final Completer<void> _reached = Completer();
  final Completer<void> _release = Completer();

  /// Completes once the line arrived and took effect; its reply is then
  /// held until [release].
  Future<void> get reached => _reached.future;

  /// Whether the line arrived.
  bool get isReached => _reached.isCompleted;

  /// Sends the held reply.
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  /// Whether [line] is the one it waits for.
  bool matches(String line) => !_reached.isCompleted && line.startsWith(prefix);

  /// Marks it reached and waits for [release].
  Future<void> hold() {
    _reached.complete();
    return _release.future;
  }
}

const Set<int> _rcky2011 = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, //
  20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57,
  58, 59,
};

const Set<int> _rcky2014 = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, //
  20, 21, 23, 24, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39,
  40, 41, 42, 43, 44, 45, 46, 47, 49, 50, 51, 52, 53, 54, 55, 56, 57,
  58, 59, 60, 61,
};

const Set<int> _rcky4tb = {
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13, 23, 24, 31, 32, 33, 34, 35, //
  36, 38, 39, 40, 41, 42, 43, 44, 45, 46, 49, 50, 51, 52, 53, 61,
};
