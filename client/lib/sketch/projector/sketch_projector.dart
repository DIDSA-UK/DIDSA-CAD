// Solver-free, client-side constraint projector for sketch drags (the "wish > solve" design applied to sketches).
//
// Pure Dart: no FFI, no Flutter, no GPL code. Each frame of a drag the caller hands in a *wish* (the grabbed point at the
// cursor, a closed-form shape's other points at the shape's proposal, everything else where it is) and the projector lands the
// points of the dragged point's connected group ON the constraint manifold at the weighted-nearest point to that wish - so a
// constrained point slides along the permitted path while the shape keeps changing. The backend remains the authority (the
// drop sends the result as a wish and the real solve returns the final positions and DOF).
//
// Method (the same family as lib/motion/local_retraction.dart, the assembly projector):
//   * residuals + exact Jacobians per constraint type via forward-mode automatic differentiation over the 2-D coordinates of
//     the points a constraint touches (a few doubles per constraint; no finite differences, no solver);
//   * continuation, not a one-shot projection: start from the last accepted frame (which is on the constraint manifold) and
//     walk towards the wish. Each step pulls towards the wish with the minimum-norm correction
//     x <- x + y0 - Aᵀ(A Aᵀ + λI)⁻¹(A y0 + r)  (A = J W⁻¹, W = per-coordinate stiffness, y0 = the pull), is capped to a trust
//     radius, brought back onto the manifold by damped Newton correctors, and is reverted + halved if that fails. So the
//     answer is always a feasible point, a wish beyond a wall lands on the wall instead of failing, and the branch is kept;
//   * the min-norm correction makes redundant but consistent webs (a slot's tangent/equal-radius ring, a polygon's chain)
//     harmless: no rank decision, no wrong-root pick, because the walk never leaves the neighbourhood of the manifold;
//   * damping: along a curved constraint the plain pull overshoots by (1 + wish distance / curvature radius) and zigzags, so
//     every step must bring the wish closer (else its multiplier is halved), and a slow monotone tail is extrapolated (Aitken);
//   * component restricted: only points connected to the dragged point through constraints (without crossing pinned points)
//     are variables - a 10x10 grid of unconnected rectangles costs one rectangle;
//   * the same Jacobians give a mobility oracle ([analyseSketchMobility]): rank, DOF and per-point free motion.
//
// A constraint type the projector cannot evaluate (cubic-spline tangency) makes the whole call report `unsupported`, and the
// caller keeps its non-local path for that drag.
import 'dart:math' as math;
import 'dart:typed_data';

import '../../api/sketch_api_client.dart';

/// Resolves a Line id to its (start, end) Point ids.
typedef LineEndpoints = (String startId, String endId) Function(String lineId);

/// What a drag frame hands to its constraint step, for a caller that wants to replace [projectSketch] (tests use it to run
/// the real SolveSpace as a reference engine; the app never does). Returns the placed points, or null to reject the frame.
typedef SketchClampOverride = Map<String, (double, double)>? Function({
  required Map<String, (double, double)> points,
  required List<ConstraintDto> constraints,
  required LineEndpoints lineEndpoints,
  required Set<String> anchors,
  required Set<String> pinned,
  required Map<String, double> provisionalDistances,
});

/// Outcome of one projection.
class SketchProjection {
  /// The constraints hold at [points] (worst residual <= tolerance).
  final bool converged;

  /// A constraint in the dragged group has no residual model here - nothing was computed.
  final bool unsupported;

  /// Projected positions of the points in the dragged group (empty when [unsupported]).
  final Map<String, (double, double)> points;

  /// Worst absolute residual at [points].
  final double residualInf;
  final int iterations;

  /// Size of the system actually solved: free points, residual rows.
  final int variablePoints;
  final int rows;

  /// Walking steps taken / reverted, and why the walk ended ('arrived', 'wall', 'limit', 'stalled', 'none').
  final int walks;
  final int rejectedSteps;
  final String exit;

  const SketchProjection({
    required this.converged,
    required this.unsupported,
    required this.points,
    required this.residualInf,
    required this.iterations,
    required this.variablePoints,
    required this.rows,
    this.walks = 0,
    this.rejectedSteps = 0,
    this.exit = 'none',
  });
}

/// Stiffness of a point the caller does not care to keep still: corrections land here first (grabbed and proposal points are
/// stiff = 1, everything else follows). Small enough that a follower's pull back to where it was costs the grabbed point
/// ~1e-4 of its tracking.
const double kProjectorFollowerStiffness = 0.01;

/// Walking steps (pull towards the wish, then correct) per call, at most.
const int kProjectorNearestMax = 24;

/// A walking step that moves nothing further than this fraction of the group's size has arrived.
const double kProjectorArrived = 1e-5;

/// Smallest step multiplier before a walk that cannot get closer to the wish is declared arrived.
const double kProjectorMinOmega = 1.0 / 32;

/// Upper bound of the (Aitken) extrapolation factor on a walking step.
const double kProjectorMaxBoost = 8.0;

/// Corrector steps after each walking step before it is judged.
const int kProjectorCorrectors = 6;

/// Constraint-only steps to make the start feasible (a healthy frame needs 0-2).
const int kProjectorMaxPolish = 10;

/// Absolute residual tolerance is `kProjectorTolerance * max(1, group diagonal)`.
const double kProjectorTolerance = 1e-6;

/// Largest displacement of one walking step (sketch units): at least [kProjectorTrust], or [kProjectorTrustDiagonal] of the
/// group's diagonal. A step whose correctors cannot restore feasibility is reverted and the radius halved.
const double kProjectorTrust = 2.0;
const double kProjectorTrustDiagonal = 0.1;

// ---- forward-mode AD over a constraint's local coordinates -----------------------------------------------------------

