/// AI Modelling workstream 4: `PlanTranslator`
/// (`docs/ai-modelling/04-translator-and-execution.md`). Walks a validated
/// [AiGenerationPlan]'s steps **in order** against an already-created real
/// Part, calling the *exact same* `DocumentApiClient`/`SketchApiClient`
/// methods a human-driven screen would call - never a new code path into
/// the backend. Maintains a single `Map<String, String> localIdToRealId`
/// as steps succeed, substituting real ids wherever a step referenced an
/// earlier `local_id`.
///
/// **Deliberately does not create the Part itself** - unlike `04`'s own
/// generic wording ("takes ... the currently-open Part, or creates one via
/// `createPart` first if none is open"), this app's actual, already-
/// shipped `AiModellingScreen._generate()` already creates a fresh Part to
/// run workstream 5's dry-run validation against (`00-conventions.md`'s
/// "v1 always starts a fresh Part") - this translator's whole reason to
/// exist is to **reuse that same Part id** for real execution rather than
/// creating a second, orphaned one (see that method's own doc comment,
/// which named this exact gap). [execute] therefore takes [partId] as a
/// required parameter.
///
/// **`gear_request` steps are detected, not executed.** `04`'s own spec
/// calls for handing these off to the existing `GearDesignScreen`/
/// `GearChainDesignScreen`/`BevelDesignScreen`, pre-filled, *targeting this
/// same Part*. Confirmed by direct check while implementing this: none of
/// those three screens has any "target an existing Part" concept at all -
/// each unconditionally calls `createPart` itself and navigates into
/// `PartScreen` on success (`GearDesignScreen._create`, and its siblings'
/// own equivalents). Making that hand-off land in the *same* Part this
/// translator is building would mean reworking three already-shipped,
/// tested screens' creation/navigation flow - real, separate scope this
/// session deliberately doesn't take on alongside the translator engine
/// itself. [execute] stops at a `gear_request` step (same "stop
/// immediately, leave everything already created in place" shape as a
/// real step failure - see [PlanTranslationOutcome.gearRequestEncountered])
/// and surfaces a clear, honest message instead of a broken or
/// wrong-Part hand-off. A real, deliberate v1 gap - see this file's own
/// note in `04-translator-and-execution.md`.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
import '../assembly/add_component.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import 'ai_plan.dart';

/// Where a step landed in [PlanTranslator.execute]'s walk - drives the
/// Review & Generate panel's per-step pending -> in-progress -> done/failed
/// progress UI (`04`'s own "mirrors this app's existing eager-feature-
/// preview convention").
enum TranslationStepStatus { pending, inProgress, done, failed }

/// Why [PlanTranslator.execute] stopped (or finished).
enum PlanTranslationOutcome {
  /// Every step executed for real, in order.
  success,

  /// Workstream 5's pre-flight dry-run reported at least one `ok: false`
  /// entry - execution never started, nothing was created.
  validationFailed,

  /// A step's real HTTP call failed for real (a genuine geometry error
  /// the dry run's simplified checks didn't catch). Execution stopped
  /// immediately; every Feature already created up to that point stays in
  /// place - no automatic rollback (`00-conventions.md`'s own explicit
  /// reasoning).
  stepFailed,

  /// A `gear_request` step was reached - see this file's own top-level doc
  /// comment for why this stops rather than attempting a hand-off.
  gearRequestEncountered,
}

/// The result of one [PlanTranslator.execute] run - always carries
/// [createdFeatureIds] (possibly empty), since even a run that stopped
/// partway through may have real Features to offer "Undo this generation"
/// for.
class PlanTranslationResult {
  final PlanTranslationOutcome outcome;

  /// Every plan `local_id` resolved to a real backend id so far - a
  /// SketchFeature/Extrude/Revolve/Sweep/Fillet/Chamfer/Shell/Pattern/Mirror/
  /// CreatePlane step's own real Feature id, or a sketch-entity step's
  /// real Point/Line/Circle/Arc/Ellipse/Polygon/Slot/Rectangle id.
  final Map<String, String> localIdToRealId;

  /// The real Feature ids actually created, in creation order - the
  /// subset of [localIdToRealId]'s values that name a real Feature (never
  /// a raw sketch-entity id) - what "Undo this generation" deletes, in
  /// reverse.
  final List<String> createdFeatureIds;

  /// Workstream 5's full per-step pre-flight dry-run report - `execute()`
  /// always runs this one validate call before doing anything else, so
  /// it's populated regardless of [outcome], not just on
  /// [PlanTranslationOutcome.validationFailed].
  final List<AiPlanStepResultDto> preflightResults;

  /// Only set when [outcome] is [PlanTranslationOutcome.stepFailed] or
  /// [PlanTranslationOutcome.gearRequestEncountered] - the index into
  /// [AiGenerationPlan.steps] execution stopped at.
  final int? stoppedAtIndex;

  /// Only set alongside [stoppedAtIndex] - that step's own `local_id`.
  final String? stoppedAtLocalId;

  /// Only set when [outcome] is [PlanTranslationOutcome.stepFailed] - the
  /// real backend error text.
  final String? errorMessage;

  const PlanTranslationResult._({
    required this.outcome,
    required this.localIdToRealId,
    required this.createdFeatureIds,
    required this.preflightResults,
    this.stoppedAtIndex,
    this.stoppedAtLocalId,
    this.errorMessage,
  });

  factory PlanTranslationResult.success({
    required Map<String, String> localIdToRealId,
    required List<String> createdFeatureIds,
    required List<AiPlanStepResultDto> preflightResults,
  }) =>
      PlanTranslationResult._(
        outcome: PlanTranslationOutcome.success,
        localIdToRealId: localIdToRealId,
        createdFeatureIds: createdFeatureIds,
        preflightResults: preflightResults,
      );

