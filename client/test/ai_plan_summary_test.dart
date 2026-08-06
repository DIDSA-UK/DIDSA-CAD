import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_summary.dart';

/// AI Modelling workstream 2: [summarizeAiPlan]'s literal-value rendering -
/// a hard requirement from `03-structured-plan-schema.md`'s "Spike
/// findings" section, not a nice-to-have: a real, reproduced LLM
/// hallucination silently changed a stated `end_distance` from 5mm to
/// 40mm past every structural/referential check workstream 5's validator
/// runs. Schema/referential validity does not imply dimensional
/// correctness - a human skimming real numbers next to what they just
/// typed is the one layer that would have caught it, so this summary must
/// show literal values ("Extrude 0->10mm"), never just step *types*
/// ("Extrude").
void main() {
  AiGenerationPlan lockedExamplePlan() => AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 0, 'y': 0},
          {'local_id': 'p2', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 60, 'y': 0},
          {'local_id': 'p3', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 60, 'y': 40},
          {'local_id': 'p4', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 0, 'y': 40},
          {
            'local_id': 'r1',
            'kind': 'sketch_rectangle',
            'sketch_feature_id': 'sk1',
            'corner_point_ids': ['p1', 'p2', 'p3', 'p4'],
          },
          {
            'local_id': 'f1',
            'kind': 'extrude',
            'sketch_feature_id': 'sk1',
            'extrude_type': 'boss',
            'start_distance': 0,
            'end_distance': 10,
          },
          {
            'local_id': 'f2',
            'kind': 'fillet',
            'edges': {'selector': 'top_face_edges', 'of': 'f1'},
            'radius': 5,
          },
        ],
      });

  test('sketch_point steps are omitted from the summary (they are pure inputs)', () {
    final summary = summarizeAiPlan(lockedExamplePlan());
    expect(summary, hasLength(4)); // sketch, rectangle, extrude, fillet - not the 4 points
  });

  test('resolves a sketch_rectangle to its own literal width x height, derived from its corner points', () {
    final summary = summarizeAiPlan(lockedExamplePlan());
    expect(summary[1], 'Rectangle 60×40mm');
  });

  test('shows an extrude step\'s literal start/end distances, not just its type', () {
    final summary = summarizeAiPlan(lockedExamplePlan());
    expect(summary[2], contains('0'));
    expect(summary[2], contains('10'));
    expect(summary[2], contains('mm'));
    expect(summary[2], isNot('Extrude')); // must not degrade to a bare type name
  });

  test('the spike-1 hallucination case: a wrong end_distance is visibly different from the correct one', () {
    Map<String, dynamic> planWithEndDistance(num endDistance) => {
          'version': 1,
          'steps': [
            {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
            {
              'local_id': 'f1',
              'kind': 'extrude',
              'sketch_feature_id': 'sk1',
              'extrude_type': 'boss',
              'start_distance': 0,
              'end_distance': endDistance,
            },
          ],
        };

    final correct = summarizeAiPlan(AiGenerationPlan.fromJson(planWithEndDistance(5)))[1];
    final hallucinated = summarizeAiPlan(AiGenerationPlan.fromJson(planWithEndDistance(40)))[1];

    expect(correct, 'Extrude 0→5mm (boss)');
    expect(hallucinated, 'Extrude 0→40mm (boss)');
    expect(correct, isNot(hallucinated));
  });

  test('fillet summary shows the selector and literal radius', () {
    final summary = summarizeAiPlan(lockedExamplePlan());
    expect(summary[3], contains('top face edges'));
    expect(summary[3], contains('5mm'));
  });

  test('sketch step names its fixed plane literally', () {
    final summary = summarizeAiPlan(lockedExamplePlan());
    expect(summary[0], 'New Sketch on XY');
  });

  test('falls back to a corner-count description when a rectangle\'s points cannot be resolved', () {
    final plan = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
        {
          'local_id': 'r1',
          'kind': 'sketch_rectangle',
          'sketch_feature_id': 'sk1',
          'corner_point_ids': ['missing1', 'missing2', 'missing3', 'missing4'],
        },
      ],
    });
    final summary = summarizeAiPlan(plan);
    expect(summary[1], 'Rectangle (4 corners)');
  });

  test('gear_request shows its literal carried parameters', () {
    final plan = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'g1', 'kind': 'gear_request', 'module': 2, 'tooth_count': 20},
      ],
    });
    final summary = summarizeAiPlan(plan);
    expect(summary.single, contains('module=2'));
    expect(summary.single, contains('tooth_count=20'));
  });
}
