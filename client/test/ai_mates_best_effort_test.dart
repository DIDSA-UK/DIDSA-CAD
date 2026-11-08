import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_translator.dart';
import 'package:didsa_cad_client/ai/ai_validation_feedback.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';

/// B2 (docs/assembly-perf-mates-and-ui-plan.md): a plan's mates are not all-or-nothing.
void main() {
  http.Response json(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> mateStep(String id, double value, {String a = 'existing:occ-a', String b = 'existing:occ-b'}) => {
        'local_id': id,
        'kind': 'mate',
        'type': 'distance',
        'value': value,
        'references': [
          {
            'occurrence_id': a,
            'subshape_ref': {'body_id': 'b1', 'shape_type': 'face', 'index': 0},
          },
          {
            'occurrence_id': b,
            'subshape_ref': {'body_id': 'b1', 'shape_type': 'face', 'index': 1},
          },
        ],
      };

  AiGenerationPlan plan(List<Map<String, dynamic>> steps) => AiGenerationPlan.fromJson({'version': 1, 'steps': steps});

  /// A fake backend: [invalid] local ids fail the dry run; [unsolvable] mate values answer the create with a 422
  /// `mate_solve_did_not_converge` (and store nothing); [fixed] occurrence ids answer `occurrence_is_fixed`.
  ({PlanTranslator translator, List<Map<String, dynamic>> created, List<Map<String, String>> queries, List<String> calls})
      fake({Set<String> invalid = const {}, Set<double> unsolvable = const {}, Set<String> fixed = const {}, required List<String> ids}) {
    final created = <Map<String, dynamic>>[];
    final queries = <Map<String, String>>[];
    final calls = <String>[];
    final mock = MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.url.path == '/document/parts/part-1/ai-plan/validate') {
        return json({
          'results': [
            for (final id in ids)
              invalid.contains(id)
                  ? {
                      'local_id': id,
                      'ok': false,
                      'warnings': [],
                      'error': {'type': 'invalid_reference', 'message': 'face_selector needs body_id'},
                    }
                  : {'local_id': id, 'ok': true, 'warnings': [], 'error': null},
          ],
        });
      }
      if (request.method == 'POST' && request.url.path == '/document/parts/part-1/mates') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final occ = request.url.queryParameters['occurrence_id'];
        if (occ != null && fixed.contains(occ)) {
          return json({
            'detail': {'type': 'occurrence_is_fixed', 'message': '$occ is fixed'},
          }, status: 422);
        }
        if (unsolvable.contains(body['value'])) {
          return json({
            'detail': {'type': 'mate_solve_did_not_converge', 'occurrence_id': occ, 'detail': 'No placement satisfies these mates together.'},
          }, status: 422);
        }
        created.add(body);
        queries.add(request.url.queryParameters);
        return json({
          'id': 'mate-${created.length}',
          'type': body['type'],
          'references': body['references'],
          'value': body['value'],
          'flipped': false,
          'suppressed': false,
        }, status: 201);
      }
      return http.Response('not found', 404);
    });
    return (
      translator: PlanTranslator(documentApi: DocumentApiClient(httpClient: mock), sketchApi: SketchApiClient(httpClient: mock)),
      created: created,
      queries: queries,
      calls: calls,
    );
  }

  test('one invalid mate does not stop the others: they are built, the invalid one is reported', () async {
    final f = fake(invalid: {'m2'}, ids: ['m1', 'm2', 'm3']);
    final result = await f.translator.execute(
      plan: plan([mateStep('m1', 10), mateStep('m2', 20), mateStep('m3', 30)]),
      partId: 'part-1',
      bestEffortMates: true,
    );
    expect(result.outcome, PlanTranslationOutcome.completedWithFailures);
    expect(f.created.map((m) => m['value']), [10, 30]);
    expect(result.localIdToRealId.keys, ['m1', 'm3']);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.localId, 'm2');
    expect(result.failures.single.atValidation, isTrue);
    expect(result.failures.single.message, contains('face_selector needs body_id'));
  });

  test('a mate whose solve does not converge is not stored, and later mates still build', () async {
    final f = fake(unsolvable: {20.0}, ids: ['m1', 'm2', 'm3']);
    final statuses = <int, TranslationStepStatus>{};
    final result = await f.translator.execute(
      plan: plan([mateStep('m1', 10), mateStep('m2', 20), mateStep('m3', 30)]),
      partId: 'part-1',
      bestEffortMates: true,
      onStepStatusChanged: (i, s) => statuses[i] = s,
    );
    expect(result.outcome, PlanTranslationOutcome.completedWithFailures);
    expect(f.created.map((m) => m['value']), [10, 30]);
    // Every create is atomic (solve=auto driving the second reference's occurrence) and there is no separate solve call.
    expect(f.queries, everyElement({'solve': 'auto', 'occurrence_id': 'occ-b'}));
    expect(f.calls.where((c) => c.contains('/solve')), isEmpty);
    expect(f.calls.where((c) => c.startsWith('DELETE')), isEmpty, reason: 'nothing was stored, so nothing to undo');
    expect(result.failures.single.localId, 'm2');
    expect(result.failures.single.atValidation, isFalse);
    expect(result.failures.single.message, contains('No placement satisfies'));
    expect(statuses[1], TranslationStepStatus.failed);
    expect(statuses[2], TranslationStepStatus.done);
  });

  test('the other side is driven when the second reference is the grounded component', () async {
    final f = fake(fixed: {'occ-b'}, ids: ['m1']);
    final result = await f.translator.execute(plan: plan([mateStep('m1', 10)]), partId: 'part-1', bestEffortMates: true);
    expect(result.outcome, PlanTranslationOutcome.success);
    expect(f.queries.single['occurrence_id'], 'occ-a');
  });

  test('a clean run is a success; the failure text lists id, stage and reason', () async {
    final clean = fake(ids: ['m1']);
    final ok = await clean.translator.execute(plan: plan([mateStep('m1', 10)]), partId: 'part-1', bestEffortMates: true);
    expect(ok.outcome, PlanTranslationOutcome.success);
    expect(ok.failures, isEmpty);

    final f = fake(invalid: {'m2'}, unsolvable: {30.0}, ids: ['m1', 'm2', 'm3']);
    final result = await f.translator.execute(
      plan: plan([mateStep('m1', 10), mateStep('m2', 20), mateStep('m3', 30)]),
      partId: 'part-1',
      bestEffortMates: true,
    );
    final text = describeMateFailures(result.failures);
    expect(text, contains('- mate m2 (failed validation)'));
    expect(text, contains('- mate m3 (could not be solved)'));
  });

  test('when no mate passes validation it is still a validation failure (so the in-app turn can retry)', () async {
    final f = fake(invalid: {'m1', 'm2'}, ids: ['m1', 'm2']);
    final result = await f.translator.execute(plan: plan([mateStep('m1', 10), mateStep('m2', 20)]), partId: 'part-1', bestEffortMates: true);
    expect(result.outcome, PlanTranslationOutcome.validationFailed);
    expect(f.created, isEmpty);
  });

  test('without bestEffortMates the old rules hold: one invalid step builds nothing', () async {
    final f = fake(invalid: {'m2'}, ids: ['m1', 'm2']);
    final result = await f.translator.execute(plan: plan([mateStep('m1', 10), mateStep('m2', 20)]), partId: 'part-1');
    expect(result.outcome, PlanTranslationOutcome.validationFailed);
    expect(f.created, isEmpty);
  });
}