  factory PlanTranslationResult.validationFailed(List<AiPlanStepResultDto> results) => PlanTranslationResult._(
        outcome: PlanTranslationOutcome.validationFailed,
        localIdToRealId: const {},
        createdFeatureIds: const [],
        preflightResults: results,
      );

  factory PlanTranslationResult.stepFailed({
    required int index,
    required String localId,
    required String message,
    required Map<String, String> localIdToRealId,
    required List<String> createdFeatureIds,
    required List<AiPlanStepResultDto> preflightResults,
  }) =>
      PlanTranslationResult._(
        outcome: PlanTranslationOutcome.stepFailed,
        localIdToRealId: localIdToRealId,
        createdFeatureIds: createdFeatureIds,
        preflightResults: preflightResults,
        stoppedAtIndex: index,
        stoppedAtLocalId: localId,
        errorMessage: message,
      );

  factory PlanTranslationResult.gearRequestEncountered({
    required int index,
    required String localId,
    required Map<String, String> localIdToRealId,
    required List<String> createdFeatureIds,
    required List<AiPlanStepResultDto> preflightResults,
  }) =>
      PlanTranslationResult._(
        outcome: PlanTranslationOutcome.gearRequestEncountered,
        localIdToRealId: localIdToRealId,
        createdFeatureIds: createdFeatureIds,
        preflightResults: preflightResults,
        stoppedAtIndex: index,
        stoppedAtLocalId: localId,
      );
}

/// The step kinds that produce a real backend Feature (as opposed to a raw
/// sketch-entity id) - see [PlanTranslationResult.createdFeatureIds].
const Set<String> _featureProducingKinds = {
  'sketch',
  'extrude',
  'revolve',
  'sweep',
  'fillet',
  'chamfer',
  'shell',
  'pattern',
  'mirror',
  'create_plane',
  'loft',
  'merge',
  'boolean',
  'delete_body',
  'scale_body',
  'move_body',
};

/// Assembly support Phase 8 (`docs/assembly-scope.md` §2k), widened by
/// Phase 18 (§6 `[2]`): every `AiMateEntityRefStep.occurrenceId`/
/// `AiMoveComponentStep.occurrenceId`/etc. is `""` (this Part's own root
/// content - never a real Occurrence to resolve), `existing:<occurrence_id>`
/// (a real, already-placed Occurrence), or - since Phase 18 - a bare
/// plan-local `local_id` naming an `AiAddComponentStep` earlier in this same
/// plan, resolved through [ids] exactly like [_resolveId] already does for
/// Features/sketch entities. `_run_step`'s own `reserved_local_id_prefix`
/// check (backend) guarantees a step's own `local_id` never itself starts
/// with `existing:`, so the two branches below can never be ambiguous.
String _resolveOccurrenceId(String occurrenceId, Map<String, String> ids) {
  if (occurrenceId.isEmpty) return '';
  if (occurrenceId.startsWith('existing:')) return occurrenceId.substring('existing:'.length);
  return ids[occurrenceId]!;
}

const Map<Type, String> _entityTypeForStepType = {
  AiSketchLineStep: 'line',
  AiSketchCircleStep: 'circle',
  AiSketchArcStep: 'arc',
  AiSketchEllipseStep: 'ellipse',
  AiSketchPolygonStep: 'polygon',
  AiSketchSlotStep: 'slot',
  AiSketchRectangleStep: 'rectangle',
};

double _degToRad(double degrees) => degrees * math.pi / 180.0;

/// Existing-Part editing (docs/ai-modelling/09-existing-part-editing.md):
/// the `existing:<id>` convention's client-side resolution. A local_id
/// naming a real, already-built Feature (rather than an earlier step in
/// *this* plan) carries its real Feature id verbatim after the prefix -
/// `existing:<id>` always means Feature id `<id>`, exactly the same real
/// id [DocumentApiClient.listFeatures] already returned it under - so no
/// lookup is needed for `ids` (the plan-local-id -> real-Feature/entity-id
/// map), just a strip. Every `ids[localId]!` call site in [_executeStep]
/// (and its own helpers) goes through this instead - see `sketchIds`'s own
/// pre-seeding in [PlanTranslator.execute] for why `sketchIds[localId]!`
/// call sites need no equivalent change: `existing:<sketch_feature_id>`
/// resolves to a real *Sketch* id, not a Feature id, so stripping the
/// prefix would give the wrong value there - pre-seeding the map under
/// that exact key instead keeps every existing `sketchIds[...]!` call site
/// correct unmodified.
String _resolveId(String localId, Map<String, String> ids) =>
    localId.startsWith('existing:') ? localId.substring('existing:'.length) : ids[localId]!;

class PlanTranslator {
  final DocumentApiClient documentApi;
  final SketchApiClient sketchApi;

  /// Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`): both
  /// nullable - only an `add_component` step needs either, and a plan with
  /// none of those can be executed with neither set (see the
  /// `AiAddComponentStep` case in [_executeStep] for the clear failure this
  /// produces if that step is encountered anyway).
  final StorageService? storageService;
  final ProjectRoot? projectRoot;

  PlanTranslator({
    DocumentApiClient? documentApi,
    SketchApiClient? sketchApi,
    this.storageService,
    this.projectRoot,
  })  : documentApi = documentApi ?? DocumentApiClient(),
        sketchApi = sketchApi ?? SketchApiClient();

