import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

import '../network/io_errors.dart';
import '../network/io_network_stack.dart' show isPrivateLanAddress;
import 'ssdp_discovery.dart';
import 'ssdp_message.dart';

/// One SSDP `NOTIFY` received by an [SsdpNotifyListener].
final class SsdpAnnouncement {
  /// Creates an announcement of [message] from [sender], placed under
  /// [destinationPolicy] (see `ssdpPlacement`).
  const SsdpAnnouncement(
    this.sender,
    this.message, {
    this.destinationPolicy = DestinationPolicy.lanOnly,
  });

  /// The address the datagram came from.
  final String sender;

  /// The parsed NOTIFY.
  final SsdpMessage message;

  /// The policy [hit] places the announcement under.
  final DestinationPolicy destinationPolicy;

  /// Whether the device announces itself (`ssdp:alive` or `ssdp:update`)
  /// rather than leaving (`ssdp:byebye`).
  bool get alive => !message.isByeBye;

  /// The announcement as a discovery hit (without description fields), or
  /// `null` when [destinationPolicy] refuses the [sender]. A
  /// [SsdpNotifyListener] never delivers such an announcement.
  DiscoveryHit? get hit => ssdpHit(sender, message, policy: destinationPolicy);

  @override
  String toString() => 'SsdpAnnouncement($sender, $message)';
}

/// Listens passively for SSDP `NOTIFY` announcements (devices coming,
/// going, and re-announcing every few minutes). It sends nothing.
///
/// Binds the SSDP port with address and port reuse, so it coexists with
/// other SSDP listeners on the host (minissdpd, media servers), and joins
/// the group on [interfaces] (by default every interface with a private or
/// link-local IPv4 address). Not part of the `NetworkStack` contract: this
/// is a native-only helper for long-running hosts such as the hub.
///
/// Safety: a datagram whose sender [destinationPolicy] refuses (LAN-only by
/// default) is dropped before it is parsed, and each announcement's `hit`
/// applies the same policy to its `LOCATION`.
final class SsdpNotifyListener {
  /// Creates a listener.
  SsdpNotifyListener({
    this.group = ssdpGroup,
    this.port = ssdpPort,
    this.interfaces,
    this.destinationPolicy = DestinationPolicy.lanOnly,
  });

  /// Multicast group to join.
  final String group;

  /// Port to listen on.
  final int port;

  /// Interfaces to join the group on; `null` for every LAN interface.
  final List<NetworkInterface>? interfaces;

  /// Which senders are heard; LAN-only by default. Loopback tests opt in
  /// with `DestinationPolicy(allowLoopback: true)`.
  final DestinationPolicy destinationPolicy;

  /// Announcements until the subscription is cancelled. Search requests and
  /// responses on the port are ignored, as are malformed datagrams. Fails
  /// with a [WatchmeError] if the port cannot be bound.
  Stream<SsdpAnnouncement> listen() {
    RawDatagramSocket? socket;
    var cancelled = false;
    late final StreamController<SsdpAnnouncement> controller;

    Future<void> start() async {
      final s = socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      // Cancelled while binding: onCancel found no socket to close.
      if (cancelled) {
        s.close();
        return;
      }
      final address = InternetAddress(group);
      final joinOn = interfaces ?? await _lanInterfaces();
      if (cancelled) {
        s.close();
        return;
      }
      var joined = 0;
      for (final interface in joinOn) {
        try {
          s.joinMulticast(address, interface);
          joined++;
        } on SocketException {
          // An interface without multicast support; the others still work.
        }
      }
      if (joined == 0) s.joinMulticast(address);
      s.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          for (var d = s.receive(); d != null; d = s.receive()) {
            final sender = d.address.address;
            if (!destinationPolicy.allows(sender)) continue;
            final message = SsdpMessage.tryParseBytes(d.data);
            if (message?.kind == SsdpMessageKind.notify &&
                !controller.isClosed) {
              controller.add(
                SsdpAnnouncement(
                  sender,
                  message!,
                  destinationPolicy: destinationPolicy,
                ),
              );
            }
          }
        },
        // A socket error (e.g. an ICMP report on Windows) is reported on the
        // stream instead of escaping as an uncaught async error.
        onError: (Object e) {
          if (!controller.isClosed) {
            controller.addError(ioError(e, '$group:$port', connected: false));
          }
        },
        onDone: () => controller.close(),
      );
    }

    controller = StreamController(
      onListen: () => start().catchError((Object e) {
        if (cancelled || controller.isClosed) return;
        controller
          ..addError(ioError(e, '$group:$port', connected: false))
          ..close();
      }),
      onCancel: () {
        cancelled = true;
        socket?.close();
      },
    );
    return controller.stream;
  }

  static Future<List<NetworkInterface>> _lanInterfaces() async => [
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    ))
      if (interface.addresses.any(isPrivateLanAddress)) interface,
  ];
}
