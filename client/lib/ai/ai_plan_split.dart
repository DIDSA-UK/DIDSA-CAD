/// Splitting an assembly plan into placements and mates (`docs/ai-modelling/16-assembly-mates-gaps-plan.md`, Phase 1).
///
/// A mate's `face_selector` is resolved by the backend's dry run against the placed occurrence's real geometry, and a
/// component added by an `add_component` step in the same plan has none yet (no target Part: `_resolve_occurrence_
/// target_part`). So an assembly plan that carries its own mates (an external AI's `99_assembly.json`) cannot be
/// validated as one plan. The app runs it in two parts instead: the placements first, which records each
/// `add_component` `local_id` -> real occurrence id (`PlanTranslationResult.localIdToRealId`); then the mates, with
/// every reference to one of those local ids rewritten to `existing:<real id>` - exactly the plan shape the in-app
/// mates turn already sends. Pure functions, no I/O.
library;

import 'ai_plan.dart';

/// An assembly plan taken apart: [placement] holds every step that is not a `mate` (order kept), [mates] the
/// `mate` steps (order kept). [placement] is null when the plan had nothing but mates.
class AiPlanSplit {
  final AiGenerationPlan? placement;
  final List<AiMateStep> mates;

  /// The plan's `intended_motion` (components meant to move), passed through untouched: ids are rewritten with the
  /// mates' by [rewriteMateOccurrenceIds].
  final List<AiIntendedMotion> intendedMotion;

  const AiPlanSplit({required this.placement, required this.mates, this.intendedMotion = const []});
}

/// Separates [plan]'s `mate` steps from everything else. A mate can reference only an `add_component` (or an
/// existing occurrence), never another step's result, so taking the mates out cannot orphan a later step.
AiPlanSplit splitPlacementAndMates(AiGenerationPlan plan) {
  final placementSteps = [for (final step in plan.steps) if (step is! AiMateStep) step];
  return AiPlanSplit(
    placement: placementSteps.isEmpty ? null : AiGenerationPlan(version: plan.version, steps: placementSteps),
    mates: plan.steps.whereType<AiMateStep>().toList(),
    intendedMotion: plan.intendedMotion,
  );
}

/// A plan of [mates] in which every reference that names an `add_component` `local_id` found in [localToReal] now
/// reads `existing:<real occurrence id>`. A reference that is `""`, already `existing:...`, or names anything else
/// (an unknown id, or a `local_id` whose component was never placed) is left as written: validation reports it.
/// Covers each reference's `occurrence_id` and a Width mate's `midplane.b_occurrence_id`, and the `component` of each
/// [intendedMotion] entry (a name that is not a local id stays as written).
AiGenerationPlan rewriteMateOccurrenceIds(
  List<AiMateStep> mates,
  Map<String, String> localToReal, {
  int version = 1,
  List<AiIntendedMotion> intendedMotion = const [],
}) {
  String? rewrite(String? id) {
    if (id == null || id.isEmpty || id.startsWith('existing:')) return id;
    final real = localToReal[id];
    return real == null ? id : 'existing:$real';
  }

  AiMateEntityRefStep rewriteRef(AiMateEntityRefStep ref) {
    final midplane = ref.midplane;
    return AiMateEntityRefStep(
      occurrenceId: rewrite(ref.occurrenceId)!,
      subshapeRef: ref.subshapeRef,
      planeRef: ref.planeRef,
      pointRef: ref.pointRef,
      midplane: midplane == null
          ? null
          : AiMidplaneRef(a: midplane.a, b: midplane.b, bOccurrenceId: rewrite(midplane.bOccurrenceId)),
      edgeSelector: ref.edgeSelector,
      faceSelector: ref.faceSelector,
    );
  }

  return AiGenerationPlan(
    version: version,
    intendedMotion: [
      for (final m in intendedMotion) AiIntendedMotion(component: rewrite(m.component)!, motion: m.motion),
    ],
    steps: [
      for (final mate in mates)
        AiMateStep(
          localId: mate.localId,
          type: mate.type,
          references: [for (final ref in mate.references) rewriteRef(ref)],
          value: mate.value,
          flipped: mate.flipped,
        ),
    ],
  );
}

/// The `add_component` `local_id`s of [plan] (what a mate reference may name bare).
Set<String> addComponentLocalIds(AiGenerationPlan plan) => {
      for (final step in plan.steps)
        if (step is AiAddComponentStep) step.localId,
    };
