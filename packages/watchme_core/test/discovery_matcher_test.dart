import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';

void main() {
  const fireTvDial = DiscoveryMatcher(
    provider: DiscoveryProviderId.ssdp,
    serviceType: 'urn:dial-multiscreen-org:service:dial:1',
    attributes: [
      AttributeMatch.equals(DiscoveryAttr.manufacturer, 'Amazon'),
      AttributeMatch.prefix(DiscoveryAttr.modelName, 'AFT'),
    ],
    portName: 'dial',
  );

  DiscoveryHit dialHit(Map<String, String> attributes, {String? st}) =>
      DiscoveryHit(
        host: '192.0.2.7',
        provider: DiscoveryProviderId.ssdp,
        port: 60000,
        serviceType: st ?? 'urn:dial-multiscreen-org:service:dial:1',
        attributes: attributes,
      );

  test('matches a Fire TV DIAL hit', () {
    expect(
      fireTvDial.matches(
        dialHit({
          DiscoveryAttr.manufacturer: 'Amazon',
          DiscoveryAttr.modelName: 'AFTKA',
        }),
      ),
      isTrue,
    );
  });

  test('equals and prefix are case-insensitive by default', () {
    expect(
      fireTvDial.matches(
        dialHit({
          DiscoveryAttr.manufacturer: 'AMAZON',
          DiscoveryAttr.modelName: 'aftka',
        }),
      ),
      isTrue,
    );
  });

  test('rejects other manufacturers, missing attributes, other types', () {
    expect(
      fireTvDial.matches(
        dialHit({
          DiscoveryAttr.manufacturer: 'Roku',
          DiscoveryAttr.modelName: 'AFTKA',
        }),
      ),
      isFalse,
    );
    expect(
      fireTvDial.matches(dialHit({DiscoveryAttr.manufacturer: 'Amazon'})),
      isFalse,
    );
    expect(
      fireTvDial.matches(
        dialHit({
          DiscoveryAttr.manufacturer: 'Amazon',
          DiscoveryAttr.modelName: 'AFTKA',
        }, st: 'roku:ecp'),
      ),
      isFalse,
    );
  });

  test('provider must match when given; null accepts any', () {
    const mdnsAny = DiscoveryMatcher(serviceType: '_amzn-wplay._tcp');
    for (final provider in [
      DiscoveryProviderId.mdns,
      DiscoveryProviderId.bonjour,
    ]) {
      expect(
        mdnsAny.matches(
          DiscoveryHit(
            host: '192.0.2.7',
            provider: provider,
            serviceType: '_amzn-wplay._tcp.local.',
          ),
        ),
        isTrue,
        reason: provider,
      );
    }
    expect(
      fireTvDial.matches(
        const DiscoveryHit(
          host: '192.0.2.7',
          provider: DiscoveryProviderId.mdns,
          serviceType: 'urn:dial-multiscreen-org:service:dial:1',
          attributes: {
            DiscoveryAttr.manufacturer: 'Amazon',
            DiscoveryAttr.modelName: 'AFTKA',
          },
        ),
      ),
      isFalse,
    );
  });

  test('a hit without a service type fails a typed matcher', () {
    expect(
      const DiscoveryMatcher(serviceType: 'roku:ecp')
          .matches(const DiscoveryHit(host: '192.0.2.1', provider: 'manual')),
      isFalse,
    );
    expect(
      const DiscoveryMatcher().matches(
        const DiscoveryHit(host: '192.0.2.1', provider: 'manual'),
      ),
      isTrue,
    );
  });

  test('regex and present constraints', () {
    const regex = AttributeMatch.regex('u', r'^amzn\.dmgr:');
    expect(regex.matches({'u': 'amzn.dmgr:ABC'}), isTrue);
    expect(regex.matches({'u': 'x amzn.dmgr:ABC'}), isFalse);
    expect(regex.matches({}), isFalse);
    const caseless = AttributeMatch.regex('m', '^aft', caseSensitive: false);
    expect(caseless.matches({'m': 'AFTKA'}), isTrue);
    const present = AttributeMatch.present('amzn.dmgr');
    expect(present.matches({'amzn.dmgr': ''}), isTrue);
    expect(present.matches({'other': 'x'}), isFalse);
    const exact = AttributeMatch.equals('m', 'AFTKA', caseSensitive: true);
    expect(exact.matches({'m': 'aftka'}), isFalse);
  });

  test('matcher JSON round-trips', () {
    expect(DiscoveryMatcher.fromJson(fireTvDial.toJson()), fireTvDial);
    const m = DiscoveryMatcher(
      attributes: [
        AttributeMatch.present('x'),
        AttributeMatch.regex('y', r'\d+'),
      ],
    );
    expect(DiscoveryMatcher.fromJson(m.toJson()), m);
  });

  test('normalizeServiceType', () {
    expect(normalizeServiceType('_googlecast._tcp.local.'), '_googlecast._tcp');
    expect(normalizeServiceType('_GoogleCast._TCP'), '_googlecast._tcp');
    expect(normalizeServiceType('roku:ecp'), 'roku:ecp');
  });
}
