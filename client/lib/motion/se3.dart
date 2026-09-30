/// SE(3) chart for the free-motion projector (`docs/motion/projector-spec.md`
/// §2 and §5). Pure Dart - no Flutter, no `dart:ui`, no `vector_math` - so the
/// same code runs in `flutter test` against `docs/motion/vectors.json`.
///
/// Conventions (the backend's `apply_delta` chart): a pose is `(t, R)`; a
/// twist `[vx vy vz wx wy wz]` has `v` = displacement of the occurrence ORIGIN
/// and `w` = a rotation vector (rad) composed on the left, `R' = exp(w)·R`.
library;

import 'dart:math' as math;

/// Below this rotation angle (rad) the Rodrigues/screw coefficients use their
/// Taylor series so nothing divides by ~0 (spec §5).
const double kSeriesSwitch = 1e-4;

/// Below this angle (rad) [screwLog]'s `V⁻¹` coefficient uses its Taylor series.
const double kLogSeriesSwitch = 1e-2;

/// Within this of π the rotation-vector axis is taken from `(R + I)/2`.
const double kNearPi = 1e-3;

/// A 3×3 matrix, row-major.
class Mat3 {
  final List<double> m; // length 9

  const Mat3(this.m);

  static Mat3 identity() => Mat3(<double>[1, 0, 0, 0, 1, 0, 0, 0, 1]);

  double at(int r, int c) => m[r * 3 + c];

  Mat3 operator *(Mat3 o) {
    final out = List<double>.filled(9, 0);
    for (var r = 0; r < 3; r++) {
      for (var c = 0; c < 3; c++) {
        out[r * 3 + c] = m[r * 3] * o.m[c] + m[r * 3 + 1] * o.m[3 + c] + m[r * 3 + 2] * o.m[6 + c];
      }
    }
    return Mat3(out);
  }

  Mat3 operator +(Mat3 o) => Mat3(List<double>.generate(9, (i) => m[i] + o.m[i]));

  Mat3 scaled(double s) => Mat3(List<double>.generate(9, (i) => m[i] * s));

  Mat3 get transposed => Mat3(<double>[m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]]);

  double get trace => m[0] + m[4] + m[8];

  List<double> mulVec(List<double> v) => <double>[
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
      ];
}

List<double> cross3(List<double> a, List<double> b) =>
    <double>[a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];

double norm3(List<double> a) => math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);

/// Cross-product matrix: `skew(w) · x == w × x`.
Mat3 skew(List<double> w) => Mat3(<double>[0, -w[2], w[1], w[2], 0, -w[0], -w[1], w[0], 0]);

/// Rodrigues: `exp(skew(w))`.
Mat3 rotFromRotvec(List<double> w) {
  final th = norm3(w);
  final k = skew(w);
  final double a, b;
  if (th < kSeriesSwitch) {
    a = 1.0 - th * th / 6.0;
    b = 0.5 - th * th / 24.0;
  } else {
    a = math.sin(th) / th;
    b = (1.0 - math.cos(th)) / (th * th);
  }
  return Mat3.identity() + k.scaled(a) + (k * k).scaled(b);
}

/// Inverse of [rotFromRotvec] (angles in [0, π]); atan2-based so it is exact
/// at small angles, axis from the symmetric part near π (spec §5).
List<double> rotvecFromRot(Mat3 r) {
  final v = <double>[
    (r.at(2, 1) - r.at(1, 2)) / 2.0,
    (r.at(0, 2) - r.at(2, 0)) / 2.0,
    (r.at(1, 0) - r.at(0, 1)) / 2.0,
  ];
  final s = norm3(v);
  final c = (r.trace - 1.0) / 2.0;
  final th = math.atan2(s, c);
  if (th < kSeriesSwitch) {
    final f = 1.0 + th * th / 6.0;
    return <double>[v[0] * f, v[1] * f, v[2] * f];
  }
  if (math.pi - th < kNearPi) {
    // sin(th) ~ 0: (R + I)/2 = a·aᵀ; take the column of the largest diagonal entry, sign from v.
    final d = <double>[(r.at(0, 0) + 1) / 2, (r.at(1, 1) + 1) / 2, (r.at(2, 2) + 1) / 2];
    var j = 0;
    if (d[1] > d[j]) j = 1;
    if (d[2] > d[j]) j = 2;
    final a = <double>[
      ((r.at(0, j) + (j == 0 ? 1 : 0)) / 2),
      ((r.at(1, j) + (j == 1 ? 1 : 0)) / 2),
      ((r.at(2, j) + (j == 2 ? 1 : 0)) / 2),
    ];
    final an = norm3(a);
    final u = <double>[a[0] / an, a[1] / an, a[2] / an];
    final sign = (u[0] * v[0] + u[1] * v[1] + u[2] * v[2]) >= 0.0 ? 1.0 : -1.0;
    return <double>[u[0] * th * sign, u[1] * th * sign, u[2] * th * sign];
  }
  final f = th / s;
  return <double>[v[0] * f, v[1] * f, v[2] * f];
}

/// Rotation about [axis] (normalised here; zero axis or zero angle = identity)
/// by [degrees] - the wire `rotation_axis` + `rotation_angle_degrees`.
Mat3 rotAxisAngle(List<double> axis, double degrees) {
  final n = norm3(axis);
  if (n < 1e-12 || degrees.abs() < 1e-15) return Mat3.identity();
  final rad = degrees * math.pi / 180.0;
  return rotFromRotvec(<double>[axis[0] / n * rad, axis[1] / n * rad, axis[2] / n * rad]);
}

