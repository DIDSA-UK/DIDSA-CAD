import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;

import 'screen_projection.dart';
import 'sketch_geometry_3d.dart' show SketchPlaneBasis;

/// New-sketch orientation confirm step (on-device feedback: changing a
/// Sketch's orientation had no visual feedback in the 3D viewport at all,
/// and the only place to set it was buried in the in-sketch hamburger menu
/// after already committing to a plane). Renders directly over
/// [PartViewport], anchored to [basis].origin in real 3D space via
/// [worldToScreen]: a "SKETCH" label plus two arrows along [basis].yAxis
/// (the sketch's own local +Y - "up" on the flat 2D canvas, see
/// [SketchPlaneBasis.oriented]'s own doc comment) and its negation, so
/// flip/rotate-90 taps are visible on the actual plane before the user
/// ever opens the 2D editor, not just inferred from a small corner
/// indicator once already inside it (see `sketch/plane_indicator.dart`,
/// which stays as-is for that in-editor case).
///
/// [camera]/[viewportSize] are a snapshot (see [PartViewportState.camera]'s
/// own doc comment) - this paints correctly at the moment it's given, but
/// does not repaint on its own as the user orbits/pans/zooms; the caller
/// re-supplies a fresh snapshot on every rebuild it triggers (flip/rotate
/// taps), which is the only camera movement expected during this step.
class SketchOrientationIndicator extends StatelessWidget {
  final PerspectiveCamera camera;
  final Size viewportSize;
  final SketchPlaneBasis basis;

  const SketchOrientationIndicator({
    super.key,
    required this.camera,
    required this.viewportSize,
    required this.basis,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SketchOrientationPainter(camera: camera, viewportSize: viewportSize, basis: basis),
      ),
    );
  }
}

/// Matches [triadAxes]' Y-axis colour (`triad.dart`'s `triadColorY`) - the
/// up/down arrows are both the sketch's own Y axis, just signed either way,
/// so one colour for the pair reads as "one axis" rather than two unrelated
/// indicators.
const Color _upDownColor = Color(0xFF27AE60);

class _SketchOrientationPainter extends CustomPainter {
  final PerspectiveCamera camera;
  final Size viewportSize;
  final SketchPlaneBasis basis;

  const _SketchOrientationPainter({required this.camera, required this.viewportSize, required this.basis});

  @override
  void paint(Canvas canvas, Size size) {
    final origin = worldToScreen(camera, viewportSize, basis.origin);
    if (origin == null) return;

    // Scales with camera distance (a fixed world-space length would look
    // huge up close and vanish from far away) - the same "gizmo scales
    // with distance" convention most CAD viewports use for on-scene
    // handles, clamped so it never gets absurdly small/large right at the
    // clip planes.
    final distance = (camera.position - basis.origin).length;
    final armLengthWorld = distance.clamp(0.5, 500.0) * 0.2;

    final upScreen = worldToScreen(camera, viewportSize, basis.origin + basis.yAxis * armLengthWorld);
    final downScreen = worldToScreen(camera, viewportSize, basis.origin - basis.yAxis * armLengthWorld);

    final paint = Paint()
      ..color = _upDownColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    if (upScreen != null) {
      canvas.drawLine(origin, upScreen, paint);
      _drawArrowhead(canvas, origin, upScreen, _upDownColor);
    }
    if (downScreen != null) {
      canvas.drawLine(origin, downScreen, paint);
      _drawArrowhead(canvas, origin, downScreen, _upDownColor);
    }

    _drawLabel(canvas, origin - const Offset(0, 22), 'SKETCH', Colors.white, background: true);
    if (upScreen != null) _drawLabel(canvas, upScreen + const Offset(0, -14), 'UP', _upDownColor);
    if (downScreen != null) _drawLabel(canvas, downScreen + const Offset(0, 6), 'DOWN', _upDownColor);
  }

  void _drawArrowhead(Canvas canvas, Offset from, Offset to, Color color) {
    final direction = to - from;
    if (direction.distance < 1e-6) return;
    final unit = direction / direction.distance;
    const headLength = 9.0;
    const headAngle = 0.5; // radians
    Offset rotate(Offset v, double angle) => Offset(
          v.dx * math.cos(angle) - v.dy * math.sin(angle),
          v.dx * math.sin(angle) + v.dy * math.cos(angle),
        );
    final left = to - rotate(unit, headAngle) * headLength;
    final right = to - rotate(unit, -headAngle) * headLength;
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(left.dx, left.dy)
      ..lineTo(right.dx, right.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawLabel(Canvas canvas, Offset center, String text, Color color, {bool background = false}) {
    final textPainter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    final origin = center - Offset(textPainter.width / 2, textPainter.height / 2);
    if (background) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          origin.translate(-6, -3) & Size(textPainter.width + 12, textPainter.height + 6),
          const Radius.circular(4),
        ),
        Paint()..color = Colors.black.withValues(alpha: 0.55),
      );
    }
    textPainter.paint(canvas, origin);
  }

  @override
  bool shouldRepaint(covariant _SketchOrientationPainter oldDelegate) =>
      oldDelegate.camera != camera || oldDelegate.viewportSize != viewportSize || oldDelegate.basis != basis;
}
