import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  test('port() prefers overrides and falls back to the default', () {
    const ep = Endpoint('127.0.0.1', ports: {'ecp': 51234});
    expect(ep.port('ecp', 8060), 51234);
    expect(ep.port('dial', 8009), 8009);
  });

  test('uri() builds URLs on the named port', () {
    const ep = Endpoint('127.0.0.1', ports: {'ecp': 51234});
    expect(
      ep.uri('http', 'ecp', 8060, '/query/device-info').toString(),
      'http://127.0.0.1:51234/query/device-info',
    );
    expect(
      ep.uri('http', 'ecp', 8060, '/launch/12', {
        'contentId': 'a b',
      }).toString(),
      'http://127.0.0.1:51234/launch/12?contentId=a+b',
    );
    expect(
      const Endpoint('192.0.2.7')
          .uri('https', 'remote', 8080, '/v1/FireTV')
          .toString(),
      'https://192.0.2.7:8080/v1/FireTV',
    );
    expect(
      ep.baseUri('http', 'ecp', 8060).toString(),
      'http://127.0.0.1:51234',
    );
  });

  test('uri() brackets IPv6 literals', () {
    const ep = Endpoint('::1', ports: {'ecp': 4000});
    expect(ep.uri('http', 'ecp', 8060, '/').toString(), 'http://[::1]:4000/');
  });

  test('fromHit records the discovery port under the matcher port name', () {
    const hit = DiscoveryHit(
      host: '192.0.2.10',
      provider: DiscoveryProviderId.ssdp,
      port: 8060,
      attributes: {DiscoveryAttr.usn: 'uuid:roku:ecp:X'},
    );
    final ep = Endpoint.fromHit(hit, portName: 'ecp');
    expect(ep.ports, {'ecp': 8060});
    expect(ep.attributes, hit.attributes);
    expect(Endpoint.fromHit(hit).ports, isEmpty);
  });

  test('with* helpers copy and override', () {
    const ep = Endpoint('10.0.0.1', ports: {'a': 1}, attributes: {'k': 'v'});
    expect(ep.withPorts({'b': 2}).ports, {'a': 1, 'b': 2});
    expect(ep.withPorts({'a': 3}).ports, {'a': 3});
    expect(ep.withAttributes({'k': 'w'}).attributes, {'k': 'w'});
    final moved = ep.withHost('10.0.0.2');
    expect(moved.host, '10.0.0.2');
    expect(moved.ports, ep.ports);
    expect(
      ep,
      const Endpoint('10.0.0.1', ports: {'a': 1}, attributes: {'k': 'v'}),
    );
  });
}
