import 'dart:async';
import 'dart:math' as math;

import 'package:watchme_core/watchme_core.dart';

import 'backoff.dart';
import 'capability_router.dart';
import 'engine_pairing.dart';
import 'identity.dart';
import 'power_orchestrator.dart';
import 'util.dart';

part 'device_entry.dart';

/// Tunables for [Engine].
final class EngineConfig {
  /// Creates an engine configuration.
  const EngineConfig({
    this.clientName = 'watchme',
    this.probeTimeout = const Duration(seconds: 8),
    this.connectTimeout = const Duration(seconds: 15),
    this.refreshTimeout = const Duration(seconds: 10),
    this.discoveryGrace = const Duration(seconds: 3),
    this.reconnect = const Backoff(),
    this.power = const PowerConfig(),
  });

  /// How watchme names itself to TVs when pairing.
  final String clientName;

  /// Longest wait for one driver's probe.
  final Duration probeTimeout;

  /// Longest wait for one driver's connect.
  final Duration connectTimeout;

  /// Longest wait for one session's refresh.
  final Duration refreshTimeout;

  /// How long past the scan window a discovery provider may run before the
  /// engine stops listening to it.
  final Duration discoveryGrace;

  /// Background reconnect policy for dropped sessions.
  final Backoff reconnect;

  /// Power orchestrator tunables.
  final PowerConfig power;
}

/// The watchme engine: device registry and identity merge, discovery and
/// pairing orchestration, capability routing and power orchestration.
///
/// Pure Dart: it reaches devices only through [Driver]s and [Transports],
/// and keeps time with a [Clock].
///
/// * **Identity.** Discovery hits and probe results are merged into one
///   device keyed by MAC, then stable id, then host (see
///   [resolveIdentity]), so a device keeps its id across IP changes.
/// * **Sessions.** A driver connects lazily on the first command that needs
///   it, and only a command the user sent may wake the device while
///   connecting (`Driver.connect(allowWake: true)`); turning a device off,
///   sending a power toggle or ending a hold (a key-up, which apps also
///   send on their own) never does. A session that reports
///   `disconnected`, or whose refresh reaches nothing, is closed, its
///   observations show as stale, and it is reconnected in the background
///   with [EngineConfig.reconnect] backoff, passively: background
///   reconnects never wake the device (`allowWake: false`), and none is
///   tried after watchme turned the device off or while it is known to be
///   off. A revoked credential ([ReauthRequired]) marks the pairing
///   invalid: the driver shows as needing pairing and is not used until
///   paired again. That includes a revocation that is only the cause of a
///   partial delivery (a connect whose wake went out before the token was
///   refused).
/// * **Routing.** [send] ranks the device's sessions with a
///   [CapabilityRouter] and falls back down the list while nothing reached
///   the device. After a failure that may have acted (a timeout, a partial
///   delivery) it neither falls back nor retries, and marks the state the
///   command changes (e.g. volume) stale until a source reports an
///   observation made after the failure; a refresh that returns what a
///   session cached before the command does not revive it. A connect that
///   fails [WatchmeErrorCode.partiallyDelivered] (a wake it sent may have
///   reached the device) counts as such a failure, not as "nothing sent":
///   the woken device must not get a toggle that switches it back off.
/// * **Power.** `SetPower` and the power keys go through the
///   [PowerOrchestrator] instead: `PressKey(RemoteKey.power)` is a toggle
///   intent, never a raw key press, and holding a power key is refused.
/// * **LAN only.** [addManual] refuses an IP literal outside
///   [destinationPolicy] up front, and discovery hits from such addresses
///   are dropped. Host names are checked by the network stack, which
///   resolves them and checks every address (see `DestinationPolicy`).
/// * **Secrets.** Credentials go from pairing straight to the
///   [CredentialStore]. Nothing the engine returns contains one: views carry
///   no secrets and pairing flows end in [Paired.redacted].
final class Engine implements WatchmeEngine {
  /// Creates an engine.
  ///
  /// A driver is enabled when it has no backends or one whose required
  /// transport features [transports] offers; likewise discovery providers.
  /// Without [credentials] or [repository], in-memory stores are used.
  /// [wakeOnLan] sends one round of Wake-on-LAN for the power orchestrator,
  /// which repeats it (see [WakeOnLanSender]); hosts pass
  /// `WakeOnLan(network, repeats: 1).send` from watchme_io, which also
  /// covers subnet broadcasts. Without it the orchestrator sends the
  /// packets itself.
  ///
  /// [destinationPolicy] is LAN-only by default. Give the native network
  /// stack the same policy: it is what enforces it on every connection.
  Engine({
    required Iterable<Driver> drivers,
    required Transports transports,
    Iterable<DiscoveryProvider> discoveryProviders = const [],
    CredentialStore? credentials,
    DeviceRepository? repository,
    Clock clock = const SystemClock(),
    this.config = const EngineConfig(),
    this.destinationPolicy = DestinationPolicy.lanOnly,
    WakeOnLanSender? wakeOnLan,
  }) : _drivers = List.unmodifiable(drivers),
       _transports = transports,
       _providers = List.unmodifiable(discoveryProviders),
       _credentials = credentials ?? MemoryCredentialStore(),
       _repository = repository ?? MemoryDeviceRepository(),
       _clock = clock {
    final ids = <String>{};
    for (final d in _drivers) {
      if (!ids.add(d.descriptor.id)) {
        throw ArgumentError.value(d.descriptor.id, 'drivers', 'duplicate id');
      }
    }
    power = PowerOrchestrator(
      transports: transports,
      clock: clock,
      config: config.power,
      router: _router,
      wakeOnLan: wakeOnLan,
    );
  }

  static const CapabilityRouter _router = CapabilityRouter();

  final List<Driver> _drivers;
  final Transports _transports;
  final List<DiscoveryProvider> _providers;
  final CredentialStore _credentials;
  final DeviceRepository _repository;
  final Clock _clock;

  /// Tunables.
  final EngineConfig config;

  /// Which addresses the engine accepts for manual adds and discovery hits.
  ///
  /// The in-process app allows loopback for its simulators; a hub must not
  /// (see `DestinationPolicy.allowLoopback`).
  final DestinationPolicy destinationPolicy;

  /// The power orchestrator `SetPower` and the power keys go through.
  late final PowerOrchestrator power;

  final Map<String, _DeviceEntry> _devices = {};
  final Map<(String, String), EnginePairing> _pairings = {};

  /// Slots a pairing has reserved (see [pair]): nothing else connects them
  /// until the pairing succeeds or ends.
  final Set<_DriverSlot> _reserved = Set.identity();

  /// Per slot, what may still hold a connection to the device after the
  /// engine let go of it: closes of sessions it dropped, and connects whose
  /// session nobody will use. A pairing waits for them.
  final Expando<Set<Future<void>>> _letGo = Expando('letGo');
  final StreamController<List<DeviceView>> _deviceLists =
      StreamController.broadcast();
  Future<void>? _started;
  Future<void>? _discovery;
  bool _closed = false;
  bool _emitScheduled = false;

  /// Descriptors of the drivers enabled on these transports.
  List<DriverDescriptor> get drivers => [
    for (final d in _drivers)
      if (_runnable(d)) d.descriptor,
  ];

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  // ------------------------------------------------------------ lifecycle

  @override
  Future<void> start() => _started ??= _load();

  Future<void> _load() async {
    final records = await _repository.all();
    for (final record in records) {
      if (_devices.containsKey(record.id)) continue;
      final entry = _DeviceEntry(record, DeviceIdentity.ofRecord(record));
      for (final id in record.driverIds) {
        final driver = _driverById(id);
        if (driver != null && _runnable(driver)) {
          entry.slots.add(_DriverSlot(driver));
        }
      }
      _sortSlots(entry);
      await _loadCredentialFlags(entry);
      _devices[record.id] = entry;
    }
    _emitDevices();
  }

