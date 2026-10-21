import 'package:watchme_core/watchme_core.dart';

import 'local_network.dart';

/// One destination of a Wake-on-LAN packet.
typedef WakeTarget = ({String host, int port, bool broadcast});

/// What [WakeOnLan.wake] did.
final class WakeOnLanReport {
  /// Creates a report.
  const WakeOnLanReport({required this.sent, required this.failed});

  /// Destinations at least one packet reached the OS for.
  final List<WakeTarget> sent;

  /// Destinations every attempt failed for, with the last error.
  final Map<WakeTarget, WatchmeError> failed;

  /// Whether anything was sent.
  bool get anySent => sent.isNotEmpty;

  @override
  String toString() =>
      'WakeOnLanReport(sent: ${sent.length}, failed: ${failed.length})';
}

/// Sends Wake-on-LAN magic packets (built by `magicPacket` in watchme_core)
/// through a [NetworkStack].
///
/// One wake sends the packet, [repeats] times [interval] apart, to every
/// port in [ports] (9 and 7 by default) on:
/// * the limited broadcast 255.255.255.255 (unless [limitedBroadcast] is
///   false),
/// * each subnet-directed broadcast from [subnetBroadcasts] (by default the
///   host's subnets, see [LocalNetwork.broadcastAddresses]), which reaches
///   TVs when the OS sends the limited broadcast out of another interface,
/// * the device's last known IP as unicast, when given; this needs no
///   broadcast permission (iOS) but relies on the OS still knowing the MAC
///   for that IP.
///
/// Delivery cannot be confirmed: a TV wakes only if its network standby
/// setting is on, and only on the interface it last used.
final class WakeOnLan {
  /// Creates a sender.
  WakeOnLan(
    this.network, {
    this.ports = const [wakeOnLanPort, 7],
    this.limitedBroadcast = true,
    Future<List<String>> Function()? subnetBroadcasts,
    this.repeats = 3,
    this.interval = const Duration(milliseconds: 100),
    this.clock = const SystemClock(),
  }) : subnetBroadcasts = subnetBroadcasts ?? LocalNetwork.broadcastAddresses;

  /// Sends the datagrams.
  final NetworkStack network;

  /// UDP ports to send to.
  final List<int> ports;

  /// Whether to send to 255.255.255.255.
  final bool limitedBroadcast;

  /// Supplies subnet-directed broadcast addresses.
  final Future<List<String>> Function() subnetBroadcasts;

  /// Packets per destination.
  final int repeats;

  /// Gap between repeats.
  final Duration interval;

  /// Time source for [interval].
  final Clock clock;

  /// The destinations a wake would use, in send order.
  Future<List<WakeTarget>> targets({String? lastKnownIp}) async {
    final hosts = <(String, bool)>[
      if (limitedBroadcast) ('255.255.255.255', true),
      for (final b in await _subnetBroadcasts()) (b, true),
      if (lastKnownIp != null) (lastKnownIp, false),
    ];
    final out = <WakeTarget>[];
    final seen = <String>{};
    for (final (host, broadcast) in hosts) {
      for (final port in ports) {
        if (seen.add('$host:$port')) {
          out.add((host: host, port: port, broadcast: broadcast));
        }
      }
    }
    return out;
  }

  /// Wakes the device with [mac] (any format `normalizeMac` accepts), also
  /// unicasting to [lastKnownIp] when given.
  ///
  /// Throws `FormatException` for an invalid MAC, and [WatchmeError]
  /// ([WatchmeErrorCode.unreachable], or the stack's error) when not a
  /// single packet could be sent; partial failures are in the report.
  Future<WakeOnLanReport> wake(String mac, {String? lastKnownIp}) async {
    final packet = magicPacket(mac);
    final destinations = await targets(lastKnownIp: lastKnownIp);
    final sent = <WakeTarget>[];
    final failed = <WakeTarget, WatchmeError>{};
    for (var round = 0; round < repeats; round++) {
      if (round > 0) await clock.delay(interval);
      for (final target in destinations) {
        try {
          await network.sendDatagram(
            target.host,
            target.port,
            packet,
            broadcast: target.broadcast,
          );
          if (!sent.contains(target)) sent.add(target);
          failed.remove(target);
        } on WatchmeError catch (e) {
          if (!sent.contains(target)) failed[target] = e;
        }
      }
    }
    if (sent.isEmpty) {
      throw failed.values.firstOrNull ??
          const WatchmeError.unreachable('No Wake-on-LAN destination');
    }
    return WakeOnLanReport(sent: sent, failed: failed);
  }

  /// Like [wake], but never throws: `true` when at least one packet went
  /// out, `false` for an invalid MAC or when nothing could be sent. Its
  /// shape is the engine's Wake-on-LAN sender. The engine calls its sender
  /// once per round and repeats the rounds itself, stopping between them
  /// when it is closed, so hosts pass `WakeOnLan(network, repeats: 1).send`
  /// to `Engine(wakeOnLan: ...)`: with more [repeats], each call would
  /// repeat every packet again, and those repeats could not be stopped.
  Future<bool> send(String mac, {String? lastKnownIp}) async {
    try {
      return (await wake(mac, lastKnownIp: lastKnownIp)).anySent;
    } on FormatException {
      return false;
    } on WatchmeError {
      return false;
    }
  }

  Future<List<String>> _subnetBroadcasts() async {
    try {
      return await subnetBroadcasts();
    } on Object {
      return const [];
    }
  }
}
