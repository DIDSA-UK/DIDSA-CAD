import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Archive, ArchiveFile, ZipEncoder;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_bundle.dart';
import 'package:didsa_cad_client/ai/ai_plan_export.dart';
import 'package:didsa_cad_client/ai/ai_plan_split.dart';
import 'package:didsa_cad_client/ai/ai_plan_translator.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

/// Sub-assemblies in one imported zip: the manifest's `sub_assemblies`, one assembly plan per sub-assembly before
/// `99_assembly.json`, a top level that places a saved sub-assembly by its type prefix, and mates that name a part inside
/// it by a path of local ids.

Uint8List _zip(Map<String, Object> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(jsonEncode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Object> _plan(String id) => {
      'version': 1,
      'steps': [
        {'local_id': id, 'kind': 'sketch', 'plane': 'XY'},
      ],
    };

Map<String, Object> _castorZip({bool withSubAssemblyInManifest = true}) => {
      '00_manifest.json': {
        'kind': 'part_manifest',
        'parts': [
          {'name': 'Bracket', 'type_prefix': 'BRACKET', 'summary': ''},
          {'name': 'Wheel', 'type_prefix': 'WHEEL', 'summary': ''},
          {'name': 'Bush', 'type_prefix': 'BUSH', 'summary': ''},
        ],
        if (withSubAssemblyInManifest)
          'sub_assemblies': [
            {'name': 'Wheel and bush', 'type_prefix': 'WHEEL_ASM', 'summary': 'the wheel on its bush'},
          ],
      },
      '01_BRACKET.json': _plan('bracket_sketch'),
      '02_WHEEL.json': _plan('wheel_sketch'),
      '03_BUSH.json': _plan('bush_sketch'),
      '90_WHEEL_ASM.json': {
        'version': 1,
        'steps': [
          {'local_id': 'bush', 'kind': 'add_component', 'relative_path': 'BUSH_001.didsa'},
          {'local_id': 'wheel', 'kind': 'add_component', 'relative_path': 'WHEEL_001.didsa'},
          {
            'local_id': 'm1',
            'kind': 'mate',
            'type': 'concentric',
            'references': [
              {'occurrence_id': 'bush', 'face_selector': {'cylinder_radius': 6}},
              {'occurrence_id': 'wheel', 'face_selector': {'cylinder_radius': 6}},
            ],
          },
        ],
      },
      '99_assembly.json': {
        'version': 1,
        'steps': [
          {'local_id': 'bracket', 'kind': 'add_component', 'relative_path': 'BRACKET_001.didsa'},
          {'local_id': 'castor', 'kind': 'add_component', 'relative_path': 'WHEEL_ASM_001.didsa'},
          {'local_id': 'mv', 'kind': 'move_component', 'occurrence_id': 'castor', 'translation': [0, 0, -30]},
          {
            'local_id': 'm1',
            'kind': 'mate',
            'type': 'concentric',
            'references': [
              {'occurrence_id': 'bracket', 'face_selector': {'cylinder_radius': 4}},
              {'occurrence_id': 'castor/bush', 'face_selector': {'cylinder_radius': 4}},
            ],
          },
        ],
        'intended_motion': [
          {'component': 'castor/wheel', 'motion': 'spins on the bush'},
        ],
      },
    };

class _FakeStorageService implements StorageService {
  final Map<String, Uint8List> files = {};

  void put(String relativePath, Map<String, dynamic> payload) {
    files[relativePath] = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    if (!files.containsKey(relativePath)) return null;
    return DesktopFileHandle(root: root as DesktopProjectRoot, relativePath: relativePath, path: relativePath);
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async => files[handle.relativePath]!;

  @override
  Future<DateTime?> lastModified(FileHandle handle) async => DateTime(2026, 1, 1);

  @override
  Future<bool> exists(FileHandle handle) async => files.containsKey(handle.relativePath);

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async => files.keys.toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

Map<String, dynamic> _partFile(String partId, {List<Map<String, dynamic>> occurrences = const []}) => {
      'schema_version': 1,
      'document': {
        'id': 'doc-$partId',
        'root_part_id': partId,
        'parts': [
          {'id': partId, 'name': partId, 'features': [], 'occurrences': occurrences, 'mates': []},
        ],
      },
      'sketches': [],
    };

void main() {
  group('AiPlanBundle with sub_assemblies', () {
    test('the assembly plans before the last are the sub-assemblies, in manifest order', () {
      final bundle = AiPlanBundle.fromZipBytes(_zip(_castorZip()));
      expect(bundle.manifest.subAssemblies.single.typePrefix, 'WHEEL_ASM');
      expect(bundle.subAssemblyJson, hasLength(1));
      expect(bundle.partPlans, hasLength(3));

      final sub = bundle.subAssemblyPlanFor(0, ['BRACKET_004.didsa', 'WHEEL_002.didsa', 'BUSH_009.didsa']);
      expect([for (final s in sub.steps.whereType<AiAddComponentStep>()) s.relativePath], ['BUSH_009.didsa', 'WHEEL_002.didsa']);

      final top = bundle.assemblyPlanFor(
        ['BRACKET_004.didsa', 'WHEEL_002.didsa', 'BUSH_009.didsa'],
        savedSubAssemblyPaths: ['WHEEL_ASM_003.didsa'],
      );
      expect([for (final s in top.steps.whereType<AiAddComponentStep>()) s.relativePath], ['BRACKET_004.didsa', 'WHEEL_ASM_003.didsa']);
    });

    test('assemblyComponents lists the parts inside a placed sub-assembly by path', () {
      final bundle = AiPlanBundle.fromZipBytes(_zip(_castorZip()));
      expect(
        [for (final c in bundle.assemblyComponents) '${c.localId}=${c.partName}'],
        ['bracket=Bracket', 'castor=Wheel and bush', 'castor/bush=Bush', 'castor/wheel=Wheel'],
      );
    });

    test('two assembly plans and no sub_assemblies in the manifest is a clear error, not a silent pick', () {
      expect(
        () => AiPlanBundle.fromZipBytes(_zip(_castorZip(withSubAssemblyInManifest: false))),
        throwsA(isA<AiPlanBundleException>().having((e) => e.message, 'message', contains('sub_assemblies'))),
      );
    });
  });

  test('a mate path through a placed sub-assembly is rewritten segment by segment', () {
    final bundle = AiPlanBundle.fromZipBytes(_zip(_castorZip()));
    final split = splitPlacementAndMates(bundle.assemblyPlanFor(['B.didsa', 'W.didsa', 'U.didsa'], savedSubAssemblyPaths: ['S.didsa']));
    final rewritten = rewriteMateOccurrenceIds(
      split.mates,
      {'bracket': 'occ-bracket', 'castor': 'occ-castor'},
      intendedMotion: split.intendedMotion,
      nested: {
        'castor': const PlacedComponentIds({'bush': 'occ-bush', 'wheel': 'occ-wheel'}),
      },
    );
    final refs = (rewritten.steps.single as AiMateStep).references.map((r) => r.occurrenceId);
    expect(refs, ['existing:occ-bracket', 'existing:occ-castor/occ-bush']);
    expect(rewritten.intendedMotion.single.component, 'existing:occ-castor/occ-wheel');

    // A path through a component that is not a sub-assembly, or to an unknown inner id, is left for validation.
    final untouched = rewriteMateOccurrenceIds(split.mates, {'bracket': 'occ-bracket', 'castor': 'occ-castor'});
    expect((untouched.steps.single as AiMateStep).references.last.occurrenceId, 'castor/bush');
  });

  test('the Assembly-mode hand-off asks for sub-assemblies in the same zip, mated by path', () {
    final package = buildExternalHandoffPackage(systemPrompt: 'SYSTEM', transcript: const [], assemblyMode: true);
    expect(package, contains('"sub_assemblies"'));
    expect(package, contains('90_<TYPE_PREFIX>.json'));
    expect(package, contains('do not split it into'));
    expect(package, contains('"castor/wheel"'));
  });

  test('add_component of a sub-assembly file brings in the parts it places', () async {
    final storage = _FakeStorageService()
      ..put('WHEEL_001.didsa', _partFile('part-wheel'))
      ..put('BUSH_001.didsa', _partFile('part-bush'))
      ..put('WHEEL_ASM_001.didsa', _partFile('part-castor', occurrences: [
        {'id': 'occ-bush', 'external_ref': 'BUSH_001.didsa', 'ref_part_id': 'part-bush', 'name_override': null},
        {'id': 'occ-wheel', 'external_ref': 'WHEEL_001.didsa', 'ref_part_id': 'part-wheel', 'name_override': null},
      ]));
    Map<String, dynamic>? imported;
    final mock = MockClient((request) async {
      http.Response json(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});
      if (request.url.path == '/document/parts/part-top/ai-plan/validate') {
        return json({
          'results': [
            {'local_id': 'castor', 'ok': true, 'warnings': [], 'error': null},
          ],
        });
      }
      if (request.method == 'GET' && request.url.path == '/document/export/native') return json(_partFile('part-top'));
      if (request.method == 'POST' && request.url.path == '/document/import/native') {
        imported = jsonDecode(request.body) as Map<String, dynamic>;
        return json({'document_id': 'doc-top', 'part_ids': []});
      }
      return http.Response('not found', 404);
    });
    const root = DesktopProjectRoot('/fake/project');
    final result = await PlanTranslator(
      documentApi: DocumentApiClient(httpClient: mock),
      sketchApi: SketchApiClient(httpClient: mock),
      storageService: storage,
      projectRoot: root,
      composer: AssemblyGraphComposer(
        storageService: storage,
        fileCache: FileCache(cacheDirectory: Directory.systemTemp.createTempSync('didsa_sub_asm_test_')),
      ),
    ).execute(
      plan: AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'castor', 'kind': 'add_component', 'relative_path': 'WHEEL_ASM_001.didsa'},
        ],
      }),
      partId: 'part-top',
    );

    expect(result.outcome, PlanTranslationOutcome.success, reason: result.errorMessage);
    final parts = ((imported!['document'] as Map)['parts'] as List).cast<Map<String, dynamic>>();
    final ids = {for (final p in parts) p['id']};
    expect(ids, containsAll(['part-top', 'part-castor', 'part-wheel', 'part-bush']));
    final castor = parts.firstWhere((p) => p['id'] == 'part-castor');
    for (final occurrence in (castor['occurrences'] as List).cast<Map<String, dynamic>>()) {
      expect(ids, contains(occurrence['resolved_part_id']), reason: '${occurrence['id']} must resolve');
    }
    // The inner occurrence ids are kept: a top-level mate names them by path.
    expect([for (final o in castor['occurrences'] as List) o['id']], ['occ-bush', 'occ-wheel']);
  });
}
