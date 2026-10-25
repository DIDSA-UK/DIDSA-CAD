/// Local nearest-point retraction (`docs/motion/projector-spec.md` §4b, F1b): the client evaluates the mates itself every
/// frame from the anchor's `constraint_model` and lands the displayed poses ON the mate manifold at the weighted-nearest
/// point to the hand's wish, instead of moving along the linearised free motion and being popped back at the next anchor.
///
/// Pure Dart (no Flutter): residuals of the five mate types with analytic forward-mode Jacobians (the same residuals as the
/// backend's `_mate_residual_vector`: each is zero ONLY on the branch the mate names - `alignment` / `side` / `perp` in the
/// model, `docs/mate-solution-choice-plan.md`), a fixed-iteration trust-region sequential nearest-point solve, and the acceptance
/// guard that makes it "never worse than the projection". Reproduces the `local_retract` golden vectors to 1e-9.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'se3.dart';
import 'weighted_basis.dart' show memberScale;

/// Follower weight of the LOCAL solve (the projection metric keeps `kFollowerWeight` = 1e-4, which squares to 1e8 in `A·Aᵀ`).
const double kLocalFollower = 1e-2;
const int kLocalIterations = 3;

/// A far wish (a hitch) gets `kLocalIterations + ceil((d_wish - kLocalTrust) / kLocalTrust)` iterations, capped here.
const int kLocalIterationsMax = 8;
const int kLocalPolish = 1;

/// Weighted mm of wished displacement per iteration.
const double kLocalTrust = 6.0;

/// Rad per iteration, any member.
const double kLocalRotationCap = 0.6;
const double kLocalLambdaAbs = 1e-9;
const double kLocalAcceptResidual = 1e-6;

/// The local answer is used only within this × `max(L, distance of the hand from the frame's start pose)` (weighted) of the
/// projector's grabbed pose: on a curved mate the projector is the one that is off by a fraction of a far wish.
const double kLocalAcceptDistance = 0.5;

/// Bigger groups / systems stay on the projection (cost grows ~ rows³).
const int kLocalMaxMembers = 8;
const int kLocalMaxRows = 64;
const int kLocalModelVersion = 3;

/// Version 4 = version 3 plus an optional `pair` on a side: the second face of a Width / Symmetric mid-plane over two members. The
/// backend emits 4 only for a component that has one, so every other scene keeps version 3 (and an old client keeps projecting).
const int kLocalPairModelVersion = 4;

/// Version 5 = coupler mates (gear / rack_pinion / screw): rows on each side's MOVE from its `anchor` pose (`LocalRetractor.setAnchors`
/// replaces the anchors at every accepted anchor). Emitted by the backend only when the group holds a coupler.
const int kLocalCouplerModelVersion = 5;

/// Version 6 = limit mates (`limit_distance` / `limit_angle`): an inequality row with `min` / `max`, held at the nearest bound only while it
/// would be violated (see [LocalRetractor.retract]). Emitted by the backend only when the group holds a limit; it may also hold couplers
/// (anchors) and pairs, so it is a superset of 3 to 5.
const int kLocalLimitModelVersion = 6;

/// Active-set rounds of one retraction, and how far (mm / degrees) a value may sit outside its range before the limit counts as violated.
const int kLocalLimitRounds = 3;
const double kLocalLimitTol = 1e-6;

/// Divisor floor (mm) of the mm-scaled squared DISTANCE residuals (axis-axis, point-point): `(x² - d²) / (2 max(d, floor))`.
const double kLocalDistanceFloor = 1e-3;

const Set<String> _types = <String>{'coincident', 'concentric', 'parallel', 'angle', 'distance'};
const Set<String> _couplerTypes = <String>{'gear', 'rack_pinion', 'screw'};
const Set<String> _limitTypes = <String>{'limit_distance', 'limit_angle'};

class _Side {
  final int member;
  final Mat3? frozenR;
  final List<double>? frozenT;

  /// local geometry by name: `point`, `axis_origin`, `direction`, `perp`, `hinge_direction` (the axis an ANGLE swings about), `porigin` (plane
  /// origin), `pnormal`.
  final Map<String, List<double>> geometry;

  /// Version 4: the second face of a mid-plane (`porigin` / `pnormal` of ITS member, or the frozen pose). The side's world plane is
  /// then (the average of the two world origins, this side's normal) and the mate adds the rows "the two normals stay parallel".
  final _Side? pair;

  /// Version 5 (a coupler's member side): the pose the member had when the solve started, as exported; [LocalRetractor.setAnchors] overrides it.
  final Mat3? anchorR;
  final List<double>? anchorT;

  const _Side(this.member, this.frozenR, this.frozenT, this.geometry, [this.pair, this.anchorR, this.anchorT]);
}

class _Mate {
  final String type;
  final double? value;
  final bool allowRotation;

