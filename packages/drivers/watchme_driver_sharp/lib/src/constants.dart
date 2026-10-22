import 'package:watchme_core/watchme_core.dart';

/// The Sharp driver id ([DriverDescriptor.id], [DeviceEvent.driverId]).
const String sharpDriverId = 'sharp.aquos';

/// [Endpoint] port names used by the Sharp driver, with their defaults.
abstract final class SharpPorts {
  /// The IP-control text protocol (plain TCP).
  static const String ipc = 'ipc';

  /// Default IP-control port. The TV menu lets the user change it (the JP
  /// manuals allow 1024-65535), so a refused 10002 does not prove that IP
  /// control is off.
  static const int ipcDefault = 10002;
}

/// [Endpoint.attributes] keys the Sharp driver reads.
abstract final class SharpAttributes {
  /// Forces a model profile by its [SharpProfile.id] (`us2010`, `us2011`,
  /// `us2014`, `us2015limited`, `us4tb`, `eu`, `jp`), for a TV whose model
  /// the driver cannot read or does not know.
  static const String profile = 'sharp.profile';

  /// Forces the volume scale: `60` or `100`.
  static const String volumeMax = 'sharp.volumeMax';
}

/// Every wait the driver makes, so tests against a loopback simulator can
/// shorten them. The defaults follow the protocol brief.
final class SharpTimings {
  /// Creates a timing set; every value has the brief's default.
  const SharpTimings({
    this.connect = const Duration(seconds: 5),
    this.promptWait = const Duration(seconds: 1),
    this.promptWaitWithLogin = const Duration(seconds: 2),
    this.loginStep = const Duration(seconds: 2),
    this.loginAnswer = const Duration(milliseconds: 1500),
    this.loginQuiet = const Duration(milliseconds: 200),
    this.unterminatedQuiet = const Duration(milliseconds: 300),
    this.reply = const Duration(seconds: 4),
    this.powerReply = const Duration(seconds: 10),
    this.probeReply = const Duration(milliseconds: 1500),
    this.probeBudget = const Duration(seconds: 5),
    this.reconnectGap = const Duration(milliseconds: 750),
    this.idleClose = const Duration(seconds: 60),
    this.powerOnSettle = const Duration(seconds: 30),
    this.powerOffSettle = const Duration(seconds: 10),
    this.bootRetryInterval = const Duration(milliseconds: 500),
  });

  /// Deadline for opening the TCP connection.
  final Duration connect;

  /// How long to wait for the unterminated `Login:` prompt when no login
  /// is stored. A TV with login disabled sends nothing at all, so silence
  /// for this long means "no login".
  final Duration promptWait;

  /// The same wait when a login is stored.
  final Duration promptWaitWithLogin;

  /// How long to wait for `Password:` after sending the login ID, and for
  /// the answer to the `POWR?` that checks whether the TV enforces its
  /// login.
  final Duration loginStep;

  /// How long to wait for the TV's answer to the password.
  final Duration loginAnswer;

  /// The silence that ends the login answer: the JP variant sends `\r\n`
  /// and `OK\r` in two chunks, and both are discarded.
  final Duration loginQuiet;

  /// How long an unterminated `OK` or `ERR` must stand alone before it is
  /// accepted (some JP firmware sends the CR at the start of the next
  /// answer instead).
  final Duration unterminatedQuiet;

  /// Answer deadline for ordinary requests.
  final Duration reply;

  /// Answer deadline for `POWR1` and `POWR0`, which may answer slowly.
  final Duration powerReply;

  /// Answer deadline for each read the probe makes.
  final Duration probeReply;

  /// Time after which the probe starts no more optional reads, so that,
  /// with one read of [probeReply] still running, it finishes inside the
  /// engine's probe timeout (8 s).
  final Duration probeBudget;

  /// Least time between closing a connection and opening the next one (a
  /// TV "won't even open the socket" when clients reconnect too fast).
  final Duration reconnectGap;

  /// A session closes its idle connection after this long (the TV cuts
  /// one after 3 minutes without traffic) and reconnects on demand.
  final Duration idleClose;

  /// After a delivered `POWR1`, `POWR?` may still read `0` while the TV
  /// boots: a `0` within this window is not taken as standby, and absolute
  /// commands refused with `ERR` are tried again.
  final Duration powerOnSettle;

  /// After a delivered `POWR0`, a `POWR?` of `1` within this window is not
  /// taken as on (unverified timing).
  final Duration powerOffSettle;

  /// Spacing of those retries.
  final Duration bootRetryInterval;
}
