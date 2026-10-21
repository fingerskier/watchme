import 'package:meta/meta.dart';

import '../errors.dart';

/// What kind of destination an IP address is, for watchme's rule that it
/// talks only to devices on the local network.
///
/// See [classifyHostAddress] and [DestinationPolicy].
enum HostAddressClass {
  /// RFC 1918 private IPv4 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16) or
  /// IPv6 unique-local (fc00::/7).
  privateLan,

  /// IPv4 link-local (169.254.0.0/16) or IPv6 link-local (fe80::/10).
  linkLocal,

  /// This host: 127.0.0.0/8 or ::1.
  loopback,

  /// RFC 6598 shared address space, 100.64.0.0/10: carrier-grade NAT and
  /// overlay VPNs such as Tailscale. It reaches beyond the LAN.
  cgnat,

  /// A globally routable unicast address, including IPv6 transition
  /// prefixes that lead off the LAN (NAT64 64:ff9b::/96, 6to4, Teredo).
  public,

  /// A special-purpose block that is neither the LAN nor the public
  /// internet: 192.0.0.0/24, documentation (192.0.2.0/24, 198.51.100.0/24,
  /// 203.0.113.0/24, 2001:db8::/32, 3fff::/20), benchmarking
  /// (198.18.0.0/15, 2001:2::/48), 240.0.0.0/4, discard-only 100::/64,
  /// deprecated site-local fec0::/10, and the rest of ::/8 (for example
  /// IPv4-compatible ::a.b.c.d and local-use NAT64 64:ff9b:1::/48).
  reserved,

  /// Multicast: 224.0.0.0/4 or ff00::/8.
  multicast,

  /// 0.0.0.0/8 ("this network") or ::. Connecting to 0.0.0.0 reaches this
  /// host's own services on Linux and macOS.
  unspecified,

  /// The IPv4 limited broadcast address 255.255.255.255. (A subnet-directed
  /// broadcast such as 192.168.1.255 cannot be told apart without the
  /// netmask, so it classifies by its range.)
  broadcast,

  /// Not an IP literal: a host name, malformed text, or a numeric form
  /// this parser does not accept (see [classifyHostAddress]).
  invalid,
}

/// Classifies the IP literal [address] without resolving anything. Pure
/// Dart: it works on the web, where `dart:io` is not available.
///
/// Accepted forms, and nothing else:
///
/// * IPv4 as four dotted decimal parts, each 0..255 with no leading zero
///   (`192.168.1.7`).
/// * IPv6 in any RFC 4291 text form, hex digits in either case, with at
///   most one `::` and optionally a dotted IPv4 tail (`::ffff:10.0.0.2`).
///   An optional zone id after `%` (`fe80::1%eth0`, or `fe80::1%25eth0` as
///   `Uri.host` returns it) is ignored for classification. No brackets.
///
/// IPv4-mapped IPv6 (`::ffff:a.b.c.d`, in either notation) classifies as
/// its IPv4 address, so `::ffff:127.0.0.1` is [HostAddressClass.loopback].
///
/// A host name is [HostAddressClass.invalid]: resolve it first and classify
/// every address it resolves to. So are the shorthand and non-decimal
/// numeric forms some resolvers accept (`127.1`, `0x7f.0.0.1`,
/// `2130706433`, `010.0.0.1`): they are never guessed at here. A native
/// stack that hands such a string to the OS resolver must classify the
/// addresses the resolver returns, not the string.
HostAddressClass classifyHostAddress(String address) {
  final v4 = _parseIPv4(address);
  if (v4 != null) return _classifyIPv4(v4);
  final v6 = _parseIPv6(address);
  if (v6 != null) return _classifyIPv6(v6);
  return HostAddressClass.invalid;
}

