// Dart port of backend/app/sketch/solver.py's solve_sketch/
// _solve_sketch_once, plus each Constraint subclass's add_to_solver from
// constraints.py (constraint dispatch) - built on [SolverBuilder]/
// [NativeSolverBuilder] (solver_builder.dart) and [SlvsNativeBindings]
// (slvs_bindings.dart).
//
// Every load-bearing behaviour here is a direct, deliberate port - not a
// redesign:
//   - provisional DistanceConstraints are skipped by the dispatch loop,
//     never reaching addToSolver (mirrors solver.py's own loop-level skip).
//   - the origin Point (if present) and any per-call anchor ids are pinned
//     into the fixed solver group (drag-solve semantics).
//   - the redundancy-safe-type convergence override and provisional-DOF
//     floor (both empirically derived - see each's own doc comment) are
//     carried over verbatim, including AtMidpointConstraint's deliberate
//     exclusion from the safe list.
//   - solveSketch retries once with no anchors if an anchored solve fails
//     to converge, exactly like the backend.
//
// Not yet ported: `_fix_circle_cardinal_point_signs` (solver.py) - a
// Circle-specific cardinal-point mirror-ambiguity fix. Out of scope for
// this port's initial (single Point / simple sketch) landing; flagged here
// rather than silently omitted.
import 'dart:ffi' as ffi;
import 'dart:io';

import '../../api/sketch_api_client.dart';
import 'slvs_bindings.dart';
import 'solver_builder.dart';

/// Resolves a Line id to its (start, end) Point ids - the Dart client
/// tracks this via `SketchController.lines` (`SketchLineView`), unlike the
/// backend's constraint dataclasses, which capture a Line's endpoints
/// directly at constraint-creation time. Constraint dispatch below needs
/// this to build the same `line_segment` handles the backend would.
typedef LineEndpoints = (String startId, String endId) Function(String lineId);

/// Outcome of one local solve - mirrors solver.py's `SolveResult` (minus
/// `blamed_constraint_ids`, a purely UI-blame convention not needed by the
/// narrow interactive path this port currently serves).
class LocalSolveResult {
  final bool converged;
  final int dof;
  final int resultCode;
  final List<String> solverReportedFailedConstraintIds;
  final Map<String, (double, double)> solvedPoints;

  LocalSolveResult({
    required this.converged,
    required this.dof,
    required this.resultCode,
    required this.solverReportedFailedConstraintIds,
    required this.solvedPoints,
  });
}

/// Constraint types the redundancy-convergence override (below) trusts -
/// deliberately excludes [AtMidpointConstraintDto], because the backend's
/// own `test_two_at_midpoint_constraints_on_the_same_point_is_singular_
/// once_hv_ties_diagonals_together` proves the same py-slvs result code can
/// also mean a genuinely under-constrained shape (an HV-constrained
/// rectangle whose width/height/position are never actually pinned) in
/// that specific case - a blanket override would silently reintroduce that
/// false positive.
bool _isRedundancySafe(ConstraintDto c) => c is! AtMidpointConstraintDto;

