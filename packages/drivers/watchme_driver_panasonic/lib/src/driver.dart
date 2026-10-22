import 'package:watchme_core/watchme_core.dart';

import 'client.dart';
import 'constants.dart';
import 'crypto.dart';
import 'descriptor.dart';
import 'redaction.dart';
import 'session.dart';
import 'soap.dart';

/// The Panasonic VIERA driver (`panasonic.viera`): the network remote
/// control (NRC) of 2011-2023 VIERA TVs, a UPnP/SOAP service on port 55000
/// ([PanasonicPorts.nrc]), plus UPnP RenderingControl for volume and mute.
///
/// Sets from 2018 on encrypt their NRC commands and pair with a PIN shown
/// on the TV; older sets take plain commands and need no pairing. 2024 and
/// later Panasonic TVs run Fire TV, Google TV, Roku or TiVo instead and are
/// not for this driver.
///
/// * [probe] is passive: it reads the NRC device and service descriptions,
///   the Pro AV description, and one RenderingControl volume read. It
///   decides whether the TV needs pairing from the service description and
///   records it in the endpoint attribute [panasonicEncryptionAttr]. Its
///   power observation is at most inferred: on when a Pro AV description
///   answers (only PAC models, only while on), standby when RenderingControl
///   answers HTTP 400. Answering at all proves nothing: a TV in network
///   standby answers its descriptions too.
/// * [startPairing] returns `null` for a TV the probe found plain. On an
///   encrypted TV it checks the TV is on (it shows a PIN only then), asks it
///   to show a PIN, prompts for it with [EnterCode], proves it, and returns
///   a [SharedSecretCredential] whose `username` is the TV's application id
///   and `secret` the encryption keyword. A wrong PIN shows a new one on
///   the TV and prompts again, up to [maxPinAttempts] times. There is no
///   way to take a PIN off the screen: cancelling sends nothing more.
/// * [connect] never wakes the TV, whatever `allowWake` says: it sends
///   neither Wake-on-LAN nor the power key, only reads and the plaintext
///   request that opens an encrypted session.
/// * No error, event or pairing step carries the application id, the
///   keyword, the challenge, the PIN or an encrypted blob.
final class PanasonicDriver implements Driver {
  /// Creates the driver.
  ///
  /// [requestTimeout] bounds each request of a session or pairing,
  /// [probeTimeout] each probe request and [probeBudget] the whole probe
  /// (the engine gives a probe 8 s). [pollInterval] is how often sessions
  /// poll while their events are listened to (`null` disables it).
  /// [allowKeyHolds] lets `PressKey` hold and release the d-pad and volume
  /// keys (`NRC_...-ON` / `-OFF`); it is off by default because a release
  /// that never arrives leaves the key held on the TV.
  PanasonicDriver({
    this._clock = const SystemClock(),
    this.requestTimeout = const Duration(seconds: 5),
    this.probeTimeout = const Duration(seconds: 3),
    this.probeBudget = const Duration(seconds: 6),
    this.maxPinAttempts = 3,
    this.pollInterval = panasonicDefaultPollInterval,
    this.allowKeyHolds = false,
  });

  final Clock _clock;

  /// Deadline of each session or pairing request.
  final Duration requestTimeout;

  /// Deadline of each probe request.
  final Duration probeTimeout;

  /// Deadline of the whole probe; optional reads are skipped once it is
  /// spent.
  final Duration probeBudget;

  /// PIN attempts before pairing fails.
  final int maxPinAttempts;

  /// Session polling period while events are listened to; `null` disables.
  final Duration? pollInterval;

  /// Whether key holds (`KeyAction.down` / `up`) are sent for the d-pad and
  /// volume keys.
  final bool allowKeyHolds;

  @override
  DriverDescriptor get descriptor => panasonicDescriptor;

  // ------------------------------------------------------------------ probe

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    final network = transports.network;
    if (network == null) {
      return const ProbeResult.notMatched(
        error: WatchmeError.unsupported('No network transport available'),
      );
    }
    final client = VieraClient(endpoint, network, timeout: probeTimeout);
    final port = client.port;
    final started = _clock.now();
    Duration? left() {
      final rest = probeBudget - _clock.now().difference(started);
      if (rest < const Duration(milliseconds: 200)) return null;
      return rest < probeTimeout ? rest : probeTimeout;
    }

