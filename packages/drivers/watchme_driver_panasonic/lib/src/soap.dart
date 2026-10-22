import 'package:watchme_core/watchme_core.dart';
import 'package:xml/xml.dart';

import 'constants.dart';

// SOAP request shapes and answer parsing for the VIERA UPnP server, written
// from the watchme research brief (sections 3 and 6), whose byte layouts
// were checked against captured Content-Length values. No code was copied.

const String _envelopeOpen =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>';

const String _envelopeClose = '</s:Body></s:Envelope>';

/// A SOAP request body for [action] of the service [urn] with the already
/// escaped argument elements [args], on one line, with the `u:` prefix.
String soapEnvelope(String urn, String action, String args) =>
    '$_envelopeOpen<u:$action xmlns:u="$urn">$args</u:$action>'
    '$_envelopeClose';

/// The request headers the official app and the field-proven clients send,
/// besides `Host` and `Content-Length`, which the network stack adds. The
/// `SOAPACTION` value is always double-quoted.
Map<String, String> soapHeaders(String urn, String action) => {
  'Accept': 'text/xml',
  'Cache-Control': 'no-cache',
  'Pragma': 'no-cache',
  'SOAPACTION': '"$urn#$action"',
  'Content-Type': 'text/xml; charset="utf-8"',
};

/// The plaintext of an `X_EncryptedCommand`: the session id, the sequence
/// number as eight digits, and the original NRC request.
String encryptedCommandPlaintext(
  String sessionId,
  int sequence,
  String action,
  String args,
) =>
    '<X_SessionId>${xmlEscape(sessionId)}</X_SessionId>'
    '<X_SequenceNumber>${sequence.toString().padLeft(8, '0')}'
    '</X_SequenceNumber>'
    '<X_OriginalCommand><u:$action xmlns:u="${VieraUrn.nrc}">$args'
    '</u:$action></X_OriginalCommand>';

/// [text] escaped for XML element content and attribute values.
String xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// The text of the first element whose local name is [localName], at any
/// depth and with any (or no) namespace prefix, with entities decoded;
/// `null` when there is none.
///
/// [xml] may be a whole document or a fragment with several roots (the
/// decrypted answer of an encrypted command): it is wrapped in a root
/// element first. A fragment the XML parser refuses (an undeclared prefix,
/// say) is searched with a lenient pattern instead.
String? xmlLeaf(String xml, String localName) {
  final body = xml.replaceFirst(RegExp(r'^\s*<\?xml[^>]*\?>'), '');
  try {
    final doc = XmlDocument.parse('<X_Data>$body</X_Data>');
    for (final e in doc.rootElement.descendantElements) {
      if (e.name.local == localName) return e.innerText;
    }
    return null;
  } on XmlException {
    final match = RegExp(
      '<(?:[A-Za-z_][\\w.-]*:)?$localName(?:\\s[^>]*)?(?:/>|>(.*?)'
      '</(?:[A-Za-z_][\\w.-]*:)?$localName\\s*>)',
      dotAll: true,
    ).firstMatch(body);
    if (match == null) return null;
    return xmlUnescape(match.group(1) ?? '');
  }
}

/// Whether [xml] contains an element whose local name is [localName].
bool xmlHasElement(String xml, String localName) =>
    xmlLeaf(xml, localName) != null;

/// Whether [xml] is an answer to [action]: it holds an `{action}Response`
/// element, at any depth and with any (or no) prefix. That covers the
/// TV's own envelope and the decrypted fragment of an encrypted command,
/// whose wrapper is unknown (bare, under some root, or in
/// `X_OriginalResult`). An HTML page or any other text is no answer.
bool isSoapAnswer(String xml, String action) =>
    xmlHasElement(xml, '${action}Response');

/// [text] with XML character and entity references decoded. A character
/// reference to no Unicode character (`&#x110000;`, or too many digits)
/// becomes U+FFFD: what the TV sends must never make parsing throw.
String xmlUnescape(String text) => text.replaceAllMapped(
  RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);'),
  (m) {
    final ref = m.group(1)!;
    if (ref.startsWith('#')) {
      final code = ref.startsWith('#x')
          ? int.tryParse(ref.substring(2), radix: 16)
          : int.tryParse(ref.substring(1));
      return code == null || code > 0x10ffff ? '�' : String.fromCharCode(code);
    }
    return switch (ref) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      _ => "'",
    };
  },
);

/// A UPnP SOAP fault: `errorCode` and `errorDescription`, read by local
/// name anywhere in the body. Both are `null` for an empty or unparsable
/// body (some TVs send a bare `500` with nothing in it).
typedef SoapFault = ({int? code, String? description});

/// Parses the fault in a `500` answer [body].
SoapFault parseSoapFault(String body) {
  if (body.trim().isEmpty) return (code: null, description: null);
  final code = xmlLeaf(body, 'errorCode')?.trim();
  final description = xmlLeaf(body, 'errorDescription')?.trim();
  return (
    code: code == null ? null : int.tryParse(code),
    description: description == null || description.isEmpty
        ? null
        : description,
  );
}

/// Facts from the NRC device description, `GET /nrc/ddd.xml`.
final class VieraDescription {
  VieraDescription._(this._fields);

