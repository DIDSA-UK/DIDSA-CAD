import '../api/document_api_client.dart';
import 'ai_plan.dart';

/// How many times a plan that fails the dry-run validation is sent back to
/// the assistant automatically, with the errors, before the failure is shown
/// to the user. One: a model that fixes nothing on the first retry rarely
/// fixes it on the second, and each retry is a paid call.
const int aiAutoRetriesOnValidationFailure = 1;

/// The backend's own `error` map (`ai_plan.py`'s `_StepError`/
/// `StepResult.error`, see `05-backend-plan-validation.md`) is always
/// `{"type": "...", ...}` - `type` alone is a bare machine code like
/// "invalid_step_payload" that tells nobody what to change. Most errors
/// also carry a human-readable `message` or, failing that, other detail keys
/// (`field`, `local_id`, `body_id`, ...) worth showing instead - except
/// ids of the dry run's own scratch objects (UUIDs), which mean nothing to
/// the user or the model.
String formatAiStepError(Map<String, dynamic>? error) {
  if (error == null) return 'failed';
  final type = (error['type'] ?? 'failed').toString();
  final message = error['message'];
  if (message != null) return '$type: $message';
  final details = error.entries
      .where((e) => e.key != 'type' && !(e.value is String && _uuid.hasMatch(e.value as String)))
      .map((e) => '${e.key}=${e.value}')
      .join(', ');
  return details.isEmpty ? type : '$type ($details)';
}

final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

/// The `user`-role turn that tells the assistant why its plan failed the
/// dry run (nothing was built), so it can send a corrected one - both for
/// the automatic retry and for a user who simply replies "try again".
/// Lists each step that failed in its own right; steps that only failed
/// because they depend on one of those are counted, not listed, since they
/// carry no information of their own.
String describeAiPlanValidationFailure(AiGenerationPlan plan, List<AiPlanStepResultDto> results) {
  final kindByLocalId = {for (final step in plan.steps) step.localId: step.kind};
  final failed = results.where((r) => !r.ok).toList();
  final dependents = failed.where((r) => r.error?['type'] == 'depends_on_failed_step').length;
  final causes = failed.where((r) => r.error?['type'] != 'depends_on_failed_step').toList();
  final buffer = StringBuffer(
    'The plan failed validation, so nothing was built. Fix these problems and reply with a '
    'complete corrected plan (every step, not only the changed ones):\n',
  );
  for (final r in causes) {
    final kind = kindByLocalId[r.localId];
    buffer.writeln('- step "${r.localId}"${kind == null ? '' : ' ($kind)'}: ${formatAiStepError(r.error)}');
  }
  if (dependents > 0) {
    buffer.writeln('($dependents later step${dependents == 1 ? '' : 's'} also failed only because '
        '${dependents == 1 ? 'it depends' : 'they depend'} on a failed step.)');
  }
  return buffer.toString().trimRight();
}
