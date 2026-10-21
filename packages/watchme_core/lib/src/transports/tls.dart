import 'package:meta/meta.dart';

import '../util/equality.dart';

/// How a TLS connection decides whether to trust the peer.
///
/// Drivers pass one per call; watchme never disables verification globally.
/// Fingerprints are SHA-256 over the peer's DER-encoded leaf certificate, as
/// hex (any case, `:` separators allowed; see [normalizeFingerprint]).
///
/// The decision, implemented once in [allows] for every network stack:
/// * [pins] non-empty: the leaf fingerprint must be in [pins]. Chain trust is
///   irrelevant, so pinned self-signed certificates work.
/// * otherwise, [trustOnFirstUse] or [allowSelfSigned]: any certificate is
///   accepted. With trust-on-first-use the caller records
///   `peerCertificateSha256` from the result and pins it from then on.
/// * otherwise: the platform's chain verification decides.
@immutable
final class TlsPolicy {
  /// Creates a policy. The default is platform verification only.
  const TlsPolicy({
    this.allowSelfSigned = false,
    this.pins = const {},
    this.trustOnFirstUse = false,
  });

  /// Accept only a leaf whose fingerprint is in [fingerprints].
  factory TlsPolicy.pinned(Iterable<String> fingerprints) =>
      TlsPolicy(pins: {for (final f in fingerprints) normalizeFingerprint(f)});

  /// First contact with a per-device self-signed certificate (Fire TV,
  /// Android TV): accept it and record its fingerprint for pinning.
  const TlsPolicy.firstUse()
    : allowSelfSigned = true,
      pins = const {},
      trustOnFirstUse = true;

  /// Platform verification only.
  static const TlsPolicy platform = TlsPolicy();

  /// Accept certificates that do not chain to a trusted root.
  final bool allowSelfSigned;

  /// Accepted SHA-256 leaf fingerprints, hex.
  final Set<String> pins;

  /// The pin is recorded at pairing and enforced afterwards.
  final bool trustOnFirstUse;

  /// Whether a peer whose leaf fingerprint is [peerSha256] may be trusted,
  /// given whether the platform verified its chain ([platformTrusted]).
  bool allows({required String peerSha256, required bool platformTrusted}) {
    if (pins.isNotEmpty) {
      final peer = normalizeFingerprint(peerSha256);
      return pins.any((p) => normalizeFingerprint(p) == peer);
    }
    if (trustOnFirstUse || allowSelfSigned) return true;
    return platformTrusted;
  }

  @override
  bool operator ==(Object other) =>
      other is TlsPolicy &&
      other.allowSelfSigned == allowSelfSigned &&
      other.trustOnFirstUse == trustOnFirstUse &&
      setEquals(other.pins, pins);

  @override
  int get hashCode =>
      Object.hash(allowSelfSigned, trustOnFirstUse, setHash(pins));

  @override
  String toString() =>
      'TlsPolicy(allowSelfSigned: $allowSelfSigned, '
      'trustOnFirstUse: $trustOnFirstUse, pins: ${pins.length})';
}

final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

/// Normalises a SHA-256 fingerprint to 64 lower-case hex digits, removing
/// `:`, `-` and whitespace. Throws [FormatException] if it is not one.
String normalizeFingerprint(String fingerprint) {
  final hex = fingerprint.replaceAll(RegExp(r'[\s:\-]'), '').toLowerCase();
  if (!_hex64.hasMatch(hex)) {
    throw FormatException('Not a SHA-256 fingerprint', fingerprint);
  }
  return hex;
}
