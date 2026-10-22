import 'dart:math';

import 'package:watchme_core/watchme_core.dart';

import 'api.dart';
import 'constants.dart';
import 'descriptor.dart';
import 'session.dart';

/// The VIZIO SmartCast driver: the HTTPS REST API of SmartCast and VIZIO OS
/// TVs on port 7345 (9000 on firmware older than 4.0).
///
/// * [probe] is passive: it reads `GET /state/device/deviceinfo`, the one
///   read a TV answers without a token, on 7345 and then 9000, and reports
///   the port that answered as the `api` port of its refined endpoint. It
///   reports no power: `power_mode` needs the pairing token, so before
///   pairing the power is unknown, never off. Sound bars and speakers
///   (settings root `audio_settings`) are not claimed.
/// * [startPairing] reads deviceinfo with trust on first use, records the
///   certificate and pins it for the rest of pairing, sends
///   `PUT /pairing/start` (the TV shows a PIN), prompts with [EnterCode]
///   and sends `PUT /pairing/pair`. A wrong PIN may be re-entered up to
///   [maxPinAttempts] times. Whenever pairing ends without a token after
///   the TV may have shown a PIN (the user cancelled, the PIN was refused,
///   anything failed), it sends `PUT /pairing/cancel`, or the TV stays in
///   pairing mode. The [TokenCredential] carries the `AUTH` token, the
///   pinned certificate, and in its attributes the controller id the token
///   is bound to and the port ([VizioCredentialKeys]). Pairing again reuses
///   the controller id of the credential it replaces
///   ([PairingContext.previousCredential]), so the TV swaps the old token
///   for the new one; a first pairing makes a random id.
/// * [connect] never wakes the TV, whatever `allowWake` says: it only reads
///   deviceinfo and `power_mode`, and sends no Wake-on-LAN (the engine's
///   power orchestrator does that, best-effort, for a TV in Eco mode). A TV
///   whose port is closed fails at once as unreachable.
/// * No error carries the token or the PIN.
final class VizioDriver implements Driver {
  /// Creates the driver.
  ///
  /// [probeTimeout] bounds each port the probe and the port search of
  /// pairing and connect try. [readTimeout] and [writeTimeout] bound
  /// session `GET`s and `PUT`s. [pollInterval] is how often sessions poll
  /// while their events are listened to (`null` disables polling).
  /// [random] makes controller ids (a secure generator by default).
  VizioDriver({
    this._clock = const SystemClock(),
    this.probeTimeout = const Duration(milliseconds: 2500),
    this.readTimeout = const Duration(seconds: 6),
    this.writeTimeout = const Duration(seconds: 15),
    this.maxPinAttempts = 3,
    this.pollInterval = vizioDefaultPollInterval,
    Random? random,
  }) : _random = random ?? Random.secure();

  final Clock _clock;
  final Random _random;

  /// Deadline of each deviceinfo read while looking for the API port.
  final Duration probeTimeout;

  /// Deadline of a session `GET`.
  final Duration readTimeout;

  /// Deadline of a `PUT`.
  final Duration writeTimeout;

  /// Wrong PINs accepted before pairing fails.
  final int maxPinAttempts;

  /// Session polling period while events are listened to; `null` disables.
  final Duration? pollInterval;

  @override
  DriverDescriptor get descriptor => vizioDescriptor;

