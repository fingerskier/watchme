import 'dart:convert';
import 'dart:io' hide Datagram;

import 'package:path/path.dart' as p;
import 'package:watchme_core/watchme_core.dart';

/// Something a file store noticed and worked around, such as a corrupt file
/// it set aside.
final class StoreWarning {
  /// Creates a warning about [path].
  const StoreWarning(this.path, this.message, {this.backupPath, this.cause});

  /// The store file.
  final String path;

  /// What happened, in English.
  final String message;

  /// Where the unreadable original was copied, if anywhere.
  final String? backupPath;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() =>
      'StoreWarning($path: $message'
      '${backupPath == null ? '' : ', backup at $backupPath'})';
}

/// A JSON document `{"version": 1, "<key>": [ ... ]}` on disk, written
/// atomically (temp file, then rename) and, when [private], readable only
/// by its owner.
///
/// Privacy on Linux and macOS fails closed: before anything is written,
/// the containing directory is restricted to 0700 and the temporary file to
/// 0600 (with `/bin/chmod`, never a `chmod` found on `PATH`), and both modes
/// are read back. If either cannot be restricted, [save] throws a
/// [WatchmeError] and writes nothing. The directory comes first so that no
/// other user can open the temporary file in the moment before its own mode
/// is tightened. Other platforms keep app data in per-app storage and are
/// left alone.
///
/// Reading tolerates damage: an unparsable file or a malformed entry is
/// copied to `<file>.corrupt-<timestamp>`, a [StoreWarning] is reported,
/// and the store continues with whatever was valid.
final class JsonFile {
  /// Creates a handle on [path] holding a list under [key].
  JsonFile(
    this.path, {
    required this.key,
    required this.private,
    required this.clock,
    required this.warn,
  });

  /// The file.
  final String path;

  /// The top-level key of the entry list.
  final String key;

  /// Whether to restrict permissions to the owner.
  final bool private;

  /// Time source for backup names.
  final Clock clock;

  /// Receives warnings.
  final void Function(StoreWarning warning) warn;

  static const int _version = 1;
  var _tempCounter = 0;

  /// Where `chmod` is looked for, in order. Absolute paths only, so a
  /// manipulated `PATH` cannot substitute another program. Tests replace it
  /// to simulate a host without `chmod`.
  static List<String> chmodPaths = const ['/bin/chmod', '/usr/bin/chmod'];

  static bool get _posix => Platform.isLinux || Platform.isMacOS;

  // Group and other permission bits.
  static const int _groupOther = 0x3f;

  /// Reads the entries, decoding each with [decode]; entries [decode]
  /// rejects with a [FormatException] are dropped after backing up the file.
  Future<List<T>> load<T>(T Function(JsonMap json) decode) async {
    final file = File(path);
    if (!await file.exists()) return [];
    if (private) await _checkModes(file);
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException catch (e) {
      await _setAside(file, 'unreadable', e, move: true);
      return [];
    }
    final List<Object?> raw;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded[key] is! List) {
        throw FormatException('Expected an object with a "$key" list');
      }
      raw = decoded[key] as List<Object?>;
    } on FormatException catch (e) {
      await _setAside(file, 'not valid store JSON', e, move: true);
      return [];
    }
    final out = <T>[];
    FormatException? firstError;
    for (final item in raw) {
      try {
        if (item is! Map) throw const FormatException('Entry is not an object');
        out.add(decode(item.cast<String, Object?>()));
      } on FormatException catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) {
      await _setAside(
        file,
        '${raw.length - out.length} malformed entr'
        '${raw.length - out.length == 1 ? 'y' : 'ies'} skipped',
        firstError,
        move: false,
      );
    }
    return out;
  }

  /// Replaces the file's contents with [entries], atomically.
  ///
  /// Throws [WatchmeError] ([WatchmeErrorCode.internal]) when the store is
  /// [private] and its directory or file cannot be made owner-only.
  Future<void> save(List<JsonMap> entries) async {
    final file = File(path);
    final dir = file.parent;
    if (!await dir.exists()) await dir.create(recursive: true);
    // The directory first: once it is owner-only, nobody else can reach the
    // temporary file during the moment it has the default mode.
    if (private) await _restrict(dir.path, '700');
    final temp = File(
      p.join(dir.path, '.${p.basename(path)}.$pid.${_tempCounter++}.tmp'),
    );
    try {
      await temp.create(exclusive: true);
      // Restrict the empty file before any secret is written to it.
      if (private) await _restrict(temp.path, '600');
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ')
            .convert({'version': _version, key: entries}),
        flush: true,
      );
      await temp.rename(path);
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> _setAside(
    File file,
    String what,
    Object cause, {
    required bool move,
  }) async {
    final stamp = clock.now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    final backup = '$path.corrupt-$stamp';
    String? saved;
    try {
      if (move) {
        await file.rename(backup);
      } else {
        await file.copy(backup);
      }
      if (private) await _restrict(backup, '600');
      saved = backup;
    } on FileSystemException {
      saved = null;
    } on WatchmeError {
      // A copy of the secrets that cannot be made private is not kept.
      await _deleteQuietly(backup);
      saved = null;
    }
    warn(
      StoreWarning(
        path,
        move ? 'Store file was $what; starting empty' : 'Store file had $what',
        backupPath: saved,
        cause: cause,
      ),
    );
  }

  /// Tightens an existing store and its directory, warning about what was
  /// open. Reading goes ahead either way: the secrets are already on disk,
  /// and the next [save] refuses to write if they cannot be protected.
  Future<void> _checkModes(File file) async {
    if (!_posix) return;
    for (final (target, mode, what) in [
      (file.parent.path, '700', 'Store directory'),
      (path, '600', 'Store file'),
    ]) {
      final before = (await FileStat.stat(target)).mode;
      if (before & _groupOther == 0) continue;
      try {
        await _restrict(target, mode);
        warn(
          StoreWarning(
            path,
            '$what was readable by other users '
            '(mode ${(before & 0x1ff).toRadixString(8)}); restricted to $mode',
          ),
        );
      } on WatchmeError catch (e) {
        warn(StoreWarning(path, e.message, cause: e));
      }
    }
  }

  /// Sets [target]'s mode and checks that group and others lost access.
  /// dart:io has no chmod, so this runs the `chmod` binary by absolute path.
  /// Throws [WatchmeError] on Linux and macOS when that fails; a no-op
  /// elsewhere.
  Future<void> _restrict(String target, String mode) async {
    if (!_posix) return;
    final chmod = chmodPaths.where((c) => File(c).existsSync()).firstOrNull;
    if (chmod == null) {
      throw WatchmeError.internal(
        'Refusing to write $path: no chmod at ${chmodPaths.join(' or ')} to '
        'make $target private',
      );
    }
    final ProcessResult result;
    try {
      result = await Process.run(chmod, [mode, target]);
    } on ProcessException catch (e) {
      throw WatchmeError.internal(
        'Refusing to write $path: $chmod could not run',
        cause: e,
      );
    }
    if (result.exitCode != 0) {
      throw WatchmeError.internal(
        'Refusing to write $path: chmod $mode $target failed: '
                '${result.stderr}'
            .trim(),
      );
    }
    final actual = (await FileStat.stat(target)).mode;
    if (actual & _groupOther != 0) {
      throw WatchmeError.internal(
        'Refusing to write $path: $target is still accessible to other users '
        '(mode ${(actual & 0x1ff).toRadixString(8)})',
      );
    }
  }

  static Future<void> _deleteQuietly(String target) async {
    try {
      await File(target).delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
