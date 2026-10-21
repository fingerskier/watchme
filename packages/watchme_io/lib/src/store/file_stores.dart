import 'dart:io' hide Datagram;

import 'package:path/path.dart' as p;
import 'package:watchme_core/watchme_core.dart';

import 'json_file.dart';

/// Runs file operations one at a time, over an in-memory copy loaded on
/// first use. Single-process: two processes sharing a file overwrite each
/// other's changes.
abstract base class _FileStore<K, V> {
  _FileStore(
    String path, {
    required String key,
    required bool private,
    required Clock clock,
    void Function(StoreWarning warning)? onWarning,
  }) {
    _file = JsonFile(
      path,
      key: key,
      private: private,
      clock: clock,
      warn: (w) {
        _warnings.add(w);
        onWarning?.call(w);
      },
    );
  }

  late final JsonFile _file;
  final List<StoreWarning> _warnings = [];
  Map<K, V>? _items;
  Future<void> _tail = Future.value();

  /// The store file.
  String get path => _file.path;

  /// Problems noticed so far (corrupt file set aside, loose permissions).
  List<StoreWarning> get warnings => List.unmodifiable(_warnings);

  K keyOf(V value);
  V decode(JsonMap json);
  JsonMap encode(V value);
  int compare(V a, V b);

  Future<T> _serial<T>(Future<T> Function(Map<K, V> items) op) {
    final result = _tail.then((_) async {
      final items = _items ??= {
        for (final v in await _file.load(decode)) keyOf(v): v,
      };
      return op(items);
    });
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _replace(
    Map<K, V> items,
    void Function(Map<K, V> next) change,
  ) async {
    final next = Map.of(items);
    change(next);
    final values = next.values.toList()..sort(compare);
    try {
      await _file.save([for (final v in values) encode(v)]);
    } on FileSystemException catch (e) {
      throw WatchmeError.internal(
        'Cannot write ${_file.path}: ${e.message}',
        cause: e,
      );
    }
    items
      ..clear()
      ..addAll(next);
  }
}

/// A [CredentialStore] in a JSON file, readable only by its owner.
///
/// Writes are atomic (temp file, then rename) and the file and any backup
/// are kept at mode 0600 on Linux and macOS; a looser file found on disk is
/// tightened with a warning. A corrupt file is set aside as
/// `<file>.corrupt-<timestamp>` and the store starts empty, reporting a
/// [StoreWarning] through `onWarning` and [warnings]. Secrets are stored in
/// plain JSON: the protection is the file mode (see the architecture
/// overview, section 7).
final class FileCredentialStore extends _FileStore<(String, String), Credential>
    implements CredentialStore {
  /// Creates a store backed by [path] (created on first write).
  FileCredentialStore(
    super.path, {
    super.onWarning,
    super.clock = const SystemClock(),
  }) : super(key: 'credentials', private: true);

  /// A store at `credentials.json` under [WatchmeDirectories.state].
  factory FileCredentialStore.standard({
    void Function(StoreWarning warning)? onWarning,
  }) => FileCredentialStore(
    p.join(WatchmeDirectories.state(), 'credentials.json'),
    onWarning: onWarning,
  );

  @override
  (String, String) keyOf(Credential value) => (value.deviceId, value.driverId);

  @override
  Credential decode(JsonMap json) => Credential.fromJson(json);

  @override
  JsonMap encode(Credential value) => value.toJson();

  @override
  int compare(Credential a, Credential b) {
    final byDevice = a.deviceId.compareTo(b.deviceId);
    return byDevice != 0 ? byDevice : a.driverId.compareTo(b.driverId);
  }

  @override
  Future<Credential?> read(String deviceId, String driverId) =>
      _serial((items) async => items[(deviceId, driverId)]);

  @override
  Future<List<Credential>> readAll(String deviceId) => _serial(
    (items) async => [
      for (final c in items.values)
        if (c.deviceId == deviceId) c,
    ]..sort(compare),
  );

  @override
  Future<void> write(Credential credential) => _serial(
    (items) => _replace(items, (next) => next[keyOf(credential)] = credential),
  );

  @override
  Future<void> delete(String deviceId, {String? driverId}) => _serial((items) {
    bool matches((String, String) key) =>
        key.$1 == deviceId && (driverId == null || key.$2 == driverId);
    if (!items.keys.any(matches)) return Future.value();
    return _replace(
      items,
      (next) => next.removeWhere((key, _) => matches(key)),
    );
  });
}

/// A [DeviceRepository] in a JSON file, with the same atomic writes and
/// corruption handling as [FileCredentialStore]. The file is private
/// (0600) by default because it lists the household's devices and MACs.
final class FileDeviceRepository extends _FileStore<String, DeviceRecord>
    implements DeviceRepository {
  /// Creates a repository backed by [path] (created on first write).
  FileDeviceRepository(
    super.path, {
    super.onWarning,
    super.clock = const SystemClock(),
    super.private = true,
  }) : super(key: 'devices');

  /// A repository at `devices.json` under [WatchmeDirectories.state].
  factory FileDeviceRepository.standard({
    void Function(StoreWarning warning)? onWarning,
  }) => FileDeviceRepository(
    p.join(WatchmeDirectories.state(), 'devices.json'),
    onWarning: onWarning,
  );

  @override
  String keyOf(DeviceRecord value) => value.id;

  @override
  DeviceRecord decode(JsonMap json) => DeviceRecord.fromJson(json);

  @override
  JsonMap encode(DeviceRecord value) => value.toJson();

  @override
  int compare(DeviceRecord a, DeviceRecord b) => a.id.compareTo(b.id);

  @override
  Future<List<DeviceRecord>> all() =>
      _serial((items) async => items.values.toList()..sort(compare));

  @override
  Future<DeviceRecord?> get(String id) => _serial((items) async => items[id]);

  @override
  Future<void> put(DeviceRecord record) =>
      _serial((items) => _replace(items, (next) => next[record.id] = record));

  @override
  Future<void> remove(String id) => _serial(
    (items) => items.containsKey(id)
        ? _replace(items, (next) => next.remove(id))
        : Future.value(),
  );
}

/// Where watchme keeps its state on this host.
abstract final class WatchmeDirectories {
  /// The per-user state directory:
  /// * Linux: `$XDG_STATE_HOME/watchme`, else `~/.local/state/watchme`;
  /// * macOS: `~/Library/Application Support/watchme`;
  /// * Windows: `%LOCALAPPDATA%\watchme` (or `%APPDATA%`).
  ///
  /// Throws [WatchmeError] (unsupported) on mobile, where the app supplies
  /// a directory from the platform (path_provider), and when no home
  /// directory is known.
  static String state({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    String need(String? value, String what) => value == null || value.isEmpty
        ? throw WatchmeError.unsupported('$what is not set')
        : value;
    if (Platform.isWindows) {
      return p.join(
        need(env['LOCALAPPDATA'] ?? env['APPDATA'], 'LOCALAPPDATA'),
        'watchme',
      );
    }
    if (Platform.isMacOS) {
      return p.join(
        need(env['HOME'], 'HOME'),
        'Library',
        'Application Support',
        'watchme',
      );
    }
    if (Platform.isLinux) {
      final xdg = env['XDG_STATE_HOME'];
      if (xdg != null && p.isAbsolute(xdg)) return p.join(xdg, 'watchme');
      return p.join(need(env['HOME'], 'HOME'), '.local', 'state', 'watchme');
    }
    throw const WatchmeError.unsupported(
      'No default state directory on this platform; pass a path',
    );
  }
}
