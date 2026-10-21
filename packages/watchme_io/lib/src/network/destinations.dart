import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

/// Resolves a host name to its addresses; the shape of
/// `InternetAddress.lookup`.
typedef HostLookup = Future<List<InternetAddress>> Function(String host);

/// Turns the host of a unicast destination into the IP addresses the stack
/// may connect to, enforcing a [DestinationPolicy] on each of them.
///
/// * An IP literal is parsed here, never resolved. An IPv6 zone id
///   (`fe80::1%eth0`) is stripped before parsing and re-applied to the
///   parsed address so that the connection keeps its scope; a zone on an
///   IPv4 literal is refused.
/// * A host name is resolved with [lookup]. Every address it resolves to
///   is checked, and one refused address refuses the whole name: a name
///   that answers with both a LAN and an internet address is how DNS
///   rebinding starts, so watchme does not pick the "good" one.
/// * The addresses are returned as `InternetAddress` values and the caller
///   connects to exactly those, so a second DNS answer can never replace
///   the checked one (rebinding between check and use).
///
/// Classification is always done on the parsed or resolved address
/// (`classifyHostAddress` from watchme_core), never on the caller's text, so
/// shorthand forms such as `127.1` are judged by what the OS makes of them.
final class DestinationResolver {
  /// Creates a resolver enforcing [policy], resolving names with [lookup]
  /// (default `InternetAddress.lookup`).
  DestinationResolver(this.policy, {HostLookup? lookup})
    : lookup = lookup ?? InternetAddress.lookup;

  /// The destinations allowed.
  final DestinationPolicy policy;

  /// Resolves host names.
  final HostLookup lookup;

  /// The checked addresses for [host] (brackets allowed, a zone id raw, not
  /// percent-encoded), in the resolver's order.
  ///
  /// Addresses of a class in [exempt] skip the policy (multicast groups,
  /// the limited broadcast address); everything else must be allowed by
  /// [policy]. Throws [WatchmeError]: [WatchmeErrorCode.destinationRefused]
  /// when an address is refused, [WatchmeErrorCode.unreachable] when the
  /// name does not resolve. Nothing is sent before it returns.
  Future<List<InternetAddress>> resolve(
    String host, {
    Set<HostAddressClass> exempt = const {},
  }) async {
    final (:literal, :zone) = splitHost(host);
    final parsed = InternetAddress.tryParse(literal);
    if (parsed != null) {
      final InternetAddress address;
      if (zone == null) {
        address = parsed;
      } else if (parsed.type != InternetAddressType.IPv6) {
        throw WatchmeError.destinationRefused(
          'Refused to contact $host: a zone id needs an IPv6 address',
        );
      } else {
        // dart:io accepts a zone only when the interface exists.
        address =
            InternetAddress.tryParse('$literal%$zone') ??
            (throw WatchmeError.unreachable(
              'Cannot reach $host: no network interface "$zone"',
            ));
      }
      _check(address, null, exempt);
      return [address];
    }
    if (zone != null) {
      throw WatchmeError.destinationRefused(
        'Refused to contact $host: a zone id needs an IPv6 address',
      );
    }
    final List<InternetAddress> found;
    try {
      found = await lookup(literal);
    } on SocketException catch (e) {
      throw WatchmeError.unreachable('Cannot resolve $host', cause: e);
    }
    if (found.isEmpty) {
      throw WatchmeError.unreachable('Cannot resolve $host');
    }
    for (final address in found) {
      _check(address, literal, exempt);
    }
    return found;
  }

  void _check(
    InternetAddress address,
    String? hostName,
    Set<HostAddressClass> exempt,
  ) {
    if (exempt.contains(classifyHostAddress(address.address))) return;
    policy.check(address.address, hostName: hostName);
  }
}

/// [host] without brackets, split at `%` into the address or name and the
/// IPv6 zone id, if any.
({String literal, String? zone}) splitHost(String host) {
  var h = host;
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final percent = h.indexOf('%');
  return percent < 0
      ? (literal: h, zone: null)
      : (literal: h.substring(0, percent), zone: h.substring(percent + 1));
}

/// The host of [uri] as a connection target: `Uri.host` percent-encodes an
/// IPv6 zone id (`fe80::1%25eth0`), which is decoded here.
String uriHost(Uri uri) => Uri.decodeComponent(uri.host);

/// The name to verify a TLS certificate against and send as SNI for
/// [host]: the host name as given, or the bare IP literal (no brackets, no
/// zone). Connecting to a resolved address never changes it.
String tlsServerName(String host) => splitHost(host).literal;
