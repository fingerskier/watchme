import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:watchme_io/watchme_io.dart';

import '../support/ssdp_samples.dart';

void main() {
  test('receives NOTIFY alive and byebye over loopback multicast', () async {
    final lo = (await NetworkInterface.list(includeLoopback: true))
        .firstWhere((i) => i.addresses.any((a) => a.isLoopback));
    // Reserve a free port; the listener shares it through address reuse.
    final reserve = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    addTearDown(reserve.close);
    const group = '239.255.77.3';
    final listener = SsdpNotifyListener(
      group: group,
      port: reserve.port,
      interfaces: [lo],
    );
    final received = <SsdpAnnouncement>[];
    final twoReceived = Completer<void>();
    final subscription = listener.listen().listen(
      (a) {
        received.add(a);
        if (received.length == 2) twoReceived.complete();
      },
      onError: (Object e) {
        if (!twoReceived.isCompleted) twoReceived.completeError(e);
      },
    );
    addTearDown(subscription.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // Multicast through loopback only, TTL 0: nothing leaves the host.
    final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    addTearDown(sender.close);
    sender
      ..multicastHops = 0
      ..setRawOption(
        RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          Uint8List.fromList(InternetAddress.loopbackIPv4.rawAddress),
        ),
      );
    for (final text in [
      buildMSearchText(),
      'junk',
      rokuNotifyAlive,
      rokuNotifyByeBye(),
    ]) {
      sender.send(utf8.encode(text), InternetAddress(group), reserve.port);
    }
    await twoReceived.future.timeout(const Duration(seconds: 3));
    expect(received.first.alive, isTrue);
    expect(received.first.sender, '127.0.0.1');
    expect(received.first.hit.serviceType, 'roku:ecp');
    expect(received.first.hit.host, '10.0.0.20');
    expect(received.first.hit.port, 8060);
    expect(received.last.alive, isFalse);
  });

  test('cancelling before the bind completes releases the port', () async {
    final lo = (await NetworkInterface.list(includeLoopback: true))
        .firstWhere((i) => i.addresses.any((a) => a.isLoopback));
    final port = await _freeUdpPort();
    final listener = SsdpNotifyListener(
      group: '239.255.77.5',
      port: port,
      interfaces: [lo],
    );
    final subscription = listener.listen().listen((_) {});
    // Cancelled at once: the bind is still in flight.
    await subscription.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Without address reuse this bind fails while the listener holds it.
    final again = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: false,
    );
    again.close();
  });
}

String buildMSearchText() => utf8.decode(buildMSearch('ssdp:all'));

Future<int> _freeUdpPort() async {
  final probe = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  final port = probe.port;
  probe.close();
  return port;
}
