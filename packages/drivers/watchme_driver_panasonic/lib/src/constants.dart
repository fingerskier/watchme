import 'package:watchme_core/watchme_core.dart';

/// The Panasonic driver id ([DriverDescriptor.id], [DeviceEvent.driverId]).
const String panasonicDriverId = 'panasonic.viera';

/// [Endpoint] port names used by the Panasonic driver, with their defaults.
abstract final class PanasonicPorts {
  /// The TV's UPnP/SOAP server: the network remote control (NRC), the DLNA
  /// MediaRenderer (volume and mute) and, on some models, PAC. Plain HTTP.
  static const String nrc = 'nrc';

  /// Default port of [nrc].
  static const int nrcDefault = 55000;
}

/// The endpoint attribute a probe sets to record whether the TV's NRC
/// service is encrypted: [panasonicEncryptionAes] or
/// [panasonicEncryptionNone]. [PairingFlow]s and sessions re-check the
/// service description themselves; the attribute only lets
/// `Driver.startPairing`, which cannot do I/O, return `null` for a TV that
/// needs no pairing.
const String panasonicEncryptionAttr = 'panasonic.nrc.encryption';

/// [panasonicEncryptionAttr] for a TV that needs PIN pairing (its service
/// description lists `X_GetEncryptSessionId`).
const String panasonicEncryptionAes = 'aes';

/// [panasonicEncryptionAttr] for a TV that takes plain commands.
const String panasonicEncryptionNone = 'none';

/// UPnP service types (URNs) the driver talks to.
abstract final class VieraUrn {
  /// The network remote control service.
  static const String nrc = 'urn:panasonic-com:service:p00NetworkControl:1';

  /// The NRC root device.
  static const String remoteController =
      'urn:panasonic-com:device:p00RemoteController:1';

  /// UPnP RenderingControl on the DLNA MediaRenderer (volume and mute).
  static const String renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';

  /// The DLNA MediaRenderer device.
  static const String mediaRenderer =
      'urn:schemas-upnp-org:device:MediaRenderer:1';

  /// The optional "Pro AV" control service of some models.
  static const String pac =
      'urn:panasonic-com:service:p00ProAVControlService:1';
}

/// Paths on the TV's UPnP server.
abstract final class VieraPaths {
  /// NRC device description.
  static const String nrcDescription = '/nrc/ddd.xml';

  /// NRC service description; lists `X_GetEncryptSessionId` on encrypted
  /// TVs.
  static const String nrcService = '/nrc/sdd_0.xml';

  /// NRC control URL.
  static const String nrcControl = '/nrc/control_0';

  /// RenderingControl's control URL on the MediaRenderer.
  static const String dmrControl = '/dmr/control_0';

  /// PAC device description; answers 200 only while a PAC model is on.
  static const String pacDescription = '/pac/ddd.xml';

  /// PAC control URL.
  static const String pacControl = '/pac/control_0';
}
