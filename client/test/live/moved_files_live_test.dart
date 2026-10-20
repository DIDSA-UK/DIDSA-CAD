// Finding moved files (F3) against a RUNNING backend and real files on disk: real DesktopStorageService, real DocumentApiClient.
//
//   CAD_API_KEY=local-e2e-key uvicorn app.main:app --port 8000     (from backend/)
//   DIDSA_LIVE_BACKEND=http://127.0.0.1:8000 DIDSA_LIVE_KEY=local-e2e-key flutter test test/live/moved_files_live_test.dart
//
// Skipped when DIDSA_LIVE_BACKEND is not set, so the normal `flutter test` / CI run never needs a server. A plain `test()` (no widget
// binding) is used on purpose: the widget binding blocks real HTTP.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/config.dart';
import 'package:didsa_cad_client/storage/desktop_storage_service.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/project_root.dart';

final String? _url = Platform.environment['DIDSA_LIVE_BACKEND'];
final String _key = Platform.environment['DIDSA_LIVE_KEY'] ?? 'local-e2e-key';

Map<String, dynamic> _file(String id, {List<Map<String, dynamic>> occurrences = const [], String? name}) => {
      'schema_version': 1,
      'document': {
        'id': 'doc-$id',
        'root_part_id': id,
        'parts': [
          {'id': id, 'name': name ?? id, 'features': [], 'occurrences': occurrences, 'mates': []},
        ],
      },
      'sketches': [],
    };

Map<String, dynamic> _occ(String id, String ref, {String? refPartId}) => {
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
    };