    final HttpResult ddd;
    try {
      ddd = await client.get(VieraPaths.nrcDescription);
    } on WatchmeError catch (e) {
      return ProbeResult.notMatched(
        error: e,
        notes: ['No VIERA network remote control answered on port $port.'],
      );
    }
    if (!ddd.ok) {
      return ProbeResult.notMatched(
        // Only the subnet refusal says something the user can act on.
        error: ddd.status == 403
            ? vieraHttpError(ddd, 'Reading the NRC description')
            : null,
        notes: [
          'GET ${VieraPaths.nrcDescription} on port $port answered HTTP '
              '${ddd.status}.',
        ],
      );
    }
    final VieraDescription description;
    try {
      description = VieraDescription.parse(ddd.text);
    } on FormatException {
      return ProbeResult.notMatched(
        notes: ['Port $port serves no VIERA NRC description.'],
      );
    }
    if (!description.isRemoteController) {
      return ProbeResult.notMatched(
        notes: ['Port $port serves a UPnP device that is not a VIERA NRC.'],
      );
    }

    bool? encrypted;
    if (left() case final t?) {
      try {
        final sdd = await client.get(VieraPaths.nrcService, timeout: t);
        if (sdd.ok) encrypted = isEncryptedService(sdd.text);
      } on WatchmeError {
        encrypted = null;
      }
    }
    final now = _clock.now();
    Observed<PowerMode>? power;
    var pac = false;
    if (left() case final t?) {
      pac = await vieraPacAnswers(client, timeout: t);
      // A PAC description answers only while the TV is on.
      if (pac) power = Observed.inferred(PowerMode.on, panasonicDriverId, now);
    }
    if (power == null) {
      if (left() case final t?) {
        try {
          final volume = await client.soap(
            VieraService.dmr,
            'GetVolume',
            '<InstanceID>0</InstanceID><Channel>Master</Channel>',
            timeout: t,
          );
          // A hint: many sets refuse RenderingControl in standby, others
          // answer it, so only the refusal says anything.
          if (volume.status == 400) {
            power = Observed.inferred(
              PowerMode.standby,
              panasonicDriverId,
              now,
            );
          }
        } on WatchmeError {
          power = null;
        }
      }
    }

