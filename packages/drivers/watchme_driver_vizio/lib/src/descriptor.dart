import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';

const Set<CapFlag> _undocumented = {CapFlag.undocumented};

/// Static facts about the VIZIO SmartCast driver.
///
/// Every capability carries [CapFlag.undocumented]: the SmartCast API is
/// documented by several independent clients and a decompile of the
/// official app, not by VIZIO, and 2025-2026 VIZIO OS builds may tighten
/// it. Support levels follow the watchme VIZIO brief (§10), narrowed where
/// the driver does less than the protocol could: no cloud app catalog, no
/// key whose code is in doubt.
const DriverDescriptor vizioDescriptor = DriverDescriptor(
  id: vizioDriverId,
  vendor: 'VIZIO',
  protocol: 'VIZIO SmartCast API',
  stability: Stability.communityStandard,
  provenance:
      'Clean-room Dart implementation of the community-documented VIZIO '
      'SmartCast API. Endpoints, bodies, status words and key codes were '
      'checked against vizaio (MIT), pyvizio (MIT), heathbar/'
      'vizio-smart-cast (MIT) and the Home Assistant vizio integration '
      '(Apache-2.0); exiva/Vizio_SmartCast_API (no licence) was read for '
      'facts only. No code was copied. The pairing token is an unscoped '
      'bearer secret, and the internal loopback API, the WebSocket bus and '
      'the raw-URL app launcher are deliberately not implemented.',
  requiresPairing: true,
  ports: {
    VizioPorts.api: VizioPorts.apiDefault,
    VizioPorts.legacy: VizioPorts.legacyDefault,
  },
  backends: [
    DriverBackend(
      id: 'vizio.smartcast.https',
      requires: {
        TransportFeature.httpReadCrossOrigin,
        TransportFeature.customHeaders,
        TransportFeature.nonSimpleMethods,
        TransportFeature.tlsAcceptSelfSigned,
        TransportFeature.tlsPeerCertificate,
      },
      targets: {DriverTarget.native},
    ),
  ],
  matchers: [
    // What the official app browses for. The SRV port is only a hint (TXT
    // `hsp` names the REST port), so no port name is filled from it.
    DiscoveryMatcher(serviceType: '_viziocast._tcp'),
    // DIAL, for sets that do not advertise mDNS. Its port is the DIAL
    // server, not the REST API.
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: 'urn:dial-multiscreen-org:device:dial:1',
      attributes: [AttributeMatch.equals(DiscoveryAttr.manufacturer, 'VIZIO')],
    ),
  ],
  userSetup: [
    SetupStep(
      id: 'vizio.quickStart',
      title: 'Optional: Power Mode = Quick Start',
      detail:
          'System > Power Mode (Eco Mode on some firmware) > Quick Start '
          'keeps the network up while the TV is off, so watchme can turn it '
          'on and read its power state. In Eco mode the TV drops off the '
          'network when off: only Wake-on-LAN can wake it, and not every set '
          'honours that. Quick Start uses more standby power.',
    ),
  ],
  ceiling: [
    CapabilitySupport.yes(
      Capability.powerOff,
      flags: _undocumented,
      note: 'Discrete power-off key (11/0) while the TV answers.',
    ),
    CapabilitySupport.partial(
      Capability.powerOn,
      flags: {CapFlag.undocumented, CapFlag.needsNetworkStandby},
      note:
          'Discrete power-on key (11/1), only while the network stays up '
          '(Quick Start). In Eco mode the API port is closed: Wake-on-LAN '
          'to the MAC the TV advertises is the only way, best-effort.',
    ),
    CapabilitySupport.yes(
      Capability.powerState,
      flags: _undocumented,
      note:
          'power_mode (needs the pairing token): 1 on, 0 Quick Start '
          'standby. A TV that does not answer (Eco, off, gone) gives no '
          'reading, and an unpaired one gives none either.',
    ),
    CapabilitySupport.yes(
      Capability.volume,
      flags: _undocumented,
      note:
          'Absolute 0-100 with readback through the settings tree '
          '(read-modify-write with HASHVAL); steps with the volume keys.',
    ),
    CapabilitySupport.yes(
      Capability.mute,
      flags: _undocumented,
      note:
          'Readable; discrete set through the settings tree, toggle key '
          '5/4. The TV ignores mute changes in standby.',
    ),
    CapabilitySupport.yes(Capability.dpadNavigation, flags: _undocumented),
    CapabilitySupport.yes(
      Capability.systemKeys,
      flags: _undocumented,
      note:
          'Back, menu, info, exit, captions, and home (the SmartCast key). '
          'No settings, search or colour keys; no guide key, since its '
          'code also means captions.',
    ),
    CapabilitySupport.partial(
      Capability.textInput,
      flags: {CapFlag.undocumented, CapFlag.needsKeyboardOpen},
      note:
          'Printable ASCII typed into a focused field; no backspace, enter '
          'or replace.',
    ),
    CapabilitySupport.partial(
      Capability.appList,
      flags: _undocumented,
      note:
          "watchme's built-in launch table only (Netflix, YouTube, "
          "SmartCast Home); the TV has no app list, and VIZIO's cloud "
          'catalog is not used.',
    ),
    CapabilitySupport.partial(
      Capability.appLaunch,
      flags: _undocumented,
      note:
          'Apps from the built-in launch table; no deep links. The current '
          'app is readable.',
    ),
    CapabilitySupport.yes(
      Capability.inputSwitch,
      flags: _undocumented,
      note:
          'Inputs by name (hdmi1, cast, tuner, ...) through the settings '
          'tree; the input-cycle key too.',
    ),
    CapabilitySupport.partial(
      Capability.channel,
      flags: _undocumented,
      note: 'TVs with a tuner: channel keys and digit entry.',
    ),
    CapabilitySupport.partial(
      Capability.mediaTransport,
      flags: _undocumented,
      note:
          'Discrete play and pause, fast-forward and rewind keys; no '
          'play/pause toggle, stop or seek, and no readable state.',
    ),
    CapabilitySupport.partial(
      Capability.nowPlaying,
      flags: _undocumented,
      note: 'The foreground app only; no title, position or playback state.',
    ),
    CapabilitySupport.no(
      Capability.pointer,
      note: 'SmartCast has no pointer API.',
    ),
    CapabilitySupport.no(
      Capability.notificationToast,
      note: 'SmartCast has no notification API.',
    ),
    CapabilitySupport.no(
      Capability.screenshot,
      note: 'SmartCast has no screenshot API.',
    ),
    CapabilitySupport.no(
      Capability.castMediaUrl,
      note:
          'VIZIO casting is Chromecast built-in, a separate protocol and '
          'driver.',
    ),
  ],
);