void main() {
  late Directory dir;
  late DesktopProjectRoot root;
  late DocumentApiClient api;
  late AssemblyDocumentClient client;

  void write(String rel, Map<String, dynamic> payload) {
    final file = File('${dir.path}/$rel')..createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(payload));
  }

  Map<String, dynamic> read(String rel) =>
      jsonDecode(File('${dir.path}/$rel').readAsStringSync()) as Map<String, dynamic>;

  List<Map<String, dynamic>> occurrencesOf(Map<String, dynamic> file) =>
      ((file['document']['parts'] as List).single['occurrences'] as List).cast<Map<String, dynamic>>();

  Future<OpenedAssembly> open(String rel) => client.openAssembly(root, rel);

  /// Full-session Save All, the way PartScreen does it.
  Future<SaveAllResult> saveAll(OpenedAssembly opened) async =>
      client.saveAll(root, await api.exportNative(), opened.relativePathByPartId);

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({'server_url': _url ?? '', 'api_key': _key});
    await ApiConfig.load();
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('didsa_live_moved_');
    addTearDown(() => dir.deleteSync(recursive: true));
    root = DesktopProjectRoot(dir.path);
    api = DocumentApiClient();
    final storage = DesktopStorageService();
    final cache = Directory.systemTemp.createTempSync('didsa_live_cache_');
    addTearDown(() => cache.deleteSync(recursive: true));
    client = AssemblyDocumentClient(
      storageService: storage,
      documentApiClient: api,
      composer: AssemblyGraphComposer(storageService: storage, fileCache: FileCache(cacheDirectory: cache)),
    );
  });

  final skip = _url == null ? 'set DIDSA_LIVE_BACKEND to run against a backend' : null;

  test('a moved file is found by id, the session holds the new path, Save All writes it, and reopening reports nothing',
      () async {
    write('Frame.didsa', _file('frame'));
    write('root.didsa', _file('root', occurrences: [_occ('o-frame', 'Frame.didsa', refPartId: 'frame')]));

    final first = await open('root.didsa');
    expect(first.references, isEmpty);

    // The user moves the file outside the app.
    Directory('${dir.path}/parts/frames').createSync(recursive: true);
    File('${dir.path}/Frame.didsa').renameSync('${dir.path}/parts/frames/Frame.didsa');

    final moved = await open('root.didsa');
    expect(moved.references.single.outcome, ReferenceOutcome.movedById);
    expect(moved.references.single.foundPath, 'parts/frames/Frame.didsa');
    expect(moved.relativePathByPartId['frame'], 'parts/frames/Frame.didsa');

    // The live backend holds the occurrence resolved, pointing at the new path.
    final session = await api.exportNative();
    final rootPart =
        ((session['document']['parts'] as List).cast<Map<String, dynamic>>()).firstWhere((p) => p['id'] == 'root');
    final occurrence = (rootPart['occurrences'] as List).single as Map<String, dynamic>;
    expect(occurrence['external_ref'], 'parts/frames/Frame.didsa');
    expect(occurrence['resolved_part_id'], 'frame');
    expect(occurrence['ref_part_id'], 'frame');
    final occurrences = await api.listOccurrences('root');
    expect(occurrences.single.resolvedPartId, 'frame');

    // Nothing on disk changed yet; Save All writes the corrected path.
    expect(occurrencesOf(read('root.didsa')).single['external_ref'], 'Frame.didsa');
    final saved = await saveAll(moved);
    expect(saved.hasFailures, isFalse);
    final onDisk = occurrencesOf(read('root.didsa')).single;
    expect(onDisk['external_ref'], 'parts/frames/Frame.didsa');
    expect(onDisk['ref_part_id'], 'frame');

    final again = await open('root.didsa');
    expect(again.references, isEmpty);
    expect(again.relativePathByPartId['frame'], 'parts/frames/Frame.didsa');
  }, skip: skip);

  test(
      'a file at the path with another id stays unresolved, keeps its stored id through a save, and is never swapped in',
      () async {
    write('Plate.didsa', _file('not-the-plate'));
    write('root.didsa', _file('root', occurrences: [_occ('o-plate', 'Plate.didsa', refPartId: 'plate')]));

    final opened = await open('root.didsa');
    final report = opened.references.single;
    expect(report.outcome, ReferenceOutcome.suggest);
    expect(report.pathMismatch, isTrue);
    expect((await api.listOccurrences('root')).single.resolvedPartId, isNull);

    await client.savePart(root, 'root', 'root.didsa');
    expect(occurrencesOf(read('root.didsa')).single['ref_part_id'], 'plate',
        reason: 'the id it is looked for by survives a save');

    final again = await open('root.didsa');
    expect(again.references.single.outcome, ReferenceOutcome.suggest);
  }, skip: skip);

  test(
      'two files sharing an id are re-minted; saving the parent alone, then Save All, leaves nothing to report on reopen',
      () async {
    // A Save As copy made before ids were re-minted: both files carry id "shared".
    write('a.didsa', _file('shared', name: 'A'));
    write('b.didsa', _file('shared', name: 'B'));
    write(
      'top.didsa',
      _file('top',
          occurrences: [_occ('o-a', 'a.didsa', refPartId: 'shared'), _occ('o-b', 'b.didsa', refPartId: 'shared')]),
    );

    final opened = await open('top.didsa');
    expect(opened.references, isEmpty);
    expect(opened.relativePathByPartId.keys.toSet().length, 3,
        reason: 'the clash was re-minted into three distinct Parts');

    // Save the parent alone: b.didsa still has the old id on disk, and the parent must say so.
    await client.savePart(root, 'top', 'top.didsa');
    expect(occurrencesOf(read('top.didsa')).map((o) => o['ref_part_id']), ['shared', 'shared']);
    expect((await open('top.didsa')).references, isEmpty);

    // Save All writes the re-minted file with its new ids, the parent after it with those ids.
    final reopened = await open('top.didsa');
    final saved = await saveAll(reopened);
    expect(saved.hasFailures, isFalse);
    expect(read('b.didsa')['document']['root_part_id'], isNot(read('a.didsa')['document']['root_part_id']));
    final finalOpen = await open('top.didsa');
    expect(finalOpen.references, isEmpty);
    expect((await api.listOccurrences(finalOpen.rootPartId)).every((o) => o.resolvedPartId != null), isTrue);
  }, skip: skip);
}
