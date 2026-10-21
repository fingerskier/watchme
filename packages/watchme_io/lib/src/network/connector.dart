import 'dart:async';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart';

import 'destinations.dart';
import 'tls_support.dart';

/// Progress of one connection attempt, shared between the code that opens
/// the socket and the caller's deadline handling.
final class ConnectAttempt {
  ConnectionTask<Socket>? _task;
  Socket? _socket;

  /// Whether the TCP connection was established (the peer answered).
  bool connected = false;

  /// Whether the TLS handshake finished (only set for TLS connections).
  bool secured = false;

  /// Whether the attempt was abandoned.
  bool cancelled = false;

  /// The peer's leaf fingerprint once TLS is up.
  String? peerSha256;

  /// The peer's DER leaf certificate once TLS is up.
  Uint8List? peerDer;

  /// Abandons the attempt: cancels a pending connect and destroys any socket.
  void cancel() {
    cancelled = true;
    _task?.cancel();
    _socket?.destroy();
  }

  /// The error for a deadline that expired during this attempt.
  WatchmeError expired(String target, Duration limit) => connected
      ? WatchmeError.timeout(
          'No answer from $target within ${limit.inMilliseconds} ms',
        )
      : WatchmeError.unreachable(
          'No answer to connect from $target within '
          '${limit.inMilliseconds} ms',
        );
}

/// Opens TCP connections, optionally wrapped in TLS under a [TlsPolicy], to
/// destinations its [DestinationResolver] allows.
///
/// The host is resolved and every address checked before any packet is
/// sent; the socket is then opened to a checked `InternetAddress` (trying
/// them in the resolver's order until one answers), never to the host text,
/// so the OS cannot resolve the name a second time. TLS still verifies the
/// certificate against, and sends as SNI, the host as the caller named it.
///
/// Deadlines are applied by the caller (see `runWithin`), which calls
/// [ConnectAttempt.cancel] on expiry; every await here re-checks
/// cancellation so a late socket is destroyed rather than leaked.
final class Connector {
  /// Creates a connector using [contexts] for TLS and [destinations] to
  /// resolve and check hosts.
  Connector(this.contexts, this.destinations);

  /// TLS contexts by client identity.
  final SecurityContexts contexts;

  /// Resolves hosts and enforces the destination policy.
  final DestinationResolver destinations;

  /// Connects to [host]:[port], recording progress in [attempt].
  ///
  /// [host] is a host name or an IP literal (brackets allowed, an IPv6 zone
  /// id raw rather than percent-encoded).
  Future<Socket> connect(
    String host,
    int port, {
    required ConnectAttempt attempt,
    TlsPolicy? tls,
    ClientIdentity? identity,
  }) async {
    final context = tls == null ? null : contexts.forIdentity(identity);
    final addresses = await destinations.resolve(host);
    final socket = await _open(addresses, port, attempt);
    attempt.connected = true;
    // Remotes send many tiny frames (key presses); Nagle would delay them.
    socket.setOption(SocketOption.tcpNoDelay, true);
    if (tls == null) return socket;
    final secured = await secureSocket(
      socket,
      host: tlsServerName(host),
      port: port,
      policy: tls,
      context: context!,
    );
    attempt._socket = secured.socket;
    if (attempt.cancelled) {
      secured.socket.destroy();
      throw const WatchmeError.cancelled('Connection attempt abandoned');
    }
    attempt
      ..secured = true
      ..peerSha256 = secured.peerSha256
      ..peerDer = secured.peerDer;
    return secured.socket;
  }

  /// A socket to the first of [addresses] that accepts, in order.
  static Future<Socket> _open(
    List<InternetAddress> addresses,
    int port,
    ConnectAttempt attempt,
  ) async {
    Object? lastError;
    for (final address in addresses) {
      if (attempt.cancelled) break;
      try {
        final task = await Socket.startConnect(address, port);
        if (attempt.cancelled) {
          task.cancel();
          break;
        }
        attempt._task = task;
        final socket = await task.socket;
        attempt._socket = socket;
        if (attempt.cancelled) {
          socket.destroy();
          break;
        }
        return socket;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    if (attempt.cancelled || lastError == null) {
      throw const WatchmeError.cancelled('Connection attempt abandoned');
    }
    throw lastError;
  }
}
