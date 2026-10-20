// Golden vectors for the Appearance tool's resolution rule (`docs/appearance-tool-scope.md` D3, `docs/appearance/vectors.json`).
//
// The same JSON gates the backend's reference (`backend/app/document/appearance.py`) and DIDSA-VR's GDScript copy. It is read
// from the repo root so a regenerated file is picked up; nothing is copied here.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/appearance/appearance_rule.dart';

const String _vectorsPath = '../docs/appearance/vectors.json';

late Map<String, dynamic> _doc;

bool _sameRecord(Map a, Map b) {
  if (a.length != b.length) return false;
  for (final key in a.keys) {
    if (!b.containsKey(key)) return false;
    final x = a[key];
    final y = b[key];
    if (x is num && y is num) {
      if ((x - y).abs() > 1e-9) return false;
    } else if (x != y) {
      return false;
    }
  }
  return true;
}

void main() {
  setUpAll(() {
    final f = File(_vectorsPath);
    if (!f.existsSync()) fail('$_vectorsPath not found (run `flutter test` from client/)');
    _doc = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  });

  test('the record has the reference fields', () {
    expect(kAppearanceFields, (_doc['fields'] as List).cast<String>());
  });

  test('every case resolves as the reference does', () {
    final cases = (_doc['cases'] as List).cast<Map<String, dynamic>>();
    expect(cases.length, greaterThanOrEqualTo(57));
    final models = _doc['models'] as Map<String, dynamic>;
    final failures = <String>[];
    for (final c in cases) {
      final model = models[c['model']] as Map<String, dynamic>;
      final scene = (c['scene_overrides'] as List?)?.map((o) => Map<String, dynamic>.from(o as Map)).toList();
      final got = resolveAppearance(model, c['root'] as String, (c['path'] as List).cast<String>(),
          bodyId: c['body_id'] as String?, faceIndex: (c['face_index'] as num?)?.toInt(), sceneOverrides: scene);
      if (!_sameRecord(got, c['expected'] as Map)) failures.add('${c['name']}: got $got, want ${c['expected']}');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('resolveFaces agrees with resolveAppearance face by face', () {
    final models = _doc['models'] as Map<String, dynamic>;
    var compared = 0;
    for (final c in (_doc['cases'] as List).cast<Map<String, dynamic>>()) {
      if (c['body_id'] == null) continue;
      final model = models[c['model']] as Map<String, dynamic>;
      final path = (c['path'] as List).cast<String>();
      final scene = (c['scene_overrides'] as List?)?.map((o) => Map<String, dynamic>.from(o as Map)).toList();
      final faces = [for (var i = 0; i < 6; i++) (c['body_id'] as String, i)];
      final many = resolveFaces(model, c['root'] as String, path, faces, sceneOverrides: scene);
      for (final (body, index) in faces) {
        final one = resolveAppearance(model, c['root'] as String, path, bodyId: body, faceIndex: index, sceneOverrides: scene);
        expect(_sameRecord(many['$body|$index']!, one), isTrue, reason: '${c['name']} face $index');
        compared++;
      }
    }
    expect(compared, greaterThan(0));
  });

  test('the record checks match the backend', () {
    expect(appearanceErrors({'colour': '#12AB34'}), isEmpty);
    expect(appearanceErrors({}), ['an appearance must set at least one field']);
    expect(appearanceErrors({'colour': 'red'}), ["colour must be '#RRGGBB'"]);
    expect(appearanceErrors({'opacity': 1.5}), ['opacity must be a number from 0 to 1']);
    expect(appearanceErrors({'emission_strength': 11}), ['emission_strength must be a number from 0 to 10']);
    expect(appearanceErrors({'shine': 1}), contains("unknown appearance field 'shine'"));
  });
}
