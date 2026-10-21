import 'package:meta/meta.dart';

import 'transports/transports.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// Finds devices on the network.
///
/// Implementations: SSDP and mDNS in watchme_io, Bonjour in the platform
/// plugin, a subnet probe, manual entry, and fakes in watchme_testkit.
abstract interface class DiscoveryProvider {
  /// Provider id, e.g. [DiscoveryProviderId.ssdp]. Copied into
  /// [DiscoveryHit.provider] and matched by [DiscoveryMatcher.provider].
  String get id;

  /// Transport features the provider needs (e.g. multicast).
  Set<TransportFeature> get requires;

  /// Scans for [window] and yields hits as they arrive, then closes.
  ///
  /// [serviceTypes] lists the SSDP search targets or mDNS service types
  /// wanted, taken from the drivers' matchers; empty means the provider's
  /// default (e.g. `ssdp:all`). Providers enrich hits as far as they
  /// passively can, e.g. SSDP fetches the `LOCATION` device description so
  /// matchers can test `manufacturer` and `modelName`. Hits may repeat; the
  /// engine de-duplicates.
  Stream<DiscoveryHit> scan(
    Duration window, {
    Set<String> serviceTypes = const {},
  });
}

/// Well-known [DiscoveryProvider.id] values.
abstract final class DiscoveryProviderId {
  /// SSDP M-SEARCH / NOTIFY (UPnP, DIAL, Roku ECP).
  static const String ssdp = 'ssdp';

  /// Multicast DNS-SD over raw sockets.
  static const String mdns = 'mdns';

  /// DNS-SD through the OS (iOS NWBrowser, Android NSD).
  static const String bonjour = 'bonjour';

  /// A host the user typed in.
  static const String manual = 'manual';

  /// Unicast probing of known ports across a subnet.
  static const String subnetProbe = 'subnet-probe';
}

/// Attribute keys that providers write into [DiscoveryHit.attributes] and
/// matchers read. mDNS TXT record keys are stored verbatim alongside these.
abstract final class DiscoveryAttr {
  /// SSDP `LOCATION` header (device description URL).
  static const String location = 'location';

  /// SSDP `USN` header.
  static const String usn = 'usn';

  /// SSDP `ST` header (search responses).
  static const String st = 'st';

  /// SSDP `NT` header (NOTIFY).
  static const String nt = 'nt';

  /// SSDP `SERVER` header.
  static const String server = 'server';

  /// UPnP description `friendlyName`.
  static const String friendlyName = 'friendlyName';

  /// UPnP description `manufacturer` (e.g. `Amazon`, `Roku`).
  static const String manufacturer = 'manufacturer';

  /// UPnP description `modelName` (e.g. `AFTKA`).
  static const String modelName = 'modelName';

  /// UPnP description `modelNumber`.
  static const String modelNumber = 'modelNumber';

  /// UPnP description `serialNumber`.
  static const String serialNumber = 'serialNumber';

  /// UPnP description `UDN` (`uuid:...`).
  static const String udn = 'UDN';

  /// UPnP description `deviceType`.
  static const String deviceType = 'deviceType';

  /// DIAL `Application-URL` response header from the description fetch.
  static const String applicationUrl = 'application-url';

  /// mDNS service instance name.
  static const String mdnsInstance = 'mdns.instance';

  /// mDNS SRV target host name.
  static const String mdnsTarget = 'mdns.target';

  /// mDNS service type of the hit, normalised (e.g. `_amzn-firetv._tcp`).
  /// It duplicates [DiscoveryHit.serviceType] so that probes, which see
  /// only the endpoint's attributes, can tell which service was found.
  static const String mdnsService = 'mdns.service';
}

/// One sighting of a device by a [DiscoveryProvider].
@immutable
final class DiscoveryHit {
  /// Creates a hit.
  const DiscoveryHit({
    required this.host,
    required this.provider,
    this.port,
    this.serviceType,
    this.name,
    this.attributes = const {},
    this.mac,
    this.stableId,
  });

  /// Decodes the form written by [toJson].
  factory DiscoveryHit.fromJson(JsonMap json) => DiscoveryHit(
    host: req<String>(json, 'host'),
    provider: req<String>(json, 'provider'),
    port: optInt(json, 'port'),
    serviceType: opt<String>(json, 'serviceType'),
    name: opt<String>(json, 'name'),
    attributes: strMap(json, 'attributes'),
    mac: opt<String>(json, 'mac'),
    stableId: opt<String>(json, 'stableId'),
  );

