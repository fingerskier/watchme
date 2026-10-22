import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A [RawDatagramSocket] that hides every datagram whose sender [accept]
/// rejects: [receive] skips them, so the code reading the socket never sees
/// their contents.
///
/// Everything else is delegated to the wrapped socket.
final class SenderFilteredSocket extends Stream<RawSocketEvent>
    implements RawDatagramSocket {
  /// Wraps [socket], delivering only datagrams whose sender [accept]s.
  SenderFilteredSocket(this._socket, this._accept);

  final RawDatagramSocket _socket;
  final bool Function(InternetAddress sender) _accept;

  @override
  Datagram? receive() {
    for (var d = _socket.receive(); d != null; d = _socket.receive()) {
      if (_accept(d.address)) return d;
    }
    return null;
  }

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _socket.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  InternetAddress get address => _socket.address;

  @override
  int get port => _socket.port;

  @override
  bool get readEventsEnabled => _socket.readEventsEnabled;

  @override
  set readEventsEnabled(bool value) => _socket.readEventsEnabled = value;

  @override
  bool get writeEventsEnabled => _socket.writeEventsEnabled;

  @override
  set writeEventsEnabled(bool value) => _socket.writeEventsEnabled = value;

  @override
  bool get multicastLoopback => _socket.multicastLoopback;

  @override
  set multicastLoopback(bool value) => _socket.multicastLoopback = value;

  @override
  int get multicastHops => _socket.multicastHops;

  @override
  set multicastHops(int value) => _socket.multicastHops = value;

  /// Not implemented by `dart:io` either; kept only to satisfy the
  /// interface.
  @override
  NetworkInterface? multicastInterface;

  @override
  bool get broadcastEnabled => _socket.broadcastEnabled;

  @override
  set broadcastEnabled(bool value) => _socket.broadcastEnabled = value;

  @override
  void close() => _socket.close();

  @override
  int send(List<int> buffer, InternetAddress address, int port) =>
      _socket.send(buffer, address, port);

  @override
  void joinMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      _socket.joinMulticast(group, interface);

  @override
  void leaveMulticast(InternetAddress group, [NetworkInterface? interface]) =>
      _socket.leaveMulticast(group, interface);

  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
}