  Future<void> _ready() async {
    final started = _started;
    if (started != null) await started;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final turn in _volumeWaiters) {
      turn.complete();
    }
    _volumeWaiters.clear();
    power.close();
    for (final pairing in [..._pairings.values]) {
      await pairing.cancel();
    }
    for (final entry in _devices.values) {
      for (final slot in entry.slots) {
        slot.generation++;
        slot.cancelReconnect();
        await _closeSession(slot);
      }
      unawaited(entry.events.close());
    }
    // A record write started before close may still be on its way to the
    // store; the caller may delete the store's directory once this returns.
    await Future.wait([..._pendingWrites]);
    unawaited(_deviceLists.close());
  }

  void _checkOpen() {
    if (_closed) throw const WatchmeError.cancelled('The engine is closed');
  }

  // ---------------------------------------------------------- device list

  @override
  Stream<List<DeviceView>> get devices => Stream.multi((controller) {
    controller.add(currentDevices);
    if (_closed) {
      controller.close();
      return;
    }
    final subscription = _deviceLists.stream.listen(
      controller.add,
      onDone: controller.close,
    );
    controller.onCancel = subscription.cancel;
  });

  @override
  List<DeviceView> get currentDevices {
    final entries = _devices.values.toList()
      ..sort((a, b) {
        final byName = a.record.name.toLowerCase().compareTo(
          b.record.name.toLowerCase(),
        );
        return byName != 0 ? byName : a.id.compareTo(b.id);
      });
    return [for (final e in entries) _viewOf(e)];
  }

  /// Emits the device list once per microtask, however many changes.
  void _emitDevices() {
    if (_emitScheduled || _closed) return;
    _emitScheduled = true;
    scheduleMicrotask(() {
      _emitScheduled = false;
      if (!_closed) _deviceLists.add(currentDevices);
    });
  }

  DeviceView _viewOf(_DeviceEntry e) => DeviceView(
    id: e.id,
    name: e.record.name,
    host: e.record.host,
    manufacturer: e.record.manufacturer,
    model: e.record.model,
    drivers: [
      for (final s in e.slots)
        DriverView(
          driverId: s.driverId,
          protocol: s.descriptor.protocol,
          requiresPairing: s.requiresPairing || s.reauthInvalid,
          offersPairing: s.descriptor.offersPairing,
          paired: s.paired,
          connection: s.connection,
          lastError: s.lastError,
          setup: s.descriptor.userSetup,
          notes: s.notes,
        ),
    ],
    capabilities: _mergedCapabilities(e).values.toList(),
    state: e.state.copyWith(
      connections: {for (final s in e.slots) s.driverId: s.connection},
    ),
    lastSeen: e.record.lastSeen,
  );

  @override
  Map<Capability, CapabilitySupport> capabilitiesOf(String deviceId) =>
      _mergedCapabilities(_require(deviceId));

  Map<Capability, CapabilitySupport> _mergedCapabilities(_DeviceEntry e) {
    final best = <Capability, (CapabilitySupport, Stability)>{};
    void offer(CapabilitySupport c, Stability stability) {
      final current = best[c.capability];
      if (current == null ||
          CapabilityRouter.compareSupport(
                c,
                current.$1,
                aStability: stability,
                bStability: current.$2,
              ) <
              0) {
        best[c.capability] = (c, stability);
      }
    }

    for (final slot in e.slots) {
      for (final c in slot.capabilities) {
        offer(c, slot.descriptor.stability);
      }
    }
    final wake = _wakeOnLanSupport(e);
    if (wake != null && !(best[Capability.powerOn]?.$1.usable ?? false)) {
      best[Capability.powerOn] = (wake, Stability.documented);
    }
    return {
      for (final c in Capability.values)
        if (best[c] case final b?) c: b.$1,
    };
  }

  /// The power-on the orchestrator can always attempt for a device with a
  /// cached MAC.
  CapabilitySupport? _wakeOnLanSupport(_DeviceEntry e) {
    if (e.identity.macs.isEmpty || _transports.network == null) return null;
    final f = _transports.features;
    if (!f.contains(TransportFeature.udpBroadcast) &&
        !f.contains(TransportFeature.udpUnicast)) {
      return null;
    }
    return const CapabilitySupport.partial(
      Capability.powerOn,
      flags: {CapFlag.writeOnly},
      note:
          'Wake-on-LAN to the remembered MAC address; works only if the TV '
          'allows network wake-up',
    );
  }

  @override
  Stream<DeviceEvent> events(String deviceId) =>
      _require(deviceId).events.stream;

  _DeviceEntry _require(String deviceId) =>
      _devices[deviceId] ??
      (throw WatchmeError.internal('Unknown device: $deviceId'));

  // ------------------------------------------------------------ discovery

  @override
  Future<void> discover(Duration window) {
    if (_closed) {
      return Future.error(const WatchmeError.cancelled('The engine is closed'));
    }
    return _discovery ??= _discover(window)
        .whenComplete(() => _discovery = null);
  }

  Future<void> _discover(Duration window) async {
    await _ready();
    final drivers = _enabledDrivers;
    final hits = <DiscoveryHit>[];
    await Future.wait([
      for (final provider in _providers)
        if (_transports.supportsAll(provider.requires))
          if (_serviceTypesFor(provider, drivers) case final types?)
            _collect(provider, window, types, hits),
    ]);
    if (_closed) return;
    final byHost = <String, List<DiscoveryHit>>{};
    for (final hit in hits) {
      (byHost[hit.host] ??= []).add(hit);
    }
    final sightings = await Future.wait([
      for (final MapEntry(:key, :value) in byHost.entries)
        _sight(key, value, drivers),
    ]);
    // One at a time, so two sightings of one device merge instead of racing.
    for (final sighting in sightings.nonNulls) {
      if (_closed) return;
      await _upsert(sighting);
    }
  }

  /// The service types to ask [provider] for, or `null` when no enabled
  /// driver could match its hits. Empty means "the provider's default".
  Set<String>? _serviceTypesFor(
    DiscoveryProvider provider,
    List<Driver> drivers,
  ) {
    var applicable = false;
    var wildcard = false;
    final types = <String>{};
    for (final d in drivers) {
      for (final m in d.descriptor.matchers) {
        if (m.provider != null && m.provider != provider.id) continue;
        final type = m.serviceType;
        if (type == null) {
          applicable = wildcard = true;
        } else if (m.provider != null || _typeFits(provider.id, type)) {
          applicable = true;
          types.add(type);
        }
      }
    }
    if (!applicable) return null;
    return wildcard ? const {} : types;
  }

  /// Whether a provider-less matcher's [type] makes sense for the provider:
  /// DNS-SD types (`_name._tcp`) go to mDNS and Bonjour, everything else to
  /// SSDP. Unknown providers get every type.
  static bool _typeFits(String providerId, String type) {
    final t = normalizeServiceType(type);
    final dnsSd =
        t.startsWith('_') && (t.endsWith('._tcp') || t.endsWith('._udp'));
    return switch (providerId) {
      DiscoveryProviderId.ssdp => !dnsSd,
      DiscoveryProviderId.mdns || DiscoveryProviderId.bonjour => dnsSd,
      _ => true,
    };
  }

  Future<void> _collect(
    DiscoveryProvider provider,
    Duration window,
    Set<String> serviceTypes,
    List<DiscoveryHit> into,
  ) {
    final done = Completer<void>();
    StreamSubscription<DiscoveryHit>? subscription;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    final guard = _clock.timer(window + config.discoveryGrace, () {
      unawaited(subscription?.cancel());
      finish();
    });
    try {
      subscription = provider
          .scan(window, serviceTypes: serviceTypes)
          .listen(
            (hit) {
              // Providers drop off-LAN senders themselves; this keeps a
              // provider that does not from steering a probe, or moving a
              // known device, to an address the policy refuses.
              if (!_refused(hit.host)) into.add(hit);
            },
            onError: (Object _) {
              // One provider's failure must not stop the others; the hits
              // it already yielded still count.
            },
            onDone: () {
              guard.cancel();
              finish();
            },
          );
    } on Object {
      guard.cancel();
      finish();
    }
    return done.future;
  }

  Future<_Sighting?> _sight(
    String host,
    List<DiscoveryHit> hits,
    List<Driver> drivers,
  ) async {
    final targets = <(Driver, Endpoint)>[];
    for (final driver in drivers) {
      var matched = false;
      final ports = <String, int>{};
      final attributes = <String, String>{};
      for (final hit in hits) {
        for (final matcher in driver.descriptor.matchers) {
          if (!matcher.matches(hit)) continue;
          matched = true;
          final (name, port) = (matcher.portName, hit.port);
          if (name != null && port != null) ports[name] = port;
          attributes.addAll(hit.attributes);
        }
      }
      if (matched) {
        targets.add((
          driver,
          Endpoint(host, ports: ports, attributes: attributes),
        ));
      }
    }
    if (targets.isEmpty) return null;
    final probes = await Future.wait([
      for (final (driver, endpoint) in targets) _probeOne(driver, endpoint),
    ]);
    if (!probes.any((p) => p.result.matched || p.result.error != null)) {
      return null;
    }
    return _Sighting(
      host: host,
      probes: probes,
      hits: hits,
      ports: {
        for (final p in probes) ...p.endpoint.ports,
        for (final p in probes) ...?p.result.endpoint?.ports,
      },
      attachFailedProbes: true,
    );
  }

  // ----------------------------------------------------------- manual add

  @override
  Future<DeviceView> addManual(
    String host, {
    Map<String, int> ports = const {},
  }) async {
    _checkOpen();
    await _ready();
    final address = host.trim();
    if (address.isEmpty) {
      throw const WatchmeError.unsupported('No host was given');
    }
    _checkManualHost(address);
    final drivers = _enabledDrivers;
    if (drivers.isEmpty) {
      throw const WatchmeError.unsupported(
        'No driver can run on these transports',
      );
    }
    final endpoint = Endpoint(address, ports: ports);
    final probes = await Future.wait([
      for (final d in drivers) _probeOne(d, endpoint),
    ]);
    final matched = [
      for (final p in probes)
        if (p.result.matched) p,
    ];
    if (matched.isEmpty) throw _noMatch(address, probes);
    _checkOpen();
    final entry = await _upsert(
      _Sighting(
        host: address,
        probes: matched,
        ports: {
          ...ports,
          for (final p in matched) ...?p.result.endpoint?.ports,
        },
      ),
    );
    return _viewOf(entry);
  }

  /// Every label decimal or `0x` hex: a numeric shorthand (`127.1`,
  /// `0x7f.0.0.1`, `2130706433`, `010.0.0.1`) that resolvers read as an
  /// address, though it is no IP literal [classifyHostAddress] accepts.
  static final RegExp _numericHost = RegExp(
    r'^(?:0x[0-9a-f]*|[0-9]+)(?:\.(?:0x[0-9a-f]*|[0-9]+))*\.?$',
    caseSensitive: false,
  );

  /// A DNS host name: letters, digits and inner hyphens per label.
  static final RegExp _hostName = RegExp(
    r'^(?=.{1,253}$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    r'(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.?$',
    caseSensitive: false,
  );

  /// Refuses a manually entered [host] before any driver runs, with a clear
  /// error: an IP literal outside [destinationPolicy], a numeric shorthand
  /// (resolvers turn it into an address this check never saw), or text that
  /// is neither an IP literal nor a host name. A host name is left to the
  /// network stack, which resolves it, checks every address it resolves to
  /// and connects to the checked one.
  void _checkManualHost(String host) {
    if (classifyHostAddress(host) != HostAddressClass.invalid) {
      destinationPolicy.check(host);
      return;
    }
    if (_numericHost.hasMatch(host)) {
      throw WatchmeError.destinationRefused(
        'Refused to contact $host: it is not a complete IP address. Write '
        'an IPv4 address as four decimal numbers, e.g. 192.168.1.20.',
      );
    }
    if (!_hostName.hasMatch(host)) {
      throw WatchmeError.unsupported(
        '"$host" is not an IP address or host name',
      );
    }
  }

  /// Whether [host] is an IP literal [destinationPolicy] refuses. Host
  /// names are not: the network stack checks what they resolve to.
  bool _refused(String host) =>
      classifyHostAddress(host) != HostAddressClass.invalid &&
      !destinationPolicy.allows(host);

  WatchmeError _noMatch(String host, List<_Probe> probes) {
    final errors = [for (final p in probes) ?p.result.error];
    // The network stack refused what a host name resolved to (off the LAN,
    // say): no driver could have reached it, and that is the explanation.
    for (final e in errors) {
      if (e.code == WatchmeErrorCode.destinationRefused) return e;
    }
    if (errors.isNotEmpty &&
        errors.every(
          (e) =>
              e.code == WatchmeErrorCode.unreachable ||
              e.code == WatchmeErrorCode.timeout,
        )) {
      final allTimeouts = errors.every(
        (e) => e.code == WatchmeErrorCode.timeout,
      );
      return WatchmeError(
        allTimeouts ? WatchmeErrorCode.timeout : WatchmeErrorCode.unreachable,
        'Nothing answered at $host',
        cause: errors.first,
      );
    }
    final notes = [for (final p in probes) ...p.result.notes];
    // A driver that reached the device and was refused (a Panasonic VIERA
    // answers 403 to clients on another subnet) has the explanation the
    // user can act on; the other drivers' "nothing there" does not.
    final specific = errors.where((e) => !_isTransportError(e)).firstOrNull;
    return WatchmeError.unsupported(
      'No driver recognised $host'
      '${specific == null ? '' : ': ${specific.message}'}'
      '${notes.isEmpty ? '' : ' (${notes.join('; ')})'}',
      rawDeviceMessage:
          specific?.rawDeviceMessage ??
          errors.map((e) => e.rawDeviceMessage).nonNulls.firstOrNull,
      cause: specific ?? errors.firstOrNull,
    );
  }

  // ------------------------------------------------------ identity merge

  Future<_DeviceEntry> _upsert(_Sighting sighting) async {
    final candidate = sighting.identity;
    final match = resolveIdentity(candidate, {
      for (final e in _devices.values) e.id: e.identity,
    });
    final _DeviceEntry entry;
    if (match == null) {
      final id = deviceIdFor(candidate, _devices.keys.toSet());
      entry = _DeviceEntry(
        DeviceRecord(id: id, name: sighting.displayName, host: sighting.host),
        candidate,
      );
      _devices[id] = entry;
    } else {
      entry = _devices[match.id]!;
      final moved = entry.record.host != sighting.host;
      entry.identity = entry.identity.mergedWith(candidate);
      if (moved) {
        // Sessions are bound to the old address; reconnect at the new one
        // when next needed.
        for (final slot in entry.slots) {
          _resetSession(entry, slot);
        }
      }
    }

    var addedSlots = false;
    for (final probe in sighting.probes) {
      final result = probe.result;
      final attach =
          result.matched ||
          (result.error != null && sighting.attachFailedProbes);
      if (!attach) continue;
      var slot = entry.slot(probe.driver.descriptor.id);
      if (slot == null) {
        slot = _DriverSlot(probe.driver);
        entry.slots.add(slot);
        addedSlots = true;
      }
      slot.attributes = {
        ...slot.attributes,
        ...probe.endpoint.attributes,
        ...?result.endpoint?.attributes,
      };
      if (result.matched) {
        if (slot.session == null) {
          slot.capabilities = List.of(result.capabilities);
        }
        slot.requiresPairing = result.requiresPairing;
        slot.notes = List.of(result.notes);
        if (_isTransportError(slot.lastError)) slot.lastError = null;
        if (result.power case final power?) {
          _applyState(entry, DeviceState(power: power), slot.driverId);
        }
      } else if (slot.session == null) {
        slot.lastError = result.error;
      }
    }
    for (final p in sighting.probes) {
      if (p.result.matched) entry.unreachable.remove(p.driver.descriptor.id);
    }
    _sortSlots(entry);

    final old = entry.record;
    final macs = entry.identity.macs;
    final primaryMac = old.mac != null && macs.contains(old.mac)
        ? old.mac
        : sighting.primaryMac ?? (macs.toList()..sort()).firstOrNull;
    entry.record = DeviceRecord(
      id: old.id,
      name: sighting.infoName ?? old.name,
      host: sighting.host,
      manufacturer: sighting.manufacturer ?? old.manufacturer,
      model: sighting.model ?? old.model,
      mac: primaryMac,
      otherMacs: {
        for (final m in macs)
          if (m != primaryMac) m,
      },
      stableId: old.stableId ?? sighting.primaryStableId,
      ports: {...old.ports, ...sighting.ports},
      driverIds: [
        for (final s in entry.slots) s.driverId,
        for (final id in old.driverIds)
          if (entry.slot(id) == null) id,
      ],
      lastSeen: _clock.now(),
    );
    if (addedSlots) await _loadCredentialFlags(entry);
    await _repository.put(entry.record);
    _emitDevices();
    return entry;
  }

  void _sortSlots(_DeviceEntry e) {
    int order(_DriverSlot s) => _drivers.indexOf(s.driver);
    e.slots.sort((a, b) => order(a).compareTo(order(b)));
  }

  Future<void> _loadCredentialFlags(_DeviceEntry e) async {
    try {
      final stored = {
        for (final c in await _credentials.readAll(e.id)) c.driverId,
      };
      for (final slot in e.slots) {
        slot.hasCredential = stored.contains(slot.driverId);
      }
    } on Object {
      // The flags are only for display; connect reads the store again.
    }
  }

  // --------------------------------------------------------------- forget

  @override
  Future<void> forget(String deviceId) async {
    _checkOpen();
    await _ready();
    final entry = _require(deviceId);
    entry.forgotten = true;
    _devices.remove(deviceId);
    for (final MapEntry(:key, :value) in [..._pairings.entries]) {
      if (key.$1 == deviceId) await value.cancel();
    }
    for (final slot in entry.slots) {
      slot.generation++;
      slot.cancelReconnect();
      await _closeSession(slot);
    }
    power.forget(deviceId);
    await _credentials.delete(deviceId);
    await _repository.remove(deviceId);
    unawaited(entry.events.close());
    _emitDevices();
  }

  // -------------------------------------------------------------- refresh

  @override
  Future<void> refresh(String deviceId) async {
    _checkOpen();
    await _ready();
    final entry = _require(deviceId);
    await Future.wait([
      for (final slot in entry.slots) _refreshSlot(entry, slot),
    ]);
    if (entry.forgotten || _closed) return;
    await _persistQuietly(entry);
    _emitDevices();
  }

  /// Refreshes an open session, or probes passively when there is none.
  /// Returns the power observation that produced, if any.
  Future<Observed<PowerMode>?> _refreshSlot(
    _DeviceEntry e,
    _DriverSlot slot,
  ) async {
    final session = slot.session;
    if (session != null) {
      try {
        final state = await withClockTimeout(
          Future.sync(session.refresh),
          config.refreshTimeout,
          _clock,
          () => WatchmeError.timeout('${slot.driverId} refresh timed out'),
        );
        if (!identical(slot.session, session)) return null;
        _applyState(e, _withoutConnections(state), slot.driverId);
        slot.consecutiveFailures = 0;
        _touch(e, slot);
        return state.power;
      } on WatchmeError catch (error) {
        _noteFailure(e, slot, error);
        if (error.code == WatchmeErrorCode.unreachable) {
          // Nothing answered at all: whatever the session last saw (a Fire
          // TV it believes on, say) no longer holds. Drop it as if it had
          // reported the loss itself; recovery is passive.
          _sessionDropped(e, slot, session, error);
        }
      } on Object catch (error) {
        _noteFailure(
          e,
          slot,
          WatchmeError.internal(
            '${slot.driverId} refresh failed: $error',
            cause: error,
          ),
        );
      }
      return null;
    }
    return _absorbProbe(
      e,
      slot,
      await _probe(slot.driver, e.endpointFor(slot)),
    );
  }

  /// Takes in a passive probe of [slot]'s driver; returns its power
  /// observation, if any.
  Observed<PowerMode>? _absorbProbe(
    _DeviceEntry e,
    _DriverSlot slot,
    ProbeResult result,
  ) {
    if (e.forgotten || _closed || !identical(e.slot(slot.driverId), slot)) {
      return null;
    }
    if (result.matched) {
      if (slot.session == null) {
        slot.capabilities = List.of(result.capabilities);
      }
      slot.requiresPairing = result.requiresPairing;
      slot.notes = List.of(result.notes);
      if (_isTransportError(slot.lastError)) slot.lastError = null;
      _touch(e, slot);
      final power = result.power;
      if (power != null) {
        _applyState(e, DeviceState(power: power), slot.driverId);
      }
      return power;
    }
    if (result.error case final error?) _noteFailure(e, slot, error);
    return null;
  }

  // -------------------------------------------------------------- pairing

  @override
  PairingFlow pair(String deviceId, String driverId) {
    if (_closed) {
      return failedPairing(
        const WatchmeError.cancelled('The engine is closed'),
      );
    }
    final entry = _devices[deviceId];
    if (entry == null) {
      return failedPairing(WatchmeError.internal('Unknown device: $deviceId'));
    }
    final slot = entry.slot(driverId);
    if (slot == null) {
      return failedPairing(
        WatchmeError.unsupported('$driverId does not handle this device'),
      );
    }
    final key = (deviceId, driverId);
    if (_pairings.containsKey(key)) {
      return failedPairing(
        WatchmeError.rejected(
          'Pairing ${slot.descriptor.protocol} with this device is already '
          'in progress',
        ),
      );
    }
    // Pairing replaces this driver's connection to the device, and some
    // devices serve one client at a time (a Sharp AQUOS's IP control
    // does): a session of the driver's own, open or opening, would make
    // the pairing's connection fail. So the pairing reserves the slot,
    // and the driver's pairing starts once what held the device has let
    // go: the session's close, and a connect in flight with the close of
    // what it opened. Until the pairing succeeds or ends, nothing else
    // connects the slot: a command fails on this route (and may fall
    // back), and no reconnect runs. A successful pairing connects again;
    // otherwise the next command does.
    _reserved.add(slot);
    slot.cancelReconnect();
    if (slot.session != null || slot.connecting != null) {
      _resetSession(entry, slot);
    }
    final holds = _letGo[slot];
    late final EnginePairing pairing;
    pairing = EnginePairing(
      _DeferredPairingFlow(
        holds == null || holds.isEmpty ? null : _released(slot),
        () => _startDriverPairing(entry, slot),
      ),
      onPaired: (credential) => _onPaired(entry, slot, credential),
      onDone: () {
        if (identical(_pairings[key], pairing)) {
          _pairings.remove(key);
          _reserved.remove(slot);
        }
      },
    );
    _pairings[key] = pairing;
    return pairing;
  }

  /// The driver's own pairing flow for [slot], or one that has failed.
  PairingFlow _startDriverPairing(_DeviceEntry entry, _DriverSlot slot) {
    if (_closed || entry.forgotten) {
      return failedPairing(const WatchmeError.cancelled('Pairing cancelled'));
    }
    final deviceId = entry.id;
    final driverId = slot.driverId;
    final PairingFlow? inner;
    try {
      inner = slot.driver.startPairing(
        entry.endpointFor(slot),
        _transports,
        PairingContext(
          deviceId: deviceId,
          clientName: config.clientName,
          // Read when the driver asks for it (VIZIO reuses its controller
          // id); a store that fails to read gives none rather than failing
          // the pairing.
          previousCredential: () async {
            try {
              return await _credentials.read(deviceId, driverId);
            } on Object {
              return null;
            }
          },
        ),
      );
    } on WatchmeError catch (error) {
      return failedPairing(error);
    } on Object catch (error) {
      return failedPairing(
        WatchmeError.internal(
          '$driverId could not start pairing: $error',
          cause: error,
        ),
      );
    }
    return inner ??
        failedPairing(
          WatchmeError.unsupported(
            '${slot.descriptor.protocol} needs no pairing',
          ),
        );
  }

  /// Completes once nothing recorded by [_holdUntil] holds [slot]'s device
  /// any more, or after [EngineConfig.connectTimeout] at most: a close that
  /// never returns must not keep the pairing from starting.
  Future<void> _released(_DriverSlot slot) async {
    Future<void> settled() async {
      for (
        var holds = _letGo[slot];
        holds != null && holds.isNotEmpty;
        holds = _letGo[slot]
      ) {
        await Future.wait([...holds]);
      }
    }

    try {
      await withClockTimeout(
        settled(),
        config.connectTimeout,
        _clock,
        () => const WatchmeError.timeout('The old connection did not close'),
      );
    } on WatchmeError {
      // Start anyway; the pairing reports what it finds.
    }
  }

  /// Records [work] as holding [slot]'s device until it completes.
  void _holdUntil(_DriverSlot slot, Future<void> work) {
    final holds = _letGo[slot] ??= {};
    late final Future<void> held;
    held = work
        .catchError((Object _) {})
        .whenComplete(() => holds.remove(held));
    holds.add(held);
  }

  /// Stores [credential], clears any revoked flag and connects.
  Future<void> _onPaired(
    _DeviceEntry e,
    _DriverSlot slot,
    Credential credential,
  ) async {
    if (e.forgotten || _closed) {
      throw const WatchmeError.cancelled('The device was forgotten');
    }
    var stored = credential;
    if (stored.deviceId != e.id || stored.driverId != slot.driverId) {
      stored = Credential.fromJson({
        ...stored.toJson(),
        'deviceId': e.id,
        'driverId': slot.driverId,
      });
    }
    await _credentials.write(stored);
    slot
      ..hasCredential = true
      ..reauthInvalid = false
      ..lastError = null
      ..consecutiveFailures = 0
      ..reconnectAttempts = 0;
    // The slot is free again once the new credential is in place.
    _reserved.remove(slot);
    _resetSession(e, slot);
    try {
      // Pairing already woke the device, at the user's request.
      await _ensureConnected(e, slot, allowWake: true);
    } on WatchmeError {
      // Pairing succeeded; the connect failure shows in the driver view.
    }
    _emitDevices();
  }

  // -------------------------------------------------------------- routing

  @override
  Future<CommandResult> send(String deviceId, Command command) async {
    if (_closed) {
      return const Failed(WatchmeError.cancelled('The engine is closed'));
    }
    try {
      await _ready();
      final entry = _devices[deviceId];
      if (entry == null) {
        return Failed(WatchmeError.internal('Unknown device: $deviceId'));
      }
      if (command case SetPower(:final on, :final userConfirmed)) {
        return await power.setPower(
          _EnginePowerTarget(this, entry),
          on,
          userConfirmed: userConfirmed,
        );
      }
      if (command case PressKey(:final key, :final action)
          when _powerKeys.contains(key)) {
        return await _pressPowerKey(entry, key, action);
      }
      if (command.capability case Capability.volume || Capability.mute) {
        return await _serialVolume(deviceId, () => _route(entry, command));
      }
      return await _route(entry, command);
    } on Object catch (error) {
      return Failed(
        WatchmeError.internal('The engine failed: $error', cause: error),
      );
    }
  }

  /// Per device, the last volume or mute command queued.
  final Map<String, Future<void>> _volumeTail = {};

  /// Volume and mute commands still waiting for the one in front of them.
  /// [close] lets them all go at once. Only waiting commands are held here,
  /// so nothing accumulates while commands come and go.
  final Set<Completer<void>> _volumeWaiters = {};

  /// Runs volume and mute commands for [deviceId] one at a time, so each
  /// routes and infers from the level the previous one left: two
  /// overlapping `SetVolume(20)` from 10 on a relative-only route must not
  /// both step by +10.
  ///
  /// [close] releases every queued command at once, as cancelled, even
  /// while the one in front never finishes (a hung session).
  Future<CommandResult> _serialVolume(
    String deviceId,
    Future<CommandResult> Function() run,
  ) {
    // send() checked before it yielded; close() may have run since, and a
    // waiter queued after it would never be released.
    if (_closed) {
      return Future.value(
        const Failed(WatchmeError.cancelled('The engine is closed')),
      );
    }
    final previous = _volumeTail[deviceId];
    final done = Completer<void>();
    final tail = done.future;
    _volumeTail[deviceId] = tail;
    final turn = Completer<void>();
    if (previous == null) {
      turn.complete();
    } else {
      _volumeWaiters.add(turn);
      previous.then((_) {
        if (_volumeWaiters.remove(turn)) turn.complete();
      });
    }
    return turn.future
        .then<CommandResult>((_) {
          if (_closed) {
            return const Failed(WatchmeError.cancelled('The engine is closed'));
          }
          return run();
        })
        .whenComplete(() {
          done.complete();
          if (identical(_volumeTail[deviceId], tail)) {
            _volumeTail.remove(deviceId);
          }
        });
  }

  Future<CommandResult> _route(_DeviceEntry entry, Command command) async {
    final before = _clock.now();
    if (command is SetVolume && _knownVolume(entry) == null) {
      await _connectRelativeVolume(entry);
    }
    final known = _knownVolume(entry);
    final routed = await _router.route(
      command,
      _candidates(entry, command.capability),
      (route, c) => _executeOn(entry, route, c),
      knownVolume: known,
    );
    final result = routed.result;
    if (routed.via case final via? when result.delivered) {
      _inferVolume(entry, command, via, known, before);
    } else if (mayHaveActed(result) && routed.steps.isNotEmpty) {
      _markUncertain(entry, command, routed.steps.last.driverId);
    }
    return result;
  }

  static const Set<RemoteKey> _powerKeys = {
    RemoteKey.power,
    RemoteKey.powerOn,
    RemoteKey.powerOff,
  };

  /// A power key goes to the power orchestrator, never to a session as a
  /// key press: a driver may map any of them to a toggle. The power key is
  /// a toggle intent; the discrete keys are `SetPower`. Holding one makes
  /// no sense and is refused.
  Future<CommandResult> _pressPowerKey(
    _DeviceEntry e,
    RemoteKey key,
    KeyAction action,
  ) async {
    if (action != KeyAction.click) {
      return Unsupported(
        'The ${key.name} key can only be pressed, not held: holding a '
        'power key would toggle the TV an unknown number of times',
      );
    }
    final target = _EnginePowerTarget(this, e);
    return switch (key) {
      RemoteKey.powerOn => power.setPower(target, true),
      RemoteKey.powerOff => power.setPower(target, false),
      _ => power.pressPowerKey(target),
    };
  }

  List<RouteCandidate> _candidates(
    _DeviceEntry e,
    Capability capability, {
    bool usableOnly = false,
  }) {
    final internet = _transports.features.contains(TransportFeature.internet);
    return [
      for (final (i, slot) in e.slots.indexed)
        if (slot.supportFor(capability) case final s
            when (!usableOnly || s.usable) &&
                (internet || !s.has(CapFlag.cloud)))
          RouteCandidate(
            driverId: slot.driverId,
            support: s,
            stability: slot.descriptor.stability,
            health: slot.health,
            preference: i,
          ),
    ];
  }

  Future<RouteAttempt> _executeOn(
    _DeviceEntry e,
    RouteCandidate route,
    Command command,
  ) async {
    if (_closed) {
      return const RouteAttempt(
        Failed(WatchmeError.cancelled('The engine is closed')),
        commandSent: false,
      );
    }
    final slot = e.slot(route.driverId);
    if (slot == null) {
      return RouteAttempt(
        Unsupported('${route.driverId} is no longer attached'),
        commandSent: false,
      );
    }
    if (slot.reauthInvalid) {
      return RouteAttempt(
        Failed(
          WatchmeError.reauthRequired(
            'Pair ${slot.descriptor.protocol} with this device again',
            rawDeviceMessage: slot.lastError?.rawDeviceMessage,
          ),
        ),
        commandSent: false,
      );
    }
    if (command case SetPower(on: false, :final userConfirmed)
        when slot.session == null &&
            slot.connecting == null &&
            !(userConfirmed && route.support.has(CapFlag.toggleOnly))) {
      // Connecting can wake a sleeping device (Fire TV's DIAL wake, and the
      // TV with it over HDMI-CEC) only for it to be sent to sleep again. A
      // passive probe that sees it off or asleep already settles it.
      //
      // Not for a toggle the user confirmed: they have just seen the device
      // on, and a probe's standby may be a guess (a Panasonic infers it
      // from a refused volume read, which a booting TV gives too). Skipping
      // the toggle would report the device off while it stays on.
      final power = _absorbProbe(
        e,
        slot,
        await _probe(slot.driver, e.endpointFor(slot)),
      );
      if (_alreadyOff(power)) {
        _emitDevices();
        return const RouteAttempt(Confirmed(), commandSent: false);
      }
      if (_closed || e.forgotten) {
        return const RouteAttempt(
          Failed(WatchmeError.cancelled('The device was forgotten')),
          commandSent: false,
        );
      }
    }
    final DriverSession session;
    try {
      session = await _ensureConnected(
        e,
        slot,
        allowWake: _mayWakeFor(route, command),
      );
    } on WatchmeError catch (error) {
      // A connect fails partiallyDelivered when a wake it sent may have
      // reached the device (a Fire TV's DIAL wake, then an API that never
      // opened or a refused token): the device may have acted, so this
      // counts as sent. Nothing falls back, and the power orchestrator
      // sends no toggle that would undo the wake.
      return RouteAttempt(
        Failed(error),
        commandSent: error.code == WatchmeErrorCode.partiallyDelivered,
      );
    }
    final started = _clock.now();
    CommandResult result;
    try {
      result = await session.execute(command);
    } on Object catch (error) {
      // Sessions must not throw; treat it as a driver bug.
      result = Failed(
        WatchmeError.internal('${slot.driverId} threw: $error', cause: error),
      );
    }
    slot.latency = _clock.now().difference(started);
    if (result.delivered) {
      slot.consecutiveFailures = 0;
      _touch(e, slot);
    } else if (result case Failed(:final error)) {
      _noteFailure(e, slot, error);
    }
    _emitDevices();
    return RouteAttempt(result);
  }

  /// Whether connecting to run [command] on [route] may wake the device.
  ///
  /// Most commands reaching here were sent by the user, so most may: a key
  /// press on a sleeping Fire TV means "wake up". The exceptions:
  ///
  /// * Power commands. Waking a device to turn it off would switch the TV
  ///   on over HDMI-CEC for nothing, and waking it before a toggle would
  ///   leave the toggle to switch it straight back off.
  /// * The end of a hold (`PressKey(key, KeyAction.up)`). Apps send it on
  ///   their own when they stop getting the key-up (focus loss, the app
  ///   going to the background, the screen closing), and a sleeping device
  ///   repeats no key, so there is nothing to wake it for.
  static bool _mayWakeFor(RouteCandidate route, Command command) =>
      switch (command) {
        PressKey(action: KeyAction.up) => false,
        _ => switch (command.capability) {
          Capability.powerOn || Capability.powerOff =>
            command is SetPower &&
                command.on &&
                !route.support.has(CapFlag.toggleOnly),
          _ => true,
        },
      };

  /// Connects the sessions a `SetVolume` may have to step through, so a
  /// level they report is known before the steps are computed. They would
  /// be connected to run the command anyway. These connects only read, so
  /// they may not wake the device; the route itself connects with waking
  /// allowed when it is tried.
  Future<void> _connectRelativeVolume(_DeviceEntry e) => Future.wait([
    for (final slot in e.slots)
      if (slot.supportFor(Capability.volume) case final s
          when s.usable && s.has(CapFlag.relativeOnly))
        if (!slot.needsPairing)
          _ensureConnected(e, slot, allowWake: false).then<void>(
            (_) {},
            onError: (Object _) {
              // The route reports the failure when it is tried.
            },
          ),
  ]);

  int? _knownVolume(_DeviceEntry e) {
    final v = e.state.volume;
    return v != null && v.confidence != Confidence.stale ? v.value : null;
  }

  /// Records the volume watchme just set, unless the session reported it.
  void _inferVolume(
    _DeviceEntry e,
    Command command,
    RouteCandidate via,
    int? known,
    DateTime before,
  ) {
    final reported = e.state.volume;
    if (reported != null &&
        reported.confidence == Confidence.reported &&
        !reported.at.isBefore(before)) {
      return;
    }
    final level = switch (command) {
      SetVolume(:final level) => level,
      StepVolume(:final steps) when known != null => math.max(
        0,
        math.min(100, known + steps),
      ),
      PressKey(key: RemoteKey.volumeUp, action: KeyAction.click)
          when known != null =>
        math.min(100, known + 1),
      PressKey(key: RemoteKey.volumeDown, action: KeyAction.click)
          when known != null =>
        math.max(0, known - 1),
      _ => null,
    };
    if (level == null) return;
    // The command just delivered sets the level, whatever came before.
    e.volumeUncertainSince = null;
    _applyState(
      e,
      DeviceState(volume: Observed.inferred(level, via.driverId, _clock.now())),
      via.driverId,
    );
  }

  /// [command] failed in a way that may still have changed the device (a
  /// partial delivery, a timeout): what watchme knew about the state it
  /// changes no longer holds. Marks it stale, whichever source reported it,
  /// so nothing is computed from it (a `SetVolume` stepped from it, say)
  /// until a source reports it again with an observation made after now.
  ///
  /// A re-report of an older observation does not count: a session's
  /// refresh may return the state it cached before the command, at its old
  /// time, and [DeviceState.merge] would prefer that live observation over
  /// the stale one made at the same instant (see [_withoutOutdated]).
  void _markUncertain(_DeviceEntry e, Command command, String driverId) {
    final s = e.state;
    final now = _clock.now();
    final DeviceState next;
    switch (command) {
      case SetVolume() ||
          StepVolume() ||
          PressKey(key: RemoteKey.volumeUp || RemoteKey.volumeDown):
        e.volumeUncertainSince = now;
        next = s.copyWith(volume: s.volume?.asStale());
      case SetMute() || PressKey(key: RemoteKey.mute):
        e.mutedUncertainSince = now;
        next = s.copyWith(muted: s.muted?.asStale());
      default:
        return;
    }
    _setState(e, next, driverId);
  }

  /// [diff] without the volume or mute observations made no later than a
  /// command that may have changed them unseen ([_markUncertain]): they
  /// describe the device before that command. A newer observation is kept
  /// and ends the uncertainty.
  static DeviceState _withoutOutdated(_DeviceEntry e, DeviceState diff) {
    final volumeSince = e.volumeUncertainSince;
    final mutedSince = e.mutedUncertainSince;
    if (volumeSince == null && mutedSince == null) return diff;
    bool outdated<T>(Observed<T>? o, DateTime? since) =>
        o != null && since != null && !o.at.isAfter(since);
    final volume = diff.volume;
    final muted = diff.muted;
    final dropVolume = outdated(volume, volumeSince);
    final dropMuted = outdated(muted, mutedSince);
    if (volume != null && !dropVolume) e.volumeUncertainSince = null;
    if (muted != null && !dropMuted) e.mutedUncertainSince = null;
    if (!dropVolume && !dropMuted) return diff;
    return DeviceState(
      power: diff.power,
      volume: dropVolume ? null : volume,
      muted: dropMuted ? null : muted,
      input: diff.input,
      foregroundApp: diff.foregroundApp,
      nowPlaying: diff.nowPlaying,
      connections: diff.connections,
    );
  }

  // ------------------------------------------------------------- sessions

  /// Thrown by a connect whose slot was reset while it ran (the device
  /// moved, was re-paired, forgotten, or the engine closed).
  static const WatchmeError _superseded = WatchmeError.cancelled(
    'The connection was superseded',
  );

  /// The slot's session, connecting first if needed. [allowWake] is passed
  /// to [Driver.connect]: only a command the user sent may wake the device.
  ///
  /// A connect superseded by a reset (e.g. the device moved to a new
  /// address) is retried once, so the command that asked for it is not
  /// failed for nothing. So is a passive connect this call joined (a
  /// background reconnect) that found the device asleep, when this call
  /// may wake it.
  Future<DriverSession> _ensureConnected(
    _DeviceEntry e,
    _DriverSlot slot, {
    required bool allowWake,
  }) async {
    final joinsPassive =
        allowWake &&
        slot.session == null &&
        slot.connecting != null &&
        !slot.connectingMayWake;
    try {
      return await _ensureConnectedOnce(e, slot, allowWake: allowWake);
    } on WatchmeError catch (error) {
      final retry =
          identical(error, _superseded) ||
          (joinsPassive && error.code == WatchmeErrorCode.unreachable);
      if (!retry ||
          _closed ||
          e.forgotten ||
          slot.reauthInvalid ||
          !identical(e.slot(slot.driverId), slot)) {
        rethrow;
      }
      return _ensureConnectedOnce(e, slot, allowWake: allowWake);
    }
  }

  Future<DriverSession> _ensureConnectedOnce(
    _DeviceEntry e,
    _DriverSlot slot, {
    required bool allowWake,
  }) {
    if (_closed) return Future.error(_superseded);
    if (_reserved.contains(slot)) {
      return Future.error(
        WatchmeError.rejected(
          'Pairing ${slot.descriptor.protocol} with this device is in '
          'progress',
        ),
      );
    }
    final session = slot.session;
    if (session != null) return Future.value(session);
    final pending = slot.connecting;
    if (pending != null) return pending;
    late final Future<DriverSession> attempt;
    attempt = _connect(e, slot, allowWake: allowWake).whenComplete(() {
      if (identical(slot.connecting, attempt)) slot.connecting = null;
    });
    slot
      ..connecting = attempt
      ..connectingMayWake = allowWake;
    return attempt;
  }

  Future<DriverSession> _connect(
    _DeviceEntry e,
    _DriverSlot slot, {
    required bool allowWake,
  }) async {
    slot.cancelReconnect();
    final generation = slot.generation;
    bool current() => generation == slot.generation && !e.forgotten && !_closed;
    final credential = await _readCredential(e, slot);
    // Reset while the store was read: the endpoint or credential may be out
    // of date, and nothing has been sent yet.
    if (!current()) throw _superseded;
    if (credential == null && slot.requiresPairing) {
      // Nothing was tried, so this is not a connection failure.
      throw WatchmeError.unauthorized(
        'Pair ${slot.descriptor.protocol} with this device first',
      );
    }
    _setConnection(e, slot, ConnectionState.connecting);
    // The device may be held until the driver's connect has settled and a
    // session nobody will use is closed (one that came after the timeout,
    // or after a reset): a pairing waits for that.
    final settled = Completer<void>();
    _holdUntil(slot, settled.future);
    void closeUnwanted(DriverSession unwanted) =>
        unawaited(_closeQuietly(unwanted).whenComplete(settled.complete));
    final connecting = Future.sync(
      () => slot.driver.connect(
        e.endpointFor(slot),
        _transports,
        credential,
        allowWake: allowWake,
      ),
    );
    unawaited(
      connecting.then<void>(
        (_) {},
        onError: (Object _) {
          settled.complete();
        },
      ),
    );
    try {
      final session = await withClockTimeout(
        connecting,
        config.connectTimeout,
        _clock,
        () => WatchmeError.timeout(
          'Connecting ${slot.driverId} to ${e.record.host} timed out',
        ),
        onLateValue: closeUnwanted,
      );
      if (!current()) {
        closeUnwanted(session);
        throw _superseded;
      }
      settled.complete();
      _attach(e, slot, session);
      return session;
    } on WatchmeError catch (error) {
      if (current()) {
        _connectFailed(e, slot, error, hadCredential: credential != null);
      }
      rethrow;
    } on Object catch (error) {
      final wrapped = WatchmeError.internal(
        '${slot.driverId} failed to connect: $error',
        cause: error,
      );
      if (current()) {
        _connectFailed(e, slot, wrapped, hadCredential: credential != null);
      }
      throw wrapped;
    }
  }

  Future<Credential?> _readCredential(_DeviceEntry e, _DriverSlot slot) async {
    try {
      final credential = await _credentials.read(e.id, slot.driverId);
      slot.hasCredential = credential != null;
      return credential;
    } on Object catch (error) {
      throw WatchmeError.internal(
        'Could not read the credential store: $error',
        cause: error,
      );
    }
  }

  void _attach(_DeviceEntry e, _DriverSlot slot, DriverSession session) {
    slot
      ..session = session
      ..lastError = null
      ..consecutiveFailures = 0
      ..reconnectAttempts = 0;
    if (session.capabilities.isNotEmpty) {
      slot.capabilities = List.of(session.capabilities);
    }
    slot.subscription = session.events.listen(
      (event) => _onSessionEvent(e, slot, session, event),
      onDone: () => _sessionDropped(e, slot, session, null),
    );
    _touch(e, slot);
    _applyState(e, _withoutConnections(session.state), slot.driverId);
    _setConnection(e, slot, ConnectionState.connected);
    unawaited(_persistQuietly(e));
  }

  /// Records a failed connect. The credential counts as revoked when the
  /// device refused it, even when the refusal is only the cause of the
  /// failure (a wake went out first: see [credentialFailure]).
  void _connectFailed(
    _DeviceEntry e,
    _DriverSlot slot,
    WatchmeError error, {
    required bool hadCredential,
  }) {
    final refusal = credentialFailure(error);
    if (refusal != null &&
        (refusal.code == WatchmeErrorCode.reauthRequired || hadCredential)) {
      _markReauth(e, slot, refusal);
      return;
    }
    _noteFailure(e, slot, error);
    _setConnection(e, slot, ConnectionState.failed, error);
  }

  void _onSessionEvent(
    _DeviceEntry e,
    _DriverSlot slot,
    DriverSession session,
    DeviceEvent event,
  ) {
    if (!identical(slot.session, session)) return;
    switch (event) {
      case StateChanged(:final state):
        _applyState(e, _withoutConnections(state), slot.driverId);
      case ConnectionChanged(state: ConnectionState.connected):
        _setConnection(e, slot, ConnectionState.connected);
      case ConnectionChanged(state: ConnectionState.connecting):
        _setConnection(e, slot, ConnectionState.connecting);
      case ConnectionChanged(:final state, :final error):
        _sessionDropped(e, slot, session, error, state: state);
      case CapabilitiesChanged(:final capabilities):
        slot.capabilities = List.of(capabilities);
        e.emit(event);
        _emitDevices();
      case ReauthRequired(:final error):
        _markReauth(e, slot, error);
    }
  }

  /// The session went away: drop it, and reconnect in the background unless
  /// that could wake a device that was turned off.
  void _sessionDropped(
    _DeviceEntry e,
    _DriverSlot slot,
    DriverSession session,
    WatchmeError? error, {
    ConnectionState state = ConnectionState.disconnected,
  }) {
    if (!identical(slot.session, session)) return;
    // Decide before marking this session's observations stale.
    final mayReconnect = !_reconnectBlocked(e);
    _detach(slot);
    e.state = _staleFrom(e.state, slot.driverId);
    if (error != null) slot.lastError = error;
    _setConnection(e, slot, state, error);
    if (mayReconnect) _scheduleReconnect(e, slot);
  }

  void _scheduleReconnect(_DeviceEntry e, _DriverSlot slot) {
    if (_closed || e.forgotten || slot.needsPairing) return;
    if (slot.reconnectTimer != null) return;
    final delay = config.reconnect.delayFor(slot.reconnectAttempts);
    if (delay == null) return;
    slot.reconnectAttempts++;
    slot.reconnectTimer = _clock.timer(delay, () {
      slot.reconnectTimer = null;
      if (_closed || e.forgotten) return;
      if (slot.session != null || slot.connecting != null) return;
      if (_reconnectBlocked(e)) return;
      // Passive: nobody asked for this connect, so it must not wake the
      // device. A device asleep fails fast as unreachable and is retried
      // with backoff; the next user command connects with waking allowed.
      _ensureConnected(e, slot, allowWake: false).then<void>(
        (_) {},
        onError: (Object error) {
          final retry =
              error is WatchmeError &&
              error.code != WatchmeErrorCode.cancelled &&
              credentialFailure(error) == null &&
              error.code != WatchmeErrorCode.unsupported &&
              error.code != WatchmeErrorCode.destinationRefused;
          if (retry) _scheduleReconnect(e, slot);
        },
      );
    });
  }

  /// Whether a background reconnect could wake a device that should stay
  /// off: watchme turned it off last, or a live source says it is off.
  bool _reconnectBlocked(_DeviceEntry e) {
    final last = power.lastCommand(e.id);
    if (last != null && !last.on) return true;
    final p = e.state.power;
    return p != null &&
        p.confidence != Confidence.stale &&
        (p.value == PowerMode.off || p.value == PowerMode.standby);
  }

  void _markReauth(_DeviceEntry e, _DriverSlot slot, WatchmeError error) {
    if (slot.reauthInvalid) return;
    final reauth = error.code == WatchmeErrorCode.reauthRequired
        ? error
        : WatchmeError.reauthRequired(
            error.message,
            rawDeviceMessage: error.rawDeviceMessage,
            cause: error,
          );
    slot
      ..reauthInvalid = true
      ..lastError = reauth
      ..consecutiveFailures += 1
      ..generation += 1;
    slot.cancelReconnect();
    _detach(slot);
    e.state = _staleFrom(e.state, slot.driverId);
    _setConnection(e, slot, ConnectionState.disconnected, reauth);
    e.emit(ReauthRequired(reauth, driverId: slot.driverId));
    _emitDevices();
  }

  /// Records a failure. A revoked credential, even as the cause of a
  /// partial delivery (see [credentialFailure]), marks the pairing invalid.
  void _noteFailure(_DeviceEntry e, _DriverSlot slot, WatchmeError error) {
    if (credentialFailure(error) case final refusal?
        when refusal.code == WatchmeErrorCode.reauthRequired) {
      _markReauth(e, slot, refusal);
      return;
    }
    slot
      ..lastError = error
      ..consecutiveFailures += 1;
    if (error.code == WatchmeErrorCode.unreachable) {
      e.unreachable[slot.driverId] = _clock.now();
    }
  }

  void _setConnection(
    _DeviceEntry e,
    _DriverSlot slot,
    ConnectionState state, [
    WatchmeError? error,
  ]) {
    if (slot.connection == state) return;
    slot.connection = state;
    e.emit(ConnectionChanged(state, driverId: slot.driverId, error: error));
    _emitDevices();
  }

  /// Drops the slot's session and anything in flight for it.
  void _resetSession(_DeviceEntry e, _DriverSlot slot) {
    slot
      ..generation += 1
      ..connecting = null;
    slot.cancelReconnect();
    _detach(slot);
    _setConnection(e, slot, ConnectionState.disconnected);
  }

  void _detach(_DriverSlot slot) {
    final session = slot.session;
    slot.session = null;
    unawaited(slot.subscription?.cancel());
    slot.subscription = null;
    if (session != null) _holdUntil(slot, _closeQuietly(session));
  }

  Future<void> _closeSession(_DriverSlot slot) async {
    final session = slot.session;
    slot.session = null;
    await slot.subscription?.cancel();
    slot.subscription = null;
    if (session != null) await _closeQuietly(session);
  }

  static Future<void> _closeQuietly(DriverSession session) async {
    try {
      await session.close();
    } on Object {
      // Closing is best effort; the session is discarded either way.
    }
  }

  // ---------------------------------------------------------------- power

  /// Collects every power observation for the device without waking it:
  /// open sessions are refreshed and the other drivers probe passively
  /// (never connect, since connecting can wake a TV). Adds the engine's
  /// reachability evidence.
  Future<List<Observed<PowerMode>>> _powerEvidence(_DeviceEntry e) async {
    if (_closed) return const [];
    final fresh = await Future.wait([
      for (final slot in [...e.slots]) _refreshSlot(e, slot),
    ]);
    _emitDevices();
    return [
      ...fresh.nonNulls,
      for (final slot in e.slots) ?slot.session?.state.power,
      ?e.state.power,
      ?e.reachability,
    ];
  }

  /// Probes every driver passively; `true` if any recognises the device.
  Future<bool> _answers(_DeviceEntry e) async {
    if (_closed) return false;
    final slots = [...e.slots];
    final results = await Future.wait([
      for (final slot in slots) _probe(slot.driver, e.endpointFor(slot)),
    ]);
    var answered = false;
    for (final (i, result) in results.indexed) {
      _absorbProbe(e, slots[i], result);
      if (result.matched) answered = true;
    }
    _emitDevices();
    return answered;
  }

  static bool _alreadyOff(Observed<PowerMode>? power) =>
      power != null &&
      power.confidence != Confidence.stale &&
      (power.value == PowerMode.off || power.value == PowerMode.standby);

  // -------------------------------------------------------------- helpers

  bool _runnable(Driver d) {
    final backends = d.descriptor.backends;
    return backends.isEmpty ||
        backends.any((b) => _transports.supportsAll(b.requires));
  }

  List<Driver> get _enabledDrivers => [
    for (final d in _drivers)
      if (_runnable(d)) d,
  ];

  Driver? _driverById(String id) {
    for (final d in _drivers) {
      if (d.descriptor.id == id) return d;
    }
    return null;
  }

  Future<_Probe> _probeOne(Driver driver, Endpoint endpoint) async => (
    driver: driver,
    endpoint: endpoint,
    result: await _probe(driver, endpoint),
  );

  /// [Driver.probe] with a timeout; never throws.
  Future<ProbeResult> _probe(Driver driver, Endpoint endpoint) async {
    final id = driver.descriptor.id;
    try {
      return await withClockTimeout(
        Future.sync(() => driver.probe(endpoint, _transports)),
        config.probeTimeout,
        _clock,
        () => WatchmeError.timeout('$id did not finish probing in time'),
      );
    } on WatchmeError catch (error) {
      return ProbeResult.notMatched(error: error);
    } on Object catch (error) {
      return ProbeResult.notMatched(
        error: WatchmeError.internal('$id probe failed: $error', cause: error),
      );
    }
  }

  /// Records that [slot]'s driver got an answer from the device.
  void _touch(_DeviceEntry e, _DriverSlot slot) {
    e.record = e.record.copyWith(lastSeen: _clock.now());
    e.unreachable.remove(slot.driverId);
  }

  /// Writes of device records still in progress. [close] waits for them,
  /// so nothing writes to the store after it returns.
  final Set<Future<void>> _pendingWrites = {};

  Future<void> _persistQuietly(_DeviceEntry e) {
    if (e.forgotten || _closed) return Future.value();
    final write = () async {
      try {
        await _repository.put(e.record);
      } on Object {
        // lastSeen is refreshed on the next successful write.
      }
    }();
    _pendingWrites.add(write);
    return write.whenComplete(() => _pendingWrites.remove(write));
  }

  void _applyState(_DeviceEntry e, DeviceState diff, String driverId) {
    final fresh = _withoutOutdated(e, diff);
    _setState(e, _believeStale(e.state.merge(fresh), fresh), driverId);
  }

  void _setState(_DeviceEntry e, DeviceState next, String driverId) {
    final previous = e.state;
    e.state = next;
    final changes = next.changesSince(previous);
    if (changes.isEmpty) return;
    e.emit(StateChanged(changes, driverId: driverId));
    _emitDevices();
  }

  /// [merged] with each observation [diff] reports stale marked stale too,
  /// when the same source made it and it is not newer than the report.
  ///
  /// [DeviceState.merge] keeps a live observation over a stale one made at
  /// the same instant, but a source that says its own observation went
  /// stale (the device stopped answering) must be believed.
  static DeviceState _believeStale(DeviceState merged, DeviceState diff) {
    Observed<T>? check<T>(Observed<T>? current, Observed<T>? report) =>
        current != null &&
            report != null &&
            report.confidence == Confidence.stale &&
            current.confidence != Confidence.stale &&
            current.source == report.source &&
            !current.at.isAfter(report.at)
        ? current.asStale()
        : current;
    return DeviceState(
      power: check(merged.power, diff.power),
      volume: check(merged.volume, diff.volume),
      muted: check(merged.muted, diff.muted),
      input: check(merged.input, diff.input),
      foregroundApp: check(merged.foregroundApp, diff.foregroundApp),
      nowPlaying: check(merged.nowPlaying, diff.nowPlaying),
      connections: merged.connections,
    );
  }

  static bool _isTransportError(WatchmeError? error) =>
      error != null &&
      (error.code == WatchmeErrorCode.unreachable ||
          error.code == WatchmeErrorCode.timeout);

  static DeviceState _withoutConnections(DeviceState s) => DeviceState(
    power: s.power,
    volume: s.volume,
    muted: s.muted,
    input: s.input,
    foregroundApp: s.foregroundApp,
    nowPlaying: s.nowPlaying,
  );

  static DeviceState _staleFrom(DeviceState s, String source) {
    Observed<T>? stale<T>(Observed<T>? o) =>
        o != null && o.source == source ? o.asStale() : o;
    return DeviceState(
      power: stale(s.power),
      volume: stale(s.volume),
      muted: stale(s.muted),
      input: stale(s.input),
      foregroundApp: stale(s.foregroundApp),
      nowPlaying: stale(s.nowPlaying),
    );
  }
}

