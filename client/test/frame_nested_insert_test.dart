import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/add_component.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// Bug report 2026-10-14: `Frame` (an assembly of Frame_A/Frame_B, saved
/// before the Save As re-mint fix, so A and B share ids, with legacy
/// `.DIDSAprt` refs) worked on its own but arrived empty when inserted into a
/// new part - two levels deep. The three data files are the reporter's own.
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

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async => _files.keys.toList();

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      throw UnimplementedError();
}


Map<String, dynamic> _load(String name) =>
    jsonDecode(File('test/data/$name').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _topPayload() => {
  'schema_version': 1,
  'document': {
    'id': 'doc-top',
    'root_part_id': 'part-top',
    'parts': [
      {'id': 'part-top', 'name': 'Top', 'features': [], 'occurrences': [], 'mates': []},
    ],
  },
  'sketches': [],
};

void main() {
  late _FakeStorageService storage;
  late AssemblyGraphComposer composer;
  const root = DesktopProjectRoot('/fake/project');

  setUp(() {
    storage = _FakeStorageService();
    storage.put('Frame_A.didsa', _load('frame_a_legacy.didsa'));
    storage.put('Frame_B.didsa', _load('frame_b_legacy.didsa'));
    storage.put('Frame.didsa', _load('frame_assembly_legacy.didsa'));
    final tempDir = Directory.systemTemp.createTempSync('didsa_frame_test_');
    composer = AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: tempDir));
  });

  test('inserting Frame into a new part resolves all four nested occurrences to two distinct Parts', () async {
    final composed = await composer.compose(root, 'Frame.didsa');
    final merged = mergeComponentIntoDocument(
      currentPayload: _topPayload(),
      componentPayload: composed.documentPayload,
      rootPartId: 'part-top',
      occurrenceId: 'occ-frame',
      externalRef: 'Frame.didsa',
    );

    final parts = ((merged['document'] as Map)['parts'] as List).cast<Map<String, dynamic>>();
    final partIds = {for (final part in parts) part['id'] as String};
    expect(parts, hasLength(4), reason: 'Top, Frame, Frame_A, Frame_B');

    final top = parts.firstWhere((part) => part['id'] == 'part-top');
    final topOccurrence = (top['occurrences'] as List).single as Map<String, dynamic>;
    final frame = parts.firstWhere((part) => part['id'] == topOccurrence['resolved_part_id']);
    final children = (frame['occurrences'] as List).cast<Map<String, dynamic>>();
    expect(children, hasLength(4));
    for (final child in children) {
      expect(partIds, contains(child['resolved_part_id']), reason: '${child['external_ref']} must resolve');
    }
    final byRef = <String, Set<Object?>>{};
    for (final child in children) {
      byRef.putIfAbsent(child['external_ref'] as String, () => {}).add(child['resolved_part_id']);
    }
    expect(byRef.keys.toSet(), {'Frame_A.didsa', 'Frame_B.didsa'});
    expect(byRef['Frame_A.didsa'], hasLength(1));
    expect(byRef['Frame_B.didsa'], hasLength(1));
    expect(byRef['Frame_A.didsa'], isNot(equals(byRef['Frame_B.didsa'])));
  });
}
