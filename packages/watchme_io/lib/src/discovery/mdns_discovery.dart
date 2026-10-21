import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:multicast_dns/multicast_dns.dart';
import 'package:watchme_core/watchme_core.dart';

import '../network/io_errors.dart';
import 'sender_filtered_socket.dart';
import 'ssdp_discovery.dart' show isDnsSdServiceType;

/// Multicast DNS-SD discovery (provider id `mdns`) over raw sockets, using
/// `package:multicast_dns` (BSD-3-Clause).
///
/// For each service type it sends one PTR query, then resolves every
/// instance it hears about: SRV for the port and target host, TXT for
/// attributes, then A (or AAAA when there is no A record) for the address.
/// Answers usually arrive as additional records with the PTR reply, so most
/// instances resolve from the cache without further queries.
///
/// Hits carry the TXT entries verbatim plus `mdns.instance` (the instance
/// label), `mdns.target` (the SRV host name) and `mdns.service` (the
/// normalised service type). The name is the Cast
/// `fn` TXT entry, or WhisperPlay's `n`, when present, else the instance
/// label. `_airplay._tcp`'s
/// `deviceid` TXT entry, which is the device's MAC, fills
/// [DiscoveryHit.mac].
///
/// Coexistence: like every mDNS querier it binds UDP 5353 with address and
/// port reuse. On Linux that binds next to avahi-daemon (checked with
/// avahi-daemon 0.9 running), and since replies to a query sent from port
/// 5353 are multicast, both receive them. Limitation of the library: an
/// instance label containing a dot can only be resolved from additional
/// records, because its queries split names on dots.
///
/// Safety, under [destinationPolicy] (LAN-only by default: private,
/// link-local and unique-local addresses):
/// * a datagram from a sender the policy refuses is dropped before the
///   mDNS client parses it, so its records never reach the cache;
/// * an instance whose A/AAAA address the policy refuses is dropped, so a
///   spoofed record cannot make watchme probe a host on the internet, in
///   the shared range 100.64.0.0/10 (carrier-grade NAT, VPN overlays), or
///   this host's own loopback services. Only loopback tests allow loopback.
///
/// The stream closes when the window ends and instances already announced
/// have been resolved (each lookup bounded by [resolveTimeout]). It fails
/// with a [WatchmeError] only if the mDNS socket cannot be opened.
final class MdnsDiscovery implements DiscoveryProvider {
  /// Creates a provider.
  ///
  /// [port], [group], [interfaces] and [socketFactory] exist for tests and
  /// unusual hosts; the defaults are standard mDNS on every interface.
  MdnsDiscovery({
    this.serviceTypes = defaultServiceTypes,
    this.resolveTimeout = const Duration(seconds: 2),
    this.port = 5353,
    this.group,
    this.interfaces,
    this.socketFactory = RawDatagramSocket.bind,
    this.destinationPolicy = DestinationPolicy.lanOnly,
  });

  /// The TV-related service types browsed when a scan names none.
  static const List<String> defaultServiceTypes = [
    '_amzn-wplay._tcp',
    '_amzn-fireTv._tcp',
    '_googlecast._tcp',
    '_androidtvremote2._tcp',
    '_airplay._tcp',
    '_companion-link._tcp',
    '_viziocast._tcp',
    '_philipstv_s_rpc._tcp',
  ];

  /// Service types browsed when a scan names none.
  final List<String> serviceTypes;

  /// Deadline for each SRV, TXT and address lookup.
  final Duration resolveTimeout;

  /// The mDNS port.
  final int port;

  /// The mDNS group; `null` for 224.0.0.251.
  final InternetAddress? group;

  /// Interfaces to join the group on; `null` for all of them.
  final NetworkInterfacesFactory? interfaces;

  /// Creates the client's sockets.
  final RawDatagramSocketFactory socketFactory;

  /// Which senders are heard and which resolved addresses are reported;
  /// LAN-only by default. Loopback tests opt in with
  /// `DestinationPolicy(allowLoopback: true)`.
  final DestinationPolicy destinationPolicy;

  @override
  String get id => DiscoveryProviderId.mdns;

  @override
  Set<TransportFeature> get requires => const {TransportFeature.multicast};

