// The shape-proposal vectors (docs/motion/sketch-shape-vectors.json; spec: docs/motion/sketch-projector-spec.md section 13),
// checked from the file alone: every hybrid frame's written-back positions are the projector's answer to the frame's proposal
// and provisional sizes (the call of spec 13.4), and every plain frame writes back exactly its proposal. The regeneration
// itself (the proposals, from the controller's own drag code) is compared with the file by the "shape proposal vectors (F6)"
// group of sketch_controller_test.dart. tools/sketch_vectors/export_shapes.sh [--check] runs both.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/sketch_shape_vectors.dart';

void main() {
  final file = File(kShapeVectorsPath);
  final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = (doc['cases'] as List).cast<Map<String, dynamic>>();

  test('every shape family has a plain and a hybrid case, and a refused grab is covered', () {
    final plain = <String>{}, hybrid = <String>{};
    for (final c in cases) {
      final input = c['input'] as Map<String, dynamic>;
      final grabbed = input['grabbed'] as String;
      final kinds = {
        for (final s in (input['shapes'] as Map<String, dynamic>).values)
          if (jsonEncode(s).contains('"$grabbed"')) s['kind'] as String,
      };
      for (final f in c['frames'] as List) {
        ((f['expected']['hybrid'] as bool) ? hybrid : plain).addAll(kinds);
      }
    }
    const families = {'circle', 'arc', 'ellipse', 'ellipse_arc', 'rectangle', 'polygon', 'slot'};
    expect(plain, containsAll(families));
    expect(hybrid, containsAll(families));
    expect(cases.where((c) => c['grab'] == false), isNotEmpty);
  });

  for (final c in cases) {
    test(c['id'] as String, () {
      final tolerance = (c['tolerance'] as num).toDouble();
      final frames = c['frames'] as List;
      if (c['grab'] == false) expect(frames, isEmpty);
      for (var k = 0; k < frames.length; k++) {
        final expected = frames[k]['expected'] as Map<String, dynamic>;
        final why = '${c['id']} frame $k';
        final result = shapePointsOf(expected['result']);
        final proposal = expected['proposal'] == null ? null : shapePointsOf(expected['proposal']);
        expect(proposal, isNotNull, reason: '$why: every frame here has a proposal');
        if (expected['hybrid'] != true) {
          expect(expected['provisional'], isEmpty, reason: why);
          expect(result.keys.toSet(), proposal!.keys.toSet(), reason: '$why: a plain frame writes back its proposal');
          for (final id in proposal.keys) {
            expect(result[id]!.$1, closeTo(proposal[id]!.$1, tolerance), reason: '$why: $id.x');
            expect(result[id]!.$2, closeTo(proposal[id]!.$2, tolerance), reason: '$why: $id.y');
          }
          continue;
        }
        if (expected['clamp'] != 'accepted') continue;
        final clamped = replayShapeClamp(c, k);
        expect(clamped, isNotNull, reason: '$why: the projector converges');
        for (final id in result.keys) {
          expect(clamped!.containsKey(id), isTrue, reason: '$why: $id is written back');
          expect(clamped[id]!.$1, closeTo(result[id]!.$1, tolerance), reason: '$why: $id.x');
          expect(clamped[id]!.$2, closeTo(result[id]!.$2, tolerance), reason: '$why: $id.y');
        }
      }
    });
  }
}
