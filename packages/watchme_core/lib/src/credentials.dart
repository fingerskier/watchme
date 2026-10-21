import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'transports/network.dart';
import 'util/equality.dart';
import 'util/json.dart';

/// What a driver needs to talk to a paired device again.
///
/// One credential per (device, driver). The JSON form ([toJson]) is the
/// storage format and contains secrets: it is written only to a
/// [CredentialStore] and never sent to UI clients. [toString] never prints
/// secrets.
@immutable
sealed class Credential {
  const Credential({
    required this.driverId,
    required this.deviceId,
    required this.createdAt,
    this.peerCertSha256,
    this.expiresAt,
  });

  /// Decodes the form written by [toJson].
  factory Credential.fromJson(JsonMap json) {
    final driverId = req<String>(json, 'driverId');
    final deviceId = req<String>(json, 'deviceId');
    final createdAt = reqTime(json, 'createdAt');
    final peer = opt<String>(json, 'peerCertSha256');
    final expiresAt = optTime(json, 'expiresAt');
    return switch (typeOf(json)) {
      'token' => TokenCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        token: req<String>(json, 'token'),
        refreshToken: opt<String>(json, 'refreshToken'),
        refreshExpiresAt: optTime(json, 'refreshExpiresAt'),
        attributes: strMap(json, 'attributes'),
      ),
      'clientCert' => ClientCertCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        certificatePem: req<String>(json, 'certificatePem'),
        privateKeyPem: req<String>(json, 'privateKeyPem'),
      ),
      'userSuppliedClientCert' => UserSuppliedClientCertCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        certificatePem: req<String>(json, 'certificatePem'),
        privateKeyPem: req<String>(json, 'privateKeyPem'),
        password: opt<String>(json, 'password'),
        label: opt<String>(json, 'label'),
      ),
      'keyPair' => KeyPairCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        algorithm: req<String>(json, 'algorithm'),
        publicKey: reqBytes(json, 'publicKey'),
        privateKey: reqBytes(json, 'privateKey'),
        peerPublicKey: optBytes(json, 'peerPublicKey'),
        peerIdentifier: opt<String>(json, 'peerIdentifier'),
      ),
      'sharedSecret' => SharedSecretCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        secret: req<String>(json, 'secret'),
        username: opt<String>(json, 'username'),
      ),
      'cloudOAuth' => CloudOAuthCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        accessToken: req<String>(json, 'accessToken'),
        refreshToken: opt<String>(json, 'refreshToken'),
        clientId: req<String>(json, 'clientId'),
        clientSecret: opt<String>(json, 'clientSecret'),
        scopes: strList(json, 'scopes'),
        tokenEndpoint: optUri(json, 'tokenEndpoint'),
      ),
      'matterFabric' => MatterFabricCredential(
        driverId: driverId,
        deviceId: deviceId,
        createdAt: createdAt,
        peerCertSha256: peer,
        expiresAt: expiresAt,
        fabricId: req<String>(json, 'fabricId'),
        nodeId: req<String>(json, 'nodeId'),
        rootCertificate: reqBytes(json, 'rootCertificate'),
        intermediateCertificate: optBytes(json, 'intermediateCertificate'),
        nodeOperationalCertificate: reqBytes(
          json,
          'nodeOperationalCertificate',
        ),
        operationalPrivateKey: reqBytes(json, 'operationalPrivateKey'),
        ipk: reqBytes(json, 'ipk'),
      ),
      final other => throw FormatException('Unknown credential type: $other'),
    };
  }

  /// The driver that issued and uses this credential.
  final String driverId;

  /// The engine's device id.
  final String deviceId;

  /// When pairing produced it.
  final DateTime createdAt;

  /// The TLS leaf fingerprint recorded at pairing (trust-on-first-use).
  /// Drivers pin it on later connections.
  final String? peerCertSha256;

  /// When the primary secret expires, if it does.
  final DateTime? expiresAt;

  /// JSON `type` discriminator.
  String get type;

  /// Whether the primary secret has expired at [now].
  bool isExpired(DateTime now) =>
      expiresAt != null && !now.isBefore(expiresAt!);

  /// Storage form, including secrets.
  JsonMap toJson() => {
    'type': type,
    'driverId': driverId,
    'deviceId': deviceId,
    'createdAt': isoTime(createdAt),
    if (peerCertSha256 != null) 'peerCertSha256': peerCertSha256,
    if (expiresAt != null) 'expiresAt': isoTime(expiresAt!),
    ..._secrets(),
  };

  JsonMap _secrets();

  bool _sameBase(Credential other) =>
      other.runtimeType == runtimeType &&
      other.driverId == driverId &&
      other.deviceId == deviceId &&
      other.createdAt.isAtSameMomentAs(createdAt) &&
      other.peerCertSha256 == peerCertSha256 &&
      _sameInstant(other.expiresAt, expiresAt);

  int get _baseHash => Object.hash(
    type,
    driverId,
    deviceId,
    createdAt.microsecondsSinceEpoch,
    peerCertSha256,
    expiresAt?.microsecondsSinceEpoch,
  );

  @override
  String toString() => '$runtimeType($driverId for $deviceId)';
}

