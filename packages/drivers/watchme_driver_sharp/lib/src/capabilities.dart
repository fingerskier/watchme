import 'package:watchme_core/watchme_core.dart';

import 'keys.dart';
import 'profiles.dart';

const Set<CapFlag> _networkPowerOn = {
  CapFlag.needsNetworkStandby,
  CapFlag.userSetupRequired,
};

/// The most Sharp IP control can do on any model. No power capability is
/// toggle-only: on and off are the discrete `POWR1` and `POWR0`, so the
/// power orchestrator never needs the POWER key toggle.
const List<CapabilitySupport> sharpCeiling = [
  CapabilitySupport.yes(
    Capability.powerOff,
    note:
        'Discrete POWR0. The POWER remote key is a separate toggle, sent '
        'only for an explicit key press while the TV reads as on.',
  ),
  CapabilitySupport.partial(
    Capability.powerOn,
    flags: _networkPowerOn,
    note:
        'Discrete POWR1, which works from standby only while the TV keeps '
        'IP control listening: the power-on command setting (RSPW) on US '
        '2010-2014 sets, Quick Start Mode on 2014 and later sets. EU '
        '2011-2013 sets have no power-on command.',
  ),
  CapabilitySupport.yes(
    Capability.powerState,
    note:
        'POWR? reads on or standby while the TV listens; a TV whose port '
        'closes in standby gives no reading, and none ever reads "off".',
  ),
  CapabilitySupport.yes(
    Capability.volume,
    note: 'VOLM sets and reads an absolute level (0-60 or 0-100 by model).',
  ),
  CapabilitySupport.yes(Capability.mute, note: 'MUTE1, MUTE2 and MUTE?.'),
  CapabilitySupport.yes(
    Capability.dpadNavigation,
    note: 'Arrow and ENTER remote keys (US 2011 and later).',
  ),
  CapabilitySupport.partial(
    Capability.systemKeys,
    note:
        'MENU, RETURN, EXIT, DISPLAY, CC and the colour keys; home opens '
        'SmartCentral/APPS; no guide or search key.',
  ),
  CapabilitySupport.no(
    Capability.textInput,
    note:
        'Not over the IP-control port. Only the UPnP service on port 12346 '
        'types text, which this driver does not use.',
  ),
  CapabilitySupport.partial(
    Capability.appList,
    note: 'No app list command: Netflix (its remote key) is the only app.',
  ),
  CapabilitySupport.partial(
    Capability.appLaunch,
    note:
        'Netflix only, through its remote key, which can also turn the TV '
        'on: refused unless the TV reads as on.',
  ),
  CapabilitySupport.yes(
    Capability.inputSwitch,
    note:
        'Discrete input commands from a fixed per-model list; IAVD? reads '
        'the input except when the tuner or an app is in front.',
  ),
  CapabilitySupport.yes(
    Capability.channel,
    note: 'Direct tuning and channel up/down on sets with a tuner.',
  ),
  CapabilitySupport.partial(
    Capability.mediaTransport,
    note:
        'Transport remote keys for HDMI-CEC devices and USB media; no '
        'play/pause toggle and no seek.',
  ),
  CapabilitySupport.no(
    Capability.nowPlaying,
    note: 'The protocol reads no title or app.',
  ),
  CapabilitySupport.no(Capability.pointer),
  CapabilitySupport.no(Capability.notificationToast),
  CapabilitySupport.no(Capability.screenshot),
  CapabilitySupport.no(
    Capability.castMediaUrl,
    note: "The TV's DLNA renderer belongs to a separate UPnP driver.",
  ),
];

