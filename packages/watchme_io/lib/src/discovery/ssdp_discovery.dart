import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:watchme_core/watchme_core.dart';

import '../network/io_network_stack.dart' show isPrivateLanAddress;
import 'ssdp_message.dart';
import 'upnp_description.dart';

/// SSDP discovery (provider id `ssdp`): M-SEARCH for UPnP devices, Roku
/// ECP and DIAL servers.
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
/// * A reply's `LOCATION` is used as the device address, and fetched, only
///   when it names the replying host or a private or link-local address
///   ([isPrivateLanAddress]), so a spoofed reply cannot make watchme contact
///   a host on the internet, this host's own loopback services, or the
///   shared (CGNAT/VPN) range. Loopback is accepted only from a loopback
///   sender (local simulators).
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
  });

  /// Searched when a scan names no service types: everything, plus Roku and
  /// DIAL explicitly because some devices answer only their own target.
  static const List<String> defaultSearchTargets = [
    'ssdp:all',
    'roku:ecp',
    'urn:dial-multiscreen-org:service:dial:1',
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
/// the reply's [location]: the `LOCATION` host and port when it is an IP
/// literal that is the sender itself, a private or link-local address
/// ([isPrivateLanAddress]), or loopback named by a loopback sender; else
/// the sender with no port. [fetchable] says the location may be fetched.
({String host, int? port, bool fetchable}) ssdpPlacement(
  String sender,
  Uri? location,
) {
  final address = location == null
      ? null
      : InternetAddress.tryParse(location.host);
  if (address == null) return (host: sender, port: null, fetchable: false);
  final senderIsLoopback =
      InternetAddress.tryParse(sender)?.isLoopback ?? false;
  final trusted =
      address.address == sender ||
      isPrivateLanAddress(address) ||
      (address.isLoopback && senderIsLoopback);
  return trusted
      ? (host: address.address, port: location!.port, fetchable: true)
      : (host: sender, port: null, fetchable: false);
}

/// The hit for an SSDP [message] from [sender], enriched with [description]
/// and [applicationUrl] when they were fetched.
DiscoveryHit ssdpHit(
  String sender,
  SsdpMessage message, {
  UpnpDescription? description,
  String? applicationUrl,
}) {
  final placement = ssdpPlacement(sender, message.locationUri);
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
          if (!_out.isClosed && !_cancelled) _out.add(hit);
        })
        .whenComplete(() => _pending.remove(work));
    _pending.add(work);
  }

  Future<DiscoveryHit> _enrich(String sender, SsdpMessage message) async {
    final location = message.locationUri;
    if (!provider.fetchDescriptions ||
        location == null ||
        !ssdpPlacement(sender, location).fetchable) {
      return ssdpHit(sender, message);
    }
    var pending = _descriptions[location];
    if (pending == null) {
      final bySender = _fetchesBySender[sender] ?? 0;
      if (_descriptions.length >= provider.maxDescriptionFetches ||
          bySender >= provider.maxDescriptionFetchesPerSender) {
        return ssdpHit(sender, message);
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
