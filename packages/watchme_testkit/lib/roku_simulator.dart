/// A Roku ECP simulator on loopback (HTTP plus an optional unicast SSDP
/// responder), for driver, engine and UI tests without hardware.
///
/// Uses `dart:io`, so it is not exported from the pure-Dart
/// `package:watchme_testkit/watchme_testkit.dart`.
library;

export 'src/simulators/roku/roku_sim_models.dart';
export 'src/simulators/roku/roku_simulator.dart';
export 'src/simulators/roku/roku_sim_xml.dart'
    show
        rokuActiveAppXml,
        rokuAppsXml,
        rokuDeviceInfoXml,
        rokuMediaPlayerXml,
        rokuRootDescriptionXml;