bool _sameInstant(DateTime? a, DateTime? b) =>
    a == null ? b == null : b != null && a.isAtSameMomentAs(b);

/// A bearer token: Fire TV client token, Samsung token, LG client-key,
/// Vizio AUTH, VIDAA access/refresh tokens.
final class TokenCredential extends Credential {
  /// Creates a token credential.
  const TokenCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.token,
    super.peerCertSha256,
    super.expiresAt,
    this.refreshToken,
    this.refreshExpiresAt,
    this.attributes = const {},
  });

  /// The token.
  final String token;

  /// A refresh token, if the protocol has one.
  final String? refreshToken;

  /// When [refreshToken] expires.
  final DateTime? refreshExpiresAt;

  /// Extra non-secret protocol values stored with the token.
  final Map<String, String> attributes;

  @override
  String get type => 'token';

  @override
  JsonMap _secrets() => {
    'token': token,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (refreshExpiresAt != null)
      'refreshExpiresAt': isoTime(refreshExpiresAt!),
    if (attributes.isNotEmpty) 'attributes': attributes,
  };

  @override
  bool operator ==(Object other) =>
      other is TokenCredential &&
      _sameBase(other) &&
      other.token == token &&
      other.refreshToken == refreshToken &&
      _sameInstant(other.refreshExpiresAt, refreshExpiresAt) &&
      mapEquals(other.attributes, attributes);

  @override
  int get hashCode => Object.hash(
    _baseHash,
    token,
    refreshToken,
    refreshExpiresAt?.microsecondsSinceEpoch,
    mapHash(attributes),
  );
}

/// A client certificate and key that watchme generated (Android TV Remote
/// v2: the pairing secret depends on its modulus and exponent).
final class ClientCertCredential extends Credential {
  /// Creates a client-certificate credential.
  const ClientCertCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.certificatePem,
    required this.privateKeyPem,
    super.peerCertSha256,
    super.expiresAt,
  });

  /// Certificate chain, PEM.
  final String certificatePem;

  /// Private key, PEM.
  final String privateKeyPem;

  /// The certificate and key as a TLS client identity.
  ClientIdentity toIdentity() => ClientIdentity.pem(
    certificateChain: certificatePem,
    privateKey: privateKeyPem,
  );

  @override
  String get type => 'clientCert';

  @override
  JsonMap _secrets() => {
    'certificatePem': certificatePem,
    'privateKeyPem': privateKeyPem,
  };

  @override
  bool operator ==(Object other) =>
      other is ClientCertCredential &&
      _sameBase(other) &&
      other.certificatePem == certificatePem &&
      other.privateKeyPem == privateKeyPem;

  @override
  int get hashCode => Object.hash(_baseHash, certificatePem, privateKeyPem);
}

/// A vendor client certificate the user imported (VIDAA). watchme never
/// ships one.
final class UserSuppliedClientCertCredential extends Credential {
  /// Creates a user-supplied client-certificate credential.
  const UserSuppliedClientCertCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.certificatePem,
    required this.privateKeyPem,
    super.peerCertSha256,
    super.expiresAt,
    this.password,
    this.label,
  });

  /// Certificate chain, PEM.
  final String certificatePem;

  /// Private key, PEM.
  final String privateKeyPem;

  /// Password for an encrypted key, if any.
  final String? password;

  /// The user's name for this material.
  final String? label;

  /// The certificate and key as a TLS client identity.
  ClientIdentity toIdentity() => ClientIdentity.pem(
    certificateChain: certificatePem,
    privateKey: privateKeyPem,
    password: password,
  );

  @override
  String get type => 'userSuppliedClientCert';

  @override
  JsonMap _secrets() => {
    'certificatePem': certificatePem,
    'privateKeyPem': privateKeyPem,
    if (password != null) 'password': password,
    if (label != null) 'label': label,
  };

  @override
  bool operator ==(Object other) =>
      other is UserSuppliedClientCertCredential &&
      _sameBase(other) &&
      other.certificatePem == certificatePem &&
      other.privateKeyPem == privateKeyPem &&
      other.password == password &&
      other.label == label;

  @override
  int get hashCode =>
      Object.hash(_baseHash, certificatePem, privateKeyPem, password, label);
}