  /// IP address (an IP literal; never a host name).
  final String host;

  /// The provider that saw it.
  final String provider;

  /// The service port: SSDP takes it from `LOCATION`, mDNS from SRV.
  final int? port;

  /// SSDP ST/NT or mDNS service type (e.g. `roku:ecp`,
  /// `_amzn-wplay._tcp`).
  final String? serviceType;

  /// A display name, if the provider learned one.
  final String? name;

  /// Provider attributes: see [DiscoveryAttr] and mDNS TXT keys.
  final Map<String, String> attributes;

  /// MAC address, normalised (see `normalizeMac`), if known.
  final String? mac;

  /// A stable identity: USN uuid, serial number, TV uuid.
  final String? stableId;

  /// JSON form.
  JsonMap toJson() => {
    'host': host,
    'provider': provider,
    if (port != null) 'port': port,
    if (serviceType != null) 'serviceType': serviceType,
    if (name != null) 'name': name,
    if (attributes.isNotEmpty) 'attributes': attributes,
    if (mac != null) 'mac': mac,
    if (stableId != null) 'stableId': stableId,
  };

  @override
  bool operator ==(Object other) =>
      other is DiscoveryHit &&
      other.host == host &&
      other.provider == provider &&
      other.port == port &&
      other.serviceType == serviceType &&
      other.name == name &&
      mapEquals(other.attributes, attributes) &&
      other.mac == mac &&
      other.stableId == stableId;

  @override
  int get hashCode => Object.hash(
    host,
    provider,
    port,
    serviceType,
    name,
    mapHash(attributes),
    mac,
    stableId,
  );

  @override
  String toString() =>
      'DiscoveryHit($provider $serviceType at $host${port == null ? '' : ':$port'})';
}

/// How an [AttributeMatch] compares.
enum AttributeMatchOp {
  /// The attribute equals the value.
  equals,

  /// The attribute starts with the value.
  prefix,

  /// The attribute matches the value as a regular expression (anywhere in
  /// the string; anchor with `^`/`$` as needed).
  regex,

  /// The attribute is present, whatever its value.
  present,
}

/// One constraint on a [DiscoveryHit.attributes] entry.
@immutable
final class AttributeMatch {
  /// Creates a constraint.
  const AttributeMatch(
    this.key,
    this.op, {
    this.value = '',
    this.caseSensitive = false,
  });

  /// `attributes[key] == value`.
  const AttributeMatch.equals(
    this.key,
    this.value, {
    this.caseSensitive = false,
  }) : op = AttributeMatchOp.equals;

  /// `attributes[key]` starts with [value].
  const AttributeMatch.prefix(
    this.key,
    this.value, {
    this.caseSensitive = false,
  }) : op = AttributeMatchOp.prefix;

  /// `attributes[key]` matches the regular expression [value].
  const AttributeMatch.regex(this.key, this.value, {this.caseSensitive = true})
    : op = AttributeMatchOp.regex;

  /// `attributes` contains [key].
  const AttributeMatch.present(this.key)
    : op = AttributeMatchOp.present,
      value = '',
      caseSensitive = false;

  /// Decodes the form written by [toJson].
  factory AttributeMatch.fromJson(JsonMap json) => AttributeMatch(
    req<String>(json, 'key'),
    reqEnum(json, 'op', AttributeMatchOp.values),
    value: opt<String>(json, 'value') ?? '',
    caseSensitive: opt<bool>(json, 'caseSensitive') ?? false,
  );

  /// Attribute key.
  final String key;

  /// Comparison.
  final AttributeMatchOp op;

  /// Expected value, prefix or pattern.
  final String value;

  /// Compare case-sensitively.
  final bool caseSensitive;

  /// Whether [attributes] satisfies this constraint.
  bool matches(Map<String, String> attributes) {
    final actual = attributes[key];
    if (actual == null) return false;
    String fold(String s) => caseSensitive ? s : s.toLowerCase();
    return switch (op) {
      AttributeMatchOp.present => true,
      AttributeMatchOp.equals => fold(actual) == fold(value),
      AttributeMatchOp.prefix => fold(actual).startsWith(fold(value)),
      AttributeMatchOp.regex => RegExp(
        value,
        caseSensitive: caseSensitive,
      ).hasMatch(actual),
    };
  }