class _D {
  final double v;
  final Float64List g;

  const _D(this.v, this.g);

  _D operator +(_D o) {
    final out = Float64List(g.length);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] + o.g[i];
    }
    return _D(v + o.v, out);
  }

  _D operator -(_D o) {
    final out = Float64List(g.length);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] - o.g[i];
    }
    return _D(v - o.v, out);
  }

  _D operator *(_D o) {
    final out = Float64List(g.length);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] * o.v + v * o.g[i];
    }
    return _D(v * o.v, out);
  }

  _D operator /(_D o) {
    final inv = 1.0 / o.v;
    final q = v * inv;
    final out = Float64List(g.length);
    for (var i = 0; i < g.length; i++) {
      out[i] = (g[i] - q * o.g[i]) * inv;
    }
    return _D(q, out);
  }

  _D scale(double s) {
    final out = Float64List(g.length);
    for (var i = 0; i < g.length; i++) {
      out[i] = g[i] * s;
    }
    return _D(v * s, out);
  }

  _D plus(double s) => _D(v + s, g);

  _D abs() => v >= 0 ? this : scale(-1);
}

class _P {
  final _D x;
  final _D y;
  const _P(this.x, this.y);
}

_P _sub(_P a, _P b) => _P(a.x - b.x, a.y - b.y);
_D _dot(_P a, _P b) => a.x * b.x + a.y * b.y;
_D _cross(_P a, _P b) => a.x * b.y - a.y * b.x;

const double _eps = 1e-12;

_D _len(_P a) {
  final s = _dot(a, a);
  final r = math.sqrt(math.max(s.v, _eps * _eps));
  final out = Float64List(s.g.length);
  for (var i = 0; i < out.length; i++) {
    out[i] = s.g[i] / (2 * r);
  }
  return _D(r, out);
}

/// `((p - s) x (e - s)) / |e - s|` - the sign convention of [DistanceConstraint]-style `LineDistance`/`PointLineDistance`
/// (the same one `local_sketch_solver.dart`'s `_signedPointLineDistance` verifies against).
_D _signedPointLine(_P p, _P s, _P e) {
  final d = _sub(e, s);
  return _cross(_sub(p, s), d) / _len(d);
}

// ---- constraint -> residual model -----------------------------------------------------------------------------------

class _Row {
  /// Residual value and its derivative per (free variable index) - sparse.
  final double value;
  final List<int> cols;
  final List<double> vals;
  const _Row(this.value, this.cols, this.vals);
}

/// The point ids a constraint reads, in a fixed order (duplicates removed). `null` for an unsupported type.
List<String>? _pointIdsOf(ConstraintDto c, LineEndpoints lines) {
  List<String> ids(List<String> raw) => raw.toSet().toList();
  List<String> line(String id) {
    final (s, e) = lines(id);
    return [s, e];
  }

  if (c is DistanceConstraintDto) return ids([c.pointAId, c.pointBId]);
  if (c is VerticalConstraintDto) return ids([c.pointAId, c.pointBId]);
  if (c is HorizontalConstraintDto) return ids([c.pointAId, c.pointBId]);
  if (c is AngleConstraintDto) return ids([...line(c.line1Id), ...line(c.line2Id)]);
  if (c is CoincidentConstraintDto) return ids([c.pointAId, c.pointBId]);
  if (c is ConcentricConstraintDto) return ids([c.center1PointId, c.center2PointId]);
  if (c is ParallelConstraintDto) return ids([...line(c.line1Id), ...line(c.line2Id)]);
  if (c is PerpendicularConstraintDto) return ids([...line(c.line1Id), ...line(c.line2Id)]);
  if (c is EqualLengthConstraintDto) return ids([...line(c.line1Id), ...line(c.line2Id)]);
  if (c is TangentConstraintDto) return ids([c.centerPointId, c.radiusPointId, ...line(c.lineId)]);
  if (c is CurveTangentConstraintDto) return ids([c.center1PointId, c.center2PointId, c.sharedPointId]);
  if (c is EqualRadiusConstraintDto) {
    return ids([c.center1PointId, c.radius1PointId, c.center2PointId, c.radius2PointId]);
  }
  if (c is LineDistanceConstraintDto) return ids([...line(c.line1Id), line(c.line2Id)[0]]);
  if (c is PointLineDistanceConstraintDto) return ids([c.pointId, ...line(c.lineId)]);
  if (c is CollinearConstraintDto) return ids([...line(c.line1Id), ...line(c.line2Id)]);
  if (c is AtMidpointConstraintDto) return ids([c.pointId, ...line(c.lineId)]);
  if (c is PointOnLineConstraintDto) return ids([c.pointId, ...line(c.lineId)]);
  if (c is PointOnCircleConstraintDto) return ids([c.pointId, c.centerPointId, c.radiusPointId]);
  if (c is PointOnEllipseConstraintDto) return ids([c.pointId, c.centerPointId, c.majorPointId, c.minorPointId]);
  if (c is FixedConstraintDto) return const <String>[];
  return null;
}

/// Branch choices that the solver makes once per solve from the geometry it starts from (an angle's supplement, the side of a
/// horizontal/vertical dimension). They are taken from [reference] (the last accepted frame), not from the proposal, so a
/// wish that crosses over is clamped instead of silently mirroring the dimension.
class _Branches {
  final bool Function(AngleConstraintDto) supplement;
  final double Function(DistanceConstraintDto) axisSign;
  const _Branches(this.supplement, this.axisSign);
}

