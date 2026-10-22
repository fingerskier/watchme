// Documents the simulated VIERA serves. Element content follows real
// descriptions quoted in the watchme research brief (a TX-49DX600EA from
// FastyBird's fixtures, a TX-50GX800E's PAC description from a
// homebridge-vieramatic issue); the indentation is the simulator's own, as
// real sets differ. SOAP answers use the byte layout that matched captured
// Content-Length values (301 and 379 bytes).

/// The NRC service type.
const String panasonicSimNrcUrn =
    'urn:panasonic-com:service:p00NetworkControl:1';

/// UPnP RenderingControl.
const String panasonicSimRenderingControlUrn =
    'urn:schemas-upnp-org:service:RenderingControl:1';

/// The Pro AV control service.
const String panasonicSimPacUrn =
    'urn:panasonic-com:service:p00ProAVControlService:1';

/// The `SERVER` header of the TV's UPnP server (verified).
const String panasonicSimServer =
    'Panasonic-VIErA/1, UPnP/1.0, Panasonic MIL DLNA SERVER';

String _escape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// `GET /nrc/ddd.xml`.
String panasonicSimNrcDescription({
  required String friendlyName,
  required String modelNumber,
  required String nrcUdn,
  required String dmrUdn,
  required String dmsUdn,
  required String nrcId,
  required String? nrcCapabilities,
}) =>
    '<?xml version="1.0"?>\n'
    '<root xmlns="urn:schemas-upnp-org:device-1-0" '
    'xmlns:vli="urn:schemas-panasonic-com:vli" '
    'xmlns:viera="urn:schemas-panasonic-com:viera" '
    'xmlns:pxn="urn:schemas-panasonic-com:pxn">\n'
    ' <specVersion><major>1</major><minor>0</minor></specVersion>\n'
    ' <device>\n'
    '  <deviceType>urn:panasonic-com:device:p00RemoteController:1'
    '</deviceType>\n'
    '  <friendlyName>${_escape(friendlyName)}</friendlyName>\n'
    '  <manufacturer>Panasonic</manufacturer>\n'
    '  <modelName>Panasonic VIErA</modelName>\n'
    '  <modelNumber>${_escape(modelNumber)}</modelNumber>\n'
    '  <UDN>$nrcUdn</UDN>\n'
    '  <viera:X_DMSUDN>$dmsUdn</viera:X_DMSUDN>\n'
    '  <viera:X_DMRUDN>$dmrUdn</viera:X_DMRUDN>\n'
    '  <viera:X_NRCUDN>$nrcUdn</viera:X_NRCUDN>\n'
    '  <vli:X_MHC_DEVICE_ID>7610266412732696</vli:X_MHC_DEVICE_ID>\n'
    '  <viera:X_VERSION>NRC-3.00</viera:X_VERSION>\n'
    '  <viera:X_DEVICE_TYPE>DTV</viera:X_DEVICE_TYPE>\n'
    '  <viera:X_KEY_TYPE>PAL-41,PAL-21,PAL-1</viera:X_KEY_TYPE>\n'
    '  <viera:X_PAD_TYPE>15-1</viera:X_PAD_TYPE>\n'
    '  <viera:X_NRC_ID>$nrcId</viera:X_NRC_ID>\n'
    '${nrcCapabilities == null ? '' : '  <viera:X_NRCCAP>$nrcCapabilities</viera:X_NRCCAP>\n'}'
    '  <serviceList>\n'
    '   <service>\n'
    '    <serviceType>$panasonicSimNrcUrn</serviceType>\n'
    '    <serviceId>urn:upnp-org:serviceId:p00NetworkControl</serviceId>\n'
    '    <SCPDURL>/nrc/sdd_0.xml</SCPDURL>\n'
    '    <controlURL>/nrc/control_0</controlURL>\n'
    '    <eventSubURL>/nrc/event_0</eventSubURL>\n'
    '   </service>\n'
    '  </serviceList>\n'
    ' </device>\n'
    '</root>\n';