/// One `addToSolver` dispatch per constraint type - direct port of each
/// Constraint subclass's `add_to_solver` in constraints.py. Every
/// subtlety called out there (Collinear's discarded second handle,
/// SplineTangent's hardcoded at_end1=true/at_end2=false, EqualRadius reusing
/// equalLength on virtual centre->rim segments, ...) is preserved exactly.
int _addToSolver(ConstraintDto c, SolverBuilder b, LineEndpoints lineEndpoints) {
  if (c is DistanceConstraintDto) {
    if (c.orientation == 'horizontal') return b.horizontalDistance(c.pointAId, c.pointBId, c.distance);
    if (c.orientation == 'vertical') return b.verticalDistance(c.pointAId, c.pointBId, c.distance);
    return b.distance(b.point2d(c.pointAId), b.point2d(c.pointBId), c.distance);
  }
  if (c is VerticalConstraintDto) {
    return b.vertical(b.point2d(c.pointAId), b.point2d(c.pointBId));
  }
  if (c is HorizontalConstraintDto) {
    return b.horizontal(b.point2d(c.pointAId), b.point2d(c.pointBId));
  }
  if (c is AngleConstraintDto) {
    final (a1s, a1e) = lineEndpoints(c.line1Id);
    final (b1s, b1e) = lineEndpoints(c.line2Id);
    final line1 = b.lineSegment(b.point2d(a1s), b.point2d(a1e));
    final line2 = b.lineSegment(b.point2d(b1s), b.point2d(b1e));
    return b.angle(line1, line2, c.angleDegrees, a1s, a1e, b1s, b1e);
  }
  if (c is CoincidentConstraintDto) {
    return b.coincident(b.point2d(c.pointAId), b.point2d(c.pointBId));
  }
  if (c is ParallelConstraintDto) {
    final (s1, e1) = lineEndpoints(c.line1Id);
    final (s2, e2) = lineEndpoints(c.line2Id);
    return b.parallel(b.lineSegment(b.point2d(s1), b.point2d(e1)), b.lineSegment(b.point2d(s2), b.point2d(e2)));
  }
  if (c is PerpendicularConstraintDto) {
    final (s1, e1) = lineEndpoints(c.line1Id);
    final (s2, e2) = lineEndpoints(c.line2Id);
    return b.perpendicular(b.lineSegment(b.point2d(s1), b.point2d(e1)), b.lineSegment(b.point2d(s2), b.point2d(e2)));
  }
  if (c is EqualLengthConstraintDto) {
    final (s1, e1) = lineEndpoints(c.line1Id);
    final (s2, e2) = lineEndpoints(c.line2Id);
    return b.equalLength(b.lineSegment(b.point2d(s1), b.point2d(e1)), b.lineSegment(b.point2d(s2), b.point2d(e2)));
  }
  if (c is TangentConstraintDto) {
    final center = b.point2d(c.centerPointId);
    final radiusLine = b.lineSegment(center, b.point2d(c.radiusPointId));
    final (ls, le) = lineEndpoints(c.lineId);
    final tangentLine = b.lineSegment(b.point2d(ls), b.point2d(le));
    return b.equalLengthPointLineDistance(center, radiusLine, tangentLine);
  }
  if (c is EqualRadiusConstraintDto) {
    final line1 = b.lineSegment(b.point2d(c.center1PointId), b.point2d(c.radius1PointId));
    final line2 = b.lineSegment(b.point2d(c.center2PointId), b.point2d(c.radius2PointId));
    return b.equalLength(line1, line2);
  }
  if (c is LineDistanceConstraintDto) {
    final (s1, e1) = lineEndpoints(c.line1Id);
    final (s2, _) = lineEndpoints(c.line2Id);
    final line1 = b.lineSegment(b.point2d(s1), b.point2d(e1));
    final point2Start = b.point2d(s2);
    return b.pointLineDistance(point2Start, line1, c.distance);
  }
  if (c is CollinearConstraintDto) {
    final (s1, e1) = lineEndpoints(c.line1Id);
    final (s2, e2) = lineEndpoints(c.line2Id);
    final line1 = b.lineSegment(b.point2d(s1), b.point2d(e1));
    final point2Start = b.point2d(s2);
    final point2End = b.point2d(e2);
    final handle = b.pointOnLine(point2Start, line1);
    b.pointOnLine(point2End, line1); // second constraint created, handle discarded - matches constraints.py
    return handle;
  }
  if (c is PointLineDistanceConstraintDto) {
    final (ls, le) = lineEndpoints(c.lineId);
    final point = b.point2d(c.pointId);
    final line = b.lineSegment(b.point2d(ls), b.point2d(le));
    return b.pointLineDistance(point, line, c.distance);
  }
  if (c is AtMidpointConstraintDto) {
    final (ls, le) = lineEndpoints(c.lineId);
    final point = b.point2d(c.pointId);
    final line = b.lineSegment(b.point2d(ls), b.point2d(le));
    return b.atMidpoint(point, line);
  }
  if (c is SplineTangentConstraintDto) {
    final segmentA = b.cubic(b.point2d(c.segmentAP0), b.point2d(c.segmentAP1), b.point2d(c.segmentAP2),
        b.point2d(c.segmentAP3));
    final segmentB = b.cubic(b.point2d(c.segmentBP0), b.point2d(c.segmentBP1), b.point2d(c.segmentBP2),
        b.point2d(c.segmentBP3));
    return b.curvesTangent(true, false, segmentA, segmentB);
  }
  throw StateError('No solver dispatch for constraint type: ${c.runtimeType}');
}

