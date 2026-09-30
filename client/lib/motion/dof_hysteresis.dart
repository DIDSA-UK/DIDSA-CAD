/// Rank/dof-change hysteresis (`docs/motion/projector-spec.md` §10).
library;

import 'free_motion_projector.dart';
import 'se3.dart';
import 'weighted_basis.dart';

/// Weighted mm of wish only the new directions would capture before they count.
const double kHysteresisGainMin = 0.05;

/// Consecutive frames above [kHysteresisGainMin] before a dof rise is adopted.
const int kHysteresisGainFrames = 3;

enum HysteresisAnchorEvent { adopted, candidate }

class HysteresisFrame {
  final List<Pose> poses;
  final double gain;

  /// `none` or `adopted` (candidate adopted this frame).
  final String event;

  const HysteresisFrame(this.poses, this.gain, this.event);
}

/// Holds the active model and an optional candidate with MORE free directions.
/// A dof drop or equal dof is adopted at once (a wall is felt); a rise waits
/// for [kHysteresisGainFrames] consecutive frames of real gain.
class DofHysteresis {
  FreeMotionProjector? _active;
  List<List<double>>? _cand;
  int _count = 0;

  FreeMotionProjector? get active => _active;
  bool get hasCandidate => _cand != null;
  int get count => _count;
  int get dim => _active?.dim ?? 0;

  void reset() {
    _active = null;
    _cand = null;
    _count = 0;
  }

  /// Feed an ACCEPTED anchor (already through Gram-Schmidt in [anchor]).
  HysteresisAnchorEvent onAnchor(FreeMotionProjector anchor) {
    final cur = _active;
    if (cur == null || anchor.dim <= cur.dim) {
      _active = anchor;
      _cand = null;
      _count = 0;
      return HysteresisAnchorEvent.adopted;
    }
    // More freedom: refresh the reference, keep the old directions, remember the candidate.
    _active = cur.withRows(cur.rows, newRefs: anchor.refs);
    _cand = anchor.rows;
    return HysteresisAnchorEvent.candidate;
  }

  /// One frame: project [wanted] with the active model, advancing the candidate counter.
  HysteresisFrame frame(Pose wanted, {MotionIntegrator integrator = MotionIntegrator.screw}) {
    var cur = _active!;
    final want = cur.wishVector(wanted);
    var gain = 0.0;
    var event = 'none';
    final cand = _cand;
    if (cand != null) {
      final full = projectOntoRows(cand, cur.scale, want);
      final old = projectOntoRows(cur.rows, cur.scale, want);
      final diff = List<double>.generate(want.length, (i) => full[i] - old[i]);
      gain = weightedNorm(cur.scale, diff);
      _count = gain > kHysteresisGainMin ? _count + 1 : 0;
      if (_count >= kHysteresisGainFrames) {
        cur = cur.withRows(cand);
        _active = cur;
        _cand = null;
        _count = 0;
        event = 'adopted';
      }
    }
    return HysteresisFrame(cur.project(wanted, integrator: integrator), gain, event);
  }
}
