import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;

/// One operation offered by the Stage 23 context action panel (Item 6) -
/// [label] is shown on the button. [enabled] was always false pre-C2 (no
/// Chamfer/Fillet/Create Plane logic existed yet); C2 is the first to ever
/// return `enabled: true` for real, for its own two Create Plane flows.
/// Prompt D wires Fillet's own callback; Prompt E wires Chamfer's.
///
/// Prompt D: [disabledReason], when non-null, is shown as a tooltip on the
/// (necessarily disabled) button - "explain, don't silently omit" (mirrors
/// the Body-only-selection guard's own style further down this file) for a
/// case where the button's *kind* of selection is right but a specific
/// property of it isn't (e.g. edges selected, but spanning more than one
/// Body) - as opposed to every other disabled scaffold action, which has no
/// reason text at all since it's simply "not built yet", not a rejected
/// selection.
class SelectionContextAction {
  final String label;
  final bool enabled;
  final String? disabledReason;

  const SelectionContextAction(this.label, {this.enabled = false, this.disabledReason});

  @override
  bool operator ==(Object other) =>
      other is SelectionContextAction &&
      other.label == label &&
      other.enabled == enabled &&
      other.disabledReason == disabledReason;

  @override
  int get hashCode => Object.hash(label, enabled, disabledReason);

  @override
  String toString() => 'SelectionContextAction($label)';
}

/// C2: resolves whether [pointEntityId] is one of [lineEntityId]'s own two
/// endpoint ids, within the Sketch Feature [sketchFeatureId] - needed to
/// gate the exactly-one-Line-plus-one-Point Create Plane combo below to
/// only the case the backend would actually accept (an arbitrary Point
/// elsewhere in the same Sketch is a legitimate, distinct selection that
/// just doesn't compose into anything yet - see this prompt's own "explicit
/// references over implicit geometric inference" scope note).
/// [contextActionsFor] stays a pure function of [Set]<[SelectionEntityRef]>
/// otherwise (it has no Sketch geometry of its own to consult), so this
/// lookup is threaded in as a callback - [PartScreen] supplies the real one
/// (backed by whatever Sketch Line data it already fetched for rendering),
/// tests supply a simple stub.
typedef PointOnLineChecker = bool Function(
  String sketchFeatureId,
  String lineEntityId,
  String pointEntityId,
);

/// On-device feedback ("allow 'point and curve' as a valid combination to
/// create a plane, on point and normal to arc" / follow-up: "it should
/// also support a point on the curve that is not the end point"):
/// [PointOnLineChecker]'s Arc-shaped sibling - whether [pointEntityId]
/// lies on [arcEntityId]'s own curve (its centre doesn't count), within
/// the Sketch Feature [sketchFeatureId]. Unlike a Line's fixed two
/// endpoints, an Arc's curve has no finite set of ids to compare against,
/// so the real implementation checks geometrically (distance from centre
/// plus sweep containment - see `PartScreen._isPointOnArc`), not by id.
typedef PointOnArcChecker = bool Function(
  String sketchFeatureId,
  String arcEntityId,
  String pointEntityId,
);

