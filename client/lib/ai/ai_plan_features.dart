// What a plan needs from the backend, and whether the backend says it has it (B5, docs/assembly-perf-mates-and-ui-plan.md).
//
// An imported AI zip is built against whatever backend the app is connected to. An older backend fails each mate on its own
// ("face_selector.normal is not a field", "occurrence not found" for an `outer/inner` path) and the user cannot tell why.
// `GET /health` lists `api_features`; this file maps what a plan uses to those names, so the AI screen can say "the backend is
// older than this app" once, before it starts.
import 'ai_plan.dart';

/// A mate reference's `face_selector` carries `normal` (a sloped face).
const String kFeatureFaceSelectorNormal = 'ai_plan.face_selector.normal';

/// A mate reference is a path into a placed sub-assembly (`outer/inner`).
const String kFeatureMatePaths = 'ai_plan.mate_paths';

/// The backend features [plan] depends on, as `/health` names them.
Set<String> requiredApiFeatures(AiGenerationPlan plan) {
  final needed = <String>{};
  for (final step in plan.steps.whereType<AiMateStep>()) {
    for (final ref in step.references) {
      if (ref.faceSelector?['normal'] != null) needed.add(kFeatureFaceSelectorNormal);
      if (ref.occurrenceId.contains('/')) needed.add(kFeatureMatePaths);
    }
  }
  return needed;
}

/// The features [plan] needs that the backend does not list, sorted. [backendFeatures] null means the backend could not be asked
/// (a failed call): nothing is claimed missing then. An empty set is a backend that answered without `api_features` (an older
/// one), so everything the plan needs is missing.
List<String> missingApiFeatures(AiGenerationPlan plan, Set<String>? backendFeatures) {
  if (backendFeatures == null) return const [];
  return (requiredApiFeatures(plan).difference(backendFeatures)).toList()..sort();
}

/// What the screen tells the user when [missing] is not empty.
String backendTooOldMessage(List<String> missing) =>
    'The backend is older than this app: update it to build these mates (it lacks ${missing.join(', ')}).';
