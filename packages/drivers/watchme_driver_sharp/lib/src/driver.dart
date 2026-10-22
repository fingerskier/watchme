import 'package:watchme_core/watchme_core.dart';

import 'capabilities.dart';
import 'constants.dart';
import 'descriptor.dart';
import 'link.dart';
import 'profiles.dart';
import 'protocol.dart';
import 'redaction.dart';
import 'session.dart';

/// The Sharp AQUOS driver: the IP-control text protocol on TCP port 10002
/// ([SharpPorts.ipc]), with an optional login.
///
/// * [probe] is passive. It opens the port and listens: a TV that asks for
///   a login is matched without anything being sent (answering the prompt
///   would be a login attempt). One with login disabled is asked `POWR?`
///   and the information reads (`MNRD1`, `TVNM1`, `SWVN1`, `IPPV1`), all
///   of them queries that change nothing.
/// * [startPairing] returns a flow for every Sharp TV, although
///   [DriverDescriptor.requiresPairing] is false: it collects the login ID
///   and password with [EnterText] when (and only when) the TV asks for
///   them, checks them, and, for a model whose power-on over IP depends on
///   the RSPW setting while that setting is off, asks [ConfirmChange]
///   before writing it. Nothing else is ever written to the TV's settings.
/// * [connect] logs in as the credential says and reads the model and
///   state; nothing it sends can wake the TV, so `allowWake` changes
///   nothing.
///
/// A credential is a [SharedSecretCredential]: the login ID as `username`
/// and the password as `secret`. One with no `username` (`null`) and an
/// empty `secret` means "this TV asks for no login" ([isSharpNoLogin]).
final class SharpDriver implements Driver {
  /// Creates the driver.
  ///
  /// [pollInterval] is how often sessions poll while their events are
  /// listened to (`null` disables polling). A wrong login may be entered
  /// again until [maxLoginAttempts] attempts have failed.
  SharpDriver({
    this._clock = const SystemClock(),
    this.timings = const SharpTimings(),
    this.pollInterval = sharpDefaultPollInterval,
    this.maxLoginAttempts = 3,
  });

  final Clock _clock;

  /// Every wait the driver makes.
  final SharpTimings timings;

  /// Session polling period while events are listened to; `null` disables.
  final Duration? pollInterval;

  /// Wrong logins accepted before pairing fails.
  final int maxLoginAttempts;

  @override
  DriverDescriptor get descriptor => sharpDescriptor;