/// A driver's pairing flow that starts once [ready] completes (at once
/// when it is `null`), its steps and answers passed through. Answers given
/// before it starts are kept for it, and a cancel before then means it
/// never starts.
final class _DeferredPairingFlow implements PairingFlow {
  _DeferredPairingFlow(Future<void>? ready, this._start) {
    if (ready == null) {
      _begin();
    } else {
      unawaited(ready.then((_) => _begin()));
    }
  }

  final PairingFlow Function() _start;
  final StreamController<PairingStep> _steps = StreamController();
  final List<String> _answers = [];
  PairingFlow? _inner;
  bool _cancelled = false;

  void _begin() {
    if (_cancelled) return;
    final inner = _inner = _start();
    for (final answer in _answers) {
      inner.submit(answer);
    }
    _answers.clear();
    inner.steps.listen(
      _steps.add,
      onError: _steps.addError,
      onDone: () => unawaited(_steps.close()),
    );
  }

  @override
  Stream<PairingStep> get steps => _steps.stream;

  @override
  void submit(String value) {
    final inner = _inner;
    if (inner != null) {
      inner.submit(value);
    } else if (!_cancelled) {
      _answers.add(value);
    }
  }

  @override
  Future<void> cancel() async {
    final inner = _inner;
    if (inner != null) return inner.cancel();
    if (_cancelled) return;
    _cancelled = true;
    _steps.add(
      const PairingFailed(WatchmeError.cancelled('Pairing cancelled')),
    );
    unawaited(_steps.close());
  }
}

/// The engine's view of one device for the [PowerOrchestrator].
final class _EnginePowerTarget implements PowerTarget {
  _EnginePowerTarget(this._engine, this._entry);

  final Engine _engine;
  final _DeviceEntry _entry;

  @override
  String get deviceId => _entry.id;

  @override
  String get host => _entry.record.host;

  @override
  Set<String> get macs => _entry.identity.macs;

  @override
  Duration? get powerQuietPeriod {
    Duration? longest;
    for (final slot in _entry.slots) {
      final own = slot.descriptor.powerQuietPeriod;
      if (own != null && (longest == null || own > longest)) longest = own;
    }
    return longest;
  }

  @override
  List<RouteCandidate> routes(Capability capability) =>
      _engine._candidates(_entry, capability, usableOnly: true);

  @override
  Future<RouteAttempt> execute(RouteCandidate route, Command command) =>
      _engine._executeOn(_entry, route, command);

  @override
  Future<List<Observed<PowerMode>>> powerEvidence() =>
      _engine._powerEvidence(_entry);

  @override
  Future<bool> answers() => _engine._answers(_entry);
}
