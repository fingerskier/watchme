import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:watchme_core/watchme_core.dart';

/// SHA-256 of [der] as 64 lower-case hex digits: the fingerprint format of
/// `TlsPolicy` pins and `peerCertificateSha256`.
String certificateSha256(List<int> der) => sha256.convert(der).toString();

/// Builds and caches `SecurityContext`s, one per client identity.
///
/// Contexts always carry the platform's trusted roots (unless disabled) so
/// that "chain trusted" means the same thing for every [TlsPolicy]; the
/// policy itself is applied per connection by [secureSocket].
final class SecurityContexts {
  /// Creates a cache. [extraTrustedRootsPem] adds roots on top of (or, with
  /// [usePlatformRoots] false, instead of) the platform's.
  SecurityContexts({this.usePlatformRoots = true, this.extraTrustedRootsPem});

  /// Whether the OS trust store is loaded.
  final bool usePlatformRoots;

  /// Additional trusted roots, PEM.
  final List<int>? extraTrustedRootsPem;

  final Map<ClientIdentity?, SecurityContext> _cache = {};

  /// The context presenting [identity] (none when `null`).
  SecurityContext forIdentity(ClientIdentity? identity) {
    final cached = _cache[identity];
    if (cached != null) return cached;
    final context = SecurityContext(withTrustedRoots: usePlatformRoots);
    try {
      if (extraTrustedRootsPem case final roots?) {
        context.setTrustedCertificatesBytes(roots);
      }
      if (identity != null) {
        context
          ..useCertificateChainBytes(_chainPem(identity))
          ..usePrivateKeyBytes(_keyPem(identity), password: identity.password);
      }
    } on TlsException catch (e) {
      throw WatchmeError.protocol(
        'Unusable TLS material: ${e.message}',
        cause: e,
      );
    }
    return _cache[identity] = context;
  }
}

/// The outcome of a successful [secureSocket].
typedef SecuredSocket = ({
  SecureSocket socket,
  String peerSha256,
  Uint8List peerDer,
});

/// Upgrades [socket] to TLS and applies [policy] to the peer's leaf
/// certificate before returning, so nothing is sent to a peer the policy
/// rejects.
///
/// `onBadCertificate` may be called for any certificate in the chain (the
/// one at the failing depth), not only the leaf, so it only records that the
/// chain is untrusted; the single decision is `TlsPolicy.allows` on the leaf
/// once the handshake has finished.
Future<SecuredSocket> secureSocket(
  Socket socket, {
  required String host,
  required int port,
  required TlsPolicy policy,
  required SecurityContext context,
}) async {
  var chainTrusted = true;
  final mayAcceptUntrusted =
      policy.pins.isNotEmpty ||
      policy.allowSelfSigned ||
      policy.trustOnFirstUse;
  final SecureSocket secure;
  try {
    secure = await SecureSocket.secure(
      socket,
      host: host,
      context: context,
      onBadCertificate: (_) {
        chainTrusted = false;
        return mayAcceptUntrusted;
      },
    );
  } on HandshakeException catch (e) {
    if (!chainTrusted && !mayAcceptUntrusted) {
      throw WatchmeError.protocol(
        'TLS: certificate of $host:$port is not trusted',
        cause: e,
      );
    }
    rethrow;
  }
  final leaf = secure.peerCertificate;
  if (leaf == null) {
    secure.destroy();
    throw WatchmeError.protocol('TLS: $host:$port sent no certificate');
  }
  final der = leaf.der;
  final fingerprint = certificateSha256(der);
  if (!policy.allows(peerSha256: fingerprint, platformTrusted: chainTrusted)) {
    secure.destroy();
    throw WatchmeError.protocol(
      policy.pins.isEmpty
          ? 'TLS: certificate of $host:$port is not trusted '
                '(sha256 $fingerprint)'
          : 'TLS: certificate of $host:$port does not match the pin '
                '(sha256 $fingerprint)',
    );
  }
  return (socket: secure, peerSha256: fingerprint, peerDer: der);
}

List<int> _chainPem(ClientIdentity identity) => switch (identity.encoding) {
  IdentityEncoding.pem => identity.certificateChain,
  IdentityEncoding.der => utf8.encode(
    [
      for (final cert in splitDerSequence(identity.certificateChain))
        _pem('CERTIFICATE', cert),
    ].join(),
  ),
};

// DER private keys are taken to be PKCS#8, the format `ClientIdentity`
// documents for binary keys.
List<int> _keyPem(ClientIdentity identity) => switch (identity.encoding) {
  IdentityEncoding.pem => identity.privateKey,
  IdentityEncoding.der => utf8.encode(_pem('PRIVATE KEY', identity.privateKey)),
};

String _pem(String label, List<int> der) {
  final b64 = base64.encode(der);
  final lines = [
    for (var i = 0; i < b64.length; i += 64)
      b64.substring(i, i + 64 > b64.length ? b64.length : i + 64),
  ];
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
}

/// Splits concatenated DER `SEQUENCE`s (a certificate chain in binary form)
/// into one element per certificate. Throws [WatchmeError] (protocol) on a
/// malformed encoding.
List<Uint8List> splitDerSequence(List<int> bytes) {
  final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  final out = <Uint8List>[];
  var offset = 0;
  Never bad() => throw const WatchmeError.protocol('Malformed DER certificate');
  while (offset < data.length) {
    if (data[offset] != 0x30 || offset + 2 > data.length) bad();
    var length = data[offset + 1];
    var header = 2;
    if (length & 0x80 != 0) {
      final count = length & 0x7f;
      if (count == 0 || count > 4 || offset + 2 + count > data.length) bad();
      length = 0;
      for (var i = 0; i < count; i++) {
        length = (length << 8) | data[offset + 2 + i];
      }
      header += count;
    }
    final end = offset + header + length;
    if (end > data.length) bad();
    out.add(Uint8List.sublistView(data, offset, end));
    offset = end;
  }
  return out;
}
