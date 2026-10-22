import 'package:watchme_core/watchme_core.dart';
import 'package:xml/xml.dart';

/// The root device of a UPnP device description (the XML at an SSDP
/// `LOCATION`).
final class UpnpDescription {
  const UpnpDescription._(this.fields);

  /// The description fields copied into discovery attributes.
  static const List<String> fieldNames = [
    DiscoveryAttr.friendlyName,
    DiscoveryAttr.manufacturer,
    DiscoveryAttr.modelName,
    DiscoveryAttr.modelNumber,
    DiscoveryAttr.serialNumber,
    DiscoveryAttr.udn,
    DiscoveryAttr.deviceType,
  ];

  /// Parses [xml], or returns `null` when it is not a device description.
  ///
  /// Element names are matched by local name, so default and prefixed
  /// namespaces both work. The parser does not fetch external entities.
  static UpnpDescription? tryParse(String xml) {
    final XmlDocument document;
    try {
      document = XmlDocument.parse(xml);
    } on XmlException {
      return null;
    }
    final root = document.rootElement;
    final device =
        root.childElements.where((e) => e.localName == 'device').firstOrNull ??
        root.descendantElements
            .where((e) => e.localName == 'device')
            .firstOrNull;
    if (device == null) return null;
    final fields = <String, String>{};
    for (final child in device.childElements) {
      if (!fieldNames.contains(child.localName)) continue;
      final value = child.innerText.trim();
      if (value.isNotEmpty) fields.putIfAbsent(child.localName, () => value);
    }
    return UpnpDescription._(fields);
  }

  /// Non-empty fields by [DiscoveryAttr] key.
  final Map<String, String> fields;

  /// `friendlyName`.
  String? get friendlyName => fields[DiscoveryAttr.friendlyName];

  /// `manufacturer`.
  String? get manufacturer => fields[DiscoveryAttr.manufacturer];

  /// `modelName`.
  String? get modelName => fields[DiscoveryAttr.modelName];

  /// `UDN` (`uuid:...`).
  String? get udn => fields[DiscoveryAttr.udn];

  /// `serialNumber`.
  String? get serialNumber => fields[DiscoveryAttr.serialNumber];
}