String _action(String name, List<(String, String, String)> args) {
  final b = StringBuffer('  <action>\n   <name>$name</name>\n');
  if (args.isNotEmpty) {
    b.write('   <argumentList>\n');
    for (final (arg, direction, variable) in args) {
      b.write(
        '    <argument><name>$arg</name><direction>$direction</direction>'
        '<relatedStateVariable>$variable</relatedStateVariable></argument>\n',
      );
    }
    b.write('   </argumentList>\n');
  }
  b.write('  </action>\n');
  return b.toString();
}

/// `GET /nrc/sdd_0.xml`. Real sets do not list `X_GetAppList` (it works
/// anyway); encrypted sets add the pairing and encryption actions.
String panasonicSimNrcService({required bool encrypted}) {
  final actions = [
    _action('X_SendKey', [('X_KeyEvent', 'in', 'X_KeyEvent')]),
    _action('X_SendString', [('X_String', 'in', 'X_String')]),
    _action('X_GetInputMode', [('X_InputMode', 'out', 'X_InputMode')]),
    _action('X_GetKeyboardType', [('X_KeyboardType', 'out', 'X_KeyboardType')]),
    _action('X_GetVectorInfo', [('X_PortNumber', 'out', 'X_PortNumber')]),
    _action('X_GetGamepadInfo', [('X_PortNumber', 'out', 'X_PortNumber')]),
    _action('X_GetAppInfo', [
      ('X_InfoType', 'in', 'X_InfoType'),
      ('X_AppInfo', 'out', 'X_AppInfo'),
    ]),
    _action('X_LaunchApp', [
      ('X_AppType', 'in', 'X_AppType'),
      ('X_LaunchKeyword', 'in', 'X_LaunchKeyword'),
      ('X_SessionId', 'out', 'X_SessionId'),
    ]),
    _action('X_ConnectApp', [
      ('X_AppType', 'in', 'X_AppType'),
      ('X_SessionId', 'in', 'X_SessionId'),
      ('X_ConnectKeyword', 'in', 'X_ConnectKeyword'),
      ('X_ConnectAddr', 'in', 'X_ConnectAddr'),
      ('X_Message', 'out', 'X_Message'),
    ]),
    _action('X_QueryApp', [
      ('X_AppType', 'in', 'X_AppType'),
      ('X_SessionId', 'in', 'X_SessionId'),
      ('X_QueryKeyword', 'in', 'X_QueryKeyword'),
      ('X_Message', 'out', 'X_Message'),
    ]),
    _action('X_GetEventServerUrl', [
      ('X_EventServerUrl', 'out', 'X_EventServerUrl'),
    ]),
    if (encrypted) ...[
      _action('X_DisplayPinCode', [
        ('X_DeviceName', 'in', 'X_DeviceName'),
        ('X_ChallengeKey', 'out', 'X_ChallengeKey'),
      ]),
      _action('X_RequestAuth', [
        ('X_AuthInfo', 'in', 'X_AuthInfo'),
        ('X_AuthResult', 'out', 'X_AuthResult'),
      ]),
      _action('X_GetEncryptSessionId', [
        ('X_ApplicationId', 'in', 'X_ApplicationId'),
        ('X_EncInfo', 'in', 'X_EncInfo'),
        ('X_EncResult', 'out', 'X_EncResult'),
      ]),
      _action('X_EncryptedCommand', [
        ('X_ApplicationId', 'in', 'X_ApplicationId'),
        ('X_EncInfo', 'in', 'X_EncInfo'),
        ('X_EncResult', 'out', 'X_EncResult'),
      ]),
    ],
  ];
  String variable(String name, {bool events = false}) =>
      '  <stateVariable sendEvents="${events ? 'yes' : 'no'}">'
      '<name>$name</name><dataType>string</dataType></stateVariable>\n';
  return '<?xml version="1.0"?>\n'
      '<scpd xmlns="urn:schemas-upnp-org:service-1-0">\n'
      ' <specVersion><major>1</major><minor>0</minor></specVersion>\n'
      ' <actionList>\n'
      '${actions.join()}'
      ' </actionList>\n'
      ' <serviceStateTable>\n'
      '${variable('X_InputMode', events: true)}'
      '${variable('X_KeyboardType', events: true)}'
      '${variable('X_ScreenState', events: true)}'
      '${variable('X_AppInfo', events: true)}'
      '${variable('X_KeyEvent')}${variable('X_String')}'
      '${variable('X_PortNumber')}${variable('X_InfoType')}'
      '${variable('X_AppType')}${variable('X_LaunchKeyword')}'
      '${variable('X_SessionId')}'
      ' </serviceStateTable>\n'
      '</scpd>\n';
}

