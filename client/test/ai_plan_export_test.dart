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

  group('buildExternalMatesFixPackage', () {
    const components = [
      ExternalMatesComponent(localId: 'plate', partName: 'Mounting Plate', relativePath: 'PLATE_001.didsa'),
      ExternalMatesComponent(localId: 'pin', partName: 'Pin', relativePath: 'PIN_001.didsa'),
    ];

    test('every reason names the components by the zip\'s local ids and asks for mates.json', () {
      for (final reason in ExternalMatesFixReason.values) {
        final text = buildExternalMatesFixPackage(components: components, reason: reason, problems: 'PROBLEM TEXT');
        expect(text, contains('- `plate`: Mounting Plate (PLATE_001.didsa)'), reason: '$reason');
        expect(text, contains('- `pin`: Pin (PIN_001.didsa)'), reason: '$reason');
        expect(text, contains('`mates.json`'), reason: '$reason');
        expect(text, contains('Import mates'), reason: '$reason');
        expect(text, contains('face_selector'), reason: '$reason'); // the mates rules travel with it
        expect(text, contains('intended_motion'), reason: '$reason');
        // The whole system prompt does not: the fix chat already has it.
        expect(text, isNot(contains('## Final reply format')), reason: '$reason');
      }
    });

    test('no mates: asks for all of them', () {
      final text = buildExternalMatesFixPackage(components: components, reason: ExternalMatesFixReason.noMates);
      expect(text, contains('no mate steps'));
      expect(text, contains('ALL the mates'));
    });

    test('failed validation: none were built, so all of them are asked for again, with the failure text', () {
      final text = buildExternalMatesFixPackage(
        components: components,
        reason: ExternalMatesFixReason.failedValidation,
        problems: '- step "m1" (mate): no such face',
      );
      expect(text, contains('NONE of them were built'));
      expect(text, contains('Reply with ALL the mates, corrected'));
      expect(text, contains('- step "m1" (mate): no such face'));
    });

    test('partly built: the built ones stay and are not to be repeated', () {
      final text = buildExternalMatesFixPackage(
        components: components,
        reason: ExternalMatesFixReason.partlyBuilt,
        problems: 'mate m3 failed',
      );
      expect(text, contains('built and stay'));
      expect(text, contains('do not repeat the earlier ones'));
      expect(text, contains('mate m3 failed'));
    });

    test('components free: only the missing mates, with the free motions listed', () {
      final text = buildExternalMatesFixPackage(
        components: components,
        reason: ExternalMatesFixReason.componentsFree,
        problems: '- `pin` (Pin): free to slide along z',
      );
      expect(text, contains('The mates are built and stay'));
      expect(text, contains('ONLY the mates that are missing'));
      expect(text, contains('do not repeat the\nmates that already hold'));
      expect(text, contains('- `pin` (Pin): free to slide along z'));
    });
  });
}
