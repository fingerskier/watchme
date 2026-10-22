import 'package:watchme_core/watchme_core.dart';

import 'constants.dart';

const Set<CapFlag> _undocumented = {CapFlag.undocumented};

/// The settings a VIERA needs, shown by [panasonicDescriptor].
const List<SetupStep> panasonicSetupSteps = [
  SetupStep(
    id: 'panasonic.tvRemote',
    title: 'TV Remote = On',
    detail:
        'Menu > Network > TV Remote App Settings > TV Remote (2015 and '
        'later), or Menu > Network > VIERA Remote Settings > VIERA Remote '
        '(2012-2014). Without it the TV takes no network commands.',
  ),
  SetupStep(
    id: 'panasonic.sameSubnet',
    title: 'watchme on the same subnet as the TV',
    detail:
        'The TV answers HTTP 403 to every client on another subnet or VLAN, '
        "Panasonic's own app included. Run watchme on the TV's network.",
  ),
  SetupStep(
    id: 'panasonic.poweredOnByApps',
    title: 'Optional: Powered On by Apps = On',
    detail:
        'Menu > Network > TV Remote App Settings > Powered On by Apps (or '
        'Networked Standby on some models) keeps the network up in standby, '
        'so the TV can be switched back on over the network. It raises '
        'standby power, and many 2011-2015 sets cannot be switched on over '
        'the network at all.',
  ),
  SetupStep(
    id: 'panasonic.wakeOnLan',
    title: 'Optional: Wake on LAN = On (if offered)',
    detail:
        "Lets watchme switch the TV on with Wake-on-LAN, given the TV's MAC "
        'address. Usually works only over Ethernet, and not in the first '
        'half minute after the TV was switched off.',
  ),
];

/// Static facts about the VIERA network remote control driver.
///
/// Every capability carries [CapFlag.undocumented]: the protocol is
/// reverse-engineered from Panasonic's remote apps. Support levels follow
/// the community evidence in the watchme research brief.
const DriverDescriptor panasonicDescriptor = DriverDescriptor(
  id: panasonicDriverId,
  vendor: 'Panasonic',
  protocol: 'VIERA network remote control',
  stability: Stability.reverseEngineered,
  provenance:
      'Clean-room Dart implementation of the VIERA network remote control '
      '(UPnP/SOAP on port 55000), its PIN pairing and its AES-128-CBC / '
      'HMAC-SHA-256 command encryption. Requests, answers, key names and '
      'the key derivations were checked against florianholzapfel/'
      'panasonic-viera (MIT), AntonioMeireles/homebridge-vieramatic '
      '(Apache-2.0), the Home Assistant panasonic_viera integration '
      "(Apache-2.0), FastyBird's Viera connector (Apache-2.0) and "
      'jens-maus/node-panasonic-viera (MIT), plus field reports in their '
      'issue trackers; crypto test vectors were recomputed independently. '
      'No code was copied.',
  // Encrypted (2018 and later) sets need a PIN; the probe decides per TV.
  requiresPairing: false,
  ports: {PanasonicPorts.nrc: PanasonicPorts.nrcDefault},
  // A VIERA ignores Wake-on-LAN for about 30 s after switching off, and a
  // toggle sent while it switches may be swallowed or act twice: the power
  // orchestrator waits this long, not its default 20 s, before it trusts
  // the evidence or toggles again.
  powerQuietPeriod: Duration(seconds: 30),
  backends: [
    DriverBackend(
      id: 'panasonic.viera.http',
      requires: {
        TransportFeature.httpReadCrossOrigin,
        TransportFeature.customHeaders,
      },
      targets: {DriverTarget.native},
    ),
  ],
  matchers: [
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: VieraUrn.nrc,
      portName: PanasonicPorts.nrc,
    ),
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: VieraUrn.remoteController,
      portName: PanasonicPorts.nrc,
    ),
    // The TV's DLNA MediaRenderer, on the same port. Its modelName tells
    // VIERA TVs apart from other Panasonic renderers (unverified for DIGA
    // recorders; the probe checks the NRC description anyway).
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: VieraUrn.mediaRenderer,
      attributes: [
        AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Panasonic'),
        AttributeMatch.equals(
          DiscoveryAttr.modelName,
          'Panasonic VIErA',
          caseSensitive: true,
        ),
      ],
      portName: PanasonicPorts.nrc,
    ),
  ],
  userSetup: panasonicSetupSteps,
  ceiling: panasonicCeiling,
);

