/// Anchor acceptance test (`docs/motion/projector-spec.md` §7).
library;

import 'se3.dart';

/// Reject an anchor whose `residual_inf` exceeds this.
const double kResidualTol = 1e-6;

/// Reject an anchor whose CLIENT-measured jump exceeds this × `L`.
const double kJumpRejectFactor = 1.0;

enum AnchorVerdict { ok, notConverged, residual, jump }

class AnchorDecision {
  final bool accept;
  final AnchorVerdict verdict;

  /// Weighted distance between the anchor and the client's own projection of the same wish; null for the first anchor / early rejects.
  final double? clientJump;

  const AnchorDecision(this.accept, this.verdict, this.clientJump);

  /// The spec's reason string (`ok`, `not_converged`, `residual`, `jump`).
  String get reason => switch (verdict) {
        AnchorVerdict.ok => 'ok',
        AnchorVerdict.notConverged => 'not_converged',
        AnchorVerdict.residual => 'residual',
        AnchorVerdict.jump => 'jump',
      };
}

/// Decides whether a `mate-motion` response may replace the current model.
/// [anchorGrabbed] = `members[0].transform`; [ownProjection] = the pose the
/// CURRENT model projects the same wish to (null for the very first anchor).
/// `quality.jump` from the wire is telemetry only and never used here.
AnchorDecision acceptAnchor({
  required bool converged,
  required double? residualInf,
  required Pose? anchorGrabbed,
  required Pose? ownProjection,
  required double lever,
}) {
  if (!converged) return const AnchorDecision(false, AnchorVerdict.notConverged, null);
  if (residualInf == null || residualInf > kResidualTol) {
    return const AnchorDecision(false, AnchorVerdict.residual, null);
  }
  double? jump;
  if (ownProjection != null && anchorGrabbed != null) {
    jump = weightedDist(anchorGrabbed, ownProjection, lever);
    if (jump > kJumpRejectFactor * lever) return AnchorDecision(false, AnchorVerdict.jump, jump);
  }
  return AnchorDecision(true, AnchorVerdict.ok, jump);
}
