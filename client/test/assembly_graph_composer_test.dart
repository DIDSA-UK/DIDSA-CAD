import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// An in-memory `StorageService` standing in for real file I/O - the same
/// "inject the real dependency, substitute a fake for tests" convention
/// this codebase already uses (e.g. `PartScreen`'s injectable `documentApi`),
/// applied here since `AssemblyGraphComposer` only ever talks to
/// `StorageService`'s abstract interface, never a concrete platform
/// implementation.
class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> _files = {};
  final Set<String> _unreadable = {};

  void put(String relativePath, Map<String, dynamic> payload) {
    _files[relativePath] = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  void makeUnreadable(String relativePath) => _unreadable.add(relativePath);

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) =>
      throw UnimplementedError();

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!_files.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    if (_unreadable.contains(handle.relativePath) || !_files.containsKey(handle.relativePath)) {
      throw StorageException('Failed to read ${handle.relativePath}');
    }
    return _files[handle.relativePath]!;
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    _files[relativePath] = bytes;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => DateTime(2026, 1, 1);

  @override
  Future<bool> exists(FileHandle handle) async => _files.containsKey(handle.relativePath);
}

Map<String, dynamic> _singlePartPayload({
  required String id,
  required String name,
  List<Map<String, dynamic>> occurrences = const [],
}) {
  return {
    'schema_version': 1,
    'document': {
      'id': 'doc-$id',
      'root_part_id': id,
      'parts': [
        {
          'id': id,
          'name': name,
          'features': [],
          'occurrences': occurrences,
          'mates': [],
        },
      ],
    },
    'sketches': [],
  };
}

Map<String, dynamic> _occurrence(String id, String externalRef) => {
  'id': id,
  'external_ref': externalRef,
  'name_override': null,
  'transform': {
    'translation': [0.0, 0.0, 0.0],
    'rotation_axis': [0.0, 0.0, 1.0],
    'rotation_angle_degrees': 0.0,
  },
  'suppressed': false,
  'hidden': false,
};

void main() {
  late _FakeStorageService storage;
  late AssemblyGraphComposer composer;
  late DesktopProjectRoot root;

  setUp(() {
    storage = _FakeStorageService();
    final tempDir = Directory.systemTemp.createTempSync('didsa_composer_test_');
    composer = AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: tempDir));
    root = const DesktopProjectRoot('/fake/project');
  });

  test('a root file with no occurrences composes to just itself', () async {
    storage.put('top.didsa', _singlePartPayload(id: 'part-top', name: 'Top'));

    final result = await composer.compose(root, 'top.didsa');

    expect(result.rootPartId, 'part-top');
    final parts = result.documentPayload['document']['parts'] as List;
    expect(parts, hasLength(1));
    expect(result.relativePathByPartId, {'part-top': 'top.didsa'});
    expect(result.staleRelativePaths, isEmpty);
  });

  test('an occurrence gets resolved_part_id set to its target file\'s own id', () async {
    storage.put('bolt.didsa', _singlePartPayload(id: 'part-bolt', name: 'Bolt'));
    storage.put(
      'top.didsa',
      _singlePartPayload(id: 'part-top', name: 'Top', occurrences: [_occurrence('occ-1', 'bolt.didsa')]),
    );

    final result = await composer.compose(root, 'top.didsa');

    final parts = (result.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts, hasLength(2));
    final topPart = parts.firstWhere((p) => p['id'] == 'part-top');
    final occurrence = (topPart['occurrences'] as List).single as Map<String, dynamic>;
    expect(occurrence['resolved_part_id'], 'part-bolt');
    expect(occurrence['external_ref'], 'bolt.didsa');
  });

  test('the same file referenced by two occurrences is deduplicated, not read/included twice', () async {
    storage.put('washer.didsa', _singlePartPayload(id: 'part-washer', name: 'Washer'));
    storage.put(
      'plate.didsa',
      _singlePartPayload(
        id: 'part-plate',
        name: 'Plate',
        occurrences: [_occurrence('occ-1', 'washer.didsa'), _occurrence('occ-2', 'washer.didsa')],
      ),
    );

    final result = await composer.compose(root, 'plate.didsa');

    final parts = (result.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts, hasLength(2)); // plate + washer, not plate + washer + washer
    expect(parts.where((p) => p['id'] == 'part-washer'), hasLength(1));
  });

  test('a direct cycle (A references B references A) throws AssemblyGraphCycleException', () async {
    storage.put('a.didsa', _singlePartPayload(id: 'part-a', name: 'A', occurrences: [_occurrence('occ-b', 'b.didsa')]));
    storage.put('b.didsa', _singlePartPayload(id: 'part-b', name: 'B', occurrences: [_occurrence('occ-a', 'a.didsa')]));

    expect(() => composer.compose(root, 'a.didsa'), throwsA(isA<AssemblyGraphCycleException>()));
  });

  test('a self-referencing file throws AssemblyGraphCycleException', () async {
    storage.put(
      'self.didsa',
      _singlePartPayload(id: 'part-self', name: 'Self', occurrences: [_occurrence('occ-self', 'self.didsa')]),
    );

    expect(() => composer.compose(root, 'self.didsa'), throwsA(isA<AssemblyGraphCycleException>()));
  });

  test('a missing referenced file leaves that occurrence unresolved rather than failing the whole compose', () async {
    storage.put(
      'top.didsa',
      _singlePartPayload(id: 'part-top', name: 'Top', occurrences: [_occurrence('occ-1', 'missing.didsa')]),
    );

    final result = await composer.compose(root, 'top.didsa');

    final parts = (result.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts, hasLength(1));
    final occurrence = (parts.single['occurrences'] as List).single as Map<String, dynamic>;
    expect(occurrence.containsKey('resolved_part_id'), isFalse);
  });

  test('a root file that cannot be read at all throws StorageException', () async {
    expect(() => composer.compose(root, 'does-not-exist.didsa'), throwsA(isA<StorageException>()));
  });

  test('an unreadable-but-cached child file falls back to the cache and is marked stale', () async {
    storage.put('bolt.didsa', _singlePartPayload(id: 'part-bolt', name: 'Bolt'));
    storage.put(
      'top.didsa',
      _singlePartPayload(id: 'part-top', name: 'Top', occurrences: [_occurrence('occ-1', 'bolt.didsa')]),
    );

    // First compose succeeds and warms the cache for bolt.didsa.
    await composer.compose(root, 'top.didsa');

    // Now bolt.didsa becomes unreadable live - the second compose should
    // fall back to the cached snapshot and flag it stale.
    storage.makeUnreadable('bolt.didsa');

    final result = await composer.compose(root, 'top.didsa');

    expect(result.staleRelativePaths, contains('bolt.didsa'));
    final parts = (result.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts.any((p) => p['id'] == 'part-bolt'), isTrue);
  });

  test('a three-level nested chain resolves every level', () async {
    storage.put('leaf.didsa', _singlePartPayload(id: 'part-leaf', name: 'Leaf'));
    storage.put(
      'sub.didsa',
      _singlePartPayload(id: 'part-sub', name: 'Sub', occurrences: [_occurrence('occ-leaf', 'leaf.didsa')]),
    );
    storage.put(
      'top.didsa',
      _singlePartPayload(id: 'part-top', name: 'Top', occurrences: [_occurrence('occ-sub', 'sub.didsa')]),
    );

    final result = await composer.compose(root, 'top.didsa');

    final parts = (result.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
    expect(parts.map((p) => p['id']).toSet(), {'part-top', 'part-sub', 'part-leaf'});
    expect(result.rootPartId, 'part-top');
  });
}