/// The most the VIERA network remote control can do.
const List<CapabilitySupport> panasonicCeiling = [
  CapabilitySupport.partial(
    Capability.powerOff,
    flags: {CapFlag.toggleOnly, CapFlag.undocumented},
    note:
        'Only the NRC_POWER toggle exists, so watchme sends it only when '
        'two sources agree the TV is on, or you confirm it.',
  ),
  CapabilitySupport.partial(
    Capability.powerOn,
    flags: {
      CapFlag.toggleOnly,
      CapFlag.needsNetworkStandby,
      CapFlag.userSetupRequired,
      CapFlag.undocumented,
    },
    note:
        'The power toggle switches the TV on only from network standby '
        '(Powered On by Apps on). Wake-on-LAN, sent by watchme when it '
        "knows the TV's MAC address, is preferred where the TV supports it. "
        'Many 2011-2015 sets cannot be switched on over the network.',
  ),
  CapabilitySupport.partial(
    Capability.powerState,
    flags: _undocumented,
    note:
        'Inferred only. The TV reports its screen state through UPnP '
        'eventing, which watchme does not receive yet; answering, and '
        'answering volume requests, does not prove the TV is on.',
  ),
  CapabilitySupport.yes(
    Capability.volume,
    flags: _undocumented,
    note:
        'Absolute 0-100 with readback through UPnP RenderingControl; needs '
        'no pairing, even on encrypted sets.',
  ),
  CapabilitySupport.yes(
    Capability.mute,
    flags: _undocumented,
    note: 'Discrete mute and unmute with readback (RenderingControl).',
  ),
  CapabilitySupport.yes(Capability.dpadNavigation, flags: _undocumented),
  CapabilitySupport.yes(
    Capability.systemKeys,
    flags: _undocumented,
    note:
        'Home, back, menu, info, guide, exit, colour keys and subtitles; no '
        'search key.',
  ),
  CapabilitySupport.partial(
    Capability.textInput,
    flags: {CapFlag.needsKeyboardOpen, CapFlag.undocumented},
    note:
        'Whole strings (X_SendString) while an on-screen keyboard is open; '
        'no backspace or replace.',
  ),
  CapabilitySupport.yes(
    Capability.appList,
    flags: _undocumented,
    note: 'Installed apps with icons; the TV lists none while in standby.',
  ),
  CapabilitySupport.yes(
    Capability.appLaunch,
    flags: _undocumented,
    note: 'By product id from the app list; no deep links.',
  ),
  CapabilitySupport.partial(
    Capability.inputSwitch,
    flags: _undocumented,
    note:
        'HDMI 1-4 and TV keys (no AV key); the current input is readable '
        'only on models with Pro AV control (PAC).',
  ),
  CapabilitySupport.partial(
    Capability.channel,
    flags: _undocumented,
    note:
        'Digits, channel up/down and last channel; no sub-channel '
        'separator and no readback.',
  ),
  CapabilitySupport.partial(
    Capability.mediaTransport,
    flags: _undocumented,
    note:
        'Play, pause, stop, rewind, fast forward, skip and record keys; no '
        'play/pause toggle or seek.',
  ),
  CapabilitySupport.partial(
    Capability.nowPlaying,
    flags: _undocumented,
    note:
        'The foreground app only (sometimes empty while an app runs); no '
        'playback state.',
  ),
  CapabilitySupport(
    Capability.pointer,
    Support.no,
    flags: _undocumented,
    note: 'The pointer protocol behind X_GetVectorInfo is unknown.',
  ),
  CapabilitySupport(
    Capability.notificationToast,
    Support.no,
    flags: _undocumented,
    note: 'No known API.',
  ),
  CapabilitySupport(
    Capability.screenshot,
    Support.no,
    flags: _undocumented,
    note: 'No known API.',
  ),
  CapabilitySupport(
    Capability.castMediaUrl,
    Support.no,
    flags: _undocumented,
    note:
        'Not implemented: the browser URL push needs an inbound connection '
        'from the TV, and DLNA playback on the TV is unverified.',
  ),
];

/// The capabilities for one TV: [panasonicCeiling] narrowed by its
/// `X_NRCCAP` list [nrcCapabilities] (when the description has one) and by
/// whether Pro AV control ([pac]) was seen.
///
/// A set that lists neither `VR_POWER` nor `VR_WOL` (a 2013 ET60, say)
/// cannot be switched on over the network, and one without `VR_LAUNCH` may
/// not launch apps; both are hints, not proof, so only power-on is
/// removed.
List<CapabilitySupport> panasonicCapabilities({
  Set<String>? nrcCapabilities,
  bool pac = false,
}) {
  final caps = nrcCapabilities;
  return [
    for (final c in panasonicCeiling)
      switch (c.capability) {
        Capability.powerOn
            when caps != null &&
                !caps.contains('VR_POWER') &&
                !caps.contains('VR_WOL') =>
          const CapabilitySupport(
            Capability.powerOn,
            Support.no,
            flags: _undocumented,
            note:
                'This TV lists neither VR_POWER nor VR_WOL: sets like it '
                'cannot be switched on over the network, only off.',
          ),
        Capability.appLaunch when caps != null && !caps.contains('VR_LAUNCH') =>
          c.copyWith(
            level: Support.partial,
            note:
                '${c.note} This TV does not list VR_LAUNCH, so launching '
                'may not work.',
          ),
        Capability.inputSwitch when pac => c.copyWith(
          note:
              'HDMI 1-4 and TV keys, plus Pro AV control (PAC) input codes '
              'and the current input.',
        ),
        _ => c,
      },
  ];
}