  /// The branch the mate stands for, +1 / -1 (absent or 0 reads as +1): the two directions point the same way / opposite ways;
  /// a DISTANCE on its -normal side; the half-turn spin of a rotation-locked CONCENTRIC.
  final double alignment;
  final double side;
  final double perp;
  final _Side a;
  final _Side b;

  /// A coupler's sense, +1 / -1 (`k`).
  final double k;

  /// A limit mate (version 6): its id (the active set's key) and its range (either bound may be absent).
  final String? limitId;
  final double? limitMin;
  final double? limitMax;

  const _Mate(this.type, this.value, this.allowRotation, this.alignment, this.side, this.perp, this.a, this.b,
      [this.k = 1.0, this.limitId, this.limitMin, this.limitMax]);
}

double _sign(Object? o) => (o is num && o < 0) ? -1.0 : 1.0;

/// A world 3-vector with its derivative (3 × n, row-major) w.r.t. the `6k` twist coordinates.
class _V {
  final List<double> v;
  final List<double> d;

  const _V(this.v, this.d);
}

class _S {
  final double v;
  final List<double> d;

  const _S(this.v, this.d);
}

List<double> _vec(Object? o) => <double>[for (final x in (o as List)) (x as num).toDouble()];

_Side _parseSide(Map<String, dynamic> j) {
  final geo = <String, List<double>>{};
  for (final name in const <String>['point', 'axis_origin', 'direction', 'perp', 'hinge_direction']) {
    if (j[name] != null) geo[name] = _vec(j[name]);
  }
  final plane = j['plane'];
  if (plane != null) {
    geo['porigin'] = _vec((plane as Map)['origin']);
    geo['pnormal'] = _vec(plane['normal']);
  }
  Mat3? fr;
  List<double>? ft;
  final frozen = j['frozen'];
  if (frozen != null) {
    final rows = (frozen as Map)['r'] as List;
    fr = Mat3(<double>[for (final row in rows) ..._vec(row)]);
    ft = _vec(frozen['t']);
  }
  _Side? pair;
  final pj = j['pair'];
  if (pj != null) {
    final pm = pj as Map<String, dynamic>;
    final pp = pm['plane'] as Map<String, dynamic>;
    pair = _Side(
      (pm['member'] as num).toInt(),
      pm['frozen'] == null ? null : Mat3(<double>[for (final row in (pm['frozen'] as Map)['r'] as List) ..._vec(row)]),
      pm['frozen'] == null ? null : _vec((pm['frozen'] as Map)['t']),
      <String, List<double>>{'porigin': _vec(pp['origin']), 'pnormal': _vec(pp['normal'])},
    );
  }
  Mat3? ar;
  List<double>? at;
  final anchor = j['anchor'];
  if (anchor != null) {
    ar = Mat3(<double>[for (final row in (anchor as Map)['r'] as List) ..._vec(row)]);
    at = _vec(anchor['t']);
  }
  return _Side((j['member'] as num).toInt(), fr, ft, geo, pair, ar, at);
}

class LocalFrameResult {
  /// The local answer was used (`false` = [poses] are the fallback / projector's).
  final bool accepted;

  /// The poses to show.
  final List<Pose> poses;

  /// The raw local answer (also when rejected).
  final List<Pose> localPoses;
  final double residualInf;
  final double fallbackDistance;

  const LocalFrameResult({
    required this.accepted,
    required this.poses,
    required this.localPoses,
    required this.residualInf,
    required this.fallbackDistance,
  });
}

class LocalRetractor {
  final int members;
  final List<String> memberIds;
  final List<_Mate> _mates;
  final int rows;

  /// The limits [retract] is holding at a bound, `{mate id: bound}`: set by the latest [retract] (reset at its start), so [residual] /
  /// [residualInf] right after it include the held rows.
  Map<String, double> _held = <String, double>{};

  /// The limits the latest [retract] held (a copy).
  Map<String, double> get heldLimits => Map<String, double>.of(_held);

  /// Whether the model holds a limit mate.
  bool get hasLimits => _mates.any((m) => _limitTypes.contains(m.type));

  /// Version 5: the pose each member had at the latest accepted anchor (the base of a coupler's rows), by member index; null = the exported ones.
  List<Pose>? _anchors;

  LocalRetractor._(this.members, this.memberIds, this._mates, this.rows);

  /// Whether the model holds a coupler mate (rows measured from anchors).
  bool get hasCoupler => _mates.any((m) => _couplerTypes.contains(m.type));

  /// Re-bases a coupler's rows on [poses] (one per member, the model's member order): call it with the members' poses of every accepted anchor.
  void setAnchors(List<Pose> poses) {
    if (poses.length == members) _anchors = List<Pose>.of(poses);
  }