/// A long-term key pair: Apple HAP Ed25519 keys, an ADB RSA key.
final class KeyPairCredential extends Credential {
  /// Creates a key-pair credential.
  const KeyPairCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.algorithm,
    required this.publicKey,
    required this.privateKey,
    super.peerCertSha256,
    super.expiresAt,
    this.peerPublicKey,
    this.peerIdentifier,
  });

  /// Key algorithm, e.g. `ed25519`, `rsa2048`.
  final String algorithm;

  /// Our public key.
  final Uint8List publicKey;

  /// Our private key.
  final Uint8List privateKey;

  /// The device's long-term public key, when the protocol exchanges one.
  final Uint8List? peerPublicKey;

  /// The device's pairing identifier, when the protocol has one.
  final String? peerIdentifier;

  @override
  String get type => 'keyPair';

  @override
  JsonMap _secrets() => {
    'algorithm': algorithm,
    'publicKey': base64Of(publicKey),
    'privateKey': base64Of(privateKey),
    if (peerPublicKey != null) 'peerPublicKey': base64Of(peerPublicKey!),
    if (peerIdentifier != null) 'peerIdentifier': peerIdentifier,
  };

  @override
  bool operator ==(Object other) =>
      other is KeyPairCredential &&
      _sameBase(other) &&
      other.algorithm == algorithm &&
      listEquals(other.publicKey, publicKey) &&
      listEquals(other.privateKey, privateKey) &&
      listEquals(other.peerPublicKey, peerPublicKey) &&
      other.peerIdentifier == peerIdentifier;

  @override
  int get hashCode => Object.hash(
    _baseHash,
    algorithm,
    listHash(publicKey),
    listHash(privateKey),
    listHash(peerPublicKey),
    peerIdentifier,
  );
}

/// A shared secret: Sony PSK, LG IP Control keycode, Philips digest
/// user/key, Titan MQTT username/password.
final class SharedSecretCredential extends Credential {
  /// Creates a shared-secret credential.
  const SharedSecretCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.secret,
    super.peerCertSha256,
    super.expiresAt,
    this.username,
  });

  /// The secret.
  final String secret;

  /// A user name, where the protocol pairs one with the secret.
  final String? username;

  @override
  String get type => 'sharedSecret';

  @override
  JsonMap _secrets() => {
    'secret': secret,
    if (username != null) 'username': username,
  };

  @override
  bool operator ==(Object other) =>
      other is SharedSecretCredential &&
      _sameBase(other) &&
      other.secret == secret &&
      other.username == username;

  @override
  int get hashCode => Object.hash(_baseHash, secret, username);
}

/// Cloud OAuth tokens (SmartThings) plus the user's own OAuth app.
/// [Credential.expiresAt] is the access token's expiry.
final class CloudOAuthCredential extends Credential {
  /// Creates a cloud OAuth credential.
  const CloudOAuthCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.accessToken,
    required this.clientId,
    super.peerCertSha256,
    super.expiresAt,
    this.refreshToken,
    this.clientSecret,
    this.scopes = const [],
    this.tokenEndpoint,
  });

  /// Access token.
  final String accessToken;

  /// Rotating refresh token.
  final String? refreshToken;

  /// The user's OAuth client id.
  final String clientId;

  /// The user's OAuth client secret.
  final String? clientSecret;

  /// Granted scopes.
  final List<String> scopes;

  /// Token endpoint for refreshes.
  final Uri? tokenEndpoint;

  @override
  String get type => 'cloudOAuth';

  @override
  JsonMap _secrets() => {
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    'clientId': clientId,
    if (clientSecret != null) 'clientSecret': clientSecret,
    if (scopes.isNotEmpty) 'scopes': scopes,
    if (tokenEndpoint != null) 'tokenEndpoint': tokenEndpoint.toString(),
  };

  @override
  bool operator ==(Object other) =>
      other is CloudOAuthCredential &&
      _sameBase(other) &&
      other.accessToken == accessToken &&
      other.refreshToken == refreshToken &&
      other.clientId == clientId &&
      other.clientSecret == clientSecret &&
      listEquals(other.scopes, scopes) &&
      other.tokenEndpoint == tokenEndpoint;

  @override
  int get hashCode => Object.hash(
    _baseHash,
    accessToken,
    refreshToken,
    clientId,
    clientSecret,
    listHash(scopes),
    tokenEndpoint,
  );
}