  // ------------------------------------------------------------------ probe

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    final network = transports.network;
    if (network == null) {
      return const ProbeResult.notMatched(
        error: WatchmeError.unsupported('No network transport available'),
      );
    }
    final ports = vizioPortCandidates(endpoint);
    final ({int port, VizioReply reply}) found;
    try {
      // Nothing secret is sent and nothing is recorded, so any certificate
      // will do.
      found = await _locate(
        endpoint,
        network,
        ports,
        tls: const TlsPolicy.firstUse(),
      );
    } on WatchmeError catch (e) {
      return ProbeResult.notMatched(
        error: e,
        notes: [
          'No VIZIO SmartCast API answered on port ${ports.join(' or ')}.',
        ],
      );
    }
    final (:port, :reply) = found;
    final info = VizioDeviceInfo.parse(reply);
    if (info == null) {
      return ProbeResult.notMatched(
        notes: [
          'Port $port answered (HTTP ${reply.status}), but not with VIZIO '
              'SmartCast device info.',
        ],
      );
    }
    if (info.isAudio) {
      return ProbeResult.notMatched(
        error: const WatchmeError.unsupported(
          'VIZIO sound bars and speakers are not supported by this driver '
          'yet',
        ),
        notes: [
          'A VIZIO audio device (${info.modelName ?? 'unknown model'}) '
              'answered on port $port.',
        ],
      );
    }
    final primary = endpoint.port(VizioPorts.api, VizioPorts.apiDefault);
    return ProbeResult.matched(
      info: _deviceInfo(endpoint.attributes, info, port),
      capabilities: vizioDescriptor.ceiling,
      requiresPairing: true,
      endpoint: port == primary
          ? null
          : endpoint.withPorts({VizioPorts.api: port}),
      notes: [
        'The VIZIO SmartCast API answered on port $port.',
        'Its power state needs pairing: power_mode requires the token.',
      ],
    );
  }

  static DeviceInfo _deviceInfo(
    Map<String, String> attrs,
    VizioDeviceInfo info,
    int port,
  ) {
    final cast = isVizioCastRecord(attrs);
    String? txt(String key) {
      final v = cast ? attrs[key]?.trim() : null;
      return v == null || v.isEmpty ? null : v;
    }

    return DeviceInfo(
      name: info.castName ?? attrs[DiscoveryAttr.friendlyName] ?? txt('name'),
      manufacturer: 'VIZIO',
      model: info.modelName ?? attrs[DiscoveryAttr.modelName],
      // TXT `wifi` is the MAC without separators (the Wake-on-LAN target).
      mac: tryNormalizeMac(txt('wifi') ?? ''),
      stableId: _stableId(info, attrs, txt),
      osVersion: info.version,
      extra: {
        'settingsRoot': ?info.settingsRoot,
        'apiVersion': ?info.apiVersion,
        'chipset': ?info.chipset,
        'apiPort': '$port',
      },
    );
  }

  static final RegExp _uuid = RegExp(
    r'uuid:([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})',
    caseSensitive: false,
  );

  static String? _stableId(
    VizioDeviceInfo info,
    Map<String, String> attrs,
    String? Function(String key) txt,
  ) {
    if (info.serialNumber case final serial?) return 'vizio:serial:$serial';
    // Firmware names the TXT device id `id` or `did`.
    if (txt('id') ?? txt('did') case final id?) {
      return 'vizio:id:${id.toLowerCase()}';
    }
    final match = _uuid.firstMatch(attrs[DiscoveryAttr.udn] ?? '');
    return match == null ? null : 'uuid:${match.group(1)!.toLowerCase()}';
  }

  /// Reads deviceinfo on each of [ports] in turn and returns the first
  /// answer, whatever its status. A port that refuses the connection
  /// (nothing reached the TV) or does not answer in time is skipped; any
  /// other failure (a certificate that is not the pinned one, a refused
  /// destination) ends the search. With no answer at all it throws
  /// [WatchmeErrorCode.unreachable], or [WatchmeErrorCode.timeout] if a
  /// port accepted the connection and then went silent.
  Future<({int port, VizioReply reply})> _locate(
    Endpoint endpoint,
    NetworkStack network,
    List<int> ports, {
    required TlsPolicy tls,
    bool Function()? cancelled,
  }) async {
    WatchmeError? failure;
    for (final port in ports) {
      if (cancelled?.call() ?? false) {
        throw const WatchmeError.cancelled('Pairing cancelled');
      }
      final api = VizioApi(
        endpoint,
        network,
        port: port,
        tls: tls,
        readTimeout: probeTimeout,
      );
      try {
        return (port: port, reply: await api.get(VizioPaths.deviceInfo));
      } on WatchmeError catch (e) {
        switch (e.code) {
          case WatchmeErrorCode.unreachable:
            failure ??= e;
          case WatchmeErrorCode.timeout:
            if (failure == null ||
                failure.code == WatchmeErrorCode.unreachable) {
              failure = e;
            }
          default:
            rethrow;
        }
      }
    }
    final list = ports.join(', ');
    final f = failure!;
    if (f.code == WatchmeErrorCode.unreachable) {
      throw WatchmeError.unreachable(
        'The VIZIO TV did not answer on port $list (it is off, in Eco '
        'mode, or not on the network)',
        rawDeviceMessage: f.rawDeviceMessage,
        cause: f,
      );
    }
    throw WatchmeError(
      f.code,
      'The VIZIO TV accepted a connection on port $list but did not answer '
      'in time',
      rawDeviceMessage: f.rawDeviceMessage,
      cause: f,
    );
  }

  // ---------------------------------------------------------------- pairing

  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) {
    final pairing = _Pairing(this, endpoint, transports, context);
    return PairingFlowController.run(pairing.run, onCancel: pairing.abandon);
  }

  /// A controller `DEVICE_ID` for one pairing: `watchme-` and 24 random hex
  /// digits. The token is bound to it.
  String _newControllerId() =>
      'watchme-${List.generate(12, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';

  /// The shape of every id [_newControllerId] makes.
  static final RegExp _controllerIdShape = RegExp(r'^watchme-[0-9a-f]{24}$');

  /// The controller id to pair under: the one this watchme paired the TV
  /// with before (from [PairingContext.previousCredential]), so the TV
  /// replaces that pairing's token instead of adding an entry to its
  /// pairing table (which fills up: `TOO_MANY_PAIRED_DEVICES`), or a new
  /// one. Only an id of watchme's own shape from a VIZIO credential for
  /// this device is reused; a store that fails to read gives a new one.
  Future<String> _controllerIdFor(PairingContext context) async {
    final Credential? previous;
    try {
      previous = await context.previousCredential?.call();
    } on Object {
      return _newControllerId();
    }
    if (previous
        case TokenCredential(
          driverId: vizioDriverId,
          :final deviceId,
          :final attributes,
        )
        when deviceId == context.deviceId) {
      final id = attributes[VizioCredentialKeys.controllerId];
      if (id != null && _controllerIdShape.hasMatch(id)) return id;
    }
    return _newControllerId();
  }

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
        'Pair with the VIZIO TV first',
      ),
      final TokenCredential c when c.driverId == vizioDriverId => c,
      _ => throw WatchmeError.unauthorized(
        'Not a VIZIO SmartCast credential: ${credential.type} for '
        '${credential.driverId}',
      ),
    };
    final TlsPolicy tls;
    try {
      tls = TlsPolicy.pinned([token.peerCertSha256 ?? '']);
    } on FormatException {
      throw const WatchmeError.reauthRequired(
        'The stored VIZIO credential has no valid certificate pin; pair '
        'again',
      );
    }
    final network = transports.requireNetwork();
    final secrets = [token.token];
    try {
      // Only reads: deviceinfo finds the port and checks the pinned
      // certificate, power_mode checks the token. Nothing here can wake the
      // TV or change what it shows, so allowWake changes nothing.
      final (:port, :reply) = await _locate(
        endpoint,
        network,
        vizioPortCandidates(
          endpoint,
          first: int.tryParse(token.attributes[VizioCredentialKeys.port] ?? ''),
        ),
        tls: tls,
      );
      final info = VizioDeviceInfo.parse(reply);
      if (info == null) {
        throw WatchmeError.protocol(
          'Port $port did not answer with VIZIO SmartCast device info',
          rawDeviceMessage: reply.text,
        );
      }
      if (info.isAudio) {
        throw const WatchmeError.unsupported(
          'VIZIO sound bars and speakers are not supported by this driver '
          'yet',
        );
      }
      final api = VizioApi(
        endpoint,
        network,
        port: port,
        tls: tls,
        token: token.token,
        readTimeout: readTimeout,
        writeTimeout: writeTimeout,
      );
      final power = await api.get(VizioPaths.powerMode);
      if (power.authRefused) {
        throw vizioError(power, 'Connecting', context: VizioContext.session);
      }
      final mode = parsePowerMode(power);
      return VizioSession(
        api,
        _clock,
        deviceInfo: info,
        power: mode == null
            ? null
            : Observed.reported(mode, vizioDriverId, _clock.now()),
        pollInterval: pollInterval,
      );
    } on WatchmeError catch (e) {
      throw redactError(e, secrets);
    }
  }
}

