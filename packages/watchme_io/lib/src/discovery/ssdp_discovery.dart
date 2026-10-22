import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

import 'ssdp_message.dart';
import 'upnp_description.dart';

/// SSDP discovery (provider id `ssdp`): M-SEARCH for UPnP devices, Roku
/// ECP and DIAL servers, Panasonic VIERA and Sharp AQUOS TVs.
///
/// Each scan sends an M-SEARCH per search target ([attempts] times, since
/// multicast over Wi-Fi is lossy), collects the unicast replies through the
/// [NetworkStack], de-duplicates them by `USN`, and, with
/// [fetchDescriptions], fetches each `LOCATION` once to add the UPnP
/// description fields (`friendlyName`, `manufacturer`, `modelName`, `UDN`,
/// ...) and DIAL's `Application-URL` response header to the hit.
///
/// Every reply header is copied into [DiscoveryHit.attributes] under its
/// lower-case name, so vendor headers such as Roku's
/// `device-group.roku.com` and DIAL's `WAKEUP` reach the matchers; a
/// `WAKEUP: MAC=...` header also fills [DiscoveryHit.mac].
///
/// Safety:
/// * A reply from a sender outside [destinationPolicy] (LAN-only by
///   default: private, link-local and unique-local addresses) is dropped
///   before it is parsed, so it yields no hit, no fetch and no address to
///   probe.
/// * A reply's `LOCATION` is used as the device address, and fetched, only
///   when its host is an IP literal [destinationPolicy] allows. Naming the
///   replying host earns no exception. So a spoofed reply cannot make
///   watchme contact a host on the internet or in the shared (CGNAT/VPN)
///   range. A loopback `LOCATION` additionally needs a loopback sender
///   (a local simulator), so that even a policy that allows loopback never
///   lets a LAN host point watchme at this host's own services. Otherwise
///   the hit is placed at the (already checked) sender, without a port.
/// * A description is fetched at most once per `LOCATION`, for at most
///   [maxDescriptionFetches] locations per scan and
///   [maxDescriptionFetchesPerSender] per replying host, and a body larger
///   than 512 KiB is refused as soon as it is seen, so hostile replies
///   cannot make a scan buffer large amounts of data.
/// * Malformed datagrams are ignored.
///
/// The stream closes when the window ends and outstanding description
/// fetches (bounded by [descriptionTimeout]) finish. It reports an error
/// only when no query could be sent at all (for example, no network).
final class SsdpDiscovery implements DiscoveryProvider {
  /// Creates a provider sending through [network].
  SsdpDiscovery(
    this.network, {
    this.searchTargets = defaultSearchTargets,
    this.mx = 2,
    this.attempts = 2,
    this.resendDelay = const Duration(milliseconds: 300),
    this.fetchDescriptions = true,
    this.descriptionTimeout = const Duration(seconds: 3),
    this.maxDescriptionFetches = 32,
    this.maxDescriptionFetchesPerSender = 4,
    this.group = ssdpGroup,
    this.port = ssdpPort,
    this.clock = const SystemClock(),
    this.destinationPolicy = DestinationPolicy.lanOnly,
  });

  /// Searched when a scan names no service types: everything, plus the
  /// targets of the TVs watchme drives, explicitly, because some devices
  /// answer only their own target: Roku ECP, DIAL (its service type, which
  /// Fire TV answers, and its device type, which VIZIO's DIAL server
  /// answers), Panasonic VIERA's network remote control service and Sharp
  /// AQUOS's IP-control device type.
  static const List<String> defaultSearchTargets = [
    'ssdp:all',
    'roku:ecp',
    'urn:dial-multiscreen-org:service:dial:1',
    'urn:dial-multiscreen-org:device:dial:1',
    'urn:panasonic-com:service:p00NetworkControl:1',
    'urn:schemas-sharp-co-jp:device:AquosIPC:1',
  ];

  /// Where M-SEARCHes are sent from and descriptions fetched.
  final NetworkStack network;

  /// Search targets used when a scan names none.
  final List<String> searchTargets;

  /// The `MX` header: devices delay their reply by up to this many seconds.
  /// Scan windows should be longer.
  final int mx;

  /// How many times each M-SEARCH is sent.
  final int attempts;

  /// The gap between attempts.
  final Duration resendDelay;

  /// Whether to fetch `LOCATION` device descriptions.
  final bool fetchDescriptions;

  /// Deadline for one description fetch.
  final Duration descriptionTimeout;

