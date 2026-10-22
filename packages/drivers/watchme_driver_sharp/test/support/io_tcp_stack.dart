import 'dart:async';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart';

/// Test-only plain TCP over `dart:io`, so the driver can be exercised
/// against the loopback Sharp simulator. It follows the `NetworkStack`
/// error contract (a failed connect is unreachable; once connected, a
/// failure is a timeout, because a request may have been delivered) but
/// is not the production stack, which lives in watchme_io. Everything
/// except [tcp] is unsupported.
class IoTcpOnlyStack implements NetworkStack {
  /// Every connection opened, in order.
  final List<String> connects = [];

  @override
  Future<ByteSocket> tcp(
    String host,
    int port, {
    TlsPolicy? tls,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) async {
    if (tls != null) {
      throw const WatchmeError.unsupported('test stack: plain TCP only');
    }
    connects.add('$host:$port');
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      return _IoTcpSocket(socket, '$host:$port');
    } on SocketException catch (e) {
      throw WatchmeError.unreachable('Cannot reach $host:$port', cause: e);
    }
  }

  @override
  Future<HttpResult> http(
    HttpCall call, {
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
  }) => throw const WatchmeError.unsupported('test stack: TCP only');

  @override
  Future<MessageSocket> webSocket(
    Uri uri, {
    List<String> protocols = const [],
    Map<String, String> headers = const {},
    TlsPolicy tls = TlsPolicy.platform,
    ClientIdentity? identity,
    Duration timeout = HttpCall.defaultTimeout,
  }) => throw const WatchmeError.unsupported('test stack: TCP only');

  @override
  Future<void> sendDatagram(
    String host,
    int port,
    List<int> bytes, {
    bool broadcast = false,
  }) => throw const WatchmeError.unsupported('test stack: TCP only');

  @override
  Stream<Datagram> multicastQuery(
    String group,
    int port,
    List<int> query,
    Duration window,
  ) => throw const WatchmeError.unsupported('test stack: TCP only');
}

final class _IoTcpSocket implements ByteSocket {
  _IoTcpSocket(this._socket, this._target) {
    _socket.done.then((_) => _markDone(), onError: (Object _) => _markDone());
  }

  final Socket _socket;
  final String _target;
  final Completer<void> _done = Completer();
  bool _closed = false;

  @override
  late final Stream<Uint8List> input = _socket.transform(
    StreamTransformer<Uint8List, Uint8List>.fromHandlers(
      handleError: (error, stack, sink) => sink.addError(
        WatchmeError.timeout('Connection to $_target lost', cause: error),
        stack,
      ),
      handleDone: (sink) {
        _markDone();
        sink.close();
      },
    ),
  );

  void _markDone() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void send(List<int> bytes) {
    if (_closed) throw StateError('Socket is closed');
    _socket.add(bytes);
  }

  @override
  Future<void> flush() async {
    try {
      await _socket.flush();
    } on Object catch (e) {
      throw WatchmeError.timeout('Connection to $_target lost', cause: e);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.flush().timeout(const Duration(seconds: 1));
    } on Object {
      // Undeliverable bytes are dropped on close.
    }
    _socket.destroy();
    _markDone();
  }

  @override
  Future<void> get done => _done.future;

  @override
  String? get peerCertificateSha256 => null;

  @override
  Uint8List? get peerCertificateDer => null;
}

/// A [Transports] bundle around [IoTcpOnlyStack].
class IoTcpTransports implements Transports {
  @override
  final IoTcpOnlyStack network = IoTcpOnlyStack();

  @override
  Set<TransportFeature> get features => const {TransportFeature.rawTcp};

  @override
  SerialPortProvider? get serial => null;

  @override
  BleCentral? get ble => null;

  @override
  HidPeripheral? get hid => null;

  @override
  IrEmitter? get ir => null;

  @override
  ProcessRunner? get process => null;
}
