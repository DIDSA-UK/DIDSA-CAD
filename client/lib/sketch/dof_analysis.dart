/// Client-side structural degrees-of-freedom (DOF) analysis over a Sketch's
/// local points/lines/circles/constraints graph - lets the canvas colour a
/// fully-constrained Line/Circle dark green and an over-constrained one red
/// instantly, with zero backend round-trip, by counting how many degrees of
/// freedom each Constraint type removes rather than solving actual numeric
/// positions. Whether an entity is fully/under/over constrained is a
/// question about the *topology* of the constraint graph, not about solved
/// positions - see docs/sketcher-overhaul-scope.md's Phase 3 for the full
/// rationale (and why this stays client-only rather than a per-edit
/// backend round-trip).
///
/// ARCHITECTURE RULE: this is advisory/UI-only, never a second source of
/// truth. Anything consuming Sketch state programmatically (a script, an AI
/// agent driving the backend API directly) must keep reading the backend's
/// own `SolveResultDto.dof`/`converged` - this class exists purely as a
/// fast local preview for whoever is actively sketching on-device.
///
/// ALGORITHM: a simplified, honestly-approximate generalisation of 2D
/// bar-joint rigidity counting (the "pebble game" family of algorithms),
/// implemented via union-find rather than a full combinatorial pebble game:
///
///  - Every Point has 2 raw degrees of freedom (x, y), except the Sketch's
///    own origin Point, which has 0 - it's permanently pinned server-side
///    (see backend solver.py's `_FIXED_GROUP`).
///  - Every Constraint removes a fixed number of degrees of freedom from
///    whichever Points it (directly or, for a line-pair constraint, via
///    its Lines' endpoints) references - see [dofCostByConstraintType]
///    below for the exact count per type and its derivation.
///  - Points are grouped into clusters via union-find: each Constraint
///    unions every Point it references into one cluster, and adds its DOF
///    cost to that cluster's running total.
///  - A cluster is "fully constrained" once its removed-DOF total exactly
///    matches its raw-DOF total *and* it contains the origin Point - so
///    it's pinned to the fixed frame, not just internally rigid-but-
///    floating. A rigid shape with no constraint chain back to the origin
///    can still be dragged/rotated as a whole, and must not be coloured
///    green even if every Point within it is fixed relative to every
///    other.
///  - A cluster is "over-constrained" when removed-DOF exceeds raw-DOF -
///    more independent equations than freedoms, the local structural
///    signature of a redundant or conflicting Constraint.
///
/// KNOWN LIMITATION (an accepted tradeoff, not an oversight - see the
/// scope doc's own risk note): this is a *counting* approximation, not a
/// full generic-rigidity check. The real (2,3)-pebble game, generalised to
/// weighted constraints, can distinguish "this specific redundant
/// Constraint is harmless because a different combination already pins the
/// same freedom" from genuine over-constraint in edge cases this counting
/// approach cannot - e.g. a literal duplicate Constraint (same two Points,
/// same value, added twice) reads as over-constrained here even though
/// py-slvs may solve it without complaint (a consistent, merely
/// rank-deficient system). It never disagrees with the backend about the
/// *sketch-wide* scalar DOF count (the same additive counting py-slvs
/// itself reports via `SolveResultDto.dof`) - only, occasionally, about
/// which *specific* entities are responsible when something's off.
///
/// FORK NOTE: [dofCostByConstraintType] must stay in sync with
/// `backend/app/sketch/constraints.py`'s Constraint type list - cheap
/// insurance against silent drift if a future standalone fork changes the
/// backend's constraint set. Each value there is that Constraint's number
/// of independent scalar equations (see constraints.py's own per-type
/// `add_to_solver` for what each actually asserts).
library;

import '../api/sketch_api_client.dart';

