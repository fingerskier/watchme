import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

/// Looks up MAC addresses in the OS neighbour (ARP) table, to learn a TV's
/// MAC for Wake-on-LAN while it is on.
///
/// The table only lists hosts this machine talked to recently, so look up
/// right after a successful request to the device. Linux and Android only
/// (`/proc/net/arp`); other platforms return `null` for now.
final class ArpCache {
  /// Creates a reader of [path]. [supported] defaults to whether the
  /// platform has `/proc/net/arp`.
  ArpCache({this.path = '/proc/net/arp', bool? supported})
    : supported = supported ?? (Platform.isLinux || Platform.isAndroid);

  /// The ARP table file.
  final String path;

  /// Whether lookups are attempted.
  final bool supported;

  /// The normalised MAC for [ip], or `null` when unknown or unsupported.
  Future<String?> macFor(String ip) async => (await entries())[ip];

  /// Every complete entry, IP to normalised MAC.
  Future<Map<String, String>> entries() async {
    if (!supported) return const {};
    try {
      return parseProcNetArp(await File(path).readAsString());
    } on FileSystemException {
      return const {};
    }
  }

  /// Parses `/proc/net/arp`, keeping complete entries (flag 0x2) with a
  /// non-zero hardware address.
  static Map<String, String> parseProcNetArp(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n').skip(1)) {
      final f = line.trim().split(RegExp(r'\s+'));
      if (f.length < 4) continue;
      final flags = int.tryParse(f[2].replaceFirst('0x', ''), radix: 16) ?? 0;
      const complete = 0x2;
      if (flags & complete == 0) continue;
      final mac = tryNormalizeMac(f[3]);
      if (mac == null || mac == '00:00:00:00:00:00') continue;
      out[f[0]] = mac;
    }
    return out;
  }
}
