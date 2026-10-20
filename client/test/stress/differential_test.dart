// Differential fuzz: thousands of seeded random cases answered by the Python reference (tools/fuzz_differential/generate.py) must be
// answered identically by the Dart copies of the appearance rule and the moved-file lookup rule.
//
//   cd backend && PYTHONPATH=. python ../tools/fuzz_differential/generate.py /tmp/fuzz.json 7 1500
//   cd client && DIDSA_FUZZ_CASES=/tmp/fuzz.json flutter test test/stress/differential_test.dart
//
// Skipped without DIDSA_FUZZ_CASES. The same file can feed DIDSA-VR's GDScript copies.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/appearance_rule.dart';
import 'package:didsa_cad_client/assembly/file_lookup_rule.dart';

bool _same(Object? a, Object? b) {
  if (a is num && b is num) return (a - b).abs() < 1e-9;
  if (a is Map && b is Map) return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  if (a is List && b is List) return a.length == b.length && [for (var i = 0; i < a.length; i++) _same(a[i], b[i])].every((x) => x);
  return a == b;
}

void main() {
  final path = Platform.environment['DIDSA_FUZZ_CASES'];
  final skip = path == null ? 'set DIDSA_FUZZ_CASES to a file from tools/fuzz_differential/generate.py' : null;
  late Map<String, dynamic> doc;
  setUpAll(() {
    if (path != null) doc = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  });

  test('appearance resolution agrees with the reference on every random case, and resolveFaces agrees face by face', () {
    final cases = (doc['appearance'] as List).cast<Map<String, dynamic>>();
    final failures = <String>[];
    for (var n = 0; n < cases.length; n++) {
      final c = cases[n];
      final scene = (c['scene_overrides'] as List?)?.map((o) => Map<String, dynamic>.from(o as Map)).toList();
      final model = c['model'] as Map<String, dynamic>;
      final path = (c['path'] as List).cast<String>();
      final got = resolveAppearance(model, c['root'] as String, path,
          bodyId: c['body_id'] as String?, faceIndex: (c['face_index'] as num?)?.toInt(), sceneOverrides: scene);
      if (!_same(got, c['expected'])) failures.add('#$n appearance: got $got want ${c['expected']}');
      final faces = <(String, int)>[
        for (final k in (c['faces'] as Map).keys) (k.toString().split('|')[0], int.parse(k.toString().split('|')[1])),
      ];
      final many = resolveFaces(model, c['root'] as String, path, faces, sceneOverrides: scene);
      for (final entry in (c['faces'] as Map).entries) {
        if (!_same(many[entry.key], entry.value)) failures.add('#$n face ${entry.key}: got ${many[entry.key]} want ${entry.value}');
      }
      if (failures.length > 15) break;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: skip);

  test('file lookup agrees with the reference on every random case', () {
    final cases = (doc['lookup'] as List).cast<Map<String, dynamic>>();
    final failures = <String>[];
    IndexedFile? file(Map? m) => m == null ? null : IndexedFile(m['path'] as String, m['part_id'] as String?);
    for (var n = 0; n < cases.length; n++) {
      final c = cases[n];
      final reference = c['reference'] as Map<String, dynamic>;
      final got = findFile(
        externalRef: (reference['external_ref'] as String?) ?? '',
        refPartId: reference['ref_part_id'] as String?,
        atPath: file(c['at_path'] as Map?),
        index: [for (final e in (c['index'] as List)) file(e as Map)!],
      );
      final want = c['expected'] as Map<String, dynamic>;
      final mine = {'result': got.result.name, 'path': got.path, 'via': got.via?.name, 'candidates': got.candidates, 'path_mismatch': got.pathMismatch};
      if (!_same(mine, {for (final k in mine.keys) k: want[k]})) failures.add('#$n: got $mine want $want for ${jsonEncode(c)}');
      if (failures.length > 10) break;
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, skip: skip);
}
