import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/storage/desktop_storage_service.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/recent_project_store.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late DesktopStorageService service;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('didsa_desktop_storage_test_');
    service = DesktopStorageService(recentProjectStore: RecentProjectStore());
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('writeFile / readFile / exists', () {
    test('writes a new file, creating missing intermediate directories', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final bytes = utf8.encode('{"schema_version": 2}');

      final handle = await service.writeFile(root, 'assemblies/top.didsa', bytes);

      expect(handle, isA<DesktopFileHandle>());
      expect(handle.relativePath, 'assemblies/top.didsa');
      expect(await File((handle as DesktopFileHandle).path).exists(), isTrue);
      expect(await service.exists(handle), isTrue);
    });

    test('reads back exactly what was written', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final bytes = utf8.encode('hello assembly world');

      final handle = await service.writeFile(root, 'part.didsa', bytes);
      final readBack = await service.readFile(handle);

      expect(readBack, bytes);
    });

    test('overwrites an existing file in place rather than erroring', () async {
      final root = DesktopProjectRoot(tempDir.path);
      await service.writeFile(root, 'part.didsa', utf8.encode('v1'));
      final handle = await service.writeFile(root, 'part.didsa', utf8.encode('v2'));

      expect(await service.readFile(handle), utf8.encode('v2'));
    });

    test('exists is false for a file that was never written', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final handle = DesktopFileHandle(root: root, relativePath: 'ghost.didsa', path: '${tempDir.path}/ghost.didsa');

      expect(await service.exists(handle), isFalse);
    });

    test('readFile throws StorageException for a missing file', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final handle = DesktopFileHandle(root: root, relativePath: 'ghost.didsa', path: '${tempDir.path}/ghost.didsa');

      expect(() => service.readFile(handle), throwsA(isA<StorageException>()));
    });
  });

  group('resolve', () {
    test('returns null for a relative path that does not exist yet', () async {
      final root = DesktopProjectRoot(tempDir.path);
      expect(await service.resolve(root, 'nothing-here.didsa'), isNull);
    });

    test('returns a handle for an existing file', () async {
      final root = DesktopProjectRoot(tempDir.path);
      await service.writeFile(root, 'sub/part.didsa', utf8.encode('x'));

      final handle = await service.resolve(root, 'sub/part.didsa');

      expect(handle, isNotNull);
      expect(handle!.relativePath, 'sub/part.didsa');
    });
  });

  group('lastModified', () {
    test('reflects a real modification time for a written file', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final before = DateTime.now().subtract(const Duration(seconds: 5));

      final handle = await service.writeFile(root, 'part.didsa', utf8.encode('x'));
      final modified = await service.lastModified(handle);

      expect(modified, isNotNull);
      expect(modified!.isAfter(before), isTrue);
    });

    test('is null for a nonexistent file rather than throwing', () async {
      final root = DesktopProjectRoot(tempDir.path);
      final handle = DesktopFileHandle(root: root, relativePath: 'ghost.didsa', path: '${tempDir.path}/ghost.didsa');

      expect(await service.lastModified(handle), isNull);
    });
  });

  group('lastUsedProjectRoot', () {
    test('is null when nothing has been saved yet', () async {
      expect(await service.lastUsedProjectRoot(), isNull);
    });

    test('is null when the persisted directory no longer exists', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: '/does/not/exist/anymore', displayName: 'gone');
      final serviceWithStore = DesktopStorageService(recentProjectStore: store);

      expect(await serviceWithStore.lastUsedProjectRoot(), isNull);
    });

    test('returns the persisted root once it has been saved and still exists', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: tempDir.path, displayName: 'projects');
      final serviceWithStore = DesktopStorageService(recentProjectStore: store);

      final root = await serviceWithStore.lastUsedProjectRoot();

      expect(root, isNotNull);
      expect(root!.persistedKey, tempDir.path);
    });
  });

  group('cross-implementation type safety', () {
    test('rejects a SafFileHandle from a DesktopStorageService call', () async {
      final safRoot = SafProjectRoot(treeUri: 'content://tree/abc', displayName: 'x');
      final safHandle = SafFileHandle(root: safRoot, relativePath: 'part.didsa', uri: 'content://tree/abc/part.didsa');

      expect(() => service.readFile(safHandle), throwsA(isA<StorageException>()));
    });
  });
}