/// Residuals of [c] over the local points [p] (id -> position with derivatives).
List<_D>? _residuals(ConstraintDto c, LineEndpoints lines, _P Function(String) p, _Branches br, int k) {
  _P a(String id) => p(id);
  (_P, _P) seg(String lineId) {
    final (s, e) = lines(lineId);
    return (p(s), p(e));
  }

  if (c is DistanceConstraintDto) {
    final pa = a(c.pointAId), pb = a(c.pointBId);
    final d = c.distance.abs();
    if (c.orientation == 'horizontal') return [(pb.x - pa.x).scale(br.axisSign(c)).plus(-d)];
    if (c.orientation == 'vertical') return [(pb.y - pa.y).scale(br.axisSign(c)).plus(-d)];
    return [_len(_sub(pb, pa)).plus(-d)];
  }
  if (c is VerticalConstraintDto) return [a(c.pointAId).x - a(c.pointBId).x];
  if (c is HorizontalConstraintDto) return [a(c.pointAId).y - a(c.pointBId).y];
  if (c is CoincidentConstraintDto) {
    final pa = a(c.pointAId), pb = a(c.pointBId);
    return [pa.x - pb.x, pa.y - pb.y];
  }
  if (c is ConcentricConstraintDto) {
    final pa = a(c.center1PointId), pb = a(c.center2PointId);
    return [pa.x - pb.x, pa.y - pb.y];
  }
  if (c is AngleConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final (s2, e2) = seg(c.line2Id);
    final u = _sub(e1, s1), v = _sub(e2, s2);
    var target = c.angleDegrees.abs() % 360;
    target = math.min(target, 360 - target);
    if (br.supplement(c)) target = 180 - target;
    // u.v - |u||v| cos(target): no division, smooth through zero.
    return [_dot(u, v) - (_len(u) * _len(v)).scale(math.cos(target * math.pi / 180))];
  }
  if (c is ParallelConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final (s2, e2) = seg(c.line2Id);
    final u = _sub(e1, s1), v = _sub(e2, s2);
    return [_cross(u, v) / (_len(u) * _len(v))];
  }
  if (c is PerpendicularConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final (s2, e2) = seg(c.line2Id);
    final u = _sub(e1, s1), v = _sub(e2, s2);
    return [_dot(u, v) / (_len(u) * _len(v))];
  }
  if (c is EqualLengthConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final (s2, e2) = seg(c.line2Id);
    return [_len(_sub(e1, s1)) - _len(_sub(e2, s2))];
  }
  if (c is TangentConstraintDto) {
    final (ls, le) = seg(c.lineId);
    final center = a(c.centerPointId);
    return [_signedPointLine(center, ls, le).abs() - _len(_sub(a(c.radiusPointId), center))];
  }
  if (c is CurveTangentConstraintDto) {
    return [_signedPointLine(a(c.sharedPointId), a(c.center1PointId), a(c.center2PointId))];
  }
  if (c is EqualRadiusConstraintDto) {
    return [
      _len(_sub(a(c.radius1PointId), a(c.center1PointId))) - _len(_sub(a(c.radius2PointId), a(c.center2PointId))),
    ];
  }
  if (c is LineDistanceConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final s2 = p(lines(c.line2Id).$1);
    return [_signedPointLine(s2, s1, e1).plus(-c.distance)];
  }
  if (c is PointLineDistanceConstraintDto) {
    final (ls, le) = seg(c.lineId);
    return [_signedPointLine(a(c.pointId), ls, le).plus(-c.distance)];
  }
  if (c is CollinearConstraintDto) {
    final (s1, e1) = seg(c.line1Id);
    final (s2, e2) = seg(c.line2Id);
    return [_signedPointLine(s2, s1, e1), _signedPointLine(e2, s1, e1)];
  }
  if (c is AtMidpointConstraintDto) {
    final (ls, le) = seg(c.lineId);
    final pt = a(c.pointId);
    return [pt.x - (ls.x + le.x).scale(0.5), pt.y - (ls.y + le.y).scale(0.5)];
  }
  if (c is PointOnLineConstraintDto) {
    final (ls, le) = seg(c.lineId);
    return [_signedPointLine(a(c.pointId), ls, le)];
  }
  if (c is PointOnCircleConstraintDto) {
    final center = a(c.centerPointId);
    return [_len(_sub(a(c.pointId), center)) - _len(_sub(a(c.radiusPointId), center))];
  }
  if (c is PointOnEllipseConstraintDto) {
    // On the ellipse with semi-axes |major - centre| and |minor - centre| (the backend builds it as a trammel; the axes'
    // perpendicularity is the shape's own structural constraint). Scaled by the major radius so the residual is a length.
    final center = a(c.centerPointId);
    final m = _sub(a(c.majorPointId), center);
    final n = _sub(a(c.minorPointId), center);
    final d = _sub(a(c.pointId), center);
    final aa = _len(m), bb = _len(n);
    final u = _dot(d, m) / (aa * aa); // = (d . m̂) / a
    final w = _dot(d, n) / (bb * bb); // = (d . n̂) / b
    final f = u * u + w * w;
    // sqrt(f) - 1 is zero on the curve; a constant mean-radius factor makes it a length (its own derivative is multiplied by
    // a residual that is zero at the answer, so it is left out of the Jacobian).
    return [f.sqrtMinusOne().scale((aa.v + bb.v) / 2)];
  }
  if (c is FixedConstraintDto) return const <_D>[];
  return null;
}

extension on _D {
  /// `sqrt(this) - 1` with derivative (clamped away from 0).
  _D sqrtMinusOne() {
    final r = math.sqrt(math.max(v, _eps));
    final out = Float64List(g.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = g[i] / (2 * r);
    }
    return _D(r - 1, out);
  }
}

// ---- the constraint system of a group of points ---------------------------------------------------------------------

