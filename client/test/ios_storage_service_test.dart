import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/ios_bookmark_channel.dart';
import 'package:didsa_cad_client/storage/ios_storage_service.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/recent_project_store.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// A fake `IosBookmarkChannel` backed by a plain in-memory file tree plus a
/// bookmark(base64 string) -> resolved-root-path table, standing in for
/// the real `uk.snail_shell.didsa_cad_client/ios_storage` platform channel
/// (unavailable in this test environment - no Xcode/device in this
/// sandbox). Mirrors this codebase's own "inject the real dependency,
/// substitute a fake for tests" convention (see
/// `client/test/saf_storage_service_test.dart`'s `_FakeSafUtil`/
/// `_FakeSafStream`), just applied to `IosBookmarkChannel`.
class _FakeIosBookmarkChannel extends IosBookmarkChannel {
  final Map<String, Uint8List> _files = {}; // full resolved path -> bytes
  final Map<String, int> _mtimesMs = {};
  final Map<String, String> _bookmarkToPath = {}; // bookmark -> resolved root path
  final Set<String> _staleBookmarks = {};
  final Set<String> _unresolvableBookmarks = {};

  IosPickedFolder? nextPicked;
  int _mtimeCounter = 2000;

  /// Registers a fake root folder, returning the bookmark string
  /// `IosProjectRoot.bookmarkBase64` should carry for it.
  String addRoot(String resolvedPath) {
    final bookmark = 'bookmark-for-$resolvedPath';
    _bookmarkToPath[bookmark] = resolvedPath;
    return bookmark;
  }

  void markStale(String bookmark) => _staleBookmarks.add(bookmark);

  void markUnresolvable(String bookmark) => _unresolvableBookmarks.add(bookmark);

  @override
  Future<IosPickedFolder?> pickFolder() async => nextPicked;

  @override
  Future<IosResolvedBookmark?> resolveBookmark(String bookmarkBase64) async {
    if (_unresolvableBookmarks.contains(bookmarkBase64)) return null;
    final path = _bookmarkToPath[bookmarkBase64];
    if (path == null) return null;
    return IosResolvedBookmark(path: path, isStale: _staleBookmarks.contains(bookmarkBase64));
  }

  @override
  Future<void> stopAccessing(String path) async {}

  @override
  Future<Uint8List> readFile(String path) async {
    final bytes = _files[path];
    if (bytes == null) throw StateError('no such file: $path');
    return bytes;
  }

  @override
  Future<void> writeFile(String path, Uint8List bytes) async {
    _files[path] = bytes;
    _mtimesMs[path] = _mtimeCounter++;
  }

  @override
  Future<int?> lastModifiedMs(String path) async => _mtimesMs[path];

  @override
  Future<bool> exists(String path) async => _files.containsKey(path);

  /// Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
  /// §3.2): renames the file at `path` to `newFileName`, keeping it in the
  /// same directory - mirrors `IosStoragePlugin.swift`'s own `moveItem`
  /// within one parent.
  @override
  Future<String> renameFile(String path, String newFileName) async {
    final bytes = _files[path];
    if (bytes == null) throw StateError('no such file: $path');
    final lastSlash = path.lastIndexOf('/');
    final newPath = lastSlash == -1 ? newFileName : '${path.substring(0, lastSlash + 1)}$newFileName';
    _files[newPath] = _files.remove(path)!;
    _mtimesMs[newPath] = _mtimesMs.remove(path) ?? _mtimeCounter++;
    return newPath;
  }

