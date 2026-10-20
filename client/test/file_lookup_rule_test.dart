// Golden vectors for the moved-file lookup rule (`docs/moved-files-scope.md` section 2, `docs/file-lookup/vectors.json`).
//
// The same JSON gates the backend's reference (`backend/app/document/file_lookup.py`) and DIDSA-VR's GDScript copy. It is read from
// the repo root so a regenerated file is picked up; nothing is copied here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/file_lookup_rule.dart';

const String _vectorsPath = '../docs/file-lookup/vectors.json';

IndexedFile? _file(Map? raw) => raw == null ? null : IndexedFile(raw['path'] as String, raw['part_id'] as String?);

void main() {
  late Map<String, dynamic> doc;

  setUpAll(() {
    final f = File(_vectorsPath);
    if (!f.existsSync()) fail('$_vectorsPath not found (run `flutter test` from client/)');
    doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  });

  test('every case is answered as the reference answers it', () {
    final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThanOrEqualTo(16));
    final failures = <String>[];
    for (final c in cases) {
      final reference = c['reference'] as Map<String, dynamic>;
      final got = findFile(
        externalRef: (reference['external_ref'] as String?) ?? '',
        refPartId: reference['ref_part_id'] as String?,
        atPath: _file(c['at_path'] as Map?),
        index: [for (final e in (c['index'] as List)) _file(e as Map)!],
      );
      final want = c['expected'] as Map<String, dynamic>;
      final gotMap = {
        'result': got.result.name,
        'path': got.path,
        'via': got.via?.name,
        'candidates': got.candidates,
        'path_mismatch': got.pathMismatch,
      };
      if (jsonEncode(gotMap) != jsonEncode({for (final k in gotMap.keys) k: want[k]})) {
        failures.add('${c['name']}: got $gotMap, want $want');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('name keys set the native extension, letter case and folders aside', () {
    expect(lookupNameKey('parts/Bracket.didsa'), 'bracket');
    expect(lookupNameKey('old/bracket.DIDSAprt'), 'bracket');
    expect(lookupNameKey(r'old\Bracket.DIDSACAD'), 'bracket');
    expect(lookupNameKey('Bracket'), 'bracket');
  });
}
