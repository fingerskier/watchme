import 'dart:async';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:watchme_core/watchme_core.dart';

import 'io_errors.dart';

/// [MessageSocket] over a `dart:io` [WebSocket].
final class IoMessageSocket implements MessageSocket {
  /// Wraps [socket], which talks to [target] (for error messages).
  IoMessageSocket(
    this._socket, {
    required this.target,
    this.protocol,
    this.peerCertificateSha256,
  }) {
    _socket.done.then((_) => _markDone(), onError: (Object _) => _markDone());
  }

  final WebSocket _socket;
  final Completer<void> _done = Completer();
  int? _sentCode;
  String? _sentReason;

  /// The peer, for error messages.
  final String target;

  @override
  final String? protocol;

  @override
  final String? peerCertificateSha256;

  @override
  late final Stream<Object> messages = _socket.transform(
    StreamTransformer<dynamic, Object>.fromHandlers(
      handleData: (data, sink) {
        switch (data) {
          case final String text:
            sink.add(text);
          case final Uint8List bytes:
            sink.add(bytes);
          case final List<int> bytes:
            sink.add(Uint8List.fromList(bytes));
        }
      },
      handleError: (error, stack, sink) =>
          sink.addError(ioError(error, target, connected: true), stack),
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
  void send(Object message) {
    switch (message) {
      case final String text:
        _socket.add(text);
      case final Uint8List bytes:
        _socket.add(bytes);
      case final List<int> bytes:
        _socket.add(Uint8List.fromList(bytes));
      default:
        throw ArgumentError.value(message, 'message', 'String or List<int>');
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    _sentCode ??= code;
    _sentReason ??= reason;
    try {
      await _socket.close(code, reason);
    } on Object {
      // Closing an already broken socket is not an error for the caller.
    }
    _markDone();
  }

  @override
  Future<void> get done => _done.future;

  @override
  int? get closeCode => _socket.closeCode ?? _sentCode;

  @override
  String? get closeReason => _socket.closeReason ?? _sentReason;
}

/// [ByteSocket] over a `dart:io` [Socket] (plain or TLS).
final class IoByteSocket implements ByteSocket {
  /// Wraps [socket], connected to [target] (for error messages).
  IoByteSocket(
    this._socket, {
    required this.target,
    this.peerCertificateSha256,
    this.peerCertificateDer,
  }) {
    _socket.done.then((_) => _markDone(), onError: (Object _) => _markDone());
  }

  final Socket _socket;
  final Completer<void> _done = Completer();
  bool _closed = false;

  /// The peer, for error messages.
  final String target;

  @override
  final String? peerCertificateSha256;

  @override
  final Uint8List? peerCertificateDer;

  @override
  late final Stream<Uint8List> input = _socket.transform(
    StreamTransformer<Uint8List, Uint8List>.fromHandlers(
      handleError: (error, stack, sink) =>
          sink.addError(ioError(error, target, connected: true), stack),
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
      throw ioError(e, target, connected: true);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _socket.flush().timeout(const Duration(seconds: 2));
    } on Object {
      // Undeliverable bytes are dropped on close.
    }
    _socket.destroy();
    _markDone();
  }

  @override
  Future<void> get done => _done.future;
}