  @override
  Future<List<String>> listFilesRecursive(String rootPath, {String? extensionFilter}) async {
    final prefix = rootPath.endsWith('/') ? rootPath : '$rootPath/';
    final results = <String>[];
    for (final path in _files.keys) {
      if (!path.startsWith(prefix)) continue;
      final relativePath = path.substring(prefix.length);
      if (extensionFilter != null && !relativePath.endsWith(extensionFilter)) continue;
      results.add(relativePath);
    }
    return results;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeIosBookmarkChannel channel;
  late IosStorageService service;
  late String bookmark;
  late IosProjectRoot root;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    channel = _FakeIosBookmarkChannel();
    service = IosStorageService(channel: channel, recentProjectStore: RecentProjectStore());
    bookmark = channel.addRoot('/fake/projects');
    root = IosProjectRoot(bookmarkBase64: bookmark, displayName: 'projects');
  });

  group('writeFile / readFile', () {
    test('creates a new file and reads it back', () async {
      final handle = await service.writeFile(root, 'assemblies/top.didsa', Uint8List.fromList([1, 2, 3]));

      expect(handle, isA<IosFileHandle>());
      expect(handle.relativePath, 'assemblies/top.didsa');
      expect(await service.readFile(handle), [1, 2, 3]);
    });

    test('overwrite preserves identity - same relative path, same resolved path', () async {
      final first = await service.writeFile(root, 'part.didsa', Uint8List.fromList([1]));
      final second = await service.writeFile(root, 'part.didsa', Uint8List.fromList([2]));

      expect((second as IosFileHandle).resolvedPath, (first as IosFileHandle).resolvedPath);
      expect(second.relativePath, first.relativePath);
      expect(await service.readFile(second), [2]);
    });
  });

  group('renameFile', () {
    test('renames the file, keeping it in the same directory', () async {
      await service.writeFile(root, 'parts/bracket.DIDSAprt', Uint8List.fromList([1, 2, 3]));

      final handle = await service.renameFile(root, 'parts/bracket.DIDSAprt', 'left-bracket.DIDSAprt');

      expect(handle.relativePath, 'parts/left-bracket.DIDSAprt');
      expect(await service.readFile(handle), [1, 2, 3]);
      expect(await service.resolve(root, 'parts/bracket.DIDSAprt'), isNull);
    });

    test('renames a top-level file with no directory of its own', () async {
      await service.writeFile(root, 'bracket.DIDSAprt', Uint8List.fromList([1]));

      final handle = await service.renameFile(root, 'bracket.DIDSAprt', 'left-bracket.DIDSAprt');

      expect(handle.relativePath, 'left-bracket.DIDSAprt');
    });

    test('throws StorageException when a file already exists at the destination', () async {
      await service.writeFile(root, 'bracket.DIDSAprt', Uint8List.fromList([1]));
      await service.writeFile(root, 'left-bracket.DIDSAprt', Uint8List.fromList([2]));

      expect(
        () => service.renameFile(root, 'bracket.DIDSAprt', 'left-bracket.DIDSAprt'),
        throwsA(isA<StorageException>()),
      );
    });

    test('throws StorageException when nothing exists at the source path', () async {
      expect(
        () => service.renameFile(root, 'does-not-exist.DIDSAprt', 'new-name.DIDSAprt'),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('resolve', () {
    test('returns null for a path that does not exist', () async {
      expect(await service.resolve(root, 'nothing.didsa'), isNull);
    });

    test('returns a handle for an existing nested file', () async {
      await service.writeFile(root, 'a/b/part.didsa', Uint8List.fromList([9]));
      final handle = await service.resolve(root, 'a/b/part.didsa');
      expect(handle, isNotNull);
      expect(handle!.relativePath, 'a/b/part.didsa');
    });
  });

  group('exists / lastModified', () {
    test('exists is true only after a write', () async {
      final missing = IosFileHandle(root: root, relativePath: 'ghost.didsa', resolvedPath: '/fake/projects/ghost.didsa');
      expect(await service.exists(missing), isFalse);

      final handle = await service.writeFile(root, 'part.didsa', Uint8List(0));
      expect(await service.exists(handle), isTrue);
    });

    test('exists reads false, not throws, for an unreachable root', () async {
      channel.markUnresolvable(bookmark);
      final handle = IosFileHandle(root: root, relativePath: 'part.didsa', resolvedPath: '/fake/projects/part.didsa');
      expect(await service.exists(handle), isFalse);
    });

    test('lastModified reflects the fake channel\'s stored timestamp', () async {
      final handle = await service.writeFile(root, 'part.didsa', Uint8List(0));
      final modified = await service.lastModified(handle);
      expect(modified, isNotNull);
      expect(modified!.millisecondsSinceEpoch, greaterThanOrEqualTo(2000));
    });
  });

  group('lastUsedProjectRoot', () {
    test('is null when nothing has been persisted yet', () async {
      expect(await service.lastUsedProjectRoot(), isNull);
    });

    test('is null when the persisted bookmark no longer resolves', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: 'bookmark-does-not-exist', displayName: 'gone');
      final serviceWithStore = IosStorageService(channel: channel, recentProjectStore: store);

      expect(await serviceWithStore.lastUsedProjectRoot(), isNull);
    });

    test('is null when the persisted bookmark resolves but is stale', () async {
      channel.markStale(bookmark);
      final store = RecentProjectStore();
      await store.save(persistedKey: bookmark, displayName: root.displayName);
      final serviceWithStore = IosStorageService(channel: channel, recentProjectStore: store);

      expect(await serviceWithStore.lastUsedProjectRoot(), isNull);
    });

    test('returns the persisted root once its bookmark resolves cleanly', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: bookmark, displayName: root.displayName);
      final serviceWithStore = IosStorageService(channel: channel, recentProjectStore: store);

      final resolved = await serviceWithStore.lastUsedProjectRoot();

      expect(resolved, isNotNull);
      expect(resolved!.persistedKey, bookmark);
      expect(resolved.displayName, root.displayName);
    });
  });

  group('listFiles', () {
    test('returns an empty list for an empty tree', () async {
      expect(await service.listFiles(root), isEmpty);
    });

    test('lists files recursively', () async {
      await service.writeFile(root, 'top.didsa', Uint8List(0));
      await service.writeFile(root, 'assemblies/sub.didsa', Uint8List(0));
      await service.writeFile(root, 'assemblies/nested/leaf.didsa', Uint8List(0));

      final paths = await service.listFiles(root);

      expect(paths.toSet(), {
        'top.didsa',
        'assemblies/sub.didsa',
        'assemblies/nested/leaf.didsa',
      });
    });

    test('extensionFilter narrows to matching file names only', () async {
      await service.writeFile(root, 'a.didsa', Uint8List(0));
      await service.writeFile(root, 'notes.txt', Uint8List(0));

      final paths = await service.listFiles(root, extensionFilter: '.didsa');

      expect(paths, ['a.didsa']);
    });

    test('throws when the root itself is unreachable', () async {
      channel.markUnresolvable(bookmark);
      expect(() => service.listFiles(root), throwsA(isA<StorageException>()));
    });
  });

  group('cross-implementation type safety', () {
    test('rejects a DesktopProjectRoot passed to an IosStorageService call', () async {
      final desktopRoot = DesktopProjectRoot('/a/b');
      expect(() => service.writeFile(desktopRoot, 'x.didsa', Uint8List(0)), throwsA(isA<StorageException>()));
    });

    test('rejects a SafProjectRoot passed to an IosStorageService call', () async {
      final safRoot = SafProjectRoot(treeUri: 'content://tree/root', displayName: 'projects');
      expect(() => service.writeFile(safRoot, 'x.didsa', Uint8List(0)), throwsA(isA<StorageException>()));
    });

    test('rejects a non-iOS FileHandle passed to readFile', () async {
      final desktopHandle = DesktopFileHandle(
        root: DesktopProjectRoot('/a/b'),
        relativePath: 'x.didsa',
        path: '/a/b/x.didsa',
      );
      expect(() => service.readFile(desktopHandle), throwsA(isA<StorageException>()));
    });
  });
}