  // ------------------------------------------------------------------ probe

  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    final network = transports.network;
    if (network == null) {
      return const ProbeResult.notMatched(
        error: WatchmeError.unsupported('No network transport available'),
      );
    }
    final port = endpoint.port(SharpPorts.ipc, SharpPorts.ipcDefault);
    final started = _clock.now();
    final SharpLink link;
    try {
      link = await SharpLink.open(
        network,
        endpoint.host,
        port,
        clock: _clock,
        timings: timings,
      );
    } on WatchmeError catch (e) {
      return ProbeResult.notMatched(
        error: e,
        notes: [
          'Nothing accepted a connection on port $port: IP control may be '
              'off, the TV may be off without network standby, or it may use '
              'another port.',
        ],
      );
    }
    try {
      final bool prompted;
      try {
        prompted = await link.awaitPrompt(timings.promptWait);
      } on SharpLinkDown {
        return ProbeResult.notMatched(
          error: WatchmeError.unreachable(
            'The device on port $port closed the connection at once',
          ),
        );
      } on WatchmeError catch (e) {
        return ProbeResult.notMatched(error: e);
      }
      final attrs = endpoint.attributes;
      if (prompted) {
        final profile = _profileFor(endpoint, null);
        return ProbeResult.matched(
          info: _info(endpoint, profile: profile.profile),
          capabilities: sharpCapabilities(
            profile.profile,
            volumeCertain: profile.volumeCertain,
            volumeMax: profile.volumeMax,
          ),
          requiresPairing: true,
          notes: const [
            'The TV asks for the login ID and password set on its IP '
                'control menu; pair with it to enter them.',
          ],
        );
      }
      // Login is off. One read-only query tells a Sharp TV from anything
      // else that listens on the port.
      final String power;
      try {
        power = await link.request(
          sharpQuery('POWR'),
          timeout: timings.probeReply,
          skipOk: true,
        );
      } on WatchmeError catch (e) {
        return ProbeResult.notMatched(
          error: e,
          notes: [
            'Something on port $port accepted the connection but did not '
                'answer POWR? like a Sharp TV.',
          ],
        );
      }
      if (!const {'0', '1', sharpErr}.contains(power)) {
        return ProbeResult.notMatched(
          error: WatchmeError.protocol(
            'Not a Sharp IP-control port: unexpected answer to POWR?',
            rawDeviceMessage: power,
          ),
        );
      }
      Future<String?> read(String command) async {
        if (!link.isOpen ||
            _clock.now().difference(started) >= timings.probeBudget) {
          return null;
        }
        try {
          final reply = await link.request(
            sharpFrame(command, '1'),
            timeout: timings.probeReply,
            skipOk: true,
          );
          return reply == sharpErr || reply.isEmpty ? null : reply;
        } on Object {
          return null;
        }
      }

      final model = await read('MNRD');
      final name = await read('TVNM');
      final software = await read('SWVN');
      final profile = _profileFor(endpoint, model, powerRead: power);
      final version =
          await read(profile.profile.versionCommand) ??
          await read(
            profile.profile.versionCommand == 'IPPV' ? 'IPPY' : 'IPPV',
          );
      final now = _clock.now();
      return ProbeResult.matched(
        info: _info(
          endpoint,
          profile: profile.profile,
          name: name,
          model: model,
          software: software,
          version: version,
        ),
        capabilities: sharpCapabilities(
          profile.profile,
          powerStateSeen: power != sharpErr,
          volumeCertain: profile.volumeCertain,
          volumeMax: profile.volumeMax,
        ),
        power: switch (power) {
          '1' => Observed.reported(PowerMode.on, sharpDriverId, now),
          '0' => Observed.reported(PowerMode.standby, sharpDriverId, now),
          _ => null,
        },
        notes: [
          if (power == '0')
            'The TV is in standby and keeps IP control listening, so it can '
                'be turned on over the network.',
          if (power == sharpErr)
            'The TV refuses POWR?: its power state cannot be read.',
          if (profile.profile == SharpProfile.us2015Limited)
            'This firmware refuses every query: power, mute toggle and '
                'remote keys work, without feedback.',
          if (attrs[SharpAttributes.profile] == null && model == null)
            'The TV did not report its model; watchme assumes the '
                '${profile.profile.label} command set.',
        ],
      );
    } finally {
      await link.close();
    }
  }

  /// The profile for [endpoint]: its `sharp.profile` attribute, else
  /// [model] (`MNRD1`), else the UPnP model name, else [SharpProfile.us2011]
  /// with the volume scale in doubt. A TV that refuses every query
  /// ([powerRead] `ERR` and no [model]) is the 2015 firmware.
  static SharpModelMatch _profileFor(
    Endpoint endpoint,
    String? model, {
    String? powerRead,
  }) {
    final attrs = endpoint.attributes;
    final fixed = SharpProfile.byId(attrs[SharpAttributes.profile]);
    if (fixed != null) {
      return (profile: fixed, volumeCertain: true, volumeMax: fixed.volumeMax);
    }
    final match =
        sharpProfileForModel(model) ??
        sharpProfileForModel(attrs[DiscoveryAttr.modelName]);
    if (match != null) return match;
    if (powerRead == sharpErr && model == null) {
      return (
        profile: SharpProfile.us2015Limited,
        volumeCertain: false,
        volumeMax: 60,
      );
    }
    return (profile: SharpProfile.us2011, volumeCertain: false, volumeMax: 60);
  }

  static final RegExp _uuid = RegExp(
    r'uuid:([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})',
    caseSensitive: false,
  );

  static DeviceInfo _info(
    Endpoint endpoint, {
    required SharpProfile profile,
    String? name,
    String? model,
    String? software,
    String? version,
  }) {
    final attrs = endpoint.attributes;
    String? udn;
    for (final key in [DiscoveryAttr.udn, DiscoveryAttr.usn]) {
      final match = _uuid.firstMatch(attrs[key] ?? '');
      if (match != null) {
        udn = 'uuid:${match.group(1)!.toLowerCase()}';
        break;
      }
    }
    final macHint = sharpMacHintFromUdn(udn);
    return DeviceInfo(
      name: name ?? attrs[DiscoveryAttr.friendlyName],
      manufacturer: 'Sharp',
      model: attrs[DiscoveryAttr.modelName] ?? model,
      stableId: udn,
      osVersion: software,
      extra: {
        'profile': profile.id,
        'mnrd': ?model,
        'protocolVersion': ?version,
        // A Wake-on-LAN hint only: hardware has not confirmed it.
        'udnMacHint': ?macHint,
      },
    );
  }

  // ---------------------------------------------------------------- pairing

  /// Pairing never shows anything on the TV, so cancelling it undoes
  /// nothing; it closes the connection in use. The login ID and password
  /// never appear in a step or an error.
  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) {
    SharpLink? current;
    void track(SharpLink? link) => current = link;
    return PairingFlowController.run((flow) async {
      final secrets = <String>[];
      try {
        return await _pair(flow, endpoint, transports, context, secrets, track);
      } on SharpLinkDown {
        // The TV closed a connection before anything of an exchange went
        // out on it (twice where pairing reconnects): nothing was sent.
        throw WatchmeError.unreachable(
          'The TV at ${endpoint.host}:'
          '${endpoint.port(SharpPorts.ipc, SharpPorts.ipcDefault)} closed the '
          'connection before watchme could send anything (another client may '
          'be connected); nothing was changed',
        );
      } on WatchmeError catch (e) {
        throw redactSharpError(e, secrets);
      } finally {
        await current?.close();
      }
    }, onCancel: () => current?.close());
  }

  Future<SharedSecretCredential> _pair(
    PairingFlowController flow,
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
    List<String> secrets,
    void Function(SharpLink? link) track,
  ) async {
    final network = transports.requireNetwork();
    final port = endpoint.port(SharpPorts.ipc, SharpPorts.ipcDefault);
    void checkCancelled() {
      if (flow.isCancelled) {
        throw const WatchmeError.cancelled('Pairing cancelled');
      }
    }

    Future<SharpLink> connect() async {
      checkCancelled();
      final link = await SharpLink.open(
        network,
        endpoint.host,
        port,
        clock: _clock,
        timings: timings,
      );
      track(link);
      return link;
    }

    // 1. Reach the port; if it is closed, say what to switch on, once.
    SharpLink link;
    try {
      link = await connect();
    } on WatchmeError catch (e) {
      if (e.code != WatchmeErrorCode.unreachable) rethrow;
      await flow.prompt(
        Instruct(
          'watchme cannot reach IP control on port $port. Make sure the TV '
          'is on, then turn on AQUOS Remote Control / IP Control in its '
          'network settings (see the setup steps), and continue.',
          requiresAck: true,
        ),
      );
      link = await connect();
    }

    // 2. A login, only if the TV asks for one.
    bool prompted;
    try {
      prompted = await link.awaitPrompt(timings.promptWait);
    } on SharpLinkDown {
      await link.close();
      await _clock.delay(timings.reconnectGap);
      link = await connect();
      prompted = await link.awaitPrompt(timings.promptWait);
    }
    SharedSecretCredential credential;
    if (!prompted) {
      // A TV with login disabled answers commands at once; one read proves
      // this is one.
      final power = await link.request(
        sharpQuery('POWR'),
        timeout: timings.reply,
        skipOk: true,
      );
      if (!const {'0', '1', sharpErr}.contains(power)) {
        throw WatchmeError.protocol(
          'Not a Sharp IP-control port: unexpected answer to POWR?',
          rawDeviceMessage: power,
        );
      }
      credential = _noLogin(context);
    } else {
      await link.close();
      (link, credential) = await _login(
        flow,
        context,
        secrets,
        connect,
        checkCancelled,
      );
    }

    // A new connection, logged in, for a write the user allowed after the
    // TV closed the one in use (its idle cut, while the user decided).
    Future<SharpLink> reopen() async {
      checkCancelled();
      await _clock.delay(timings.reconnectGap);
      checkCancelled();
      final fresh = await openSharpLink(
        network: network,
        host: endpoint.host,
        port: port,
        clock: _clock,
        timings: timings,
        credential: credential,
      );
      track(fresh);
      return fresh;
    }

    // 3. Offer power-on over the network where it needs a setting.
    try {
      await _offerNetworkPowerOn(flow, link, endpoint, reopen, checkCancelled);
    } on WatchmeError catch (e) {
      // The login is verified; reading or writing the setting failed.
      if (e.code == WatchmeErrorCode.cancelled) rethrow;
    }
    await link.close();
    checkCancelled();
    return credential;
  }

  /// A credential for a TV that asks for no login (see [isSharpNoLogin]).
  SharedSecretCredential _noLogin(PairingContext context) =>
      SharedSecretCredential(
        driverId: sharpDriverId,
        deviceId: context.deviceId,
        createdAt: _clock.now(),
        secret: '',
      );

  Future<(SharpLink, SharedSecretCredential)> _login(
    PairingFlowController flow,
    PairingContext context,
    List<String> secrets,
    Future<SharpLink> Function() connect,
    void Function() checkCancelled,
  ) async {
    var label = 'Login ID set on the TV';
    for (var attempt = 1; ; attempt++) {
      final login = await _askText(flow, EnterText(label));
      final password = await _askText(
        flow,
        const EnterText('Password set on the TV', secret: true),
      );
      secrets.addAll([login, password]);
      await _clock.delay(timings.reconnectGap);
      final link = await connect();
      final prompted = await link.awaitPrompt(timings.promptWaitWithLogin);
      if (!prompted) {
        // Login was switched off on the TV meanwhile.
        return (link, _noLogin(context));
      }
      checkCancelled();
      try {
        await link.answerLogin(login, password);
        return (
          link,
          SharedSecretCredential(
            driverId: sharpDriverId,
            deviceId: context.deviceId,
            createdAt: _clock.now(),
            username: login,
            secret: password,
          ),
        );
      } on SharpLoginRefused catch (e) {
        await link.close();
        if (attempt >= maxLoginAttempts) {
          throw WatchmeError.unauthorized(
            'Wrong login ID or password ($attempt attempts; login refused)',
            rawDeviceMessage: redactSharpSecrets(e.deviceText, secrets),
          );
        }
        label = 'The login ID or password was wrong. Login ID set on the TV';
      }
    }
  }

  /// Asks [step] until the answer fits it.
  static Future<String> _askText(
    PairingFlowController flow,
    EnterText step,
  ) async {
    var current = step;
    while (true) {
      final value = await flow.prompt(current);
      if (current.accepts(value)) return value;
      current = EnterText(
        'At most ${step.maxLength} characters and no line breaks. '
        '${step.label}',
        secret: step.secret,
        minLength: step.minLength,
        maxLength: step.maxLength,
      );
    }
  }

  /// For a US 2010-2014 set that is on and whose power-on command setting
  /// (RSPW) does not accept IP, asks before setting it: it raises standby
  /// power. Reads only (`POWR?`, `MNRD1`, `RSPW?`) until the user says
  /// yes; writes nothing on any other answer.
  ///
  /// The question waits for the user, and the TV may close the idle
  /// connection meanwhile: `RSPW2` then goes out on a new one from
  /// [reopen], since nothing went out on the closed one.
  Future<void> _offerNetworkPowerOn(
    PairingFlowController flow,
    SharpLink link,
    Endpoint endpoint,
    Future<SharpLink> Function() reopen,
    void Function() checkCancelled,
  ) async {
    Future<String?> read(String frame) async {
      final reply = await link.request(
        frame,
        timeout: timings.reply,
        skipOk: true,
      );
      return reply == sharpErr || reply.isEmpty ? null : reply;
    }

    final power = await read(sharpQuery('POWR'));
    final model = await read(sharpFrame('MNRD', '1'));
    final profile = _profileFor(endpoint, model, powerRead: power).profile;
    if (power != '1') return;
    if (profile.rspw) {
      final rspw = await read(sharpQuery('RSPW'));
      if (rspw == '0' || rspw == '1') {
        final answer = await flow.prompt(
          const ConfirmChange(
            'Let watchme turn this TV on over the network?',
            detail:
                "watchme would set the TV's power-on command setting (RSPW) "
                'to accept IP control, so the TV keeps listening in standby. '
                "Sharp's manual warns that the TV then uses \"just about the "
                'same" power in standby as usual and that the Center Icon '
                'Illumination on the front stays lit. Without it, watchme '
                'can still turn the TV off, but not on. You can change it '
                'back on the TV or by pairing again.',
            yesLabel: 'Allow power-on over the network',
            noLabel: 'Not now',
          ),
        );
        if (answer != ConfirmChange.yes) return;
        checkCancelled();
        final frame = sharpFrame('RSPW', '2');
        // Whether RSPW2 went out (it may have acted), and the TV's answer.
        var sent = false;
        String? reply;
        Future<void> write(SharpLink on) async {
          try {
            reply = await on.request(frame, timeout: timings.reply);
          } on WatchmeError {
            sent = true; // written, then lost or garbled
            rethrow;
          }
          sent = true;
        }

        try {
          try {
            await write(link);
          } on SharpLinkDown {
            link = await reopen();
            await write(link);
          }
        } on SharpLinkDown {
          // Closed again before it went out.
        } on WatchmeError catch (e) {
          if (e.code == WatchmeErrorCode.cancelled) rethrow;
        }
        if (reply != sharpOk) {
          flow.emit(
            Instruct(switch ((sent, reply)) {
              (_, sharpErr) =>
                'The TV refused the power-on command setting (RSPW). '
                    'Without it watchme cannot turn the TV on.',
              (false, _) =>
                'watchme lost the connection to the TV before it could '
                    'change the power-on command setting (RSPW); nothing was '
                    'changed. Pair again to try again.',
              _ =>
                'The TV did not confirm the power-on command setting '
                    '(RSPW); it may or may not have changed.',
            }),
          );
        }
      }
    }
    if (profile.quickStart) {
      flow.emit(
        const Instruct(
          'To let watchme turn this TV on, also set Quick Start Mode to On '
          '(Menu > Setup, or Initial Setup on 4T-B sets). It uses more power '
          'in standby.',
        ),
      );
    }
  }

  // ---------------------------------------------------------------- connect

  /// Opens a [SharpSession]. [allowWake] changes nothing: connecting,
  /// logging in and the reads that follow never wake the TV or change what
  /// it shows, and `POWR1` is sent only by `SetPower(true)`.
  ///
  /// Throws [WatchmeError] as [SharpSession.open] describes; also
  /// [WatchmeErrorCode.unauthorized] for a credential that is not a Sharp
  /// [SharedSecretCredential].
  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential, {
    bool allowWake = true,
  }) async {
    final SharedSecretCredential? login = switch (credential) {
      null => null,
      final SharedSecretCredential c when c.driverId == sharpDriverId => c,
      _ => throw WatchmeError.unauthorized(
        'Not a Sharp IP-control credential: ${credential.type} for '
        '${credential.driverId}',
      ),
    };
    return SharpSession.open(
      endpoint: endpoint,
      network: transports.requireNetwork(),
      clock: _clock,
      timings: timings,
      credential: login,
      pollInterval: pollInterval,
    );
  }
}
