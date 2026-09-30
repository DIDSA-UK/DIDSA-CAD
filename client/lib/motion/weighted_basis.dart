/// Follower-weighted metric and Gram-Schmidt (`docs/motion/projector-spec.md`
/// §2-§3). Pure Dart.
library;

import 'dart:math' as math;

/// Follower metric scale relative to the grabbed member. A contract constant
/// (the backend's `_FOLLOWER_WEIGHT`), never sent on the wire.
const double kFollowerWeight = 1e-4;

/// Gram-Schmidt: drop a row whose remainder is below this fraction of its own norm.
const double kGramSchmidtDropRelative = 1e-6;

/// Gram-Schmidt: drop a row whose weighted norm is below this outright.
const double kGramSchmidtDropAbsolute = 1e-12;

/// Per-coordinate metric scale `s` (length `6·members`): `⟨a,b⟩ = Σ (s·a)(s·b)`.
/// `[1,1,1,L,L,L]` for member [grabbed], times [follower] for the others.
List<double> memberScale(int members, double lever, {int grabbed = 0, double follower = kFollowerWeight}) {
  final out = <double>[];
  for (var m = 0; m < members; m++) {
    final f = m == grabbed ? 1.0 : follower;
    out.addAll(<double>[f, f, f, f * lever, f * lever, f * lever]);
  }
  return out;
}

double weightedDot(List<double> s, List<double> a, List<double> b) {
  var acc = 0.0;
  for (var i = 0; i < a.length; i++) {
    acc += (s[i] * a[i]) * (s[i] * b[i]);
  }
  return acc;
}

double weightedNorm(List<double> s, List<double> a) => math.sqrt(weightedDot(s, a, a));

/// Modified Gram-Schmidt with one re-orthogonalisation pass in metric [s]
/// (spec §3). Output rows are orthonormal in that metric and span the same
/// space; dependent / zero rows are skipped. Do it once per accepted anchor.
List<List<double>> weightedGramSchmidt(List<List<double>> rows, List<double> s) {
  final out = <List<double>>[];
  for (final row in rows) {
    final v = List<double>.of(row);
    final n0 = weightedNorm(s, v);
    if (n0 < kGramSchmidtDropAbsolute) continue;
    for (var pass = 0; pass < 2; pass++) {
      for (final u in out) {
        final c = weightedDot(s, v, u);
        for (var i = 0; i < v.length; i++) {
          v[i] -= c * u[i];
        }
      }
    }
    final n = weightedNorm(s, v);
    if (n < kGramSchmidtDropRelative * n0) continue;
    out.add(List<double>.generate(v.length, (i) => v[i] / n));
  }
  return out;
}

/// `Σ ⟨u_i, want⟩ u_i` - the weighted least-squares fit of [want] onto the
/// span of the orthonormal [rows].
List<double> projectOntoRows(List<List<double>> rows, List<double> s, List<double> want) {
  final a = List<double>.filled(want.length, 0);
  for (final u in rows) {
    final c = weightedDot(s, u, want);
    for (var i = 0; i < a.length; i++) {
      a[i] += c * u[i];
    }
  }
  return a;
}
