// No dart:io here: these tests also run compiled to JavaScript
// (`dart test -p node test/destination_test.dart`).

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

const privateLan = HostAddressClass.privateLan;
const linkLocal = HostAddressClass.linkLocal;
const loopback = HostAddressClass.loopback;
const cgnat = HostAddressClass.cgnat;
const public = HostAddressClass.public;
const reserved = HostAddressClass.reserved;
const multicast = HostAddressClass.multicast;
const unspecified = HostAddressClass.unspecified;
const broadcast = HostAddressClass.broadcast;
const invalid = HostAddressClass.invalid;

void expectClasses(Map<String, HostAddressClass> table) {
  for (final MapEntry(key: address, value: expected) in table.entries) {
    expect(classifyHostAddress(address), expected, reason: '"$address"');
  }
}

void main() {
  group('classifyHostAddress, IPv4', () {
    test('0.0.0.0/8 is unspecified', () {
      expectClasses({
        '0.0.0.0': unspecified,
        '0.0.0.1': unspecified,
        '0.1.2.3': unspecified,
        '0.255.255.255': unspecified,
        '1.0.0.0': public,
      });
    });

    test('RFC 1918 ranges and their edges', () {
      expectClasses({
        '9.255.255.255': public,
        '10.0.0.0': privateLan,
        '10.0.0.2': privateLan,
        '10.255.255.255': privateLan,
        '11.0.0.0': public,
        '172.15.255.255': public,
        '172.16.0.0': privateLan,
        '172.20.1.1': privateLan,
        '172.31.255.255': privateLan,
        '172.32.0.0': public,
        '192.167.255.255': public,
        '192.168.0.0': privateLan,
        '192.168.1.7': privateLan,
        '192.168.255.255': privateLan,
        '192.169.0.0': public,
      });
    });

    test('100.64.0.0/10 (CGNAT, overlay VPNs) is not the LAN', () {
      expectClasses({
        '100.63.255.255': public,
        '100.64.0.0': cgnat,
        '100.64.1.1': cgnat,
        '100.100.100.100': cgnat,
        '100.127.255.255': cgnat,
        '100.128.0.0': public,
      });
    });

    test('loopback is 127.0.0.0/8', () {
      expectClasses({
        '126.255.255.255': public,
        '127.0.0.0': loopback,
        '127.0.0.1': loopback,
        '127.1.2.3': loopback,
        '127.255.255.255': loopback,
        '128.0.0.0': public,
      });
    });

    test('link-local is 169.254.0.0/16', () {
      expectClasses({
        '169.253.255.255': public,
        '169.254.0.0': linkLocal,
        '169.254.1.1': linkLocal,
        '169.254.255.255': linkLocal,
        '169.255.0.0': public,
      });
    });

    test('special-purpose blocks are reserved', () {
      expectClasses({
        '191.255.255.255': public,
        '192.0.0.0': reserved,
        '192.0.0.9': reserved,
        '192.0.0.255': reserved,
        '192.0.1.0': public,
        '192.0.2.0': reserved,
        '192.0.2.1': reserved,
        '192.0.2.255': reserved,
        '192.0.3.0': public,
        '192.88.99.1': public,
        '198.17.255.255': public,
        '198.18.0.0': reserved,
        '198.19.255.255': reserved,
        '198.20.0.0': public,
        '198.51.99.255': public,
        '198.51.100.0': reserved,
        '198.51.100.255': reserved,
        '198.51.101.0': public,
        '203.0.112.255': public,
        '203.0.113.0': reserved,
        '203.0.113.255': reserved,
        '203.0.114.0': public,
      });
    });

    test('multicast, class E and broadcast', () {
      expectClasses({
        '223.255.255.255': public,
        '224.0.0.0': multicast,
        '224.0.0.251': multicast, // mDNS
        '239.255.255.250': multicast, // SSDP
        '239.255.255.255': multicast,
        '240.0.0.0': reserved,
        '250.1.2.3': reserved,
        '255.255.255.254': reserved,
        '255.255.255.255': broadcast,
      });
    });

    test('public addresses', () {
      expectClasses({
        '1.1.1.1': public,
        '8.8.8.8': public,
        '93.184.216.34': public,
        '101.0.0.1': public,
        '200.1.2.3': public,
      });
    });

    test('a subnet-directed broadcast classifies by its range', () {
      expect(classifyHostAddress('192.168.1.255'), privateLan);
    });
  });

  group('classifyHostAddress, IPv6', () {
    test('unspecified and loopback', () {
      expectClasses({
        '::': unspecified,
        '0:0:0:0:0:0:0:0': unspecified,
        '0000:0000:0000:0000:0000:0000:0000:0000': unspecified,
        '::1': loopback,
        '0:0:0:0:0:0:0:1': loopback,
        '::0:1': loopback,
        '::2': reserved,
        '::1:0': reserved,
      });
    });

    test('link-local is fe80::/10, site-local fec0::/10 is reserved', () {
      expectClasses({
        'fe80::': linkLocal,
        'fe80::1': linkLocal,
        'FE80::1': linkLocal,
        'fe80::1ff:fe23:4567:890a': linkLocal,
        'febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff': linkLocal,
        'fec0::1': reserved,
        'feff::1': reserved,
      });
    });

    test('unique-local fc00::/7 is the LAN', () {
      expectClasses({
        'fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff': public,
        'fc00::': privateLan,
        'fc00::1': privateLan,
        'fd12:3456:789a::1': privateLan,
        'FD00::abcd': privateLan,
        'fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff': privateLan,
      });
    });

    test('multicast is ff00::/8', () {
      expectClasses({
        'ff02::fb': multicast, // mDNS
        'ff02::c': multicast, // SSDP link-local
        'ff05::c': multicast, // SSDP site-local
        'ff0e::1': multicast,
      });
    });

    test('documentation, benchmarking and discard prefixes are reserved', () {
      expectClasses({
        '2001:db8::1': reserved,
        '2001:0db8:ffff:ffff:ffff:ffff:ffff:ffff': reserved,
        '2001:db9::1': public,
        '2001:2::1': reserved,
        '2001:2:0:ffff::1': reserved,
        '2001:2:1::1': public,
        '3fff::1': reserved,
        '3fff:fff::1': reserved,
        '3fff:1000::1': public,
        '100::1': reserved,
        '100::ffff:ffff:ffff:ffff': reserved,
        '100:0:0:1::1': public,
      });
    });

    test('the rest of ::/8 is reserved; NAT64 64:ff9b::/96 is public', () {
      expectClasses({
        '::192.168.1.1': reserved, // IPv4-compatible (deprecated)
        '::c0a8:101': reserved,
        '::ffff:0:192.168.1.1': reserved, // IPv4-translated
        '1::': reserved,
        '64:ff9b::8.8.8.8': public,
        '64:ff9b::192.168.1.1': public, // a NAT64 never leads to the LAN
        '64:ff9b::c0a8:101': public,
        '64:ff9b:1::1': reserved, // local-use NAT64
      });
    });

    test('global unicast and transition prefixes are public', () {
      expectClasses({
        '2001:4860:4860::8888': public,
        '2606:4700:4700::1111': public,
        '2002:c0a8:107::1': public, // 6to4 of 192.168.1.7
        '2001::1': public, // Teredo
        '2a00:1450:4001:80b::200e': public,
      });
    });

    test('every RFC 4291 text form parses', () {
      expectClasses({
        'fd00:1:2:3:4:5:6:7': privateLan,
        'fd00:0:0:0:0:0:0:1': privateLan,
        'fd00::1': privateLan,
        'fd00:1:2:3:4:5:6::': privateLan,
        'fd00::2:3:4:5:6:7': privateLan,
        'fd00:1:2:3:4:5:192.168.1.1': privateLan,
        'fd00::192.168.1.1': privateLan,
        'Fd00:0001:0002::000a': privateLan,
      });
    });
  });

  group('classifyHostAddress, IPv4-mapped IPv6', () {
    test('classifies as the embedded IPv4 address', () {
      expectClasses({
        '::ffff:192.168.1.7': privateLan,
        '::FFFF:192.168.1.7': privateLan,
        '::ffff:c0a8:107': privateLan,
        '::ffff:C0A8:0107': privateLan,
        '0:0:0:0:0:ffff:192.168.1.7': privateLan,
        '0:0:0:0:0:ffff:c0a8:0107': privateLan,
        '::ffff:10.0.0.1': privateLan,
        '::ffff:172.16.0.1': privateLan,
        '::ffff:169.254.1.1': linkLocal,
        '::ffff:127.0.0.1': loopback,
        '::ffff:7f00:1': loopback,
        '::ffff:100.64.0.1': cgnat,
        '::ffff:8.8.8.8': public,
        '::ffff:203.0.113.1': reserved,
        '::ffff:0.0.0.0': unspecified,
        '::ffff:0:0': unspecified,
        '::ffff:224.0.0.251': multicast,
        '::ffff:255.255.255.255': broadcast,
        '::ffff:ffff:ffff': broadcast,
      });
    });
  });

  group('classifyHostAddress, zone ids', () {
    test('a zone id is ignored for classification', () {
      expectClasses({
        'fe80::1%eth0': linkLocal,
        'fe80::1%25eth0': linkLocal, // as Uri.host returns it
        'fe80::1%2': linkLocal,
        'fe80::1%wlp2s0': linkLocal,
        'fe80::1%en0.100': linkLocal,
        'fe80::1%a_b~c-d': linkLocal,
        'ff02::fb%eth0': multicast,
        '::1%lo': loopback,
        '2001:4860::1%eth0': public,
      });
    });

    test('Uri.host of a scoped literal classifies', () {
      final host = Uri.parse('http://[fe80::1%25eth0]:8080/').host;
      expect(classifyHostAddress(host), linkLocal);
      final mapped = Uri.parse('http://[::ffff:127.0.0.1]:8060/').host;
      expect(classifyHostAddress(mapped), loopback);
    });

    test('malformed zones and zones on IPv4 are invalid', () {
      expectClasses({
        'fe80::1%': invalid,
        'fe80::1%eth 0': invalid,
        'fe80::1%eth0%1': invalid,
        'fe80::1%/64': invalid,
        'fe80::1%eth0/64': invalid,
        '%eth0': invalid,
        '192.168.1.7%eth0': invalid,
      });
    });
  });

  group('classifyHostAddress, invalid input', () {
    test('host names are not literals', () {
      expectClasses({
        '': invalid,
        ' ': invalid,
        'localhost': invalid,
        'tv.local': invalid,
        'example.com': invalid,
        'fire-tv': invalid,
        'cafe': invalid,
        'dead.beef': invalid,
      });
    });

    test('non-canonical IPv4 forms are never guessed at', () {
      expectClasses({
        '127.1': invalid,
        '127.0.1': invalid,
        '0x7f.0.0.1': invalid,
        '0x7f000001': invalid,
        '2130706433': invalid,
        '017700000001': invalid,
        '010.0.0.1': invalid,
        '192.168.01.7': invalid,
        '192.168.1.07': invalid,
        '00.0.0.0': invalid,
        '0177.0.0.1': invalid,
      });
    });

    test('malformed IPv4', () {
      expectClasses({
        '192.168.1': invalid,
        '192.168.1.7.': invalid,
        '.192.168.1.7': invalid,
        '192..168.1': invalid,
        '1.2.3.4.5': invalid,
        '192.168.1.256': invalid,
        '256.0.0.1': invalid,
        '1000.0.0.1': invalid,
        '192.168.1.-1': invalid,
        '192.168.1.+1': invalid,
        ' 192.168.1.7': invalid,
        '192.168.1.7 ': invalid,
        '192.168.1.7\n': invalid,
        '192.168.1.7:8080': invalid,
        '192.168.1.7/24': invalid,
        'http://192.168.1.7': invalid,
        '١٩٢.١٦٨.١.٧': invalid,
        '１９２.１６８.１.７': invalid, // full-width digits
      });
    });

    test('malformed IPv6', () {
      expectClasses({
        ':': invalid,
        ':::': invalid,
        '::::': invalid,
        '1:::2': invalid,
        ':1::': invalid,
        '1::2:': invalid,
        ':1:2:3:4:5:6:7:8': invalid,
        '1:2:3:4:5:6:7:8:': invalid,
        '1::2::3': invalid,
        '1:2:3:4:5:6:7': invalid,
        '1:2:3:4:5:6:7:8:9': invalid,
        '1:2:3:4:5:6:7:8::': invalid,
        '::1:2:3:4:5:6:7:8': invalid,
        '1:2:3:4::5:6:7:8': invalid,
        '12345::1': invalid,
        '00000::1': invalid,
        'g::1': invalid,
        '::-1': invalid,
        '::+1': invalid,
        '::0x1': invalid,
        '[::1]': invalid,
        '[fe80::1]': invalid,
        '::1 ': invalid,
        ' ::1': invalid,
        'fe80::1/64': invalid,
      });
    });

    test('malformed IPv4 tails in IPv6', () {
      expectClasses({
        '::ffff:1.2.3': invalid,
        '::ffff:1.2.3.4.5': invalid,
        '::ffff:192.168.001.1': invalid,
        '::ffff:256.1.1.1': invalid,
        '1.2.3.4::': invalid,
        '1.2.3.4::1': invalid,
        '::1.2.3.4:5': invalid,
        '::ffff:1.2.3.4:5': invalid,
        'fd00:1:2:3:4:5:6:1.2.3.4': invalid,
        'fd00:1:2:3:4:5:6:7:1.2.3.4': invalid,
      });
    });
  });

  group('DestinationPolicy', () {
    const lan = DestinationPolicy.lanOnly;
    const withLoopback = DestinationPolicy(allowLoopback: true);
    const nonPrivate = DestinationPolicy(allowNonPrivate: true);
    const both = DestinationPolicy(allowLoopback: true, allowNonPrivate: true);

    test('the default is LAN-only without loopback', () {
      expect(const DestinationPolicy(), lan);
      expect(lan.allowLoopback, isFalse);
      expect(lan.allowNonPrivate, isFalse);
    });

    test('allowsClass for every class under every policy', () {
      final expected = <HostAddressClass, List<bool>>{
        // [lan, withLoopback, nonPrivate, both]
        privateLan: [true, true, true, true],
        linkLocal: [true, true, true, true],
        loopback: [false, true, false, true],
        cgnat: [false, false, true, true],
        public: [false, false, true, true],
        reserved: [false, false, true, true],
        multicast: [false, false, false, false],
        unspecified: [false, false, false, false],
        broadcast: [false, false, false, false],
        invalid: [false, false, false, false],
      };
      expect(expected.keys, containsAll(HostAddressClass.values));
      for (final kind in HostAddressClass.values) {
        final policies = [lan, withLoopback, nonPrivate, both];
        for (final (i, policy) in policies.indexed) {
          expect(
            policy.allowsClass(kind),
            expected[kind]![i],
            reason: '$kind under $policy',
          );
        }
      }
    });

    test('LAN-only allows private, link-local and unique-local addresses '
        'and their IPv4-mapped forms', () {
      for (final address in [
        '192.168.1.7',
        '10.0.0.2',
        '172.16.5.4',
        '169.254.10.20',
        'fe80::1',
        'fe80::1%eth0',
        'fd00::1',
        '::ffff:192.168.1.7',
        '::ffff:169.254.1.1',
      ]) {
        expect(lan.allows(address), isTrue, reason: address);
        expect(lan.refusal(address), isNull, reason: address);
        expect(isAllowedDestination(address), isTrue, reason: address);
        lan.check(address);
      }
    });

    test('LAN-only refuses everything else', () {
      for (final address in [
        '8.8.8.8', // public: a spoofed SSDP sender or manual host
        '93.184.216.34',
        '2001:4860:4860::8888',
        '100.64.1.1', // CGNAT / Tailscale named by an mDNS record
        '::ffff:100.64.1.1',
        '127.0.0.1',
        '::1',
        '::ffff:127.0.0.1',
        '0.0.0.0',
        '::',
        '224.0.0.251',
        'ff02::fb',
        '255.255.255.255',
        '192.0.2.10',
        '2001:db8::1',
        '64:ff9b::192.168.1.1',
        'localhost',
        'tv.local',
        '127.1',
      ]) {
        expect(lan.allows(address), isFalse, reason: address);
        expect(isAllowedDestination(address), isFalse, reason: address);
        final error = lan.refusal(address);
        expect(error, isNotNull, reason: address);
        expect(error!.code, WatchmeErrorCode.destinationRefused);
        expect(error.message, contains(address));
        expect(
          () => lan.check(address),
          throwsA(
            isA<WatchmeError>().having(
              (e) => e.code,
              'code',
              WatchmeErrorCode.destinationRefused,
            ),
          ),
          reason: address,
        );
      }
    });

    test('allowLoopback admits loopback in every notation, nothing more', () {
      for (final address in [
        '127.0.0.1',
        '127.9.9.9',
        '::1',
        '::ffff:7f00:1',
      ]) {
        expect(withLoopback.allows(address), isTrue, reason: address);
        expect(
          isAllowedDestination(address, allowLoopback: true),
          isTrue,
          reason: address,
        );
      }
      for (final address in ['8.8.8.8', '100.64.0.1', '0.0.0.0', 'localhost']) {
        expect(withLoopback.allows(address), isFalse, reason: address);
      }
    });

    test('allowNonPrivate admits public, shared and reserved unicast, but '
        'not loopback, multicast, broadcast or unspecified', () {
      for (final address in [
        '8.8.8.8',
        '100.64.0.1',
        '192.0.2.10',
        '2001:db8::1',
        '2001:4860::1',
      ]) {
        expect(nonPrivate.allows(address), isTrue, reason: address);
        expect(
          isAllowedDestination(address, allowNonPrivate: true),
          isTrue,
          reason: address,
        );
      }
      for (final address in [
        '127.0.0.1',
        '::1',
        '224.0.0.1',
        'ff02::1',
        '255.255.255.255',
        '0.0.0.0',
        '::',
        'example.com',
      ]) {
        expect(nonPrivate.allows(address), isFalse, reason: address);
      }
    });

    test('the refusal names the host name and the resolved address', () {
      final error = lan.refusal('8.8.8.8', hostName: 'tv.example.com')!;
      expect(error.message, contains('tv.example.com (8.8.8.8)'));
      expect(error.message, contains('public'));
      expect(lan.refusal('100.64.0.1')!.message, contains('100.64.0.0/10'));
      expect(lan.refusal('127.0.0.1')!.message, contains('loopback'));
      expect(
        lan.refusal('8.8.8.8', hostName: '8.8.8.8')!.message,
        isNot(contains('(8.8.8.8)')),
      );
    });

    test('value semantics', () {
      expect(
        const DestinationPolicy(allowLoopback: true),
        const DestinationPolicy(allowLoopback: true),
      );
      expect(
        withLoopback.hashCode,
        const DestinationPolicy(allowLoopback: true).hashCode,
      );
      expect(withLoopback, isNot(nonPrivate));
      expect(lan, isNot(both));
      expect(
        both.toString(),
        'DestinationPolicy(allowLoopback: true, allowNonPrivate: true)',
      );
    });
  });
}
