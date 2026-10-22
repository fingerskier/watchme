import 'dart:convert';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_driver_vizio/watchme_driver_vizio.dart';

void main() {
  group('descriptor', () {
    test('identity, ports, pairing and backend', () {
      final d = VizioDriver().descriptor;
      expect(d, same(vizioDescriptor));
      expect(d.id, 'vizio.smartcast');
      expect(d.vendor, 'VIZIO');
      expect(d.stability, Stability.communityStandard);
      expect(d.requiresPairing, isTrue);
      expect(d.ports, {'api': 7345, 'legacy': 9000});
      expect(d.backends.single.targets, {DriverTarget.native});
      expect(
        d.backends.single.requires,
        containsAll([
          TransportFeature.customHeaders,
          TransportFeature.nonSimpleMethods,
          TransportFeature.tlsAcceptSelfSigned,
          TransportFeature.tlsPeerCertificate,
        ]),
      );
      // Round-trips through JSON, as the hub and the docs matrix use it.
      expect(DriverDescriptor.fromJson(d.toJson()), d);
    });

    test('provenance names the references and the licences', () {
      final p = vizioDescriptor.provenance;
      for (final ref in [
        'vizaio (MIT)',
        'pyvizio (MIT)',
        'heathbar/vizio-smart-cast (MIT)',
        'Home Assistant vizio integration (Apache-2.0)',
        'exiva/Vizio_SmartCast_API (no licence)',
        'No code was copied',
      ]) {
        expect(p, contains(ref));
      }
    });

    test('the ceiling covers every capability, truthfully', () {
      final c = vizioDescriptor.ceiling.toCapabilityMap();
      expect(c.keys.toSet(), Capability.values.toSet());
      expect(c[Capability.powerOff]!.level, Support.yes);
      expect(c[Capability.powerOn]!.level, Support.partial);
      expect(
        c[Capability.powerOn]!.flags,
        contains(CapFlag.needsNetworkStandby),
      );
      expect(c[Capability.powerState]!.level, Support.yes);
      // Power is discrete both ways: nothing may be a toggle.
      for (final s in c.values) {
        expect(s.flags, isNot(contains(CapFlag.toggleOnly)), reason: '$s');
      }
      // Absolute volume with readback.
      expect(
        c[Capability.volume]!.flags,
        isNot(contains(CapFlag.relativeOnly)),
      );
      expect(c[Capability.volume]!.flags, isNot(contains(CapFlag.writeOnly)));
      // No cloud catalog is used, so nothing claims the cloud.
      for (final s in c.values) {
        expect(s.flags, isNot(contains(CapFlag.cloud)), reason: '$s');
      }
      expect(
        c[Capability.textInput]!.flags,
        contains(CapFlag.needsKeyboardOpen),
      );
      for (final cap in [
        Capability.pointer,
        Capability.notificationToast,
        Capability.screenshot,
        Capability.castMediaUrl,
      ]) {
        expect(c[cap]!.level, Support.no, reason: '$cap');
      }
      for (final s in c.values.where((s) => s.usable)) {
        expect(s.flags, contains(CapFlag.undocumented), reason: '$s');
      }
    });

    test('matchers take a _viziocast._tcp record and a VIZIO DIAL '
        'description', () {
      final matchers = vizioDescriptor.matchers;
      bool matches(DiscoveryHit hit) => matchers.any((m) => m.matches(hit));
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.9',
            provider: DiscoveryProviderId.mdns,
            serviceType: '_viziocast._tcp.local.',
          ),
        ),
        isTrue,
      );
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.9',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'urn:dial-multiscreen-org:device:dial:1',
            attributes: {DiscoveryAttr.manufacturer: 'VIZIO'},
          ),
        ),
        isTrue,
      );
      expect(
        matches(
          const DiscoveryHit(
            host: '10.0.0.9',
            provider: DiscoveryProviderId.ssdp,
            serviceType: 'urn:dial-multiscreen-org:device:dial:1',
            attributes: {DiscoveryAttr.manufacturer: 'Amazon'},
          ),
        ),
        isFalse,
      );
      // No matcher fills a port from the hit: the SRV and DIAL ports are
      // not the REST API.
      expect(matchers.every((m) => m.portName == null), isTrue);
    });

    test('a setup step explains Quick Start', () {
      final step = vizioDescriptor.userSetup.single;
      expect(step.id, 'vizio.quickStart');
      expect(step.detail, contains('Eco'));
    });
  });

  group('keys (brief §12 vectors)', () {
    String body(List<VizioKey> keys) => jsonEncode(vizioKeyListBody(keys));

    test('KEYLIST bodies are byte-exact', () {
      expect(
        body([vizioKeys[RemoteKey.powerOff]!]),
        '{"KEYLIST":[{"CODESET":11,"CODE":0,"ACTION":"KEYPRESS"}]}',
      );
      expect(
        body([vizioKeys[RemoteKey.powerOn]!]),
        '{"KEYLIST":[{"CODESET":11,"CODE":1,"ACTION":"KEYPRESS"}]}',
      );
      expect(
        body([vizioKeys[RemoteKey.mute]!]),
        '{"KEYLIST":[{"CODESET":5,"CODE":4,"ACTION":"KEYPRESS"}]}',
      );
      expect(
        body([vizioKeys[RemoteKey.select]!]),
        '{"KEYLIST":[{"CODESET":3,"CODE":2,"ACTION":"KEYPRESS"}]}',
      );
      expect(
        body(vizioTextKeys('Hi')!),
        '{"KEYLIST":[{"CODESET":0,"CODE":72,"ACTION":"KEYPRESS"},'
        '{"CODESET":0,"CODE":105,"ACTION":"KEYPRESS"}]}',
      );
      expect(
        body(List.filled(3, vizioKeys[RemoteKey.volumeUp]!)),
        '{"KEYLIST":[{"CODESET":5,"CODE":1,"ACTION":"KEYPRESS"},'
        '{"CODESET":5,"CODE":1,"ACTION":"KEYPRESS"},'
        '{"CODESET":5,"CODE":1,"ACTION":"KEYPRESS"}]}',
      );
    });

    test('the cross-checked codes', () {
      expect(vizioKeys[RemoteKey.up], (codeset: 3, code: 8));
      expect(vizioKeys[RemoteKey.down], (codeset: 3, code: 0));
      expect(vizioKeys[RemoteKey.left], (codeset: 3, code: 1));
      expect(vizioKeys[RemoteKey.right], (codeset: 3, code: 7));
      expect(vizioKeys[RemoteKey.back], (codeset: 4, code: 0));
      expect(vizioKeys[RemoteKey.menu], (codeset: 4, code: 8));
      expect(vizioKeys[RemoteKey.info], (codeset: 4, code: 6));
      expect(vizioKeys[RemoteKey.exit], (codeset: 9, code: 0));
      expect(vizioKeys[RemoteKey.channelUp], (codeset: 8, code: 1));
      expect(vizioKeys[RemoteKey.previousChannel], (codeset: 8, code: 2));
      expect(vizioKeys[RemoteKey.input], (codeset: 7, code: 1));
      expect(vizioKeys[RemoteKey.play], (codeset: 2, code: 3));
      expect(vizioKeys[RemoteKey.pause], (codeset: 2, code: 2));
      // Digits are ASCII '0'-'9' in codeset 0, not codes 0-9.
      for (var i = 0; i < 10; i++) {
        expect(vizioKeys[RemoteKey.digits[i]], (codeset: 0, code: 48 + i));
      }
    });

    test('the toggle and doubtful codes are not mapped', () {
      expect(vizioKeys.values, isNot(contains(vizioPowerToggleKey)));
      expect(vizioKeys[RemoteKey.power], isNull);
      expect(vizioKeys[RemoteKey.playPause], isNull);
      expect(vizioKeys[RemoteKey.guide], isNull);
      // Home is the SmartCast key, which every reference agrees on.
      expect(vizioKeys[RemoteKey.home], (codeset: 4, code: 3));
    });

    test('text is printable ASCII only', () {
      expect(vizioTextKeys('a 7'), [
        (codeset: 0, code: 97),
        (codeset: 0, code: 32),
        (codeset: 0, code: 55),
      ]);
      expect(vizioTextKeys('café'), isNull);
      expect(vizioTextKeys('a\nb'), isNull);
    });
  });

  group('apps', () {
    test('launch payloads are the verified ones', () {
      Map<String, Object?> body(String id) =>
          vizioApps.singleWhere((a) => a.id == id).launchBody;
      expect(
        jsonEncode(body('netflix')),
        '{"VALUE":{"APP_ID":"1","NAME_SPACE":3,"MESSAGE":null}}',
      );
      expect(
        jsonEncode(body('youtube')),
        '{"VALUE":{"APP_ID":"1","NAME_SPACE":5,"MESSAGE":null}}',
      );
      expect(
        jsonEncode(body('smartcast-home')),
        '{"VALUE":{"APP_ID":"1","NAME_SPACE":4,'
        '"MESSAGE":"http://127.0.0.1:12345/scfs/sctv/main.html"}}',
      );
    });

    test('the raw-URL launcher is not in the table', () {
      expect(vizioApps.where((a) => a.appId == '3001'), isEmpty);
    });

    test('name spaces 2 and 4 match each other, others do not', () {
      final home = vizioApps.singleWhere((a) => a.id == 'smartcast-home');
      expect(home.matches(4, '1'), isTrue);
      expect(home.matches(2, '1'), isTrue);
      expect(home.matches(3, '1'), isFalse);
      final netflix = vizioApps.singleWhere((a) => a.id == 'netflix');
      expect(netflix.matches(3, '1'), isTrue);
      expect(netflix.matches(2, '1'), isFalse);
    });
  });

  group('port candidates', () {
    test('7345 then 9000 by default', () {
      expect(vizioPortCandidates(const Endpoint('10.0.0.9')), [7345, 9000]);
    });

    test('a remembered port or a TXT hsp hint goes first', () {
      expect(vizioPortCandidates(const Endpoint('10.0.0.9'), first: 9000), [
        9000,
        7345,
      ]);
      expect(
        vizioPortCandidates(
          const Endpoint(
            '10.0.0.9',
            attributes: {
              DiscoveryAttr.mdnsService: '_viziocast._tcp',
              'hsp': '7345',
              'hp': '7346',
            },
          ),
        ),
        [7345, 9000],
      );
      // The hint is read only from a VIZIO record.
      expect(
        vizioPortCandidates(
          const Endpoint(
            '10.0.0.9',
            attributes: {
              DiscoveryAttr.mdnsService: '_googlecast._tcp',
              'hsp': '1234',
            },
          ),
        ),
        [7345, 9000],
      );
    });

    test('explicit ports win over hints', () {
      expect(
        vizioPortCandidates(
          const Endpoint('127.0.0.1', ports: {'api': 40001, 'legacy': 40002}),
          first: 9000,
        ),
        [40001, 40002],
      );
    });
  });
}