/// `GET /dmr/ddd.xml`: the DLNA MediaRenderer with RenderingControl.
String panasonicSimDmrDescription({
  required String friendlyName,
  required String modelNumber,
  required String dmrUdn,
}) =>
    '<?xml version="1.0"?>\n'
    '<root xmlns="urn:schemas-upnp-org:device-1-0">\n'
    ' <specVersion><major>1</major><minor>0</minor></specVersion>\n'
    ' <device>\n'
    '  <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1'
    '</deviceType>\n'
    '  <friendlyName>${_escape(friendlyName)}</friendlyName>\n'
    '  <manufacturer>Panasonic</manufacturer>\n'
    '  <modelName>Panasonic VIErA</modelName>\n'
    '  <modelNumber>${_escape(modelNumber)}</modelNumber>\n'
    '  <UDN>$dmrUdn</UDN>\n'
    '  <serviceList>\n'
    '   <service>\n'
    '    <serviceType>$panasonicSimRenderingControlUrn</serviceType>\n'
    '    <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>\n'
    '    <SCPDURL>/dmr/sdd_0.xml</SCPDURL>\n'
    '    <controlURL>/dmr/control_0</controlURL>\n'
    '    <eventSubURL>/dmr/event_0</eventSubURL>\n'
    '   </service>\n'
    '  </serviceList>\n'
    ' </device>\n'
    '</root>\n';

/// `GET /dmr/sdd_0.xml`: the RenderingControl actions the simulator has.
String panasonicSimDmrService() =>
    '<?xml version="1.0"?>\n'
    '<scpd xmlns="urn:schemas-upnp-org:service-1-0">\n'
    ' <specVersion><major>1</major><minor>0</minor></specVersion>\n'
    ' <actionList>\n'
    '${_action('GetVolume', [('InstanceID', 'in', 'A_ARG_TYPE_InstanceID'), ('Channel', 'in', 'A_ARG_TYPE_Channel'), ('CurrentVolume', 'out', 'Volume')])}'
    '${_action('SetVolume', [('InstanceID', 'in', 'A_ARG_TYPE_InstanceID'), ('Channel', 'in', 'A_ARG_TYPE_Channel'), ('DesiredVolume', 'in', 'Volume')])}'
    '${_action('GetMute', [('InstanceID', 'in', 'A_ARG_TYPE_InstanceID'), ('Channel', 'in', 'A_ARG_TYPE_Channel'), ('CurrentMute', 'out', 'Mute')])}'
    '${_action('SetMute', [('InstanceID', 'in', 'A_ARG_TYPE_InstanceID'), ('Channel', 'in', 'A_ARG_TYPE_Channel'), ('DesiredMute', 'in', 'Mute')])}'
    ' </actionList>\n'
    '</scpd>\n';

