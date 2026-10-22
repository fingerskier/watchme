import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_sharp/watchme_driver_sharp.dart';

String _hex(String frame) =>
    [for (final b in ascii.encode(frame)) b.toRadixString(16).padLeft(2, '0')]
        .join(' ');

void _expectReplies(String text, List<String> replies, String pending) {
  final parsed = parseSharpReplies(text);
  expect(parsed.replies, replies, reason: text);
  expect(parsed.pending, pending, reason: text);
}

void main() {
  group('frames (brief section 12 vectors)', () {
    const vectors = {
      'POWR1   \r': '50 4f 57 52 31 20 20 20 0d',
      'POWR0   \r': '50 4f 57 52 30 20 20 20 0d',
      'POWR?   \r': '50 4f 57 52 3f 20 20 20 0d',
      'RSPW2   \r': '52 53 50 57 32 20 20 20 0d',
      'IAVD2   \r': '49 41 56 44 32 20 20 20 0d',
      'ITVD0   \r': '49 54 56 44 30 20 20 20 0d',
      'VOLM30  \r': '56 4f 4c 4d 33 30 20 20 0d',
      'VOLM5   \r': '56 4f 4c 4d 35 20 20 20 0d',
      'VOLM100 \r': '56 4f 4c 4d 31 30 30 20 0d',
      'MUTE2   \r': '4d 55 54 45 32 20 20 20 0d',
      'RCKY33  \r': '52 43 4b 59 33 33 20 20 0d',
      'RCKY0   \r': '52 43 4b 59 30 20 20 20 0d',
      'MNRD1   \r': '4d 4e 52 44 31 20 20 20 0d',
      'HPOS-30 \r': '48 50 4f 53 2d 33 30 20 0d',
      'ITGD    \r': '49 54 47 44 20 20 20 20 0d',
      'DA2P0701\r': '44 41 32 50 30 37 30 31 0d',
      'DC2L045 \r': '44 43 32 4c 30 34 35 20 0d',
    };

    test('every frame is 4 command characters, 4 parameter characters and '
        'CR', () {
      for (final MapEntry(key: frame, value: hex) in vectors.entries) {
        final built = sharpFrame(
          frame.substring(0, 4),
          frame.substring(4, 8).trimRight(),
        );
        expect(built, frame);
        expect(_hex(built), hex, reason: frame);
      }
    });

    test('queries are ? and three blanks', () {
      expect(sharpQuery('POWR'), 'POWR?   \r');
      expect(sharpQuery('RSPW'), 'RSPW?   \r');
    });

    test('parameters are aligned left, never right', () {
      expect(sharpFrame('RCKY', '12'), 'RCKY12  \r');
      expect(sharpFrame('VOLM', '0030'), 'VOLM0030\r');
    });

    test('refuses malformed commands and parameters', () {
      expect(() => sharpFrame('POW', '1'), throwsArgumentError);
      expect(() => sharpFrame('powr', '1'), throwsArgumentError);
      expect(() => sharpFrame('VOLM', '10000'), throwsArgumentError);
      expect(() => sharpFrame('VOLM', '1\r'), throwsArgumentError);
      expect(() => sharpFrame('VOLM', 'ab'), throwsArgumentError);
    });
  });

  group('reply reader', () {
    test('section 12 vectors', () {
      _expectReplies('OK\r', ['OK'], '');
      _expectReplies('\r\nOK\r', ['OK'], '');
      _expectReplies('\rOK\r', ['OK'], '');
      _expectReplies('1\r', ['1'], '');
      _expectReplies('45\r', ['45'], '');
      _expectReplies('\r\n', <String>[], '');
      _expectReplies('OK', <String>[], 'OK');
      _expectReplies('OK\rERR\r', ['OK', 'ERR'], '');
    });

    test('a reply ends at LF too; padding is trimmed', () {
      _expectReplies('30 \n1', ['30'], '1');
    });

    test('one request takes only the first of two buffered replies', () {
      final buffer = SharpReplyBuffer()..add(ascii.encode('OK\rERR\r'));
      expect(buffer.takeReply(), 'OK');
      expect(buffer.hasReply, isTrue);
      expect(buffer.takeAll(), 'ERR\r');
      expect(buffer.isEmpty, isTrue);
    });

    test('recognises login refusals', () {
      expect(isSharpLoginRefusal('\r\nUser Name or Password mismatch'), isTrue);
      expect(isSharpLoginRefusal('USER NAME OR PASSWORD MISMATCH'), isTrue);
      expect(isSharpLoginRefusal('\r\nLogin:'), isTrue);
      expect(isSharpLoginRefusal('\r\n'), isFalse);
    });
  });

  group('TuneChannel (US)', () {
    List<String>? frames(String ch) =>
        sharpUsTuneRequests(ch)
            ?.map((r) => sharpFrame(r.command, r.parameter))
            .toList();

    test('section 12 vectors', () {
      expect(frames('7'), ['DCCH7   \r']);
      expect(frames('135'), ['DCCH135 \r']);
      expect(frames('7.1'), ['DA2P0701\r']);
      expect(frames('45.3'), ['DA2P4503\r']);
      expect(frames('123.45'), ['DC2U123 \r', 'DC2L045 \r']);
      expect(frames('05678'), ['DC105678\r']);
      expect(frames('12345'), ['DC112345\r']);
      expect(frames('16383'), ['DC116383\r']);
      expect(frames('2.0'), ['DA2P0200\r']);
      expect(frames('99.99'), ['DA2P9999\r']);
      expect(frames('1.100'), ['DC2U1   \r', 'DC2L100 \r']);
    });

    test('ambiguous or out-of-range channels are refused', () {
      for (final ch in [
        '5678',
        '136',
        '100.1000',
        '0',
        '16384',
        '',
        'abc',
        '7.',
        '.1',
        '1000.1',
      ]) {
        expect(sharpUsTuneRequests(ch), isNull, reason: ch);
      }
    });

    test('EU digital channels are 1-999', () {
      expect(sharpEuTuneRequests('101'), [(command: 'DTVD', parameter: '101')]);
      expect(sharpEuTuneRequests('1000'), isNull);
      expect(sharpEuTuneRequests('0'), isNull);
    });
  });

  group('UDN MAC hint', () {
    test('section 12 vectors', () {
      expect(
        sharpMacHintFromUdn('uuid:e94ee5fe-0a78-11e1-b06a-34F62D350D0F'),
        '34:f6:2d:35:0d:0f',
      );
      expect(
        sharpMacHintFromUdn('dbda0c3c-0a78-11e1-9713-34F62D350D0F'),
        '34:f6:2d:35:0d:0f',
      );
      expect(
        sharpMacHintFromUdn('38ea00d5-1c6f-4f38-8e04-d2aae644b525'),
        isNull,
        reason: 'version 4',
      );
    });

    test('a version-1 UDN without a Sharp OUI gives none', () {
      expect(
        sharpMacHintFromUdn('e94ee5fe-0a78-11e1-b06a-001122334455'),
        isNull,
      );
    });
  });

  group('profiles', () {
    test('picks the profile from MNRD1 or a full model number', () {
      final cases = {
        'C6400UA': (SharpProfile.us2011, true),
        'LC-70C6400U': (SharpProfile.us2011, true),
        'LC-60LE830U': (SharpProfile.us2010, true),
        'LE835U': (SharpProfile.us2010, true),
        'LC-70UD27U': (SharpProfile.us2014, true),
        'LC-60LE650U': (SharpProfile.us2014, false),
        'LC-60LE652U': (SharpProfile.us2011, false),
        'LC-43LE653U': (SharpProfile.us2015Limited, false),
        '4T-B60BN1U': (SharpProfile.us4tb, true),
        'LC-70LE747E': (SharpProfile.eu, true),
        'LC-46LE830E': (SharpProfile.eu, true),
        'LC-40LE999K': (SharpProfile.eu, false),
        'LC-40W35': (SharpProfile.jp, true),
        '4T-C50AH1': (SharpProfile.jp, true),
        'LC-60LE951X': (SharpProfile.us2011, false),
        'LC-60LE999U': (SharpProfile.us2011, false),
      };
      for (final MapEntry(key: model, value: (profile, certain))
          in cases.entries) {
        final match = sharpProfileForModel(model);
        expect(match?.profile, profile, reason: model);
        expect(match?.volumeCertain, certain, reason: model);
      }
    });

    test('the scale to use: the model\'s when certain, else 60', () {
      final scales = {
        'LC-70LE747E': 100, // EU 2013
        'LC-46LE830E': 60, // EU 2011
        'LC-70UD27U': 100,
        'C6400UA': 60,
        'LC-60LE650U': 60, // in doubt: the quiet side
        'LC-40LE999K': 60,
      };
      for (final MapEntry(key: model, value: max) in scales.entries) {
        expect(sharpProfileForModel(model)!.volumeMax, max, reason: model);
      }
    });

    test('nothing known gives null (the session then assumes us2011)', () {
      expect(sharpProfileForModel(null), isNull);
      expect(sharpProfileForModel(''), isNull);
      expect(sharpProfileForModel('AQUOS'), isNull);
    });

    test('profiles round-trip by id', () {
      for (final p in SharpProfile.values) {
        expect(SharpProfile.byId(p.id), p);
      }
      expect(SharpProfile.byId('US2014'), SharpProfile.us2014);
      expect(SharpProfile.byId('nope'), isNull);
    });

    test('volume scales and input numbering follow the manuals', () {
      expect(SharpProfile.us2010.volumeMax, 60);
      expect(SharpProfile.us2011.volumeMax, 60);
      expect(SharpProfile.us2014.volumeMax, 100);
      expect(SharpProfile.us4tb.volumeMax, 100);
      expect(SharpProfile.us2010.inputs.containsKey('pc'), isFalse);
      expect(SharpProfile.us2011.inputs['pc']!.iavd, 8);
      expect(SharpProfile.eu.inputs['hdmi1']!.iavd, 4);
      expect(SharpProfile.us4tb.inputForIavd(0), 'tv');
      expect(SharpProfile.eu.inputs['tv']!.parameter, '');
      expect(SharpProfile.us2011.noArgument, '0');
      expect(SharpProfile.us4tb.noArgument, '');
    });
  });

  group('keys', () {
    test('every mapped key has a code in the 2014 or 2011 table', () {
      for (final MapEntry(:key, :value) in sharpKeyCodes.entries) {
        expect(
          SharpProfile.us2011.rcky.contains(value) ||
              SharpProfile.us2014.rcky.contains(value),
          isTrue,
          reason: key.name,
        );
      }
    });

    test('keys with no Sharp code are absent', () {
      for (final key in [
        RemoteKey.guide,
        RemoteKey.search,
        RemoteKey.playPause,
        RemoteKey.backspace,
        RemoteKey.enter,
        RemoteKey.instantReplay,
      ]) {
        expect(sharpKeyCodes.containsKey(key), isFalse, reason: key.name);
      }
    });

    test('the wake keys are POWER and NETFLIX', () {
      expect(sharpWakeKeys, {12, 59});
      expect(sharpKeyCodes[RemoteKey.power], 12);
    });
  });

  group('capabilities', () {
    test('no power route is toggle-only, on any profile', () {
      for (final p in SharpProfile.values) {
        final caps = sharpCapabilities(p, powerStateSeen: true);
        for (final c in [Capability.powerOn, Capability.powerOff]) {
          expect(
            caps.supportFor(c).has(CapFlag.toggleOnly),
            isFalse,
            reason: '${p.id} ${c.name}',
          );
        }
      }
    });

    test('power-on needs network standby; EU sets have none', () {
      final on = sharpCapabilities(SharpProfile.us2011)
          .supportFor(Capability.powerOn);
      expect(on.level, Support.partial);
      expect(on.flags, {
        CapFlag.needsNetworkStandby,
        CapFlag.userSetupRequired,
      });
      expect(
        sharpCapabilities(SharpProfile.eu).supportFor(Capability.powerOn).level,
        Support.no,
      );
    });

    test('power state is yes only once POWR? answered; never on 2015', () {
      expect(
        sharpCapabilities(SharpProfile.us2014)
            .supportFor(Capability.powerState)
            .level,
        Support.partial,
      );
      expect(
        sharpCapabilities(
          SharpProfile.us2014,
          powerStateSeen: true,
        ).supportFor(Capability.powerState).level,
        Support.yes,
      );
      expect(
        sharpCapabilities(
          SharpProfile.us2015Limited,
          powerStateSeen: true,
        ).supportFor(Capability.powerState).level,
        Support.no,
      );
    });

    test('the 2015 firmware is write-only', () {
      final caps = sharpCapabilities(SharpProfile.us2015Limited);
      expect(caps.supportFor(Capability.volume).flags, {
        CapFlag.relativeOnly,
        CapFlag.writeOnly,
      });
      expect(caps.supportFor(Capability.mute).flags, {
        CapFlag.toggleOnly,
        CapFlag.writeOnly,
      });
      expect(caps.supportFor(Capability.inputSwitch).level, Support.no);
    });

    test('models without remote keys have no d-pad, apps or transport', () {
      for (final p in [SharpProfile.us2010, SharpProfile.eu, SharpProfile.jp]) {
        final caps = sharpCapabilities(p);
        for (final c in [
          Capability.dpadNavigation,
          Capability.systemKeys,
          Capability.appLaunch,
          Capability.appList,
          Capability.mediaTransport,
        ]) {
          expect(caps.supportFor(c).level, Support.no, reason: '${p.id} $c');
        }
      }
    });

    test('every profile lists every capability once', () {
      for (final p in SharpProfile.values) {
        final caps = sharpCapabilities(p);
        expect(
          caps.map((c) => c.capability).toSet(),
          Capability.values.toSet(),
          reason: p.id,
        );
        expect(caps, hasLength(Capability.values.length), reason: p.id);
      }
    });

    test('an uncertain volume scale says so', () {
      final caps = sharpCapabilities(SharpProfile.us2011, volumeCertain: false);
      expect(caps.supportFor(Capability.volume).note, contains('assumed'));
    });
  });
}
