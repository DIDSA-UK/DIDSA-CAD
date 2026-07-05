import 'selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;

/// One operation offered by the Stage 23 context action panel (Item 6) -
/// [label] is shown on the button. [enabled] was always false pre-C2 (no
/// Chamfer/Fillet/Create Plane logic existed yet); C2 is the first to ever
/// return `enabled: true` for real, for its own two Create Plane flows -
/// see the `// TODO: wire up <action>` comment at Chamfer/Fillet's own
/// callback sites in `selection_context_panel.dart` for what's still a
/// scaffold.
class SelectionContextAction {
  final String label;
  final bool enabled;

  const SelectionContextAction(this.label, {this.enabled = false});

  @override
  bool operator ==(Object other) =>
      other is SelectionContextAction && other.label == label && other.enabled == enabled;

  @override
  int get hashCode => Object.hash(label, enabled);

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

/// The Item 6 composition table: which operations are offered for a given
/// selection, based on which [SelectionEntityKind]s it contains (and, for
/// C2's two new combos, exact count and - for the sketch-entity one - the
/// actual Line/Point endpoint relationship via [isPointOnLine]). Labels for
/// mixed-kind/still-scaffolded combinations are static text describing the
/// intended operation, not dynamically computed from the selection.
List<SelectionContextAction> contextActionsFor(
  Set<SelectionEntityRef> selection, {
  PointOnLineChecker? isPointOnLine,
}) {
  if (selection.isEmpty) return const [];

  // Prompt A3: none of Create Plane/Chamfer/Fillet make sense against a
  // whole-Body selection - without this guard, a Body-only selection would
  // fall through every branch below to the final "alone" case and
  // nonsensically offer "Create Plane". Body selections don't compose with
  // vertex/edge/face ones in the same table below; this deliberately
  // suppresses every action rather than picking one arbitrarily.
  if (selection.any((s) => s.kind == SelectionEntityKind.body)) return const [];

  final sketchPoints = selection.where((s) => s.kind == SelectionEntityKind.sketchPoint).toList();
  final sketchLines = selection.where((s) => s.kind == SelectionEntityKind.sketchLine).toList();
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

  if (sketchPoints.isNotEmpty || sketchLines.isNotEmpty) {
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
    final onlySketchEntities = selection.length == sketchPoints.length + sketchLines.length;
    if (onlySketchEntities && sketchPoints.length == 1 && sketchLines.length == 1) {
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
    return const [SelectionContextAction('Create Plane', enabled: true)];
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
  if (hasEdge) {
    return const [SelectionContextAction('Chamfer'), SelectionContextAction('Fillet')];
  }
  // hasFace (2+) || hasVertex, alone.
  return const [SelectionContextAction('Create Plane')];
}
