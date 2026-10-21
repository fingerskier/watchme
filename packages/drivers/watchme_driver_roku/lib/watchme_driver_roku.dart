/// Roku External Control Protocol (ECP) driver for watchme.
///
/// [RokuDriver] (`roku.ecp`) probes, connects to and controls Roku players
/// and Roku TVs over plain HTTP on port 8060. Pure Dart: it talks only to
/// the watchme_core `Transports` interfaces, so it also compiles for the web.
///
/// The XML parsers, key table and capability rules are exported too, for
/// tools and tests.
library;

export 'src/capabilities.dart'
    show rokuCapabilities, rokuCeiling, rokuEnableHint;
export 'src/ecp_client.dart'
    show
        EcpClient,
        hostHeader,
        isIpLiteral,
        rokuEcpDefaultPort,
        rokuEcpPortName,
        rokuRefusal;
export 'src/ecp_xml.dart';
export 'src/keys.dart';
export 'src/roku_driver.dart';
export 'src/roku_session.dart';
