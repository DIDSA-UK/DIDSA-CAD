// Dart port of backend/app/sketch/solver.py's SolverBuilder Protocol
// (constraints.py) and its concrete implementation, _PySlvsBuilder
// (solver.py) - see this port's own governing plan for the exact source
// this mirrors. Every doc comment below that describes *why* a piece of
// logic exists is carried over near-verbatim from the Python original,
// since these are empirically-derived behaviours (sign conventions,
// supplement disambiguation, ...), not incidental implementation details -
// changing them here without changing them there would silently diverge
// from the backend's own solve results.
import 'dart:ffi' as ffi;
import 'dart:math' as math;

import 'slvs_bindings.dart';

/// Mirrors constraints.py's `SolverBuilder` Protocol method-for-method.
/// [point2d]/[horizontalDistance]/[verticalDistance] take Point *ids*
/// (resolved/cached internally); every other method takes already-resolved
/// integer handles returned by [point2d]/[lineSegment]/[cubic].
abstract class SolverBuilder {
  int point2d(String pointId);
  int ephemeralPoint2d(String seedFromPointId);
  int ephemeralPoint2dAt(double x, double y);
  (double x, double y) seedXY(String pointId);
  int distance(int pointAHandle, int pointBHandle, double value);
  int horizontalDistance(String pointAId, String pointBId, double value);
  int verticalDistance(String pointAId, String pointBId, double value);
  int vertical(int pointAHandle, int pointBHandle);
  int horizontal(int pointAHandle, int pointBHandle);
  int lineSegment(int pointAHandle, int pointBHandle);
  int angle(int lineAHandle, int lineBHandle, double degrees, String lineAStartId, String lineAEndId,
      String lineBStartId, String lineBEndId);
  int coincident(int pointAHandle, int pointBHandle);
  int parallel(int lineAHandle, int lineBHandle);
  int perpendicular(int lineAHandle, int lineBHandle);
  int equalLength(int lineAHandle, int lineBHandle);
  int equalLengthPointLineDistance(int pointHandle, int radiusLineHandle, int tangentLineHandle);
  int pointOnLine(int pointHandle, int lineHandle);
  int pointLineDistance(int pointHandle, int lineHandle, double value);
  int atMidpoint(int pointHandle, int lineHandle);
  int cubic(int p0Handle, int p1Handle, int p2Handle, int p3Handle);
  int curvesTangent(bool atEnd1, bool atEnd2, int curve1Handle, int curve2Handle);
}

/// A 2D point's current (x, y) - the same shape [NativeSolverBuilder] needs
/// from the live sketch, mirroring solver.py's `Point` lookups (`points:
/// dict[str, Point]`).
typedef PointLookup = (double x, double y) Function(String pointId);

/// [SolverBuilder] backed by [SlvsNativeBindings] - mirrors solver.py's
/// `_PySlvsBuilder` exactly, including its lazy/memoizing handle caches
/// (a fresh cache per solve, never persisted across solves - see
/// solveSketch's own doc comment for why: "no persistent solver-side
/// entity, rebuilt every call").
class NativeSolverBuilder implements SolverBuilder {
  final SlvsNativeBindings _b;
  final ffi.Pointer<ffi.Void> _sys;
  final int _workplane;
  final PointLookup _pointXY;

  /// Point ids pinned into the fixed group rather than the solve group -
  /// the sketch's own origin (if present) plus any Point this local solve
  /// has no business moving under any circumstance (an external reference,
  /// a `FixedConstraintDto` target). See [point2d]'s own doc comment.
  final Set<String> _pinnedPointIds;

  /// Point ids currently being dragged - stay in the ordinary solve group
  /// (never [_pinnedPointIds]) but their own u/v params are marked via
  /// SolveSpace's `dragged[]` mechanism (see [draggedParamHandles]) once
  /// [point2d] registers them, so the solver favors leaving them close to
  /// their current (raw, live-drag-target) value without forcing it - the
  /// "soft-drag"/live-clamp this port's own governing plan calls for,
  /// replacing the older, cruder approach of just hard-pinning a dragged
  /// Point into [_pinnedPointIds] (which forced it to stay exactly where it
  /// was seeded even when that violated a Constraint - the class of bug the
  /// spike behind this mechanism was built to fix).
  final Set<String> _draggedPointIds;

  final Map<String, int> _pointHandles = {};

