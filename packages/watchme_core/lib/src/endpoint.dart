import 'package:meta/meta.dart';

import 'discovery.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// Where a device is: a host plus per-protocol port overrides and the
/// discovery attributes that led to it.
///
/// Drivers MUST resolve every port through [port] (or [uri]) with their
/// protocol's default, never hard-code one, so the same driver reaches a
/// real TV on its standard ports and a simulator on random loopback ports:
///
/// ```dart
/// final ep = Endpoint('127.0.0.1', ports: {'ecp': 51234});
/// ep.port('ecp', 8060); // 51234
/// ep.uri('http', 'ecp', 8060, '/query/device-info');
/// ```
///
/// Port names are lower-case protocol-scoped ids chosen by each driver and
/// listed in its `DriverDescriptor.ports` (e.g. Roku `ecp`; Fire TV `dial`
/// and `api`).
@immutable
final class Endpoint {
  /// Creates an endpoint. [host] should be an IP literal: some protocols
  /// (Roku ECP) reject host names in the `Host` header.
  const Endpoint(
    this.host, {
    this.ports = const {},
    this.attributes = const {},
  });

  /// Builds an endpoint from a discovery hit. When [portName] is given and
  /// the hit has a port, that port is recorded under [portName].
  factory Endpoint.fromHit(DiscoveryHit hit, {String? portName}) => Endpoint(
    hit.host,
    ports: {if (portName != null && hit.port != null) portName: hit.port!},
    attributes: hit.attributes,
  );

  /// Decodes the form written by [toJson].
  factory Endpoint.fromJson(JsonMap json) => Endpoint(
    req<String>(json, 'host'),
    ports: intMap(json, 'ports'),
    attributes: strMap(json, 'attributes'),
  );

  /// IP address or, for manual entries, a host name.
  final String host;

  /// Port overrides by protocol port name.
  final Map<String, int> ports;

  /// Discovery attributes (see `DiscoveryAttr`), for probes that can use
  /// them instead of a network round trip.
  final Map<String, String> attributes;

  /// The port named [name], or [defaultPort] when not overridden.
  int port(String name, int defaultPort) => ports[name] ?? defaultPort;

  /// `scheme://host:port` for the port named [portName].
  Uri baseUri(String scheme, String portName, int defaultPort) =>
      Uri(scheme: scheme, host: host, port: port(portName, defaultPort));

  /// A URI on the port named [portName] with [path] and optional [query].
  /// IPv6 literals are bracketed automatically.
  Uri uri(
    String scheme,
    String portName,
    int defaultPort, [
    String path = '/',
    Map<String, String>? query,
  ]) => Uri(
    scheme: scheme,
    host: host,
    port: port(portName, defaultPort),
    path: path,
    queryParameters: query == null || query.isEmpty ? null : query,
  );

  /// Returns a copy with [ports] added (overriding existing names).
  Endpoint withPorts(Map<String, int> ports) =>
      Endpoint(host, ports: {...this.ports, ...ports}, attributes: attributes);

  /// Returns a copy with [attributes] added (overriding existing keys).
  Endpoint withAttributes(Map<String, String> attributes) => Endpoint(
    host,
    ports: ports,
    attributes: {...this.attributes, ...attributes},
  );

  /// Returns a copy at a different [host], keeping ports and attributes
  /// (e.g. after a DHCP change).
  Endpoint withHost(String host) =>
      Endpoint(host, ports: ports, attributes: attributes);

  /// JSON form.
  JsonMap toJson() => {
    'host': host,
    if (ports.isNotEmpty) 'ports': ports,
    if (attributes.isNotEmpty) 'attributes': attributes,
  };

  @override
  bool operator ==(Object other) =>
      other is Endpoint &&
      other.host == host &&
      mapEquals(other.ports, ports) &&
      mapEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(host, mapHash(ports), mapHash(attributes));

  @override
  String toString() =>
      ports.isEmpty ? 'Endpoint($host)' : 'Endpoint($host $ports)';
}
