import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';

const Set<CapFlag> _undocumented = {CapFlag.undocumented};

/// Static facts about the Fire TV remote-API driver.
///
/// Every capability carries [CapFlag.undocumented]: the API is
/// reverse-engineered from Amazon's mobile remote app and may change with a
/// firmware update. Support levels follow the community evidence collected
/// in `docs/research/tv-control-landscape.md`.
const DriverDescriptor fireTvDescriptor = DriverDescriptor(
  id: fireTvDriverId,
  vendor: 'Amazon',
  protocol: 'Fire TV remote API (Lightning)',
  stability: Stability.reverseEngineered,
  provenance:
      'Clean-room Dart implementation of the community-documented Fire TV '
      'mobile-remote API. Endpoints, headers and bodies were checked against '
      'LibreControl/fire-tv (MIT) and hms-homelab/hms-firetv (MIT); no code '
      'was copied.',
  requiresPairing: true,
  ports: {
    FireTvPorts.dial: FireTvPorts.dialDefault,
    FireTvPorts.api: FireTvPorts.apiDefault,
  },
  backends: [
    DriverBackend(
      id: 'firetv.lightning.https',
      requires: {
        TransportFeature.httpReadCrossOrigin,
        TransportFeature.customHeaders,
        TransportFeature.tlsAcceptSelfSigned,
        TransportFeature.tlsPeerCertificate,
      },
      targets: {DriverTarget.native},
    ),
  ],
  matchers: [
    // Amazon WhisperPlay; Fire TVs are told apart from other Amazon devices
    // by the `amzn.dmgr` token in their records.
    DiscoveryMatcher(
      serviceType: '_amzn-wplay._tcp',
      attributes: [
        AttributeMatch.regex(DiscoveryAttr.mdnsInstance, r'amzn\.dmgr'),
      ],
    ),
    // The SRV port of this service is the remote API (LibreControl).
    DiscoveryMatcher(
      serviceType: '_amzn-fireTv._tcp',
      portName: FireTvPorts.api,
    ),
    // The only advertisement LibreControl's 2026 hardware test saw.
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: 'urn:dial-multiscreen-org:service:dial:1',
      attributes: [
        AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Amazon'),
        AttributeMatch.prefix(
          DiscoveryAttr.modelName,
          'AFT',
          caseSensitive: true,
        ),
      ],
    ),
  ],
  ceiling: [
    CapabilitySupport.yes(
      Capability.powerOff,
      flags: _undocumented,
      note:
          'Puts the Fire TV to sleep; the TV follows over HDMI-CEC when '
          'CEC is enabled. The power key is a separate toggle of the TV '
          'over HDMI-CEC, with no state.',
    ),
    CapabilitySupport.partial(
      Capability.powerOn,
      flags: {CapFlag.undocumented, CapFlag.needsNetworkStandby},
      note:
          'The DIAL FireTVRemote launch wakes a sleeping Fire TV; nothing '
          'wakes one that is fully powered off.',
    ),
    CapabilitySupport(
      Capability.powerState,
      Support.no,
      flags: _undocumented,
      note: 'The status endpoint reports no power state.',
    ),
    CapabilitySupport.partial(
      Capability.volume,
      flags: {CapFlag.undocumented, CapFlag.relativeOnly, CapFlag.writeOnly},
      note:
          'volume_up / volume_down forwarded to the TV over HDMI-CEC. '
          'Confirmed only on a Vega OS stick; may be ignored on Fire OS.',
    ),
    CapabilitySupport.partial(
      Capability.mute,
      flags: {CapFlag.undocumented, CapFlag.toggleOnly, CapFlag.writeOnly},
      note:
          'Mute toggle forwarded over HDMI-CEC, with no readable state. '
          'Confirmed only on a Vega OS stick.',
    ),
    CapabilitySupport.yes(
      Capability.dpadNavigation,
      flags: _undocumented,
      note: 'Press and hold through keyDown/keyUp.',
    ),
    CapabilitySupport.yes(
      Capability.systemKeys,
      flags: _undocumented,
      note: 'Home, back and menu.',
    ),
    CapabilitySupport.partial(
      Capability.textInput,
      flags: {CapFlag.undocumented, CapFlag.needsKeyboardOpen},
      note:
          'Whole strings into the open on-screen keyboard; no backspace, '
          'enter or replace.',
    ),
    CapabilitySupport.yes(
      Capability.appList,
      flags: _undocumented,
      note: 'Installed apps with names and icons (appsV2).',
    ),
    CapabilitySupport.yes(
      Capability.appLaunch,
      flags: _undocumented,
      note: 'By Android package name; no deep links.',
    ),
    CapabilitySupport(Capability.inputSwitch, Support.no, flags: _undocumented),
    CapabilitySupport(Capability.channel, Support.no, flags: _undocumented),
    CapabilitySupport.partial(
      Capability.mediaTransport,
      flags: _undocumented,
      note:
          'Play/pause toggle and scan forward/backward only; no discrete '
          'play or pause, no seek. Backward scan (direction "back", as the '
          'official app sends it) is not yet verified on hardware.',
    ),
    CapabilitySupport(
      Capability.nowPlaying,
      Support.no,
      flags: _undocumented,
      note: 'No known endpoint.',
    ),
    CapabilitySupport(Capability.pointer, Support.no, flags: _undocumented),
    CapabilitySupport(
      Capability.notificationToast,
      Support.no,
      flags: _undocumented,
    ),
    CapabilitySupport(Capability.screenshot, Support.no, flags: _undocumented),
    CapabilitySupport(
      Capability.castMediaUrl,
      Support.no,
      flags: _undocumented,
      note: 'Fire TV casting goes through Matter Casting, not this API.',
    ),
  ],
);
