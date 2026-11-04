import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan_bundle.dart';
import 'package:didsa_cad_client/ai/ai_plan_export.dart';

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
}
