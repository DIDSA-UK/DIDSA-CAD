// Finding moved files (`docs/moved-files-scope.md`, F3): the composer finds a referenced file by its Part id when the path misses
// or holds another file. Mirrors DIDSA-VR's `tests/moved_files.gd`, case by case.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/project_file_index.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> files = {};
  final Map<String, DateTime> modified = {};
  final Set<String> unreadable = {};
  int listCalls = 0;
  int reads = 0;
  var _clock = 0;

  void put(String relativePath, Map<String, dynamic> payload) {
    files[relativePath] = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    modified[relativePath] = DateTime(2026, 1, 1).add(Duration(seconds: _clock++));
  }

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) => throw UnimplementedError();

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() => throw UnimplementedError();

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!files.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    reads++;
    if (unreadable.contains(handle.relativePath) || !files.containsKey(handle.relativePath)) {
      throw StorageException('Failed to read ${handle.relativePath}');
    }
    return files[handle.relativePath]!;
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes) async {
    put(relativePath, jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => modified[handle.relativePath];

  @override
  Future<bool> exists(FileHandle handle) async => files.containsKey(handle.relativePath);

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    listCalls++;
    return files.keys.toList();
  }

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) =>
      throw UnimplementedError();
}

Map<String, dynamic> _part(String id, {List<Map<String, dynamic>> occurrences = const []}) => {
      'schema_version': 1,
      'document': {
        'id': 'doc-$id',
        'root_part_id': id,
        'parts': [
          {'id': id, 'name': id, 'features': [], 'occurrences': occurrences, 'mates': []},
        ],
      },
      'sketches': [],
    };

Map<String, dynamic> _occ(String id, String ref, {String? refPartId, String? resolvedPartId}) => {
      'id': id,
      'external_ref': ref,
      'name_override': null,
      'transform': {
        'translation': [0.0, 0.0, 0.0],
        'rotation_axis': [0.0, 0.0, 1.0],
        'rotation_angle_degrees': 0.0,
      },
      'suppressed': false,
      'hidden': false,
      if (refPartId != null) 'ref_part_id': refPartId,
      if (resolvedPartId != null) 'resolved_part_id': resolvedPartId,
    };

Map<String, dynamic> _occurrenceOf(ComposedAssemblyGraph graph, String partId, String occurrenceId) {
  final parts = (graph.documentPayload['document']['parts'] as List).cast<Map<String, dynamic>>();
  final part = parts.firstWhere((p) => p['id'] == partId);
  return (part['occurrences'] as List).cast<Map<String, dynamic>>().firstWhere((o) => o['id'] == occurrenceId);
}

ReferenceReport _reportFor(ComposedAssemblyGraph graph, String occurrenceId) =>
    graph.references.firstWhere((r) => r.occurrenceId == occurrenceId);

