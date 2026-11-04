import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan_bundle.dart';
import 'package:didsa_cad_client/ai/ai_plan_export.dart';
import 'package:didsa_cad_client/ai/ai_plan_split.dart';
import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';

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

void main() {
  test('a single-part hand-off asks for one plan.json; an Assembly-mode one asks for the zip the importer reads', () {
    final single = buildExternalHandoffPackage(systemPrompt: 'SYSTEM', transcript: const []);
    expect(single, contains('plan.json'));
    expect(single, isNot(contains('00_manifest.json')));

    final assembly = buildExternalHandoffPackage(systemPrompt: 'SYSTEM', transcript: const [], assemblyMode: true);
    expect(assembly, contains('ONE .zip file'));
    expect(assembly, contains('00_manifest.json'));
    expect(assembly, contains('99_assembly.json'));
    expect(assembly, contains('<TYPE_PREFIX>_001.didsa'));
    expect(assembly, contains('SYSTEM'));
  });

  test('a zip laid out as the Assembly-mode hand-off describes is read by the importer, in manifest order', () {
    final bundle = AiPlanBundle.fromZipBytes(_zip({
      '00_manifest.json': {
        'kind': 'part_manifest',
        'parts': [
          {'name': 'Block', 'type_prefix': 'BLOCK', 'summary': 'a block'},
          {'name': 'Pin', 'type_prefix': 'PIN', 'summary': 'a pin'},
        ],
      },
      '01_BLOCK.json': _plan('block_sketch'),
      '02_PIN.json': _plan('pin_sketch'),
      '99_assembly.json': {
        'version': 1,
        'steps': [
          {'local_id': 'a1', 'kind': 'add_component', 'relative_path': 'BLOCK_001.didsa'},
          {'local_id': 'a2', 'kind': 'add_component', 'relative_path': 'PIN_001.didsa'},
          {'local_id': 'm2', 'kind': 'move_component', 'occurrence_id': 'a2', 'translation': [40, 25, 0]},
        ],
      },
    }));

    expect(bundle.manifest.parts.map((p) => p.name), ['Block', 'Pin']);
    expect(bundle.partPlans[0].steps.single.localId, 'block_sketch');
    expect(bundle.partPlans[1].steps.single.localId, 'pin_sketch');
    // The add_component paths follow the parts to wherever they were really saved.
    final assembly = bundle.assemblyPlanFor(['parts/BLOCK_003.didsa', 'parts/PIN_007.didsa']).toJson();
    final paths = [for (final s in assembly['steps'] as List) if (s['kind'] == 'add_component') s['relative_path']];
    expect(paths, ['parts/BLOCK_003.didsa', 'parts/PIN_007.didsa']);
  });

  test('the Assembly-mode hand-off asks for mates at the end of 99_assembly.json, by add_component local_id', () {
    final package = buildExternalHandoffPackage(systemPrompt: 'SYSTEM', transcript: const [], assemblyMode: true);
    expect(package, contains('at the END, the mate steps'));
    expect(package, contains('add_component'));
    expect(package, contains('face_selector'));
    // The old instruction that contradicted this is gone.
    expect(package, isNot(contains('Place parts only')));
    expect(package, isNot(contains('no mate steps')));
  });

  test('the hand-off package embeds the external assembly paragraphs, never the in-app "no mate steps yet" ones', () {
    final prompt = buildAiScopingSystemPrompt(assemblyMode: true, externalHandoff: true);
    expect(prompt, contains(assemblyModeExternalVocabularyText));
    expect(prompt, isNot(contains('No mate steps\nyet')));
    expect(prompt, isNot(contains('you are asked for the mates, with each')));
    expect(prompt, contains('99_assembly.json'));
    expect(prompt, contains('local_id of an add_component step'));
    // The in-app prompt keeps its own text.
    final inApp = buildAiScopingSystemPrompt(assemblyMode: true);
    expect(inApp, contains(assemblyModeVocabularyText));
    expect(inApp, isNot(contains('99_assembly.json')));
  });

  test('a zip with mates at the end of 99_assembly.json is read by the importer and splits into placements and mates', () {
    final bundle = AiPlanBundle.fromZipBytes(_zip({
      '00_manifest.json': {
        'kind': 'part_manifest',
        'parts': [
          {'name': 'Block', 'type_prefix': 'BLOCK', 'summary': 'a block'},
          {'name': 'Pin', 'type_prefix': 'PIN', 'summary': 'a pin'},
        ],
      },
      '01_BLOCK.json': _plan('block_sketch'),
      '02_PIN.json': _plan('pin_sketch'),
      '99_assembly.json': {
        'version': 1,
        'steps': [
          {'local_id': 'block', 'kind': 'add_component', 'relative_path': 'BLOCK_001.didsa'},
          {'local_id': 'pin', 'kind': 'add_component', 'relative_path': 'PIN_001.didsa'},
          {'local_id': 'mv', 'kind': 'move_component', 'occurrence_id': 'pin', 'translation': [40, 25, 0]},
          {
            'local_id': 'm1',
            'kind': 'mate',
            'type': 'concentric',
            'references': [
              {'occurrence_id': 'block', 'face_selector': {'cylinder_radius': 5}},
              {'occurrence_id': 'pin', 'face_selector': {'cylinder_radius': 5}},
            ],
          },
          {
            'local_id': 'm2',
            'kind': 'mate',
            'type': 'coincident',
            'references': [
              {'occurrence_id': 'block', 'face_selector': {'direction': '+z'}},
              {'occurrence_id': 'pin', 'face_selector': {'direction': '-z', 'near': [0, 0, 10]}},
            ],
          },
        ],
      },
    }));
    final plan = bundle.assemblyPlanFor(['BLOCK_001.didsa', 'PIN_001.didsa']);
    final split = splitPlacementAndMates(plan);
    expect(split.placement!.steps.map((s) => s.kind), ['add_component', 'add_component', 'move_component']);
    expect(split.mates.map((m) => m.localId), ['m1', 'm2']);
    final rewritten = rewriteMateOccurrenceIds(split.mates, {'block': 'occ-b', 'pin': 'occ-p'});
    expect((rewritten.steps.last as AiMateStep).references.map((r) => r.occurrenceId), ['existing:occ-b', 'existing:occ-p']);
  });
}
