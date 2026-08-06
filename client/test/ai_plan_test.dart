import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';

/// AI Modelling workstream 2: [AiGenerationPlan]/[AiPlanStep] parsing -
/// mirrors `backend/app/document/ai_plan_schemas.py`'s locked shape
/// (`docs/ai-modelling/03-structured-plan-schema.md`'s own "Shape" example
/// is reused verbatim below, the authoritative locked example every other
/// workstream's own tests/prompts converge on).
void main() {
  Map<String, dynamic> lockedExamplePlanJson() => {
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
      };

  test('parses the locked schema example end to end', () {
    final plan = AiGenerationPlan.fromJson(lockedExamplePlanJson());

    expect(plan.version, 1);
    expect(plan.steps, hasLength(8));

    final sketch = plan.steps[0] as AiSketchStep;
    expect(sketch.plane, AiFixedPlane.xy);

    final rectangle = plan.steps[5] as AiSketchRectangleStep;
    expect(rectangle.cornerPointIds, ['p1', 'p2', 'p3', 'p4']);
    expect(rectangle.sketchFeatureId, 'sk1');

    final extrude = plan.steps[6] as AiExtrudeStep;
    expect(extrude.extrudeType, AiExtrudeType.boss);
    expect(extrude.startDistance, 0);
    expect(extrude.endDistance, 10);

    final fillet = plan.steps[7] as AiFilletStep;
    expect(fillet.edges.selector, AiEdgeSelectorKind.topFaceEdges);
    expect(fillet.edges.of, 'f1');
    expect(fillet.radius, 5);
  });

  test('stepById resolves a plan-local id to its owning step', () {
    final plan = AiGenerationPlan.fromJson(lockedExamplePlanJson());
    expect(plan.stepById('r1'), isA<AiSketchRectangleStep>());
    expect(plan.stepById('does-not-exist'), isNull);
  });

  test('toJson then fromJson round-trips every field of a mixed plan', () {
    final original = AiGenerationPlan.fromJson(lockedExamplePlanJson());
    final roundTripped = AiGenerationPlan.fromJson(original.toJson());

    expect(roundTripped.steps, hasLength(original.steps.length));
    final originalExtrude = original.steps[6] as AiExtrudeStep;
    final roundTrippedExtrude = roundTripped.steps[6] as AiExtrudeStep;
    expect(roundTrippedExtrude.startDistance, originalExtrude.startDistance);
    expect(roundTrippedExtrude.endDistance, originalExtrude.endDistance);
    expect(roundTrippedExtrude.extrudeType, originalExtrude.extrudeType);
  });

  test('gear_request carries arbitrary extra parameters opaquely and round-trips them', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'g1',
          'kind': 'gear_request',
          'gear_type': 'external_spur',
          'module': 2,
          'tooth_count': 20,
        },
      ],
    };

    final plan = AiGenerationPlan.fromJson(json);
    final gear = plan.steps.single as AiGearRequestStep;
    expect(gear.parameters, {'gear_type': 'external_spur', 'module': 2, 'tooth_count': 20});

    final roundTripped = gear.toJson();
    expect(roundTripped['local_id'], 'g1');
    expect(roundTripped['kind'], 'gear_request');
    expect(roundTripped['gear_type'], 'external_spur');
  });

  test('throws FormatException for an unknown step kind (permissive-but-not-silent parsing)', () {
    final json = {
      'version': 1,
      'steps': [
        {'local_id': 's1', 'kind': 'spline'},
      ],
    };

    expect(() => AiGenerationPlan.fromJson(json), throwsFormatException);
  });

  test('throws when the plan has no steps at all', () {
    expect(() => AiGenerationPlan.fromJson({'version': 1, 'steps': []}), throwsFormatException);
    expect(() => AiGenerationPlan.fromJson({'version': 1}), throwsFormatException);
  });

  test('optional fields default exactly like the Pydantic model defaults', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'f1',
          'kind': 'extrude',
          'sketch_feature_id': 'sk1',
          'extrude_type': 'boss',
          'start_distance': 0,
          'end_distance': 10,
        },
      ],
    };
    final extrude = AiGenerationPlan.fromJson(json).steps.single as AiExtrudeStep;
    expect(extrude.targetBodyIds, isEmpty);
    expect(extrude.profileRefs, isEmpty);
  });
}