  /// JSON form.
  JsonMap toJson() => {
    'key': key,
    'op': op.name,
    if (op != AttributeMatchOp.present) 'value': value,
    if (caseSensitive) 'caseSensitive': true,
  };

  @override
  bool operator ==(Object other) =>
      other is AttributeMatch &&
      other.key == key &&
      other.op == op &&
      other.value == value &&
      other.caseSensitive == caseSensitive;

  @override
  int get hashCode => Object.hash(key, op, value, caseSensitive);

  @override
  String toString() => 'AttributeMatch($key ${op.name} $value)';
}

/// Declares which discovery hits a driver recognises.
///
/// All given conditions must hold. Examples:
///
/// ```dart
/// // Roku
/// DiscoveryMatcher(provider: DiscoveryProviderId.ssdp,
///     serviceType: 'roku:ecp', portName: 'ecp');
/// // Fire TV via DIAL
/// DiscoveryMatcher(provider: DiscoveryProviderId.ssdp,
///     serviceType: 'urn:dial-multiscreen-org:service:dial:1',
///     attributes: [AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Amazon'),
///                  AttributeMatch.prefix(DiscoveryAttr.modelName, 'AFT')]);
/// // Fire TV via mDNS or Bonjour
/// DiscoveryMatcher(serviceType: '_amzn-wplay._tcp');
/// ```
@immutable
final class DiscoveryMatcher {
  /// Creates a matcher.
  const DiscoveryMatcher({
    this.provider,
    this.serviceType,
    this.attributes = const [],
    this.portName,
  });

  /// Decodes the form written by [toJson].
  factory DiscoveryMatcher.fromJson(JsonMap json) => DiscoveryMatcher(
    provider: opt<String>(json, 'provider'),
    serviceType: opt<String>(json, 'serviceType'),
    attributes: objList(json, 'attributes', AttributeMatch.fromJson),
    portName: opt<String>(json, 'portName'),
  );

  /// Required [DiscoveryHit.provider]; `null` accepts any provider (useful
  /// for mDNS types seen by both `mdns` and `bonjour`).
  final String? provider;

  /// Required SSDP ST/NT or mDNS service type, compared after
  /// [normalizeServiceType]; `null` accepts any.
  final String? serviceType;

  /// Attribute constraints, all of which must hold.
  final List<AttributeMatch> attributes;

  /// The `Endpoint` port name that [DiscoveryHit.port] fills when this
  /// matcher matches (e.g. `ecp` for Roku). `null` ignores the hit's port.
  final String? portName;

  /// Whether [hit] satisfies every condition.
  bool matches(DiscoveryHit hit) {
    if (provider != null && provider != hit.provider) return false;
    if (serviceType != null) {
      final type = hit.serviceType;
      if (type == null) return false;
      if (normalizeServiceType(type) != normalizeServiceType(serviceType!)) {
        return false;
      }
    }
    return attributes.every((a) => a.matches(hit.attributes));
  }

  /// JSON form.
  JsonMap toJson() => {
    if (provider != null) 'provider': provider,
    if (serviceType != null) 'serviceType': serviceType,
    if (attributes.isNotEmpty)
      'attributes': [for (final a in attributes) a.toJson()],
    if (portName != null) 'portName': portName,
  };

  @override
  bool operator ==(Object other) =>
      other is DiscoveryMatcher &&
      other.provider == provider &&
      other.serviceType == serviceType &&
      listEquals(other.attributes, attributes) &&
      other.portName == portName;

  @override
  int get hashCode =>
      Object.hash(provider, serviceType, listHash(attributes), portName);

  @override
  String toString() => 'DiscoveryMatcher($provider, $serviceType, $attributes)';
}

/// Normalises an SSDP search target or mDNS service type for comparison:
/// lower-case, without a trailing `.` or `.local`.
///
/// `_googlecast._tcp.local.` becomes `_googlecast._tcp`.
String normalizeServiceType(String type) {
  var t = type.trim().toLowerCase();
  if (t.endsWith('.')) t = t.substring(0, t.length - 1);
  if (t.endsWith('.local')) t = t.substring(0, t.length - '.local'.length);
  return t;
}
