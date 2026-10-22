import 'dart:convert';
import 'dart:io' hide Datagram;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watchme_core/watchme_core.dart';
import 'package:watchme_io/src/store/json_file.dart' show JsonFile;
import 'package:watchme_io/watchme_io.dart';
import 'package:watchme_testkit/watchme_testkit.dart';

final created = DateTime.utc(2026, 10, 21, 12);

TokenCredential token(
  String device, {
  String driver = 'firetv.lightning',
  String value = 'tok',
}) => TokenCredential(
  driverId: driver,
  deviceId: device,
  createdAt: created,
  token: value,
  peerCertSha256: fakeFingerprint('tv'),
  attributes: const {'friendlyName': 'watchme'},
);

final List<Credential> everyKind = [
  token('dev-1'),
  ClientCertCredential(
    driverId: 'androidtv.remote2',
    deviceId: 'dev-1',
    createdAt: created,
    certificatePem:
        '-----BEGIN CERTIFICATE-----\nAA==\n-----END CERTIFICATE-----\n',
    privateKeyPem:
        '-----BEGIN PRIVATE KEY-----\nAA==\n-----END PRIVATE KEY-----\n',
  ),
  KeyPairCredential(
    driverId: 'appletv.companion',
    deviceId: 'dev-2',
    createdAt: created,
    algorithm: 'ed25519',
    publicKey: Uint8List.fromList([1, 2, 3]),
    privateKey: Uint8List.fromList([4, 5, 6]),
  ),
  SharedSecretCredential(
    driverId: 'sony.rest',
    deviceId: 'dev-3',
    createdAt: created,
    secret: '0000',
    expiresAt: DateTime.utc(2027),
  ),
];

int modeOf(String path) => File(path).statSync().mode & 0x1ff;

