import 'package:watchme_core/watchme_core.dart';

import 'api.dart';
import 'constants.dart';
import 'descriptor.dart';
import 'session.dart';

/// The Amazon Fire TV driver: DIAL wake, PIN pairing and the HTTPS remote
/// API ("Lightning") of the official mobile remote app.
///
/// * [probe] is passive and needs an answer from the device: it reads
///   `GET /v1/FireTV/status` without a token and, when the remote API does
///   not answer, the DIAL status of the `FireTVRemote` app (a `GET`, which
///   DIAL defines as side-effect free), so a sleeping device still matches.
///   Discovery attributes only identify the device; with no answer at all
///   the probe fails as unreachable. It never sends the DIAL wake. It
///   reports the power it saw: on (inferred) when the API answers, standby
///   (inferred) when the API port is closed while DIAL answers.
/// * [startPairing] wakes the device, asks it to show a PIN, prompts for it
///   with [EnterCode] and returns a [TokenCredential] whose
///   [Credential.peerCertSha256] is the device certificate recorded on
///   first use.
/// * [connect] wakes the device through DIAL every time (the API port does
///   not listen while the device sleeps), then verifies the token with the
///   recorded certificate pinned. With `allowWake: false` (connections the
///   user did not ask for) it sends no DIAL launch and fails at once as
///   unreachable while the API port is closed.
/// * No error carries a bearer value: the client token, a token a PIN
///   verification returned, and the `X-Api-Key` value are redacted from
///   every error text, along with token-bearing JSON fields.
///
/// Ports come from the endpoint names [FireTvPorts.dial] and
/// [FireTvPorts.api].
final class FireTvDriver implements Driver {
  /// Creates the driver.
  ///
  /// After a DIAL wake the API port opens a moment later; calls that find
  /// it closed are retried every [apiPollInterval] for up to
  /// [apiStartupTimeout]. A wrong PIN may be re-entered until
  /// [maxPinAttempts] attempts have failed.
  FireTvDriver({
    this._clock = const SystemClock(),
    this.apiStartupTimeout = const Duration(seconds: 6),
    this.apiPollInterval = const Duration(milliseconds: 500),
    this.probeTimeout = const Duration(seconds: 3),
    this.maxPinAttempts = 3,
  });

  final Clock _clock;

  /// How long to wait for the API port to open after a DIAL wake.
  final Duration apiStartupTimeout;

  /// How often to retry while waiting for the API port.
  final Duration apiPollInterval;

  /// Timeout of the probe's read-only status call.
  final Duration probeTimeout;

  /// Wrong PINs accepted before pairing fails.
  final int maxPinAttempts;

  @override
  DriverDescriptor get descriptor => fireTvDescriptor;

  // ------------------------------------------------------------------ probe

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    final network = transports.network;
    if (network == null) {
      return const ProbeResult.notMatched(
        error: WatchmeError.unsupported('No network transport available'),
      );
    }
    final attrs = endpoint.attributes;
    final advertised = _advertisedAsFireTv(attrs);
    final apiPort = endpoint.port(FireTvPorts.api, FireTvPorts.apiDefault);

    // Read-only and token-less: a paired-only API answers 401/403, which
    // still proves it is there. Accepts any certificate because nothing
    // secret is sent and nothing is recorded.
    final api = FireTvApi(endpoint, network, tls: const TlsPolicy.firstUse());
    FireTvStatus? status;
    var apiAnswered = false;
    var apiReachable = false;
    WatchmeError? failure;
    try {
      final result = await api.get(FireTvPaths.status, timeout: probeTimeout);
      apiReachable = true;
      if (isAuthFailure(result)) {
        apiAnswered = true;
      } else if (result.ok) {
        status = parseStatus(result);
        apiAnswered = status != null;
      }
    } on WatchmeError catch (e) {
      failure = e;
    }