/// The active constraints of the group of points reachable from [startIds] through constraints (not crossing pinned points),
/// with the residual/Jacobian evaluation over that group's free coordinates. Shared by the projector and the mobility oracle.
class _System {
  final bool unsupported;

  /// Free points of the group, in variable order (variable `2*i`, `2*i+1` = x, y of `varIds[i]`).
  final List<String> varIds;
  final Map<String, int> varOf;
  final List<ConstraintDto> _active;
  final List<List<String>> _idsOf;
  final List<int> _groupList;
  final Map<String, (double, double)> _points;
  final LineEndpoints _lines;
  final _Branches _branches;

  _System._(this.unsupported, this.varIds, this.varOf, this._active, this._idsOf, this._groupList, this._points, this._lines,
      this._branches);

  factory _System.build({
    required Map<String, (double, double)> points,
    required List<ConstraintDto> constraints,
    required LineEndpoints lineEndpoints,
    required Set<String> startIds,
    required Set<String> pinned,
    required Map<String, double> provisionalDistances,
    Map<String, (double, double)>? reference,
  }) {
    final ref = reference ?? points;

    // 1. active constraints and the point ids each reads.
    final active = <ConstraintDto>[];
    final idsOf = <List<String>>[];
    for (var c in constraints) {
      if (c is DistanceConstraintDto && c.provisional) {
        final size = provisionalDistances[c.id];
        if (size == null) continue; // not yet confirmed: contributes nothing
        c = DistanceConstraintDto(
          id: c.id,
          pointAId: c.pointAId,
          pointBId: c.pointBId,
          distance: size,
          orientation: c.orientation,
        );
      }
      if (c is FixedConstraintDto) continue; // pinned by the caller through [pinned]
      final ids = _pointIdsOf(c, lineEndpoints);
      if (ids == null) {
        // Only an unsupported constraint that touches the group matters; decided after the group is known.
        active.add(c);
        idsOf.add(const <String>[]);
        continue;
      }
      if (ids.any((id) => !points.containsKey(id))) continue;
      active.add(c);
      idsOf.add(ids);
    }

    // 2. the group: BFS from the start points over shared non-pinned points.
    final byPoint = <String, List<int>>{};
    for (var i = 0; i < active.length; i++) {
      for (final id in idsOf[i]) {
        (byPoint[id] ??= <int>[]).add(i);
      }
    }
    final inGroup = <String>{};
    final groupConstraints = <int>{};
    final queue = <String>[
      for (final id in startIds)
        if (points.containsKey(id) && !pinned.contains(id)) id,
    ];
    inGroup.addAll(queue);
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      for (final ci in byPoint[id] ?? const <int>[]) {
        if (!groupConstraints.add(ci)) continue;
        for (final other in idsOf[ci]) {
          if (!pinned.contains(other) && inGroup.add(other)) queue.add(other);
        }
      }
    }
    // An unsupported constraint cannot be discovered through its (unknown) point ids: check its type against the group.
    var unsupported = false;
    for (var i = 0; i < active.length; i++) {
      if (_pointIdsOf(active[i], lineEndpoints) == null && _touchesGroup(active[i], inGroup)) unsupported = true;
    }

    final varOf = <String, int>{};
    final varIds = <String>[];
    for (final id in inGroup) {
      varOf[id] = varIds.length;
      varIds.add(id);
    }

    // branch choices from the reference frame
    double angleBetween(AngleConstraintDto c) {
      final (s1, e1) = lineEndpoints(c.line1Id);
      final (s2, e2) = lineEndpoints(c.line2Id);
      final a1 = ref[s1], a2 = ref[e1], b1 = ref[s2], b2 = ref[e2];
      if (a1 == null || a2 == null || b1 == null || b2 == null) return 0;
      final ax = a2.$1 - a1.$1, ay = a2.$2 - a1.$2, bx = b2.$1 - b1.$1, by = b2.$2 - b1.$2;
      final la = math.sqrt(ax * ax + ay * ay), lb = math.sqrt(bx * bx + by * by);
      if (la == 0 || lb == 0) return -1;
      return math.acos(((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0)) * 180 / math.pi;
    }

    final branches = _Branches(
      (c) {
        final current = angleBetween(c);
        if (current < 0) return false;
        var target = c.angleDegrees.abs() % 360;
        target = math.min(target, 360 - target);
        return ((180.0 - target) - current).abs() < (target - current).abs();
      },
      (c) {
        final pa = ref[c.pointAId], pb = ref[c.pointBId];
        if (pa == null || pb == null) return 1.0;
        final d = c.orientation == 'horizontal' ? pb.$1 - pa.$1 : pb.$2 - pa.$2;
        return d < 0 ? -1.0 : 1.0;
      },
    );

    return _System._(unsupported, varIds, varOf, active, idsOf, groupConstraints.toList()..sort(), points, lineEndpoints, branches);
  }

  /// Residual rows with their sparse Jacobian at the coordinates [x] (the group's free variables).
  List<_Row> evaluate(Float64List x) {
    final rows = <_Row>[];
    for (final ci in _groupList) {
      final c = _active[ci];
      final ids = _idsOf[ci];
      final k = 2 * ids.length;
      final slot = <String, int>{for (var i = 0; i < ids.length; i++) ids[i]: i};
      _P local(String id) {
        final i = slot[id]!;
        final v = varOf[id];
        final xv = v != null ? x[2 * v] : _points[id]!.$1;
        final yv = v != null ? x[2 * v + 1] : _points[id]!.$2;
        final gx = Float64List(k), gy = Float64List(k);
        if (v != null) {
          gx[2 * i] = 1;
          gy[2 * i + 1] = 1;
        }
        return _P(_D(xv, gx), _D(yv, gy));
      }

      final res = _residuals(c, _lines, local, _branches, k);
      if (res == null) continue;
      for (final r in res) {
        final cols = <int>[];
        final vals = <double>[];
        for (var i = 0; i < ids.length; i++) {
          final v = varOf[ids[i]];
          if (v == null) continue;
          for (var d = 0; d < 2; d++) {
            final g = r.g[2 * i + d];
            if (g != 0) {
              cols.add(2 * v + d);
              vals.add(g);
            }
          }
        }
        rows.add(_Row(r.v, cols, vals));
      }
    }
    return rows;
  }
}

