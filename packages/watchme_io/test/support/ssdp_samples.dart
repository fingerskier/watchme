// Captured-style SSDP and UPnP samples, rewritten with documentation
// addresses (10.0.0.x) and made-up serials. Shapes follow Roku's ECP
// documentation, the brs-desktop emulator (MIT) and the DIAL reference
// server (BSD).

String crlf(String text) => text.replaceAll('\n', '\r\n');

/// A Roku reply to `ST: roku:ecp`, with Roku's extra headers.
String rokuResponse({String host = '10.0.0.20'}) => crlf('''
HTTP/1.1 200 OK
Cache-Control: max-age=3600
ST: roku:ecp
USN: uuid:roku:ecp:YN00AB123456
Ext:
Server: Roku/14.1.4 UPnP/1.0 Roku/14.1.4
LOCATION: http://$host:8060/
device-group.roku.com: 46F5CCE2472F2B14D77
WAKEUP: MAC=D8-31-34-AA-BB-CC;Timeout=10

''');

/// A Roku device description (served at `http://<ip>:8060/`).
const String rokuDescription = '''
<?xml version="1.0" encoding="UTF-8" ?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:roku-com:device:player:1-0</deviceType>
    <friendlyName>Living Room Roku</friendlyName>
    <manufacturer>Roku</manufacturer>
    <manufacturerURL>http://www.roku.com/</manufacturerURL>
    <modelDescription>Roku Streaming Player Network Media</modelDescription>
    <modelName>Roku Ultra</modelName>
    <modelNumber>4850X</modelNumber>
    <serialNumber>YN00AB123456</serialNumber>
    <UDN>uuid:29600009-5406-1005-8080-d83134aabbcc</UDN>
    <serviceList>
      <service>
        <serviceType>urn:roku-com:service:ecp:1</serviceType>
        <serviceId>urn:roku-com:serviceId:ecp1-0</serviceId>
      </service>
      <service>
        <serviceType>urn:dial-multiscreen-org:service:dial:1</serviceType>
        <serviceId>urn:dial-multiscreen-org:serviceId:dial1-0</serviceId>
      </service>
    </serviceList>
  </device>
</root>
''';

const String fireTvUdn = 'uuid:7c2a6a2e-3c1f-4c55-9a0e-0fa1c2d3e4f5';

/// A Fire TV DIAL reply, as seen by LibreControl's 2026 hardware test.
String fireTvDialResponse({
  String host = '10.0.0.7',
  String locationHost = '10.0.0.7',
}) => crlf('''
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
EXT:
LOCATION: http://$locationHost:60000/upnp/dev/7c2a6a2e/desc
SERVER: Linux/4.9 UPnP/1.0 Cling/2.0
ST: urn:dial-multiscreen-org:service:dial:1
USN: $fireTvUdn::urn:dial-multiscreen-org:service:dial:1
BOOTID.UPNP.ORG: 7

''');

/// The same device answering `ssdp:all` as its root device.
String fireTvRootResponse() => crlf('''
HTTP/1.1 200 OK
LOCATION: http://10.0.0.7:60000/upnp/dev/7c2a6a2e/desc
ST: upnp:rootdevice
USN: $fireTvUdn::upnp:rootdevice

''');

/// The Fire TV device description, with a prefixed namespace.
const String fireTvDescription = '''
<?xml version="1.0"?>
<u:root xmlns:u="urn:schemas-upnp-org:device-1-0">
  <u:specVersion><u:major>1</u:major><u:minor>0</u:minor></u:specVersion>
  <u:device>
    <u:deviceType>urn:dial-multiscreen-org:device:dial:1</u:deviceType>
    <u:friendlyName>Den Fire TV</u:friendlyName>
    <u:manufacturer>Amazon</u:manufacturer>
    <u:modelName>AFTKA</u:modelName>
    <u:UDN>uuid:7c2a6a2e-3c1f-4c55-9a0e-0fa1c2d3e4f5</u:UDN>
  </u:device>
</u:root>
''';

/// An `ssdp:alive` NOTIFY with bare `\n` line endings.
const String rokuNotifyAlive = '''
NOTIFY * HTTP/1.1
Host: 239.255.255.250:1900
Cache-Control: max-age=3600
NT: roku:ecp
NTS: ssdp:alive
Location: http://10.0.0.20:8060/
USN: uuid:roku:ecp:YN00AB123456

''';

/// An `ssdp:byebye` NOTIFY.
String rokuNotifyByeBye() => crlf('''
NOTIFY * HTTP/1.1
HOST: 239.255.255.250:1900
NT: roku:ecp
NTS: ssdp:byebye
USN: uuid:roku:ecp:YN00AB123456

''');

/// A Panasonic VIERA reply to its network remote control target, in the
/// shape the VIERA research brief gives (made-up UDN).
String vieraNrcResponse() => crlf('''
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
EXT:
LOCATION: http://10.0.0.40:55000/nrc/ddd.xml
SERVER: Linux/4.0 UPnP/1.0 Panasonic-UPnP-MW/1.0
ST: urn:panasonic-com:service:p00NetworkControl:1
USN: uuid:4d454931-0200-1090-8001-80c755b86c63::urn:panasonic-com:service:p00NetworkControl:1

''');

/// A Sharp AQUOS reply to its IP-control device type; its description
/// port (12346) is not the control port.
String aquosIpcResponse() => crlf('''
HTTP/1.1 200 OK
CACHE-CONTROL: max-age=1800
EXT:
LOCATION: http://10.0.0.50:12346/ipc/
SERVER: Linux UPnP/1.0 Sharp
ST: urn:schemas-sharp-co-jp:device:AquosIPC:1
USN: uuid:34f62d00-0001-11e0-8000-34f62d000001::urn:schemas-sharp-co-jp:device:AquosIPC:1

''');
