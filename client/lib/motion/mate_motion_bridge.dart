/// Glue between the `mate-motion` wire DTOs and the pure projector types.
/// The only file in `lib/motion/` that imports the API layer.
library;

import '../api/document_api_client.dart';
import 'free_motion_projector.dart';
import 'se3.dart';

Pose poseOfDto(RigidTransformDto t) => Pose.fromWire(
      translation: t.translation,
      rotationAxis: t.rotationAxis,
      rotationAngleDegrees: t.rotationAngleDegrees,
    );

RigidTransformDto dtoOfPose(Pose p) {
  final w = p.toWire();
  return RigidTransformDto(translation: w.translation, rotationAxis: w.axis, rotationAngleDegrees: w.degrees);
}

/// Builds the projector from an anchor response, or `null` when there is
/// nothing to build one from: `converged:false`, missing basis/chart/members,
/// or a basis whose width is not `6·members`. A null result means HOLD, never "all free".
FreeMotionProjector? projectorFromMateMotion(MateMotionDto r) {
  final basis = r.basis;
  final chart = r.chart;
  if (!r.converged || basis == null || chart == null || r.members.isEmpty) return null;
  final width = 6 * r.members.length;
  if (basis.any((row) => row.length != width)) return null;
  return FreeMotionProjector.fromAnchor(
    refs: <Pose>[for (final m in r.members) poseOfDto(m.transform)],
    basis: basis,
    lever: chart.leverArm,
  );
}