  /// Parses an anchor's `constraint_model`; `null` (= keep projecting) for no model, another `version`, an unknown mate type,
  /// a side missing geometry its residual needs, or a group the local solve is not meant for (spec §4b.2).
  static LocalRetractor? tryParse(Map<String, dynamic>? json, {int maxMembers = kLocalMaxMembers}) {
    if (json == null) return null;
    try {
      final version = (json['version'] as num?)?.toInt();
      if (version != kLocalModelVersion &&
          version != kLocalPairModelVersion &&
          version != kLocalCouplerModelVersion &&
          version != kLocalLimitModelVersion) {
        return null;
      }
      final v6 = version == kLocalLimitModelVersion;
      final ids = <String>[for (final m in json['members'] as List) m as String];
      if (ids.isEmpty || ids.length > maxMembers) return null;
      final mates = <_Mate>[];
      for (final raw in json['mates'] as List) {
        final m = raw as Map<String, dynamic>;
        final type = m['type'] as String;
        final coupler = _couplerTypes.contains(type);
        final limit = _limitTypes.contains(type);
        if (!_types.contains(type) && !(coupler && (version == kLocalCouplerModelVersion || v6)) && !(limit && v6)) return null;
        if (limit && (m['id'] is! String)) return null;
        final side = _Mate(
          type,
          (m['value'] as num?)?.toDouble(),
          m['allow_rotation'] as bool? ?? true,
          _sign(m['alignment']),
          _sign(m['side']),
          _sign(m['perp']),
          _parseSide(m['a'] as Map<String, dynamic>),
          _parseSide(m['b'] as Map<String, dynamic>),
          _sign(m['k']),
          limit ? m['id'] as String : null,
          limit ? (m['min'] as num?)?.toDouble() : null,
          limit ? (m['max'] as num?)?.toDouble() : null,
        );
        if (limit && side.limitMin == null && side.limitMax == null) return null;
        if (coupler && !_couplerSidesOk(side)) return null;
        if (side.a.member >= ids.length || side.b.member >= ids.length) return null;
        if ((side.a.pair?.member ?? -1) >= ids.length || (side.b.pair?.member ?? -1) >= ids.length) return null;
        // `pair` belongs to version 4 only: a version-3 model that carries one is malformed, not "version 3 plus extras".
        if (version == kLocalModelVersion && (side.a.pair != null || side.b.pair != null)) return null;
        // `anchor` and the coupler types belong to version 5 only.
        if (version != kLocalCouplerModelVersion && !v6 && (side.a.anchorR != null || side.b.anchorR != null)) return null;
        mates.add(side);
      }
      final probe = LocalRetractor._(ids.length, ids, mates, 0);
      // A dry evaluation at identity poses: throws on a missing field, tells the row count.
      final identity = <Pose>[for (var i = 0; i < ids.length; i++) Pose(<double>[0, 0, 0], Mat3.identity())];
      final r = probe._evaluate(identity, false).$1;
      if (r.length + mates.where((m) => _limitTypes.contains(m.type)).length > kLocalMaxRows) return null;
      for (final m in mates.where((m) => _limitTypes.contains(m.type))) {
        probe._limitRow(m, identity); // throws (-> null) for a side missing the geometry the limit measures
      }
      return LocalRetractor._(ids.length, ids, mates, r.length);
    } catch (_) {
      return null;
    }
  }

  /// A coupler's two sides each need an axis (`axis_origin`, `direction`), a member side its anchor, and a positive value.
  static bool _couplerSidesOk(_Mate m) {
    if (m.value == null || m.value! <= 0) return false;
    for (final s in <_Side>[m.a, m.b]) {
      if (!s.geometry.containsKey('axis_origin') || !s.geometry.containsKey('direction')) return false;
      if (s.member >= 0 && s.anchorR == null) return false;
    }
    return true;
  }

  int get n => 6 * members;

  // ---- coupler rows (version 5, projector-spec §4b "gear, rack_pinion, screw") ---------------------------------------

  /// The side's axis in the world at its base pose (a constant).
  List<double> _baseAxis(_Side s) {
    final local = s.geometry['direction']!;
    final nn = norm3(local);
    final u = <double>[local[0] / nn, local[1] / nn, local[2] / nn];
    if (s.member >= 0) {
      final r0 = _anchors != null ? _anchors![s.member].r : s.anchorR!;
      return r0.mulVec(u);
    }
    return s.frozenR != null ? s.frozenR!.mulVec(u) : u;
  }