    final refined = _refineDialPort(endpoint);
    // A sleeping Fire TV has a closed API port; its DIAL server still
    // answers and reports the FireTVRemote app. An advertisement names the
    // device but proves nothing about it being there now, so DIAL is asked
    // whenever the API is silent.
    var dialAnswered = false;
    var dialIsFireTv = false;
    if (!apiAnswered) {
      try {
        final dial = await FireTvApi(
          refined,
          network,
          tls: TlsPolicy.platform,
        ).dialStatus(timeout: probeTimeout);
        dialAnswered = true;
        dialIsFireTv = isFireTvRemoteDialStatus(dial);
      } on WatchmeError catch (e) {
        failure ??= e;
      }
    }
    final identified = apiAnswered || dialIsFireTv || advertised;
    final reachable = apiReachable || dialAnswered;
    if (!identified || !reachable) {
      return ProbeResult.notMatched(
        error: reachable
            ? null
            : failure ??
                  const WatchmeError.unreachable('The Fire TV did not answer'),
        notes: [
          if (advertised)
            'Neither the Fire TV remote API on port $apiPort nor its DIAL '
                'server answered.'
          else
            'No Fire TV advertisement, no Fire TV remote API on port $apiPort '
                'and no FireTVRemote DIAL app.',
        ],
      );
    }
    final now = _clock.now();
    return ProbeResult.matched(
      info: DeviceInfo(
        name:
            attrs[DiscoveryAttr.friendlyName] ??
            _whisperPlay(attrs, 'n') ??
            _instanceName(attrs),
        manufacturer: 'Amazon',
        model: attrs[DiscoveryAttr.modelName],
        stableId: _stableId(attrs),
        osVersion: status?.osVersion,
        extra: {
          'platformType': ?status?.platformType,
          'turnstileVersion': ?status?.turnstileVersion,
        },
      ),
      capabilities: fireTvDescriptor.ceiling,
      requiresPairing: true,
      endpoint: refined == endpoint ? null : refined,
      // The API listens only while the device is awake (hms-firetv: "8080
      // does not listen while asleep"); a refused API port next to a live
      // DIAL server is a sleeping device.
      power: apiAnswered
          ? Observed.inferred(PowerMode.on, fireTvDriverId, now)
          : dialAnswered && failure?.code == WatchmeErrorCode.unreachable
          ? Observed.inferred(PowerMode.standby, fireTvDriverId, now)
          : null,
      notes: [
        if (apiAnswered)
          'The Fire TV remote API answered on port $apiPort.'
        else
          'The Fire TV remote API on port $apiPort did not answer (the '
              'device is probably asleep); connecting wakes it through DIAL.',
      ],
    );
  }

  static bool _advertisedAsFireTv(Map<String, String> attrs) {
    final manufacturer = attrs[DiscoveryAttr.manufacturer]?.toLowerCase();
    final model = attrs[DiscoveryAttr.modelName] ?? '';
    if (manufacturer == 'amazon' && model.startsWith('AFT')) return true;
    if (attrs[DiscoveryAttr.mdnsService]?.toLowerCase() ==
        '_amzn-firetv._tcp') {
      return true;
    }
    // Otherwise look for the tokens Fire TV mDNS records carry: `amzn.dmgr`
    // (WhisperPlay) or a full `_amzn-fireTv._tcp` instance name.
    return attrs.values.any((v) {
      final lower = v.toLowerCase();
      return lower.contains('amzn.dmgr') || lower.contains('_amzn-firetv._tcp');
    });
  }

  /// A TXT entry of a WhisperPlay (`_amzn-wplay._tcp`) record. Observed on
  /// a Fire TV stick: `n` is the name the user gave the device and `u` a
  /// 32-hex-digit device id that also appears in the `amzn.dmgr:` instance
  /// label.
  static String? _whisperPlay(Map<String, String> attrs, String key) {
    final whisperPlay =
        attrs[DiscoveryAttr.mdnsService]?.toLowerCase() == '_amzn-wplay._tcp' ||
        (attrs[DiscoveryAttr.mdnsInstance]?.contains('amzn.dmgr') ?? false);
    final value = attrs[key]?.trim();
    return whisperPlay && value != null && value.isNotEmpty ? value : null;
  }

  static String? _instanceName(Map<String, String> attrs) {
    final instance = attrs[DiscoveryAttr.mdnsInstance];
    if (instance == null || instance.contains('amzn.dmgr')) return null;
    final cut = instance.indexOf('._');
    return cut > 0 ? instance.substring(0, cut) : instance;
  }

  static final RegExp _uuid = RegExp(
    r'uuid:([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})',
    caseSensitive: false,
  );

  static String? _stableId(Map<String, String> attrs) {
    for (final key in [DiscoveryAttr.udn, DiscoveryAttr.usn]) {
      final match = _uuid.firstMatch(attrs[key] ?? '');
      if (match != null) return 'uuid:${match.group(1)!.toLowerCase()}';
    }
    final id = _whisperPlay(attrs, 'u');
    if (id != null && RegExp(r'^[0-9a-fA-F]{16,64}$').hasMatch(id)) {
      return 'amzn.dmgr:${id.toLowerCase()}';
    }
    return null;
  }

  /// Takes the DIAL port from the SSDP `Application-URL` when it is a plain
  /// `http://<same host>:<port>/apps/` base and no port was set explicitly.
  static Endpoint _refineDialPort(Endpoint endpoint) {
    if (endpoint.ports.containsKey(FireTvPorts.dial)) return endpoint;
    final url = Uri.tryParse(
      endpoint.attributes[DiscoveryAttr.applicationUrl] ?? '',
    );
    if (url == null ||
        url.scheme != 'http' ||
        !url.hasPort ||
        url.host != endpoint.host ||
        !const {'/apps', '/apps/'}.contains(url.path)) {
      return endpoint;
    }
    return endpoint.withPorts({FireTvPorts.dial: url.port});
  }

  // ---------------------------------------------------------------- pairing

  /// Errors never carry a token: a PIN-verify answer that fails, whatever
  /// its status, is shown with every value redacted except plain words in
  /// a refusal (see [redactSecrets]), and every known bearer value (the
  /// `X-Api-Key` value, a token the device sent) is removed from every
  /// error text, in any escaped form.
  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) => PairingFlowController.run((flow) async {
    final secrets = [fireTvApiKey];
    try {
      return await _pair(flow, endpoint, transports, context, secrets);
    } on WatchmeError catch (e) {
      throw redactError(e, secrets);
    }
  });

  /// Runs pairing, adding every token the device sends to [secrets].
  Future<TokenCredential> _pair(
    PairingFlowController flow,
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
    List<String> secrets,
  ) async {
    final network = transports.requireNetwork();
    // A flow cancelled before (or while) the device wakes must not wake it
    // or put a PIN on the TV for a pairing nobody is doing.
    void checkCancelled() {
      if (flow.isCancelled) {
        throw const WatchmeError.cancelled('Pairing cancelled');
      }
    }

    checkCancelled();
    // Trust on first use: accept the device's self-signed certificate once,
    // record it, and pin it for the rest of pairing and every later call.
    final firstUse = FireTvApi(
      endpoint,
      network,
      tls: const TlsPolicy.firstUse(),
    );
    final wakeFailure = await tryWake(firstUse);
    final HttpResult shown;
    try {
      shown = await _untilListening(
        (timeout) => firstUse.post(
          FireTvPaths.pinDisplay,
          json: {'friendlyName': context.clientName},
          timeout: timeout,
        ),
        cancelled: () => flow.isCancelled,
      );
    } on WatchmeError catch (e) {
      throw withWakeContext(e, wakeFailure);
    }
    if (!shown.ok) throw _pairingError(shown, 'Showing the PIN');
    final fingerprint = shown.peerCertificateSha256;
    if (fingerprint == null) {
      throw const WatchmeError.protocol(
        'The network stack did not report the Fire TV certificate, so it '
        'cannot be pinned',
      );
    }

    final pinned = FireTvApi(
      endpoint,
      network,
      tls: TlsPolicy.pinned([fingerprint]),
    );
    var label = 'Enter the PIN shown on the TV';
    for (var attempt = 1; ; attempt++) {
      final pin = await _askPin(flow, label);
      final verified = await pinned.post(
        FireTvPaths.pinVerify,
        json: {'pin': pin},
      );
      // This answer carries the new token in `description`, whatever its
      // status, and an unexpected one may carry it anywhere: an error shows
      // it with every value redacted, keeping only plain words ("PIN
      // expired") in a refusal.
      String shown() => redactSecrets(
        verified.text,
        secrets: secrets,
        allValues: true,
        keepProse: !verified.ok,
      );
      if (!verified.ok) throw _pinVerifyError(verified, shown());
      final token = description(verified);
      if (token == null) {
        throw WatchmeError.protocol(
          'The Fire TV answered the PIN without a description field',
          rawDeviceMessage: shown(),
        );
      }
      if (token.isEmpty) {
        // Wrong PIN; the TV keeps showing it, so the user may try again.
        if (attempt >= maxPinAttempts) {
          throw WatchmeError.unauthorized(
            'Wrong PIN ($attempt attempts)',
            rawDeviceMessage: shown(),
          );
        }
        label = 'Wrong PIN. Enter the PIN shown on the TV';
        continue;
      }
      if (token == 'OK' || !isPrintableToken(token)) {
        // hms-firetv sees "OK" when the PIN is accepted but no token is
        // issued yet; there is no documented way to fetch it later. A token
        // refused for its characters is still a token: never show it.
        if (token != 'OK') secrets.add(token);
        throw WatchmeError.protocol(
          'The Fire TV accepted the PIN but returned no usable token',
          rawDeviceMessage: shown(),
        );
      }
      return TokenCredential(
        driverId: fireTvDriverId,
        deviceId: context.deviceId,
        createdAt: _clock.now(),
        token: token,
        peerCertSha256: fingerprint,
        attributes: {'friendlyName': context.clientName},
      );
    }
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

  /// [_pairingError] for a refused PIN check, showing [shown] (the answer,
  /// redacted) instead of the body: the status is in the message.
  static WatchmeError _pinVerifyError(HttpResult result, String shown) {
    final error = _pairingError(result, 'Checking the PIN');
    return WatchmeError(
      error.code,
      error.message,
      rawDeviceMessage: result.body.isEmpty ? error.rawDeviceMessage : shown,
      cause: error.cause,
    );
  }

  static WatchmeError _pairingError(HttpResult result, String what) =>
      switch (result.status) {
        401 || 403 => result.toError(
          WatchmeErrorCode.unauthorized,
          '$what: the Fire TV refused (HTTP ${result.status})',
        ),
        _ => apiError(result, what),
      };

  // ---------------------------------------------------------------- connect

  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  }) async {
    final token = switch (credential) {
      null => throw const WatchmeError.unauthorized(
        'Pair with the Fire TV first',
      ),
      final TokenCredential c when c.driverId == fireTvDriverId => c,
      _ => throw WatchmeError.unauthorized(
        'Not a Fire TV remote credential: ${credential.type} for '
        '${credential.driverId}',
      ),
    };
    final TlsPolicy tls;
    try {
      tls = TlsPolicy.pinned([token.peerCertSha256 ?? '']);
    } on FormatException {
      throw const WatchmeError.reauthRequired(
        'The stored Fire TV credential has no valid certificate pin; pair '
        'again',
      );
    }
    final network = transports.requireNetwork();
    final api = FireTvApi(endpoint, network, tls: tls, token: token.token);
    try {
      final result = allowWake
          ? await _wakeAndReadStatus(api)
          : await _readStatusWithoutWaking(api, endpoint);
      if (isAuthFailure(result)) throw api.errorFor(result, 'Connecting');
      // A firmware without the status endpoint still takes commands; the
      // token is then checked by the first one.
      if (!result.ok && result.status != 404) {
        throw api.errorFor(result, 'Connecting');
      }
      return FireTvSession(
        api,
        _clock,
        status: result.ok ? parseStatus(result) : null,
        apiStartupTimeout: apiStartupTimeout,
        apiPollInterval: apiPollInterval,
      );
    } on WatchmeError catch (e) {
      throw api.redact(e);
    }
  }

  /// Port 8080 does not listen while the device sleeps: wakes it through
  /// DIAL first, every time, then waits for the API to answer.
  Future<HttpResult> _wakeAndReadStatus(FireTvApi api) async {
    final wakeFailure = await tryWake(api);
    try {
      return await _untilListening(
        (timeout) => api.get(FireTvPaths.status, timeout: timeout),
      );
    } on WatchmeError catch (e) {
      throw withWakeContext(e, wakeFailure);
    }
  }

  /// Reads the status once and sends nothing that could wake the device. A
  /// closed API port (the device sleeps, or is gone) fails at once as
  /// unreachable.
  static Future<HttpResult> _readStatusWithoutWaking(
    FireTvApi api,
    Endpoint endpoint,
  ) async {
    try {
      return await api.get(FireTvPaths.status);
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.unreachable) rethrow;
      final port = endpoint.port(FireTvPorts.api, FireTvPorts.apiDefault);
      throw WatchmeError.unreachable(
        'The Fire TV remote API on port $port is not listening (the device '
        'is asleep or gone), and connecting without waking it was asked',
        rawDeviceMessage: e.rawDeviceMessage,
        cause: e,
      );
    }
  }

  Future<T> _untilListening<T>(
    Future<T> Function(Duration attemptTimeout) call, {
    bool Function()? cancelled,
  }) => untilListening(
    call,
    clock: _clock,
    timeout: apiStartupTimeout,
    interval: apiPollInterval,
    cancelled: cancelled,
  );
}