/// Whether a unicast connection to the IP literal [address] is allowed.
///
/// Shorthand for `DestinationPolicy(allowLoopback: ..., allowNonPrivate:
/// ...).allows(address)`; see [DestinationPolicy.allows].
bool isAllowedDestination(
  String address, {
  bool allowLoopback = false,
  bool allowNonPrivate = false,
}) => DestinationPolicy(
  allowLoopback: allowLoopback,
  allowNonPrivate: allowNonPrivate,
).allows(address);

/// Which addresses watchme may open a unicast connection to.
///
/// The default policy is LAN-only: private (RFC 1918), link-local (IPv4 and
/// IPv6) and unique-local IPv6 addresses, including their IPv4-mapped IPv6
/// forms. Everything else is refused: public, shared 100.64.0.0/10,
/// reserved, unspecified, multicast and broadcast addresses, and loopback
/// unless [allowLoopback] is set. A refusal is a [WatchmeError] with
/// [WatchmeErrorCode.destinationRefused].
///
/// Enforcement:
///
/// * The native network stack applies it to every unicast connection: HTTP,
///   WebSocket, TCP, TLS and unicast UDP. It resolves a host name itself,
///   checks every address the name resolves to, and connects to the checked
///   IP literal, so a DNS answer cannot change between check and use
///   (rebinding).
/// * Discovery (mDNS, SSDP) uses the same policy for the senders it hears
///   and the addresses they name: a hit from or naming a refused address is
///   dropped before it is processed, and a reply naming its own sender
///   gets no exception.
/// * Multicast discovery queries and Wake-on-LAN broadcasts sent on LAN
///   interfaces are not unicast connections; this policy does not govern
///   them.
/// * The engine checks a manually added IP literal with the same policy up
///   front, to give a clear error before any driver runs.
@immutable
final class DestinationPolicy {
  /// Creates a policy. The default is LAN-only, without loopback.
  const DestinationPolicy({
    this.allowLoopback = false,
    this.allowNonPrivate = false,
  });

  /// The default LAN-only policy.
  static const DestinationPolicy lanOnly = DestinationPolicy();

  /// Whether loopback addresses (127.0.0.0/8, ::1 and ::ffff:127.0.0.0/104)
  /// are allowed.
  ///
  /// The in-process Flutter app enables it: its simulators listen on
  /// 127.0.0.1, and an app in the user's own process is in the user's
  /// trust domain. A hub (M1) must not enable it, because a spoofed
  /// discovery reply or a manual entry could then make the hub reach its
  /// own local services on behalf of a LAN client. Tests that use loopback
  /// opt in explicitly.
  final bool allowLoopback;

  /// Escape hatch: also allow public, shared (100.64.0.0/10) and reserved
  /// unicast addresses, e.g. for a TV reached over a routed or VPN network.
  /// Off by default. It never allows loopback (that is [allowLoopback]) or
  /// unspecified, multicast, broadcast and invalid addresses.
  final bool allowNonPrivate;

  /// Whether an address of class [kind] is allowed.
  bool allowsClass(HostAddressClass kind) => switch (kind) {
    HostAddressClass.privateLan || HostAddressClass.linkLocal => true,
    HostAddressClass.loopback => allowLoopback,
    HostAddressClass.cgnat ||
    HostAddressClass.public ||
    HostAddressClass.reserved => allowNonPrivate,
    HostAddressClass.multicast ||
    HostAddressClass.unspecified ||
    HostAddressClass.broadcast ||
    HostAddressClass.invalid => false,
  };

  /// Whether a unicast connection to the IP literal [address] is allowed.
  ///
  /// [address] must be an IP literal ([classifyHostAddress]); a host name
  /// is refused. Resolve names first and check every resulting address.
  bool allows(String address) => allowsClass(classifyHostAddress(address));

  /// `null` when [address] is allowed, else the
  /// [WatchmeErrorCode.destinationRefused] error to report.
  ///
  /// [hostName] is the name [address] was resolved from, if any, for the
  /// message.
  WatchmeError? refusal(String address, {String? hostName}) {
    final kind = classifyHostAddress(address);
    if (allowsClass(kind)) return null;
    final target = hostName == null || hostName == address
        ? address
        : '$hostName ($address)';
    return WatchmeError.destinationRefused(
      'Refused to contact $target: ${_describe(kind)}. watchme only '
      'contacts devices on the local network (private, link-local or '
      'unique-local addresses).',
    );
  }