  /// Parses a device description.
  ///
  /// Throws [FormatException] when [xml] is not XML. A document of another
  /// kind parses too; check [isRemoteController].
  factory VieraDescription.parse(String xml) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException catch (e) {
      throw FormatException('The device description is not XML: ${e.message}');
    }
    final fields = <String, String>{};
    for (final e in doc.descendantElements) {
      if (e.childElements.isNotEmpty) continue;
      fields.putIfAbsent(e.name.local, () => e.innerText.trim());
    }
    return VieraDescription._(fields);
  }

  final Map<String, String> _fields;

  String? _field(String name) {
    final v = _fields[name];
    return v == null || v.isEmpty ? null : v;
  }

  /// `deviceType`.
  String? get deviceType => _field('deviceType');

  /// Whether this is the NRC root device
  /// (`urn:panasonic-com:device:p00RemoteController:1`).
  bool get isRemoteController =>
      deviceType?.toLowerCase().contains('p00remotecontroller') ?? false;

  /// `friendlyName`: the TV's network name, e.g. `49DX600_Series`.
  String? get friendlyName => _field('friendlyName');

  /// The name to show: [friendlyName] with `_` as spaces, as the vendor's
  /// own integrations show it.
  String? get displayName => friendlyName?.replaceAll('_', ' ');

  /// `manufacturer` (`Panasonic`).
  String? get manufacturer => _field('manufacturer');

  /// `modelName` (`Panasonic VIErA`).
  String? get modelName => _field('modelName');

  /// `modelNumber`: the model (`TX-49DX600EA`), or a series code on older
  /// sets (`ET60`).
  String? get modelNumber => _field('modelNumber');

  /// `UDN`, e.g. `uuid:4D454930-0200-1000-8001-A81374B30314`.
  String? get udn => _field('UDN');

  /// `X_VERSION`, the NRC protocol version (`NRC-3.00`), not a firmware
  /// version.
  String? get nrcVersion => _field('X_VERSION');

  /// `X_NRC_ID`.
  String? get nrcId => _field('X_NRC_ID');

  /// `X_KEY_TYPE`.
  String? get keyType => _field('X_KEY_TYPE');

  /// `X_NRCCAP` as a set, or `null` when the description has none.
  Set<String>? get nrcCapabilities {
    final raw = _field('X_NRCCAP');
    if (raw == null) return null;
    return {
      for (final c in raw.split(','))
        if (c.trim().isNotEmpty) c.trim().toUpperCase(),
    };
  }

  /// `uuid:` plus the UDN, lower-cased.
  String? get stableId {
    final match = RegExp(
      r'([0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12})',
    ).firstMatch(udn ?? '');
    return match == null ? null : 'uuid:${match.group(1)!.toLowerCase()}';
  }

  /// The UDN's last 12 hex digits as a MAC: they match Panasonic AV OUIs,
  /// so they may be the wired MAC. Unconfirmed on hardware, so it is kept
  /// as a candidate, never as `DeviceInfo.mac`.
  String? get udnMacCandidate {
    final match = RegExp(r'-([0-9a-fA-F]{12})$').firstMatch(udn ?? '');
    return match == null ? null : tryNormalizeMac(match.group(1)!);
  }

  /// `X_NRC_ID` as a MAC (it looks like the Wi-Fi module's); a candidate
  /// only, like [udnMacCandidate].
  String? get nrcIdMacCandidate {
    final id = nrcId;
    return id == null ? null : tryNormalizeMac(id);
  }
}

/// Whether a service description (`GET /nrc/sdd_0.xml`) is that of an
/// encrypted TV: every client decides it by the presence of
/// `X_GetEncryptSessionId`.
bool isEncryptedService(String sdd) => sdd.contains('X_GetEncryptSessionId');

/// Parses the `X_AppList` value (entities already decoded): entries
/// separated by `>`, each `vc_app'state'product_id=ID'name'icon'...`.
/// Malformed entries are skipped.
List<AppInfo> parseVieraAppList(String list) {
  final apps = <AppInfo>[];
  for (final entry in list.split('>')) {
    final fields = entry.trim().split("'");
    if (fields.length < 4) continue;
    final keyword = fields[2].trim();
    final eq = keyword.indexOf('=');
    final id = (eq < 0 ? keyword : keyword.substring(eq + 1)).trim();
    if (id.isEmpty) continue;
    final name = fields[3].trim();
    final icon = fields.length > 4 ? Uri.tryParse(fields[4].trim()) : null;
    apps.add(
      AppInfo(
        id: id,
        name: name.isEmpty ? id : name,
        icon: icon != null && icon.hasScheme ? icon : null,
      ),
    );
  }
  return apps;
}

/// Parses an `X_AppInfo` value, `vc_app:1:product_id=ID:Name`; `null` when
/// it is empty (the TV sometimes sends nothing even while an app runs) or
/// has no id.
AppInfo? parseVieraAppInfo(String info) {
  final parts = info.trim().split(':');
  if (parts.length < 3) return null;
  final keyword = parts[2];
  final eq = keyword.indexOf('=');
  final id = (eq < 0 ? keyword : keyword.substring(eq + 1)).trim();
  if (id.isEmpty) return null;
  final name = parts.length > 3 ? parts.sublist(3).join(':').trim() : '';
  return AppInfo(id: id, name: name.isEmpty ? id : name);
}
