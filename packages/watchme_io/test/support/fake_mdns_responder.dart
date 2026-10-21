import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

/// A DNS-SD service the fake responder announces.
final class FakeMdnsService {
  const FakeMdnsService({
    required this.type,
    required this.instance,
    required this.target,
    required this.port,
    this.ipv4,
    this.txt = const [],
  });

  /// e.g. `_amzn-wplay._tcp`.
  final String type;

  /// Instance label, e.g. `Den Fire TV`.
  final String instance;

  /// SRV target host name, e.g. `fire-tv-abc.local`.
  final String target;
  final int port;
  final String? ipv4;

  /// TXT strings, e.g. `['n=Den', 'amzn.dmgr=x']`.
  final List<String> txt;

  String get fqdn => '$instance.$type.local';
}

/// A minimal mDNS responder for loopback tests. It joins [group] on the
/// loopback interface only and answers with multicast that has TTL 0, so
/// nothing reaches a real network.
final class FakeMdnsResponder {
  FakeMdnsResponder._(this.socket, this.group, this.services, this.additionals);

  /// Binds a free port (shared through address reuse with the client).
  static Future<FakeMdnsResponder?> start({
    required InternetAddress group,
    required NetworkInterface loopback,
    required List<FakeMdnsService> services,
    bool additionals = true,
  }) async {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
    try {
      socket.joinMulticast(group, loopback);
    } on SocketException {
      socket.close();
      return null;
    }
    confineToLoopback(socket);
    final responder = FakeMdnsResponder._(socket, group, services, additionals);
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = socket.receive(); d != null; d = socket.receive()) {
        responder._handle(d.data);
      }
    });
    return responder;
  }

  final RawDatagramSocket socket;
  final InternetAddress group;
  final List<FakeMdnsService> services;
  final bool additionals;

  /// Questions received, as `TYPE name`.
  final List<String> questions = [];

  int get port => socket.port;

  void close() => socket.close();

  void _handle(Uint8List packet) {
    if (packet.length < 12) return;
    final data = ByteData.sublistView(packet);
    if (data.getUint16(2) & 0x8000 != 0) return; // a response, maybe ours
    final count = data.getUint16(4);
    var offset = 12;
    for (var i = 0; i < count; i++) {
      final (name, next) = _readName(packet, offset);
      final type = data.getUint16(next);
      offset = next + 4;
      questions.add('$type $name');
      _answer(name.toLowerCase(), type);
    }
  }

  void _answer(String name, int type) {
    final answers = <List<int>>[];
    final extra = <List<int>>[];
    for (final s in services) {
      if (type == _ptr && name == '${s.type}.local'.toLowerCase()) {
        answers.add(_record('${s.type}.local', _ptr, _name(s.fqdn)));
        if (additionals) extra.addAll(_detail(s));
      } else if (name == s.fqdn.toLowerCase() && type == _srv) {
        answers.add(_srvRecord(s));
      } else if (name == s.fqdn.toLowerCase() && type == _txt) {
        answers.add(_txtRecord(s));
      } else if (name == s.target.toLowerCase() &&
          type == _a &&
          s.ipv4 != null) {
        answers.add(_aRecord(s));
      }
    }
    if (answers.isEmpty) return;
    final header = ByteData(12)
      ..setUint16(2, 0x8400)
      ..setUint16(6, answers.length)
      ..setUint16(10, extra.length);
    final bytes = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add([for (final r in answers) ...r])
      ..add([for (final r in extra) ...r]);
    socket.send(bytes.takeBytes(), group, port);
  }

  List<List<int>> _detail(FakeMdnsService s) => [
    _srvRecord(s),
    _txtRecord(s),
    if (s.ipv4 != null) _aRecord(s),
  ];

  List<int> _srvRecord(FakeMdnsService s) {
    final rdata = ByteData(6)..setUint16(4, s.port);
    return _record(s.fqdn, _srv, [
      ...rdata.buffer.asUint8List(),
      ..._name(s.target),
    ], unique: true);
  }

  List<int> _txtRecord(FakeMdnsService s) => _record(s.fqdn, _txt, [
    for (final entry in s.txt) ...[
      utf8.encode(entry).length,
      ...utf8.encode(entry),
    ],
  ], unique: true);

  List<int> _aRecord(FakeMdnsService s) =>
      _record(s.target, _a, InternetAddress(s.ipv4!).rawAddress, unique: true);

  static const _a = 1;
  static const _ptr = 12;
  static const _txt = 16;
  static const _srv = 33;

  static List<int> _record(
    String name,
    int type,
    List<int> rdata, {
    bool unique = false,
  }) {
    final fixed = ByteData(10)
      ..setUint16(0, type)
      ..setUint16(2, unique ? 0x8001 : 0x0001)
      ..setUint32(4, 120)
      ..setUint16(8, rdata.length);
    return [..._name(name), ...fixed.buffer.asUint8List(), ...rdata];
  }

  // Splits on the first labels the way DNS-SD does: everything before the
  // service type is one instance label, even with dots or spaces.
  static List<int> _name(String name) {
    final labels = <String>[];
    final serviceAt = RegExp(r'\._[^.]+\._(tcp|udp)\.').firstMatch(name);
    var rest = name;
    if (serviceAt != null && serviceAt.start > 0) {
      labels.add(name.substring(0, serviceAt.start));
      rest = name.substring(serviceAt.start + 1);
    }
    labels.addAll(rest.split('.').where((l) => l.isNotEmpty));
    return [
      for (final label in labels) ...[
        utf8.encode(label).length,
        ...utf8.encode(label),
      ],
      0,
    ];
  }

  static (String, int) _readName(Uint8List packet, int offset) {
    final labels = <String>[];
    while (packet[offset] != 0) {
      final length = packet[offset];
      labels.add(utf8.decode(packet.sublist(offset + 1, offset + 1 + length)));
      offset += 1 + length;
    }
    return (labels.join('.'), offset + 1);
  }
}

/// Makes [socket]'s multicast leave only through loopback, with TTL 0.
void confineToLoopback(RawDatagramSocket socket) {
  socket
    ..multicastHops = 0
    ..setRawOption(
      RawSocketOption(
        RawSocketOption.levelIPv4,
        RawSocketOption.IPv4MulticastInterface,
        Uint8List.fromList(InternetAddress.loopbackIPv4.rawAddress),
      ),
    );
}

/// A `RawDatagramSocketFactory` for `MDnsClient` whose sockets are
/// [confineToLoopback]ed.
Future<RawDatagramSocket> loopbackSocketFactory(
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = false,
  int ttl = 1,
}) async {
  final socket = await RawDatagramSocket.bind(
    host,
    port,
    reuseAddress: reuseAddress,
    reusePort: reusePort,
  );
  confineToLoopback(socket);
  return socket;
}
