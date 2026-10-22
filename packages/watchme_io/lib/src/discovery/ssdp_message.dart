import 'dart:convert';

import 'package:watchme_core/watchme_core.dart';

/// The SSDP multicast group (IPv4).
const String ssdpGroup = '239.255.255.250';

/// The SSDP port.
const int ssdpPort = 1900;

/// Kinds of [SsdpMessage].
enum SsdpMessageKind {
  /// `HTTP/1.1 200 OK`: a unicast reply to an M-SEARCH.
  searchResponse,

  /// `NOTIFY * HTTP/1.1`: an `ssdp:alive`, `ssdp:byebye` or `ssdp:update`
  /// announcement.
  notify,

  /// `M-SEARCH * HTTP/1.1`: another control point searching.
  search,
}

/// A parsed SSDP datagram.
///
/// Parsing is lenient about what devices get wrong (bare `\n` line endings,
/// odd header case, stray whitespace, missing values) and returns `null`
/// only for datagrams that are not SSDP at all.
final class SsdpMessage {
  const SsdpMessage._(this.kind, this.headers);

  /// Parses [text], or returns `null` when it is not an SSDP message.
  static SsdpMessage? tryParse(String text) {
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return null;
    final start = lines.first.trim().toUpperCase();
    final SsdpMessageKind kind;
    if (start.startsWith('HTTP/1.') &&
        start.split(RegExp(r'\s+')).elementAtOrNull(1) == '200') {
      kind = SsdpMessageKind.searchResponse;
    } else if (start.startsWith('NOTIFY ')) {
      kind = SsdpMessageKind.notify;
    } else if (start.startsWith('M-SEARCH ')) {
      kind = SsdpMessageKind.search;
    } else {
      return null;
    }
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) break;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final name = line.substring(0, colon).trim().toLowerCase();
      if (name.isEmpty || name.contains(' ')) continue;
      headers.putIfAbsent(name, () => line.substring(colon + 1).trim());
    }
    return SsdpMessage._(kind, headers);
  }

  /// Parses UTF-8 [bytes]; see [tryParse].
  static SsdpMessage? tryParseBytes(List<int> bytes) =>
      tryParse(utf8.decode(bytes, allowMalformed: true));

  /// What kind of message this is.
  final SsdpMessageKind kind;

  /// Headers by lower-case name. A repeated header keeps its first value.
  final Map<String, String> headers;

  /// The header [name], matched case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// `LOCATION`: the device description URL.
  String? get location => _nonEmpty(DiscoveryAttr.location);

  /// `USN`: unique service name, e.g. `uuid:roku:ecp:P0A070000007` or
  /// `uuid:<udn>::urn:dial-multiscreen-org:service:dial:1`.
  String? get usn => _nonEmpty(DiscoveryAttr.usn);

  /// The search target (`ST`) of a response, or the notification type
  /// (`NT`) of a NOTIFY.
  String? get serviceType =>
      _nonEmpty(DiscoveryAttr.st) ?? _nonEmpty(DiscoveryAttr.nt);

  /// `NTS` of a NOTIFY: `ssdp:alive`, `ssdp:byebye` or `ssdp:update`.
  String? get nts => _nonEmpty('nts');

  /// Whether this NOTIFY says the device is leaving.
  bool get isByeBye => nts?.toLowerCase() == 'ssdp:byebye';

  /// [location] as an `http`/`https` URI with a host, else `null`.
  Uri? get locationUri {
    final raw = location;
    if (raw == null) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
  }

  /// The `uuid:...` part of [usn] (before `::`), a stable device identity.
  String? get uuid {
    final value = usn;
    if (value == null || !value.toLowerCase().startsWith('uuid:')) return null;
    final end = value.indexOf('::');
    final id = end < 0 ? value : value.substring(0, end);
    return id.length > 'uuid:'.length ? id : null;
  }

  /// The MAC from a DIAL 2.x `WAKEUP: MAC=<mac>;Timeout=<s>` header,
  /// normalised, or `null`.
  String? get wakeupMac {
    final value = header('wakeup');
    if (value == null) return null;
    for (final part in value.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0 && part.substring(0, eq).trim().toUpperCase() == 'MAC') {
        return tryNormalizeMac(part.substring(eq + 1));
      }
    }
    return null;
  }

  String? _nonEmpty(String name) {
    final value = headers[name];
    return value == null || value.isEmpty ? null : value;
  }

  @override
  String toString() => 'SsdpMessage(${kind.name}, $serviceType, $usn)';
}

/// Builds an SSDP `M-SEARCH` for [searchTarget] (e.g. `roku:ecp`,
/// `ssdp:all`), asking devices to answer within [mx] seconds.
List<int> buildMSearch(
  String searchTarget, {
  int mx = 2,
  String host = '$ssdpGroup:$ssdpPort',
}) => utf8.encode(
  'M-SEARCH * HTTP/1.1\r\n'
  'HOST: $host\r\n'
  'MAN: "ssdp:discover"\r\n'
  'MX: $mx\r\n'
  'ST: $searchTarget\r\n'
  '\r\n',
);
