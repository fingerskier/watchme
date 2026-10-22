import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../firetv/test_certificates.dart';

/// The simulated TV's power.
enum VizioSimPower {
  /// On, picture showing: `power_mode` reports 1.
  on,

  /// Quick Start standby: the API keeps answering and `power_mode` reports
  /// 0.
  standby,

  /// Eco mode or deep off: the API port refuses connections.
  off,
}

/// How the simulator spells the keys of its JSON answers. SmartCast keys
/// are case-insensitive (`STATUS` and `status` both occur), so clients must
/// normalise them.
enum VizioSimKeyCase {
  /// `STATUS`, `ITEMS`, `POWER_MODE`.
  upper,

  /// `status`, `items`, `power_mode`.
  lower,

  /// Upper case and lower case on alternate answers.
  alternate,
}

/// Which certificate the simulator's HTTPS API presents.
///
/// Both are the self-signed, TEST-ONLY loopback certificates of the Fire TV
/// simulator, reused here (a real VIZIO presents a fleet-wide self-signed
/// certificate with CN `BG2.prod.vizio.com`; trust-on-first-use does not
/// care about the name). Switching between them with
/// `VizioSimulator.restartWithCertificate` simulates a certificate that
/// changed after pairing.
enum VizioSimulatorCertificate {
  /// The default identity.
  primary(primaryCertificatePem, primaryPrivateKeyPem),

  /// A second identity, for pin-mismatch tests.
  alternate(alternateCertificatePem, alternatePrivateKeyPem);

  const VizioSimulatorCertificate(this.certificatePem, this.privateKeyPem);

  /// The certificate, PEM.
  final String certificatePem;

  /// The private key, PKCS#8 PEM. Test-only.
  final String privateKeyPem;

  /// The certificate, DER.
  Uint8List get der {
    final body = certificatePem
        .replaceAll(RegExp('-----[A-Z ]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    return base64.decode(body);
  }

  /// SHA-256 of [der], 64 lower-case hex digits: the value a TLS client
  /// records for trust-on-first-use pinning.
  String get sha256Fingerprint => sha256.convert(der).toString();

  /// A server context presenting this identity.
  SecurityContext context() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(certificatePem))
    ..usePrivateKeyBytes(utf8.encode(privateKeyPem));
}

/// One input of the simulated TV, as `devices/name_input` lists it.
final class VizioSimInput {
  /// Creates an input.
  const VizioSimInput(this.cname, this.name, {this.meta = ''});

  /// The canonical id (`hdmi1`, `cast`, `tuner`): what `current_input`
  /// accepts on modern firmware.
  final String cname;

  /// The display label (`HDMI-1`, `CAST`, `TV`).
  final String name;

  /// The user or meta name (`VALUE.NAME`), e.g. `SMARTCAST` for `cast`.
  final String meta;

  /// What `current_input` reports while this input is current: the meta
  /// name for cast, the display name otherwise.
  String get currentValue => cname == 'cast' ? meta : name;
}

/// An app the simulated TV can launch and report from `/app/current`.
final class VizioSimApp {
  /// Creates an app.
  const VizioSimApp(this.name, this.appId, this.nameSpace, {this.message});

  /// Display name (not on the wire).
  final String name;

  /// `APP_ID`.
  final String appId;

  /// `NAME_SPACE`.
  final int nameSpace;

  /// `MESSAGE`.
  final String? message;

  /// The `VALUE` object of `/app/current` and `/app/launch`.
  Map<String, Object?> toValue() => {
    'APP_ID': appId,
    'NAME_SPACE': nameSpace,
    'MESSAGE': message,
  };

  @override
  String toString() => 'VizioSimApp($name $nameSpace/$appId)';
}

/// One request the simulator received.
final class VizioSimRequest {
  /// Creates a record (used by the simulator).
  VizioSimRequest(this.method, this.uri, this.headers, this.body);

  /// Upper-case HTTP method.
  final String method;

  /// Request URI (path and query).
  final Uri uri;

  /// Request headers with lower-case names; repeated values joined by `, `.
  final Map<String, String> headers;

  /// The raw body as text (empty when there was none).
  final String body;

  /// The URI path.
  String get path => uri.path;

  /// The header [name], case-insensitively.
  String? header(String name) => headers[name.toLowerCase()];

  /// The body parsed as JSON, or `null` when it is not JSON.
  Object? get json {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'VizioSimRequest($method $uri)';
}

/// An answer the simulator holds back (see `VizioSimulator.holdNext`).
final class VizioSimGate {
  /// Creates a gate for the next [method] [path] request.
  VizioSimGate(this.method, this.path);

  /// The method it waits for.
  final String method;

  /// The exact path it waits for.
  final String path;

  final Completer<VizioSimRequest> _reached = Completer();
  final Completer<void> _release = Completer();

  /// Completes with the request once it arrived and was handled; its answer
  /// is then held until [release].
  Future<VizioSimRequest> get reached => _reached.future;

  /// Whether the request arrived.
  bool get isReached => _reached.isCompleted;

  /// Sends the held answer (at once if the request already arrived,
  /// otherwise as soon as it does).
  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  /// Whether [req] is the request this gate waits for.
  bool matches(VizioSimRequest req) =>
      !_reached.isCompleted && req.method == method && req.path == path;

  /// Holds [req] until [release].
  Future<void> hold(VizioSimRequest req) {
    _reached.complete(req);
    return _release.future;
  }
}