  /// Most distinct `LOCATION`s fetched in one scan; later ones are reported
  /// without description fields.
  final int maxDescriptionFetches;

  /// Most distinct `LOCATION`s fetched for one replying host in one scan.
  final int maxDescriptionFetchesPerSender;

  /// Multicast group (tests may use another).
  final String group;

  /// Multicast port (tests may use another).
  final int port;

  /// Time source for resends.
  final Clock clock;

  /// Which senders are heard and which `LOCATION`s are used; LAN-only by
  /// default. Loopback tests and simulators opt in with
  /// `DestinationPolicy(allowLoopback: true)`.
  final DestinationPolicy destinationPolicy;

  /// Descriptions larger than this are not device descriptions.
  static const int maxDescriptionBytes = 512 * 1024;

  @override
  String get id => DiscoveryProviderId.ssdp;

  @override
  Set<TransportFeature> get requires => const {TransportFeature.multicast};

  @override
  Stream<DiscoveryHit> scan(
    Duration window, {
    Set<String> serviceTypes = const {},
  }) {
    final targets = serviceTypes.isEmpty
        ? searchTargets
        : [
            for (final type in serviceTypes)
              if (isSsdpSearchTarget(type)) type.trim(),
          ];
    return _Scan(this, targets, window).run();
  }

  Future<({UpnpDescription description, String? applicationUrl})?> _fetch(
    Uri location,
  ) async {
    try {
      final result = await network.http(
        HttpCall.get(
          location,
          timeout: descriptionTimeout,
          maxResponseBytes: maxDescriptionBytes,
        ),
      );
      if (!result.ok || result.body.length > maxDescriptionBytes) return null;
      final description = UpnpDescription.tryParse(result.text);
      if (description == null) return null;
      return (
        description: description,
        applicationUrl: result.header(DiscoveryAttr.applicationUrl),
      );
    } on WatchmeError {
      return null;
    }
  }
}

/// Whether [type] can be an SSDP search target, i.e. it is not a DNS-SD
/// service type such as `_googlecast._tcp`. Lets one set of matcher types
/// be handed to every provider.
bool isSsdpSearchTarget(String type) {
  final t = type.trim();
  return t.isNotEmpty && !isDnsSdServiceType(t);
}

/// Whether [type] is a DNS-SD service type (`_name._tcp` or `_name._udp`,
/// optionally followed by `.local` or `.local.`).
bool isDnsSdServiceType(String type) => RegExp(
  r'^_[^.\s]+\._(tcp|udp)(\.local\.?)?$',
  caseSensitive: false,
).hasMatch(type.trim());

/// Where a discovered SSDP service lives, given the replying [sender] and
/// the reply's [location], under [policy]; `null` when [policy] refuses the
/// sender, whose reply must then be ignored altogether.
///
/// The `LOCATION` host and port are used, and [fetchable] is true, when the
/// host is an IP literal that [policy] allows (a loopback one only from a
/// loopback sender). Being the sender itself earns no exception. Otherwise
/// the service is placed at the sender, with no port.
({String host, int? port, bool fetchable})? ssdpPlacement(
  String sender,
  Uri? location, {
  DestinationPolicy policy = DestinationPolicy.lanOnly,
}) {
  final senderClass = classifyHostAddress(sender);
  if (!policy.allowsClass(senderClass)) return null;
  final fallback = (host: sender, port: null, fetchable: false);
  final address = location == null
      ? null
      : InternetAddress.tryParse(location.host);
  if (address == null) return fallback;
  final kind = classifyHostAddress(address.address);
  final trusted =
      policy.allowsClass(kind) &&
      (kind != HostAddressClass.loopback ||
          senderClass == HostAddressClass.loopback);
  return trusted
      ? (host: address.address, port: location!.port, fetchable: true)
      : fallback;
}

/// The hit for an SSDP [message] from [sender], enriched with [description]
/// and [applicationUrl] when they were fetched; `null` when [policy]
/// refuses the sender (see [ssdpPlacement]).
DiscoveryHit? ssdpHit(
  String sender,
  SsdpMessage message, {
  UpnpDescription? description,
  String? applicationUrl,
  DestinationPolicy policy = DestinationPolicy.lanOnly,
}) {
  final placement = ssdpPlacement(sender, message.locationUri, policy: policy);
  if (placement == null) return null;
  return DiscoveryHit(
    host: placement.host,
    provider: DiscoveryProviderId.ssdp,
    port: placement.port,
    serviceType: message.serviceType,
    name: description?.friendlyName,
    attributes: {
      ...message.headers,
      ...?description?.fields,
      DiscoveryAttr.applicationUrl: ?applicationUrl,
    },
    mac: message.wakeupMac,
    stableId: message.uuid ?? description?.udn,
  );
}