void main() {
  late _FakeStorageService storage;
  late AssemblyGraphComposer composer;
  late DesktopProjectRoot root;

  setUp(() {
    storage = _FakeStorageService();
    final tempDir = Directory.systemTemp.createTempSync('didsa_moved_files_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    composer = AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: tempDir));
    root = const DesktopProjectRoot('/fake/project');
  });

  group('a reference whose file moved', () {
    setUp(() {
      storage.put('parts/frames/Frame_A.didsa', _part('frame'));
      storage.put('parts/Bolt (renamed).didsa', _part('bolt'));
      storage.put('moved/Seeded.didsa', _part('seeded'));
      storage.put(
        'root.didsa',
        _part(
          'root',
          occurrences: [
            _occ('o-frame', 'Frame_A.didsa', refPartId: 'frame'),
            _occ('o-bolt', 'Bolt.didsa', refPartId: 'bolt'),
            // A file saved before ref_part_id existed: the id it was saved with.
            _occ('o-seeded', 'Seeded.didsa', resolvedPartId: 'seeded'),
          ],
        ),
      );
    });

    test('is found by its part id; the corrected path is in the session, and reported', () async {
      final graph = await composer.compose(root, 'root.didsa');

      final frame = _occurrenceOf(graph, 'root', 'o-frame');
      expect(frame['resolved_part_id'], 'frame');
      expect(frame['external_ref'], 'parts/frames/Frame_A.didsa');
      expect(graph.relativePathByPartId['frame'], 'parts/frames/Frame_A.didsa');
      final bolt = _occurrenceOf(graph, 'root', 'o-bolt');
      expect(bolt['resolved_part_id'], 'bolt');
      expect(bolt['external_ref'], 'parts/Bolt (renamed).didsa');
      final seeded = _occurrenceOf(graph, 'root', 'o-seeded');
      expect(seeded['resolved_part_id'], 'seeded');
      expect(seeded['external_ref'], 'moved/Seeded.didsa');

      expect(graph.references, hasLength(3));
      expect(graph.references.every((r) => r.outcome == ReferenceOutcome.movedById && !r.needsYou), isTrue);
      final report = _reportFor(graph, 'o-frame');
      expect(report.requestedPath, 'Frame_A.didsa');
      expect(report.foundPath, 'parts/frames/Frame_A.didsa');
      expect(report.parentPartId, 'root');
      expect(report.parentPath, 'root.didsa');
      expect(referenceSummary(graph.references), '3 files were found in new places');
    });

    test('is found before the stale cached copy is used (the cache is not touched)', () async {
      // Warm the cache for the old path, then let the file vanish from it.
      storage.put('Frame_A.didsa', _part('frame'));
      await composer.compose(root, 'root.didsa');
      storage.files.remove('Frame_A.didsa');

      final graph = await composer.compose(root, 'root.didsa');

      expect(graph.staleRelativePaths, isEmpty);
      expect(_occurrenceOf(graph, 'root', 'o-frame')['external_ref'], 'parts/frames/Frame_A.didsa');
    });
  });

  group('a reference that stays unresolved, with the reason', () {
    setUp(() {
      storage.put('left/Leg.didsa', _part('leg'));
      storage.put('right/Leg.didsa', _part('leg'));
      storage.put('Plate.didsa', _part('not-the-plate'));
      storage.put('old/Washer.didsa', _part('washer-somewhere'));
      storage.put(
        'root.didsa',
        _part(
          'root',
          occurrences: [
            _occ('o-leg', 'Leg.didsa', refPartId: 'leg'),
            _occ('o-plate', 'Plate.didsa', refPartId: 'plate'),
            _occ('o-washer', 'Washer.didsa'),
            _occ('o-gone', 'Gone.didsa', refPartId: 'gone'),
          ],
        ),
      );
    });

    test('two copies with the id: ask, nothing loaded', () async {
      final graph = await composer.compose(root, 'root.didsa');

      final report = _reportFor(graph, 'o-leg');
      expect(report.outcome, ReferenceOutcome.ask);
      expect(report.candidates, ['left/Leg.didsa', 'right/Leg.didsa']);
      expect(_occurrenceOf(graph, 'root', 'o-leg').containsKey('resolved_part_id'), isFalse);
      expect(graph.relativePathByPartId.values, isNot(contains('left/Leg.didsa')));
    });

    test('a file at the path with another id is a suggestion, never used', () async {
      final graph = await composer.compose(root, 'root.didsa');

      final report = _reportFor(graph, 'o-plate');
      expect(report.outcome, ReferenceOutcome.suggest);
      expect(report.pathMismatch, isTrue);
      expect(report.candidates, ['Plate.didsa']);
      expect(_occurrenceOf(graph, 'root', 'o-plate').containsKey('resolved_part_id'), isFalse);
      expect(graph.documentPayload['document']['parts'], hasLength(1));
    });

    test('an older reference (no id) with the name elsewhere: a suggestion', () async {
      final graph = await composer.compose(root, 'root.didsa');

      final report = _reportFor(graph, 'o-washer');
      expect(report.outcome, ReferenceOutcome.suggest);
      expect(report.candidates, ['old/Washer.didsa']);
      expect(report.storedPartId, isNull);
      expect(_occurrenceOf(graph, 'root', 'o-washer').containsKey('resolved_part_id'), isFalse);
    });

    test('nothing with the id or the name: missing', () async {
      final graph = await composer.compose(root, 'root.didsa');

      final report = _reportFor(graph, 'o-gone');
      expect(report.outcome, ReferenceOutcome.missing);
      expect(report.candidates, isEmpty);
      expect(graph.references.where((r) => r.needsYou), hasLength(4));
      expect(referenceSummary(graph.references), '4 need you');
    });
  });

  group('references that need no lookup', () {
    test('a file at its path (with its id, or with no stored id) loads as before and builds no index', () async {
      storage.put('a.didsa', _part('a'));
      storage.put('b.didsa', _part('b'));
      storage.put(
        'root.didsa',
        _part('root', occurrences: [_occ('o-a', 'a.didsa', refPartId: 'a'), _occ('o-b', 'b.didsa')]),
      );

      final graph = await composer.compose(root, 'root.didsa');

      expect(graph.references, isEmpty);
      expect(storage.listCalls, 0);
      expect(_occurrenceOf(graph, 'root', 'o-a')['resolved_part_id'], 'a');
      expect(_occurrenceOf(graph, 'root', 'o-b')['resolved_part_id'], 'b');
    });

    test('a file at the path is kept when the reference has only an older resolved_part_id (a session id)', () async {
      storage.put('a.didsa', _part('a-on-disk'));
      storage.put(
          'root.didsa', _part('root', occurrences: [_occ('o-a', 'a.didsa', resolvedPartId: 'a-minted-in-a-session')]));

      final graph = await composer.compose(root, 'root.didsa');

      expect(graph.references, isEmpty);
      expect(_occurrenceOf(graph, 'root', 'o-a')['resolved_part_id'], 'a-on-disk');
    });

    test('the index is built once for a compose with several misses', () async {
      storage.put('x/A.didsa', _part('a'));
      storage.put('x/B.didsa', _part('b'));
      storage.put(
        'root.didsa',
        _part('root', occurrences: [_occ('o-a', 'A.didsa', refPartId: 'a'), _occ('o-b', 'B.didsa', refPartId: 'b')]),
      );

      await composer.compose(root, 'root.didsa');

      expect(storage.listCalls, 1);
    });
  });

  group('the stale cached copy', () {
    test('is still used, marked stale and reported, when nothing is found by id or name', () async {
      storage.put('bolt.didsa', _part('bolt'));
      storage.put('top.didsa', _part('top', occurrences: [_occ('o-1', 'bolt.didsa', refPartId: 'bolt')]));
      await composer.compose(root, 'top.didsa');
      storage.unreadable.add('bolt.didsa');

      final graph = await composer.compose(root, 'top.didsa');

      expect(graph.staleRelativePaths, contains('bolt.didsa'));
      expect(_occurrenceOf(graph, 'top', 'o-1')['resolved_part_id'], 'bolt');
      final report = _reportFor(graph, 'o-1');
      expect(report.staleCopy, isTrue);
      expect(report.outcome, ReferenceOutcome.missing);
    });
  });

  group('ids re-minted by the compose', () {
    test('the reference is saved with the id the file has on disk, so the next open reports nothing', () async {
      // Two different files that share an id (an old Save As copy that was edited).
      Map<String, dynamic> shared(String name) {
        final payload = _part('shared');
        (payload['document']['parts'] as List).single['name'] = name;
        return payload;
      }

      storage.put('a.didsa', shared('A'));
      storage.put('b.didsa', shared('B'));
      storage.put(
        'top.didsa',
        _part('top',
            occurrences: [_occ('o-a', 'a.didsa', refPartId: 'shared'), _occ('o-b', 'b.didsa', refPartId: 'shared')]),
      );
      final graph = await composer.compose(root, 'top.didsa');
      expect(graph.references, isEmpty);
      final idForB = graph.relativePathByPartId.entries.firstWhere((e) => e.value == 'b.didsa').key;
      expect(idForB, isNot('shared'));

      // Save the parent alone: b.didsa is still on disk with the old id, so the saved reference must say so.
      final topExport = {
        'schema_version': 1,
        'document': {
          'id': 'doc',
          'root_part_id': 'top',
          'parts': [
            {
              'id': 'top',
              'occurrences': [
                {..._occ('o-a', 'a.didsa'), 'ref_part_id': 'shared', 'resolved_part_id': 'shared'},
                {..._occ('o-b', 'b.didsa'), 'ref_part_id': idForB, 'resolved_part_id': idForB},
              ],
            },
          ],
        },
        'sketches': [],
      };
      final client = AssemblyDocumentClient(
        storageService: storage,
        composer: composer,
        documentApiClient: DocumentApiClient(
          httpClient: MockClient((request) async => _json(topExport)),
        ),
      );
      await client.savePart(root, 'top', 'top.didsa');

      final saved = jsonDecode(utf8.decode(storage.files['top.didsa']!)) as Map<String, dynamic>;
      final occurrences = (saved['document']['parts'][0]['occurrences'] as List).cast<Map<String, dynamic>>();
      expect(occurrences.map((o) => o['ref_part_id']), ['shared', 'shared']);
      expect(occurrences.any((o) => o.containsKey('resolved_part_id')), isFalse);

      // Opening it again finds both where they are, with nothing to report.
      final again = await composer.compose(root, 'top.didsa');
      expect(again.references, isEmpty);
    });

    test('an unresolved reference keeps its stored id when saved (it is what the file is looked for by)', () async {
      storage.put('Plate.didsa', _part('not-the-plate'));
      final export = {
        'schema_version': 1,
        'document': {
          'id': 'doc',
          'root_part_id': 'top',
          'parts': [
            {
              'id': 'top',
              'occurrences': [_occ('o-plate', 'Plate.didsa', refPartId: 'plate')],
            },
          ],
        },
        'sketches': [],
      };
      final client = AssemblyDocumentClient(
        storageService: storage,
        composer: composer,
        documentApiClient: DocumentApiClient(httpClient: MockClient((request) async => _json(export))),
      );

      await client.savePart(root, 'top', 'top.didsa');

      final saved = jsonDecode(utf8.decode(storage.files['top.didsa']!)) as Map<String, dynamic>;
      expect(saved['document']['parts'][0]['occurrences'][0]['ref_part_id'], 'plate');
    });

    test('Save All writes a file placed by another first', () async {
      storage.put('child.didsa', _part('child'));
      final export = {
        'schema_version': 1,
        'document': {
          'id': 'doc',
          'root_part_id': 'top',
          'parts': [
            {
              'id': 'top',
              'occurrences': [_occ('o-c', 'child.didsa', refPartId: 'child2', resolvedPartId: 'child2')],
            },
            {'id': 'child2', 'occurrences': <Map<String, dynamic>>[]},
          ],
        },
        'sketches': [],
      };
      final order = <String>[];
      final client = AssemblyDocumentClient(
        storageService: storage,
        composer: composer,
        documentApiClient: DocumentApiClient(
          httpClient: MockClient((request) async {
            if (request.method == 'POST') return _json({'document_id': 'd', 'part_ids': []});
            final partId = request.url.queryParameters['part_id']!;
            order.add(partId);
            final part = (export['document'] as Map)['parts'].firstWhere((p) => p['id'] == partId);
            return _json({
              ...export,
              'document': {
                ...(export['document'] as Map<String, dynamic>),
                'root_part_id': partId,
                'parts': [part],
              },
            });
          }),
        ),
      );

      // The parent is listed first; the child must still be written first.
      await client.saveAll(root, export, {'top': 'top.didsa', 'child2': 'child.didsa'});

      expect(order, ['child2', 'top']);
      final saved = jsonDecode(utf8.decode(storage.files['top.didsa']!)) as Map<String, dynamic>;
      expect(saved['document']['parts'][0]['occurrences'][0]['ref_part_id'], 'child2');
    });
  });

  group('the project index', () {
    test('lists native files with their root part ids, skipping dot-folders, and caches ids by modified time',
        () async {
      storage.put('a/One.didsa', _part('one'));
      storage.put('.hidden/Two.didsa', _part('two'));
      storage.put('notes.txt', {'x': 1});
      final index = ProjectFileIndex(storage);

      final first = await index.build(root);
      expect(first.map((e) => (e.path, e.partId)), [('a/One.didsa', 'one')]);
      final readsAfterFirst = storage.reads;

      await index.build(root);
      expect(storage.reads, readsAfterFirst, reason: 'an unchanged file is not read again');

      storage.put('a/One.didsa', _part('one-changed'));
      expect((await index.build(root)).single.partId, 'one-changed');
    });

    test('a file that cannot be read has no id', () async {
      storage.put('bad.didsa', _part('x'));
      storage.files['bad.didsa'] = Uint8List.fromList(utf8.encode('{not json'));
      storage.unreadable.add('also-bad.didsa');
      final index = ProjectFileIndex(storage);

      expect((await index.build(root)).single.partId, isNull);
      expect(await index.partIdAt(root, 'nowhere.didsa'), isNull);
    });
  });
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
