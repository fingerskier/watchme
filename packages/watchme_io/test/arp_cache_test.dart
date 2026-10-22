import 'dart:io';

import 'package:test/test.dart';
import 'package:watchme_io/watchme_io.dart';

const sample = '''
IP address       HW type     Flags       HW address            Mask     Device
10.0.0.7         0x1         0x2         D8:31:34:AA:BB:CC     *        wlan0
10.0.0.8         0x1         0x0         00:00:00:00:00:00     *        wlan0
10.0.0.9         0x1         0x6         3c:22:fb:00:00:01     *        eth0
10.0.0.10        0x1         0x2         00:00:00:00:00:00     *        eth0
broken
''';

void main() {
  test('parses complete entries from /proc/net/arp', () {
    expect(ArpCache.parseProcNetArp(sample), {
      '10.0.0.7': 'd8:31:34:aa:bb:cc',
      '10.0.0.9': '3c:22:fb:00:00:01',
    });
  });

  test('looks up a MAC from a table file', () async {
    final dir = await Directory.systemTemp.createTemp('watchme_arp');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/arp')..writeAsStringSync(sample);
    final cache = ArpCache(path: file.path, supported: true);
    expect(await cache.macFor('10.0.0.7'), 'd8:31:34:aa:bb:cc');
    expect(await cache.macFor('10.0.0.8'), isNull);
    expect(
      await ArpCache(
        path: '${dir.path}/missing',
        supported: true,
      ).macFor('10.0.0.7'),
      isNull,
    );
    expect(
      await ArpCache(path: file.path, supported: false).macFor('10.0.0.7'),
      isNull,
    );
  });
}
