import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan_bundle.dart';

Uint8List _zip(Map<String, Object> files) {
  final archive = Archive();
  files.forEach((name, json) {
    final bytes = utf8.encode(jsonEncode(json));
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _manifest = {
  'kind': 'part_manifest',
  'parts': [
    {'name': 'Long Rail', 'type_prefix': 'LONG_RAIL', 'summary': ''},
    {'name': 'Post', 'type_prefix': 'POST', 'summary': ''},
  ],
};

Map<String, Object> _partPlan() => {
      'version': 1,
      'steps': [
        {'local_id': 'sk', 'kind': 'sketch', 'plane': 'XY'},
      ],
    };

Map<String, Object> _assemblyPlan() => {
      'version': 1,
      'steps': [
        {'local_id': 'c1', 'kind': 'add_component', 'relative_path': 'sub/LONG_RAIL_001.DIDSAprt'},
        {'local_id': 'c2', 'kind': 'add_component', 'relative_path': 'POST_001.DIDSAprt'},
        {'local_id': 'c3', 'kind': 'add_component', 'relative_path': 'POST_001.DIDSAprt'},
        {'local_id': 'c4', 'kind': 'add_component', 'relative_path': 'OTHER_001.DIDSAprt'},
      ],
    };

void main() {
  test('parses manifest, part plans in file order, and assembly', () {
    final bundle = AiPlanBundle.fromZipBytes(_zip({
      '05_ASSEMBLY_plan.json': _assemblyPlan(),
      '02_POST_plan.json': _partPlan(),
      '00_part_manifest.json': _manifest,
      '01_LONG_RAIL_plan.json': _partPlan(),
    }));
    expect(bundle.manifest.parts.map((p) => p.typePrefix), ['LONG_RAIL', 'POST']);
    expect(bundle.partPlans, hasLength(2));
  });

  test('assemblyPlanFor repoints references at the saved paths and leaves unknown ones', () {
    final bundle = AiPlanBundle.fromZipBytes(_zip({
      '00_part_manifest.json': _manifest,
      '01_a.json': _partPlan(),
      '02_b.json': _partPlan(),
      '03_assembly.json': _assemblyPlan(),
    }));
    final paths = bundle.assemblyPlanFor(['LONG_RAIL_004.DIDSAprt', 'POST_002.DIDSAprt']).steps.map((s) => s.toJson()['relative_path']);
    expect(paths, ['LONG_RAIL_004.DIDSAprt', 'POST_002.DIDSAprt', 'POST_002.DIDSAprt', 'OTHER_001.DIDSAprt']);
  });

  test('rejects a part-count mismatch, a missing assembly, and a non-zip', () {
    expect(
      () => AiPlanBundle.fromZipBytes(_zip({'0.json': _manifest, '1.json': _partPlan(), '2.json': _assemblyPlan()})),
      throwsA(isA<AiPlanBundleException>()),
    );
    expect(
      () => AiPlanBundle.fromZipBytes(_zip({'0.json': _manifest, '1.json': _partPlan(), '2.json': _partPlan()})),
      throwsA(isA<AiPlanBundleException>()),
    );
    expect(() => AiPlanBundle.fromZipBytes(Uint8List.fromList([1, 2, 3])), throwsA(isA<AiPlanBundleException>()));
  });
}