// ---- the projector --------------------------------------------------------------------------------------------------

/// Projects the group of [anchorPointIds] onto [constraints].
///
/// * [points] - the wish and the starting point (the grabbed point at the cursor, a shape's proposal, the rest where it is).
/// * [stiffPointIds] - points the correction should avoid moving (the grabbed point(s) and a closed-form shape's proposal);
///   every other free point is a follower with stiffness [followerStiffness].
/// * [pinnedPointIds] - never move (origin, locked/fixed points).
/// * [provisionalDistances] - a shape's still-unconfirmed size constraints, switched on at these values for this call only
///   (see `SketchController`'s hybrid drag).
/// * [reference] - last accepted positions; branch choices (angle supplement, side of a horizontal/vertical dimension) come
///   from here. Defaults to [points].
SketchProjection projectSketch({
  required Map<String, (double, double)> points,
  required List<ConstraintDto> constraints,
  required LineEndpoints lineEndpoints,
  required Set<String> anchorPointIds,
  Set<String> stiffPointIds = const {},
  Set<String> pinnedPointIds = const {},
  Map<String, double> provisionalDistances = const {},
  Map<String, (double, double)>? reference,
  double followerStiffness = kProjectorFollowerStiffness,
  int maxPolish = kProjectorMaxPolish,
}) {
  const unsupported = SketchProjection(
    converged: false,
    unsupported: true,
    points: <String, (double, double)>{},
    residualInf: double.infinity,
    iterations: 0,
    variablePoints: 0,
    rows: 0,
  );
  final system = _System.build(
    points: points,
    constraints: constraints,
    lineEndpoints: lineEndpoints,
    startIds: anchorPointIds,
    pinned: pinnedPointIds,
    provisionalDistances: provisionalDistances,
    reference: reference,
  );
  if (system.unsupported) return unsupported;
  if (system.varIds.isEmpty) {
    return const SketchProjection(
      converged: true,
      unsupported: false,
      points: <String, (double, double)>{},
      residualInf: 0,
      iterations: 0,
      variablePoints: 0,
      rows: 0,
    );
  }
  final varIds = system.varIds;

  // variables, bounding box (tolerance scale).
  final n = 2 * varIds.length;
  final x = Float64List(n);
  final wish = Float64List(n);
  final stiff = Float64List(n);
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (var i = 0; i < varIds.length; i++) {
    final (px, py) = points[varIds[i]]!;
    // Start from the last accepted frame (on the constraint manifold) and walk towards the wish: continuation keeps the
    // branch and never has to project a far-off wish in one non-convex jump.
    final (sx, sy) = reference?[varIds[i]] ?? (px, py);
    x[2 * i] = sx;
    x[2 * i + 1] = sy;
    wish[2 * i] = px;
    wish[2 * i + 1] = py;
    final s = (anchorPointIds.contains(varIds[i]) || stiffPointIds.contains(varIds[i])) ? 1.0 : followerStiffness;
    stiff[2 * i] = s;
    stiff[2 * i + 1] = s;
    minX = math.min(minX, sx);
    maxX = math.max(maxX, sx);
    minY = math.min(minY, sy);
    maxY = math.max(maxY, sy);
  }
  final diagonal = math.sqrt(math.pow(maxX - minX, 2) + math.pow(maxY - minY, 2));
  final tolerance = kProjectorTolerance * math.max(1.0, diagonal);

  List<_Row> evaluate() => system.evaluate(x);

  // 5. sequential nearest-point Gauss-Newton: [kProjectorNearestIterations] steps that also pull towards the wish, then
  // constraint-only polish steps (quadratic convergence) until the residual is within tolerance.
  var rows = evaluate();
  double worst(List<_Row> rs) {
    var m = 0.0;
    for (final r in rs) {
      m = math.max(m, r.value.abs());
    }
    return m;
  }

  var residualInf = worst(rows);
  var iterations = 0;
  final zero = Float64List(n);
  final trust = math.max(kProjectorTrust, kProjectorTrustDiagonal * diagonal);

  // One damped constraint-only Newton step (min-norm in the scaled metric, halved until the residual norm drops). False
  // when no step length improves it.
  bool correct() {
    final y = _correction(rows, n, stiff, zero, 1.0);
    final before = _norm2(rows);
    final saved = Float64List.fromList(x);
    var alpha = 1.0;
    for (var attempt = 0; attempt < 8; attempt++) {
      for (var c = 0; c < n; c++) {
        x[c] = saved[c] + alpha * y[c] / stiff[c];
      }
      final next = evaluate();
      if (_norm2(next) < before) {
        rows = next;
        residualInf = worst(rows);
        iterations++;
        return true;
      }
      alpha *= 0.5;
    }
    x.setAll(0, saved);
    return false;
  }

  double wishDistanceNow() {
    var d = 0.0;
    for (var c = 0; c < n; c++) {
      final e = stiff[c] * (wish[c] - x[c]);
      d += e * e;
    }
    return math.sqrt(d);
  }

  // 0. a feasible start (the last accepted frame is; a frame whose provisional sizes just changed is nearly so).
  for (var polish = 0; polish < maxPolish && rows.isNotEmpty && residualInf > tolerance; polish++) {
    if (!correct()) break;
  }

  // 1. Walk towards the wish by continuation: each pull (tangent projection + first-order correction, displacement capped
  // at the trust radius) must be brought back onto the manifold by a few correctors, else it is reverted and halved. The
  // answer is therefore always a feasible point; a wish beyond a wall stops at the wall (the nearest point) instead of
  // failing.
  var radius = trust;
  var stalled = 0;
  var walks = 0;
  var rejected = 0;
  var exit = 'limit';
  Float64List? prevStep;
  var omega = 1.0;
  for (var walk = 0; walk < kProjectorNearestMax && rows.isNotEmpty && residualInf <= tolerance; walk++) {
    final n0 = wishDistanceNow();
    if (n0 < tolerance) {
      exit = 'arrived';
      break;
    }
    final saved = Float64List.fromList(x);
    final savedRows = rows;
    final y0 = Float64List(n);
    for (var c = 0; c < n; c++) {
      y0[c] = stiff[c] * (wish[c] - x[c]);
    }
    // The pull is NOT limited: most of it may be blocked by the constraints, and what slides along them is what we want.
    // The step actually taken is capped below.
    final y = _correction(rows, n, stiff, y0, 1.0);
    var biggest = 0.0;
    for (var c = 0; c < n; c++) {
      biggest = math.max(biggest, (y[c] / stiff[c]).abs());
    }
    // The constraints block the whole pull (it is all normal to the manifold): this is the nearest point.
    if (biggest < kProjectorArrived * math.max(1.0, diagonal)) {
      exit = 'arrived';
      break;
    }
    // Step multiplier. Along a curved constraint the plain pull overshoots by (1 + wish distance / curvature radius) and
    // zigzags; a halved multiplier removes that. On a slow monotone tail (ratio rho of consecutive steps near 1) it is
    // extrapolated 1/(1-rho) instead (Aitken). Every step must stay feasible AND bring the grabbed point closer to the
    // wish, else the multiplier is halved (and finally the walk has arrived: nothing improves).
    var boost = 1.0;
    if (prevStep != null) {
      var dot = 0.0, prevNorm = 0.0;
      for (var c = 0; c < n; c++) {
        dot += (y[c] / stiff[c]) * prevStep[c];
        prevNorm += prevStep[c] * prevStep[c];
      }
      final rho = prevNorm > 0 ? dot / prevNorm : 0.0;
      if (rho < -0.3) omega = math.max(kProjectorMinOmega, omega * 0.5);
      if (rho > 0.5 && rho < 0.999) boost = math.min(kProjectorMaxBoost, 1 / (1 - rho));
    }
    var accepted = false;
    var infeasible = false;
    for (final attempt in boost > 1.0 ? [omega * boost, omega] : [omega]) {
      final cap = biggest * attempt > radius ? radius / (biggest * attempt) : 1.0;
      for (var c = 0; c < n; c++) {
        x[c] = saved[c] + attempt * cap * y[c] / stiff[c];
      }
      rows = evaluate();
      residualInf = worst(rows);
      iterations++;
      for (var k = 0; k < kProjectorCorrectors && residualInf > tolerance; k++) {
        if (!correct()) break;
      }
      if (residualInf <= tolerance && wishDistanceNow() < n0 * (1 - 1e-9)) {
        accepted = true;
        break;
      }
      if (residualInf > tolerance) infeasible = true;
      x.setAll(0, saved);
      rows = savedRows;
      residualInf = worst(rows);
    }
    if (!accepted) {
      prevStep = null;
      if (infeasible) {
        // the step was too long for the curvature here: shrink the trust radius
        radius *= 0.5;
        rejected++;
        if (++stalled > 5) {
          exit = 'stalled';
          break;
        }
      } else {
        // feasible but not closer: overshoot (halve) - or, at the floor, this is the nearest point
        omega *= 0.5;
        rejected++;
        if (omega < kProjectorMinOmega) {
          exit = 'arrived';
          break;
        }
      }
      continue;
    }
    walks++;
    stalled = 0;
    radius = math.min(trust, radius * 2);
    // Arrived (the wish is met, or a wall/optimum leaves nowhere to go): the step actually taken is negligible.
    var moved = 0.0;
    final step = Float64List(n);
    for (var c = 0; c < n; c++) {
      step[c] = x[c] - saved[c];
      moved = math.max(moved, step[c].abs());
    }
    prevStep = step;
    if (moved < kProjectorArrived * math.max(1.0, diagonal) || wishDistanceNow() < tolerance) {
      exit = 'arrived';
      break;
    }
  }

  final out = <String, (double, double)>{
    for (var i = 0; i < varIds.length; i++) varIds[i]: (x[2 * i], x[2 * i + 1]),
  };
  var finite = true;
  for (final v in x) {
    if (!v.isFinite) finite = false;
  }
  return SketchProjection(
    converged: finite && residualInf <= tolerance,
    unsupported: false,
    points: out,
    residualInf: residualInf,
    iterations: iterations,
    variablePoints: varIds.length,
    rows: rows.length,
    walks: walks,
    rejectedSteps: rejected,
    exit: exit,
  );
}

