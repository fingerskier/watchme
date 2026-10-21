import 'package:xml/xml.dart';

import 'roku_sim_models.dart';

// XML bodies in the shapes real Roku devices serve (cross-checked against
// Roku's ECP documentation, python-rokuecp (MIT) and brs-desktop (MIT)).

String _doc(void Function(XmlBuilder b) build) {
  final b = XmlBuilder()..processing('xml', 'version="1.0" encoding="UTF-8" ');
  build(b);
  return b.buildDocument().toXmlString(pretty: true, indent: '\t');
}

void _el(XmlBuilder b, String name, Object? value) =>
    b.element(name, nest: value?.toString() ?? '');

/// `GET /query/device-info`.
String rokuDeviceInfoXml(
  RokuSimDevice d, {
  required RokuSimPowerMode powerMode,
  required RokuControlMode controlMode,
  required Duration uptime,
}) => _doc(
  (b) => b.element(
    'device-info',
    nest: () {
      _el(b, 'udn', d.udn);
      _el(b, 'serial-number', d.serialNumber);
      _el(b, 'device-id', d.deviceId);
      _el(b, 'advertising-id', '00000000-0000-4000-8000-000000000000');
      _el(b, 'vendor-name', d.vendorName);
      _el(b, 'model-name', d.modelName);
      _el(b, 'model-number', d.modelNumber);
      _el(b, 'model-region', 'US');
      _el(b, 'is-tv', d.isTv);
      _el(b, 'is-stick', d.isStick);
      if (d.isTv) {
        _el(b, 'screen-size', 50);
        _el(b, 'panel-id', 2);
      }
      if (d.tunerType case final t?) _el(b, 'tuner-type', t);
      _el(b, 'supports-ethernet', d.ethernetMac != null);
      _el(b, 'wifi-mac', d.wifiMac);
      _el(b, 'wifi-driver', 'realtek');
      _el(b, 'has-wifi-extender', false);
      _el(b, 'has-wifi-5G-support', true);
      _el(b, 'can-use-wifi-extender', true);
      if (d.ethernetMac case final mac?) _el(b, 'ethernet-mac', mac);
      _el(b, 'network-type', d.networkType);
      _el(b, 'network-name', 'SimNet');
      _el(b, 'friendly-device-name', d.userDeviceName);
      _el(b, 'friendly-model-name', d.friendlyModelName);
      _el(b, 'default-device-name', d.defaultDeviceName);
      _el(b, 'user-device-name', d.userDeviceName);
      _el(b, 'user-device-location', d.userDeviceLocation);
      _el(b, 'build-number', d.buildNumber);
      _el(b, 'software-version', d.softwareVersion);
      _el(b, 'software-build', d.softwareBuild);
      _el(b, 'lightning-base-build-number', '');
      _el(b, 'ui-build-number', d.buildNumber);
      _el(b, 'ui-software-version', d.softwareVersion);
      _el(b, 'ui-software-build', d.softwareBuild);
      _el(b, 'secure-device', true);
      if (d.reportEcpSettingMode) {
        _el(b, 'ecp-setting-mode', controlMode.name);
      }
      _el(b, 'language', 'en');
      _el(b, 'country', 'US');
      _el(b, 'locale', 'en_US');
      _el(b, 'time-zone-auto', true);
      _el(b, 'time-zone', 'US/Eastern');
      _el(b, 'time-zone-name', 'United States/Eastern');
      _el(b, 'time-zone-tz', 'America/New_York');
      _el(b, 'time-zone-offset', -240);
      _el(b, 'clock-format', '12-hour');
      _el(b, 'uptime', uptime.inSeconds);
      _el(b, 'power-mode', powerMode.wire);
      _el(b, 'supports-suspend', d.isTv);
      _el(b, 'supports-find-remote', d.supportsFindRemote);
      _el(b, 'find-remote-is-possible', false);
      _el(b, 'supports-audio-guide', true);
      _el(b, 'supports-rva', true);
      _el(b, 'has-hands-free-voice-remote', false);
      _el(b, 'developer-enabled', false);
      _el(b, 'keyed-developer-id', null);
      _el(b, 'device-automation-bridge-available', false);
      _el(b, 'search-enabled', true);
      _el(b, 'search-channels-enabled', true);
      _el(b, 'voice-search-enabled', true);
      _el(b, 'supports-private-listening', true);
      _el(b, 'supports-private-listening-dtv', d.isTv);
      _el(b, 'supports-warm-standby', d.isTv);
      _el(b, 'headphones-connected', false);
      _el(b, 'supports-audio-settings', false);
      _el(b, 'expert-pq-enabled', d.isTv ? '1.0' : '0.0');
      _el(b, 'supports-ecs-textedit', true);
      _el(b, 'supports-ecs-microphone', true);
      _el(b, 'supports-wake-on-wlan', d.supportsWakeOnWlan);
      _el(b, 'supports-airplay', true);
      _el(b, 'has-play-on-roku', true);
      _el(b, 'has-mobile-screensaver', true);
      _el(b, 'support-url', 'roku.com/support');
      _el(b, 'grandcentral-version', '13.1.27');
      _el(b, 'supports-trc', true);
      _el(b, 'trc-version', '3.0');
      _el(b, 'trc-channel-version', '9.3.6');
      _el(b, 'davinci-version', '2.8.20');
      _el(b, 'av-sync-calibration-enabled', '3.0');
      if (d.supportsTvPowerControl case final v?) {
        _el(b, 'supports-tv-power-control', v);
      }
      if (d.supportsAudioVolumeControl case final v?) {
        _el(b, 'supports-audio-volume-control', v);
      }
    },
  ),
);