  /// `(turn, d turn, travel, d travel)` of a member side about / along the world unit [axis] since its anchor pose.
  (double, List<double>, double, List<double>) _motion(_Side s, List<Pose> poses, List<double> axis) {
    final zero = List<double>.filled(n, 0.0);
    final m = s.member;
    if (m < 0) return (0.0, zero, 0.0, zero);
    final Mat3 r0;
    final List<double> t0;
    if (_anchors != null) {
      r0 = _anchors![m].r;
      t0 = _anchors![m].t;
    } else {
      r0 = s.anchorR!;
      t0 = s.anchorT!;
    }
    final r = poses[m].r;
    final t = poses[m].t;
    final q = r * r0.transposed;
    // unit quaternion of q, w >= 0 (same branch as the backend)
    double w;
    List<double> v;
    final tr = q.trace;
    if (tr > 0.0) {
      final sc = math.sqrt(tr + 1.0) * 2.0;
      w = 0.25 * sc;
      v = <double>[(q.at(2, 1) - q.at(1, 2)) / sc, (q.at(0, 2) - q.at(2, 0)) / sc, (q.at(1, 0) - q.at(0, 1)) / sc];
    } else {
      var i = 0;
      if (q.at(1, 1) > q.at(i, i)) i = 1;
      if (q.at(2, 2) > q.at(i, i)) i = 2;
      final j = (i + 1) % 3, k = (i + 2) % 3;
      final sc = math.sqrt(q.at(i, i) - q.at(j, j) - q.at(k, k) + 1.0) * 2.0;
      v = <double>[0, 0, 0];
      v[i] = 0.25 * sc;
      v[j] = (q.at(j, i) + q.at(i, j)) / sc;
      v[k] = (q.at(k, i) + q.at(i, k)) / sc;
      w = (q.at(k, j) - q.at(j, k)) / sc;
    }
    if (w < 0.0) {
      w = -w;
      v = <double>[-v[0], -v[1], -v[2]];
    }
    final a = v[0] * axis[0] + v[1] * axis[1] + v[2] * axis[2];
    final vxa = cross3(v, axis);
    final den = w * w + a * a;
    final gturn = List<double>.of(zero);
    for (var i = 0; i < 3; i++) {
      gturn[6 * m + 3 + i] = (w * w * axis[i] + w * vxa[i] + a * v[i]) / den;
    }
    final p = s.geometry['axis_origin']!;
    final rp = r.mulVec(p);
    final r0p = r0.mulVec(p);
    final travel = ((rp[0] + t[0]) - (r0p[0] + t0[0])) * axis[0] +
        ((rp[1] + t[1]) - (r0p[1] + t0[1])) * axis[1] +
        ((rp[2] + t[2]) - (r0p[2] + t0[2])) * axis[2];
    final gtravel = List<double>.of(zero);
    final qxa = cross3(rp, axis);
    for (var i = 0; i < 3; i++) {
      gtravel[6 * m + i] = axis[i];
      gtravel[6 * m + 3 + i] = qxa[i];
    }
    return (2.0 * math.atan2(a, w), gturn, travel, gtravel);
  }

  /// `(value, gradient)` of a limit mate's measured value, mm for `limit_distance` (`(P_a - P_b) . N`, N = B's plane normal, else A's), degrees for
  /// `limit_angle` (the signed angle from A's direction to B's about the hinge, `atan2((a x b) . h, a . b)`); the gradient is per unit of that value.
  (double, List<double>) _limitRow(_Mate mate, List<Pose> poses) {
    final d = _geo(mate.a, poses);
    final f = _geo(mate.b, poses);
    if (mate.type == 'limit_distance') {
      _V origin(Map<String, _V> g) => g['porigin'] ?? g['point']!;
      final normal = f.containsKey('pnormal') ? f['pnormal']! : d['pnormal']!;
      final sg = _dot(_sub(origin(d), origin(f)), _unit(normal));
      return (sg.v, sg.d);
    }
    final hinge = d['hinge_direction'] ?? f['hinge_direction']!;
    final na = _unit(d['direction']!);
    final nb = _unit(f['direction']!);
    final sn = _dot(_cross(na, nb), _unit(hinge));
    final cs = _dot(na, nb);
    final den = sn.v * sn.v + cs.v * cs.v;
    final deg = 180.0 / math.pi;
    return (
      math.atan2(sn.v, cs.v) * deg,
      <double>[for (var c = 0; c < n; c++) (cs.v * sn.d[c] - sn.v * cs.d[c]) / den * deg],
    );
  }

  /// `{mate id: bound}` of the limits not yet held whose range [poses] leave.
  Map<String, double> _violated(List<Pose> poses, Map<String, double> held) {
    final out = <String, double>{};
    for (final m in _mates) {
      if (!_limitTypes.contains(m.type) || held.containsKey(m.limitId)) continue;
      final value = _limitRow(m, poses).$1;
      if (m.limitMax != null && value > m.limitMax! + kLocalLimitTol) {
        out[m.limitId!] = m.limitMax!;
      } else if (m.limitMin != null && value < m.limitMin! - kLocalLimitTol) {
        out[m.limitId!] = m.limitMin!;
      }
    }
    return out;
  }