  /// The u/v param handles of every [_draggedPointIds] member [point2d] has
  /// registered so far, in encounter order - what a caller passes to
  /// [SlvsNativeBindings.solveDragged]'s own fixed 4-param ceiling (matching
  /// Slvs_System.dragged's own `[4]`). Capped at 4 entries (2 Points' worth)
  /// here too, same ceiling, rather than silently truncated later at the
  /// FFI call site.
  final List<int> draggedParamHandles = [];
  final Map<(int, int), int> _lineHandles = {};
  final Map<(int, int, int, int), int> _cubicHandles = {};
  int? _horizontalRefLine;
  int? _verticalRefLine;

  NativeSolverBuilder({
    required SlvsNativeBindings bindings,
    required ffi.Pointer<ffi.Void> sys,
    required int workplane,
    required PointLookup pointXY,
    required Set<String> pinnedPointIds,
    Set<String> draggedPointIds = const {},
  })  : _b = bindings,
        _sys = sys,
        _workplane = workplane,
        _pointXY = pointXY,
        _pinnedPointIds = pinnedPointIds,
        _draggedPointIds = draggedPointIds;

  /// Ids of every Point this builder has actually registered a solver
  /// entity for - mirrors `_PySlvsBuilder.solved_point_ids()`.
  Iterable<String> get solvedPointIds => _pointHandles.keys;

  int handleForPoint(String pointId) => _pointHandles[pointId]!;

  @override
  int point2d(String pointId) {
    return _pointHandles.putIfAbsent(pointId, () {
      final (x, y) = _pointXY(pointId);
      // A Point is never both pinned and dragged - [_pinnedPointIds] is
      // reserved for geometry this solve must never move at all (the
      // sketch's own origin, a locked/external-reference Point), which a
      // soft-drag bias would be meaningless for anyway (the fixed group's
      // params aren't varied by the solve regardless of dragged[]).
      final group = _pinnedPointIds.contains(pointId) ? slvsFixedGroup : slvsSolveGroup;
      final pu = _b.addParamV(_sys, x, group);
      final pv = _b.addParamV(_sys, y, group);
      if (group == slvsSolveGroup && _draggedPointIds.contains(pointId) && draggedParamHandles.length + 2 <= 4) {
        draggedParamHandles..add(pu)..add(pv);
      }
      return _b.addPoint2d(_sys, _workplane, pu, pv, group);
    });
  }

  /// Mirrors solver.py's `ephemeral_point2d` - a fresh, un-memoized py-slvs
  /// point every call (unlike [point2d], never cached in [_pointHandles]),
  /// always in the free-to-move solve group regardless of whether the seed
  /// Point itself happens to be pinned, since an ephemeral point's own
  /// position is never meant to be pinned to anything - only the seed
  /// *value* is borrowed, not the seed Point's own pinned-ness. Used by
  /// [PointOnEllipseConstraintDto]'s Trammel of Archimedes construction for
  /// its two solver-internal auxiliary points, which have no meaning of
  /// their own a user could ever select/drag.
  @override
  int ephemeralPoint2d(String seedFromPointId) {
    final (x, y) = _pointXY(seedFromPointId);
    return ephemeralPoint2dAt(x, y);
  }

  /// [ephemeralPoint2d]'s own raw-coordinate sibling, for a Constraint that
  /// needs to seed its own scratch geometry at a *derived* position (e.g.
  /// PointOnEllipseConstraintDto's trammel auxiliary points, seeded at a
  /// computed trammel-rod position rather than any single existing Point's
  /// own literal position) instead of directly borrowing an existing
  /// Point's value. Mirrors solver.py's `ephemeral_point2d_at`.
  @override
  int ephemeralPoint2dAt(double x, double y) {
    final pu = _b.addParamV(_sys, x, slvsSolveGroup);
    final pv = _b.addParamV(_sys, y, slvsSolveGroup);
    return _b.addPoint2d(_sys, _workplane, pu, pv, slvsSolveGroup);
  }

  /// The *current* (pre-solve) raw position backing [pointId] - mirrors
  /// solver.py's `seed_xy`, exposing the same [_pointXY] lookup
  /// [point2d]/[ephemeralPoint2d] already use internally to a Constraint
  /// that needs to compute a derived initial guess from more than one
  /// existing Point's position at once.
  @override
  (double x, double y) seedXY(String pointId) => _pointXY(pointId);

