import 'package:watchme_core/watchme_core.dart';

import 'capabilities.dart';
import 'ecp_client.dart';
import 'ecp_xml.dart';
import 'roku_session.dart';

/// The Roku ECP driver's static facts.
final DriverDescriptor rokuDescriptor = DriverDescriptor(
  id: rokuDriverId,
  vendor: 'Roku',
  protocol: 'Roku External Control Protocol (ECP)',
  ceiling: rokuCeiling,
  backends: const [
    DriverBackend(
      id: 'roku.ecp.http',
      requires: {TransportFeature.httpReadCrossOrigin},
      targets: {DriverTarget.native, DriverTarget.webSafe},
    ),
  ],
  stability: Stability.documented,
  provenance:
      "Clean-room implementation from Roku's ECP documentation "
      '(developer.roku.com, updated 2026-10-15). Response shapes were '
      'cross-checked against python-rokuecp (MIT) and brs-desktop (MIT); '
      'Limited-mode and Host-header handling follow field reports (openHAB '
      'PR #17925, Home Assistant #131969). No code was copied.',
  matchers: const [
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      serviceType: 'roku:ecp',
      portName: rokuEcpPortName,
    ),
    DiscoveryMatcher(
      provider: DiscoveryProviderId.ssdp,
      attributes: [AttributeMatch.prefix(DiscoveryAttr.usn, 'uuid:roku:ecp')],
      portName: rokuEcpPortName,
    ),
  ],
  userSetup: [
    SetupStep(
      id: 'roku.controlByMobileApps',
      title: 'Control by mobile apps = Enabled',
      detail:
          'On Roku OS 14.1 and later, open Settings > System > Advanced '
          'system settings > Control by mobile apps (on some firmware under '
          'Network access) and choose Enabled. The usual default, Limited, '
          'refuses key presses, text, the app list and playback state. '
          'Choose Permissive only if watchme runs on a different subnet '
          'from the Roku.',
      helpUrl: Uri.parse('https://support.roku.com/article/217288467'),
    ),
    SetupStep(
      id: 'roku.fastTvStart',
      title: 'Optional: Fast TV Start = On (Roku TVs)',
      detail:
          'Settings > System > Power > Fast TV Start keeps the network up '
          'in standby, so watchme can turn the TV on with the PowerOn key. '
          'Without it the network sleeps about 10 minutes after power-off '
          'and only Wake-on-LAN can wake the TV (it uses more standby power).',
    ),
  ],
  ports: const {rokuEcpPortName: rokuEcpDefaultPort},
);

/// The Roku External Control Protocol driver (`roku.ecp`).
///
/// Plain HTTP on port 8060 ([rokuEcpPortName]), no pairing. Since Roku OS
/// 14.1 most commands need "Control by mobile apps" = Enabled on the TV;
/// [probe] detects the Limited level and reports it as a setup note and
/// [CapFlag.userSetupRequired] capabilities instead of failing.
///
/// ```dart
/// final driver = RokuDriver();
/// final probe = await driver.probe(Endpoint('192.0.2.10'), transports);
/// final session = await driver.connect(Endpoint('192.0.2.10'), transports, null);
/// await session.execute(const PressKey(RemoteKey.home));
/// ```
final class RokuDriver implements Driver {
  /// Creates the driver.
  ///
  /// [pollInterval] is how often sessions poll state while their events are
  /// listened to (`null` disables polling). [replaceBackspaces] is how many
  /// Backspace presses `TypeText(replace: true)` sends first.
  /// [castReceiverAppId] is the channel `CastUrl` launches (`null` makes
  /// `CastUrl` unsupported).
  const RokuDriver({
    this.clock = const SystemClock(),
    this.pollInterval = rokuDefaultPollInterval,
    this.requestTimeout = const Duration(seconds: 5),
    this.replaceBackspaces = rokuDefaultReplaceBackspaces,
    this.castReceiverAppId = mediaAssistantAppId,
  });

  /// The driver id, `roku.ecp`.
  static const String id = rokuDriverId;

  /// Time source for observations and polling.
  final Clock clock;

  /// Session polling period while events are listened to; `null` disables.
  final Duration? pollInterval;

  /// Deadline for each ECP request.
  final Duration requestTimeout;

  /// Backspace presses sent before `TypeText(replace: true)`.
  final int replaceBackspaces;

  /// The receiver channel `CastUrl` launches.
  final String? castReceiverAppId;

  @override
  DriverDescriptor get descriptor => rokuDescriptor;