  /// The one row of a coupler mate: `(value, gradient)`.
  (double, List<double>) _couplerRow(_Mate mate, List<Pose> poses) {
    final axisA = _baseAxis(mate.a);
    final value = mate.value!;
    List<double> lin(List<double> x, double ca, List<double> y) => <double>[for (var i = 0; i < n; i++) x[i] - ca * y[i]];
    switch (mate.type) {
      case 'gear':
        final a = _motion(mate.a, poses, axisA);
        final b = _motion(mate.b, poses, _baseAxis(mate.b));
        return (b.$1 - mate.k * value * a.$1, lin(b.$2, mate.k * value, a.$2));
      case 'rack_pinion':
        final a = _motion(mate.a, poses, axisA);
        final b = _motion(mate.b, poses, _baseAxis(mate.b));
        final c = mate.k * value / (2.0 * math.pi);
        return (b.$3 - c * a.$1, lin(b.$4, c, a.$2));
      default: // screw: everything about / along the screw's (A's) axis
        final a = _motion(mate.a, poses, axisA);
        final b = _motion(mate.b, poses, axisA);
        final c = mate.k * value / (2.0 * math.pi);
        final grad = <double>[for (var i = 0; i < n; i++) (b.$4[i] - a.$4[i]) - c * (b.$2[i] - a.$2[i])];
        return ((b.$3 - a.$3) - c * (b.$1 - a.$1), grad);
    }
  }

  // ---- residual + analytic Jacobian ---------------------------------------------------------------------------------

  _V _world(_Side s, List<Pose> poses, String name, bool point) {
    final local = s.geometry[name]!;
    final d = List<double>.filled(3 * n, 0.0);
    final Mat3 r;
    final List<double> t;
    final m = s.member;
    if (m < 0) {
      if (s.frozenR == null) return _V(List<double>.of(local), d);
      r = s.frozenR!;
      t = s.frozenT!;
    } else {
      r = poses[m].r;
      t = poses[m].t;
    }
    final w = r.mulVec(local);
    final v = point ? <double>[w[0] + t[0], w[1] + t[1], w[2] + t[2]] : w;
    if (m >= 0) {
      final c0 = 6 * m;
      if (point) {
        d[0 * n + c0] = 1;
        d[1 * n + c0 + 1] = 1;
        d[2 * n + c0 + 2] = 1;
      }
      // -skew(w)
      d[0 * n + c0 + 4] = w[2];
      d[0 * n + c0 + 5] = -w[1];
      d[1 * n + c0 + 3] = -w[2];
      d[1 * n + c0 + 5] = w[0];
      d[2 * n + c0 + 3] = w[1];
      d[2 * n + c0 + 4] = -w[0];
    }
    return _V(v, d);
  }

  Map<String, _V> _geo(_Side s, List<Pose> poses) {
    final g = <String, _V>{};
    for (final name in s.geometry.keys) {
      final point = name == 'point' || name == 'axis_origin' || name == 'porigin';
      g[name] = _world(s, poses, name, point);
    }
    final pair = s.pair;
    if (pair != null && g.containsKey('porigin')) {
      // Version 4: the plane midway between this face and the pair's (origin = average, normal = this face's).
      final other = _world(pair, poses, 'porigin', true);
      final o = g['porigin']!;
      final mid = _V(
        <double>[(o.v[0] + other.v[0]) / 2, (o.v[1] + other.v[1]) / 2, (o.v[2] + other.v[2]) / 2],
        List<double>.generate(3 * n, (i) => (o.d[i] + other.d[i]) / 2),
      );
      g['porigin'] = mid;
      if (g.containsKey('point')) g['point'] = mid;
      g['pair_normal'] = _world(pair, poses, 'pnormal', false);
    }
    return g;
  }

  _V _sub(_V a, _V b) => _V(
        <double>[a.v[0] - b.v[0], a.v[1] - b.v[1], a.v[2] - b.v[2]],
        List<double>.generate(3 * n, (i) => a.d[i] - b.d[i]),
      );

  _S _dot(_V a, _V b) {
    final d = List<double>.filled(n, 0.0);
    for (var c = 0; c < n; c++) {
      var s = 0.0;
      for (var i = 0; i < 3; i++) {
        s += a.d[i * n + c] * b.v[i] + b.d[i * n + c] * a.v[i];
      }
      d[c] = s;
    }
    return _S(a.v[0] * b.v[0] + a.v[1] * b.v[1] + a.v[2] * b.v[2], d);
  }

  _V _cross(_V a, _V b) {
    final d = List<double>.filled(3 * n, 0.0);
    for (var c = 0; c < n; c++) {
      final da = <double>[a.d[c], a.d[n + c], a.d[2 * n + c]];
      final db = <double>[b.d[c], b.d[n + c], b.d[2 * n + c]];
      final t1 = cross3(da, b.v);
      final t2 = cross3(a.v, db);
      for (var i = 0; i < 3; i++) {
        d[i * n + c] = t1[i] + t2[i];
      }
    }
    return _V(cross3(a.v, b.v), d);
  }