  /// `04`'s own "Pre-flight" + "Real execution" sections, back to back:
  /// validates the whole plan first (nothing runs for real on any `ok:
  /// false`), then walks [plan]'s steps in order against the real [partId],
  /// stopping immediately on the first real failure or `gear_request` step.
  /// [onStepStatusChanged] drives the Review & Generate panel's progress UI.
  Future<PlanTranslationResult> execute({
    required AiGenerationPlan plan,
    required String partId,
    List<FeatureDto> existingFeatures = const [],
    Set<String> disabledKinds = const {},
    void Function(int index, TranslationStepStatus status)? onStepStatusChanged,
  }) async {
    final validation = await documentApi.validateAiPlan(partId, plan.toJson(), disabledKinds: disabledKinds);
    if (validation.results.any((r) => !r.ok)) {
      return PlanTranslationResult.validationFailed(validation.results);
    }
    final resolvedEdgesByLocalId = <String, List<SubShapeRefDto>>{
      for (final r in validation.results)
        if (r.resolvedEdges != null) r.localId: r.resolvedEdges!,
    };
    // `resolvedEdgesByLocalId`'s own Shell-specific sibling: a `shell` step's
    // `faces_to_remove` world-axis selector needs real OCCT topology to
    // resolve too, never available client-side - see `StepResult.
    // resolved_faces`'s own doc comment in `ai_plan_schemas.py`.
    final resolvedFacesByLocalId = <String, List<SubShapeRefDto>>{
      for (final r in validation.results)
        if (r.resolvedFaces != null) r.localId: r.resolvedFaces!,
    };
    // Assembly support Phase 14 (`docs/assembly-scope.md` §6 `[3]`): the
    // resolved index for any `mate` step reference that used `edgeSelector`
    // - `resolvedEdgesByLocalId`'s own sibling, one level down (per-
    // reference within a step, not per-step) since a Mate has exactly two
    // references and at most one or both may have used a selector.
    final resolvedMateReferencesByLocalId = <String, List<SubShapeRefDto?>>{
      for (final r in validation.results)
        if (r.resolvedMateReferences != null) r.localId: r.resolvedMateReferences!,
    };

    final localIdToRealId = <String, String>{};
    // Existing-Part editing: an `existing:<feature_id>` naming a real
    // SketchFeature must resolve to that Sketch's own real id wherever a
    // step reads `sketchIds[...]` (every sketch-entity step's own
    // `sketch_feature_id`) - pre-seeded here under the exact
    // `existing:<feature_id>` key so those call sites work completely
    // unmodified, the same way `sketchIdByLocalId` is otherwise only ever
    // populated as a brand-new `AiSketchStep` executes. Harmless (never
    // read) for a fresh-Part generation, where [existingFeatures] is empty.
    final sketchIdByLocalId = <String, String>{
      for (final f in existingFeatures)
        if (f.produces == 'sketch' && f.sketchId != null) 'existing:${f.id}': f.sketchId!,
    };
    final createdFeatureIds = <String>[];

    for (var i = 0; i < plan.steps.length; i++) {
      final step = plan.steps[i];

      if (step is AiGearRequestStep) {
        return PlanTranslationResult.gearRequestEncountered(
          index: i,
          localId: step.localId,
          localIdToRealId: localIdToRealId,
          createdFeatureIds: createdFeatureIds,
          preflightResults: validation.results,
        );
      }

      onStepStatusChanged?.call(i, TranslationStepStatus.inProgress);
      try {
        final realId = await _executeStep(
          step,
          plan: plan,
          partId: partId,
          ids: localIdToRealId,
          sketchIds: sketchIdByLocalId,
          resolvedEdgesByLocalId: resolvedEdgesByLocalId,
          resolvedMateReferencesByLocalId: resolvedMateReferencesByLocalId,
          resolvedFacesByLocalId: resolvedFacesByLocalId,
        );
        localIdToRealId[step.localId] = realId;
        if (_featureProducingKinds.contains(step.kind)) createdFeatureIds.add(realId);
        onStepStatusChanged?.call(i, TranslationStepStatus.done);
      } on ApiException catch (e) {
        onStepStatusChanged?.call(i, TranslationStepStatus.failed);
        return PlanTranslationResult.stepFailed(
          index: i,
          localId: step.localId,
          message: e.message,
          localIdToRealId: localIdToRealId,
          createdFeatureIds: createdFeatureIds,
          preflightResults: validation.results,
        );
      }
    }

    return PlanTranslationResult.success(
      localIdToRealId: localIdToRealId,
      createdFeatureIds: createdFeatureIds,
      preflightResults: validation.results,
    );
  }

  /// The "Undo this generation" bolt-on (`04`'s own section): deletes
  /// every Feature this translator created, in **reverse** creation order,
  /// via [DocumentApiClient.cascadeDeleteFeature] - not the plain single-
  /// Feature delete, which never cleans up a deleted SketchFeature's own
  /// Sketch (confirmed by reading `Part.delete_feature`: it only pops the
  /// Feature list, nothing else). Safe to use per-Feature here despite its
  /// "also deletes transitive dependents" behavior: reverse creation order
  /// guarantees nothing depending on the Feature being deleted still
  /// exists by the time its turn comes, so each call's own cascade is
  /// always empty beyond the Feature (and its owned Sketch) itself.
  Future<void> undo({required String partId, required List<String> createdFeatureIds}) async {
    for (final featureId in createdFeatureIds.reversed) {
      await documentApi.cascadeDeleteFeature(partId, featureId);
    }
  }

