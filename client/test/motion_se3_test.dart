import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/motion/se3.dart';

void _near(List<double> a, List<double> b, double tol, [String? why]) {
  for (var i = 0; i < a.length; i++) {
    expect((a[i] - b[i]).abs(), lessThan(tol), reason: '${why ?? ''}[$i] ${a[i]} vs ${b[i]}');
  }
}

void main() {
  group('rotation vector', () {
    test('round trips at tiny, ordinary and near-π angles', () {
      for (final mag in const [1e-9, 1e-7, 1e-5, 0.1, 1.0, 3.0, math.pi - 5e-4, math.pi - 1e-7]) {
        for (final axis in const [
          [1.0, 0.0, 0.0],
          [0.0, 1.0, 0.0],
          [0.0, 0.0, 1.0],
          [0.48, -0.6, 0.64],
          [-0.36, 0.48, -0.8],
        ]) {
          final w = <double>[axis[0] * mag, axis[1] * mag, axis[2] * mag];
          final back = rotvecFromRot(rotFromRotvec(w));
          // Spec §5 near π (π − θ < 1e-3) takes the axis from (R + I)/2, exact only AT π: the error is O(π − θ).
          final band = math.pi - mag < 1e-3 ? 1.5 * (math.pi - mag) : 0.0;
          _near(back, w, 1e-9 * math.max(1.0, mag) + band, 'mag=$mag axis=$axis');
        }
      }
    });

    test('identity gives a zero vector', () {
      _near(rotvecFromRot(Mat3.identity()), [0, 0, 0], 1e-15);
    });
  });

  group('screwExp', () {
    test('rotates exactly about a line not through the origin (x/y components included)', () {
      final axis = <double>[0.6, -0.8 * 0.6, 0.8 * 0.8];
      final n = norm3(axis);
      final u = [for (final a in axis) a / n];
      final c = <double>[12, -7, 3];
      for (final theta in const [1e-6, 0.3, -1.1, 2.4]) {
        final base = Pose(<double>[4, 5, -6], rotFromRotvec(<double>[0.3, -0.2, 0.5]));
        final w = [for (final a in u) a * theta];
        final e = rotFromRotvec(w);
        final rel = <double>[base.t[0] - c[0], base.t[1] - c[1], base.t[2] - c[2]];
        final er = e.mulVec(rel);
        final want = Pose(<double>[er[0] + c[0], er[1] + c[1], er[2] + c[2]], e * base.r);
        final v = cross3(w, rel);
        final got = screwExp(base, <double>[v[0], v[1], v[2], w[0], w[1], w[2]]);
        _near(got.t, want.t, 1e-9, 'theta=$theta t');
        _near(got.r.m, want.r.m, 1e-12, 'theta=$theta r');
      }
    });

    test('zero twist returns the pose', () {
      final base = Pose(<double>[1, 2, 3], rotFromRotvec(<double>[0.1, 0.2, 0.3]));
      final got = screwExp(base, List<double>.filled(6, 0));
      _near(got.t, base.t, 1e-15);
      _near(got.r.m, base.r.m, 1e-15);
    });

    test('poseDelta inverts applyDelta', () {
      final base = Pose(<double>[1, 2, 3], rotFromRotvec(<double>[0.1, 0.2, 0.3]));
      final d = <double>[0.5, -0.25, 2.0, 0.2, -0.1, 0.4];
      _near(poseDelta(applyDelta(base, d), base), d, 1e-12);
    });
  });
}
