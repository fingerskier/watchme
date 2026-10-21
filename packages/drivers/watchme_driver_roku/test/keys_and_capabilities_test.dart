import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_roku/watchme_driver_roku.dart';

import 'support/fixtures.dart';

void main() {
  group('rokuKeyNames', () {
    test('every mapped name is an ECP key', () {
      for (final name in rokuKeyNames.values) {
        expect(rokuEcpKeyNames, contains(name));
      }
    });

    test('covers the documented Roku remote and TV keys', () {
      const documented = {
        'Home', 'Rev', 'Fwd', 'Play', 'Select', 'Left', 'Right', 'Down', //
        'Up', 'Back', 'InstantReplay', 'Info', 'Backspace', 'Search',
        'Enter', 'VolumeDown', 'VolumeMute', 'VolumeUp', 'PowerOff',
        'PowerOn', 'ChannelUp', 'ChannelDown', 'InputTuner', 'InputHDMI1',
        'InputHDMI2', 'InputHDMI3', 'InputHDMI4', 'InputAV1',
      };
      expect(rokuKeyNames.values.toSet(), containsAll(documented));
    });

    test('keys Roku lacks are unmapped', () {
      for (final key in [
        RemoteKey.guide,
        RemoteKey.exit,
        RemoteKey.settings,
        RemoteKey.captions,
        RemoteKey.red,
        RemoteKey.digit5,
        RemoteKey.stop,
        RemoteKey.next,
        RemoteKey.record,
        RemoteKey.previousChannel,
        RemoteKey.input,
      ]) {
        expect(rokuKeyNames[key], isNull, reason: key.name);
      }
    });

    test('verbs', () {
      expect(rokuKeyVerb(KeyAction.click), 'keypress');
      expect(rokuKeyVerb(KeyAction.down), 'keydown');
      expect(rokuKeyVerb(KeyAction.up), 'keyup');
    });
  });

  group('Lit_ encoding', () {
    String lit(String c) => rokuLiteralKey(c.runes.single);

    test('unreserved ASCII stays literal', () {
      expect(lit('a'), 'Lit_a');
      expect(lit('Z'), 'Lit_Z');
      expect(lit('7'), 'Lit_7');
      expect(lit('-'), 'Lit_-');
      expect(lit('~'), 'Lit_~');
    });

    test('everything else is percent-encoded UTF-8', () {
      expect(lit(' '), 'Lit_%20');
      expect(lit('/'), 'Lit_%2F');
      expect(lit('+'), 'Lit_%2B');
      expect(lit('%'), 'Lit_%25');
      expect(lit('?'), 'Lit_%3F');
      expect(lit('#'), 'Lit_%23');
      expect(lit("'"), 'Lit_%27');
      expect(lit('€'), 'Lit_%E2%82%AC');
      expect(lit('é'), 'Lit_%C3%A9');
      expect(lit('😀'), 'Lit_%F0%9F%98%80');
    });

    test('one key per code point, not per UTF-16 unit', () {
      expect(rokuLiteralKeys('a😀b'), ['Lit_a', 'Lit_%F0%9F%98%80', 'Lit_b']);
      expect(rokuLiteralKeys(''), isEmpty);
    });
  });

  test('input ids', () {
    expect(rokuInputKey('hdmi1'), 'InputHDMI1');
    expect(rokuInputKey('HDMI4'), 'InputHDMI4');
    expect(rokuInputKey('tvinput.hdmi2'), 'InputHDMI2');
    expect(rokuInputKey('tuner'), 'InputTuner');
    expect(rokuInputKey('tvinput.dtv'), 'InputTuner');
    expect(rokuInputKey('av1'), 'InputAV1');
    expect(rokuInputKey('tvinput.cvbs'), 'InputAV1');
    expect(rokuInputKey('hdmi9'), isNull);
    expect(rokuInputIdForApp('tvinput.hdmi3'), 'hdmi3');
    expect(rokuInputIdForApp('tvinput.dtv'), 'tuner');
    expect(rokuInputIdForApp('tvinput.cvbs'), 'av1');
    expect(rokuInputIdForApp('tvinput.foo'), 'tvinput.foo');
  });

  test('IP literal check and Host header', () {
    expect(isIpLiteral('192.0.2.10'), isTrue);
    expect(isIpLiteral('::1'), isTrue);
    expect(isIpLiteral('[fe80::1]'), isTrue);
    expect(isIpLiteral('roku.local'), isFalse);
    expect(isIpLiteral('living-room-tv'), isFalse);
    expect(isIpLiteral('999.1.1.1'), isFalse);
    expect(isIpLiteral('10.0.0'), isFalse);
    expect(hostHeader(Uri.parse('http://192.0.2.10:8060/')), '192.0.2.10:8060');
    expect(hostHeader(Uri.parse('http://[::1]:51234/')), '[::1]:51234');
  });

  group('capabilities', () {
    final tv = RokuDeviceInfo.parse(tclTvDeviceInfo);
    final player = RokuDeviceInfo.parse(expressPlayerDeviceInfo);

    test('the ceiling covers every capability once', () {
      expect(
        rokuCeiling.map((c) => c.capability).toSet(),
        Capability.values.toSet(),
      );
      expect(rokuCeiling, hasLength(Capability.values.length));
      expect(rokuDescriptor.ceiling, rokuCeiling);
    });

    test('ceiling marks the access-gated capabilities', () {
      final keys = rokuCeiling.supportFor(Capability.dpadNavigation);
      expect(keys.has(CapFlag.userSetupRequired), isTrue);
      expect(
        rokuCeiling
            .supportFor(Capability.powerState)
            .has(CapFlag.userSetupRequired),
        isFalse,
      );
      final volume = rokuCeiling.supportFor(Capability.volume);
      expect(volume.flags, containsAll({CapFlag.relativeOnly}));
      expect(
        rokuCeiling.supportFor(Capability.powerOn).flags,
        containsAll({CapFlag.needsNetworkStandby, CapFlag.undocumented}),
      );
    });

    test('Enabled TV: everything the ceiling has, no setup flags', () {
      final caps = rokuCapabilities(tv, RokuEcpAccess.enabled);
      for (final c in caps) {
        expect(c.has(CapFlag.userSetupRequired), isFalse, reason: '$c');
        expect(
          c.level,
          rokuCeiling.supportFor(c.capability).level,
          reason: '$c',
        );
      }
      expect(caps.supportFor(Capability.inputSwitch).level, Support.yes);
      expect(caps.supportFor(Capability.channel).level, Support.yes);
    });

    test('players lose inputs and tuner, and follow the CEC fields', () {
      final caps = rokuCapabilities(player, RokuEcpAccess.enabled);
      expect(caps.supportFor(Capability.inputSwitch).level, Support.no);
      expect(caps.supportFor(Capability.channel).level, Support.no);
      expect(caps.supportFor(Capability.powerOff).level, Support.partial);
      // supports-audio-volume-control is false on this player.
      expect(caps.supportFor(Capability.volume).level, Support.no);
      expect(caps.supportFor(Capability.mute).level, Support.no);
      expect(caps.supportFor(Capability.powerState).level, Support.partial);
      expect(caps.supportFor(Capability.dpadNavigation).level, Support.yes);
    });

    test('Limited: keys refused with a setup flag, state still readable', () {
      final caps = rokuCapabilities(tv, RokuEcpAccess.limited);
      final keys = caps.supportFor(Capability.dpadNavigation);
      expect(keys.level, Support.no);
      expect(keys.has(CapFlag.userSetupRequired), isTrue);
      expect(keys.note, contains('Control by mobile apps'));
      expect(caps.supportFor(Capability.textInput).level, Support.no);
      expect(caps.supportFor(Capability.appList).level, Support.no);
      expect(caps.supportFor(Capability.powerState).level, Support.yes);
      final now = caps.supportFor(Capability.nowPlaying);
      expect(now.level, Support.partial);
      expect(now.has(CapFlag.userSetupRequired), isTrue);
      expect(caps.supportFor(Capability.appLaunch).level, Support.partial);
      // Never-supported capabilities stay plain "no".
      expect(
        caps.supportFor(Capability.pointer).has(CapFlag.userSetupRequired),
        isFalse,
      );
    });

    test('Disabled without device-info: nothing usable', () {
      final caps = rokuCapabilities(null, RokuEcpAccess.disabled);
      expect(caps.where((c) => c.usable), isEmpty);
      expect(
        caps.supportFor(Capability.powerState).has(CapFlag.userSetupRequired),
        isTrue,
      );
    });

    test('Unknown keeps the ceiling flags as a warning', () {
      final caps = rokuCapabilities(tv, RokuEcpAccess.unknown);
      expect(caps, rokuCeiling);
    });
  });
}