double _norm2(List<_Row> rs) {
  var s = 0.0;
  for (final r in rs) {
    s += r.value * r.value;
  }
  return s;
}

bool _touchesGroup(ConstraintDto c, Set<String> group) {
  // Spline tangency: the only unsupported type; its points are the eight control points.
  if (c is SplineTangentConstraintDto) {
    return group.contains(c.segmentAP0) ||
        group.contains(c.segmentAP1) ||
        group.contains(c.segmentAP2) ||
        group.contains(c.segmentAP3) ||
        group.contains(c.segmentBP0) ||
        group.contains(c.segmentBP1) ||
        group.contains(c.segmentBP2) ||
        group.contains(c.segmentBP3);
  }
  return true; // an unknown type: be safe
}

/// One sequential step: `y0' - Aᵀ(A Aᵀ + λI)⁻¹(A y0' + r)` in the scaled metric (`A = J W⁻¹`), with `y0' = f0 * y0`.
Float64List _correction(List<_Row> rows, int n, Float64List stiff, Float64List y0, double f0) {
  final m = rows.length;
  // scaled sparse rows
  final aVals = <List<double>>[
    for (final r in rows) [for (var i = 0; i < r.cols.length; i++) r.vals[i] / stiff[r.cols[i]]],
  ];
  // columns -> rows, for A Aᵀ
  final colRows = List<List<int>>.generate(n, (_) => <int>[]);
  final colPos = List<List<int>>.generate(n, (_) => <int>[]);
  for (var i = 0; i < m; i++) {
    final cols = rows[i].cols;
    for (var j = 0; j < cols.length; j++) {
      colRows[cols[j]].add(i);
      colPos[cols[j]].add(j);
    }
  }
  final mat = List<Float64List>.generate(m, (_) => Float64List(m));
  for (var c = 0; c < n; c++) {
    final rs = colRows[c], ps = colPos[c];
    for (var p = 0; p < rs.length; p++) {
      final vp = aVals[rs[p]][ps[p]];
      for (var q = p; q < rs.length; q++) {
        final add = vp * aVals[rs[q]][ps[q]];
        mat[rs[p]][rs[q]] += add;
        if (q != p) mat[rs[q]][rs[p]] += add;
      }
    }
  }
  var maxDiag = 0.0;
  for (var i = 0; i < m; i++) {
    maxDiag = math.max(maxDiag, mat[i][i]);
  }
  final lambda = 1e-10 * maxDiag + 1e-14;
  for (var i = 0; i < m; i++) {
    mat[i][i] += lambda;
  }
  final yScaled = Float64List(n);
  for (var c = 0; c < n; c++) {
    yScaled[c] = y0[c] * f0;
  }
  final rhs = Float64List(m);
  for (var i = 0; i < m; i++) {
    var s = rows[i].value;
    final cols = rows[i].cols;
    for (var j = 0; j < cols.length; j++) {
      s += aVals[i][j] * yScaled[cols[j]];
    }
    rhs[i] = s;
  }
  final z = _solveSpd(mat, rhs);
  final out = Float64List.fromList(yScaled);
  for (var i = 0; i < m; i++) {
    final cols = rows[i].cols;
    for (var j = 0; j < cols.length; j++) {
      out[cols[j]] -= aVals[i][j] * z[i];
    }
  }
  return out;
}

