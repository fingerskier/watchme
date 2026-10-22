import 'package:test/test.dart';
import 'package:watchme_io/watchme_io.dart';

void main() {
  test('parses connected subnets from /proc/net/route', () {
    const route =
        'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n'
        'wlan0\t00000000\t0100000A\t0003\t0\t0\t600\t00000000\t0\t0\t0\n'
        'wlan0\t0000000A\t00000000\t0001\t0\t0\t600\t00FFFFFF\t0\t0\t0\n'
        'docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0\n'
        'tun0\t0100000A\t00000000\t0005\t0\t0\t0\tFFFFFFFF\t0\t0\t0\n'
        'eth1\t0000A8C0\t00000000\t0000\t0\t0\t0\t00FFFFFF\t0\t0\t0\n'
        'garbage line\n';
    final subnets = LocalNetwork.parseProcNetRoute(route);
    expect(subnets, [
      const LocalSubnet('wlan0', '10.0.0.0', 24),
      const LocalSubnet('docker0', '172.17.0.0', 16),
      const LocalSubnet('tun0', '10.0.0.1', 32),
    ]);
    expect(subnets.map((s) => s.broadcast), [
      '10.0.0.255',
      '172.17.255.255',
      null,
    ]);
    expect(subnets.first.contains('10.0.0.7'), isTrue);
    expect(subnets.first.contains('10.0.1.7'), isFalse);
    expect(subnets.first.contains('nonsense'), isFalse);
  });

  test('parses macOS ifconfig output', () {
    const ifconfig = '''
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	ether 3c:22:fb:00:00:01
	inet6 fe80::1%en0 prefixlen 64 secured scopeid 0x6
	inet 10.0.0.42 netmask 0xffffff00 broadcast 10.0.0.255
bridge100: flags=8863<UP,BROADCAST> mtu 1500
	inet 192.168.64.1 netmask 255.255.240.0 broadcast 192.168.79.255
''';
    final subnets = LocalNetwork.parseIfconfig(ifconfig);
    expect(subnets, [
      const LocalSubnet('en0', '10.0.0.0', 24),
      const LocalSubnet('bridge100', '192.168.64.0', 20),
    ]);
    expect(subnets.last.broadcast, '192.168.79.255');
  });

  test('reads this host without failing', () async {
    final subnets = await LocalNetwork.ipv4Subnets();
    for (final s in subnets) {
      expect(s.prefixLength, inInclusiveRange(1, 32));
    }
    expect(await LocalNetwork.broadcastAddresses(), isA<List<String>>());
  });
}