  _V _scale(_V a, double c) => _V(<double>[a.v[0] * c, a.v[1] * c, a.v[2] * c], <double>[for (final x in a.d) x * c]);

  _V _unit(_V a) {
    final nn = norm3(a.v);
    final u = <double>[a.v[0] / nn, a.v[1] / nn, a.v[2] / nn];
    final d = List<double>.filled(3 * n, 0.0);
    for (var c = 0; c < n; c++) {
      final dc = <double>[a.d[c], a.d[n + c], a.d[2 * n + c]];
      final p = u[0] * dc[0] + u[1] * dc[1] + u[2] * dc[2];
      for (var i = 0; i < 3; i++) {
        d[i * n + c] = (dc[i] - u[i] * p) / nn;
      }
    }
    return _V(u, d);
  }

  /// `(r, J)` at [poses]; `J` rows are empty lists when [withJacobian] is false.
  (List<double>, List<List<double>>) _evaluate(List<Pose> poses, bool withJacobian) {
    final rows = <double>[];
    final jac = <List<double>>[];
    void add(double v, List<double> d) {
      rows.add(v);
      jac.add(d);
    }

    void addV(_V x) {
      for (var i = 0; i < 3; i++) {
        add(x.v[i], x.d.sublist(i * n, (i + 1) * n));
      }
    }

    // `a - s b`: zero only when `a` points the way `s b` does (the alignment branch).
    void directionRows(_V a, _V b, double s) => addV(_sub(a, _scale(b, s)));

    // A signed separation against its target on the chosen side, `sep - side * d` (linear: one Newton step from either side).
    void addSigned(_S sg, double target) => add(sg.v - target, sg.d);

    // A squared form scaled to mm, `(x² - d²) / (2 max(d, floor))`.
    void addScaled(_S sq, double dist) {
      final scale = 2.0 * math.max(dist, kLocalDistanceFloor);
      add((sq.v - dist * dist) / scale, <double>[for (final x in sq.d) x / scale]);
    }

    for (final mate in _mates) {
      if (_limitTypes.contains(mate.type)) {
        final bound = _held[mate.limitId];
        if (bound != null) {
          final (value, gradient) = _limitRow(mate, poses);
          final unit = mate.type == 'limit_angle' ? math.pi / 180.0 : 1.0;
          add((value - bound) * unit, <double>[for (final x in gradient) x * unit]);
        }
        continue;
      }
      if (_couplerTypes.contains(mate.type)) {
        final (value, gradient) = _couplerRow(mate, poses);
        add(value, gradient);
        continue;
      }
      final d = _geo(mate.a, poses);
      final f = _geo(mate.b, poses);
      final s = mate.alignment;
      switch (mate.type) {
        case 'coincident':
          if (d.containsKey('porigin') && f.containsKey('porigin')) {
            final sg = _dot(_sub(d['porigin']!, f['porigin']!), f['pnormal']!);
            add(sg.v, sg.d);
            directionRows(d['pnormal']!, f['pnormal']!, s);
          } else if (d.containsKey('porigin')) {
            final sg = _dot(_sub(f['point']!, d['porigin']!), d['pnormal']!);
            add(sg.v, sg.d);
          } else if (f.containsKey('porigin')) {
            final sg = _dot(_sub(d['point']!, f['porigin']!), f['pnormal']!);
            add(sg.v, sg.d);
          } else {
            addV(_sub(d['point']!, f['point']!));
          }
        case 'concentric':
          directionRows(d['direction']!, f['direction']!, s);
          addV(_cross(_sub(d['axis_origin']!, f['axis_origin']!), f['direction']!));
          if (!mate.allowRotation && d.containsKey('perp') && f.containsKey('perp')) {
            directionRows(d['perp']!, f['perp']!, mate.perp);
          }
        case 'parallel':
          directionRows(d['direction']!, f['direction']!, s);
        case 'angle':
          var target = mate.value!.abs() % 360.0;
          target = math.min(target, 360.0 - target);
          final nd = _unit(d['direction']!);
          final nf = _unit(f['direction']!);
          final dd = _dot(nd, nf);
          add(dd.v - math.cos(target * math.pi / 180.0), dd.d);
          final hinge = d['hinge_direction'] ?? f['hinge_direction'];
          if (hinge != null && math.sin(target * math.pi / 180.0) >= 1e-6) {
            // About a hinge: the sine of the signed swing is +-sin(target) (`alignment`) - zero only on the named way.
            final sw = _dot(_cross(nd, nf), _unit(hinge));
            add(sw.v - s * math.sin(target * math.pi / 180.0), sw.d);
          }
        case 'distance':
          final dist = mate.value!.abs();
          final signedTarget = mate.side * dist;
          if (d.containsKey('porigin') && f.containsKey('porigin')) {
            addSigned(_dot(_sub(d['porigin']!, f['porigin']!), f['pnormal']!), signedTarget);
            directionRows(d['pnormal']!, f['pnormal']!, s);
          } else if (d.containsKey('porigin')) {
            addSigned(_dot(_sub(f['point']!, d['porigin']!), d['pnormal']!), signedTarget);
          } else if (f.containsKey('porigin')) {
            addSigned(_dot(_sub(d['point']!, f['porigin']!), f['pnormal']!), signedTarget);
          } else if (d.containsKey('axis_origin') && f.containsKey('axis_origin')) {
            final p = _cross(_sub(d['axis_origin']!, f['axis_origin']!), f['direction']!);
            addScaled(_dot(p, p), dist);
            directionRows(d['direction']!, f['direction']!, s);
          } else {
            final off = _sub(d['point']!, f['point']!);
            addScaled(_dot(off, off), dist);
          }
      }
      for (final g in <Map<String, _V>>[d, f]) {
        // A pair's two faces stay parallel: the cross product of their unit normals (3 rows, rank 2).
        if (g.containsKey('pair_normal')) addV(_cross(_unit(g['pnormal']!), _unit(g['pair_normal']!)));
      }
    }
    return (rows, jac);
  }