/// The capabilities for a TV with [profile].
///
/// [powerStateSeen]: `POWR?` has answered `0` or `1`, which proves the
/// readback works (`yes`); before that it is `partial`. [volumeCertain]
/// and [volumeMax] describe the volume scale in use.
List<CapabilitySupport> sharpCapabilities(
  SharpProfile profile, {
  bool powerStateSeen = false,
  bool volumeCertain = true,
  int? volumeMax,
}) {
  final keys = profile.rcky;
  bool hasKeys(Iterable<int> codes) => codes.every(keys.contains);
  final max = volumeMax ?? profile.volumeMax;
  final caps = <CapabilitySupport>[
    if (profile == SharpProfile.us2015Limited)
      const CapabilitySupport.partial(
        Capability.powerOff,
        flags: {CapFlag.undocumented},
        note: 'POWR0; untested on this firmware.',
      )
    else
      sharpCeiling.supportFor(Capability.powerOff),
    if (!profile.powerOn)
      const CapabilitySupport.no(
        Capability.powerOn,
        note:
            'The EU 2011-2013 manuals list no power-on command; use '
            'Wake-on-LAN, HDMI-CEC or IR.',
      )
    else
      CapabilitySupport.partial(
        Capability.powerOn,
        flags: {
          ..._networkPowerOn,
          if (profile == SharpProfile.jp ||
              profile == SharpProfile.us2015Limited)
            CapFlag.undocumented,
        },
        note: switch (profile) {
          SharpProfile.us2010 || SharpProfile.us2011 =>
            'POWR1 from standby needs the power-on command setting '
                '(RSPW) to accept IP; watchme sets it only with your '
                'consent while pairing.',
          SharpProfile.us2014 =>
            'POWR1 from standby needs Quick Start Mode = On (Menu > Setup) '
                'and the power-on command setting (RSPW).',
          SharpProfile.us4tb =>
            'POWR1 from standby needs Quick Start Mode = On; otherwise use '
                'Wake-on-LAN with Wake on Wi-Fi/LAN enabled.',
          SharpProfile.jp =>
            'POWR1 (not in the JP manuals; field reports) from standby '
                'needs Quick Start set to always on.',
          _ => 'POWR1 answered OK on this firmware; from standby untested.',
        },
      ),
    if (!profile.queries)
      const CapabilitySupport.no(
        Capability.powerState,
        note: 'This firmware answers ERR to every query.',
      )
    else if (powerStateSeen)
      const CapabilitySupport.yes(
        Capability.powerState,
        note: 'POWR? answers on or standby while the TV listens.',
      )
    else
      const CapabilitySupport.partial(
        Capability.powerState,
        note: 'Readback only while network standby is on.',
      ),
    if (profile.absoluteVolume)
      CapabilitySupport.yes(
        Capability.volume,
        note: volumeCertain
            ? 'VOLM 0-$max, set and read.'
            : 'VOLM 0-$max assumed: the scale of this model is not known '
                  'for sure, so levels err on the quiet side.',
      )
    else if (hasKeys(const [32, 33]))
      const CapabilitySupport.partial(
        Capability.volume,
        flags: {CapFlag.relativeOnly, CapFlag.writeOnly},
        note: 'VOL+ and VOL- keys only; this firmware refuses VOLM.',
      )
    else
      const CapabilitySupport.no(Capability.volume),
    if (profile.discreteMute)
      sharpCeiling.supportFor(Capability.mute)
    else
      const CapabilitySupport.partial(
        Capability.mute,
        flags: {CapFlag.toggleOnly, CapFlag.writeOnly},
        note: 'Only the MUTE0 toggle; this firmware refuses MUTE1/MUTE2/MUTE?.',
      ),
    if (hasKeys(const [40, 41, 42, 43, 44]))
      sharpCeiling.supportFor(Capability.dpadNavigation)
    else
      const CapabilitySupport.no(
        Capability.dpadNavigation,
        note: 'This model has no remote-key command (RCKY).',
      ),
    if (hasKeys(const [38, 45, 46]))
      sharpCeiling.supportFor(Capability.systemKeys)
    else
      const CapabilitySupport.no(
        Capability.systemKeys,
        note: 'This model has no remote-key command (RCKY).',
      ),
    sharpCeiling.supportFor(Capability.textInput),
    if (keys.contains(sharpNetflixKey)) ...[
      sharpCeiling.supportFor(Capability.appList),
      sharpCeiling.supportFor(Capability.appLaunch),
    ] else ...const [
      CapabilitySupport.no(
        Capability.appList,
        note: 'No app list command and no NETFLIX key on this model.',
      ),
      CapabilitySupport.no(
        Capability.appLaunch,
        note: 'No app launch command and no NETFLIX key on this model.',
      ),
    ],
    if (profile.inputs.isEmpty)
      const CapabilitySupport.no(
        Capability.inputSwitch,
        note:
            'This firmware is believed to refuse IAVD (unverified); use the '
            'INPUT key.',
      )
    else
      CapabilitySupport.yes(
        Capability.inputSwitch,
        note:
            'Inputs: ${profile.inputs.keys.join(', ')}. IAVD? reads the '
            'input except when the tuner or an app is in front.',
      ),
    switch (profile.channels) {
      SharpChannels.us when profile == SharpProfile.us2010 =>
        const CapabilitySupport.partial(
          Capability.channel,
          flags: {CapFlag.undocumented},
          note:
              'The tuning commands are documented from the 2011 manuals on '
              'and untested on 2010 sets.',
        ),
      SharpChannels.us => const CapabilitySupport.yes(
        Capability.channel,
        note:
            'Direct tuning (7, 7.1, 123.45, 5-digit cable) and channel '
            'up/down.',
      ),
      SharpChannels.eu => const CapabilitySupport.yes(
        Capability.channel,
        note: 'Digital channels 1-999 (DTVD) and channel up/down.',
      ),
      SharpChannels.upDown => const CapabilitySupport.partial(
        Capability.channel,
        note: 'Channel up/down only; direct tuning is not mapped.',
      ),
      SharpChannels.keys => const CapabilitySupport.partial(
        Capability.channel,
        flags: {CapFlag.writeOnly},
        note: 'CH up/down keys only.',
      ),
    },
    if (hasKeys(const [15, 16, 17, 18, 20]))
      sharpCeiling.supportFor(Capability.mediaTransport)
    else
      const CapabilitySupport.no(
        Capability.mediaTransport,
        note: 'This model has no transport remote keys.',
      ),
    for (final c in const [
      Capability.nowPlaying,
      Capability.pointer,
      Capability.notificationToast,
      Capability.screenshot,
      Capability.castMediaUrl,
    ])
      sharpCeiling.supportFor(c),
  ];
  return List.unmodifiable(caps);
}