/// A rigid pose: translation [t] and rotation [r].
class Pose {
  final List<double> t; // length 3
  final Mat3 r;

  const Pose(this.t, this.r);

  /// From the wire form (`translation`, `rotation_axis`, `rotation_angle_degrees`).
  factory Pose.fromWire({
    required List<double> translation,
    required List<double> rotationAxis,
    required double rotationAngleDegrees,
  }) =>
      Pose(List<double>.of(translation), rotAxisAngle(rotationAxis, rotationAngleDegrees));

  /// Wire form: `(translation, axis, degrees)`; identity rotation reports axis `[0, 0, 1]`.
  ({List<double> translation, List<double> axis, double degrees}) toWire() {
    final v = rotvecFromRot(r);
    final th = norm3(v);
    final axis = th > 1e-12 ? <double>[v[0] / th, v[1] / th, v[2] / th] : <double>[0, 0, 1];
    return (translation: List<double>.of(t), axis: axis, degrees: th * 180.0 / math.pi);
  }
}

/// `[t_new − t_old, rotvec(R_new·R_oldᵀ)]` - the inverse of [applyDelta].
List<double> poseDelta(Pose newer, Pose older) {
  final w = rotvecFromRot(newer.r * older.r.transposed);
  return <double>[
    newer.t[0] - older.t[0],
    newer.t[1] - older.t[1],
    newer.t[2] - older.t[2],
    w[0],
    w[1],
    w[2],
  ];
}

/// `(t + v, exp(w)·R)` - the additive integration the backend's chart defines.
Pose applyDelta(Pose base, List<double> d, [int offset = 0]) => Pose(
      <double>[base.t[0] + d[offset], base.t[1] + d[offset + 1], base.t[2] + d[offset + 2]],
      rotFromRotvec(<double>[d[offset + 3], d[offset + 4], d[offset + 5]]) * base.r,
    );

/// Integrates the twist `d[offset..offset+6]` as a constant spatial screw
/// (spec §5): `R' = E·R`, `t' = E·t + V·(v − w × t)`. Exact for group orbits.
Pose screwExp(Pose base, List<double> d, [int offset = 0]) {
  final v = <double>[d[offset], d[offset + 1], d[offset + 2]];
  final w = <double>[d[offset + 3], d[offset + 4], d[offset + 5]];
  final th = norm3(w);
  final k = skew(w);
  final double a, b;
  if (th < kSeriesSwitch) {
    a = 0.5 - th * th / 24.0;
    b = 1.0 / 6.0 - th * th / 120.0;
  } else {
    a = (1.0 - math.cos(th)) / (th * th);
    b = (th - math.sin(th)) / (th * th * th);
  }
  final vm = Mat3.identity() + k.scaled(a) + (k * k).scaled(b);
  final e = rotFromRotvec(w);
  final wxt = cross3(w, base.t);
  final et = e.mulVec(base.t);
  final vt = vm.mulVec(<double>[v[0] - wxt[0], v[1] - wxt[1], v[2] - wxt[2]]);
  return Pose(<double>[et[0] + vt[0], et[1] + vt[1], et[2] + vt[2]], e * base.r);
}

/// `V(w)⁻¹ = I − K/2 + c·K²`, `c = (1 − θ sinθ / (2(1 − cosθ))) / θ²` (series below θ < 1e-2, where the
/// closed form cancels: `1/12 + θ²/720 + θ⁴/30240`). Inverse of the `V` in [screwExp].
Mat3 _vInverse(List<double> w) {
  final th = norm3(w);
  final k = skew(w);
  final double c;
  if (th < kLogSeriesSwitch) {
    c = 1.0 / 12.0 + th * th / 720.0 + th * th * th * th / 30240.0;
  } else {
    c = (1.0 - th * math.sin(th) / (2.0 * (1.0 - math.cos(th)))) / (th * th);
  }
  return Mat3.identity() + k.scaled(-0.5) + (k * k).scaled(c);
}

/// The twist `d = [v, w]` with `screwExp(base, d) == target` - the exact inverse of [screwExp] (spec §4):
/// `w = rotvec(R_T·R_Bᵀ)`, `u = V(w)⁻¹ (t_T − exp(w)·t_B)`, `v = u + w × t_B`.
List<double> screwLog(Pose base, Pose target) {
  final w = rotvecFromRot(target.r * base.r.transposed);
  final e = rotFromRotvec(w);
  final et = e.mulVec(base.t);
  final u = _vInverse(w).mulVec(<double>[target.t[0] - et[0], target.t[1] - et[1], target.t[2] - et[2]]);
  final wxt = cross3(w, base.t);
  return <double>[u[0] + wxt[0], u[1] + wxt[1], u[2] + wxt[2], w[0], w[1], w[2]];
}

/// `‖[1,1,1,L,L,L] ∘ log(a, b)‖` - the weighted distance between two poses (spec §7, §6 `travel`).
double weightedDist(Pose a, Pose b, double lever) {
  final d = poseDelta(a, b);
  final x = d[0], y = d[1], z = d[2];
  final p = d[3] * lever, q = d[4] * lever, r = d[5] * lever;
  return math.sqrt(x * x + y * y + z * z + p * p + q * q + r * r);
}