  /// Stacked mate residual at [poses].
  List<double> residual(List<Pose> poses) => _evaluate(poses, false).$1;

  double residualInf(List<Pose> poses) {
    var m = 0.0;
    for (final x in residual(poses)) {
      m = math.max(m, x.abs());
    }
    return m;
  }

  /// Analytic Jacobian rows (`rows` × `6·members`), same chart as the basis.
  List<List<double>> jacobian(List<Pose> poses) => _evaluate(poses, true).$2;

  // ---- retraction ------------------------------------------------------------------------------------------------

  List<Pose> _step(List<Pose> cur, List<double> dx) =>
      <Pose>[for (var i = 0; i < members; i++) applyDelta(cur[i], dx, 6 * i)];

  List<double> _capRotation(List<double> dx) {
    var rot = 0.0;
    for (var i = 0; i < members; i++) {
      rot = math.max(rot, norm3(<double>[dx[6 * i + 3], dx[6 * i + 4], dx[6 * i + 5]]));
    }
    if (rot <= kLocalRotationCap) return dx;
    final f = kLocalRotationCap / rot;
    return <double>[for (final x in dx) x * f];
  }

  /// `Aᵀ (A·Aᵀ + λ I)⁻¹ rhs` with `A = J / w` (`n`-vector).
  List<double> _correction(List<List<double>> a, List<double> rhs) {
    final m = a.length;
    final mat = List<Float64List>.generate(m, (_) => Float64List(m));
    for (var i = 0; i < m; i++) {
      for (var j = i; j < m; j++) {
        var s = 0.0;
        final ai = a[i], aj = a[j];
        for (var c = 0; c < n; c++) {
          s += ai[c] * aj[c];
        }
        mat[i][j] = s;
        mat[j][i] = s;
      }
      mat[i][i] += kLocalLambdaAbs;
    }
    final z = _solve(mat, Float64List.fromList(rhs));
    final out = List<double>.filled(n, 0.0);
    for (var i = 0; i < m; i++) {
      final ai = a[i];
      final zi = z[i];
      for (var c = 0; c < n; c++) {
        out[c] += ai[c] * zi;
      }
    }
    return out;
  }

  /// Sequential nearest-point retraction (spec §4b): `kLocalIterations` trust-region steps towards [wishes] then
  /// [polish] constraint-only steps. [w] = per-coordinate metric (see [localScale]).
  ///
  /// With limit mates (version 6) it is the active-set rounds: retract with none held, hold every limit the answer leaves at its nearest bound
  /// (an equality row) and retract again from the SAME start and wish, at most [kLocalLimitRounds] times. Nothing is carried to the next call
  /// (a limit is released the moment the wish no longer pushes past it); [heldLimits] says which were held.
  List<Pose> retract(List<Pose> poses, List<Pose> wishes, List<double> w,
      {int iterations = kLocalIterations, int polish = kLocalPolish}) {
    _held = <String, double>{};
    var got = _retractOnce(poses, wishes, w, iterations, polish);
    if (!hasLimits) return got;
    for (var round = 0; round < kLocalLimitRounds; round++) {
      final violated = _violated(got, _held);
      if (violated.isEmpty) break;
      _held = <String, double>{..._held, ...violated};
      got = _retractOnce(poses, wishes, w, iterations, polish);
    }
    return got;
  }

