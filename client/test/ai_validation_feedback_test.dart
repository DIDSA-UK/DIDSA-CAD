import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_validation_feedback.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';

AiPlanStepResultDto _result(String localId, Map<String, dynamic>? error) =>
    AiPlanStepResultDto.fromJson({'local_id': localId, 'ok': error == null, 'warnings': [], 'error': error});

void main() {
  test('formatAiStepError prefers the message, then the detail keys, then the bare type', () {
    expect(formatAiStepError(null), 'failed');
    expect(formatAiStepError({'type': 'invalid_step_payload', 'message': 'cut requires a target'}),
        'invalid_step_payload: cut requires a target');
    expect(formatAiStepError({'type': 'point_not_on_line', 'line_id': 'l1'}), 'point_not_on_line (line_id=l1)');
    expect(formatAiStepError({'type': 'unknown_local_id'}), 'unknown_local_id');
    // The dry run's scratch ids are dropped; plan-level details stay.
    expect(
      formatAiStepError({
        'type': 'point_not_on_line',
        'sketch_id': '2eeb853b-3b87-43fd-bd85-418346de3a3b',
        'line_id': 'cb0638d8-7796-4ae2-ac7b-4ad486c1fcbc',
      }),
      'point_not_on_line',
    );
    expect(formatAiStepError({'type': 'missing_body', 'body_id': '1c762e74-3419-4e36-9601-5cbf18470681', 'field': 'edges.of'}),
        'missing_body (field=edges.of)');
  });

  test('the feedback lists each step that failed in its own right and only counts its dependents', () {
    final plan = AiGenerationPlan.fromJson({
      'version': 1,
      'steps': [
        {'local_id': 'sk1', 'kind': 'sketch', 'plane': 'XY'},
        {'local_id': 'pl1', 'kind': 'create_plane', 'plane_type': 'normal_to_line_at_point', 'line_ref': 'l1', 'point_ref': 'p3'},
        {'local_id': 'sk2', 'kind': 'sketch', 'plane_feature_id': 'pl1'},
      ],
    });
    final text = describeAiPlanValidationFailure(plan, [
      _result('sk1', null),
      _result('pl1', {'type': 'point_not_on_line', 'line_id': 'l1'}),
      _result('sk2', {'type': 'depends_on_failed_step', 'field': 'plane_feature_id', 'local_id': 'pl1'}),
    ]);
    expect(text, startsWith('The plan failed validation, so nothing was built.'));
    expect(text, contains('- step "pl1" (create_plane): point_not_on_line (line_id=l1)'));
    expect(text, isNot(contains('"sk2"')));
    expect(text, contains('(1 later step also failed only because it depends on a failed step.)'));
    expect(text, isNot(contains('"sk1"')));
  });
}
