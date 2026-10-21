/// `dart:io` implementations of the watchme transports: the network stack
/// (HTTP, WebSocket, TCP, UDP with TLS pinning and trust-on-first-use), SSDP
/// and mDNS discovery, Wake-on-LAN, the ARP cache, a process runner, and
/// file-backed credential and device stores.
///
/// Native only: never import this from drivers or watchme_core.
///
/// Note: `dart:io` also declares a `Datagram`; code importing both this
/// library and `dart:io` should `hide Datagram` from `dart:io`.
library;

export 'src/arp_cache.dart';
export 'src/discovery/mdns_discovery.dart';
export 'src/discovery/ssdp_discovery.dart'
    show
        SsdpDiscovery,
        isDnsSdServiceType,
        isSsdpSearchTarget,
        ssdpHit,
        ssdpPlacement;
export 'src/discovery/ssdp_message.dart';
export 'src/discovery/ssdp_notify_listener.dart';
export 'src/discovery/upnp_description.dart';
export 'src/io_transports.dart';
export 'src/local_network.dart';
export 'src/network/io_network_stack.dart'
    show IoNetworkStack, isLanAddress, isPrivateLanAddress;
export 'src/process/io_process_runner.dart';
export 'src/store/file_stores.dart';
export 'src/store/json_file.dart' show StoreWarning;
export 'src/wake_on_lan.dart';