  /// Throws the [refusal] for [address], if there is one.
  void check(String address, {String? hostName}) {
    final error = refusal(address, hostName: hostName);
    if (error != null) throw error;
  }

  static String _describe(HostAddressClass kind) => switch (kind) {
    HostAddressClass.privateLan => 'a private address',
    HostAddressClass.linkLocal => 'a link-local address',
    HostAddressClass.loopback => 'it is this computer (loopback)',
    HostAddressClass.cgnat =>
      'it is in the shared 100.64.0.0/10 range used by carrier-grade NAT '
          'and VPN overlays, not the local network',
    HostAddressClass.public => 'it is a public internet address',
    HostAddressClass.reserved => 'it is a reserved or documentation address',
    HostAddressClass.multicast => 'it is a multicast address',
    HostAddressClass.unspecified => 'it is an unspecified address',
    HostAddressClass.broadcast => 'it is a broadcast address',
    HostAddressClass.invalid => 'it is not an IP address',
  };

  @override
  bool operator ==(Object other) =>
      other is DestinationPolicy &&
      other.allowLoopback == allowLoopback &&
      other.allowNonPrivate == allowNonPrivate;

  @override
  int get hashCode => Object.hash(allowLoopback, allowNonPrivate);

  @override
  String toString() =>
      'DestinationPolicy(allowLoopback: $allowLoopback, '
      'allowNonPrivate: $allowNonPrivate)';
}

final RegExp _decimal = RegExp(r'^[0-9]{1,3}$');
final RegExp _hexGroup = RegExp(r'^[0-9A-Fa-f]{1,4}$');
final RegExp _zoneId = RegExp(r'^[A-Za-z0-9._~-]+$');

/// Four bytes, or `null` unless [text] is a strict dotted-quad.
List<int>? _parseIPv4(String text) {
  final parts = text.split('.');
  if (parts.length != 4) return null;
  final bytes = <int>[];
  for (final part in parts) {
    if (!_decimal.hasMatch(part)) return null;
    if (part.length > 1 && part.startsWith('0')) return null;
    final value = int.parse(part);
    if (value > 255) return null;
    bytes.add(value);
  }
  return bytes;
}

/// Sixteen bytes, or `null` unless [text] is an IPv6 literal (optionally
/// with a zone id).
List<int>? _parseIPv6(String text) {
  var address = text;
  final percent = address.indexOf('%');
  if (percent >= 0) {
    if (!_zoneId.hasMatch(address.substring(percent + 1))) return null;
    address = address.substring(0, percent);
  }
  if (!address.contains(':')) return null;

  // A second `::` leaves an empty group after the split, which the hex
  // check below rejects.
  final gap = address.indexOf('::');
  final List<String> head;
  final List<String> tail;
  if (gap >= 0) {
    final before = address.substring(0, gap);
    final after = address.substring(gap + 2);
    head = before.isEmpty ? const [] : before.split(':');
    tail = after.isEmpty ? const [] : after.split(':');
  } else {
    head = address.split(':');
    tail = const [];
  }

  // Only the very last group may be a dotted IPv4 tail.
  final headWords = _words(head, ipv4Tail: gap < 0);
  final tailWords = _words(tail, ipv4Tail: true);
  if (headWords == null || tailWords == null) return null;
  final explicit = headWords.length + tailWords.length;
  if (gap < 0 ? explicit != 8 : explicit > 7) return null;

  final words = [
    ...headWords,
    for (var i = explicit; i < 8; i++) 0,
    ...tailWords,
  ];
  return [
    for (final word in words) ...[word >> 8, word & 0xff],
  ];
}