/// Gaussian elimination with partial pivoting (destroys [m]); symmetric positive semi-definite plus damping.
Float64List _solveSpd(List<Float64List> m, Float64List b) {
  final k = b.length;
  final rhs = Float64List.fromList(b);
  for (var col = 0; col < k; col++) {
    var piv = col;
    var best = m[col][col].abs();
    for (var r = col + 1; r < k; r++) {
      final v = m[r][col].abs();
      if (v > best) {
        best = v;
        piv = r;
      }
    }
    if (piv != col) {
      final tmp = m[col];
      m[col] = m[piv];
      m[piv] = tmp;
      final tb = rhs[col];
      rhs[col] = rhs[piv];
      rhs[piv] = tb;
    }
    final d = m[col][col];
    if (d == 0) continue;
    for (var r = col + 1; r < k; r++) {
      final f = m[r][col] / d;
      if (f == 0) continue;
      for (var c = col; c < k; c++) {
        m[r][c] -= f * m[col][c];
      }
      rhs[r] -= f * rhs[col];
    }
  }
  final x = Float64List(k);
  for (var r = k - 1; r >= 0; r--) {
    var s = rhs[r];
    for (var c = r + 1; c < k; c++) {
      s -= m[r][c] * x[c];
    }
    final d = m[r][r];
    x[r] = d == 0 ? 0.0 : s / d;
  }
  return x;
}

// ---- mobility oracle ------------------------------------------------------------------------------------------------

/// What the constraints leave free, measured on the same Jacobians the projector uses (first order, at the given positions).
///
/// This is a rank computation, not a structural count: redundant-but-consistent constraints (a slot's tangent ring, a
/// rectangle's doubled parallel) do not fool it, and a point pinned by a dimension plus a horizontal is found pinned even
/// though no single constraint says so.
class SketchMobility {
  /// A constraint in the group has no residual model: nothing was measured.
  final bool unsupported;

  /// Free points in the analysed group, residual rows, and the rank of the constraint Jacobian.
  final int variablePoints;
  final int rows;
  final int rank;

  /// Degrees of freedom of the group: `2 * variablePoints - rank`.
  final int dof;

  /// Worst constraint residual at the given positions (large = the positions do not satisfy the constraints).
  final double residualInf;

  /// Per free point of the group: 0 = cannot move, 1 = slides along one direction, 2 = free.
  final Map<String, int> pointMobility;

  /// Unit direction of the one permitted motion, for points with mobility 1.
  final Map<String, (double, double)> direction;

  const SketchMobility({
    required this.unsupported,
    required this.variablePoints,
    required this.rows,
    required this.rank,
    required this.dof,
    required this.residualInf,
    required this.pointMobility,
    required this.direction,
  });

  /// Mobility of [pointId] (2 for a point outside the analysed group's constraints: nothing holds it).
  int mobilityOf(String pointId) => pointMobility[pointId] ?? 2;
}

