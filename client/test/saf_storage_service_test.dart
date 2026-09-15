import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_stream/saf_stream_platform_interface.dart' show SafNewFile;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart' show SafDocumentFile;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/recent_project_store.dart';
import 'package:didsa_cad_client/storage/saf_storage_service.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// A fake `SafUtil` backed by a plain in-memory tree, standing in for the
/// real Android platform channel (unavailable in this test environment -
/// see `docs/assembly-scope.md`'s note on SAF being genuinely untestable
/// without a device/emulator). Mirrors this codebase's own "inject the
/// real dependency, substitute a fake for tests" convention (e.g.
/// `PartScreen`'s injectable `documentApi`), just applied to a third-party
/// plugin class rather than an in-repo one.
class _FakeSafUtil extends SafUtil {
  final Map<String, _FakeNode> _nodesByUri = {};
  int _nextId = 0;

  String _newUri() => 'content://fake-tree/${_nextId++}';

  _FakeNode addDir(String uri, {required String name}) {
    final node = _FakeNode(uri: uri, name: name, isDir: true);
    _nodesByUri[uri] = node;
    return node;
  }

  @override
  Future<SafDocumentFile?> child(String uri, List<String> names) async {
    var current = _nodesByUri[uri];
    for (final name in names) {
      if (current == null) return null;
      current = current.children[name];
    }
    return current?.toDocumentFile();
  }

  @override
  Future<SafDocumentFile> mkdirp(String uri, List<String> names) async {
    var current = _nodesByUri[uri];
    if (current == null) {
      throw StateError('mkdirp against an unknown tree: $uri');
    }
    for (final name in names) {
      final existing = current!.children[name];
      if (existing != null) {
        current = existing;
        continue;
      }
      final child = _FakeNode(uri: _newUri(), name: name, isDir: true);
      current.children[name] = child;
      _nodesByUri[child.uri] = child;
      current = child;
    }
    return current!.toDocumentFile();
  }

  @override
  Future<SafDocumentFile?> stat(String uri, bool? isDir, {bool? throws}) async {
    final node = _nodesByUri[uri];
    if (node == null) {
      if (throws == true) throw StateError('not found: $uri');
      return null;
    }
    return node.toDocumentFile();
  }

  @override
  Future<bool> exists(String uri, bool isDir) async => _nodesByUri.containsKey(uri);
}

class _FakeNode {
  _FakeNode({required this.uri, required this.name, required this.isDir, this.bytes});

  final String uri;
  final String name;
  final bool isDir;
  Uint8List? bytes;
  int lastModifiedMs = 1000;
  final Map<String, _FakeNode> children = {};

  SafDocumentFile toDocumentFile() => SafDocumentFile(
    uri: uri,
    name: name,
    isDir: isDir,
    length: bytes?.length ?? 0,
    lastModified: lastModifiedMs,
  );
}

/// A fake `SafStream` sharing the same in-memory tree as `_FakeSafUtil`
/// (constructed together per test) so a write through one is visible to a
/// read/stat through the other, matching how the real platform channel
/// backs both packages with the same underlying SAF tree.
class _FakeSafStream extends SafStream {
  _FakeSafStream(this._util);

  final _FakeSafUtil _util;
  int _writeCount = 0;

  @override
  Future<Uint8List> readFileBytes(String uri, {int? start, int? count}) async {
    final node = _util._nodesByUri[uri];
    if (node == null || node.bytes == null) {
      throw StateError('no such file: $uri');
    }
    return node.bytes!;
  }

  @override
  Future<SafNewFile> writeFileUriBytes(String fileUri, Uint8List data, {bool? append}) async {
    final node = _util._nodesByUri[fileUri];
    if (node == null) throw StateError('no such file: $fileUri');
    node.bytes = append == true ? Uint8List.fromList([...?node.bytes, ...data]) : data;
    node.lastModifiedMs = 2000 + _writeCount++;
    return SafNewFile(Uri.parse(fileUri), node.name);
  }