/// How many degrees of freedom each Constraint type removes. Kept as its
/// own top-level constant (rather than buried in [SketchRigidity]) so it
/// reads as the single source of truth this file's header comment promises
/// to keep in sync with the backend.
const Map<String, int> dofCostByConstraintType = {
  'distance': 1, // |Pa - Pb| = d - one scalar equation, regardless of
  // linear/horizontal/vertical orientation (each pins exactly one axis or
  // one combined magnitude, never both).
  'vertical': 1, // xa = xb
  'horizontal': 1, // ya = yb
  'angle': 1, // angle(L1, L2) = value
  'coincident': 2, // xa = xb AND ya = yb
  'parallel': 1, // cross(dir(L1), dir(L2)) = 0
  'perpendicular': 1, // dot(dir(L1), dir(L2)) = 0
  'equal_length': 1, // |L1| = |L2|
  'line_distance': 1, // perpendicular distance(L1, L2) = value
  'collinear': 2, // both of L2's endpoints on L1 - two point-on-line
  // equations (see constraints.py's CollinearConstraint.add_to_solver).
  'point_line_distance': 1, // perpendicular distance(point, line) = value
  'at_midpoint': 2, // point == midpoint(line) - an x and a y equation.
};

/// Resolves a Constraint to its backend `type` discriminator string (the
/// [dofCostByConstraintType] key) and every Point id it references,
/// resolving a line-pair Constraint's Lines to their endpoint Point ids
/// via [lineStartPointId]/[lineEndPointId] - one dispatch for both, rather
/// than two separate `is`-chains that could drift out of sync with each
/// other as constraint types are added.
///
/// [ConstraintDto] carries no `type` field client-side - only
/// `ConstraintDto.fromJson`'s switch statement (sketch_api_client.dart)
/// ever sees the backend's raw JSON discriminator, so it has to be
/// re-derived here from each concrete subclass.
///
/// The client's DTOs for the line-pair types (angle/parallel/
/// perpendicular/equal_length/collinear/line_distance) only carry Line
/// ids, unlike the backend's own internal model (constraints.py captures
/// each Line's endpoint ids directly at creation time for the solver's
/// benefit - see e.g. `AngleConstraint.line1_start_id`), since the API
/// response shape (schemas.py's `AngleConstraintResponse` etc.) never
/// exposed them.
({String type, List<String> pointIds}) _describe(
  ConstraintDto constraint,
  Map<String, String> lineStartPointId,
  Map<String, String> lineEndPointId,
) {
  List<String> ofLines(String line1Id, String line2Id) {
    final ids = <String>[];
    final l1Start = lineStartPointId[line1Id];
    final l1End = lineEndPointId[line1Id];
    final l2Start = lineStartPointId[line2Id];
    final l2End = lineEndPointId[line2Id];
    if (l1Start != null) ids.add(l1Start);
    if (l1End != null) ids.add(l1End);
    if (l2Start != null) ids.add(l2Start);
    if (l2End != null) ids.add(l2End);
    return ids;
  }

  List<String> ofLine(String lineId, String pointId) {
    final ids = <String>[pointId];
    final start = lineStartPointId[lineId];
    final end = lineEndPointId[lineId];
    if (start != null) ids.add(start);
    if (end != null) ids.add(end);
    return ids;
  }

  if (constraint is DistanceConstraintDto) {
    return (type: 'distance', pointIds: [constraint.pointAId, constraint.pointBId]);
  }
  if (constraint is VerticalConstraintDto) {
    return (type: 'vertical', pointIds: [constraint.pointAId, constraint.pointBId]);
  }
  if (constraint is HorizontalConstraintDto) {
    return (type: 'horizontal', pointIds: [constraint.pointAId, constraint.pointBId]);
  }
  if (constraint is CoincidentConstraintDto) {
    return (type: 'coincident', pointIds: [constraint.pointAId, constraint.pointBId]);
  }
  if (constraint is AngleConstraintDto) {
    return (type: 'angle', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is ParallelConstraintDto) {
    return (type: 'parallel', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is PerpendicularConstraintDto) {
    return (type: 'perpendicular', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is EqualLengthConstraintDto) {
    return (type: 'equal_length', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is CollinearConstraintDto) {
    return (type: 'collinear', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is LineDistanceConstraintDto) {
    return (type: 'line_distance', pointIds: ofLines(constraint.line1Id, constraint.line2Id));
  }
  if (constraint is PointLineDistanceConstraintDto) {
    return (
      type: 'point_line_distance',
      pointIds: ofLine(constraint.lineId, constraint.pointId),
    );
  }
  if (constraint is AtMidpointConstraintDto) {
    return (type: 'at_midpoint', pointIds: ofLine(constraint.lineId, constraint.pointId));
  }
  return (type: '', pointIds: const []);
}

/// Result of running [SketchRigidity.analyze] over one Sketch's current
/// local state - answers "is this Point/segment fully or over constrained"
/// with no further computation (the union-find clustering already ran).
class SketchRigidity {
  final Set<String> _fullyConstrainedPointIds;
  final Set<String> _overConstrainedPointIds;

  const SketchRigidity._(this._fullyConstrainedPointIds, this._overConstrainedPointIds);

  /// [pointIds] should include every Point id in the Sketch (origin
  /// included). [lineStartPointId]/[lineEndPointId] resolve a Line id to
  /// its endpoint Point ids, for the line-pair Constraint types - see
  /// [_describe]. [originPointId] is the Sketch's own permanently-pinned
  /// Point id (null only for a brand-new/unloaded Sketch), the sole source
  /// of "grounded" in the algorithm described in this file's header
  /// comment.
  factory SketchRigidity.analyze({
    required Iterable<String> pointIds,
    required String? originPointId,
    required Map<String, String> lineStartPointId,
    required Map<String, String> lineEndPointId,
    required Iterable<ConstraintDto> constraints,
  }) {
    final parent = <String, String>{};

    String find(String id) {
      parent.putIfAbsent(id, () => id);
      var root = id;
      while (parent[root] != root) {
        root = parent[root]!;
      }
      var current = id;
      while (parent[current] != root) {
        final next = parent[current]!;
        parent[current] = root;
        current = next;
      }
      return root;
    }

    void union(String a, String b) {
      final rootA = find(a);
      final rootB = find(b);
      if (rootA != rootB) parent[rootA] = rootB;
    }

    final descriptions = [
      for (final constraint in constraints) _describe(constraint, lineStartPointId, lineEndPointId),
    ];

    for (final description in descriptions) {
      final ids = description.pointIds;
      for (var i = 1; i < ids.length; i++) {
        union(ids[0], ids[i]);
      }
    }

    final removedDofByRoot = <String, int>{};
    for (final description in descriptions) {
      final ids = description.pointIds;
      if (ids.isEmpty) continue;
      final root = find(ids.first);
      final cost = dofCostByConstraintType[description.type] ?? 0;
      removedDofByRoot[root] = (removedDofByRoot[root] ?? 0) + cost;
    }

    final rawDofByRoot = <String, int>{};
    final groundedByRoot = <String, bool>{};
    for (final pointId in pointIds) {
      if (!parent.containsKey(pointId)) continue; // Untouched by any Constraint.
      final root = find(pointId);
      rawDofByRoot[root] = (rawDofByRoot[root] ?? 0) + (pointId == originPointId ? 0 : 2);
      if (pointId == originPointId) groundedByRoot[root] = true;
    }

    final fully = <String>{};
    final over = <String>{};
    for (final pointId in pointIds) {
      if (!parent.containsKey(pointId)) continue;
      final root = find(pointId);
      final remaining = (rawDofByRoot[root] ?? 0) - (removedDofByRoot[root] ?? 0);
      if (remaining < 0) {
        over.add(pointId);
      } else if (remaining == 0 && (groundedByRoot[root] ?? false)) {
        fully.add(pointId);
      }
    }

    return SketchRigidity._(fully, over);
  }

  /// An empty analysis - every query returns false. Used before a Sketch
  /// has loaded, mirroring the "nothing computed yet" state other
  /// controller fields default to.
  const SketchRigidity.empty() : this._(const {}, const {});

  bool isPointFullyConstrained(String pointId) => _fullyConstrainedPointIds.contains(pointId);

  bool isPointOverConstrained(String pointId) => _overConstrainedPointIds.contains(pointId);

  /// Whether a two-Point-defined entity (a Line's start/end, or a Circle's
  /// center/radius Point) has zero remaining freedom - both defining
  /// Points must themselves be fully constrained.
  bool isSegmentFullyConstrained(String pointIdA, String pointIdB) =>
      isPointFullyConstrained(pointIdA) && isPointFullyConstrained(pointIdB);

  /// Same shape as [isSegmentFullyConstrained], but true if *either*
  /// defining Point sits in an over-constrained cluster - a Line/Circle is
  /// implicated by a redundant Constraint on just one of its ends just as
  /// much as on both.
  bool isSegmentOverConstrained(String pointIdA, String pointIdB) =>
      isPointOverConstrained(pointIdA) || isPointOverConstrained(pointIdB);
}
