import 'package:watchme_core/watchme_core.dart';

import 'ecp_xml.dart';

const _setup = CapFlag.userSetupRequired;

/// What the text shown for capabilities refused by the access setting says
/// to do.
const String rokuEnableHint =
    'Set Settings > System > Advanced system settings > Control by mobile '
    'apps to Enabled on the Roku.';

/// The most Roku ECP over HTTP can do. Capabilities that Roku OS 14.1+
/// refuses unless "Control by mobile apps" is Enabled carry
/// [CapFlag.userSetupRequired]; [rokuCapabilities] drops the flag once the
/// setting is known to be Enabled.
const List<CapabilitySupport> rokuCeiling = [
  CapabilitySupport.yes(
    Capability.powerOff,
    flags: {_setup},
    note:
        'Discrete PowerOff key on Roku TVs; players reach the TV through '
        'HDMI-CEC. The Power key is a separate toggle with no state, sent '
        'only under the power rules.',
  ),
  CapabilitySupport.partial(
    Capability.powerOn,
    flags: {CapFlag.needsNetworkStandby, CapFlag.undocumented, _setup},
    note:
        'PowerOn key (undocumented but widely used). Works only while the '
        "TV's network is awake (Fast TV Start, or about 10 minutes after "
        'power-off); otherwise use Wake-on-LAN.',
  ),
  CapabilitySupport.yes(
    Capability.powerState,
    note:
        'device-info power-mode: PowerOn, DisplayOff, Ready (standby); no '
        'answer means off or deep sleep.',
  ),
  CapabilitySupport.partial(
    Capability.volume,
    flags: {CapFlag.relativeOnly, CapFlag.writeOnly, _setup},
    note: 'VolumeUp/VolumeDown keys only; no absolute level or readback.',
  ),
  CapabilitySupport.partial(
    Capability.mute,
    flags: {CapFlag.toggleOnly, CapFlag.writeOnly, _setup},
    note: 'VolumeMute toggles; the mute state cannot be read.',
  ),
  CapabilitySupport.yes(Capability.dpadNavigation, flags: {_setup}),
  CapabilitySupport.yes(
    Capability.systemKeys,
    flags: {_setup},
    note: 'Home, Back, Info (options), Search, InstantReplay; no Settings key.',
  ),
  CapabilitySupport.yes(
    Capability.textInput,
    flags: {CapFlag.needsKeyboardOpen, _setup},
    note: 'Lit_ key presses, one per character, while a keyboard is shown.',
  ),
  CapabilitySupport.yes(
    Capability.appList,
    flags: {_setup},
    note:
        'query/apps (no longer in the ECP doc table, but served and used '
        'by every maintained library).',
  ),
  CapabilitySupport.yes(
    Capability.appLaunch,
    flags: {_setup},
    note: 'launch/<id>, with contentId and mediaType deep-link parameters.',
  ),
  CapabilitySupport.yes(
    Capability.inputSwitch,
    flags: {_setup},
    note: 'Roku TVs only: InputHDMI1-4, InputAV1, InputTuner.',
  ),
  CapabilitySupport.yes(
    Capability.channel,
    flags: {_setup},
    note: 'Roku TVs with a tuner: ChannelUp/ChannelDown and tvinput.dtv?ch=.',
  ),
  CapabilitySupport.partial(
    Capability.mediaTransport,
    flags: {_setup},
    note: 'Play (play/pause toggle), Rev, Fwd, InstantReplay; no seek or stop.',
  ),
  CapabilitySupport.partial(
    Capability.nowPlaying,
    flags: {_setup},
    note:
        'Foreground app, plus playback state and position from query/'
        'media-player; no titles.',
  ),
  CapabilitySupport.no(Capability.pointer, note: 'Roku has no system pointer.'),
  CapabilitySupport.no(
    Capability.notificationToast,
    note: 'ECP has no notification API.',
  ),
  CapabilitySupport.no(
    Capability.screenshot,
    note: 'ECP has no screenshot command.',
  ),
  CapabilitySupport.partial(
    Capability.castMediaUrl,
    flags: {CapFlag.takesOverScreen, _setup},
    note:
        'Through a receiver channel that must be installed (default: Media '
        'Assistant, id 782875); Play on Roku was locked down in Roku OS 11.5.',
  ),
];

/// The capabilities this driver can offer for one device: [rokuCeiling]
/// narrowed by its device-info [info] (players have no inputs or tuner and
/// reach TV power and volume only through HDMI-CEC) and by [access] (the
/// "Control by mobile apps" level).
///
/// With [info] `null` (device-info itself was refused) only [access]
/// applies.
List<CapabilitySupport> rokuCapabilities(
  RokuDeviceInfo? info,
  RokuEcpAccess access,
) => [
  for (final c in rokuCeiling) _forAccess(_forDevice(c, info), access, info),
];

CapabilitySupport _forDevice(CapabilitySupport c, RokuDeviceInfo? info) {
  if (info == null || info.isTv) return c;
  CapabilitySupport cec(bool? supported, String what) => supported == false
      ? CapabilitySupport.no(
          c.capability,
          note: 'This Roku player reports no $what control.',
        )
      : CapabilitySupport.partial(
          c.capability,
          flags: c.flags,
          note:
              '${c.note} On a player this goes through HDMI-CEC '
              '(or the audio device) and works only if the TV accepts it.',
        );
  return switch (c.capability) {
    Capability.inputSwitch => const CapabilitySupport.no(
      Capability.inputSwitch,
      note: 'Roku players have no TV inputs.',
    ),
    Capability.channel => const CapabilitySupport.no(
      Capability.channel,
      note: 'Roku players have no tuner.',
    ),
    Capability.powerOff ||
    Capability.powerOn => cec(info.supportsTvPowerControl, 'TV power'),
    Capability.volume ||
    Capability.mute => cec(info.supportsAudioVolumeControl, 'volume'),
    Capability.powerState => CapabilitySupport.partial(
      Capability.powerState,
      note: "Reports the player's own power mode, not the TV's.",
    ),
    _ => c,
  };
}

CapabilitySupport _forAccess(
  CapabilitySupport c,
  RokuEcpAccess access,
  RokuDeviceInfo? info,
) {
  if (!c.usable) return c;
  switch (access) {
    case RokuEcpAccess.unknown:
      return c;
    case RokuEcpAccess.enabled:
      return c.copyWith(flags: c.flags.difference(const {_setup}));
    case RokuEcpAccess.limited:
      return switch (c.capability) {
        Capability.powerState => c,
        Capability.nowPlaying => CapabilitySupport.partial(
          Capability.nowPlaying,
          flags: {...c.flags, _setup},
          note:
              'Limited mode: only the foreground app; playback state needs '
              'Control by mobile apps = Enabled.',
        ),
        Capability.appLaunch || Capability.castMediaUrl => CapabilitySupport(
          c.capability,
          Support.partial,
          flags: {...c.flags, _setup},
          note:
              'Limited mode may refuse launches (reports disagree). '
              '$rokuEnableHint',
        ),
        _ => _refused(c, 'Refused while Control by mobile apps is Limited.'),
      };
    case RokuEcpAccess.disabled:
      if (c.capability == Capability.powerState && info != null) return c;
      return _refused(c, 'Refused: the Roku does not allow ECP control.');
  }
}

CapabilitySupport _refused(CapabilitySupport c, String why) =>
    CapabilitySupport(
      c.capability,
      Support.no,
      flags: {...c.flags, _setup},
      note: '$why $rokuEnableHint',
    );