/// The 16-bit words of [groups]; a dotted IPv4 last group counts as two
/// when [ipv4Tail] allows it.
List<int>? _words(List<String> groups, {required bool ipv4Tail}) {
  final words = <int>[];
  for (var i = 0; i < groups.length; i++) {
    final group = groups[i];
    if (ipv4Tail && i == groups.length - 1 && group.contains('.')) {
      final v4 = _parseIPv4(group);
      if (v4 == null) return null;
      words
        ..add((v4[0] << 8) | v4[1])
        ..add((v4[2] << 8) | v4[3]);
    } else {
      if (!_hexGroup.hasMatch(group)) return null;
      words.add(int.parse(group, radix: 16));
    }
  }
  return words;
}

HostAddressClass _classifyIPv4(List<int> b) {
  final [a, b1, b2, b3] = b;
  if (a == 0) return HostAddressClass.unspecified;
  if (a == 10) return HostAddressClass.privateLan;
  if (a == 100 && b1 >= 64 && b1 <= 127) return HostAddressClass.cgnat;
  if (a == 127) return HostAddressClass.loopback;
  if (a == 169 && b1 == 254) return HostAddressClass.linkLocal;
  if (a == 172 && b1 >= 16 && b1 <= 31) return HostAddressClass.privateLan;
  if (a == 192 && b1 == 168) return HostAddressClass.privateLan;
  if (a == 192 && b1 == 0 && (b2 == 0 || b2 == 2)) {
    return HostAddressClass.reserved;
  }
  if (a == 198 && (b1 == 18 || b1 == 19)) return HostAddressClass.reserved;
  if (a == 198 && b1 == 51 && b2 == 100) return HostAddressClass.reserved;
  if (a == 203 && b1 == 0 && b2 == 113) return HostAddressClass.reserved;
  if (a >= 224 && a <= 239) return HostAddressClass.multicast;
  if (a == 255 && b1 == 255 && b2 == 255 && b3 == 255) {
    return HostAddressClass.broadcast;
  }
  if (a >= 240) return HostAddressClass.reserved;
  return HostAddressClass.public;
}

HostAddressClass _classifyIPv6(List<int> b) {
  bool zero(int from, int to) {
    for (var i = from; i < to; i++) {
      if (b[i] != 0) return false;
    }
    return true;
  }

  if (zero(0, 16)) return HostAddressClass.unspecified;
  if (zero(0, 15) && b[15] == 1) return HostAddressClass.loopback;
  // ::ffff:a.b.c.d reaches the IPv4 host a.b.c.d.
  if (zero(0, 10) && b[10] == 0xff && b[11] == 0xff) {
    return _classifyIPv4(b.sublist(12));
  }
  // 64:ff9b::/96, the well-known NAT64 prefix, leads to the IPv4 internet.
  if (b[0] == 0x00 &&
      b[1] == 0x64 &&
      b[2] == 0xff &&
      b[3] == 0x9b &&
      zero(4, 12)) {
    return HostAddressClass.public;
  }
  if (b[0] == 0x00) return HostAddressClass.reserved;
  if (b[0] == 0x01 && zero(1, 8)) return HostAddressClass.reserved;
  if (b[0] == 0x20 && b[1] == 0x01) {
    if (b[2] == 0x0d && b[3] == 0xb8) return HostAddressClass.reserved;
    if (b[2] == 0x00 && b[3] == 0x02 && b[4] == 0 && b[5] == 0) {
      return HostAddressClass.reserved;
    }
  }
  if (b[0] == 0x3f && b[1] == 0xff && (b[2] & 0xf0) == 0) {
    return HostAddressClass.reserved;
  }
  if ((b[0] & 0xfe) == 0xfc) return HostAddressClass.privateLan;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return HostAddressClass.linkLocal;
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0xc0) return HostAddressClass.reserved;
  if (b[0] == 0xff) return HostAddressClass.multicast;
  return HostAddressClass.public;
}
