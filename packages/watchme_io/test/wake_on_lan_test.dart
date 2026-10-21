import 'dart:async';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

const mac = 'D8-31-34-AA-BB-CC';

void main() {
  test('sends the magic packet to a loopback UDP listener', () async {
    final listener = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(listener.close);
    final packets = <Uint8List>[];
    final got2 = Completer<void>();
    listener.listen((event) {
      final d = listener.receive();
      if (d == null) return;
      packets.add(d.data);
      if (packets.length == 2 && !got2.isCompleted) got2.complete();
    });
    // Unicast to loopback only: no broadcast leaves this host.
    final report = await WakeOnLan(
      IoNetworkStack(),
      ports: [listener.port],
      limitedBroadcast: false,
      subnetBroadcasts: () async => [],
      repeats: 2,
      interval: const Duration(milliseconds: 10),
    ).wake(mac, lastKnownIp: '127.0.0.1');
    await got2.future.timeout(const Duration(seconds: 2));
    expect(packets, everyElement(magicPacket(mac)));
    expect(packets.first, hasLength(102));
    expect(report.sent, [
      (host: '127.0.0.1', port: listener.port, broadcast: false),
    ]);
    expect(report.failed, isEmpty);
  });

  test('targets the limited broadcast, subnet broadcasts and the last IP '
      'on ports 9 and 7', () async {
    final net = FakeNetworkStack();
    final report = await WakeOnLan(
      net,
      subnetBroadcasts: () async => ['10.0.0.255', '172.17.255.255'],
      repeats: 1,
    ).wake(mac, lastKnownIp: '10.0.0.7');
    final sent = [
      for (final d in net.sentDatagrams) '${d.host}:${d.port}:${d.broadcast}',
    ];
    expect(sent, [
      '255.255.255.255:9:true',
      '255.255.255.255:7:true',
      '10.0.0.255:9:true',
      '10.0.0.255:7:true',
      '172.17.255.255:9:true',
      '172.17.255.255:7:true',
      '10.0.0.7:9:false',
      '10.0.0.7:7:false',
    ]);
    expect(
      net.sentDatagrams,
      everyElement(
        isA<SentDatagram>().having((d) => d.bytes, 'bytes', magicPacket(mac)),
      ),
    );
    expect(report.sent, hasLength(8));
  });

  test('repeats each destination and de-duplicates them', () async {
    final net = FakeNetworkStack();
    final clock = FakeClock();
    final wake = WakeOnLan(
      net,
      ports: [9],
      subnetBroadcasts: () async => ['255.255.255.255'],
      repeats: 3,
      interval: const Duration(milliseconds: 100),
      clock: clock,
    ).wake(mac);
    await clock.advance(const Duration(seconds: 1));
    await wake;
    expect(net.sentDatagrams, hasLength(3));
  });

  test('reports partial failures and throws when nothing is sent', () async {
    final net = FakeNetworkStack()
      ..features.remove(TransportFeature.udpBroadcast);
    final report = await WakeOnLan(
      net,
      ports: [9],
      subnetBroadcasts: () async => [],
      repeats: 1,
    ).wake(mac, lastKnownIp: '10.0.0.7');
    expect(report.sent.single.host, '10.0.0.7');
    expect(report.failed.keys.single.host, '255.255.255.255');
    expect(report.failed.values.single.code, WatchmeErrorCode.unsupported);

    await expectLater(
      WakeOnLan(net, subnetBroadcasts: () async => [], repeats: 1).wake(mac),
      throwsWatchmeError(WatchmeErrorCode.unsupported),
    );
  });

  test('send reports instead of throwing', () async {
    final net = FakeNetworkStack();
    final wol = WakeOnLan(net, subnetBroadcasts: () async => [], repeats: 1);
    expect(await wol.send(mac, lastKnownIp: '10.0.0.7'), isTrue);
    expect(net.sentDatagrams.map((d) => (d.host, d.port)), [
      ('255.255.255.255', 9),
      ('255.255.255.255', 7),
      ('10.0.0.7', 9),
      ('10.0.0.7', 7),
    ]);
    expect(await wol.send('not a mac'), isFalse);
    net.features
      ..remove(TransportFeature.udpBroadcast)
      ..remove(TransportFeature.udpUnicast);
    expect(await wol.send(mac, lastKnownIp: '10.0.0.7'), isFalse);
  });

  test('rejects an invalid MAC', () {
    expect(
      WakeOnLan(FakeNetworkStack()).wake('not a mac'),
      throwsFormatException,
    );
  });

  test(
    'a failing subnet lookup still wakes through the other targets',
    () async {
      final net = FakeNetworkStack();
      await WakeOnLan(
        net,
        ports: [9],
        subnetBroadcasts: () async => throw const FileSystemException('nope'),
        repeats: 1,
      ).wake(mac);
      expect(net.sentDatagrams.single.host, '255.255.255.255');
    },
  );
}
