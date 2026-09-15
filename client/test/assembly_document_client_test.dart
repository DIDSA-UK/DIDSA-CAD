import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// Same in-memory fake used by `assembly_graph_composer_test.dart` - kept
/// as a private copy here (this codebase's own convention for small test
/// fakes, e.g. every `test_feature_*.py`'s own helper functions are
/// copy-pasted rather than shared via a common module).
class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> files = {};

  void put(String relativePath, Map<String, dynamic> payload) {
    files[relativePath] = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) =>
      throw UnimplementedError();

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!files.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    if (!files.containsKey(handle.relativePath)) {
      throw StorageException('Failed to read ${handle.relativePath}');
    }
    return files[handle.relativePath]!;
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    files[relativePath] = bytes;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => DateTime(2026, 1, 1);

  @override
  Future<bool> exists(FileHandle handle) async => files.containsKey(handle.relativePath);
}

Map<String, dynamic> _singlePartPayload({required String id, required String name}) => {
  'schema_version': 1,
  'document': {
    'id': 'doc-$id',
    'root_part_id': id,
    'parts': [
      {'id': id, 'name': name, 'features': [], 'occurrences': [], 'mates': []},
    ],
  },
  'sketches': [],
};

http.Response _jsonResponse(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  late DesktopProjectRoot root;

  setUp(() {
    root = const DesktopProjectRoot('/fake/project');
  });

  test('openAssembly composes the graph and imports it via one importNative call', () async {
    final storage = _FakeStorageService();
    storage.put('top.didsa', _singlePartPayload(id: 'part-top', name: 'Top'));
    final tempDir = await Directory.systemTemp.createTemp('didsa_assembly_doc_client_test_');
    addTearDown(() => tempDir.delete(recursive: true));

    Map<String, dynamic>? capturedImportBody;
    final documentApiClient = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.method == 'POST' && request.url.path.endsWith('/import/native')) {
          capturedImportBody = jsonDecode(request.body) as Map<String, dynamic>;
          return _jsonResponse({'document_id': 'doc-1', 'part_ids': ['part-top']});
        }
        return _jsonResponse({}, status: 404);
      }),
    );
    final client = AssemblyDocumentClient(
      storageService: storage,
      documentApiClient: documentApiClient,
      composer: AssemblyGraphComposer(
        storageService: storage,
        fileCache: FileCache(cacheDirectory: tempDir),
      ),
    );

    final opened = await client.openAssembly(root, 'top.didsa');

    expect(opened.rootPartId, 'part-top');
    expect(opened.relativePathByPartId, {'part-top': 'top.didsa'});
    expect(capturedImportBody, isNotNull);
    expect(capturedImportBody!['document']['root_part_id'], 'part-top');
  });

  test('fetchAssemblyMesh parses the backend response into an AssemblyMeshDto', () async {
    final storage = _FakeStorageService();
    final documentApiClient = DocumentApiClient(
      httpClient: MockClient((request) async {
        expect(request.url.path, endsWith('/parts/part-top/assembly-mesh'));
        return _jsonResponse({
          'geometry': [
            {
              'part_id': 'part-top',
              'bodies': [
                {
                  'body_id': 'body-1',
                  'source': 'computed',
                  'mesh': {
                    'vertices': [[0.0, 0.0, 0.0]],
                    'normals': [[0.0, 0.0, 1.0]],
                    'triangle_indices': [],
                    'face_ids': [],
                  },
                },
              ],
            },
          ],
          'instances': [
            {
              'occurrence_path': [],
              'part_id': 'part-top',
              'world_transform': {
                'translation': [0.0, 0.0, 0.0],
                'rotation_axis': [0.0, 0.0, 1.0],
                'rotation_angle_degrees': 0.0,
              },
              'hidden': false,
            },
          ],
        });
      }),
    );
    final client = AssemblyDocumentClient(storageService: storage, documentApiClient: documentApiClient);

    final mesh = await client.fetchAssemblyMesh('part-top');

    expect(mesh.geometry, hasLength(1));
    expect(mesh.geometry.single.partId, 'part-top');
    expect(mesh.instances, hasLength(1));
    expect(mesh.instances.single.occurrencePath, isEmpty);
  });

  test('savePart exports one Part and writes it to the given relative path', () async {
    final storage = _FakeStorageService();
    String? capturedPartIdParam;
    final documentApiClient = DocumentApiClient(
      httpClient: MockClient((request) async {
        capturedPartIdParam = request.url.queryParameters['part_id'];
        return _jsonResponse(_singlePartPayload(id: 'part-top', name: 'Top'));
      }),
    );
    final client = AssemblyDocumentClient(storageService: storage, documentApiClient: documentApiClient);

    await client.savePart(root, 'part-top', 'top.didsa');

    expect(capturedPartIdParam, 'part-top');
    expect(storage.files.containsKey('top.didsa'), isTrue);
    final written = jsonDecode(utf8.decode(storage.files['top.didsa']!)) as Map<String, dynamic>;
    expect(written['document']['parts'][0]['id'], 'part-top');
  });
}
