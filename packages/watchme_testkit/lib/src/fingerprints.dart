import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A deterministic SHA-256 fingerprint (64 lower-case hex digits) derived
/// from [seed], for scripting TLS peers in tests.
String fakeFingerprint(String seed) =>
    sha256.convert(utf8.encode(seed)).toString();

/// The SHA-256 fingerprint of [der] bytes, as the real stack computes it for
/// a peer certificate.
String sha256Hex(List<int> der) => sha256.convert(der).toString();