/// watchme's Matter fabric material for the controller path. Certificates
/// are Matter TLV-encoded; 64-bit ids are decimal strings (web-safe).
final class MatterFabricCredential extends Credential {
  /// Creates a Matter fabric credential.
  const MatterFabricCredential({
    required super.driverId,
    required super.deviceId,
    required super.createdAt,
    required this.fabricId,
    required this.nodeId,
    required this.rootCertificate,
    required this.nodeOperationalCertificate,
    required this.operationalPrivateKey,
    required this.ipk,
    super.peerCertSha256,
    super.expiresAt,
    this.intermediateCertificate,
  });

  /// Fabric id.
  final String fabricId;

  /// Our node id on the fabric.
  final String nodeId;

  /// Root CA certificate.
  final Uint8List rootCertificate;

  /// Intermediate CA certificate, if any.
  final Uint8List? intermediateCertificate;

  /// Node operational certificate.
  final Uint8List nodeOperationalCertificate;

  /// Operational private key.
  final Uint8List operationalPrivateKey;

  /// Identity protection key.
  final Uint8List ipk;

  @override
  String get type => 'matterFabric';

  @override
  JsonMap _secrets() => {
    'fabricId': fabricId,
    'nodeId': nodeId,
    'rootCertificate': base64Of(rootCertificate),
    if (intermediateCertificate != null)
      'intermediateCertificate': base64Of(intermediateCertificate!),
    'nodeOperationalCertificate': base64Of(nodeOperationalCertificate),
    'operationalPrivateKey': base64Of(operationalPrivateKey),
    'ipk': base64Of(ipk),
  };

  @override
  bool operator ==(Object other) =>
      other is MatterFabricCredential &&
      _sameBase(other) &&
      other.fabricId == fabricId &&
      other.nodeId == nodeId &&
      listEquals(other.rootCertificate, rootCertificate) &&
      listEquals(other.intermediateCertificate, intermediateCertificate) &&
      listEquals(
        other.nodeOperationalCertificate,
        nodeOperationalCertificate,
      ) &&
      listEquals(other.operationalPrivateKey, operationalPrivateKey) &&
      listEquals(other.ipk, ipk);

  @override
  int get hashCode => Object.hash(
    _baseHash,
    fabricId,
    nodeId,
    listHash(rootCertificate),
    listHash(intermediateCertificate),
    listHash(nodeOperationalCertificate),
    listHash(operationalPrivateKey),
    listHash(ipk),
  );
}

/// Persists credentials. Implementations: [MemoryCredentialStore], a file
/// store in watchme_io, OS keystores in the app.
abstract interface class CredentialStore {
  /// The credential for ([deviceId], [driverId]), or `null`.
  Future<Credential?> read(String deviceId, String driverId);

  /// Every credential stored for [deviceId].
  Future<List<Credential>> readAll(String deviceId);

  /// Stores [credential], replacing any for the same device and driver.
  Future<void> write(Credential credential);

  /// Deletes the credential for [deviceId] and [driverId], or all of the
  /// device's credentials when [driverId] is `null`.
  Future<void> delete(String deviceId, {String? driverId});
}

/// A [CredentialStore] held in memory, for tests and ephemeral sessions.
final class MemoryCredentialStore implements CredentialStore {
  /// Creates a store, optionally seeded with [initial] credentials.
  MemoryCredentialStore([Iterable<Credential> initial = const []]) {
    for (final c in initial) {
      _items[(c.deviceId, c.driverId)] = c;
    }
  }

  final Map<(String, String), Credential> _items = {};

  @override
  Future<Credential?> read(String deviceId, String driverId) async =>
      _items[(deviceId, driverId)];

  @override
  Future<List<Credential>> readAll(String deviceId) async => [
    for (final MapEntry(:key, :value) in _items.entries)
      if (key.$1 == deviceId) value,
  ];

  @override
  Future<void> write(Credential credential) async {
    _items[(credential.deviceId, credential.driverId)] = credential;
  }

  @override
  Future<void> delete(String deviceId, {String? driverId}) async {
    _items.removeWhere(
      (key, _) =>
          key.$1 == deviceId && (driverId == null || key.$2 == driverId),
    );
  }
}