  @override
  int distance(int pointAHandle, int pointBHandle, double value) =>
      _b.addPointsDistance(_sys, value, pointAHandle, pointBHandle, _workplane, slvsSolveGroup);

  int _fixedRefPoint(double u, double v) {
    final pu = _b.addParamV(_sys, u, slvsFixedGroup);
    final pv = _b.addParamV(_sys, v, slvsFixedGroup);
    return _b.addPoint2d(_sys, _workplane, pu, pv, slvsFixedGroup);
  }

  /// A fixed (never solved) line from (0,0) to (1,0) in workplane
  /// coordinates, used only as a direction reference for
  /// [horizontalDistance] - py-slvs has no addPointsHorizDistance/
  /// addPointsVertDistance primitive; the documented way to pin only one
  /// axis of separation is addPointsProjectDistance against a reference
  /// line in the desired direction. Lazily created and cached so at most
  /// one such line exists per solve.
  int _horizontalRefLineHandle() =>
      _horizontalRefLine ??= _b.addLineSegment(_sys, _fixedRefPoint(0.0, 0.0), _fixedRefPoint(1.0, 0.0), slvsFixedGroup);

  /// Same as [_horizontalRefLineHandle], but a (0,0)-(0,1) reference line
  /// for [verticalDistance].
  int _verticalRefLineHandle() =>
      _verticalRefLine ??= _b.addLineSegment(_sys, _fixedRefPoint(0.0, 0.0), _fixedRefPoint(0.0, 1.0), slvsFixedGroup);

  @override
  int horizontalDistance(String pointAId, String pointBId, double value) =>
      _projectDistance(pointAId, pointBId, value, _Axis.x, _horizontalRefLineHandle());

  @override
  int verticalDistance(String pointAId, String pointBId, double value) =>
      _projectDistance(pointAId, pointBId, value, _Axis.y, _verticalRefLineHandle());

  /// `addPointsProjectDistance` is a genuinely *signed* constraint: for a
  /// positive `value`, `addPointsProjectDistance(value, a, b, refLine)`
  /// deterministically solves `proj(b - a) == -value`, regardless of
  /// either Point's initial position (confirmed empirically against the
  /// installed py-slvs build - not a Newton-branch-selection ambiguity;
  /// re-seeding makes no difference). Rather than hardcode a fixed sign
  /// convention (deterministic but arbitrary, and wrong half the time
  /// depending on tap order), this chooses the sign that preserves
  /// whichever side point_b *already* sits on relative to point_a along
  /// this axis, before the solve - the same "nudge the value, don't
  /// teleport the geometry" behaviour a CAD user expects, and the same
  /// left-alone-if-already-satisfied default a Newton solver would give if
  /// this primitive weren't seed-independent. Defaults to the positive
  /// side only when the two Points start out exactly level/plumb.
  int _projectDistance(String pointAId, String pointBId, double value, _Axis axis, int refLineHandle) {
    final (ax, ay) = _pointXY(pointAId);
    final (bx, by) = _pointXY(pointBId);
    final currentSeparation = axis == _Axis.x ? bx - ax : by - ay;
    final signedValue = currentSeparation < 0 ? -value.abs() : value.abs();
    final pointAHandle = point2d(pointAId);
    final pointBHandle = point2d(pointBId);
    return _b.addPointsProjectDistance(_sys, -signedValue, pointAHandle, pointBHandle, refLineHandle, slvsSolveGroup);
  }

  @override
  int vertical(int pointAHandle, int pointBHandle) =>
      _b.addPointsVertical(_sys, pointAHandle, pointBHandle, _workplane, slvsSolveGroup);

  @override
  int horizontal(int pointAHandle, int pointBHandle) =>
      _b.addPointsHorizontal(_sys, pointAHandle, pointBHandle, _workplane, slvsSolveGroup);

  @override
  int lineSegment(int pointAHandle, int pointBHandle) =>
      _lineHandles.putIfAbsent((pointAHandle, pointBHandle), () => _b.addLineSegment(_sys, pointAHandle, pointBHandle, slvsSolveGroup));

  @override
  int cubic(int p0Handle, int p1Handle, int p2Handle, int p3Handle) => _cubicHandles.putIfAbsent(
      (p0Handle, p1Handle, p2Handle, p3Handle),
      () => _b.addCubic(_sys, _workplane, p0Handle, p1Handle, p2Handle, p3Handle, slvsSolveGroup));