/// `GET /pac/ddd.xml` (PAC models, only while on). No indentation, as in
/// the captured TX-50GX800E description.
String panasonicSimPacDescription({
  required String friendlyName,
  required String pacUdn,
}) =>
    '<?xml version="1.0"?>\n'
    '<root xmlns="urn:schemas-upnp-org:device-1-0" '
    'xmlns:pxn="urn:schemas-panasonic-com:pxn">\n'
    '<specVersion><major>1</major><minor>0</minor></specVersion>\n'
    '<device>\n'
    '<deviceType>urn:panasonic-com:device:p00ProAVController:1'
    '</deviceType>\n'
    '<friendlyName>${_escape(friendlyName)}</friendlyName>\n'
    '<manufacturer>Panasonic</manufacturer>\n'
    '<modelName>Panasonic VIErA</modelName>\n'
    '<UDN>$pacUdn</UDN>\n'
    '<pxn:X_VERSION>PAC-1.00</pxn:X_VERSION>\n'
    '<pxn:X_CMD_TYPE>US-1</pxn:X_CMD_TYPE>\n'
    '<pxn:X_MARKET>PAL</pxn:X_MARKET>\n'
    '<pxn:X_PANEL>4K2KLCD2_2</pxn:X_PANEL>\n'
    '<pxn:X_MY>2016</pxn:X_MY>\n'
    '<serviceList>\n'
    '<service>\n'
    '<serviceType>$panasonicSimPacUrn</serviceType>\n'
    '<serviceId>urn:upnp-org:serviceId:p00ProAVControlService</serviceId>\n'
    '<SCPDURL>/pac/sdd_0.xml</SCPDURL>\n'
    '<controlURL>/pac/control_0</controlURL>\n'
    '<eventSubURL>/pac/event_0</eventSubURL>\n'
    '</service>\n'
    '</serviceList>\n'
    '</device>\n'
    '</root>\n';

/// A SOAP answer in the TV's exact layout: LF line breaks, one-space steps,
/// each out-argument on its own line, or the closing tag on the same line
/// when there are none. [outArgs] values must already be escaped.
String panasonicSimSoapAnswer(
  String action,
  String urn, [
  List<(String, String)> outArgs = const [],
]) {
  final b = StringBuffer(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
    ' <s:Body>\n'
    '  <u:${action}Response xmlns:u="$urn">',
  );
  if (outArgs.isEmpty) {
    b.write('</u:${action}Response>\n');
  } else {
    b.write('\n');
    for (final (name, value) in outArgs) {
      b.write('   <$name>$value</$name>\n');
    }
    b.write('  </u:${action}Response>\n');
  }
  b.write(' </s:Body>\n</s:Envelope>\n');
  return b.toString();
}

/// The fragment the simulator seals into an encrypted command's
/// `X_EncResult`: the inner answer element, on one line. The real wrapper
/// is unknown; with [wrapped] it sits in an `X_OriginalResult` element.
String panasonicSimEncryptedAnswer(
  String action,
  List<(String, String)> outArgs, {
  bool wrapped = false,
}) {
  final inner =
      '<u:${action}Response xmlns:u="$panasonicSimNrcUrn">'
      '${outArgs.map((a) => '<${a.$1}>${a.$2}</${a.$1}>').join()}'
      '</u:${action}Response>';
  return wrapped ? '<X_OriginalResult>$inner</X_OriginalResult>' : inner;
}

/// A standard UPnP 1.0 SOAP fault (the real Panasonic texts are unknown).
String panasonicSimFault(int code, String description) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\n'
    ' <s:Body>\n'
    '  <s:Fault>\n'
    '   <faultcode>s:Client</faultcode>\n'
    '   <faultstring>UPnPError</faultstring>\n'
    '   <detail>\n'
    '    <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">\n'
    '     <errorCode>$code</errorCode>\n'
    '     <errorDescription>${_escape(description)}</errorDescription>\n'
    '    </UPnPError>\n'
    '   </detail>\n'
    '  </s:Fault>\n'
    ' </s:Body>\n'
    '</s:Envelope>\n';

/// A GENA property-set body with one `e:property` per variable.
String panasonicSimPropertySet(List<(String, String)> variables) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
    '${variables.map((v) => '<e:property><${v.$1}>${_escape(v.$2)}</${v.$1}></e:property>').join()}'
    '</e:propertyset>';

/// [text] escaped the way the TV escapes its app list: `'` as `&apos;` and
/// `>` as `&gt;`.
String panasonicSimEscape(String text) => _escape(text);
