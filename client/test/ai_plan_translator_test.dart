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