/// One solve attempt - mirrors solver.py's `_solve_sketch_once`. Builds a
/// fresh py-slvs system every call (no persistent solver-side entity - see
/// this file's own header comment), registers every Point (not just ones a
/// Constraint references, so free parameters are counted toward [dof]), and
/// applies the redundancy-safe-type convergence override plus the
/// provisional-DOF floor exactly as the backend does.
LocalSolveResult _solveOnce({
  required SlvsNativeBindings bindings,
  required Map<String, (double, double)> points,
  required List<ConstraintDto> constraints,
  required LineEndpoints lineEndpoints,
  required Set<String> pinnedPointIds,
}) {
  final sys = bindings.create();
  try {
    final origin = bindings.addPoint3dV(sys, 0, 0, 0, slvsFixedGroup);
    final normal = bindings.addNormal3dV(sys, 1, 0, 0, 0, slvsFixedGroup);
    final workplane = bindings.addWorkplane(sys, origin, normal, slvsFixedGroup);

    final builder = NativeSolverBuilder(
      bindings: bindings,
      sys: sys,
      workplane: workplane,
      pointXY: (id) => points[id]!,
      pinnedPointIds: pinnedPointIds,
    );

    final constraintIdByHandle = <int, String>{};
    for (final c in constraints) {
      // Not yet confirmed by the user - contributes zero DOF-removal,
      // exactly as if it didn't exist, until confirmed (mirrors
      // DistanceConstraint.provisional's own doc comment).
      if (c is DistanceConstraintDto && c.provisional) continue;
      final handle = _addToSolver(c, builder, lineEndpoints);
      constraintIdByHandle[handle] = c.id;
    }

    // Register every Point, not just ones a Constraint happens to
    // reference, so its free parameters are counted toward dof below.
    for (final id in points.keys) {
      builder.point2d(id);
    }

    final resultCode = bindings.solve(sys, slvsSolveGroup, 1);
    var converged = resultCode == 0;

    // Same redundant-but-solved override as solver.py: a Slot-shaped
    // closed loop of Tangent/EqualRadius-tied Arcs is *mathematically*
    // over-determined by exactly one redundant equation. py-slvs reports
    // 4 (upstream) or 5 (this fork) for "solved correctly despite a
    // redundant constraint" - trusted only when every constraint present
    // is one of the types confirmed safe (see _isRedundancySafe).
    final hasTangentOrEqualRadius = constraints.any((c) => c is TangentConstraintDto || c is EqualRadiusConstraintDto);
    if (!converged &&
        (resultCode == 4 || resultCode == 5) &&
        hasTangentOrEqualRadius &&
        constraints.every(_isRedundancySafe)) {
      converged = true;
    }

    // Provisional-DOF floor: py-slvs's own Dof is unreliable for the
    // redundant system above - it reports 0 even while a real,
    // still-unconfirmed degree of freedom (e.g. a Slot's shared radius)
    // remains. A dof of 0 is only trustworthy once every DistanceConstraint
    // measuring this redundant sub-system has actually been confirmed.
    final hasUnconfirmedProvisional =
        constraints.any((c) => c is DistanceConstraintDto && c.provisional);
    final rawDof = bindings.getDof(sys);
    final dof = (converged && hasUnconfirmedProvisional) ? (rawDof > 1 ? rawDof : 1) : rawDof;

    final solvedPoints = <String, (double, double)>{};
    for (final id in builder.solvedPointIds) {
      final handle = builder.handleForPoint(id);
      final u = bindings.getEntityParam(sys, handle, 0);
      final v = bindings.getEntityParam(sys, handle, 1);
      solvedPoints[id] = (bindings.getParamValue(sys, u), bindings.getParamValue(sys, v));
    }

    final failedCount = bindings.getFailedCount(sys);
    final solverReportedFailedConstraintIds = <String>[
      for (var i = 0; i < failedCount; i++)
        if (constraintIdByHandle.containsKey(bindings.getFailedAt(sys, i)))
          constraintIdByHandle[bindings.getFailedAt(sys, i)]!,
    ];

    return LocalSolveResult(
      converged: converged,
      dof: dof,
      resultCode: resultCode,
      solverReportedFailedConstraintIds: solverReportedFailedConstraintIds,
      solvedPoints: solvedPoints,
    );
  } finally {
    bindings.destroy(sys);
  }
}

/// Mirrors solver.py's `solve_sketch`: solves once with [anchorPointIds]
/// (plus [originPointId], if any) pinned into the fixed group, and retries
/// once with no anchors at all if that fails to converge - e.g. the dragged
/// Point is Coincident with the fixed origin, or with another anchored
/// Point, which the anchored attempt can never satisfy since neither side
/// is free to move to match the other.
LocalSolveResult solveSketchLocally({
  required SlvsNativeBindings bindings,
  required Map<String, (double, double)> points,
  required List<ConstraintDto> constraints,
  required LineEndpoints lineEndpoints,
  String? originPointId,
  Set<String> anchorPointIds = const {},
}) {
  final pinned = {...anchorPointIds, if (originPointId != null) originPointId};
  var result = _solveOnce(
    bindings: bindings,
    points: points,
    constraints: constraints,
    lineEndpoints: lineEndpoints,
    pinnedPointIds: pinned,
  );
  if (anchorPointIds.isNotEmpty && !result.converged) {
    result = _solveOnce(
      bindings: bindings,
      points: points,
      constraints: constraints,
      lineEndpoints: lineEndpoints,
      pinnedPointIds: {if (originPointId != null) originPointId},
    );
  }
  return result;
}

/// Loads the platform-appropriate build of didsa_slvs_ffi. Android
/// (Milestone D) bundles the .so as a normal native library, loadable by
/// name alone; other platforms (desktop testing) need an explicit path.
SlvsNativeBindings loadSlvsBindings({String? explicitPath}) {
  final lib = explicitPath != null
      ? ffi.DynamicLibrary.open(explicitPath)
      : Platform.isAndroid
          ? ffi.DynamicLibrary.open('libdidsa_slvs_ffi.so')
          : throw UnsupportedError(
              'loadSlvsBindings needs an explicit path outside Android (no bundled library convention yet)');
  return SlvsNativeBindings(lib);
}
