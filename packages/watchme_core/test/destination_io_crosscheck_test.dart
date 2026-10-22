@TestOn('vm')
library;

// Cross-checks the pure-Dart classifier against dart:io's own address
// parser and flags. watchme_core itself never imports dart:io; only this
// test does.

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

/// Whether [address] (raw bytes) is an IPv4-mapped IPv6 address, which
/// dart:io's flags do not look through.
bool _mapped(Uint8List raw) =>
    raw.length == 16 &&
    raw.sublist(0, 10).every((b) => b == 0) &&
    raw[10] == 0xff &&
    raw[11] == 0xff;

void _agrees(InternetAddress address) {
  final text = address.address;
  final kind = classifyHostAddress(text);
  expect(kind, isNot(HostAddressClass.invalid), reason: text);
  if (_mapped(address.rawAddress)) return;
  expect(
    kind == HostAddressClass.loopback,
    address.isLoopback,
    reason: '$text loopback',
  );
  // dart:io's IPv6 isLinkLocal masks the second byte with 0xB0 instead of
  // 0xC0, so it calls fec0::/12 (deprecated site-local) link-local and
  // misses fe90:: to febf::. Check IPv6 against fe80::/10 on the bytes
  // dart:io parsed instead.
  final raw = address.rawAddress;
  final linkLocal = address.type == InternetAddressType.IPv4
      ? address.isLinkLocal
      : raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80;
  expect(
    kind == HostAddressClass.linkLocal,
    linkLocal,
    reason: '$text link-local',
  );
  expect(
    kind == HostAddressClass.multicast,
    address.isMulticast,
    reason: '$text multicast',
  );
}

void main() {
  test('accepts exactly the literals dart:io accepts (zone ids aside)', () {
    const corpus = [
      '192.168.1.7', '0.0.0.0', '255.255.255.255', '127.0.0.1', //
      '010.0.0.1', '127.1', '0x7f.0.0.1', '2130706433', '1.2.3.4.5',
      '192.168.1.256', '192.168.1', ' 192.168.1.7', '192.168.1.7 ',
      '::', '::1', 'fe80::1', 'FE80::1', 'fd00::1', 'ff02::fb',
      '::ffff:192.168.1.7', '::ffff:c0a8:107', '0:0:0:0:0:ffff:1.2.3.4',
      '1:2:3:4:5:6:7::', '::1:2:3:4:5:6:7', '1:2:3:4:5:6:1.2.3.4',
      '1::2:3:4:5:6:7:8', '1:2:3:4:5:6:7:1.2.3.4', '::ffff:1.2.3',
      '00000::1', '::01234', ':::', '1::2::3', ':1::', '1::2:', '[::1]',
      'localhost', 'tv.local', '', '64:ff9b::8.8.8.8', '2001:db8::1',
    ];
    for (final text in corpus) {
      final ours = classifyHostAddress(text) != HostAddressClass.invalid;
      final theirs = InternetAddress.tryParse(text) != null;
      expect(ours, theirs, reason: '"$text"');
    }
  });

  test('agrees with dart:io on loopback, link-local and multicast for '
      'random addresses', () {
    final random = Random(20261021);
    for (var i = 0; i < 20000; i++) {
      final v4 = Uint8List.fromList([
        for (var j = 0; j < 4; j++) random.nextInt(256),
      ]);
      _agrees(InternetAddress.fromRawAddress(v4));
      final v6 = Uint8List.fromList([
        for (var j = 0; j < 16; j++) random.nextInt(256),
      ]);
      // Bias half the IPv6 samples towards the interesting prefixes.
      if (i.isEven) {
        const prefixes = [
          [0x00, 0x00], [0xfe, 0x80], [0xfe, 0xc0], [0xfc, 0x00], //
          [0xfd, 0x00], [0xff, 0x02], [0x20, 0x01], [0x00, 0x64],
        ];
        final prefix = prefixes[random.nextInt(prefixes.length)];
        v6
          ..[0] = prefix[0]
          ..[1] = (v6[1] & 0x3f) | prefix[1];
      }
      _agrees(InternetAddress.fromRawAddress(v6));
    }
  });

  test('IPv6 link-local follows RFC 4291 fe80::/10, not '
      'InternetAddress.isLinkLocal', () {
    for (final text in ['fe80::1', 'fe8f::1', 'fe90::1', 'febf::1']) {
      expect(classifyHostAddress(text), HostAddressClass.linkLocal);
    }
    for (final text in ['fec0::1', 'fecf::1']) {
      // dart:io reports these as link-local; they are deprecated site-local.
      expect(classifyHostAddress(text), HostAddressClass.reserved);
      expect(DestinationPolicy.lanOnly.allows(text), isFalse);
    }
  });

  test('every form dart:io prints for an address classifies like the raw '
      'bytes do', () {
    for (final text in [
      '192.168.1.7',
      '::ffff:192.168.1.7',
      'fe80::1',
      '::1',
      'fd12:3456:789a::1',
      '100.64.0.1',
    ]) {
      final parsed = InternetAddress(text);
      final reprinted = InternetAddress.fromRawAddress(parsed.rawAddress);
      expect(
        classifyHostAddress(reprinted.address),
        classifyHostAddress(text),
        reason: text,
      );
    }
  });
}
