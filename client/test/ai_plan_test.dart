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

  /// The reported square-to-round bug's own shape: a loft between two
  /// sections on different sketches.
  test('loft parses 2+ sections and round-trips every field', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'lf1',
          'kind': 'loft',
          'sections': [
            {'sketch_feature_id': 'sk1', 'profile_refs': ['r1']},
            {'sketch_feature_id': 'sk2', 'profile_refs': ['c1']},
          ],
          'mode': 'boss',
          'ruled': true,
        },
      ],
    };

    final loft = AiGenerationPlan.fromJson(json).steps.single as AiLoftStep;
    expect(loft.sections, hasLength(2));
    expect(loft.sections[0].sketchFeatureId, 'sk1');
    expect(loft.sections[0].profileRefs, ['r1']);
    expect(loft.sections[1].sketchFeatureId, 'sk2');
    expect(loft.mode, AiLoftMode.boss);
    expect(loft.ruled, isTrue);
    expect(loft.targetBodyIds, isEmpty);
    expect(loft.thickness, isNull);
    expect(loft.guideCurveRefs, isEmpty);

    final roundTripped = AiGenerationPlan.fromJson({'version': 1, 'steps': [loft.toJson()]}).steps.single as AiLoftStep;
    expect(roundTripped.sections, hasLength(2));
    expect(roundTripped.mode, AiLoftMode.boss);
    expect(roundTripped.ruled, isTrue);
  });

  test('direct-editing/boolean steps parse and round-trip', () {
    final merge = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'm1', 'kind': 'merge', 'body_ids': ['f1', 'f2']},
      ],
    }).steps.single as AiMergeStep;
    expect(merge.bodyIds, ['f1', 'f2']);

    final boolean = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {
          'local_id': 'b1',
          'kind': 'boolean',
          'operation': 'subtract',
          'target_body_ids': ['f1'],
          'tool_body_ids': ['f2'],
        },
      ],
    }).steps.single as AiBooleanStep;
    expect(boolean.operation, AiBooleanOperation.subtract);
    expect(boolean.consumeToolBodies, isTrue);

    final deleteBody = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'd1', 'kind': 'delete_body', 'body_ids': ['f1']},
      ],
    }).steps.single as AiDeleteBodyStep;
    expect(deleteBody.bodyIds, ['f1']);

    final scaleBody = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 's1', 'kind': 'scale_body', 'body_id': 'f1', 'factor': 2.0},
      ],
    }).steps.single as AiScaleBodyStep;
    expect(scaleBody.factor, 2.0);

    final moveBody = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {
          'local_id': 'mv1',
          'kind': 'move_body',
          'body_id': 'f1',
          'delta': [10.0, 0.0, 0.0],
          'rotation_axis': {'sketch_line_ref': 'l1'},
          'rotation_angle_degrees': 90.0,
          'make_copy': true,
        },
      ],
    }).steps.single as AiMoveBodyStep;
    expect(moveBody.delta, [10.0, 0.0, 0.0]);
    expect(moveBody.rotationAxis?.sketchLineRef, 'l1');
    expect(moveBody.rotationAngleDegrees, 90.0);
    expect(moveBody.makeCopy, isTrue);

    for (final step in [merge, boolean, deleteBody, scaleBody, moveBody]) {
      final roundTripped = AiPlanStep.fromJson(step.toJson());
      expect(roundTripped.runtimeType, step.runtimeType);
    }
  });

  // --- Assembly support Phase 14 (docs/assembly-scope.md §6 [3]/[1] partial) ---

  test('mate step parses a reference with edge_selector and round-trips it', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'mate1',
          'kind': 'mate',
          'type': 'concentric',
          'references': [
            {
              'occurrence_id': '',
              'subshape_ref': {'body_id': 'b1', 'shape_type': 'edge', 'index': 0},
              'edge_selector': {'selector': 'vertical_edges'},
            },
            {
              'occurrence_id': 'existing:occ-1',
              'subshape_ref': {'body_id': 'b2', 'shape_type': 'face', 'index': 2},
            },
          ],
        },
      ],
    };

    final mate = AiGenerationPlan.fromJson(json).steps.single as AiMateStep;
    expect(mate.type, AiMateType.concentric);
    expect(mate.references, hasLength(2));

    final withSelector = mate.references[0];
    expect(withSelector.occurrenceId, '');
    expect(withSelector.subshapeRef?.bodyId, 'b1');
    expect(withSelector.edgeSelector, isNotNull);
    expect(withSelector.edgeSelector!.selector, AiEdgeSelectorKind.verticalEdges);
    // `of` is never present for a Mate's own edge_selector (no plan-local
    // Body-producing step to name).
    expect(withSelector.edgeSelector!.of, isNull);

    final withoutSelector = mate.references[1];
    expect(withoutSelector.occurrenceId, 'existing:occ-1');
    expect(withoutSelector.edgeSelector, isNull);

    final roundTripped = AiPlanStep.fromJson(mate.toJson()) as AiMateStep;
    expect(roundTripped.references[0].edgeSelector?.selector, AiEdgeSelectorKind.verticalEdges);
    expect(roundTripped.references[0].edgeSelector?.toJson().containsKey('of'), isFalse);
    expect(roundTripped.references[1].edgeSelector, isNull);
  });

  test('fillet edges.of still round-trips as required for a real fillet/chamfer step', () {
    // The same AiEdgeSelector type now serves both call sites - confirms
    // widening `of` to nullable didn't silently drop it for the call site
    // that still always provides it.
    final fillet = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {
          'local_id': 'f2',
          'kind': 'fillet',
          'edges': {'selector': 'top_face_edges', 'of': 'f1'},
          'radius': 5,
        },
      ],
    }).steps.single as AiFilletStep;
    expect(fillet.edges.of, 'f1');
    expect(fillet.edges.toJson()['of'], 'f1');
  });

  test('pattern_component step parses a linear pattern and round-trips it', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'p1',
          'kind': 'pattern_component',
          'source_occurrence_ids': ['existing:occ-1'],
          'pattern_type': 'linear',
          'direction': [1.0, 0.0, 0.0],
          'count': 4,
          'spacing': 10.0,
          'reverse': false,
        },
      ],
    };

    final pattern = AiGenerationPlan.fromJson(json).steps.single as AiPatternComponentStep;
    expect(pattern.sourceOccurrenceIds, ['existing:occ-1']);
    expect(pattern.patternType, 'linear');
    expect(pattern.direction, [1.0, 0.0, 0.0]);
    expect(pattern.count, 4);
    expect(pattern.spacing, 10.0);
    expect(pattern.axis, isNull);

    final roundTripped = AiPlanStep.fromJson(pattern.toJson()) as AiPatternComponentStep;
    expect(roundTripped.sourceOccurrenceIds, pattern.sourceOccurrenceIds);
    expect(roundTripped.count, pattern.count);
    expect(roundTripped.spacing, pattern.spacing);
  });

  test('pattern_component step parses a circular pattern with axis and multiple sources', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'p1',
          'kind': 'pattern_component',
          'source_occurrence_ids': ['existing:occ-1', 'existing:occ-2'],
          'pattern_type': 'circular',
          'axis': {
            'origin': [0.0, 0.0, 0.0],
            'direction': [0.0, 0.0, 1.0],
          },
          'count_angular': 6,
          'angle_total': 180.0,
          'reverse_angular': true,
          'skip_indices': [2],
          'orient_with_rotation': false,
        },
      ],
    };

    final pattern = AiGenerationPlan.fromJson(json).steps.single as AiPatternComponentStep;
    expect(pattern.sourceOccurrenceIds, ['existing:occ-1', 'existing:occ-2']);
    expect(pattern.patternType, 'circular');
    expect(pattern.axis?.origin, [0.0, 0.0, 0.0]);
    expect(pattern.axis?.direction, [0.0, 0.0, 1.0]);
    expect(pattern.countAngular, 6);
    expect(pattern.angleTotal, 180.0);
    expect(pattern.reverseAngular, isTrue);
    expect(pattern.skipIndices, [2]);
    expect(pattern.orientWithRotation, isFalse);

    final roundTripped = AiPlanStep.fromJson(pattern.toJson()) as AiPatternComponentStep;
    expect(roundTripped.axis?.direction, [0.0, 0.0, 1.0]);
    expect(roundTripped.skipIndices, [2]);
    expect(roundTripped.orientWithRotation, isFalse);
  });

  test('pattern_component step defaults exactly like the Pydantic model defaults', () {
    final pattern = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {
          'local_id': 'p1',
          'kind': 'pattern_component',
          'source_occurrence_ids': ['existing:occ-1'],
        },
      ],
    }).steps.single as AiPatternComponentStep;
    expect(pattern.patternType, 'linear');
    expect(pattern.direction, [1.0, 0.0, 0.0]);
    expect(pattern.count, 1);
    expect(pattern.spacing, 0.0);
    expect(pattern.reverse, isFalse);
    expect(pattern.countAngular, 1);
    expect(pattern.angleTotal, 360.0);
    expect(pattern.reverseAngular, isFalse);
    expect(pattern.skipIndices, isEmpty);
    expect(pattern.orientWithRotation, isTrue);
  });

  test('add_component step parses and round-trips with a name_override', () {
    final json = {
      'version': 1,
      'steps': [
        {
          'local_id': 'ac1',
          'kind': 'add_component',
          'relative_path': 'parts/bracket.DIDSAprt',
          'name_override': 'Bracket',
        },
      ],
    };

    final step = AiGenerationPlan.fromJson(json).steps.single as AiAddComponentStep;
    expect(step.localId, 'ac1');
    expect(step.kind, 'add_component');
    expect(step.relativePath, 'parts/bracket.DIDSAprt');
    expect(step.nameOverride, 'Bracket');

    final roundTripped = AiPlanStep.fromJson(step.toJson()) as AiAddComponentStep;
    expect(roundTripped.relativePath, step.relativePath);
    expect(roundTripped.nameOverride, step.nameOverride);
  });

  test('add_component step parses without a name_override and omits it on toJson', () {
    final step = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'ac1', 'kind': 'add_component', 'relative_path': 'parts/bracket.DIDSAprt'},
      ],
    }).steps.single as AiAddComponentStep;

    expect(step.nameOverride, isNull);
    expect(step.toJson().containsKey('name_override'), isFalse);
  });
}