/// `GET /` (the UPnP root description SSDP's LOCATION points at).
String rokuRootDescriptionXml(RokuSimDevice d) => _doc(
  (b) => b.element(
    'root',
    attributes: {'xmlns': 'urn:schemas-upnp-org:device-1-0'},
    nest: () {
      b.element(
        'specVersion',
        nest: () {
          _el(b, 'major', 1);
          _el(b, 'minor', 0);
        },
      );
      b.element(
        'device',
        nest: () {
          _el(b, 'deviceType', 'urn:roku-com:device:player:1-0');
          _el(b, 'friendlyName', d.userDeviceName);
          _el(b, 'manufacturer', 'Roku');
          _el(b, 'manufacturerURL', 'http://www.roku.com/');
          _el(b, 'modelDescription', 'Roku Streaming Player Network Media');
          _el(b, 'modelName', d.modelName);
          _el(b, 'modelNumber', d.modelNumber);
          _el(b, 'modelURL', 'http://www.roku.com/');
          _el(b, 'serialNumber', d.serialNumber);
          _el(b, 'UDN', 'uuid:${d.udn}');
          b.element(
            'serviceList',
            nest: () {
              for (final (type, id, scpd) in const [
                (
                  'urn:roku-com:service:ecp:1',
                  'urn:roku-com:serviceId:ecp1-0',
                  'ecp_SCPD.xml',
                ),
                (
                  'urn:dial-multiscreen-org:service:dial:1',
                  'urn:dial-multiscreen-org:serviceId:dial1-0',
                  'dial_SCPD.xml',
                ),
              ]) {
                b.element(
                  'service',
                  nest: () {
                    _el(b, 'serviceType', type);
                    _el(b, 'serviceId', id);
                    _el(b, 'controlURL', null);
                    _el(b, 'eventSubURL', null);
                    _el(b, 'SCPDURL', scpd);
                  },
                );
              }
            },
          );
        },
      );
    },
  ),
);

/// `GET /query/apps`.
String rokuAppsXml(Iterable<RokuSimApp> apps) => _doc(
  (b) => b.element(
    'apps',
    nest: () {
      for (final app in apps) {
        b.element(
          'app',
          attributes: {'id': app.id, 'type': app.type, 'version': app.version},
          nest: app.name,
        );
      }
    },
  ),
);

/// `GET /query/active-app`; [app] `null` is the home screen.
String rokuActiveAppXml(RokuSimApp? app) => _doc(
  (b) => b.element(
    'active-app',
    nest: () {
      if (app == null) {
        _el(b, 'app', 'Roku');
      } else {
        b.element(
          'app',
          attributes: {'id': app.id, 'type': app.type, 'version': app.version},
          nest: app.name,
        );
      }
    },
  ),
);

/// `GET /query/media-player`.
String rokuMediaPlayerXml({
  required RokuSimPlayerState state,
  RokuSimApp? app,
  Duration position = Duration.zero,
  Duration? duration,
  bool isLive = false,
}) => _doc(
  (b) => b.element(
    'player',
    attributes: {'error': 'false', 'state': state.name},
    nest: () {
      if (app == null ||
          state == RokuSimPlayerState.none ||
          state == RokuSimPlayerState.close) {
        return;
      }
      b
        ..element(
          'plugin',
          attributes: {
            'bandwidth': '19807640 bps',
            'id': app.id,
            'name': app.name,
          },
        )
        ..element(
          'format',
          attributes: {
            'audio': 'eac3',
            'captions': 'none',
            'container': 'mp4',
            'drm': 'widevine',
            'video': 'hevc_b',
            'video_res': '3840x2160',
          },
        )
        ..element(
          'buffering',
          attributes: {'current': '1000', 'max': '1000', 'target': '0'},
        )
        ..element('new_stream', attributes: {'speed': '128000 bps'});
      _el(b, 'position', '${position.inMilliseconds} ms');
      if (duration != null) _el(b, 'duration', '${duration.inMilliseconds} ms');
      b.element(
        'is_live',
        attributes: {'blocked': 'false'},
        nest: isLive.toString(),
      );
      if (duration != null) _el(b, 'runtime', '${duration.inMilliseconds} ms');
    },
  ),
);
