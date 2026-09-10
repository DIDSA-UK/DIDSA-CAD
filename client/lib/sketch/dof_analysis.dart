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
/// A narrower gap this module used to have no way to close: a literal
/// duplicate Constraint (same two Points, same value, added twice), or a
/// Regular Polygon's own deliberately-redundant EqualRadius/Angle chain
/// (see the backend `Polygon` docstring) plus one further genuinely-
/// implied Constraint stacked on top (a Horizontal edge *and* a matching
/// "across flats" LineDistance together - either alone removes a real
/// remaining degree of freedom, but once both are present the second is
/// fully implied by the first, so this per-type counter double-charges
/// it) - both read as over-constrained here even though py-slvs solves
/// them without complaint (a consistent, merely rank-deficient system;
/// confirmed directly against the real solver for the Polygon case - see
/// `backend/app/sketch/solver.py`'s own `_residual_verified_convergence`
/// doc comment, which exists specifically to rescue this class of false
/// positive on the *backend* side). Bug fix (on-device feedback: an
/// ordinary Horizontal/Vertical/Collinear-dimensioned profile - e.g. a
/// stepped rectangle - read red even though it was genuinely solvable):
/// that backend rescue path originally only recognised 9 constraint
/// types, and required *every* constraint in the Sketch to be one of them
/// before it would vouch for anything - so a Coincident/Collinear/
/// PointOnLine/Perpendicular/Concentric constraint anywhere (Coincident
/// and Collinear especially, both extremely common in a hand-drawn
/// profile) disqualified the whole Sketch from rescue even when the
/// actual redundancy was entirely within an already-checkable subset.
/// `_RESIDUAL_CHECKABLE_CONSTRAINT_TYPES` now also covers those five -
/// see that constant's own doc comment for the per-type safety reasoning
/// (and why `AtMidpointConstraint` stays deliberately excluded).
/// The real (2,3)-pebble game,
/// generalised to weighted constraints, could tell "harmless redundancy"
/// apart from genuine over-constraint on purely structural grounds; this
/// counting approach cannot - so [SketchRigidity.analyze]'s own
/// `trustConvergedSolve` parameter closes the gap a different way
/// instead: whenever the backend's own last solve is known to have
/// actually converged, that numeric confirmation is strictly more
/// trustworthy than this module's topological guess, so the guess is
/// deferred to entirely rather than raced against it - see that
/// parameter's own doc comment.
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
  'concentric': 2, // same coincident call as above, just applied to two
  // Circles'/Arcs' centre Points instead of two free Points - same cost by
  // construction (see backend ConcentricConstraint.add_to_solver).
  'parallel': 1, // cross(dir(L1), dir(L2)) = 0
  'perpendicular': 1, // dot(dir(L1), dir(L2)) = 0
  'equal_length': 1, // |L1| = |L2|
  'line_distance': 1, // perpendicular distance(L1, L2) = value
  'collinear': 2, // both of L2's endpoints on L1 - two point-on-line
  // equations (see constraints.py's CollinearConstraint.add_to_solver).
  'point_line_distance': 1, // perpendicular distance(point, line) = value
  'at_midpoint': 2, // point == midpoint(line) - an x and a y equation.
  // Pre-existing gap fix (found while adding point_on_line/point_on_circle
  // below): tangent/equal_radius/spline_tangent already existed as real,
  // wired backend constraint types but had no entry here at all, silently
  // under-reporting DOF/grounding for any Sketch using them. All three
  // confirmed empirically against the installed py-slvs (see the backend
  // investigation this fix came out of) rather than guessed:
  'tangent': 1, // equal_length_point_line_distance(centre, radius_line,
  // tangent_line) - confirmed via direct py-slvs probe: 4 free params -> 3
  // after adding the constraint.
  'curve_tangent': 1, // point_on_line(shared_point, virtual centre-to-centre
  // line) - literally the same primitive call as 'point_on_line' below
  // (just built from a virtual line through both centres rather than a
  // real Line entity), so the cost is the same one scalar equation by
  // construction, not an independent empirical probe.
  'equal_radius': 1, // the exact same equal_length call 'equal_length'
  // above already uses (two virtual centre->rim lines), just applied to
  // Circles/Arcs instead of Lines - same cost by construction.
  'spline_tangent': 1, // addCurvesTangent - confirmed via direct py-slvs
  // probe: 14 free params -> 13 after adding the constraint (a single
  // tangent-direction-alignment equation, not the 2 one might expect from
  // "match a 2D direction").
  'point_on_line': 1, // point_on_line(point, line) - point lies anywhere
  // on the line's own infinite extension, same primitive/cost as
  // point_line_distance above.
  'point_on_circle': 1, // equal_length(centre->point, centre->radius_point)
  // - confirmed via direct py-slvs probe: a free Point pulled onto a
  // radius-5 circle converges with Dof == 1 (the Point's own remaining
  // angular freedom around the circle).
  'point_on_ellipse': 1, // Trammel of Archimedes (2 ephemeral auxiliary
  // points, 5 chained primitives - see backend PointOnEllipseConstraint's
  // own doc comment) - confirmed via direct py-slvs probe across 6
  // configurations (axis-aligned/rotated, varied radii): a free Point
  // pulled onto a fully-fixed ellipse converges with Dof == 1 every time
  // (the Point's own remaining freedom along the curve), same net cost as
  // point_on_line/point_on_circle above despite the construction's own
  // extra internal auxiliary points.
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
  if (constraint is ConcentricConstraintDto) {
    return (type: 'concentric', pointIds: [constraint.center1PointId, constraint.center2PointId]);
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
  // Pre-existing gap fix (found alongside dofCostByConstraintType's own -
  // see that map's doc comment): Tangent/EqualRadius/SplineTangent had no
  // dispatch case here at all, silently falling through to the `type: ''`
  // default below - meaning even *with* a dofCostByConstraintType entry,
  // the cost could never actually be looked up for a Sketch using any of
  // these three, since describeConstraint never named the type or the
  // Points it grounds together.
  if (constraint is TangentConstraintDto) {
    final ids = [constraint.centerPointId, constraint.radiusPointId];
    final start = lineStartPointId[constraint.lineId];
    final end = lineEndPointId[constraint.lineId];
    if (start != null) ids.add(start);
    if (end != null) ids.add(end);
    return (type: 'tangent', pointIds: ids);
  }
  if (constraint is CurveTangentConstraintDto) {
    return (
      type: 'curve_tangent',
      pointIds: [constraint.center1PointId, constraint.center2PointId, constraint.sharedPointId],
    );
  }
  if (constraint is EqualRadiusConstraintDto) {
    return (
      type: 'equal_radius',
      pointIds: [
        constraint.center1PointId,
        constraint.radius1PointId,
        constraint.center2PointId,
        constraint.radius2PointId,
      ],
    );
  }
  if (constraint is SplineTangentConstraintDto) {
    return (
      type: 'spline_tangent',
      pointIds: [
        constraint.segmentAP0,
        constraint.segmentAP1,
        constraint.segmentAP2,
        constraint.segmentAP3,
        constraint.segmentBP1,
        constraint.segmentBP2,
        constraint.segmentBP3,
      ],
    );
  }
  if (constraint is PointOnLineConstraintDto) {
    return (type: 'point_on_line', pointIds: ofLine(constraint.lineId, constraint.pointId));
  }
  if (constraint is PointOnCircleConstraintDto) {
    return (
      type: 'point_on_circle',
      pointIds: [constraint.pointId, constraint.centerPointId, constraint.radiusPointId],
    );
  }
  if (constraint is PointOnEllipseConstraintDto) {
    return (
      type: 'point_on_ellipse',
      pointIds: [
        constraint.pointId,
        constraint.centerPointId,
        constraint.majorPointId,
        constraint.minorPointId,
      ],
    );
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
  final Set<String> _pinnedPointIds;

  const SketchRigidity._(
    this._fullyConstrainedPointIds,
    this._overConstrainedPointIds,
    this._groundedPointIds,
    this._pinnedPointIds,
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
  /// [trustConvergedSolve] (bug fix, on-device feedback: "a line to line
  /// (across flats) dimension combined with a horizontal constraint on an
  /// edge causes a red outline and the solver fails to solve or considers
  /// over constrained... a typical method for fully constraining a hex or
  /// other polygon") - pass `true` only when the backend's own most recent
  /// solve genuinely reported `converged: true` for the *current* Sketch
  /// state (`SketchController._lastSolveConverged`, refreshed after every
  /// meaningful edit - see that field's own doc comment). This module's
  /// own DOF-cost counting is a topological approximation that cannot tell
  /// a Regular Polygon's own deliberately-redundant EqualRadius/Angle
  /// chain plus one further genuinely-implied Constraint (a Horizontal
  /// edge and a matching across-flats LineDistance together - see this
  /// class's own header "KNOWN LIMITATIONS" for the exact math) apart from
  /// a real conflict - it just double-charges both as independent DOF
  /// removals and reports over-constrained. A backend solve that actually
  /// converged is definitive proof no such conflict exists, numerically
  /// stronger than this structural guess, so when it's available this
  /// module defers to it entirely for the *over*-constrained verdict
  /// (`fully`/`grounded` are unaffected - a converged solve says nothing
  /// wrong about those) rather than raising a false alarm the backend has
  /// already ruled out.
  factory SketchRigidity.analyze({
    required Iterable<String> pointIds,
    required Set<String> fixedPointIds,
    required Map<String, String> lineStartPointId,
    required Map<String, String> lineEndPointId,
    required Iterable<ConstraintDto> constraints,
    bool trustConvergedSolve = false,
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

    // Provisional DistanceConstraints (see DistanceConstraintDto.provisional)
    // are skipped by the backend solver entirely - mirror that here so this
    // local preview agrees with SketchController.isFullyConstrained's own
    // backend-derived padlock instead of colouring an unconfirmed shape
    // green.
    final descriptions = [
      for (final constraint in constraints)
        if (!(constraint is DistanceConstraintDto && constraint.provisional))
          describeConstraint(constraint, lineStartPointId, lineEndPointId),
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
      if (remaining < 0 && !trustConvergedSolve) {
        over.add(pointId);
      } else if (remaining == 0 && (groundedByRoot[root] ?? false)) {
        fully.add(pointId);
      }
      if (groundedByRoot[root] ?? false) grounded.add(pointId);
    }

    // [isPointPinned]'s own second, narrower union-find pass - deliberately
    // separate from the `parent`/cluster analysis above. That analysis asks
    // "does this Point's whole *cluster* have zero remaining freedom",
    // which understates a Point whenever anything else sharing its cluster
    // (via some other, non-pinning Constraint - a radius dimension, say)
    // still has freedom of its own: an Arc/Circle centre Coincident to the
    // origin has an exactly fixed position on its own regardless of
    // whether its start/end Points can still rotate around it, but the
    // moment a confirmed radius `DistanceConstraint` unions centre with
    // start (and, via EqualRadiusConstraint, end too) into one cluster,
    // that cluster's remaining DOF goes from 0 to 2 (the two endpoints'
    // own sweep-angle freedom) - so `isPointFullyConstrained(centrePointId)`
    // flips to false even though the centre itself never moved. Confirmed
    // directly on-device: an Arc centred exactly at the origin with a
    // confirmed radius dimension let its centre be dragged away, visibly
    // detaching it from the origin (the "Coincident" badge left stranded
    // behind) - `_arcDragMode`/`beginPointDrag` (`sketch_controller.dart`)
    // both gate on `isPointFullyPinned`, which this bug fix closes at the
    // source rather than patching each call site individually.
    //
    // Only 'coincident'/'concentric' (see [dofCostByConstraintType]: both
    // literally assert `xa = xb AND ya = yb`, nothing else) count as edges
    // here - each is a simple, exact "these two Points share one position"
    // fact, true regardless of whatever *else* either Point is unioned
    // into via a different (non-fully-pinning) Constraint type, so a plain
    // union-find over just these two types, then flooding "pinned" out
    // from [fixedPointIds], is exact - no DOF-counting approximation risk,
    // the same guarantee [isPointGrounded] already relies on for its own,
    // broader ("any Constraint type") reachability question.
    //
    // Deliberately excludes 'at_midpoint' (also cost-2, also always in
    // [dofCostByConstraintType]) despite otherwise fitting the "exactly
    // pins one Point's position" description: unlike coincident/concentric,
    // an AtMidpointConstraint's pinned Point sits at the midpoint of a
    // *Line* - it's only actually fixed once *both* the Line's own
    // endpoints are independently pinned too, which a plain pairwise union
    // can't express (it would need a proper two-input fixpoint, unioning
    // the midpoint Point only once both line-endpoint unions have already
    // resolved). Rare enough in practice (nowhere near as common as an
    // Arc/Circle centre Coincident to the origin, this fix's actual
    // on-device motivating case) that leaving it to the existing
    // cluster-DOF check alone - same as before this fix - is the safer
    // tradeoff versus risking a wrong fixpoint implementation.
    final pinParent = <String, String>{};
    String pinFind(String id) {
      pinParent.putIfAbsent(id, () => id);
      var root = id;
      while (pinParent[root] != root) {
        root = pinParent[root]!;
      }
      var current = id;
      while (pinParent[current] != root) {
        final next = pinParent[current]!;
        pinParent[current] = root;
        current = next;
      }
      return root;
    }

    void pinUnion(String a, String b) {
      final rootA = pinFind(a);
      final rootB = pinFind(b);
      if (rootA != rootB) pinParent[rootA] = rootB;
    }

    for (final description in descriptions) {
      if (description.type != 'coincident' && description.type != 'concentric') continue;
      final ids = description.pointIds;
      for (var i = 1; i < ids.length; i++) {
        pinUnion(ids[0], ids[i]);
      }
    }

    final pinnedRoots = <String>{
      for (final pointId in fixedPointIds)
        if (pinParent.containsKey(pointId)) pinFind(pointId),
    };
    final pinned = <String>{
      ...fixedPointIds,
      for (final pointId in pointIds)
        if (pinParent.containsKey(pointId) && pinnedRoots.contains(pinFind(pointId))) pointId,
    };

    return SketchRigidity._(fully, over, grounded, pinned);
  }

  /// An empty analysis - every query returns false. Used before a Sketch
  /// has loaded, mirroring the "nothing computed yet" state other
  /// controller fields default to.
  const SketchRigidity.empty() : this._(const {}, const {}, const {}, const {});

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

  /// Whether [pointId]'s own position is exactly fixed - transitively, via
  /// a chain of Coincident/Concentric Constraints only - to one of the
  /// Sketch's fixed Points (today, only ever the origin). Deliberately
  /// narrower than [isPointGrounded] (which follows *any* Constraint type)
  /// and orthogonal to [isPointFullyConstrained] (a whole-cluster DOF-count
  /// approximation): a Point can be exactly pinned this way while its
  /// cluster's own remaining-DOF count is still nonzero, whenever some
  /// *other*, non-pinning Constraint (a radius dimension, say) also unions
  /// it with a Point that still has freedom of its own - see [analyze]'s
  /// own doc comment (the Arc/Circle-centre-coincident-to-origin bug this
  /// closes) for the full reasoning. Like [isPointGrounded], this is exact
  /// topological reachability, not a counting approximation - no risk of a
  /// false positive.
  bool isPointPinned(String pointId) => _pinnedPointIds.contains(pointId);

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
