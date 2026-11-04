import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_split.dart';

AiGenerationPlan _plan(List<Map<String, dynamic>> steps) => AiGenerationPlan.fromJson({'version': 1, 'steps': steps});

Map<String, dynamic> _add(String id, String path) => {'local_id': id, 'kind': 'add_component', 'relative_path': path};

Map<String, dynamic> _mate(String id, String a, String b, {Map<String, dynamic>? extraB}) => {
      'local_id': id,
      'kind': 'mate',
      'type': 'coincident',
      'references': [
        {'occurrence_id': a, 'face_selector': {'direction': '+z'}},
        {'occurrence_id': b, 'face_selector': {'direction': '-z'}, ...?extraB},
      ],
    };

void main() {
  group('splitPlacementAndMates', () {
    test('takes the mate steps out, keeping both lists in their original order', () {
      final plan = _plan([
        _add('plate', 'PLATE_001.didsa'),
        _mate('m1', 'plate', 'pin'),
        _add('pin', 'PIN_001.didsa'),
        {'local_id': 'mv', 'kind': 'move_component', 'occurrence_id': 'pin', 'translation': [1, 2, 3]},
        _mate('m2', 'pin', 'plate'),
      ]);
      final split = splitPlacementAndMates(plan);
      expect(split.placement!.steps.map((s) => s.localId), ['plate', 'pin', 'mv']);
      expect(split.mates.map((s) => s.localId), ['m1', 'm2']);
    });

    test('a plan without mates comes back whole; a plan of only mates has no placement', () {
      final noMates = _plan([_add('a', 'A_001.didsa')]);
      expect(splitPlacementAndMates(noMates).mates, isEmpty);
      expect(splitPlacementAndMates(noMates).placement!.steps, hasLength(1));
      expect(splitPlacementAndMates(_plan([_mate('m', 'x', 'y')])).placement, isNull);
    });
  });

  group('rewriteMateOccurrenceIds', () {
    test('an add_component local_id becomes existing:<real id>; face selectors and values survive', () {
      final split = splitPlacementAndMates(_plan([
        _add('plate', 'PLATE_001.didsa'),
        _add('pin', 'PIN_001.didsa'),
        {
          'local_id': 'm1',
          'kind': 'mate',
          'type': 'distance',
          'value': 5,
          'references': [
            {'occurrence_id': 'plate', 'face_selector': {'normal': [0, 0.6, 0.8]}},
            {'occurrence_id': 'pin', 'face_selector': {'cylinder_radius': 4, 'near': [0, 0, 1]}},
          ],
        },
      ]));
      final rewritten = rewriteMateOccurrenceIds(split.mates, {'plate': 'occ-1', 'pin': 'occ-2'});
      final mate = rewritten.steps.single as AiMateStep;
      expect(mate.references.map((r) => r.occurrenceId), ['existing:occ-1', 'existing:occ-2']);
      expect(mate.references[0].faceSelector, {'normal': [0, 0.6, 0.8]});
      expect(mate.references[1].faceSelector, {'cylinder_radius': 4, 'near': [0, 0, 1]});
      expect(mate.value, 5);
      expect(mate.type, AiMateType.distance);
    });

    test('empty, existing: and unknown ids are left alone for validation to report', () {
      final split = splitPlacementAndMates(_plan([
        _mate('m1', '', 'existing:occ-9'),
        _mate('m2', 'ghost', 'plate'),
      ]));
      final rewritten = rewriteMateOccurrenceIds(split.mates, {'plate': 'occ-1'});
      final ids = [for (final s in rewritten.steps.cast<AiMateStep>()) ...s.references.map((r) => r.occurrenceId)];
      expect(ids, ['', 'existing:occ-9', 'ghost', 'existing:occ-1']);
    });

    test("a Width mate's midplane b_occurrence_id is rewritten too", () {
      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {
            'local_id': 'w',
            'kind': 'mate',
            'type': 'coincident',
            'references': [
              {
                'occurrence_id': 'frame',
                'midplane': {
                  'a': {'face_ref': {'body_id': 'b', 'shape_type': 'face', 'index': 0}},
                  'b': {'face_ref': {'body_id': 'b', 'shape_type': 'face', 'index': 1}},
                  'b_occurrence_id': 'rail',
                },
              },
              {'occurrence_id': 'plate', 'subshape_ref': {'body_id': 'p', 'shape_type': 'face', 'index': 0}},
            ],
          },
        ],
      });
      final rewritten = rewriteMateOccurrenceIds(
        splitPlacementAndMates(plan).mates,
        {'frame': 'f1', 'rail': 'r1', 'plate': 'p1'},
      );
      final first = (rewritten.steps.single as AiMateStep).references.first;
      expect(first.occurrenceId, 'existing:f1');
      expect(first.midplane!.bOccurrenceId, 'existing:r1');
    });
  });

  test('addComponentLocalIds lists only add_component steps', () {
    final ids = addComponentLocalIds(_plan([
      _add('a', 'A_001.didsa'),
      {'local_id': 'mv', 'kind': 'move_component', 'occurrence_id': 'a', 'translation': [0, 0, 0]},
    ]));
    expect(ids, {'a'});
  });
}