  /// Reads `query/device-info` and, when the device is awake, tries
  /// `query/media-player` (a read that Limited mode refuses) to learn the
  /// "Control by mobile apps" level. Never changes anything on the device.
  @override
  Future<ProbeResult> probe(Endpoint endpoint, Transports transports) async {
    final EcpClient client;
    try {
      client = EcpClient(endpoint, transports, timeout: requestTimeout);
    } on WatchmeError catch (e) {
      return ProbeResult.notMatched(error: e);
    }
    final notes = [
      if (!client.hostIsIpLiteral)
        'Addressed by the name "${endpoint.host}": recent Roku firmware '
            'refuses requests whose Host is not an IP address, so add the '
            'device by its IP address.',
    ];
    final HttpResult r;
    try {
      r = await client.get('/query/device-info');
    } on WatchmeError catch (e) {
      return ProbeResult.notMatched(error: e, notes: notes);
    }
    if (!r.ok) {
      // A Roku that refuses even device-info still says so in ECP's words.
      if (rokuRefusal(r) == null) {
        return ProbeResult.notMatched(
          error: client.errorFor(r, 'query/device-info'),
          notes: notes,
        );
      }
      return ProbeResult.matched(
        info: _infoFromDiscovery(endpoint),
        capabilities: rokuCapabilities(null, RokuEcpAccess.disabled),
        notes: [
          ...notes,
          'The Roku refuses ECP requests ("${r.text.trim()}"). '
              '$rokuEnableHint',
        ],
      );
    }
    final RokuDeviceInfo info;
    try {
      info = RokuDeviceInfo.parse(r.text);
    } on FormatException catch (e) {
      return ProbeResult.notMatched(
        error: WatchmeError.protocol(
          'Not a Roku: query/device-info did not return Roku device-info',
          rawDeviceMessage: r.text,
          cause: e,
        ),
        notes: notes,
      );
    }
    final access = await _detectAccess(endpoint, transports, info);
    final awake =
        info.powerMode == PowerMode.on || info.powerMode == PowerMode.screenOff;
    return ProbeResult.matched(
      info: info.toDeviceInfo(),
      capabilities: rokuCapabilities(info, access),
      // device-info answers in standby too, so it is the power state, not
      // the fact that it answered.
      power: info.powerMode == PowerMode.unknown
          ? null
          : Observed.reported(info.powerMode, rokuDriverId, clock.now()),
      notes: [
        ...notes,
        switch (access) {
          RokuEcpAccess.limited =>
            'Control by mobile apps is set to Limited: key presses, text, '
                'the app list and playback state are refused. $rokuEnableHint',
          RokuEcpAccess.disabled =>
            'The Roku refuses ECP commands. $rokuEnableHint',
          RokuEcpAccess.unknown when !awake =>
            'The Roku is in standby (power-mode '
                '${info.powerModeRaw ?? 'unknown'}), so whether Control by '
                'mobile apps is Enabled could not be checked.',
          RokuEcpAccess.unknown =>
            'Could not tell whether Control by mobile apps is Enabled.',
          RokuEcpAccess.enabled => null,
        },
      ].nonNulls.toList(),
    );
  }

  /// The longest the probe's optional access check may take, so that it
  /// and device-info together stay inside the engine's probe timeout.
  static const Duration accessCheckTimeout = Duration(seconds: 2);

  Future<RokuEcpAccess> _detectAccess(
    Endpoint endpoint,
    Transports transports,
    RokuDeviceInfo info,
  ) async {
    if (info.ecpAccess != RokuEcpAccess.unknown) return info.ecpAccess;
    // Standby refuses everything but device-info, which would read as a
    // false "Limited".
    if (info.powerMode != PowerMode.on &&
        info.powerMode != PowerMode.screenOff) {
      return RokuEcpAccess.unknown;
    }
    final client = EcpClient(
      endpoint,
      transports,
      timeout: requestTimeout < accessCheckTimeout
          ? requestTimeout
          : accessCheckTimeout,
    );
    try {
      final r = await client.get('/query/media-player');
      return r.ok
          ? RokuEcpAccess.enabled
          : rokuRefusal(r) ?? RokuEcpAccess.unknown;
    } on WatchmeError {
      return RokuEcpAccess.unknown;
    }
  }

  DeviceInfo _infoFromDiscovery(Endpoint endpoint) {
    final a = endpoint.attributes;
    final serial =
        a[DiscoveryAttr.serialNumber] ??
        rokuSerialFromUsn(a[DiscoveryAttr.usn]);
    return DeviceInfo(
      name: a[DiscoveryAttr.friendlyName],
      manufacturer: a[DiscoveryAttr.manufacturer] ?? 'Roku',
      model: a[DiscoveryAttr.modelName],
      stableId: serial == null ? null : rokuStableId(serial),
    );
  }

  /// Roku ECP needs no pairing.
  @override
  PairingFlow? startPairing(
    Endpoint endpoint,
    Transports transports,
    PairingContext context,
  ) => null;

  /// Opens a [RokuSession]. [credential] is ignored: ECP has none.
  ///
  /// Throws [WatchmeError] as described in [RokuSession.connect].
  @override
  Future<DriverSession> connect(
    Endpoint endpoint,
    Transports transports,
    Credential? credential,
  ) => RokuSession.connect(
    endpoint,
    transports,
    clock: clock,
    pollInterval: pollInterval,
    requestTimeout: requestTimeout,
    replaceBackspaces: replaceBackspaces,
    castReceiverAppId: castReceiverAppId,
  );
}
