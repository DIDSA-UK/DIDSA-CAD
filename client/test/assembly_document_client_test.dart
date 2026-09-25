import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/save_all.dart';
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

  /// Relative paths whose [writeFile] should throw [StorageException] -
  /// `saveAll`'s own partial-failure test uses this to simulate a revoked
  /// SAF grant/disk-full write without touching every other path's write.
  final Set<String> failOnWrite = {};

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
    if (failOnWrite.contains(relativePath)) {
      throw StorageException('Failed to write $relativePath');
    }
    files[relativePath] = bytes;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => DateTime(2026, 1, 1);

  @override
  Future<bool> exists(FileHandle handle) async => files.containsKey(handle.relativePath);

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async => files.keys.toList();

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      throw UnimplementedError();
}

Map<String, dynamic> _singlePartPayload({
  required String id,
  required String name,
  List<Map<String, dynamic>> occurrences = const [],
}) => {
  'schema_version': 1,
  'document': {
    'id': 'doc-$id',
    'root_part_id': id,
    'parts': [
      {'id': id, 'name': name, 'features': [], 'occurrences': occurrences, 'mates': []},
    ],
  },
  'sketches': [],
};

/// Phase 16 (`docs/assembly-scope.md` §2s): the same `_occurrence` shape
/// `assembly_graph_composer_test.dart`'s own fixture already establishes -
/// duplicated here per this file's existing small-fake convention rather
/// than shared.
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

  group('stampExternalRefs', () {
    test('rewrites external_ref by resolved_part_id, leaving an unresolved one untouched', () {
      final payload = {
        'document': {
          'parts': [
            {
              'id': 'part-top',
              'occurrences': [
                {'id': 'occ-1', 'resolved_part_id': 'part-child', 'external_ref': 'old.DIDSAprt'},
                {'id': 'occ-2', 'resolved_part_id': 'part-unresolved', 'external_ref': null},
              ],
            },
          ],
        },
      };

      final stamped = stampExternalRefs(
        documentPayload: payload,
        relativePathByPartId: {'part-child': 'new.DIDSAprt'},
      );

      final occurrences =
          ((stamped['document'] as Map)['parts'] as List)[0]['occurrences'] as List;
      expect((occurrences[0] as Map)['external_ref'], 'new.DIDSAprt');
      expect((occurrences[1] as Map)['external_ref'], isNull);
    });
  });

  group('saveAll', () {
    Map<String, dynamic> twoPartSession() => {
      'schema_version': 1,
      'document': {
        'id': 'doc-1',
        'root_part_id': 'part-top',
        'parts': [
          {
            'id': 'part-top',
            'name': 'Top',
            'features': [],
            'occurrences': [
              {
                'id': 'occ-1',
                'external_ref': 'bracket.DIDSAprt', // stale bare filename
                'resolved_part_id': 'part-child',
                'transform': null,
                'suppressed': false,
                'hidden': false,
              },
            ],
            'mates': [],
          },
          {'id': 'part-child', 'name': 'Child', 'features': [], 'occurrences': [], 'mates': []},
        ],
      },
      'sketches': [],
    };

    /// A router mock covering both requests `saveAll` makes: the one
    /// `importNative` (the stamped re-import) and one `exportNative` per
    /// Part (`savePart`'s own single-Part export, echoing back whichever
    /// Part the just-captured import body now holds - i.e. the *stamped*
    /// `external_ref`, not the stale one `twoPartSession` started with).
    ({DocumentApiClient client, Map<String, dynamic>? Function() capturedImportBody}) routedClient() {
      Map<String, dynamic>? capturedImportBody;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/import/native')) {
            capturedImportBody = jsonDecode(request.body) as Map<String, dynamic>;
            return _jsonResponse({'document_id': 'doc-1', 'part_ids': ['part-top', 'part-child']});
          }
          if (request.method == 'GET' && request.url.path.endsWith('/export/native')) {
            final partId = request.url.queryParameters['part_id'];
            final part = (capturedImportBody!['document']['parts'] as List)
                .cast<Map<String, dynamic>>()
                .firstWhere((p) => p['id'] == partId);
            return _jsonResponse({
              'schema_version': 1,
              'document': {'id': 'doc-1', 'root_part_id': partId, 'parts': [part]},
              'sketches': [],
            });
          }
          return _jsonResponse({}, status: 404);
        }),
      );
      return (client: client, capturedImportBody: () => capturedImportBody);
    }

    test('stamps every external_ref, re-imports, then writes every Part\'s own file', () async {
      final storage = _FakeStorageService();
      final routed = routedClient();
      final client = AssemblyDocumentClient(storageService: storage, documentApiClient: routed.client);

      final result = await client.saveAll(
        root,
        twoPartSession(),
        {'part-top': 'top.DIDSAprt', 'part-child': 'bracket_child.DIDSAprt'},
      );

      expect(result.hasFailures, isFalse);
      expect(result.savedRelativePaths, unorderedEquals(['top.DIDSAprt', 'bracket_child.DIDSAprt']));

      final importedTop = (routed.capturedImportBody()!['document']['parts'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == 'part-top');
      final importedOccurrence = (importedTop['occurrences'] as List).single as Map<String, dynamic>;
      expect(importedOccurrence['external_ref'], 'bracket_child.DIDSAprt');

      final writtenTop = jsonDecode(utf8.decode(storage.files['top.DIDSAprt']!)) as Map<String, dynamic>;
      final writtenOccurrence =
          ((writtenTop['document']['parts'] as List)[0] as Map)['occurrences'][0] as Map<String, dynamic>;
      expect(writtenOccurrence['external_ref'], 'bracket_child.DIDSAprt');
    });

    test('collects a per-Part StorageException without aborting the rest', () async {
      final storage = _FakeStorageService()..failOnWrite.add('bracket_child.DIDSAprt');
      final routed = routedClient();
      final client = AssemblyDocumentClient(storageService: storage, documentApiClient: routed.client);

      final result = await client.saveAll(
        root,
        twoPartSession(),
        {'part-top': 'top.DIDSAprt', 'part-child': 'bracket_child.DIDSAprt'},
      );

      expect(result.savedRelativePaths, ['top.DIDSAprt']);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.partId, 'part-child');
      expect(result.failures.single.relativePath, 'bracket_child.DIDSAprt');
    });
  });

  // §6 roadmap Phase 16 (`docs/assembly-scope.md` §2s): the spike this
  // phase's own roadmap entry called for - confirming gap `[22]`
  // ("composed multi-file part_ids are session-scoped only") isn't a real
  // defect. `AssemblyGraphComposer.compose`'s own maps
  // (`resolvedByPath`/`partIdByPath`) are local variables created fresh
  // inside `compose()` itself (`assembly_graph_composer.dart:94-97`) - no
  // instance-level cache carries anything between calls - so these tests
  // pin exactly that: calling `openAssembly` more than once on the same
  // `AssemblyDocumentClient`/`AssemblyGraphComposer` instance never leaks
  // state from an earlier call into a later one.
  group('Phase 16: multi-file part-id/path persistence spike', () {
    test('open, save, and reopen the same project in one session round-trips ids and paths', () async {
      final storage = _FakeStorageService();
      storage.put('bracket.didsa', _singlePartPayload(id: 'part-bracket', name: 'Bracket'));
      storage.put(
        'top.didsa',
        _singlePartPayload(id: 'part-top', name: 'Top', occurrences: [_occurrence('occ-1', 'bracket.didsa')]),
      );
      final tempDir = await Directory.systemTemp.createTemp('didsa_assembly_doc_client_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final documentApiClient = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/import/native')) {
            return _jsonResponse({'document_id': 'doc-1', 'part_ids': ['part-top', 'part-bracket']});
          }
          if (request.method == 'GET' && request.url.path.endsWith('/export/native')) {
            final partId = request.url.queryParameters['part_id'];
            final payload = partId == 'part-bracket'
                ? _singlePartPayload(id: 'part-bracket', name: 'Bracket')
                : _singlePartPayload(
                    id: 'part-top',
                    name: 'Top',
                    occurrences: [_occurrence('occ-1', 'bracket.didsa')],
                  );
            return _jsonResponse(payload);
          }
          return _jsonResponse({}, status: 404);
        }),
      );
      final client = AssemblyDocumentClient(
        storageService: storage,
        documentApiClient: documentApiClient,
        composer: AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: tempDir)),
      );

      final firstOpen = await client.openAssembly(root, 'top.didsa');

      // Simulate "edit, then Save All" happening in between the two opens.
      await client.saveAll(
        root,
        {
          'schema_version': 1,
          'document': {
            'id': 'doc-1',
            'root_part_id': 'part-top',
            'parts': [
              {
                'id': 'part-top',
                'name': 'Top',
                'features': [],
                'occurrences': [_occurrence('occ-1', 'bracket.didsa')],
                'mates': [],
              },
              {'id': 'part-bracket', 'name': 'Bracket', 'features': [], 'occurrences': [], 'mates': []},
            ],
          },
          'sketches': [],
        },
        firstOpen.relativePathByPartId,
      );

      final secondOpen = await client.openAssembly(root, 'top.didsa');

      expect(secondOpen.rootPartId, firstOpen.rootPartId);
      expect(secondOpen.relativePathByPartId, firstOpen.relativePathByPartId);
      expect(secondOpen.staleRelativePaths, isEmpty);
    });

    test('opening project B after project A cleanly supersedes it - no leaked state', () async {
      final storage = _FakeStorageService();
      storage.put('a.didsa', _singlePartPayload(id: 'part-a', name: 'A'));
      storage.put('b.didsa', _singlePartPayload(id: 'part-b', name: 'B'));
      final tempDir = await Directory.systemTemp.createTemp('didsa_assembly_doc_client_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      final importBodies = <Map<String, dynamic>>[];
      final documentApiClient = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.method == 'POST' && request.url.path.endsWith('/import/native')) {
            importBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _jsonResponse({'document_id': 'doc-1', 'part_ids': ['part-a']});
          }
          return _jsonResponse({}, status: 404);
        }),
      );
      final client = AssemblyDocumentClient(
        storageService: storage,
        documentApiClient: documentApiClient,
        composer: AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: tempDir)),
      );

      final openedA = await client.openAssembly(root, 'a.didsa');
      final openedB = await client.openAssembly(root, 'b.didsa');

      expect(openedA.relativePathByPartId, {'part-a': 'a.didsa'});
      // The second `openAssembly` call's own result must not carry over
      // project A's Part id - `compose`'s maps start empty every call.
      expect(openedB.relativePathByPartId, {'part-b': 'b.didsa'});

      expect(importBodies, hasLength(2));
      final secondImportPartIds = (importBodies[1]['document']['parts'] as List)
          .cast<Map<String, dynamic>>()
          .map((p) => p['id']);
      // `import_native` is a full replace (`AssemblyDocumentClient
      // .openAssembly`'s own doc comment) - the second call's own payload
      // carries only project B's Part, confirming no accidental merge.
      expect(secondImportPartIds, ['part-b']);
    });
  });
}
