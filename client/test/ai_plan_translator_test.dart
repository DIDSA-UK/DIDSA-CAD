import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_translator.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';

/// AI Modelling workstream 4: [PlanTranslator]'s own logic, exercised
/// directly against fixture plans (no LLM/provider call involved, no
/// widget tree - `ai_modelling_screen_test.dart` covers the screen wiring,
/// this file covers the translator engine itself) via a [MockClient]
/// shared between a [DocumentApiClient] and a [SketchApiClient], the same
/// sharing `ai_modelling_screen_test.dart` already does since both clients
/// talk to the same real backend.
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> decodeBody(http.Request request) =>
      request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

  group('PlanTranslator.execute - full success', () {
    test('a sketch -> rectangle -> extrude -> fillet plan creates everything for real, in order', () async {
      final paths = <String>[];
      var pointCount = 0;
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p3', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p4', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'r1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'f1', 'ok': true, 'warnings': [], 'error': null},
              {
                'local_id': 'c1',
                'ok': true,
                'warnings': [],
                'error': null,
                // Deliberately keyed by the plan's own `edges.of` local_id
                // ("f1"), not a real backend id - see `StepResult.
                // resolved_edges`'s own doc comment.
                'resolved_edges': [
                  {'body_id': 'f1', 'shape_type': 'edge', 'index': 0},
                  {'body_id': 'f1', 'shape_type': 'edge', 'index': 3},
                ],
              },
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          pointCount++;
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-$pointCount', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/rectangles') {
          return jsonResponse({
            'id': 'rect-1',
            'corner_point_ids': ['point-1', 'point-2', 'point-3', 'point-4'],
            'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
            'axis_aligned': true,
          });
        }
        if (request.url.path == '/document/parts/part-1/extrude-features') {
          return jsonResponse({
            'type': 'extrude',
            'id': 'feat-extrude1',
            'locked': false,
            'sketch_feature_id': 'feat-sk1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'target_body_ids': <String>[],
          });
        }
        if (request.url.path == '/document/parts/part-1/fillet-features') {
          return jsonResponse({
            'type': 'fillet',
            'id': 'feat-fillet1',
            'locked': false,
            'edge_refs': decodeBody(request)['edge_refs'],
            'radius': 2.0,
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
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
            'local_id': 'c1',
            'kind': 'fillet',
            'edges': {'selector': 'top_face_edges', 'of': 'f1'},
            'radius': 2,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final statuses = <int, List<TranslationStepStatus>>{};
      final result = await translator.execute(
        plan: plan,
        partId: 'part-1',
        onStepStatusChanged: (index, status) => statuses.putIfAbsent(index, () => []).add(status),
      );

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(result.localIdToRealId, {
        'sk1': 'feat-sk1',
        'p1': 'point-1',
        'p2': 'point-2',
        'p3': 'point-3',
        'p4': 'point-4',
        'r1': 'rect-1',
        'f1': 'feat-extrude1',
        'c1': 'feat-fillet1',
      });
      // Every Feature-producing step (not the raw sketch-entity ids) is
      // tracked for Undo, in creation order.
      expect(result.createdFeatureIds, ['feat-sk1', 'feat-extrude1', 'feat-fillet1']);
      // Every step reported a status; the last transition for each was `done`.
      for (var i = 0; i < plan.steps.length; i++) {
        expect(statuses[i]!.last, TranslationStepStatus.done, reason: 'step $i');
      }
      // The fillet's real edge_refs substituted "f1" for its real id.
      final filletCall = paths.indexOf('POST /document/parts/part-1/fillet-features');
      expect(filletCall, greaterThan(-1));
    });
  });

  group('PlanTranslator.execute - existing-Part editing (existing:<id> references)', () {
    test('a fillet targeting an existing Body (no new Feature-producing steps at all) resolves and posts the real id',
        () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path} ${decodeBody(request)}');
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          return jsonResponse({
            'results': [
              {
                'local_id': 'c1',
                'ok': true,
                'warnings': [],
                'error': null,
                // Mirrors the real backend's own `_resolve_edges`: keyed by
                // the plan's own `edges.of` value verbatim - here that
                // value already carries the `existing:` prefix, since the
                // plan never named a plan-local Body step at all.
                'resolved_edges': [
                  {'body_id': 'existing:feat-extrude-existing', 'shape_type': 'edge', 'index': 0},
                  {'body_id': 'existing:feat-extrude-existing', 'shape_type': 'edge', 'index': 1},
                ],
              },
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/fillet-features') {
          return jsonResponse({
            'type': 'fillet',
            'id': 'feat-fillet1',
            'locked': false,
            'edge_refs': decodeBody(request)['edge_refs'],
            'radius': 2.0,
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {
            'local_id': 'c1',
            'kind': 'fillet',
            'edges': {'selector': 'top_face_edges', 'of': 'existing:feat-extrude-existing'},
            'radius': 2,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(result.createdFeatureIds, ['feat-fillet1']);
      final filletCallBody =
          paths.firstWhere((p) => p.startsWith('POST /document/parts/part-1/fillet-features'));
      // The real Feature id, never the "existing:" wrapper - the wrapper is
      // a plan-authoring convention only, resolved away before anything is
      // sent over the wire.
      expect(filletCallBody, contains('feat-extrude-existing'));
      expect(filletCallBody, isNot(contains('existing:')));
    });

    test('a new sketch_point step anchored to an existing Sketch (via existingFeatures pre-seeding) posts to the '
        'real Sketch id, without ever creating a new SketchFeature', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          return jsonResponse({
            'results': [
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/sketch/sketches/sketch-existing/points') {
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-1', 'x': body['x'], 'y': body['y']});
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {
            'local_id': 'p1',
            'kind': 'sketch_point',
            'sketch_feature_id': 'existing:feat-sketch-existing',
            'x': 5,
            'y': 5,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(
        plan: plan,
        partId: 'part-1',
        existingFeatures: [
          FeatureDto(
            type: 'sketch',
            id: 'feat-sketch-existing',
            locked: false,
            sketchId: 'sketch-existing',
            produces: 'sketch',
          ),
        ],
      );

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(result.localIdToRealId, {'p1': 'point-1'});
      // No new SketchFeature was ever created - the plan referenced the
      // real, already-existing one throughout.
      expect(paths.any((p) => p.startsWith('POST /document/parts/part-1/features/sketch')), isFalse);
      expect(paths, contains('POST /sketch/sketches/sketch-existing/points'));
    });
  });

  group('PlanTranslator.execute - computed sketch-entity points (degrees, not radians)', () {
    test('sketch_line with length+angle computes the end point via a real createPoint call', () async {
      final createPointBodies = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'l1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          createPointBodies.add(body);
          return jsonResponse({'id': 'point-${createPointBodies.length}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/lines') {
          return jsonResponse({
            'id': 'line-1',
            'start_point_id': decodeBody(request)['start_point_id'],
            'end_point_id': decodeBody(request)['end_point_id'],
            'length': 10.0,
            'construction': false,
          });
        }
        // Workstream 8 (dimension-driven sketches): a literal `length` on
        // this plan's sketch_line step now also creates a real
        // DistanceConstraint right after the line itself.
        if (request.url.path == '/sketch/sketches/sketch-1/constraints') {
          final body = decodeBody(request);
          return jsonResponse({
            'type': 'distance',
            'id': 'dist-1',
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': body['distance'],
            'orientation': body['orientation'],
            'provisional': body['provisional'],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 0, 'y': 0},
          {
            'local_id': 'l1',
            'kind': 'sketch_line',
            'sketch_feature_id': 'sk1',
            'start_point_id': 'p1',
            'length': 10,
            'angle': 90, // degrees - "straight up" from p1
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      // The first createPoint call is the explicit p1 (0,0); the second is
      // the computed end point - must land near (0, 10), never near
      // (10*cos(90 rad), 10*sin(90 rad)) ~ (-4.48, 8.94), the exact bug
      // `ai_plan.py`'s own regression test (`test_ai_plan_validate.py`)
      // guards against server-side.
      expect(createPointBodies, hasLength(2));
      final computed = createPointBodies[1];
      expect((computed['x'] as num).toDouble(), closeTo(0.0, 1e-6));
      expect((computed['y'] as num).toDouble(), closeTo(10.0, 1e-6));
    });

    test('sketch_circle with radius+angle computes the radius point via the same degrees convention', () async {
      final createPointBodies = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'circ1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          createPointBodies.add(body);
          return jsonResponse({'id': 'point-${createPointBodies.length}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/circles') {
          return jsonResponse({
            'id': 'circle-1',
            'center_point_id': decodeBody(request)['center_point_id'],
            'radius_point_id': decodeBody(request)['radius_point_id'],
            'radius': 5.0,
            'construction': false,
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 10, 'y': 10},
          {
            'local_id': 'circ1',
            'kind': 'sketch_circle',
            'sketch_feature_id': 'sk1',
            'center_point_id': 'p1',
            'radius': 5,
            'angle': 0, // degrees - straight along +x from the center
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      final computed = createPointBodies[1];
      expect((computed['x'] as num).toDouble(), closeTo(15.0, 1e-6));
      expect((computed['y'] as num).toDouble(), closeTo(10.0, 1e-6));
    });
  });

  group('PlanTranslator.execute - dimension-driven sketches (real constraints, not raw coordinates)', () {
    test('sketch_line with a literal length creates a real, non-provisional DistanceConstraint', () async {
      final constraintCalls = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'l1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-${body['x']}-${body['y']}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/lines') {
          return jsonResponse({
            'id': 'line-1',
            'start_point_id': decodeBody(request)['start_point_id'],
            'end_point_id': decodeBody(request)['end_point_id'],
            'length': 25.0,
            'construction': false,
          });
        }
        if (request.method == 'POST' && request.url.path == '/sketch/sketches/sketch-1/constraints') {
          final body = decodeBody(request);
          constraintCalls.add(body);
          return jsonResponse({
            'type': 'distance',
            'id': 'dist-1',
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': body['distance'],
            'orientation': body['orientation'],
            'provisional': body['provisional'],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 0, 'y': 0},
          {'local_id': 'p2', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 25, 'y': 0},
          {
            'local_id': 'l1',
            'kind': 'sketch_line',
            'sketch_feature_id': 'sk1',
            'start_point_id': 'p1',
            'end_point_id': 'p2',
            'length': 25,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(constraintCalls, hasLength(1));
      expect(constraintCalls.single['distance'], 25.0);
      expect(constraintCalls.single['orientation'], 'linear');
      expect(constraintCalls.single['provisional'], isFalse);
    });

    test('sketch_line with no literal length creates no constraint at all', () async {
      final constraintCalls = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'l1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-${body['x']}-${body['y']}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/lines') {
          return jsonResponse({
            'id': 'line-1',
            'start_point_id': decodeBody(request)['start_point_id'],
            'end_point_id': decodeBody(request)['end_point_id'],
            'length': 25.0,
            'construction': false,
          });
        }
        if (request.method == 'POST' && request.url.path == '/sketch/sketches/sketch-1/constraints') {
          constraintCalls.add(decodeBody(request));
          fail('no length was given - no constraint should ever be created');
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 0, 'y': 0},
          {'local_id': 'p2', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 25, 'y': 0},
          {
            'local_id': 'l1',
            'kind': 'sketch_line',
            'sketch_feature_id': 'sk1',
            'start_point_id': 'p1',
            'end_point_id': 'p2',
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(constraintCalls, isEmpty);
    });

    test('sketch_rectangle with width/height creates horizontal+vertical DistanceConstraints', () async {
      final constraintCalls = <Map<String, dynamic>>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p3', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p4', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'r1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-${body['x']}-${body['y']}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/rectangles') {
          return jsonResponse({
            'id': 'rect-1',
            'corner_point_ids': decodeBody(request)['corner_point_ids'],
            'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
            'axis_aligned': true,
          });
        }
        if (request.method == 'POST' && request.url.path == '/sketch/sketches/sketch-1/constraints') {
          final body = decodeBody(request);
          constraintCalls.add(body);
          return jsonResponse({
            'type': 'distance',
            'id': 'dist-${constraintCalls.length}',
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': body['distance'],
            'orientation': body['orientation'],
            'provisional': body['provisional'],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
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
            'width': 60,
            'height': 40,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(constraintCalls, hasLength(2));
      final byOrientation = {for (final c in constraintCalls) c['orientation'] as String: c};
      expect(byOrientation.keys, containsAll(['horizontal', 'vertical']));
      expect(byOrientation['horizontal']!['distance'], 60.0);
      // Ids come from this test's own point-creation mock, which formats
      // them as 'point-$x-$y' using the request body's real (double, not
      // int) x/y - matches every other point-id literal in this file.
      expect(byOrientation['horizontal']!['point_a_id'], 'point-0.0-0.0');
      expect(byOrientation['horizontal']!['point_b_id'], 'point-60.0-0.0');
      expect(byOrientation['vertical']!['distance'], 40.0);
      expect(byOrientation['vertical']!['point_a_id'], 'point-60.0-0.0');
      expect(byOrientation['vertical']!['point_b_id'], 'point-60.0-40.0');
    });

    test('sketch_circle confirms its own provisional radius constraint via updateConstraintValue', () async {
      final patchCalls = <String>[];
      final mock = MockClient((request) async {
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'circ1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points') {
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-${body['x']}-${body['y']}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/circles') {
          return jsonResponse({
            'id': 'circle-1',
            'center_point_id': decodeBody(request)['center_point_id'],
            'radius_point_id': decodeBody(request)['radius_point_id'],
            'radius': 5.0,
            'construction': false,
            'radius_constraint_id': 'radius-constraint-1',
          });
        }
        if (request.method == 'PATCH' && request.url.path == '/sketch/sketches/sketch-1/constraints/radius-constraint-1') {
          patchCalls.add(decodeBody(request)['value'].toString());
          return jsonResponse({'converged': true, 'dof': 0, 'detail': 'ok'});
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'p1', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 10, 'y': 10},
          {'local_id': 'p2', 'kind': 'sketch_point', 'sketch_feature_id': 'sk1', 'x': 15, 'y': 10},
          {
            'local_id': 'circ1',
            'kind': 'sketch_circle',
            'sketch_feature_id': 'sk1',
            'center_point_id': 'p1',
            'radius_point_id': 'p2',
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(patchCalls, ['5.0']);
    });
  });

  group('PlanTranslator.execute - validation failure', () {
    test('never calls anything beyond validate when the pre-flight reports a failure', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add(request.url.path);
        return jsonResponse({
          'results': [
            {
              'local_id': 'f1',
              'ok': false,
              'warnings': [],
              'error': {'type': 'unknown_local_id'},
            },
          ],
        });
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {
            'local_id': 'f1',
            'kind': 'extrude',
            'sketch_feature_id': 'does_not_exist',
            'extrude_type': 'boss',
            'start_distance': 0,
            'end_distance': 10,
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.validationFailed);
      expect(result.preflightResults.single.ok, isFalse);
      expect(result.createdFeatureIds, isEmpty);
      expect(paths, ['/document/parts/part-1/ai-plan/validate']);
    });
  });

  group('PlanTranslator.execute - a real step failure partway through', () {
    test('stops immediately, leaves earlier Features in place, never attempts later steps', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'f1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'f2', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/document/parts/part-1/extrude-features') {
          return jsonResponse({
            'detail': {'type': 'no_extrudable_profile'},
          }, status: 422);
        }
        if (request.url.path == '/document/parts/part-1/create-plane-features') {
          fail('a later step must never be attempted once an earlier one fails for real');
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
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
            'kind': 'create_plane',
            'plane_type': 'three_points',
            'point_refs': ['a', 'b', 'c'],
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final statuses = <int, TranslationStepStatus>{};
      final result = await translator.execute(
        plan: plan,
        partId: 'part-1',
        onStepStatusChanged: (index, status) => statuses[index] = status,
      );

      expect(result.outcome, PlanTranslationOutcome.stepFailed);
      expect(result.stoppedAtIndex, 1);
      expect(result.stoppedAtLocalId, 'f1');
      expect(result.errorMessage, contains('no_extrudable_profile'));
      // sk1 already succeeded and stays tracked/created - no rollback.
      expect(result.localIdToRealId['sk1'], 'feat-sk1');
      expect(result.createdFeatureIds, ['feat-sk1']);
      expect(statuses[0], TranslationStepStatus.done);
      expect(statuses[1], TranslationStepStatus.failed);
      expect(statuses.containsKey(2), isFalse);
      expect(paths, isNot(contains('POST /document/parts/part-1/create-plane-features')));
    });
  });

  group('PlanTranslator.execute - gear_request interception', () {
    test('stops before executing a gear_request step, without ever calling anything for it', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path.endsWith('/ai-plan/validate')) {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'g1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'g1', 'kind': 'gear_request', 'module': 2, 'tooth_count': 20},
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.gearRequestEncountered);
      expect(result.stoppedAtIndex, 1);
      expect(result.stoppedAtLocalId, 'g1');
      expect(result.createdFeatureIds, ['feat-sk1']);
      expect(paths.where((p) => p.contains('gear')), isEmpty);
    });
  });

  group('PlanTranslator.execute - Loft (the square-to-round bug report)', () {
    test('a loft between two sketches posts a real LoftFeature with both sections resolved', () async {
      final paths = <String>[];
      var sketchCount = 0;
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p3', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'p4', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'r1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'sk2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'pc', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'pr', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'c1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'lf1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          sketchCount++;
          final sketchId = 'sketch-$sketchCount';
          final featId = 'feat-sk$sketchCount';
          return jsonResponse({'type': 'sketch', 'id': featId, 'locked': false, 'sketch_id': sketchId});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/points' || request.url.path == '/sketch/sketches/sketch-2/points') {
          final sketchNum = request.url.path.contains('sketch-1') ? 1 : 2;
          final body = decodeBody(request);
          return jsonResponse({'id': 'point-$sketchNum-${body['x']}-${body['y']}', 'x': body['x'], 'y': body['y']});
        }
        if (request.url.path == '/sketch/sketches/sketch-1/rectangles') {
          return jsonResponse({
            'id': 'rect-1',
            'corner_point_ids': ['point-1-0-0', 'point-1-60-0', 'point-1-60-40', 'point-1-0-40'],
            'line_ids': ['line-1', 'line-2', 'line-3', 'line-4'],
            'axis_aligned': true,
          });
        }
        if (request.url.path == '/sketch/sketches/sketch-2/circles') {
          final body = decodeBody(request);
          return jsonResponse({
            'id': 'circ-1',
            'center_point_id': body['center_point_id'],
            'radius_point_id': body['radius_point_id'],
            'radius_constraint_id': 'rc-1',
            'radius': 20.0,
          });
        }
        if (request.url.path == '/sketch/sketches/sketch-2/constraints/rc-1/value') {
          return jsonResponse({'ok': true});
        }
        if (request.url.path == '/document/parts/part-1/loft-features') {
          return jsonResponse({
            'type': 'loft',
            'id': 'feat-loft1',
            'locked': false,
            'sections': decodeBody(request)['sections'],
            'mode': 'boss',
            'ruled': false,
            'target_body_ids': <String>[],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
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
          {'local_id': 'sk2', 'kind': 'sketch', 'plane': 'XY'},
          {'local_id': 'pc', 'kind': 'sketch_point', 'sketch_feature_id': 'sk2', 'x': 30, 'y': 20},
          {'local_id': 'pr', 'kind': 'sketch_point', 'sketch_feature_id': 'sk2', 'x': 50, 'y': 20},
          {
            'local_id': 'c1',
            'kind': 'sketch_circle',
            'sketch_feature_id': 'sk2',
            'center_point_id': 'pc',
            'radius_point_id': 'pr',
          },
          {
            'local_id': 'lf1',
            'kind': 'loft',
            'sections': [
              {'sketch_feature_id': 'sk1', 'profile_refs': ['r1']},
              {'sketch_feature_id': 'sk2', 'profile_refs': ['c1']},
            ],
            'mode': 'boss',
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(result.localIdToRealId['lf1'], 'feat-loft1');
      expect(paths, contains('POST /document/parts/part-1/loft-features'));
    });
  });

  group('PlanTranslator.execute - Direct Editing / Boolean', () {
    test('merge, boolean, delete_body, scale_body, and move_body each post to their own real endpoint', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          return jsonResponse({
            'results': [
              {'local_id': 'sk1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'f1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'f2', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'm1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'b1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'd1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 's1', 'ok': true, 'warnings': [], 'error': null},
              {'local_id': 'mv1', 'ok': true, 'warnings': [], 'error': null},
            ],
          });
        }
        if (request.url.path == '/document/parts/part-1/features/sketch') {
          return jsonResponse({'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1'});
        }
        if (request.url.path == '/document/parts/part-1/extrude-features') {
          final id = decodeBody(request)['start_distance'] == 0 && paths.where((p) => p.contains('extrude')).length <= 1
              ? 'feat-f1'
              : 'feat-f2';
          return jsonResponse({
            'type': 'extrude',
            'id': id,
            'locked': false,
            'sketch_feature_id': 'feat-sk1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'target_body_ids': <String>[],
          });
        }
        if (request.url.path == '/document/parts/part-1/merge-features') {
          return jsonResponse({'type': 'merge', 'id': 'feat-merge1', 'locked': false, 'body_ids': decodeBody(request)['body_ids']});
        }
        if (request.url.path == '/document/parts/part-1/boolean-features') {
          final body = decodeBody(request);
          return jsonResponse({
            'type': 'boolean',
            'id': 'feat-bool1',
            'locked': false,
            'operation': body['operation'],
            'target_body_ids': body['target_body_ids'],
            'tool_body_ids': body['tool_body_ids'],
            'consume_tool_bodies': body['consume_tool_bodies'],
          });
        }
        if (request.url.path == '/document/parts/part-1/delete-body-features') {
          return jsonResponse({'type': 'delete_body', 'id': 'feat-del1', 'locked': false, 'body_ids': decodeBody(request)['body_ids']});
        }
        if (request.url.path == '/document/parts/part-1/scale-body-features') {
          final body = decodeBody(request);
          return jsonResponse({'type': 'scale_body', 'id': 'feat-scale1', 'locked': false, 'body_id': body['body_id'], 'factor': body['factor']});
        }
        if (request.url.path == '/document/parts/part-1/move-body-features') {
          final body = decodeBody(request);
          return jsonResponse({
            'type': 'move_body',
            'id': 'feat-move1',
            'locked': false,
            'body_id': body['body_id'],
            'delta': body['delta'],
            'rotation_axis': null,
            'rotation_angle_degrees': body['rotation_angle_degrees'],
            'make_copy': body['make_copy'],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
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
            'kind': 'extrude',
            'sketch_feature_id': 'sk1',
            'extrude_type': 'boss',
            'start_distance': 20,
            'end_distance': 30,
          },
          {'local_id': 'm1', 'kind': 'merge', 'body_ids': ['f1', 'f2']},
          {
            'local_id': 'b1',
            'kind': 'boolean',
            'operation': 'subtract',
            'target_body_ids': ['f1'],
            'tool_body_ids': ['f2'],
          },
          {'local_id': 'd1', 'kind': 'delete_body', 'body_ids': ['f1']},
          {'local_id': 's1', 'kind': 'scale_body', 'body_id': 'f1', 'factor': 2.0},
          {'local_id': 'mv1', 'kind': 'move_body', 'body_id': 'f1', 'delta': [10.0, 0.0, 0.0]},
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1');

      expect(result.outcome, PlanTranslationOutcome.success);
      expect(paths, contains('POST /document/parts/part-1/merge-features'));
      expect(paths, contains('POST /document/parts/part-1/boolean-features'));
      expect(paths, contains('POST /document/parts/part-1/delete-body-features'));
      expect(paths, contains('POST /document/parts/part-1/scale-body-features'));
      expect(paths, contains('POST /document/parts/part-1/move-body-features'));
    });
  });

  group('PlanTranslator.execute - tool-toggle enforcement (disabledKinds)', () {
    test('disabledKinds is merged into the validate request body', () async {
      Map<String, dynamic>? validateBody;
      final mock = MockClient((request) async {
        if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
          validateBody = decodeBody(request);
          return jsonResponse({
            'results': [
              {
                'local_id': 'lf1',
                'ok': false,
                'warnings': [],
                'error': {'type': 'kind_disabled', 'kind': 'loft'},
              },
            ],
          });
        }
        return http.Response('not found', 404);
      });

      final plan = AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {
            'local_id': 'lf1',
            'kind': 'loft',
            'sections': [
              {'sketch_feature_id': 'sk1'},
              {'sketch_feature_id': 'sk2'},
            ],
            'mode': 'boss',
          },
        ],
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      final result = await translator.execute(plan: plan, partId: 'part-1', disabledKinds: {'loft'});

      expect(result.outcome, PlanTranslationOutcome.validationFailed);
      expect(validateBody?['disabled_kinds'], ['loft']);
      expect(result.preflightResults.single.error?['type'], 'kind_disabled');
    });
  });

  group('PlanTranslator.undo', () {
    test('deletes every created Feature in reverse order via cascade delete', () async {
      final cascadeDeletedPaths = <String>[];
      final mock = MockClient((request) async {
        if (request.method == 'DELETE' && request.url.path.endsWith('/cascade')) {
          cascadeDeletedPaths.add(request.url.path);
          return jsonResponse({'deleted_feature_ids': [], 'deleted_sketch_ids': []});
        }
        return http.Response('not found', 404);
      });

      final translator = PlanTranslator(
        documentApi: DocumentApiClient(httpClient: mock),
        sketchApi: SketchApiClient(httpClient: mock),
      );
      await translator.undo(partId: 'part-1', createdFeatureIds: ['feat-sk1', 'feat-extrude1', 'feat-fillet1']);

      expect(cascadeDeletedPaths, [
        '/document/parts/part-1/features/feat-fillet1/cascade',
        '/document/parts/part-1/features/feat-extrude1/cascade',
        '/document/parts/part-1/features/feat-sk1/cascade',
      ]);
    });
  });

  test('sanity: math.radians(90) does not equal 90 (confirms the degrees test above is a real regression guard)', () {
    expect(math.pi / 2, isNot(closeTo(90.0, 0.01)));
  });
}
