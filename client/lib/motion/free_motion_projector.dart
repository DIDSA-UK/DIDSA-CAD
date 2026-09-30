/// The per-frame projector (`docs/motion/projector-spec.md` §4-§5): given the
/// latest accepted anchor (reference poses + free-motion basis) and the
/// hand's wished pose for the grabbed occurrence, which pose should every
/// group member be drawn at? Local, no network call.
library;

import 'se3.dart';
import 'weighted_basis.dart';

/// How the projected twist is integrated.
enum MotionIntegrator {
  /// Constant spatial screw (spec §5). The normative one.
  screw,

  /// "Add `v`, compose `exp(w)`" - the v0 integrator; informational only.
  additive,
}

/// One accepted anchor turned into a projector. Immutable.
///
/// [refs] are the anchor's `members[].transform` (grabbed first = column
/// order of the response `basis`); [rows] are the response basis re-made
/// orthonormal in the follower-weighted metric (spec §3); [lever] is the
/// response's `chart.lever_arm`.
class FreeMotionProjector {
  final List<Pose> refs;
  final List<List<double>> rows;
  final double lever;
  final double followerWeight;
  final List<double> scale;

  FreeMotionProjector._(this.refs, this.rows, this.lever, this.followerWeight, this.scale);

  /// Builds the model from a response: runs the weighted Gram-Schmidt once.
  factory FreeMotionProjector.fromAnchor({
    required List<Pose> refs,
    required List<List<double>> basis,
    required double lever,
    double followerWeight = kFollowerWeight,
  }) {
    final s = memberScale(refs.length, lever, follower: followerWeight);
    return FreeMotionProjector._(List<Pose>.unmodifiable(refs), weightedGramSchmidt(basis, s), lever, followerWeight, s);
  }

  /// Same refs/lever with already-orthonormal [rows] (used by the hysteresis to mix an old basis with a new ref).
  FreeMotionProjector withRows(List<List<double>> newRows, {List<Pose>? newRefs}) =>
      FreeMotionProjector._(newRefs ?? refs, newRows, lever, followerWeight, scale);

  int get members => refs.length;

  /// Number of free directions after re-orthonormalisation; 0 = the group cannot move.
  int get dim => rows.length;

  /// The wish vector: `log(ref_0, wanted)` in the grabbed block, zero elsewhere (followers have no wish).
  List<double> wishVector(Pose wanted) {
    final want = List<double>.filled(6 * members, 0);
    final d = poseDelta(wanted, refs[0]);
    for (var i = 0; i < 6; i++) {
      want[i] = d[i];
    }
    return want;
  }

  /// The projected 6k twist (followers included).
  List<double> projectTwist(Pose wanted) => projectOntoRows(rows, scale, wishVector(wanted));

  /// Poses for every member at the wished grabbed pose. `dim == 0` returns [refs].
  List<Pose> project(Pose wanted, {MotionIntegrator integrator = MotionIntegrator.screw}) =>
      integrate(projectTwist(wanted), integrator: integrator);

  /// Integrates an already-projected twist from the reference poses.
  List<Pose> integrate(List<double> d, {MotionIntegrator integrator = MotionIntegrator.screw}) => <Pose>[
        for (var m = 0; m < members; m++)
          integrator == MotionIntegrator.screw ? screwExp(refs[m], d, 6 * m) : applyDelta(refs[m], d, 6 * m),
      ];

  /// `‖g ∘ log(ref_0, shown)‖`, `g = [1,1,1,L,L,L]` - travel of the grabbed member since the anchor (spec §6).
  double travel(Pose shownGrabbed) => weightedDist(shownGrabbed, refs[0], lever);
}
