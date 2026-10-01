/// Local nearest-point retraction (`docs/motion/projector-spec.md` §4b, F1b): the client evaluates the mates itself every
/// frame from the anchor's `constraint_model` and lands the displayed poses ON the mate manifold at the weighted-nearest
/// point to the hand's wish, instead of moving along the linearised free motion and being popped back at the next anchor.
///
/// Pure Dart (no Flutter): residuals of the five mate types with analytic forward-mode Jacobians (the same residuals as the
/// backend's `_mate_residual_vector`), a fixed-iteration trust-region sequential nearest-point solve, and the acceptance
/// guard that makes it "never worse than the projection". Reproduces the `local_retract` golden vectors to 1e-9.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'se3.dart';
import 'weighted_basis.dart' show memberScale;

/// Follower weight of the LOCAL solve (the projection metric keeps `kFollowerWeight` = 1e-4, which squares to 1e8 in `A·Aᵀ`).
const double kLocalFollower = 1e-2;
const int kLocalIterations = 3;
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
const int kLocalModelVersion = 1;

const Set<String> _types = <String>{'coincident', 'concentric', 'parallel', 'angle', 'distance'};

class _Side {
  final int member;
  final Mat3? frozenR;
  final List<double>? frozenT;

  /// local geometry by name: `point`, `axis_origin`, `direction`, `perp`, `porigin` (plane origin), `pnormal`.
  final Map<String, List<double>> geometry;

  const _Side(this.member, this.frozenR, this.frozenT, this.geometry);
}

class _Mate {
  final String type;
  final double? value;
  final bool allowRotation;
  final _Side a;
  final _Side b;

  const _Mate(this.type, this.value, this.allowRotation, this.a, this.b);
}

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
  for (final name in const <String>['point', 'axis_origin', 'direction', 'perp']) {
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
  return _Side((j['member'] as num).toInt(), fr, ft, geo);
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

  LocalRetractor._(this.members, this.memberIds, this._mates, this.rows);

  /// Parses an anchor's `constraint_model`; `null` (= keep projecting) for no model, another `version`, an unknown mate type,
  /// a side missing geometry its residual needs, or a group the local solve is not meant for (spec §4b.2).
  static LocalRetractor? tryParse(Map<String, dynamic>? json, {int maxMembers = kLocalMaxMembers}) {
    if (json == null) return null;
    try {
      if ((json['version'] as num?)?.toInt() != kLocalModelVersion) return null;
      final ids = <String>[for (final m in json['members'] as List) m as String];
      if (ids.isEmpty || ids.length > maxMembers) return null;
      final mates = <_Mate>[];
      for (final raw in json['mates'] as List) {
        final m = raw as Map<String, dynamic>;
        final type = m['type'] as String;
        if (!_types.contains(type)) return null;
        final side = _Mate(
          type,
          (m['value'] as num?)?.toDouble(),
          m['allow_rotation'] as bool? ?? true,
          _parseSide(m['a'] as Map<String, dynamic>),
          _parseSide(m['b'] as Map<String, dynamic>),
        );
        if (side.a.member >= ids.length || side.b.member >= ids.length) return null;
        mates.add(side);
      }
      final probe = LocalRetractor._(ids.length, ids, mates, 0);
      // A dry evaluation at identity poses: throws on a missing field, tells the row count.
      final identity = <Pose>[for (var i = 0; i < ids.length; i++) Pose(<double>[0, 0, 0], Mat3.identity())];
      final r = probe._evaluate(identity, false).$1;
      if (r.length > kLocalMaxRows) return null;
      return LocalRetractor._(ids.length, ids, mates, r.length);
    } catch (_) {
      return null;
    }
  }

  int get n => 6 * members;

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

    void addSquared(_S sg, double tsq) => add(sg.v * sg.v - tsq, <double>[for (final x in sg.d) 2 * sg.v * x]);

    for (final mate in _mates) {
      final d = _geo(mate.a, poses);
      final f = _geo(mate.b, poses);
      switch (mate.type) {
        case 'coincident':
          if (d.containsKey('porigin') && f.containsKey('porigin')) {
            final s = _dot(_sub(d['porigin']!, f['porigin']!), f['pnormal']!);
            add(s.v, s.d);
            addV(_cross(d['pnormal']!, f['pnormal']!));
          } else if (d.containsKey('porigin')) {
            final s = _dot(_sub(f['point']!, d['porigin']!), d['pnormal']!);
            add(s.v, s.d);
          } else if (f.containsKey('porigin')) {
            final s = _dot(_sub(d['point']!, f['porigin']!), f['pnormal']!);
            add(s.v, s.d);
          } else {
            addV(_sub(d['point']!, f['point']!));
          }
        case 'concentric':
          addV(_cross(d['direction']!, f['direction']!));
          addV(_cross(_sub(d['axis_origin']!, f['axis_origin']!), f['direction']!));
          if (!mate.allowRotation && d.containsKey('perp') && f.containsKey('perp')) {
            addV(_cross(d['perp']!, f['perp']!));
          }
        case 'parallel':
          addV(_cross(d['direction']!, f['direction']!));
        case 'angle':
          var target = mate.value!.abs() % 360.0;
          target = math.min(target, 360.0 - target);
          final dd = _dot(_unit(d['direction']!), _unit(f['direction']!));
          add(dd.v - math.cos(target * math.pi / 180.0), dd.d);
        case 'distance':
          final tsq = mate.value! * mate.value!;
          if (d.containsKey('porigin') && f.containsKey('porigin')) {
            addSquared(_dot(_sub(d['porigin']!, f['porigin']!), f['pnormal']!), tsq);
            addV(_cross(d['pnormal']!, f['pnormal']!));
          } else if (d.containsKey('porigin')) {
            addSquared(_dot(_sub(f['point']!, d['porigin']!), d['pnormal']!), tsq);
          } else if (f.containsKey('porigin')) {
            addSquared(_dot(_sub(d['point']!, f['porigin']!), f['pnormal']!), tsq);
          } else if (d.containsKey('axis_origin') && f.containsKey('axis_origin')) {
            final p = _cross(_sub(d['axis_origin']!, f['axis_origin']!), f['direction']!);
            final pp = _dot(p, p);
            add(pp.v - tsq, pp.d);
            addV(_cross(d['direction']!, f['direction']!));
          } else {
            final off = _sub(d['point']!, f['point']!);
            final oo = _dot(off, off);
            add(oo.v - tsq, oo.d);
          }
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
  List<Pose> retract(List<Pose> poses, List<Pose> wishes, List<double> w,
      {int iterations = kLocalIterations, int polish = kLocalPolish}) {
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
    final got = retract(poses, wishes, w);
    final res = residualInf(got);
    final dist = weightedDist(got[0], fallback[0], lever);
    final wishStep = weightedDist(wishes[0], poses[0], lever);
    final ok = res <= kLocalAcceptResidual && dist <= kLocalAcceptDistance * math.max(lever, wishStep);
    return LocalFrameResult(
      accepted: ok,
      poses: ok ? got : fallback,
      localPoses: got,
      residualInf: res,
      fallbackDistance: dist,
    );
  }
}

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
