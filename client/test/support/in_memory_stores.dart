// In-memory stand-ins for the two stores a RemoteStorageService keeps on disk (the sync state and queue, and the file cache), for
// widget tests: real file I/O does not settle inside `testWidgets`' fake-async pump loop (docs/flutter-widget-test-lessons.md).
import 'dart:typed_data';

import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/server/sync_state.dart';

class InMemorySyncStore extends SyncStore {
  final Map<String, ProjectSyncState> _states = {};
  final Map<String, Uint8List> _bytes = {};

  @override
  Future<ProjectSyncState> load(ServerProjectRoot root) async => _states.putIfAbsent(root.persistedKey, ProjectSyncState.new);

  @override
  Future<void> save(ServerProjectRoot root) async {}

  String _k(ServerProjectRoot root, String kind, String path) => '${root.persistedKey}|$kind|$path';

  @override
  Future<void> putQueued(ServerProjectRoot root, String path, Uint8List bytes) async => _bytes[_k(root, 'queue', path)] = bytes;

  @override
  Future<Uint8List?> getQueued(ServerProjectRoot root, String path) async => _bytes[_k(root, 'queue', path)];

  @override
  Future<void> deleteQueued(ServerProjectRoot root, String path) async => _bytes.remove(_k(root, 'queue', path));

  @override
  Future<void> putMine(ServerProjectRoot root, String path, Uint8List bytes) async => _bytes[_k(root, 'mine', path)] = bytes;

  @override
  Future<Uint8List?> getMine(ServerProjectRoot root, String path) async => _bytes[_k(root, 'mine', path)];

  @override
  Future<void> deleteMine(ServerProjectRoot root, String path) async => _bytes.remove(_k(root, 'mine', path));
}

class InMemoryFileCache extends FileCache {
  final Map<String, CachedFile> _files = {};

  String _k(ProjectRoot root, String path) => '${root.persistedKey}|$path';

  @override
  Future<void> put(ProjectRoot root, String relativePath, Uint8List bytes, {DateTime? lastKnownModified, int? serverVersion}) async {
    _files[_k(root, relativePath)] = CachedFile(
      bytes: bytes,
      cachedAt: DateTime.now(),
      lastKnownModified: lastKnownModified,
      serverVersion: serverVersion,
    );
  }

  @override
  Future<CachedFile?> get(ProjectRoot root, String relativePath) async => _files[_k(root, relativePath)];

  @override
  Future<void> evict(ProjectRoot root, String relativePath) async => _files.remove(_k(root, relativePath));
}
