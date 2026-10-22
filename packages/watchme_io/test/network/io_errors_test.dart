import 'dart:async';
import 'dart:io' hide Datagram;

import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/src/network/io_errors.dart';

void main() {
  group('ioError', () {
    test('a socket failure before connecting is unreachable', () {
      final e = ioError(
        const SocketException('Connection refused'),
        '192.0.2.1:8080',
        connected: false,
      );
      expect(e.code, WatchmeErrorCode.unreachable);
    });

    test('a socket failure after connecting is a timeout, not unreachable', () {
      // The request may already have reached the device, so callers must
      // not treat it as "nothing was delivered" and repeat it.
      final e = ioError(
        const SocketException('Connection reset by peer'),
        '192.0.2.1:8080',
        connected: true,
      );
      expect(e.code, WatchmeErrorCode.timeout);
      expect(e.message, contains('lost'));
    });

    test('a timeout maps by connection state', () {
      expect(
        ioError(TimeoutException('x'), 't', connected: false).code,
        WatchmeErrorCode.unreachable,
      );
      expect(
        ioError(TimeoutException('x'), 't', connected: true).code,
        WatchmeErrorCode.timeout,
      );
    });
  });
}
