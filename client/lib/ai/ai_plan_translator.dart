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

import 'dart:math' as math;

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException, SketchApiClient;
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
  /// SketchFeature/Extrude/Revolve/Sweep/Fillet/Chamfer/Pattern/Mirror/
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
  'pattern',
  'mirror',
  'create_plane',
};

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

class PlanTranslator {
  final DocumentApiClient documentApi;
  final SketchApiClient sketchApi;

  PlanTranslator({DocumentApiClient? documentApi, SketchApiClient? sketchApi})
      : documentApi = documentApi ?? DocumentApiClient(),
        sketchApi = sketchApi ?? SketchApiClient();

  /// `04`'s own "Pre-flight" + "Real execution" sections, back to back:
  /// validates the whole plan first (nothing runs for real on any `ok:
  /// false`), then walks [plan]'s steps in order against the real [partId],
  /// stopping immediately on the first real failure or `gear_request` step.
  /// [onStepStatusChanged] drives the Review & Generate panel's progress UI.
  Future<PlanTranslationResult> execute({
    required AiGenerationPlan plan,
    required String partId,
    void Function(int index, TranslationStepStatus status)? onStepStatusChanged,
  }) async {
    final validation = await documentApi.validateAiPlan(partId, plan.toJson());
    if (validation.results.any((r) => !r.ok)) {
      return PlanTranslationResult.validationFailed(validation.results);
    }
    final resolvedEdgesByLocalId = <String, List<SubShapeRefDto>>{
      for (final r in validation.results)
        if (r.resolvedEdges != null) r.localId: r.resolvedEdges!,
    };

    final localIdToRealId = <String, String>{};
    final sketchIdByLocalId = <String, String>{};
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

  Future<String> _executeStep(
    AiPlanStep step, {
    required AiGenerationPlan plan,
    required String partId,
    required Map<String, String> ids,
    required Map<String, String> sketchIds,
    required Map<String, List<SubShapeRefDto>> resolvedEdgesByLocalId,
  }) async {
    switch (step) {
      case AiSketchStep():
        final feature = await documentApi.createSketchFeature(
          partId,
          plane: step.plane?.wireValue,
          planeFeatureId: step.planeFeatureId == null ? null : ids[step.planeFeatureId!],
        );
        sketchIds[step.localId] = feature.sketchId!;
        return feature.id;

      case AiSketchPointStep():
        final point = await sketchApi.createPoint(sketchIds[step.sketchFeatureId]!, step.x, step.y);
        return point.id;

      case AiSketchLineStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final startId = ids[step.startPointId]!;
        String endId;
        if (step.endPointId != null) {
          endId = ids[step.endPointId!]!;
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
        return line.id;

      case AiSketchCircleStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = ids[step.centerPointId]!;
        String radiusPointId;
        if (step.radiusPointId != null) {
          radiusPointId = ids[step.radiusPointId!]!;
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
        return circle.id;

      case AiSketchArcStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = ids[step.centerPointId]!;
        final startId = ids[step.startPointId]!;
        String endId;
        if (step.endPointId != null) {
          endId = ids[step.endPointId!]!;
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
        return arc.id;

      case AiSketchEllipseStep():
        final sketchId = sketchIds[step.sketchFeatureId]!;
        final centerId = ids[step.centerPointId]!;
        String majorPointId;
        if (step.majorPointId != null) {
          majorPointId = ids[step.majorPointId!]!;
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
        return ellipse.id;

      case AiSketchPolygonStep():
        final polygon = await sketchApi.createPolygon(
          sketchIds[step.sketchFeatureId]!,
          ids[step.centerPointId]!,
          ids[step.firstVertexPointId]!,
          step.sides,
          construction: step.construction,
          referenceCircles: step.referenceCircles,
        );
        return polygon.id;

      case AiSketchSlotStep():
        final slot = await sketchApi.createSlot(
          sketchIds[step.sketchFeatureId]!,
          ids[step.center1PointId]!,
          ids[step.center2PointId]!,
          step.radius,
          construction: step.construction,
        );
        return slot.id;

      case AiSketchRectangleStep():
        final rectangle = await sketchApi.createRectangle(
          sketchIds[step.sketchFeatureId]!,
          [for (final p in step.cornerPointIds) ids[p]!],
          axisAligned: step.axisAligned,
          construction: step.construction,
        );
        return rectangle.id;

      case AiExtrudeStep():
        final feature = await documentApi.createExtrudeFeature(
          partId,
          sketchFeatureId: ids[step.sketchFeatureId]!,
          extrudeType: step.extrudeType.wireValue,
          startDistance: step.startDistance,
          endDistance: step.endDistance,
          targetBodyIds: [for (final t in step.targetBodyIds) ids[t]!],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiRevolveStep():
        final feature = await documentApi.createRevolveFeature(
          partId,
          sketchFeatureId: ids[step.sketchFeatureId]!,
          axisRef: _entityRef(plan, ids, sketchIds, step.axisRef),
          angle: step.angle,
          mode: step.mode.wireValue,
          targetBodyIds: [for (final t in step.targetBodyIds) ids[t]!],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiSweepStep():
        final feature = await documentApi.createSweepFeature(
          partId,
          sketchFeatureId: ids[step.sketchFeatureId]!,
          pathRefs: _entityRefs(plan, ids, sketchIds, step.pathRefs),
          mode: step.mode.wireValue,
          targetBodyIds: [for (final t in step.targetBodyIds) ids[t]!],
          profileRefs: _entityRefs(plan, ids, sketchIds, step.profileRefs),
        );
        return feature.id;

      case AiFilletStep():
        final planEdges = resolvedEdgesByLocalId[step.localId]!;
        final feature = await documentApi.createFilletFeature(
          partId,
          edgeRefs: [for (final e in planEdges) _realSubShapeRef(step.edges.of, e, ids)],
          radius: step.radius,
        );
        return feature.id;

      case AiChamferStep():
        final planEdges = resolvedEdgesByLocalId[step.localId]!;
        final feature = await documentApi.createChamferFeature(
          partId,
          edgeRefs: [for (final e in planEdges) _realSubShapeRef(step.edges.of, e, ids)],
          distance: step.distance,
        );
        return feature.id;

      case AiPatternStep():
        final feature = await documentApi.createPatternFeature(
          partId,
          sourceBodyIds: [for (final s in step.sourceBodyIds) ids[s]!],
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
          toolFeatureId: step.toolFeatureId == null ? null : ids[step.toolFeatureId!],
        );
        return feature.id;

      case AiMirrorStep():
        final feature = await documentApi.createMirrorFeature(
          partId,
          sourceBodyIds: [for (final s in step.sourceBodyIds) ids[s]!],
          mirrorPlane: PlaneRefDto(
            fixedPlane: step.mirrorPlane.fixedPlane?.wireValue,
            planeFeatureId: step.mirrorPlane.planeFeatureId == null ? null : ids[step.mirrorPlane.planeFeatureId!],
          ),
          merge: step.merge == AiMergeMode.fuseIntoOne ? MergeMode.fuseIntoOne : MergeMode.keepSeparate,
          toolFeatureId: step.toolFeatureId == null ? null : ids[step.toolFeatureId!],
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

      case AiGearRequestStep():
        throw StateError('gear_request steps are intercepted before _executeStep is called');
    }
  }

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
      entityId: ids[localId]!,
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
  return SubShapeRefDto(bodyId: '${ids[of]!}$suffix', shapeType: planEdge.shapeType, index: planEdge.index);
}