/// Writes a hand-made store file with the mode the store itself uses, so
/// only the damage under test produces a warning.
void writeRaw(String path, String text) {
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(text);
  if (!Platform.isWindows) {
    Process.runSync('chmod', ['700', p.dirname(path)]);
    Process.runSync('chmod', ['600', path]);
  }
}

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('watchme_store');
    path = p.join(dir.path, 'state', 'credentials.json');
  });
  tearDown(() => dir.delete(recursive: true));

  group('FileCredentialStore', () {
    test(
      'round-trips every credential kind through a fresh instance',
      () async {
        final store = FileCredentialStore(path);
        for (final c in everyKind) {
          await store.write(c);
        }
        final reopened = FileCredentialStore(path);
        for (final c in everyKind) {
          expect(await reopened.read(c.deviceId, c.driverId), c);
        }
        expect(await reopened.readAll('dev-1'), hasLength(2));
        expect(await reopened.read('dev-1', 'nope'), isNull);
        expect(reopened.warnings, isEmpty);
        final json =
            jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
        expect(json['version'], 1);
        expect(json['credentials'], hasLength(4));
      },
    );

    test('replaces and deletes', () async {
      final store = FileCredentialStore(path);
      await store.write(token('dev-1'));
      await store.write(token('dev-1', value: 'new'));
      await store.write(token('dev-1', driver: 'roku.ecp'));
      await store.write(token('dev-2'));
      expect(
        ((await store.read('dev-1', 'firetv.lightning'))! as TokenCredential)
            .token,
        'new',
      );

      await store.delete('dev-1', driverId: 'roku.ecp');
      expect(await FileCredentialStore(path).readAll('dev-1'), hasLength(1));
      await store.delete('dev-1');
      final reopened = FileCredentialStore(path);
      expect(await reopened.readAll('dev-1'), isEmpty);
      expect(await reopened.readAll('dev-2'), hasLength(1));
      await store.delete('unknown');
    });

    test('keeps the file and its directory private', () async {
      await FileCredentialStore(path).write(token('dev-1'));
      expect(modeOf(path), 0x180, reason: 'file mode 0600');
      expect(modeOf(p.dirname(path)), 0x1c0, reason: 'directory mode 0700');
    }, testOn: 'linux || mac-os');

    test('tightens a file other users can read', () async {
      await FileCredentialStore(path).write(token('dev-1'));
      await Process.run('chmod', ['644', path]);
      final warnings = <StoreWarning>[];
      final store = FileCredentialStore(path, onWarning: warnings.add);
      expect(await store.read('dev-1', 'firetv.lightning'), isNotNull);
      expect(modeOf(path), 0x180);
      expect(warnings.single.message, contains('readable by other users'));
    }, testOn: 'linux || mac-os');

    test('restricts a directory that already existed', () async {
      // path_provider creates the app's directory with the default mode.
      final existing = Directory(p.dirname(path))..createSync(recursive: true);
      await Process.run('chmod', ['755', existing.path]);
      await FileCredentialStore(path).write(token('dev-1'));
      expect(modeOf(existing.path), 0x1c0, reason: 'directory mode 0700');
      expect(modeOf(path), 0x180, reason: 'file mode 0600');
    }, testOn: 'linux || mac-os');

    test('tightens an open directory when loading', () async {
      await FileCredentialStore(path).write(token('dev-1'));
      await Process.run('chmod', ['755', p.dirname(path)]);
      final warnings = <StoreWarning>[];
      final store = FileCredentialStore(path, onWarning: warnings.add);
      expect(await store.read('dev-1', 'firetv.lightning'), isNotNull);
      expect(modeOf(p.dirname(path)), 0x1c0);
      expect(warnings.single.message, contains('directory'));
    }, testOn: 'linux || mac-os');

    test('refuses to write secrets when chmod is unavailable', () async {
      final saved = JsonFile.chmodPaths;
      JsonFile.chmodPaths = [p.join(dir.path, 'no-such-chmod')];
      addTearDown(() => JsonFile.chmodPaths = saved);
      final store = FileCredentialStore(path);
      await expectLater(
        store.write(token('dev-1')),
        throwsWatchmeError(WatchmeErrorCode.internal),
      );
      expect(File(path).existsSync(), isFalse);
      // No temporary file holding the token was left behind either.
      final leftovers = Directory(p.dirname(path)).existsSync()
          ? Directory(p.dirname(path)).listSync()
          : const <FileSystemEntity>[];
      expect(leftovers, isEmpty);
      expect(await store.readAll('dev-1'), isEmpty);
    }, testOn: 'linux || mac-os');

    test('writes atomically, leaving no temporary files', () async {
      final store = FileCredentialStore(path);
      await Future.wait([
        for (var i = 0; i < 20; i++) store.write(token('dev-$i')),
      ]);
      final names = Directory(p.dirname(path))
          .listSync()
          .map((e) => p.basename(e.path));
      expect(names, ['credentials.json']);
      expect(
        (jsonDecode(File(path).readAsStringSync()) as Map)['credentials'],
        hasLength(20),
      );
    });

    test('sets a corrupt file aside and starts empty', () async {
      writeRaw(path, '{"version": 1, "credentials": [ {"type": "tok');
      final clock = FakeClock(DateTime.utc(2026, 10, 21, 9, 30));
      final warnings = <StoreWarning>[];
      final store = FileCredentialStore(
        path,
        clock: clock,
        onWarning: warnings.add,
      );
      expect(await store.readAll('dev-1'), isEmpty);
      final warning = warnings.single;
      expect(warning.message, contains('starting empty'));
      expect(warning.backupPath, '$path.corrupt-2026-10-21T09-30-00-000Z');
      expect(
        File(warning.backupPath!).readAsStringSync(),
        startsWith('{"version"'),
      );
      expect(File(path).existsSync(), isFalse);
      expect(store.warnings, warnings);

      await store.write(token('dev-1'));
      expect(
        await FileCredentialStore(path).read('dev-1', 'firetv.lightning'),
        isNotNull,
      );
    });

    test(
      'keeps valid entries next to malformed ones and backs up the file',
      () async {
        writeRaw(
          path,
          jsonEncode({
            'version': 1,
            'credentials': [
              token('dev-1').toJson(),
              {'type': 'token', 'driverId': 'x'},
              'not an object',
              {...token('dev-2').toJson(), 'type': 'futureKind'},
            ],
          }),
        );
        final store = FileCredentialStore(path);
        expect(await store.read('dev-1', 'firetv.lightning'), token('dev-1'));
        expect(await store.readAll('dev-2'), isEmpty);
        expect(store.warnings.single.message, contains('3 malformed entries'));
        expect(File(store.warnings.single.backupPath!).existsSync(), isTrue);
        expect(
          File(path).existsSync(),
          isTrue,
          reason: 'original kept until next write',
        );
      },
    );

    test('a JSON document of the wrong shape is set aside', () async {
      writeRaw(path, '[1, 2, 3]');
      final store = FileCredentialStore(path);
      expect(await store.readAll('x'), isEmpty);
      expect(store.warnings.single.backupPath, isNotNull);
    });

    test(
      'a failed write surfaces as a WatchmeError and changes nothing',
      () async {
        // The store's directory is a regular file, so it cannot be created.
        final blocker = File(p.join(dir.path, 'blocker'))
          ..writeAsStringSync('');
        final store = FileCredentialStore(
          p.join(blocker.path, 'credentials.json'),
        );
        await expectLater(
          store.write(token('dev-1')),
          throwsWatchmeError(WatchmeErrorCode.internal),
        );
        expect(await store.readAll('dev-1'), isEmpty);
      },
    );
  });

  group('FileDeviceRepository', () {
    final record = DeviceRecord(
      id: 'dev-1',
      name: 'Den Fire TV',
      host: '10.0.0.7',
      manufacturer: 'Amazon',
      model: 'AFTKA',
      mac: 'd8:31:34:aa:bb:cc',
      otherMacs: const {'d8:31:34:aa:bb:cd'},
      stableId: 'uuid:7c2a6a2e',
      ports: const {'dial': 8009, 'remote': 8080},
      driverIds: const ['firetv.lightning'],
      lastSeen: DateTime.utc(2026, 10, 21),
    );

    test('round-trips, replaces and removes records', () async {
      final repo = FileDeviceRepository(p.join(dir.path, 'devices.json'));
      await repo.put(record);
      await repo.put(record.copyWith(name: 'Renamed'));
      await repo.put(
        const DeviceRecord(id: 'dev-0', name: 'Roku', host: '10.0.0.20'),
      );
      final reopened = FileDeviceRepository(p.join(dir.path, 'devices.json'));
      expect((await reopened.get('dev-1'))!.name, 'Renamed');
      expect(await reopened.get('dev-1'), record.copyWith(name: 'Renamed'));
      expect((await reopened.all()).map((r) => r.id), ['dev-0', 'dev-1']);
      await reopened.remove('dev-0');
      await reopened.remove('missing');
      expect(
        await FileDeviceRepository(p.join(dir.path, 'devices.json')).all(),
        hasLength(1),
      );
    });

    test('is private by default', () async {
      final file = p.join(dir.path, 'devices.json');
      await FileDeviceRepository(file).put(record);
      expect(modeOf(file), 0x180);
    }, testOn: 'linux || mac-os');
  });

  group('WatchmeDirectories', () {
    test('follows XDG on Linux', () {
      expect(
        WatchmeDirectories.state(
          environment: {'XDG_STATE_HOME': '/x/state', 'HOME': '/home/u'},
        ),
        '/x/state/watchme',
      );
      expect(
        WatchmeDirectories.state(environment: {'HOME': '/home/u'}),
        '/home/u/.local/state/watchme',
      );
      expect(
        WatchmeDirectories.state(
          environment: {'XDG_STATE_HOME': 'relative', 'HOME': '/home/u'},
        ),
        '/home/u/.local/state/watchme',
      );
      expect(
        () => WatchmeDirectories.state(environment: {}),
        throwsWatchmeError(WatchmeErrorCode.unsupported),
      );
    }, testOn: 'linux');
  });
}