  @override
  int curvesTangent(bool atEnd1, bool atEnd2, int curve1Handle, int curve2Handle) =>
      _b.addCurvesTangent(_sys, atEnd1 ? 1 : 0, atEnd2 ? 1 : 0, curve1Handle, curve2Handle, _workplane, slvsSolveGroup);

  @override
  int angle(int lineAHandle, int lineBHandle, double degrees, String lineAStartId, String lineAEndId,
      String lineBStartId, String lineBEndId) {
    final supplement = _angleNeedsSupplement(degrees, lineAStartId, lineAEndId, lineBStartId, lineBEndId);
    return _b.addAngle(_sys, degrees, supplement ? 1 : 0, lineAHandle, lineBHandle, _workplane, slvsSolveGroup);
  }

  /// py-slvs's addAngle takes a `supplement` flag choosing between
  /// constraining the angle to `degrees` or to its supplement
  /// (180 - degrees) - a genuine, un-auto-resolved ambiguity (unlike the
  /// ordinary +/- sign of an angle/distance, which Newton's method already
  /// picks correctly from any seed). Always passing false would force a
  /// Sketch already sitting near the *supplementary* configuration (e.g.
  /// one interior angle of a Polygon, mid-drag, while its neighbours hold
  /// the primary angle) to snap to the wrong angle - reported on-device as
  /// a dimension "flipping polarity". Chooses whichever of
  /// `degrees`/`180 - degrees` is closer to the Lines' currently *measured*
  /// angle - the same "preserve what's already true" principle
  /// [_projectDistance] uses - a no-op returning false when either Line
  /// has zero current length.
  bool _angleNeedsSupplement(
      double degrees, String aStartId, String aEndId, String bStartId, String bEndId) {
    final (aStartX, aStartY) = _pointXY(aStartId);
    final (aEndX, aEndY) = _pointXY(aEndId);
    final (bStartX, bStartY) = _pointXY(bStartId);
    final (bEndX, bEndY) = _pointXY(bEndId);
    final aDx = aEndX - aStartX, aDy = aEndY - aStartY;
    final bDx = bEndX - bStartX, bDy = bEndY - bStartY;
    final aLen = math.sqrt(aDx * aDx + aDy * aDy);
    final bLen = math.sqrt(bDx * bDx + bDy * bDy);
    if (aLen == 0 || bLen == 0) return false;
    final cosTheta = ((aDx * bDx + aDy * bDy) / (aLen * bLen)).clamp(-1.0, 1.0);
    final currentAngle = math.acos(cosTheta) * 180.0 / math.pi;
    return ((180.0 - degrees) - currentAngle).abs() < (degrees - currentAngle).abs();
  }

  @override
  int coincident(int pointAHandle, int pointBHandle) =>
      _b.addPointsCoincident(_sys, pointAHandle, pointBHandle, _workplane, slvsSolveGroup);

  @override
  int parallel(int lineAHandle, int lineBHandle) => _b.addParallel(_sys, lineAHandle, lineBHandle, _workplane, slvsSolveGroup);

  @override
  int perpendicular(int lineAHandle, int lineBHandle) =>
      _b.addPerpendicular(_sys, lineAHandle, lineBHandle, _workplane, slvsSolveGroup);

  @override
  int equalLength(int lineAHandle, int lineBHandle) =>
      _b.addEqualLength(_sys, lineAHandle, lineBHandle, _workplane, slvsSolveGroup);

  @override
  int equalLengthPointLineDistance(int pointHandle, int radiusLineHandle, int tangentLineHandle) => _b
      .addEqualLengthPointLineDistance(_sys, pointHandle, radiusLineHandle, tangentLineHandle, _workplane, slvsSolveGroup);

  @override
  int pointOnLine(int pointHandle, int lineHandle) =>
      _b.addPointOnLine(_sys, pointHandle, lineHandle, _workplane, slvsSolveGroup);

  @override
  int pointLineDistance(int pointHandle, int lineHandle, double value) =>
      _b.addPointLineDistance(_sys, value, pointHandle, lineHandle, _workplane, slvsSolveGroup);

  @override
  int atMidpoint(int pointHandle, int lineHandle) =>
      _b.addMidPoint(_sys, pointHandle, lineHandle, _workplane, slvsSolveGroup);
}

enum _Axis { x, y }
