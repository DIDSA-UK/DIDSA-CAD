/// Displayed-vs-anchor blend (`docs/motion/projector-spec.md` §9).
///
/// A newly accepted anchor changes the model, so the projection of the same
/// wish jumps by the anchor step. The blender keeps a per-member offset in the
/// `poseDelta` chart and decays it by `exp(−1/τ)` per frame. Display only:
/// never feed `shown` back into the wish, never persist it.
library;

import 'dart:math' as math;

import 'se3.dart';

/// τ in frames (≈ 33 ms at 60 Hz).
const double kBlendTauFrames = 2.0;

/// Offsets below this weighted size may be dropped by the caller (spec §9). [MotionBlender.isSettled].
const double kBlendSettled = 1e-6;

class MotionBlender {
  final double _decay;
  List<List<double>> _offsets;

  MotionBlender(int members, {double tauFrames = kBlendTauFrames})
      : _decay = math.exp(-1.0 / tauFrames),
        _offsets = List<List<double>>.generate(members, (_) => List<double>.filled(6, 0));

  /// Current per-member offsets (copies), mostly for tests.
  List<List<double>> get offsets => <List<double>>[for (final o in _offsets) List<double>.of(o)];

  /// Replaces the offsets (used by tests and when resuming from a hold).
  void setOffsets(List<List<double>> offsets) {
    _offsets = <List<double>>[for (final o in offsets) List<double>.of(o)];
  }

  void reset() {
    _offsets = <List<double>>[for (final _ in _offsets) List<double>.filled(6, 0)];
  }

  /// Call on the frame a new anchor is accepted, BEFORE [shown]: continuity
  /// with what the OLD model would have shown this frame.
  void onAnchor(List<Pose> oldProjected, List<Pose> newProjected) {
    final oldShown = <Pose>[for (var m = 0; m < oldProjected.length; m++) applyDelta(oldProjected[m], _offsets[m])];
    _offsets = <List<double>>[for (var m = 0; m < oldShown.length; m++) poseDelta(oldShown[m], newProjected[m])];
  }

  /// `apply_delta(P, o)` per member, then decays the offsets one frame.
  List<Pose> shown(List<Pose> projected) {
    final out = <Pose>[for (var m = 0; m < projected.length; m++) applyDelta(projected[m], _offsets[m])];
    _offsets = <List<double>>[
      for (final o in _offsets) <double>[for (final x in o) x * _decay],
    ];
    return out;
  }

  /// True when every offset is below [kBlendSettled] in the weighted size (`lever` = `L`).
  bool isSettled(double lever) {
    for (final o in _offsets) {
      final a = o[0], b = o[1], c = o[2], d = o[3] * lever, e = o[4] * lever, f = o[5] * lever;
      if (math.sqrt(a * a + b * b + c * c + d * d + e * e + f * f) >= kBlendSettled) return false;
    }
    return true;
  }
}
