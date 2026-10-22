import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The TEST-ONLY certificates in `test/fixtures/tls` (see its README).
abstract final class TlsFixtures {
  static String _read(String name) =>
      File('test/fixtures/tls/$name').readAsStringSync();

  /// Test CA certificate, PEM.
  static String get caPem => _read('ca.pem');

  /// CA-signed `127.0.0.1` server certificate, PEM.
  static String get serverPem => _read('server.pem');

  /// Its key.
  static String get serverKey => _read('server.key');

  /// Self-signed `127.0.0.1` certificate, PEM.
  static String get selfSignedPem => _read('selfsigned.pem');

  /// Its key.
  static String get selfSignedKey => _read('selfsigned.key');

  /// CA-signed client certificate, PEM.
  static String get clientPem => _read('client.pem');

  /// Its key.
  static String get clientKey => _read('client.key');

  /// A server context presenting [certPem] / [keyPem].
  static SecurityContext serverContext(String certPem, String keyPem) =>
      SecurityContext()
        ..useCertificateChainBytes(utf8.encode(certPem))
        ..usePrivateKeyBytes(utf8.encode(keyPem));

  /// The DER bytes of the first certificate in [pem].
  static Uint8List der(String pem) {
    final body = RegExp(
      '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----',
      dotAll: true,
    ).firstMatch(pem)!.group(1)!.replaceAll(RegExp(r'\s'), '');
    return base64.decode(body);
  }

  /// SHA-256 fingerprint of the first certificate in [pem].
  static String fingerprint(String pem) => sha256.convert(der(pem)).toString();
}