  @override
  Future<SafNewFile> writeFileBytes(
    String treeUri,
    String fileName,
    String mime,
    Uint8List data, {
    bool? overwrite,
    bool? append,
  }) async {
    final parent = _util._nodesByUri[treeUri];
    if (parent == null) throw StateError('no such directory: $treeUri');
    final existing = parent.children[fileName];
    if (existing != null && overwrite == true) {
      existing.bytes = data;
      existing.lastModifiedMs = 2000 + _writeCount++;
      return SafNewFile(Uri.parse(existing.uri), fileName);
    }
    final node = _FakeNode(uri: _util._newUri(), name: fileName, isDir: false, bytes: data);
    node.lastModifiedMs = 2000 + _writeCount++;
    parent.children[fileName] = node;
    _util._nodesByUri[node.uri] = node;
    return SafNewFile(Uri.parse(node.uri), fileName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSafUtil safUtil;
  late _FakeSafStream safStream;
  late SafStorageService service;
  late SafProjectRoot root;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    safUtil = _FakeSafUtil();
    safStream = _FakeSafStream(safUtil);
    service = SafStorageService(safUtil: safUtil, safStream: safStream, recentProjectStore: RecentProjectStore());
    safUtil.addDir('content://fake-tree/root', name: 'projects');
    root = SafProjectRoot(treeUri: 'content://fake-tree/root', displayName: 'projects');
  });

  group('writeFile / readFile', () {
    test('creates intermediate directories and writes a new file', () async {
      final handle = await service.writeFile(root, 'assemblies/top.didsa', Uint8List.fromList([1, 2, 3]));

      expect(handle, isA<SafFileHandle>());
      expect(handle.relativePath, 'assemblies/top.didsa');
      expect(await service.readFile(handle), [1, 2, 3]);
    });

    test('overwrites an existing file via its own URI rather than minting a new one', () async {
      final first = await service.writeFile(root, 'part.didsa', Uint8List.fromList([1]));
      final second = await service.writeFile(root, 'part.didsa', Uint8List.fromList([2]));

      expect((second as SafFileHandle).uri, (first as SafFileHandle).uri);
      expect(await service.readFile(second), [2]);
    });

    test('writeFile without a file name in the relative path throws', () async {
      expect(() => service.writeFile(root, '', Uint8List(0)), throwsA(isA<StorageException>()));
    });
  });

  group('resolve', () {
    test('returns null for a path that does not exist', () async {
      expect(await service.resolve(root, 'nothing.didsa'), isNull);
    });

    test('returns null for a directory (not a file)', () async {
      await service.writeFile(root, 'sub/part.didsa', Uint8List(0));
      expect(await service.resolve(root, 'sub'), isNull);
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
      final missing = SafFileHandle(root: root, relativePath: 'ghost.didsa', uri: 'content://fake-tree/ghost');
      expect(await service.exists(missing), isFalse);

      final handle = await service.writeFile(root, 'part.didsa', Uint8List(0));
      expect(await service.exists(handle), isTrue);
    });

    test('lastModified reflects the fake tree\'s stored timestamp', () async {
      final handle = await service.writeFile(root, 'part.didsa', Uint8List(0));
      final modified = await service.lastModified(handle);
      expect(modified, isNotNull);
      expect(modified!.millisecondsSinceEpoch, greaterThanOrEqualTo(2000));
    });
  });

  group('lastUsedProjectRoot', () {
    test('is null when the persisted grant no longer resolves (revoked permission)', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: 'content://fake-tree/does-not-exist', displayName: 'gone');
      final serviceWithStore = SafStorageService(safUtil: safUtil, safStream: safStream, recentProjectStore: store);

      expect(await serviceWithStore.lastUsedProjectRoot(), isNull);
    });

    test('returns the persisted root once its grant still resolves', () async {
      final store = RecentProjectStore();
      await store.save(persistedKey: root.treeUri, displayName: root.displayName);
      final serviceWithStore = SafStorageService(safUtil: safUtil, safStream: safStream, recentProjectStore: store);

      final resolved = await serviceWithStore.lastUsedProjectRoot();

      expect(resolved, isNotNull);
      expect(resolved!.persistedKey, root.treeUri);
    });
  });

  group('cross-implementation type safety', () {
    test('rejects a DesktopProjectRoot passed to a SafStorageService call', () async {
      final desktopRoot = DesktopProjectRoot('/a/b');
      expect(() => service.writeFile(desktopRoot, 'x.didsa', Uint8List(0)), throwsA(isA<StorageException>()));
    });
  });
}