/// One pairing conversation. [abandon] runs on user cancel and on every
/// failure, and sends `PUT /pairing/cancel` once when the TV may be showing
/// a PIN for this pairing.
final class _Pairing {
  _Pairing(this.driver, this.endpoint, this.transports, this.context);

  final VizioDriver driver;
  final Endpoint endpoint;
  final Transports transports;
  final PairingContext context;

  /// The `DEVICE_ID` this pairing uses, chosen before the first request
  /// (see [VizioDriver._controllerIdFor]).
  late final String controllerId;

  /// Secrets met so far: a token the TV sent with a failure.
  final List<String> secrets = [];

  VizioApi? _api;

  /// Whether `/pairing/start` may have put a PIN on screen.
  bool _started = false;
  bool _cancelSent = false;
  bool _paired = false;

  /// What the TV is told it pairs with (`DEVICE_ID`, `DEVICE_NAME`).
  Map<String, Object?> get _identity => {
    'DEVICE_ID': controllerId,
    'DEVICE_NAME': context.clientName,
  };

  /// Tells the TV to drop the pairing, once, if it may be showing a PIN.
  /// Never throws: the pairing has failed or was cancelled already.
  Future<void> abandon() async {
    final api = _api;
    if (api == null || !_started || _cancelSent || _paired) return;
    _cancelSent = true;
    try {
      await api.put(
        VizioPaths.pairingCancel,
        _identity,
        timeout: driver.probeTimeout,
      );
    } on WatchmeError {
      // Best effort; the PIN times out on the TV eventually.
    }
  }