  /// AI Modelling's dimension-driven-sketches workstream (`docs/ai-
  /// modelling/08-dimension-driven-sketches.md`): Circle/Arc/Ellipse/
  /// Polygon/Slot creation already auto-creates their own size-defining
  /// `DistanceConstraint` *provisional* (skipped entirely by the solver
  /// until a real value is confirmed - see the backend `DistanceConstraint.
  /// provisional`'s own doc comment), exactly like a human's freshly-drawn,
  /// not-yet-dimensioned shape. This confirms it with the entity's own
  /// just-created radius via the same PATCH endpoint the dimension bar
  /// itself calls (`SketchApiClient.updateConstraintValue`) - turning "no
  /// real dimension at all" into a real, editable one at the AI's own
  /// intended size, in one call. [constraintId] is nullable only for the
  /// same test/back-compat reason the DTOs themselves keep it nullable
  /// (see e.g. [CircleDto.radiusConstraintId]'s own doc comment) - always
  /// present on a real backend response.
  Future<void> _confirmRadius(String sketchId, String? constraintId, double value) async {
    if (constraintId == null) return;
    await sketchApi.updateConstraintValue(sketchId, constraintId, value);
  }

  Future<String> _executeStep(
    AiPlanStep step, {
    required AiGenerationPlan plan,
    required String partId,
    required Map<String, String> ids,
    required Map<String, String> sketchIds,
    required Map<String, List<SubShapeRefDto>> resolvedEdgesByLocalId,
    required Map<String, List<SubShapeRefDto?>> resolvedMateReferencesByLocalId,
    required Map<String, List<SubShapeRefDto>> resolvedFacesByLocalId,
  }) async {
    switch (step) {
      case AiSketchStep():
        final feature = await documentApi.createSketchFeature(
          partId,
          plane: step.plane?.wireValue,
          planeFeatureId: step.planeFeatureId == null ? null : _resolveId(step.planeFeatureId!, ids),
        );
        sketchIds[step.localId] = feature.sketchId!;
        return feature.id;

      case AiSketchPointStep():
        final point = await sketchApi.createPoint(sketchIds[step.sketchFeatureId]!, step.x, step.y);
        return point.id;

      case AiSketchLineStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final startId = _resolveId(step.startPointId, ids);
        String endId;
        if (step.endPointId != null) {
          endId = _resolveId(step.endPointId!, ids);
        } else {
          final start = _pointXY(plan, step.startPointId);
          final rad = _degToRad(step.angle!);
          final end = await sketchApi.createPoint(
            sketchId,
            start.x + step.length! * math.cos(rad),
            start.y + step.length! * math.sin(rad),
          );
          endId = end.id;
        }
        final line = await sketchApi.createLine(sketchId, startId, endId, construction: step.construction);
        // 08's own "Line length": unlike Circle/Arc/Ellipse/Polygon/Slot, a
        // Line has no automatic size-defining constraint at all - only add
        // one when the plan itself named a literal length. `angle`-only
        // dimensioning is a real, deliberate v1-of-this-workstream gap (no
        // second reference line exists yet to constrain an angle against) -
        // see that doc's own note.
        if (step.length != null) {
          await sketchApi.createDistanceConstraint(
            sketchId,
            line.startPointId,
            line.endPointId,
            step.length!,
            orientation: 'linear',
            provisional: false,
          );
        }
        return line.id;

      case AiSketchCircleStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = _resolveId(step.centerPointId, ids);
        String radiusPointId;
        if (step.radiusPointId != null) {
          radiusPointId = _resolveId(step.radiusPointId!, ids);
        } else {
          final center = _pointXY(plan, step.centerPointId);
          final radiusPoint = step.angle == null
              ? await sketchApi.createPoint(sketchId, center.x, center.y + step.radius!)
              : await sketchApi.createPoint(
                  sketchId,
                  center.x + step.radius! * math.cos(_degToRad(step.angle!)),
                  center.y + step.radius! * math.sin(_degToRad(step.angle!)),
                );
          radiusPointId = radiusPoint.id;
        }
        final circle = await sketchApi.createCircle(sketchId, centerId, radiusPointId, construction: step.construction);
        await _confirmRadius(sketchId, circle.radiusConstraintId, circle.radius);
        return circle.id;

      case AiSketchArcStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = _resolveId(step.centerPointId, ids);
        final startId = _resolveId(step.startPointId, ids);
        String endId;
        if (step.endPointId != null) {
          endId = _resolveId(step.endPointId!, ids);
        } else {
          final center = _pointXY(plan, step.centerPointId);
          final start = _pointXY(plan, step.startPointId);
          final radius = math.sqrt(math.pow(start.x - center.x, 2) + math.pow(start.y - center.y, 2));
          final rad = _degToRad(step.endAngle!);
          final end = await sketchApi.createPoint(
            sketchId,
            center.x + radius * math.cos(rad),
            center.y + radius * math.sin(rad),
          );
          endId = end.id;
        }
        final arc = await sketchApi.createArc(sketchId, centerId, startId, endId, construction: step.construction);
        await _confirmRadius(sketchId, arc.radiusConstraintId, arc.radius);
        return arc.id;

      case AiSketchEllipseStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = _resolveId(step.centerPointId, ids);
        String majorPointId;
        if (step.majorPointId != null) {
          majorPointId = _resolveId(step.majorPointId!, ids);
        } else {
          final center = _pointXY(plan, step.centerPointId);
          final rad = _degToRad(step.angle!);
          final majorPoint = await sketchApi.createPoint(
            sketchId,
            center.x + step.majorRadius! * math.cos(rad),
            center.y + step.majorRadius! * math.sin(rad),
          );
          majorPointId = majorPoint.id;
        }
        final ellipse = await sketchApi.createEllipse(
          sketchId,
          centerId,
          majorPointId,
          step.minorRadius,
          construction: step.construction,
        );
        await _confirmRadius(sketchId, ellipse.majorConstraintId, ellipse.majorRadius);
        await _confirmRadius(sketchId, ellipse.minorConstraintId, ellipse.minorRadius);
        return ellipse.id;

      case AiSketchPolygonStep():
        final polygonSketchId = sketchIds[step.sketchFeatureId]!;
        final polygon = await sketchApi.createPolygon(
          polygonSketchId,
          _resolveId(step.centerPointId, ids),
          _resolveId(step.firstVertexPointId, ids),
          step.sides,
          construction: step.construction,
          referenceCircles: step.referenceCircles,
        );
        await _confirmRadius(polygonSketchId, polygon.radiusConstraintId, polygon.radius);
        return polygon.id;

      case AiSketchSlotStep():
        final slotSketchId = sketchIds[step.sketchFeatureId]!;
        final slot = await sketchApi.createSlot(
          slotSketchId,
          _resolveId(step.center1PointId, ids),
          _resolveId(step.center2PointId, ids),
          step.radius,
          construction: step.construction,
        );
        await _confirmRadius(slotSketchId, slot.radiusConstraintId, slot.radius);
        return slot.id;

      case AiSketchRectangleStep():
        final rectangleSketchId = sketchIds[step.sketchFeatureId]!;
        final cornerIds = [for (final p in step.cornerPointIds) _resolveId(p, ids)];
        final rectangle = await sketchApi.createRectangle(
          rectangleSketchId,
          cornerIds,
          axisAligned: step.axisAligned,
          construction: step.construction,
        );
        // 08's own "Rectangle width/height": corner0->corner1 is width,
        // corner1->corner2 is height - the same two edges `axisAligned`
        // already pins Horizontal/Vertical, so a "horizontal"/"vertical"-
        // orientation dimension here is an orthogonal DOF, never redundant
        // with those direction constraints. A non-axis-aligned rectangle
        // has no global horizontal/vertical to pin, so a plain "linear"
        // distance is used instead - still that edge's own real length.
        if (step.width != null) {
          await sketchApi.createDistanceConstraint(
            rectangleSketchId,
            cornerIds[0],
            cornerIds[1],
            step.width!,
            orientation: step.axisAligned ? 'horizontal' : 'linear',
          );
        }
        if (step.height != null) {
          await sketchApi.createDistanceConstraint(
            rectangleSketchId,
            cornerIds[1],
            cornerIds[2],
            step.height!,
            orientation: step.axisAligned ? 'vertical' : 'linear',
          );
        }
        return rectangle.id;

      case AiExtrudeStep():
        final feature = await documentApi.createExtrudeFeature(
          partId,
          sketchFeatureId: _resolveId(step.sketchFeatureId, ids),
          extrudeType: step.extrudeType.wireValue,
          startDistance: step.startDistance,
          endDistance: step.endDistance,
          targetBodyIds: [for (final t in step.targetBodyIds) _resolveId(t, ids)],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiRevolveStep():
        final feature = await documentApi.createRevolveFeature(
          partId,
          sketchFeatureId: _resolveId(step.sketchFeatureId, ids),
          axisRef: _entityRef(plan, ids, sketchIds, step.axisRef),
          angle: step.angle,
          mode: step.mode.wireValue,
          targetBodyIds: [for (final t in step.targetBodyIds) _resolveId(t, ids)],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiSweepStep():
        final feature = await documentApi.createSweepFeature(
          partId,
          sketchFeatureId: _resolveId(step.sketchFeatureId, ids),
          pathRefs: _entityRefs(plan, ids, sketchIds, step.pathRefs),
          mode: step.mode.wireValue,
          targetBodyIds: [for (final t in step.targetBodyIds) _resolveId(t, ids)],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiFilletStep():
        final planEdges = resolvedEdgesByLocalId[step.localId]!;
        // `edges.of` is required (validated server-side, `_resolve_edges`'s
        // own runtime check) for a fillet/chamfer step specifically - only
        // optional at the schema level so the same `AiEdgeSelector` type can
        // also serve `AiMateEntityRefStep.edgeSelector` (Phase 14, which has
        // no plan-local Body-producing step to name `of` with at all - see
        // that field's own doc comment). A plan that reaches real execution
        // already passed workstream 5's own dry-run validate, which would
        // have failed this step already had `of` been omitted.
        final feature = await documentApi.createFilletFeature(
          partId,
          edgeRefs: [for (final e in planEdges) _realSubShapeRef(step.edges.of!, e, ids)],
          radius: step.radius,
        );
        return feature.id;

      case AiChamferStep():
        final planEdges = resolvedEdgesByLocalId[step.localId]!;
        final feature = await documentApi.createChamferFeature(
          partId,
          edgeRefs: [for (final e in planEdges) _realSubShapeRef(step.edges.of!, e, ids)],
          distance: step.distance,
        );
        return feature.id;

      case AiShellStep():
        // `bodyId` (a separate `ShellFeature` field, unlike Fillet/Chamfer's
        // edge-refs-only shape) must carry the same `#N` multi-solid suffix
        // every resolved face ref itself does - `_realSubShapeRef` already
        // derives that from `step.bodyOf`'s own real id, so the first
        // rewritten face's `bodyId` is reused rather than re-deriving the
        // suffix by hand (`faces_to_remove` is guaranteed non-empty by the
        // backend's own `invalid_step_payload` check this plan already
        // passed dry-run validation for).
        final realFaces = [for (final f in resolvedFacesByLocalId[step.localId]!) _realSubShapeRef(step.bodyOf, f, ids)];
        final feature = await documentApi.createShellFeature(
          partId,
          bodyId: realFaces.first.bodyId,
          facesToRemove: realFaces,
          thickness: step.thickness,
          thicknessDirection: step.thicknessDirection,
        );
        return feature.id;

      case AiPatternStep():
        final feature = await documentApi.createPatternFeature(
          partId,
          sourceBodyIds: [for (final s in step.sourceBodyIds) _resolveId(s, ids)],
          patternType: step.patternType.wireValue,
          direction1: _patternDirectionRef(plan, ids, sketchIds, step.direction1),
          count1: step.count1,
          spacing1: step.spacing1,
          reverse1: step.reverse1,
          direction2: _patternDirectionRef(plan, ids, sketchIds, step.direction2),
          count2: step.count2,
          spacing2: step.spacing2,
          reverse2: step.reverse2,
          axis: _patternAxisRef(plan, ids, sketchIds, step.axis),
          countAngular: step.countAngular,
          angleTotal: step.angleTotal,
          reverseAngular: step.reverseAngular,
          skipIndices: step.skipIndices,
          merge: step.merge == AiMergeMode.fuseIntoOne ? MergeMode.fuseIntoOne : MergeMode.keepSeparate,
          toolFeatureId: step.toolFeatureId == null ? null : _resolveId(step.toolFeatureId!, ids),
        );
        return feature.id;

      case AiMirrorStep():
        final feature = await documentApi.createMirrorFeature(
          partId,
          sourceBodyIds: [for (final s in step.sourceBodyIds) _resolveId(s, ids)],
          mirrorPlane: PlaneRefDto(
            fixedPlane: step.mirrorPlane.fixedPlane?.wireValue,
            planeFeatureId:
                step.mirrorPlane.planeFeatureId == null ? null : _resolveId(step.mirrorPlane.planeFeatureId!, ids),
          ),
          merge: step.merge == AiMergeMode.fuseIntoOne ? MergeMode.fuseIntoOne : MergeMode.keepSeparate,
          toolFeatureId: step.toolFeatureId == null ? null : _resolveId(step.toolFeatureId!, ids),
        );
        return feature.id;

      case AiCreatePlaneStep():
        SketchEntityRefDto? lineRef;
        SketchEntityRefDto? pointRef;
        var pointRefs = const <PointRefDto>[];
        if (step.planeType == AiCreatePlaneType.normalToLineAtPoint) {
          lineRef = _entityRef(plan, ids, sketchIds, step.lineRef!);
          pointRef = _entityRef(plan, ids, sketchIds, step.pointRef!);
        } else {
          pointRefs = [
            for (final p in step.pointRefs) PointRefDto(sketchPointRef: _entityRef(plan, ids, sketchIds, p)),
          ];
        }
        final feature = await documentApi.createCreatePlaneFeature(
          partId,
          planeType: step.planeType.wireValue,
          lineRef: lineRef,
          pointRef: pointRef,
          pointRefs: pointRefs,
        );
        return feature.id;

      case AiLoftStep():
        final feature = await documentApi.createLoftFeature(
          partId,
          sections: [
            for (final s in step.sections)
              LoftSectionDto(
                sketchFeatureId: _resolveId(s.sketchFeatureId, ids),
                profileRefs: _entityRefs(plan, ids, sketchIds, s.profileRefs),
                referencePoint: s.referencePoint == null ? null : _entityRef(plan, ids, sketchIds, s.referencePoint!),
                alignmentPoint: s.alignmentPoint == null ? null : _entityRef(plan, ids, sketchIds, s.alignmentPoint!),
              ),
          ],
          mode: step.mode.wireValue,
          ruled: step.ruled,
          targetBodyIds: [for (final t in step.targetBodyIds) _resolveId(t, ids)],
          thickness: step.thickness,
          guideCurveRefs: _entityRefs(plan, ids, sketchIds, step.guideCurveRefs),
        );
        return feature.id;

      case AiMergeStep():
        final feature = await documentApi.createMergeFeature(
          partId,
          bodyIds: [for (final b in step.bodyIds) _resolveId(b, ids)],
        );
        return feature.id;

      case AiBooleanStep():
        final feature = await documentApi.createBooleanFeature(
          partId,
          operation: step.operation == AiBooleanOperation.subtract ? BooleanOperation.subtract : BooleanOperation.common,
          targetBodyIds: [for (final t in step.targetBodyIds) _resolveId(t, ids)],
          toolBodyIds: [for (final t in step.toolBodyIds) _resolveId(t, ids)],
          consumeToolBodies: step.consumeToolBodies,
        );
        return feature.id;

      case AiDeleteBodyStep():
        final feature = await documentApi.createDeleteBodyFeature(
          partId,
          bodyIds: [for (final b in step.bodyIds) _resolveId(b, ids)],
        );
        return feature.id;

      case AiScaleBodyStep():
        final feature = await documentApi.createScaleBodyFeature(
          partId,
          bodyId: _resolveId(step.bodyId, ids),
          factor: step.factor,
        );
        return feature.id;

      case AiMoveBodyStep():
        final feature = await documentApi.createMoveBodyFeature(
          partId,
          bodyId: _resolveId(step.bodyId, ids),
          delta: step.delta,
          rotationAxis: step.rotationAxis == null
              ? null
              : PatternAxisRefDto(sketchLineRef: _entityRef(plan, ids, sketchIds, step.rotationAxis!.sketchLineRef)),
          rotationAngleDegrees: step.rotationAngleDegrees,
          copy: step.makeCopy,
        );
        return feature.id;

      case AiMateStep():
        // Phase 14 (`docs/assembly-scope.md` §6 `[3]`): whichever reference(s)
        // used `edgeSelector` get the dry run's own already-resolved real
        // index substituted in (`resolvedMateReferences[i]`, `null` for a
        // reference that didn't use one - see `_mateEntityRefDto`'s own
        // doc comment) - there is no other way for this client to resolve
        // an `EdgeSelector` at all (the heuristics need real OCCT topology,
        // never available client-side).
        final resolvedReferences = resolvedMateReferencesByLocalId[step.localId];
        final mate = await documentApi.createMate(
          partId,
          type: step.type.wireValue,
          references: [
            for (var i = 0; i < step.references.length; i++)
              _mateEntityRefDto(step.references[i], resolvedReferences == null ? null : resolvedReferences[i], ids),
          ],
          value: step.value,
          flipped: step.flipped,
        );
        // Mirrors `MatePanel`'s own real-UI behavior (`docs/assembly-scope.md`
        // §2i): solve immediately so the mated Occurrence visibly snaps into
        // place. Ambiguous which of the two references is "the one being
        // moved" for a plan-authored Mate (unlike a human's own drag-then-
        // mate gesture) - the second reference is used as a reasonable
        // default (the first commonly names the fixed/anchor side), skipping
        // `""` (this Part's own root content, never a real Occurrence to
        // solve). A non-converging solve surfaces as a real `ApiException`,
        // the same "genuine geometry error the dry run's simplified checks
        // didn't catch" `PlanTranslationOutcome.stepFailed` already covers.
        final solveTarget = step.references[1].occurrenceId.isNotEmpty
            ? step.references[1].occurrenceId
            : step.references[0].occurrenceId;
        if (solveTarget.isNotEmpty) {
          await documentApi.solveForOccurrence(partId, _resolveOccurrenceId(solveTarget, ids));
        }
        return mate.id;

      case AiAddComponentStep():
        final storage = storageService;
        final root = projectRoot;
        if (storage == null || root == null) {
          throw ApiException('add_component requires an open project folder - this session has none available');
        }
        final handle = await storage.resolve(root, step.relativePath);
        if (handle == null) {
          throw ApiException('Component file not found in project: ${step.relativePath}');
        }
        final Uint8List bytes;
        try {
          bytes = await storage.readFile(handle);
        } on StorageException catch (e) {
          throw ApiException('Failed to read component file ${step.relativePath}: ${e.message}');
        }
        final Map<String, dynamic> componentPayload;
        try {
          componentPayload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        } catch (_) {
          throw ApiException('Not a valid native project file: ${step.relativePath}');
        }
        final currentPayload = await documentApi.exportNative();
        final newOccurrenceId = const Uuid().v4();
        final Map<String, dynamic> merged;
        try {
          merged = mergeComponentIntoDocument(
            currentPayload: currentPayload,
            componentPayload: componentPayload,
            rootPartId: partId,
            occurrenceId: newOccurrenceId,
            externalRef: step.relativePath,
            nameOverride: step.nameOverride,
          );
        } on AddComponentException catch (e) {
          throw ApiException(e.message);
        }
        await documentApi.importNative(merged);
        return newOccurrenceId;

      case AiMoveComponentStep():
        final occurrence = await documentApi.updateOccurrenceTransform(
          partId,
          _resolveOccurrenceId(step.occurrenceId, ids),
          RigidTransformDto(
            translation: step.translation,
            rotationAxis: step.rotationAxis,
            rotationAngleDegrees: step.rotationAngleDegrees,
          ),
        );
        return occurrence.id;

      case AiHideComponentStep():
        final occurrence = await documentApi.updateOccurrenceHidden(
          partId,
          _resolveOccurrenceId(step.occurrenceId, ids),
          true,
        );
        return occurrence.id;

      case AiIsolateComponentStep():
        final targetId = _resolveOccurrenceId(step.occurrenceId, ids);
        final siblings = await documentApi.listOccurrences(partId);
        for (final occurrence in siblings) {
          if (occurrence.hidden == (occurrence.id != targetId)) continue;
          await documentApi.updateOccurrenceHidden(partId, occurrence.id, occurrence.id != targetId);
        }
        return targetId;

      case AiPatternComponentStep():
        final pattern = await documentApi.createComponentPattern(
          partId,
          sourceOccurrenceIds: [for (final s in step.sourceOccurrenceIds) _resolveOccurrenceId(s, ids)],
          patternType: step.patternType,
          direction: step.direction,
          count: step.count,
          spacing: step.spacing,
          reverse: step.reverse,
          axis: step.axis == null
              ? null
              : ComponentPatternAxisDto(origin: step.axis!.origin, direction: step.axis!.direction),
          countAngular: step.countAngular,
          angleTotal: step.angleTotal,
          reverseAngular: step.reverseAngular,
          skipIndices: step.skipIndices,
          orientWithRotation: step.orientWithRotation,
        );
        return pattern.id;

      case AiGearRequestStep():
        throw StateError('gear_request steps are intercepted before _executeStep is called');
    }
  }

  /// [AiMateEntityRefStep] -> [MateEntityRefDto], resolving [step]'s own
  /// `occurrence_id` (`""` or `existing:<id>`) to a real id via
  /// [_resolveOccurrenceId] - every other field is already a literal,
  /// already-real ref (see that step class's own doc comment).
  ///
  /// Phase 14 (`docs/assembly-scope.md` §6 `[3]`): [resolvedSubshapeRef], when
  /// non-null, replaces [AiMateEntityRefStep.subshapeRef] outright - the
  /// dry run's own real, resolved `edgeSelector` result (see [execute]'s own
  /// `resolvedMateReferencesByLocalId`), never [step.subshapeRef] itself in
  /// that case (which, when `edgeSelector` was used, carries whatever
  /// placeholder `index` the LLM's own request happened to include, not a
  /// real one - `subshape_ref.body_id`/`shape_type` are still trusted
  /// as-is either way, since only `index` ever needed resolving).
  MateEntityRefDto _mateEntityRefDto(
    AiMateEntityRefStep step,
    SubShapeRefDto? resolvedSubshapeRef,
    Map<String, String> ids,
  ) =>
      MateEntityRefDto(
        occurrenceId: _resolveOccurrenceId(step.occurrenceId, ids),
        subshapeRef: resolvedSubshapeRef ??
            (step.subshapeRef == null
                ? null
                : SubShapeRefDto(bodyId: step.subshapeRef!.bodyId, shapeType: step.subshapeRef!.shapeType, index: step.subshapeRef!.index)),
        planeRef: step.planeRef == null
            ? null
            : PlaneRefDto(
                faceRef: step.planeRef!.faceRef == null
                    ? null
                    : SubShapeRefDto(
                        bodyId: step.planeRef!.faceRef!.bodyId,
                        shapeType: step.planeRef!.faceRef!.shapeType,
                        index: step.planeRef!.faceRef!.index,
                      ),
                fixedPlane: step.planeRef!.fixedPlane?.wireValue,
                planeFeatureId: step.planeRef!.planeFeatureId,
              ),
        pointRef: step.pointRef == null
            ? null
            : PointRefDto(
                vertexRef: step.pointRef!.vertexRef == null
                    ? null
                    : SubShapeRefDto(
                        bodyId: step.pointRef!.vertexRef!.bodyId,
                        shapeType: step.pointRef!.vertexRef!.shapeType,
                        index: step.pointRef!.vertexRef!.index,
                      ),
                sketchPointRef: step.pointRef!.sketchPointRef == null
                    ? null
                    : SketchEntityRefDto.fromJson(step.pointRef!.sketchPointRef!),
              ),
      );

  SketchEntityRefDto _entityRef(
    AiGenerationPlan plan,
    Map<String, String> ids,
    Map<String, String> sketchIds,
    String localId,
  ) {
    final step = plan.stepById(localId)!;
    final entityType = step is AiSketchPointStep ? 'point' : _entityTypeForStepType[step.runtimeType]!;
    final sketchFeatureLocalId = _sketchFeatureIdOf(step);
    return SketchEntityRefDto(
      sketchId: sketchIds[sketchFeatureLocalId]!,
      entityType: entityType,
      entityId: _resolveId(localId, ids),
    );
  }

  List<SketchEntityRefDto> _entityRefs(
    AiGenerationPlan plan,
    Map<String, String> ids,
    Map<String, String> sketchIds,
    List<String> localIds,
  ) =>
      [for (final id in localIds) _entityRef(plan, ids, sketchIds, id)];

  PatternDirectionRefDto? _patternDirectionRef(
    AiGenerationPlan plan,
    Map<String, String> ids,
    Map<String, String> sketchIds,
    AiPatternDirectionStep? step,
  ) {
    if (step == null) return null;
    return PatternDirectionRefDto(
      fixedAxis: step.fixedAxis?.wireValue,
      sketchLineRef: step.sketchLineRef == null ? null : _entityRef(plan, ids, sketchIds, step.sketchLineRef!),
    );
  }

  PatternAxisRefDto? _patternAxisRef(
    AiGenerationPlan plan,
    Map<String, String> ids,
    Map<String, String> sketchIds,
    AiPatternAxisStep? step,
  ) {
    if (step == null) return null;
    return PatternAxisRefDto(sketchLineRef: _entityRef(plan, ids, sketchIds, step.sketchLineRef));
  }
}

/// The plan-local `sketch_feature_id` field every sketch-entity step type
/// carries - used to look up which real Sketch (via `sketchIds`) an entity
/// reference belongs to. Every concrete sketch-entity [AiPlanStep] subtype
/// has exactly this field under exactly this name (mirrors the real
/// backend schemas' own field-naming consistency).
String _sketchFeatureIdOf(AiPlanStep step) => switch (step) {
      AiSketchPointStep() => step.sketchFeatureId,
      AiSketchLineStep() => step.sketchFeatureId,
      AiSketchCircleStep() => step.sketchFeatureId,
      AiSketchArcStep() => step.sketchFeatureId,
      AiSketchEllipseStep() => step.sketchFeatureId,
      AiSketchPolygonStep() => step.sketchFeatureId,
      AiSketchSlotStep() => step.sketchFeatureId,
      AiSketchRectangleStep() => step.sketchFeatureId,
      _ => throw ArgumentError('${step.kind} is not a sketch-entity step'),
    };

typedef _Point = ({double x, double y});

_Point _pointXY(AiGenerationPlan plan, String localId) {
  final step = plan.stepById(localId);
  if (step is! AiSketchPointStep) {
    throw ArgumentError('$localId is not a sketch_point step');
  }
  return (x: step.x, y: step.y);
}

/// Rewrites a `StepResult.resolved_edges` entry's local_id-keyed
/// [planEdge.bodyId] (`"{of}{suffix}"`, see that field's own doc comment)
/// back into a real [SubShapeRefDto] by substituting [ids]'s real id for
/// the known `of` local_id prefix and keeping any `#N` multi-solid suffix
/// verbatim.
SubShapeRefDto _realSubShapeRef(String of, SubShapeRefDto planEdge, Map<String, String> ids) {
  final suffix = planEdge.bodyId.substring(of.length);
  return SubShapeRefDto(bodyId: '${_resolveId(of, ids)}$suffix', shapeType: planEdge.shapeType, index: planEdge.index);
}