/// The Item 6 composition table: which operations are offered for a given
/// selection, based on which [SelectionEntityKind]s it contains (and, for
/// C2's two new combos, exact count and - for the sketch-entity one - the
/// actual Line/Point endpoint relationship via [isPointOnLine]). Labels for
/// mixed-kind/still-scaffolded combinations are static text describing the
/// intended operation, not dynamically computed from the selection.
List<SelectionContextAction> contextActionsFor(
  Set<SelectionEntityRef> selection, {
  PointOnLineChecker? isPointOnLine,
  PointOnArcChecker? isPointOnArc,
}) {
  if (selection.isEmpty) return const [];

  // Prompt A3: none of Create Plane/Chamfer/Fillet make sense against a
  // whole-Body selection - a Body selection doesn't compose with
  // vertex/edge/face ones in the same table below, so any selection mixing
  // a Body with something else still offers nothing (deliberately
  // suppressed rather than picking one arbitrarily), same as before.
  //
  // Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md`
  // §2.1/§4): one or more Bodies, nothing else selected - now offers
  // Mirror, the first real operation a Body-only selection has ever
  // enabled. On-device UX feedback on the guided "New > Mirror" flow pulled
  // multi-body seeding forward from its original Phase 6 scoping into
  // Phase 1 directly (see `MirrorFeature`'s own updated backend docstring),
  // so any positive count of Bodies - not just exactly one - enables this
  // now. Checked before the generic mixed-Body guard below, same precedence
  // pattern the single/two-plane-like checks further down use against their
  // own generic buckets.
  // Pattern/Mirror scoping's Phase 2/6 (`docs/pattern-mirror-scope.md`
  // §2.2/§2.8/§4): a Body-only selection also offers Pattern - Phase 6
  // widened Pattern's own `source_body_ids` from Phase 2's original
  // exactly-one to 1+ (mirroring Mirror's own Phase 1 revision exactly -
  // see `PatternFeature`'s own backend docstring), so any positive count of
  // Bodies now enables both Mirror and Pattern identically.
  final bodies = selection.where((s) => s.kind == SelectionEntityKind.body).toList();
  if (bodies.isNotEmpty) {
    if (bodies.length == selection.length) {
      // Boolean family, first entry: 2+ Bodies, nothing else selected, also
      // offers Merge alongside Mirror/Pattern - a new precedence branch
      // rather than replacing the existing one, since a single Body has
      // nothing to merge with (Mirror/Pattern stay offered for exactly one,
      // unchanged from before this addition).
      // Boolean family, Subtract/Common: the same 2+ Bodies selection also
      // offers Subtract/Common alongside Merge - an ambient selection can't
      // disambiguate which Bodies should be a target vs. a tool the way the
      // guided flow's own two-stage picker does, so both buttons pre-seed
      // the *entire* current selection as targets and jump straight to
      // tool-picking (see `PartScreen._onBooleanTapped`'s own doc comment).
      if (bodies.length >= 2) {
        return const [
          SelectionContextAction('Mirror', enabled: true),
          SelectionContextAction('Pattern', enabled: true),
          SelectionContextAction('Merge', enabled: true),
          SelectionContextAction('Subtract', enabled: true),
          SelectionContextAction('Common', enabled: true),
        ];
      }
      return const [
        SelectionContextAction('Mirror', enabled: true),
        SelectionContextAction('Pattern', enabled: true),
      ];
    }
    return const [];
  }

  final sketchPoints = selection.where((s) => s.kind == SelectionEntityKind.sketchPoint).toList();
  final sketchLines = selection.where((s) => s.kind == SelectionEntityKind.sketchLine).toList();
  final sketchArcs = selection.where((s) => s.kind == SelectionEntityKind.sketchArc).toList();
  final vertices = selection.where((s) => s.kind == SelectionEntityKind.vertex).toList();

  // C4: exactly three points total, nothing else - Three Points, mixing Body
  // Vertices and Sketch Points freely (any split between the two, including
  // all-vertex or all-sketch-point). Checked before the sketch-entity-only
  // branch just below, which would otherwise incorrectly swallow a selection
  // like 2 Sketch Points + 1 Vertex as "not exactly 1 line + 1 point, so
  // offers nothing" - and before the generic hasVertex-alone bucket further
  // down, for the same reason the single/two-face checks below take
  // precedence over their own generic buckets.
  if (sketchPoints.length + vertices.length == 3 && selection.length == 3) {
    return const [SelectionContextAction('Create Plane (Three Points)', enabled: true)];
  }

  if (sketchPoints.isNotEmpty || sketchLines.isNotEmpty || sketchArcs.isNotEmpty) {
    // C2: the one sketch-entity combo this prompt wires (normal-to-line-at-
    // point) - everything else involving a Sketch Point/Line (a lone Point,
    // a lone Line, two of either, a Point that isn't the Line's own
    // endpoint, or anything mixed with a Body sub-shape) offers nothing
    // yet, same "not every combination has to compose into something"
    // precedent the Body-selection guard above already sets. Without this
    // whole branch, a lone sketchPoint (say) would otherwise fall through
    // to the generic vertex/edge/face buckets below and nonsensically
    // offer a placeholder "Create Plane", since hasFace/hasEdge/hasVertex
    // would all be false for it.
    //
    // On-device feedback ("allow 'point and curve' as a valid combination
    // to create a plane, on point and normal to arc"): a second sketch-
    // entity combo, normal-to-arc-at-point - a Sketch Arc plus the Point
    // that's one of its own two endpoints, same "explicit references over
    // implicit geometric inference" shape the Line combo above already
    // uses, just checked via [isPointOnArc] instead of [isPointOnLine].
    final onlySketchEntities =
        selection.length == sketchPoints.length + sketchLines.length + sketchArcs.length;
    if (onlySketchEntities && sketchPoints.length == 1 && sketchLines.length == 1 && sketchArcs.isEmpty) {
      final point = sketchPoints.single;
      final line = sketchLines.single;
      final sameFeature = point.sketchFeatureId == line.sketchFeatureId;
      final isEndpoint = sameFeature &&
          (isPointOnLine?.call(line.sketchFeatureId, line.sketchEntityId, point.sketchEntityId) ??
              false);
      if (isEndpoint) {
        return const [SelectionContextAction('Create Plane', enabled: true)];
      }
    }
    if (onlySketchEntities && sketchPoints.length == 1 && sketchArcs.length == 1 && sketchLines.isEmpty) {
      final point = sketchPoints.single;
      final arc = sketchArcs.single;
      final sameFeature = point.sketchFeatureId == arc.sketchFeatureId;
      final isEndpoint = sameFeature &&
          (isPointOnArc?.call(arc.sketchFeatureId, arc.sketchEntityId, point.sketchEntityId) ?? false);
      if (isEndpoint) {
        return const [SelectionContextAction('Create Plane', enabled: true)];
      }
    }
    return const [];
  }

  final faces = selection.where((s) => s.kind == SelectionEntityKind.face).toList();
  final edges = selection.where((s) => s.kind == SelectionEntityKind.edge).toList();
  final hasFace = faces.isNotEmpty;
  final hasEdge = edges.isNotEmpty;
  final hasVertex = vertices.isNotEmpty;

  // C5: a `referencePlane`/`createPlane` entity is "plane-like" for exactly
  // the three Create Plane combos below (OFFSET_FACE/MIDPLANE/PARALLEL_TO_
  // FACE_THROUGH_VERTEX all now accept a `PlaneRefDto` - a Body face, a
  // fixed reference plane, or an existing Plane - in place of a bare
  // face_ref, see the backend's `PlaneRef`) - deliberately kept out of
  // `hasFace`/`faces` themselves, which stay strictly Body faces, so the
  // Chamfer/Fillet/`hasEdge && hasFace` branches below (real Body-topology
  // operations a plane can't participate in) are unaffected.
  final referencePlanes = selection.where((s) => s.kind == SelectionEntityKind.referencePlane).toList();
  final createPlanes = selection.where((s) => s.kind == SelectionEntityKind.createPlane).toList();
  final planeLikeCount = faces.length + referencePlanes.length + createPlanes.length;

  // C2/C5: exactly one plane-like entity, nothing else - the other real
  // Create Plane flow this prompt wires (offset-from-face/-plane). Checked
  // before the generic buckets below so it takes precedence over the old
  // scaffolded "face(s) alone" placeholder those still cover for 2+ faces.
  if (planeLikeCount == 1 && selection.length == 1) {
    // On-device feedback: a single Body face alone also offers "New Sketch
    // on Face" alongside Create Plane - a one-step shortcut that creates a
    // zero-offset plane flush against the face and immediately starts the
    // same sketch-orientation flow a plane-based new sketch already goes
    // through, rather than making the user create the plane first and then
    // separately start a sketch on it.
    //
    // On-device feedback: also offers Chamfer/Fillet directly, resolved
    // against the face's own boundary edge loop (mirrors the ambient
    // [_toggleFilletFaceEdges]/[_toggleChamferFaceEdges] "tap a face while
    // the picker is already open" convenience, just reachable before that
    // picker session exists) - a lone face was previously a dead end for
    // Fillet/Chamfer entirely, requiring the user to hunt down and select
    // its individual boundary edges by hand first.
    if (faces.length == 1) {
      return const [
        SelectionContextAction('Create Plane', enabled: true),
        SelectionContextAction('New Sketch on Face', enabled: true),
        SelectionContextAction('Chamfer', enabled: true),
        SelectionContextAction('Fillet', enabled: true),
      ];
    }
    // On-device feedback (bug fix): a lone reference plane or existing
    // Plane already offered "New Sketch" via its own tap-to-sheet flow
    // (only reachable outside Selection mode, via [PartScreen._onPlaneTap]/
    // [_onCreatePlaneFeatureTap]) - but selecting the same plane *while in*
    // Selection mode routed through this table instead, which only ever
    // returned bare "Create Plane" for it, silently dropping "New Sketch"
    // for that mode. Mirrors the face case immediately above so both
    // selection paths behave the same regardless of mode.
    return const [
      SelectionContextAction('Create Plane', enabled: true),
      SelectionContextAction('New Sketch', enabled: true),
    ];
  }

  // C3/C5: exactly two plane-like entities (any mix of Body faces, fixed
  // reference planes, and existing Planes), nothing else - Midplane,
  // equidistant between them. Checked before the generic "hasFace (2+)"
  // bucket below (still a scaffolded placeholder for 3+ faces, or 2 faces
  // mixed with an edge/vertex) so it takes precedence for exactly this
  // shape, the same way the single-plane-like OFFSET_FACE check above takes
  // precedence over that bucket for exactly one. Whether the two are
  // actually parallel is a backend-only check (see `_faces_not_parallel`) -
  // this only gates on selection *shape*, not on any geometric property the
  // client can't see.
  if (planeLikeCount == 2 && selection.length == 2) {
    return const [SelectionContextAction('Create Plane (Midplane)', enabled: true)];
  }

  if (hasEdge && hasFace) {
    // Mixed edges+faces (any vertices too) - the full operation set.
    return const [
      SelectionContextAction('Create Plane'),
      SelectionContextAction('Chamfer'),
      SelectionContextAction('Fillet'),
    ];
  }
  // C4: exactly one Edge and one Vertex, nothing else - Normal to Edge
  // Through Vertex. Checked before the generic "hasEdge && hasVertex" bucket
  // just below (still a scaffolded placeholder for any other edge/vertex
  // mix, e.g. 2+ of either), same precedence pattern the single/two-face
  // checks above use against their own generic buckets.
  if (edges.length == 1 && vertices.length == 1 && selection.length == 2) {
    return const [
      SelectionContextAction('Create Plane (Normal to Edge Through Vertex)', enabled: true),
    ];
  }
  // C4/C5: exactly one plane-like entity and one Vertex, nothing else -
  // Parallel to Face Through Vertex, same precedence pattern.
  if (planeLikeCount == 1 && vertices.length == 1 && selection.length == 2) {
    return const [
      SelectionContextAction('Create Plane (Parallel to Face Through Vertex)', enabled: true),
    ];
  }
  if (hasEdge && hasVertex) {
    return const [SelectionContextAction('Create Plane (Normal to Edge Through Vertex)')];
  }
  if (hasFace && hasVertex) {
    return const [SelectionContextAction('Create Plane (Parallel to Face Through Vertex)')];
  }
  // Prompt D: one or more edges, nothing else - Fillet (and, matching
  // Prompt E's own instruction to reuse this exact condition, Chamfer) are
  // enabled only when every selected edge belongs to the same Body (OCCT's
  // `BRepFilletAPI_MakeFillet`/`BRepFilletAPI_MakeChamfer` each operate on
  // one solid at a time - see the backend's `mixed_body_selection` error).
  // A cross-body edge selection still shows both buttons (never silently
  // omitted, matching the Body-only-selection guard's own "explain, don't
  // omit" precedent above) but disabled, with `disabledReason` set so the
  // panel can surface why.
  if (hasEdge && selection.length == edges.length) {
    final sameBody = _allSameBody(edges);
    final reason = sameBody ? null : 'Selected edges must all belong to the same Body';
    return [
      SelectionContextAction('Chamfer', enabled: sameBody, disabledReason: reason),
      SelectionContextAction('Fillet', enabled: sameBody, disabledReason: reason),
    ];
  }
  if (hasEdge) {
    return const [SelectionContextAction('Chamfer'), SelectionContextAction('Fillet')];
  }
  // hasFace (2+) || hasVertex, alone.
  return const [SelectionContextAction('Create Plane')];
}

/// Prompt D/E: whether every entry in [edges] names the same Body -
/// factored out so Fillet and Chamfer's identical "1+ edges, same Body"
/// enabling rule is checked in exactly one place, per Prompt E's own
/// instruction not to duplicate it.
bool _allSameBody(List<SelectionEntityRef> edges) => edges.map((e) => e.bodyId).toSet().length == 1;