  List<Pose> _retractOnce(List<Pose> poses, List<Pose> wishes, List<double> w, int iterations, int polish) {
    var cur = List<Pose>.of(poses);
    for (var it = 0; it < iterations; it++) {
      final (r, jac) = _evaluate(cur, true);
      final g = <double>[];
      for (var i = 0; i < members; i++) {
        g.addAll(poseDelta(wishes[i], cur[i]));
      }
      final a = <List<double>>[
        for (final row in jac) <double>[for (var c = 0; c < n; c++) row[c] / w[c]],
      ];
      var y0 = <double>[for (var c = 0; c < n; c++) w[c] * g[c]];
      var n0 = 0.0;
      for (final x in y0) {
        n0 += x * x;
      }
      n0 = math.sqrt(n0);
      if (n0 > kLocalTrust) {
        final f = kLocalTrust / n0;
        y0 = <double>[for (final x in y0) x * f];
      }
      List<double> y;
      if (r.isNotEmpty) {
        final rhs = <double>[
          for (var i = 0; i < a.length; i++) _dotv(a[i], y0) + r[i],
        ];
        final corr = _correction(a, rhs);
        y = <double>[for (var c = 0; c < n; c++) y0[c] - corr[c]];
      } else {
        y = y0;
      }
      cur = _step(cur, _capRotation(<double>[for (var c = 0; c < n; c++) y[c] / w[c]]));
    }
    for (var it = 0; it < polish; it++) {
      final (r, jac) = _evaluate(cur, true);
      if (r.isEmpty) break;
      var big = 0.0;
      for (final x in r) {
        big = math.max(big, x.abs());
      }
      if (big < 1e-12) break;
      final a = <List<double>>[
        for (final row in jac) <double>[for (var c = 0; c < n; c++) row[c] / w[c]],
      ];
      final corr = _correction(a, r);
      cur = _step(cur, _capRotation(<double>[for (var c = 0; c < n; c++) -corr[c] / w[c]]));
    }
    return cur;
  }

  /// One frame: retract from [poses] (the previous displayed poses) towards [wishes] (grabbed: the hand; followers:
  /// their previous displayed poses) in the local metric, accept only a converged result within
  /// `kLocalAcceptDistance · max(lever, wish distance)` of the projector's grabbed pose ([fallback] = the projector's poses for the same wish).
  LocalFrameResult frame({
    required List<Pose> poses,
    required List<Pose> wishes,
    required List<Pose> fallback,
    required double lever,
  }) {
    final w = localScale(members, lever);
    final wishStep = weightedDist(wishes[0], poses[0], lever);
    final got = retract(poses, wishes, w, iterations: localIterations(wishStep));
    final res = residualInf(got);
    final dist = weightedDist(got[0], fallback[0], lever);
    // A held limit is a stop the projector (the fallback) knows nothing of - it would show the part going on through it - so the distance guard
    // cannot judge the answer: a converged result with a limit held is accepted as it is.
    final ok = res <= kLocalAcceptResidual && (_held.isNotEmpty || dist <= kLocalAcceptDistance * math.max(lever, wishStep));
    return LocalFrameResult(
      accepted: ok,
      poses: ok ? got : fallback,
      localPoses: got,
      residualInf: res,
      fallbackDistance: dist,
    );
  }
}

/// Iterations for one frame whose hand wish is [wishStep] (weighted mm) from the start pose: the base count, plus one per
/// [kLocalTrust] beyond the first, capped at [kLocalIterationsMax].
int localIterations(double wishStep) =>
    math.min(kLocalIterationsMax, math.max(kLocalIterations, kLocalIterations + ((wishStep - kLocalTrust) / kLocalTrust).ceil()));

/// The local metric: grabbed `[1,1,1,L,L,L]`, followers × [kLocalFollower]; the grabbed member is index 0.
List<double> localScale(int members, double lever) => memberScale(members, lever, follower: kLocalFollower);

double _dotv(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    s += a[i] * b[i];
  }
  return s;
}

/// Gaussian elimination with partial pivoting (destroys [m]); `m` is symmetric positive (semi-)definite plus damping.
Float64List _solve(List<Float64List> m, Float64List b) {
  final k = b.length;
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
      final tb = b[col];
      b[col] = b[piv];
      b[piv] = tb;
    }
    final d = m[col][col];
    for (var r = col + 1; r < k; r++) {
      final f = m[r][col] / d;
      if (f == 0) continue;
      for (var c = col; c < k; c++) {
        m[r][c] -= f * m[col][c];
      }
      b[r] -= f * b[col];
    }
  }
  final x = Float64List(k);
  for (var r = k - 1; r >= 0; r--) {
    var s = b[r];
    for (var c = r + 1; c < k; c++) {
      s -= m[r][c] * x[c];
    }
    x[r] = s / m[r][r];
  }
  return x;
}
