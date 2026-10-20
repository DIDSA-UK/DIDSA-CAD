// Golden vectors for scene composition (`docs/scenes-scope.md` section 5, `docs/scenes/vectors.json`).
//
// The same JSON gates the backend's reference (`backend/app/document/scene_compose.py`) and DIDSA-VR's GDScript copy. Read from
// the repo root; nothing is copied here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/scene_compose.dart';

const String _vectorsPath = '../docs/scenes/vectors.json';

bool _sameRecord(Map a, Map b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    final x = a[key];
    final y = b[key];
    if (!b.containsKey(key)) return false;
    if (x is num && y is num ? (x - y).abs() > 1e-9 : x != y) return false;
  }
  return true;
}

void main() {
  late Map<String, dynamic> doc;

  setUpAll(() {
    final f = File(_vectorsPath);
    if (!f.existsSync()) fail('$_vectorsPath not found (run `flutter test` from client/)');
    doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  });

  test('every case composes as the reference does', () {
    final tol = (doc['tolerance'] as num).toDouble();
    final nodes = [for (final n in doc['nodes'] as List) Map<String, dynamic>.from(n as Map)];
    final model = doc['model'] as Map<String, dynamic>;
    final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThanOrEqualTo(6));
    final failures = <String>[];
    for (final c in cases) {
      final got = composeScene(nodes, model, doc['root'] as String, c['scene'] as Map<String, dynamic>?);
      final expected = c['expected'] as Map<String, dynamic>;
      expect(got.keys.toSet(), expected.keys.toSet(), reason: c['name'] as String);
      for (final path in expected.keys) {
        final want = expected[path] as Map<String, dynamic>;
        final node = got[path]!;
        final wb = want['world']['basis'] as List;
        final wo = want['world']['origin'] as List;
        for (var r = 0; r < 3; r++) {
          if ((node.world.origin[r] - (wo[r] as num)).abs() > tol) failures.add('${c['name']} $path origin');
          for (var k = 0; k < 3; k++) {
            if ((node.world.basis[r][k] - (wb[r][k] as num)).abs() > tol) failures.add('${c['name']} $path basis');
          }
        }
        if (node.hidden != want['hidden']) failures.add('${c['name']} $path hidden');
        if (!_sameRecord(node.appearance, want['appearance'] as Map)) failures.add('${c['name']} $path appearance ${node.appearance}');
        final bodies = want['bodies'] as Map;
        for (final b in bodies.keys) {
          if (!_sameRecord(node.bodies[b] ?? const {}, bodies[b] as Map)) failures.add('${c['name']} $path body $b');
        }
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('the nearest scene hidden decides, null when the scene says nothing', () {
    final flags = {'frame': true, 'frame/barB': false};
    expect(sceneHiddenDecision('frame/barA', flags), isTrue);
    expect(sceneHiddenDecision('frame/barB', flags), isFalse);
    expect(sceneHiddenDecision('bolt', flags), isNull);
    expect(parentPath(''), isNull);
    expect(parentPath('bolt#pattern:p1:1'), '');
    expect(parentPath('a/b/c'), 'a/b');
  });
}
