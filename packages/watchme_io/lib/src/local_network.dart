import 'dart:io' hide Datagram;

import 'process/io_process_runner.dart';

/// An IPv4 subnet this host is attached to.
final class LocalSubnet {
  /// Creates a subnet of [interfaceName] with network [network] and
  /// [prefixLength] (0-32).
  const LocalSubnet(this.interfaceName, this.network, this.prefixLength);

  /// The interface name (`wlan0`, `en0`).
  final String interfaceName;

  /// The network address, dotted quad.
  final String network;

  /// The prefix length (24 for a /24).
  final int prefixLength;

  int get _mask =>
      prefixLength == 0 ? 0 : (0xffffffff << (32 - prefixLength)) & 0xffffffff;

  /// The directed broadcast address, or `null` for /31 and /32 subnets,
  /// which have none.
  String? get broadcast => prefixLength >= 31
      ? null
      : _quad((_int(network) & _mask) | (~_mask & 0xffffffff));

  /// Whether [ipv4] (dotted quad) lies in this subnet.
  bool contains(String ipv4) {
    final value = _tryInt(ipv4);
    return value != null && (value & _mask) == (_int(network) & _mask);
  }

  @override
  bool operator ==(Object other) =>
      other is LocalSubnet &&
      other.interfaceName == interfaceName &&
      other.network == network &&
      other.prefixLength == prefixLength;

  @override
  int get hashCode => Object.hash(interfaceName, network, prefixLength);

  @override
  String toString() => 'LocalSubnet($interfaceName $network/$prefixLength)';
}

/// The host's IPv4 subnets, for subnet-directed Wake-on-LAN broadcasts.
///
/// `dart:io` does not expose netmasks, so this reads them from the OS:
/// `/proc/net/route` on Linux and Android, `ifconfig` on macOS. Elsewhere
/// (Windows, iOS) it returns an empty list and callers fall back to the
/// limited broadcast 255.255.255.255.
abstract final class LocalNetwork {
  /// The host's directly connected IPv4 subnets, loopback excluded.
  static Future<List<LocalSubnet>> ipv4Subnets() async {
    try {
      if (Platform.isLinux || Platform.isAndroid) {
        return parseProcNetRoute(await File('/proc/net/route').readAsString());
      }
      if (Platform.isMacOS) {
        final result = await const IoProcessRunner().run('/sbin/ifconfig', []);
        return result.exitCode == 0 ? parseIfconfig(result.stdout) : [];
      }
    } on Object {
      // Unreadable on this host; the caller still has the limited broadcast.
    }
    return [];
  }

  /// The directed broadcast addresses of [ipv4Subnets], de-duplicated.
  static Future<List<String>> broadcastAddresses() async =>
      {for (final subnet in await ipv4Subnets()) ?subnet.broadcast}.toList();

  /// Parses Linux `/proc/net/route`: every up, non-gateway route with a
  /// non-zero mask is a directly connected subnet. Addresses in that file
  /// are little-endian hex.
  static List<LocalSubnet> parseProcNetRoute(String text) {
    final out = <LocalSubnet>[];
    for (final line in text.split('\n').skip(1)) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 8) continue;
      final destination = int.tryParse(f[1], radix: 16);
      final gateway = int.tryParse(f[2], radix: 16);
      final flags = int.tryParse(f[3], radix: 16);
      final mask = int.tryParse(f[7], radix: 16);
      if (destination == null || gateway == null || flags == null) continue;
      if (mask == null || mask == 0 || gateway != 0) continue;
      const up = 0x1;
      const viaGateway = 0x2;
      if (flags & up == 0 || flags & viaGateway != 0) continue;
      if (f[0] == 'lo') continue;
      final hostMask = _swap(mask);
      final subnet = LocalSubnet(
        f[0],
        _quad(_swap(destination) & hostMask),
        _prefix(hostMask),
      );
      if (!out.contains(subnet)) out.add(subnet);
    }
    return out;
  }

  /// Parses BSD/macOS `ifconfig` output lines such as
  /// `inet 10.0.0.5 netmask 0xffffff00 broadcast 10.0.0.255`.
  static List<LocalSubnet> parseIfconfig(String text) {
    final out = <LocalSubnet>[];
    String? interface;
    final header = RegExp(r'^([A-Za-z0-9_.\-]+):\s');
    final inet = RegExp(
      r'^\s+inet\s+(\d+\.\d+\.\d+\.\d+)\s+netmask\s+(0x[0-9a-fA-F]+|\d+\.\d+\.\d+\.\d+)',
    );
    for (final line in text.split('\n')) {
      final h = header.firstMatch(line);
      if (h != null) {
        interface = h.group(1);
        continue;
      }
      final m = inet.firstMatch(line);
      if (m == null || interface == null || interface.startsWith('lo')) {
        continue;
      }
      final rawMask = m.group(2)!;
      final mask = rawMask.startsWith('0x')
          ? int.parse(rawMask.substring(2), radix: 16)
          : _int(rawMask);
      if (mask == 0) continue;
      final subnet = LocalSubnet(
        interface,
        _quad(_int(m.group(1)!) & mask),
        _prefix(mask),
      );
      if (!out.contains(subnet)) out.add(subnet);
    }
    return out;
  }
}

int _swap(int v) =>
    ((v & 0xff) << 24) |
    ((v & 0xff00) << 8) |
    ((v >> 8) & 0xff00) |
    ((v >> 24) & 0xff);

int _prefix(int mask) {
  var bits = 0;
  for (
    var m = mask & 0xffffffff;
    m & 0x80000000 != 0;
    m = (m << 1) & 0xffffffff
  ) {
    bits++;
  }
  return bits;
}

int? _tryInt(String quad) {
  final parts = quad.split('.');
  if (parts.length != 4) return null;
  var value = 0;
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    value = (value << 8) | n;
  }
  return value;
}

int _int(String quad) =>
    _tryInt(quad) ?? (throw FormatException('Not an IPv4 address', quad));

String _quad(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff].join('.');
