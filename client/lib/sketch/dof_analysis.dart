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
/// DELIBERATE DIVERGENCE FROM py-slvs's OWN `Dof`: a rigid-but-ungrounded
/// cluster (every Point fixed relative to every other, but no chain back
/// to the origin) genuinely has only 3 real remaining degrees of freedom
/// (2D translation + rotation) by standard generic-rigidity convention
/// (Gruebler's equation) - the *same* convention py-slvs's own rank-based
/// `Dof` uses, confirmed by directly testing an ungrounded rectangle
/// against the real solver (`dof: 0`, not 3). Product decision (raised
/// directly against an on-device sketch): a shape that can still be
/// dragged/rotated as a whole is *not* "fully constrained" from this
/// app's point of view, regardless of what py-slvs's raw `Dof` says - so
/// this module's "fully constrained"/[isPointFullyConstrained] requires
/// grounding on purpose, and does *not* try to match py-slvs's `Dof`
/// here. [isPointGrounded] exposes the same origin-connectivity check on
/// its own (a plain, *exact* graph-reachability question, no DOF-counting
/// approximation involved) - `SketchController.isFullyConstrained`
/// combines it with the backend's own authoritative `dof`/`converged` for
/// the whole-sketch "padlock" signal, so the padlock and the per-entity
/// colouring agree.
///
/// KNOWN LIMITATIONS (accepted tradeoffs, not oversights - see the scope
/// doc's own risk note): this *is* still a counting approximation for the
/// DOF-cost side (not the grounding side, which is exact), not a full
/// generic-rigidity check:
///
///  - A genuinely-independent set of constraints can still be
///    *numerically* inconsistent (e.g. a rectangle's width, height, and
///    diagonal dimensioned to mutually-impossible values) - topology
///    alone can never catch this, by design (see the header's opening
///    paragraph). `SketchController` compensates by also colouring red
///    whenever the backend's last solve actually failed to converge,
///    using `SolveResultDto.solverReportedFailedConstraintIds` to find
///    which specific entities are implicated (see [describeConstraint]).
///
/// A narrower, still-real gap this module cannot fully close even with
/// that compensation: a literal duplicate Constraint (same two Points,
/// same value, added twice) reads as over-constrained here even though
/// py-slvs solves it without complaint (a consistent, merely
/// rank-deficient system) - the real (2,3)-pebble game, generalised to
/// weighted constraints, could tell "harmless duplicate" apart from
/// genuine over-constraint; this counting approach cannot.
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
/// other as constraint types are added. Public (not just used by
/// [SketchRigidity.analyze] internally) because `sketch_controller.dart`
/// also needs it, to map the backend's own `solver_reported_failed_
/// constraint_ids` (see `SolveResultDto`) back to the Point ids those
/// Constraints reference, for colouring the entities responsible for an
/// actual numeric solve failure - something no purely-structural analysis
/// in this file can ever detect on its own (see this file's own
/// "ARCHITECTURE RULE"/"KNOWN LIMITATION" header comments).
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
({String type, List<String> pointIds}) describeConstraint(
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
  final Set<String> _groundedPointIds;

  const SketchRigidity._(
    this._fullyConstrainedPointIds,
    this._overConstrainedPointIds,
    this._groundedPointIds,
  );

  /// [pointIds] should include every Point id in the Sketch (origin
  /// included). [lineStartPointId]/[lineEndPointId] resolve a Line id to
  /// its endpoint Point ids, for the line-pair Constraint types - see
  /// [describeConstraint]. [fixedPointIds] are every Point id that's
  /// permanently pinned independent of any Constraint - today that's only
  /// ever the Sketch's own origin Point (a singleton set, or empty only
  /// for a brand-new/unloaded Sketch), but this takes a set rather than a
  /// single id on purpose: a future "Fix"/"Where Dragged" Constraint type
  /// (pinning an arbitrary Point's absolute position, not just the
  /// origin's) would only need to add its own target Point id(s) here,
  /// with the rest of the grounding algorithm - which only ever cares
  /// "does this cluster contain *any* fixed Point" - unchanged.
  factory SketchRigidity.analyze({
    required Iterable<String> pointIds,
    required Set<String> fixedPointIds,
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
      for (final constraint in constraints) describeConstraint(constraint, lineStartPointId, lineEndPointId),
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
      final isFixed = fixedPointIds.contains(pointId);
      rawDofByRoot[root] = (rawDofByRoot[root] ?? 0) + (isFixed ? 0 : 2);
      if (isFixed) groundedByRoot[root] = true;
    }

    final fully = <String>{};
    final over = <String>{};
    final grounded = <String>{};
    for (final pointId in pointIds) {
      if (!parent.containsKey(pointId)) continue;
      final root = find(pointId);
      final remaining = (rawDofByRoot[root] ?? 0) - (removedDofByRoot[root] ?? 0);
      if (remaining < 0) {
        over.add(pointId);
      } else if (remaining == 0 && (groundedByRoot[root] ?? false)) {
        fully.add(pointId);
      }
      if (groundedByRoot[root] ?? false) grounded.add(pointId);
    }

    return SketchRigidity._(fully, over, grounded);
  }

  /// An empty analysis - every query returns false. Used before a Sketch
  /// has loaded, mirroring the "nothing computed yet" state other
  /// controller fields default to.
  const SketchRigidity.empty() : this._(const {}, const {}, const {});

  bool isPointFullyConstrained(String pointId) => _fullyConstrainedPointIds.contains(pointId);

  bool isPointOverConstrained(String pointId) => _overConstrainedPointIds.contains(pointId);

  /// Whether [pointId] is (transitively, via any chain of Constraints)
  /// connected to one of the Sketch's fixed Points (today, only ever the
  /// origin - see [analyze]'s own doc comment) - a purely topological,
  /// exact (no counting-approximation risk) connectivity question, unlike
  /// [isPointFullyConstrained] which also depends on this module's
  /// approximate DOF-cost totals. `SketchController.isFullyConstrained`
  /// combines this with the backend's own authoritative `dof`/`converged`
  /// for the whole-sketch "padlock" signal - see that getter's own doc
  /// comment for why splitting the two concerns this way is more robust
  /// than trusting either alone.
  bool isPointGrounded(String pointId) => _groundedPointIds.contains(pointId);

  /// Whether *any* Point anywhere in the Sketch is grounded. Grounding
  /// propagates through a cluster's whole union-find (a single fixed
  /// Point anywhere in a connected structure grounds every other Point in
  /// it - see [isPointGrounded]), so once the backend confirms
  /// `dof <= 0` for the *whole* Sketch, one grounded Point anywhere is
  /// already enough to know every connected piece of geometry is grounded
  /// - a disconnected, ungrounded piece can never coexist with a
  /// backend-confirmed `dof <= 0` (it would always contribute its own
  /// nonzero remaining freedom - confirmed directly against py-slvs).
  /// `SketchController.isFullyConstrained` uses exactly this combination
  /// rather than checking every individual entity's own grounding.
  bool get isAnyPointGrounded => _groundedPointIds.isNotEmpty;

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