final class _Scan {
  _Scan(this.provider, this.targets, this.window);

  final SsdpDiscovery provider;
  final List<String> targets;
  final Duration window;

  late final StreamController<DiscoveryHit> _out = StreamController(
    onListen: _start,
    onCancel: _cancel,
  );
  final List<StreamSubscription<Datagram>> _subscriptions = [];
  final List<Completer<void>> _queriesDone = [];
  final Set<String> _seen = {};
  final Set<Future<void>> _pending = {};
  final Map<
    Uri,
    Future<({UpnpDescription description, String? applicationUrl})?>
  >
  _descriptions = {};
  final Map<String, int> _fetchesBySender = {};
  WatchmeError? _firstError;
  var _sent = 0;
  var _cancelled = false;

  Stream<DiscoveryHit> run() => _out.stream;

  Future<void> _start() async {
    final queries = <Future<void>>[];
    for (var attempt = 0; attempt < provider.attempts; attempt++) {
      final offset = provider.resendDelay * attempt;
      if (attempt > 0 && offset >= window) break;
      for (final target in targets) {
        queries.add(_query(target, offset));
      }
    }
    await Future.wait(queries);
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
    if (_sent == 0 && _firstError != null && !_cancelled) {
      _out.addError(_firstError!);
    }
    _cancel();
  }

  Future<void> _query(String target, Duration offset) async {
    if (offset > Duration.zero) await provider.clock.delay(offset);
    if (_cancelled) return;
    final done = Completer<void>();
    _queriesDone.add(done);
    var failed = false;
    _subscriptions.add(
      provider.network
          .multicastQuery(
            provider.group,
            provider.port,
            buildMSearch(
              target,
              mx: provider.mx,
              host: '${provider.group}:${provider.port}',
            ),
            window - offset,
          )
          .listen(
            _handle,
            onError: (Object e) {
              failed = true;
              _firstError ??= e is WatchmeError
                  ? e
                  : WatchmeError.internal('SSDP query failed: $e', cause: e);
            },
            onDone: () {
              if (!failed) _sent++;
              if (!done.isCompleted) done.complete();
            },
          ),
    );
    await done.future;
  }

  void _handle(Datagram datagram) {
    // A sender outside the policy is not heard at all: not parsed, not
    // de-duplicated, never probed.
    if (!provider.destinationPolicy.allows(datagram.host)) return;
    final message = SsdpMessage.tryParseBytes(datagram.data);
    if (message == null ||
        message.kind == SsdpMessageKind.search ||
        message.isByeBye) {
      return;
    }
    final key =
        message.usn ??
        '${datagram.host}|${message.serviceType}|${message.location}';
    if (!_seen.add(key)) return;
    late final Future<void> work;
    work = _enrich(datagram.host, message)
        .then((hit) {
          if (hit != null && !_out.isClosed && !_cancelled) _out.add(hit);
        })
        .whenComplete(() => _pending.remove(work));
    _pending.add(work);
  }

  Future<DiscoveryHit?> _enrich(String sender, SsdpMessage message) async {
    final policy = provider.destinationPolicy;
    final location = message.locationUri;
    final placement = ssdpPlacement(sender, location, policy: policy);
    if (placement == null) return null;
    if (!provider.fetchDescriptions ||
        location == null ||
        !placement.fetchable) {
      return ssdpHit(sender, message, policy: policy);
    }
    var pending = _descriptions[location];
    if (pending == null) {
      final bySender = _fetchesBySender[sender] ?? 0;
      if (_descriptions.length >= provider.maxDescriptionFetches ||
          bySender >= provider.maxDescriptionFetchesPerSender) {
        return ssdpHit(sender, message, policy: policy);
      }
      _fetchesBySender[sender] = bySender + 1;
      pending = _descriptions[location] = provider._fetch(location);
    }
    final fetched = await pending;
    return ssdpHit(
      sender,
      message,
      description: fetched?.description,
      applicationUrl: fetched?.applicationUrl,
      policy: policy,
    );
  }

  void _cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final s in _subscriptions) {
      unawaited(s.cancel());
    }
    for (final done in _queriesDone) {
      if (!done.isCompleted) done.complete();
    }
    unawaited(_out.close());
  }
}
