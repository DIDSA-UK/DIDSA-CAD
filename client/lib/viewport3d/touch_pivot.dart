
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'selection_hit_test.dart' show pointAtRayDistance;

/// What a tap in orbit mode does (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 2).
enum OrbitTapOutcome {
  /// Set the persistent rotation pivot at the tapped point on the model.
  setPivot,

  /// A reference plane or a created plane is in front: the tap keeps its meaning (opens the plane sheet).
  plane,

  /// Nothing was hit: the ordinary background tap, which also clears the pivot.
  background,
}

/// Decides a tap in orbit mode from how far along the picking ray each candidate was hit, both as distances in world
/// units (a null means not hit). A body, component or edge hit wins unless a plane is nearer: the 20 mm reference planes
/// sit in front of a big body from many angles, and without this check every tap on it would open a plane sheet.
OrbitTapOutcome resolveOrbitTap({double? pivotDistance, double? planeDistance}) {
  if (pivotDistance != null && (planeDistance == null || pivotDistance < planeDistance)) {
    return OrbitTapOutcome.setPivot;
  }
  return planeDistance != null ? OrbitTapOutcome.plane : OrbitTapOutcome.background;
}

/// A point the view orbits about, and its distance along the ray it was picked with.
typedef PivotHit = ({vm.Vector3 point, double distance});

/// The pivot for the nearest of [distances] (distances along [ray], as each hit's `rayT`), or null when there are none.
/// A distance is not a ray parameter: the picking ray's direction is not a unit vector, so the point is found with
/// [pointAtRayDistance], not `ray.at`.
PivotHit? nearestPivotHit(vm.Ray ray, Iterable<double> distances) {
  if (distances.isEmpty) return null;
  final nearest = distances.reduce((a, b) => a <= b ? a : b);
  return (point: pointAtRayDistance(ray, nearest), distance: nearest);
}

/// The marker drawn at the rotation pivot: a ring with a dot, a fixed size on screen whatever the zoom, outlined so it
/// reads on any background.
class PivotMarkerPainter extends CustomPainter {
  final Offset position;
  final Color color;

  const PivotMarkerPainter({required this.position, required this.color});

  static const double ringRadius = 9;
  static const double dotRadius = 2.5;

  @override
  void paint(Canvas canvas, Size size) {
    final outline = Paint()
      ..color = const Color(0xCC000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(position, ringRadius, outline);
    canvas.drawCircle(position, ringRadius, ring);
    canvas.drawCircle(position, dotRadius + 1, Paint()..color = const Color(0xCC000000));
    canvas.drawCircle(position, dotRadius, Paint()..color = color);
  }

  @override
  bool shouldRepaint(PivotMarkerPainter old) => old.position != position || old.color != color;
}