  Future<Credential> run(PairingFlowController flow) async {
    try {
      return await _pair(flow);
    } on WatchmeError catch (e) {
      await abandon();
      throw redactError(e, secrets);
    } on Object {
      await abandon();
      rethrow;
    }
  }

  Future<TokenCredential> _pair(PairingFlowController flow) async {
    final network = transports.requireNetwork();
    void checkCancelled() {
      if (flow.isCancelled) {
        throw const WatchmeError.cancelled('Pairing cancelled');
      }
    }

    controllerId = await driver._controllerIdFor(context);
    checkCancelled();
    // Trust on first use: accept the TV's self-signed certificate once (it
    // is the same on every VIZIO, so the token is the real secret), record
    // it, and pin it for the rest of pairing and every later call.
    final (:port, :reply) = await driver._locate(
      endpoint,
      network,
      vizioPortCandidates(endpoint),
      tls: const TlsPolicy.firstUse(),
      cancelled: () => flow.isCancelled,
    );
    final info = VizioDeviceInfo.parse(reply);
    if (info == null) {
      throw WatchmeError.protocol(
        'Port $port did not answer with VIZIO SmartCast device info',
        rawDeviceMessage: reply.text,
      );
    }
    if (info.isAudio) {
      throw const WatchmeError.unsupported(
        'VIZIO sound bars and speakers are not supported by this driver yet',
      );
    }
    final fingerprint =
        reply.http.peerCertificateSha256 ??
        (throw const WatchmeError.protocol(
          'The network stack did not report the VIZIO certificate, so it '
          'cannot be pinned',
        ));
    final api = _api = VizioApi(
      endpoint,
      network,
      port: port,
      tls: TlsPolicy.pinned([fingerprint]),
      readTimeout: driver.readTimeout,
      writeTimeout: driver.writeTimeout,
    );
    checkCancelled();

    final VizioReply started;
    try {
      started = await api.put(VizioPaths.pairingStart, _identity);
    } on WatchmeError catch (e) {
      // Unless it reached nothing, the start may have put a PIN on screen.
      _started =
          e.code != WatchmeErrorCode.unreachable &&
          e.code != WatchmeErrorCode.destinationRefused;
      rethrow;
    }
    final challenge = switch (started.item) {
      {'challenge_type': final int type, 'pairing_req_token': final int req}
          when started.success =>
        (type: type, req: req),
      _ => null,
    };
    // A refusal the TV spelt out (BLOCKED, TOO_MANY_PAIRED_DEVICES, ...)
    // started nothing; a success, or an answer without a status, may have.
    _started = started.success || started.result == null;
    if (!started.success) {
      throw vizioError(
        started,
        'Starting pairing',
        context: VizioContext.pairing,
      );
    }
    if (challenge == null) {
      throw WatchmeError.protocol(
        'The TV started pairing without a challenge',
        rawDeviceMessage: redactSecrets(started.text),
      );
    }
    checkCancelled();

    var label = 'PIN shown on the TV';
    for (var attempt = 1; ; attempt++) {
      final pin = await _askPin(flow, label);
      final answer = await api.put(VizioPaths.pairingPair, {
        'DEVICE_ID': controllerId,
        'CHALLENGE_TYPE': challenge.type,
        'RESPONSE_VALUE': pin,
        'PAIRING_REQ_TOKEN': challenge.req,
      });
      // The answer carries the new token when it succeeds, and an unusual
      // one may carry it anywhere: errors show it with every value
      // redacted except the status word.
      String shown() => redactSecrets(
        answer.text,
        secrets: secrets,
        allValues: true,
        keep: vizioResultWords,
      );
      if (answer.success) {
        // The token goes back as the AUTH header value, which must be
        // printable ASCII: anything else (CR/LF, say) could never be sent,
        // so storing it would only break every later connect. A token
        // refused for its characters is still a token: never shown.
        final token = switch (answer.item?['auth_token']) {
          final String t when _headerSafe.hasMatch(t) => t,
          _ => null,
        };
        if (token == null) {
          if (answer.item?['auth_token'] case final String t) secrets.add(t);
          throw WatchmeError.protocol(
            'The TV accepted the PIN but sent no usable token',
            rawDeviceMessage: shown(),
          );
        }
        _paired = true;
        return TokenCredential(
          driverId: vizioDriverId,
          deviceId: context.deviceId,
          createdAt: driver._clock.now(),
          token: token,
          peerCertSha256: fingerprint,
          attributes: {
            VizioCredentialKeys.controllerId: controllerId,
            VizioCredentialKeys.friendlyName: context.clientName,
            VizioCredentialKeys.port: '$port',
          },
        );
      }
      final wrongPin =
          answer.http.ok &&
          (answer.result == 'PAIRING_DENIED' ||
              answer.result == 'VALUE_OUT_OF_RANGE');
      if (wrongPin && attempt < driver.maxPinAttempts) {
        // The TV keeps the PIN on screen; the user may try again.
        label = 'Wrong PIN. Enter the PIN shown on the TV';
        continue;
      }
      if (wrongPin) {
        throw WatchmeError.unauthorized(
          'Wrong PIN ($attempt attempt${attempt == 1 ? '' : 's'})',
          rawDeviceMessage: shown(),
        );
      }
      throw vizioError(
        answer,
        'Checking the PIN',
        context: VizioContext.pairing,
        shown: shown(),
      );
    }
  }

  /// A token usable as an HTTP header value: printable ASCII, not blank.
  static final RegExp _headerSafe = RegExp(
    r'^[\x20-\x7e]*[\x21-\x7e][\x20-\x7e]*$',
  );

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
}