  @override
  Stream<DiscoveryHit> scan(
    Duration window, {
    Set<String> serviceTypes = const {},
  }) {
    final types = {
      for (final type
          in serviceTypes.isEmpty
              ? this.serviceTypes
              : serviceTypes.where(isDnsSdServiceType))
        normalizeServiceType(type),
    };
    late final StreamController<DiscoveryHit> out;
    MDnsClient? client;
    var cancelled = false;

    Future<void> run() async {
      if (types.isEmpty) return;
      final c = client = MDnsClient(rawDatagramSocketFactory: _openSocket);
      try {
        await c.start(
          listenAddress: InternetAddress.anyIPv4,
          interfacesFactory: interfaces,
          mDnsPort: port,
          mDnsAddress: group,
          onError: (Object _) {},
        );
      } on Object catch (e) {
        throw ioError(e, 'mDNS port $port', connected: false);
      }
      if (cancelled) return;
      final seen = <String>{};
      final resolving = <Future<void>>[];
      await Future.wait([
        for (final type in types)
          c
              .lookup<PtrResourceRecord>(
                ResourceRecordQuery.serverPointer('$type.local'),
                timeout: window,
              )
              .forEach((ptr) {
                if (cancelled || !seen.add(ptr.domainName.toLowerCase())) {
                  return;
                }
                resolving.add(
                  _resolve(c, type, ptr.domainName).then((hit) {
                    if (hit != null && !cancelled) out.add(hit);
                  }),
                );
              }),
      ]);
      await Future.wait(resolving);
    }

    void stop() {
      cancelled = true;
      try {
        client?.stop();
      } on StateError {
        // Still starting; run() notices cancellation and stops it.
      }
    }

    out = StreamController(
      onListen: () => run()
          .catchError((Object e) {
            if (!cancelled) out.addError(e);
          })
          .whenComplete(() {
            stop();
            out.close();
          }),
      onCancel: stop,
    );
    return out.stream;
  }

  Future<DiscoveryHit?> _resolve(
    MDnsClient client,
    String type,
    String instance,
  ) async {
    try {
      final txtFuture = _first(
        client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(instance),
          timeout: resolveTimeout,
        ),
      );
      final srv = await _first(
        client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(instance),
          timeout: resolveTimeout,
        ),
      );
      if (srv == null) {
        txtFuture.ignore();
        return null;
      }
      final address =
          await _first(
            client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv4(srv.target),
              timeout: resolveTimeout,
            ),
          ) ??
          await _first(
            client.lookup<IPAddressResourceRecord>(
              ResourceRecordQuery.addressIPv6(srv.target),
              timeout: resolveTimeout,
            ),
          );
      final txt = await txtFuture;
      if (address == null || !_acceptable(address.address)) return null;
      return mdnsHit(
        serviceType: type,
        instance: instance,
        host: address.address.address,
        port: srv.port,
        target: srv.target,
        txt: parseMdnsTxt(txt?.text ?? ''),
      );
    } on StateError {
      // The client was stopped (scan cancelled) mid-resolution.
      return null;
    }
  }

  bool _acceptable(InternetAddress address) =>
      destinationPolicy.allows(address.address);

  /// [socketFactory]'s socket, hiding datagrams from refused senders.
  Future<RawDatagramSocket> _openSocket(
    dynamic host,
    int port, {
    bool reuseAddress = true,
    bool reusePort = false,
    int ttl = 1,
  }) async => SenderFilteredSocket(
    await socketFactory(
      host,
      port,
      reuseAddress: reuseAddress,
      reusePort: reusePort,
      ttl: ttl,
    ),
    _acceptable,
  );

  static Future<T?> _first<T>(Stream<T> stream) async {
    await for (final value in stream) {
      return value;
    }
    return null;
  }
}

/// Splits TXT record text as `package:multicast_dns` delivers it (one entry
/// per line) into key/value pairs. Keys are kept verbatim; an entry without
/// `=` is a boolean attribute with an empty value; the first occurrence of
/// a key wins (RFC 6763 section 6.4).
Map<String, String> parseMdnsTxt(String text) {
  final out = <String, String>{};
  for (final entry in text.split('\n')) {
    if (entry.isEmpty) continue;
    final eq = entry.indexOf('=');
    final key = eq < 0 ? entry : entry.substring(0, eq);
    if (key.isEmpty) continue;
    out.putIfAbsent(key, () => eq < 0 ? '' : entry.substring(eq + 1));
  }
  return out;
}

/// The hit for a resolved DNS-SD [instance] (its full name, e.g.
/// `Den._amzn-wplay._tcp.local`) of [serviceType], reachable at
/// [host]:[port] through SRV [target], with [txt] attributes.
DiscoveryHit mdnsHit({
  required String serviceType,
  required String instance,
  required String host,
  required int port,
  required String target,
  Map<String, String> txt = const {},
}) {
  final type = normalizeServiceType(serviceType);
  final suffix = '.$type.local';
  final label = instance.toLowerCase().endsWith(suffix)
      ? instance.substring(0, instance.length - suffix.length)
      : instance;
  return DiscoveryHit(
    host: host,
    provider: DiscoveryProviderId.mdns,
    port: port,
    serviceType: type,
    // Cast's `fn`; Amazon WhisperPlay's `n` (its instance label is an opaque
    // `amzn.dmgr:` token).
    name: txt['fn'] ?? (type == '_amzn-wplay._tcp' ? txt['n'] : null) ?? label,
    attributes: {
      ...txt,
      DiscoveryAttr.mdnsInstance: label,
      DiscoveryAttr.mdnsTarget: target,
      DiscoveryAttr.mdnsService: type,
    },
    mac: type == '_airplay._tcp'
        ? tryNormalizeMac(txt['deviceid'] ?? '')
        : null,
  );
}