/// Measures the mobility of the group of points reachable from [startIds] through [constraints] (without crossing
/// [pinnedPointIds]) at the positions in [points]. Provisional dimensions do not count, like in the solver.
SketchMobility analyseSketchMobility({
  required Map<String, (double, double)> points,
  required List<ConstraintDto> constraints,
  required LineEndpoints lineEndpoints,
  required Set<String> startIds,
  Set<String> pinnedPointIds = const {},
}) {
  const empty = SketchMobility(
    unsupported: true,
    variablePoints: 0,
    rows: 0,
    rank: 0,
    dof: 0,
    residualInf: double.infinity,
    pointMobility: <String, int>{},
    direction: <String, (double, double)>{},
  );
  final system = _System.build(
    points: points,
    constraints: constraints,
    lineEndpoints: lineEndpoints,
    startIds: startIds,
    pinned: pinnedPointIds,
    provisionalDistances: const {},
  );
  if (system.unsupported) return empty;
  final varIds = system.varIds;
  final n = 2 * varIds.length;
  final x = Float64List(n);
  for (var i = 0; i < varIds.length; i++) {
    final (px, py) = points[varIds[i]]!;
    x[2 * i] = px;
    x[2 * i + 1] = py;
  }
  final rows = [
    for (final r in system.evaluate(x))
      if (r.cols.isNotEmpty) r,
  ];
  var residualInf = 0.0;
  for (final r in rows) {
    residualInf = math.max(residualInf, r.value.abs());
  }

  // Reduced row echelon form with column-wise partial pivoting.
  final a = List<Float64List>.generate(rows.length, (i) {
    final row = Float64List(n);
    for (var j = 0; j < rows[i].cols.length; j++) {
      row[rows[i].cols[j]] += rows[i].vals[j];
    }
    return row;
  });
  var maxAbs = 1.0;
  for (final row in a) {
    for (final v in row) {
      maxAbs = math.max(maxAbs, v.abs());
    }
  }
  final tol = kMobilityPivotTolerance * maxAbs;
  final pivotCol = <int>[];
  var r = 0;
  for (var col = 0; col < n && r < a.length; col++) {
    var best = r;
    for (var i = r + 1; i < a.length; i++) {
      if (a[i][col].abs() > a[best][col].abs()) best = i;
    }
    if (a[best][col].abs() <= tol) continue;
    final tmp = a[r];
    a[r] = a[best];
    a[best] = tmp;
    final inv = 1.0 / a[r][col];
    for (var c = col; c < n; c++) {
      a[r][c] *= inv;
    }
    for (var i = 0; i < a.length; i++) {
      if (i == r) continue;
      final f = a[i][col];
      if (f == 0) continue;
      for (var c = col; c < n; c++) {
        a[i][c] -= f * a[r][c];
      }
    }
    pivotCol.add(col);
    r++;
  }
  final rank = pivotCol.length;
  final isPivot = List<bool>.filled(n, false);
  for (final c in pivotCol) {
    isPivot[c] = true;
  }

  // Nullspace basis (free column f: x_f = 1, x_pivot = -R[row][f]), orthonormalised so that per-point shares are meaningful.
  final basis = <Float64List>[];
  for (var f = 0; f < n; f++) {
    if (isPivot[f]) continue;
    final v = Float64List(n);
    v[f] = 1.0;
    for (var i = 0; i < pivotCol.length; i++) {
      v[pivotCol[i]] = -a[i][f];
    }
    for (final q in basis) {
      var dot = 0.0;
      for (var c = 0; c < n; c++) {
        dot += v[c] * q[c];
      }
      for (var c = 0; c < n; c++) {
        v[c] -= dot * q[c];
      }
    }
    var norm = 0.0;
    for (final e in v) {
      norm += e * e;
    }
    norm = math.sqrt(norm);
    if (norm < 1e-12) continue;
    for (var c = 0; c < n; c++) {
      v[c] /= norm;
    }
    basis.add(v);
  }

  final mobility = <String, int>{};
  final direction = <String, (double, double)>{};
  for (var i = 0; i < varIds.length; i++) {
    // G = M Mᵀ for the point's 2 x k block M of the basis.
    var gxx = 0.0, gxy = 0.0, gyy = 0.0;
    for (final q in basis) {
      gxx += q[2 * i] * q[2 * i];
      gxy += q[2 * i] * q[2 * i + 1];
      gyy += q[2 * i + 1] * q[2 * i + 1];
    }
    final tr = gxx + gyy;
    final det = gxx * gyy - gxy * gxy;
    final disc = math.sqrt(math.max(0.0, tr * tr / 4 - det));
    final l1 = tr / 2 + disc, l2 = tr / 2 - disc;
    final rank2 = (l1 > kMobilityShareTolerance ? 1 : 0) + (l2 > kMobilityShareTolerance ? 1 : 0);
    mobility[varIds[i]] = rank2;
    if (rank2 == 1) {
      // eigenvector of the larger eigenvalue
      var dx = gxy, dy = l1 - gxx;
      if (dx.abs() + dy.abs() < 1e-18) {
        dx = gxx >= gyy ? 1.0 : 0.0;
        dy = gxx >= gyy ? 0.0 : 1.0;
      }
      final len = math.sqrt(dx * dx + dy * dy);
      direction[varIds[i]] = (dx / len, dy / len);
    }
  }
  return SketchMobility(
    unsupported: false,
    variablePoints: varIds.length,
    rows: rows.length,
    rank: rank,
    dof: n - rank,
    residualInf: residualInf,
    pointMobility: mobility,
    direction: direction,
  );
}

/// Pivot threshold of the Jacobian's row reduction, relative to its largest entry.
const double kMobilityPivotTolerance = 1e-8;

/// A point whose share of the (orthonormal) free-motion basis is below this cannot move.
const double kMobilityShareTolerance = 1e-9;