    return ProbeResult.matched(
      info: DeviceInfo(
        name: description.displayName,
        manufacturer: description.manufacturer ?? 'Panasonic',
        model: description.modelNumber ?? description.modelName,
        stableId: description.stableId,
        extra: {
          'nrcVersion': ?description.nrcVersion,
          'nrcCapabilities': ?description.nrcCapabilities?.join(','),
          'nrcId': ?description.nrcId,
          'udnMacCandidate': ?description.udnMacCandidate,
          'nrcIdMacCandidate': ?description.nrcIdMacCandidate,
          'encrypted': ?encrypted?.toString(),
          if (pac) 'pac': 'true',
        },
      ),
      capabilities: panasonicCapabilities(
        nrcCapabilities: description.nrcCapabilities,
        pac: pac,
      ),
      requiresPairing: encrypted ?? false,
      endpoint: encrypted == null
          ? null
          : endpoint.withAttributes({
              panasonicEncryptionAttr: encrypted
                  ? panasonicEncryptionAes
                  : panasonicEncryptionNone,
            }),
      power: power,
      notes: [
        switch (encrypted) {
          true =>
            'This TV encrypts its remote control: pair with it (it shows a '
                'PIN).',
          false => 'This TV takes plain commands; it needs no pairing.',
          null =>
            'Could not read the NRC service description, so whether the TV '
                'needs pairing is not known yet.',
        },
        if (power?.value == PowerMode.standby)
          'RenderingControl refused a request (HTTP 400): the TV is '
              'probably in standby.',
      ],
    );
  }

  // ---------------------------------------------------------------- pairing

  /// See the class notes. Returns `null` when the probe found the TV plain
  /// ([panasonicEncryptionAttr] is [panasonicEncryptionNone]); without that
  /// attribute the flow checks first and fails with
  /// [WatchmeErrorCode.unsupported] for a plain TV.
  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) {
    if (endpoint.attributes[panasonicEncryptionAttr] ==
        panasonicEncryptionNone) {
      return null;
    }
    return PairingFlowController.run((flow) async {
      final secrets = <String>[];
      try {
        return await _pair(flow, endpoint, transports, context, secrets);
      } on WatchmeError catch (e) {
        throw redactVieraError(e, secrets);
      } on Object catch (e) {
        throw WatchmeError.internal(
          redactViera('Pairing failed: $e', secrets: secrets),
        );
      }
    });
  }

  /// Runs pairing, adding every secret it sees (the challenge, the PIN,
  /// the new app id and keyword) to [secrets] before anything can fail.
  Future<SharedSecretCredential> _pair(
    PairingFlowController flow,
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
    List<String> secrets,
  ) async {
    void checkCancelled() {
      if (flow.isCancelled) {
        throw const WatchmeError.cancelled('Pairing cancelled');
      }
    }

    // A flow cancelled before it started sends nothing at all.
    checkCancelled();
    final client = VieraClient(
      endpoint,
      transports.requireNetwork(),
      timeout: requestTimeout,
    );
    final sdd = await client.get(VieraPaths.nrcService);
    if (!sdd.ok) {
      throw vieraHttpError(sdd, 'Reading the NRC service description');
    }
    if (!isEncryptedService(sdd.text)) {
      throw const WatchmeError.unsupported(
        'This Panasonic TV takes plain commands and needs no pairing',
      );
    }

    // The TV shows a PIN only while it is on, and pairing must not wake
    // it. RenderingControl refusing a read is the standby hint available
    // without UPnP eventing (an answer does not prove the TV is on).
    checkCancelled();
    final volume = await client.soap(
      VieraService.dmr,
      'GetVolume',
      '<InstanceID>0</InstanceID><Channel>Master</Channel>',
    );
    if (volume.status == 400) {
      throw WatchmeError.rejected(
        'Turn the TV on first: it seems to be in standby (it refused a '
        'volume request with HTTP 400), and it shows the pairing PIN only '
        'while on',
        rawDeviceMessage: volume.body.isEmpty ? 'HTTP 400' : volume.text,
      );
    }
    if (volume.status == 403) throw vieraHttpError(volume, 'Checking the TV');

    var label = 'Enter the PIN shown on the TV';
    for (var attempt = 1; ; attempt++) {
      checkCancelled();
      final shown = await client.soap(
        VieraService.nrc,
        'X_DisplayPinCode',
        '<X_DeviceName>${xmlEscape(context.clientName)}</X_DeviceName>',
      );
      final challenge = shown.ok
          ? xmlLeaf(shown.text, 'X_ChallengeKey')?.trim()
          : null;
      if (challenge != null && challenge.isNotEmpty) secrets.add(challenge);
      if (!shown.ok) {
        throw vieraHttpError(shown, 'Showing the PIN', secrets: secrets);
      }
      if (challenge == null || challenge.isEmpty) {
        throw WatchmeError.protocol(
          'The TV showed no PIN challenge (X_ChallengeKey missing)',
          rawDeviceMessage: redactViera(shown.text, secrets: secrets),
        );
      }
      final VieraKeys keys;
      try {
        keys = VieraKeys.forPairing(challenge);
      } on FormatException catch (e) {
        throw WatchmeError.protocol(
          'The TV sent an unusable PIN challenge: ${e.message}',
        );
      }
      if (attempt == 1) {
        flow.emit(
          const Instruct(
            'A PIN is now shown on the TV. If you stop pairing, dismiss it '
            "with the TV's own remote: watchme cannot remove it.",
          ),
        );
      }
      final pin = await _askPin(flow, label);
      secrets.add(pin);
      checkCancelled();
      final auth = await client.soap(
        VieraService.nrc,
        'X_RequestAuth',
        '<X_AuthInfo>${vieraSeal(keys, '<X_PinCode>$pin</X_PinCode>')}'
            '</X_AuthInfo>',
      );
      if (auth.status == 500 && parseSoapFault(auth.text).code == 600) {
        // A wrong (or expired) PIN. The TV may have dropped its challenge,
        // so a new PIN is shown before asking again, as Home Assistant does.
        if (attempt >= maxPinAttempts) {
          throw WatchmeError.unauthorized(
            'Wrong PIN ($attempt attempts)',
            rawDeviceMessage: redactViera(auth.text, secrets: secrets),
          );
        }
        label = 'Wrong PIN. Enter the new PIN shown on the TV';
        continue;
      }
      if (!auth.ok) {
        throw vieraHttpError(auth, 'Checking the PIN', secrets: secrets);
      }
      return _credentialFrom(client, auth, keys, context, secrets);
    }
  }

  /// The credential in an accepted `X_RequestAuth` answer, verified by
  /// opening an encrypted session with it.
  Future<SharedSecretCredential> _credentialFrom(
    VieraClient client,
    HttpResult auth,
    VieraKeys keys,
    PairingContext context,
    List<String> secrets,
  ) async {
    final blob = xmlLeaf(auth.text, 'X_AuthResult');
    String? appId;
    String? keyword;
    if (blob != null) {
      try {
        final text = vieraOpen(keys, blob).text;
        appId = xmlLeaf(text, 'X_ApplicationId')?.trim();
        keyword = xmlLeaf(text, 'X_Keyword')?.trim();
      } on FormatException {
        appId = null;
      }
    }
    secrets.addAll([?appId, ?keyword]);
    if (appId == null || appId.isEmpty || keyword == null) {
      throw WatchmeError.protocol(
        'The TV accepted the PIN but sent no pairing key watchme can read',
        rawDeviceMessage: redactViera(auth.text, secrets: secrets),
      );
    }
    final VieraKeys sessionKeys;
    try {
      sessionKeys = VieraKeys.forSession(keyword);
    } on FormatException {
      throw const WatchmeError.protocol(
        'The TV accepted the PIN but sent a malformed pairing key',
      );
    }
    // The TV has just issued the credential, so any failure to use it is
    // the TV's: a protocol error, never a reason to re-pair.
    try {
      final r = await client.soap(
        VieraService.nrc,
        'X_GetEncryptSessionId',
        vieraSessionRequestArgs(appId, sessionKeys),
      );
      if (!r.ok || vieraSessionIdFrom(r.text, sessionKeys) == null) {
        throw WatchmeError.protocol(
          'The TV issued a pairing key but then refused a session with it '
          '(HTTP ${r.status})',
          rawDeviceMessage: r.body.isEmpty
              ? 'HTTP ${r.status}'
              : redactViera(r.text, secrets: secrets),
        );
      }
    } on WatchmeError catch (e) {
      if (e.code == WatchmeErrorCode.protocol) rethrow;
      throw WatchmeError.protocol(
        'Checking the new pairing failed: ${e.message}',
        rawDeviceMessage: e.rawDeviceMessage,
        cause: e,
      );
    }
    return SharedSecretCredential(
      driverId: panasonicDriverId,
      deviceId: context.deviceId,
      createdAt: _clock.now(),
      username: appId,
      secret: keyword,
    );
  }

  static Future<String> _askPin(
    PairingFlowController flow,
    String label,
  ) async {
    var step = EnterCode(label, 4, CodeAlphabet.digits);
    while (true) {
      final pin = (await flow.prompt(step)).trim();
      if (step.accepts(pin)) return pin;
      step = const EnterCode(
        'The PIN is the 4 digits shown on the TV',
        4,
        CodeAlphabet.digits,
      );
    }
  }

  // ---------------------------------------------------------------- connect

  /// Opens a [PanasonicSession]. [allowWake] makes no difference: nothing
  /// this driver sends while connecting can wake the TV or change what it
  /// shows (see the class notes).
  ///
  /// Throws [WatchmeError] as described in [PanasonicSession.connect], and
  /// [WatchmeErrorCode.unauthorized] for a credential of another kind.
  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  }) async {
    final SharedSecretCredential? shared = switch (credential) {
      null => null,
      final SharedSecretCredential c when c.driverId == panasonicDriverId => c,
      _ => throw WatchmeError.unauthorized(
        'Not a Panasonic VIERA credential: ${credential.type} for '
        '${credential.driverId}',
      ),
    };
    return PanasonicSession.connect(
      VieraClient(
        endpoint,
        transports.requireNetwork(),
        timeout: requestTimeout,
      ),
      shared,
      clock: _clock,
      pollInterval: pollInterval,
      allowKeyHolds: allowKeyHolds,
    );
  }
}
