import 'dart:math' as math;
import 'dart:typed_data' show Float64List;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:vector_math/vector_math.dart' as vm;

import 'screen_projection.dart';
import 'sketch_geometry_3d.dart' show SketchPlaneBasis;

/// New-sketch orientation confirm step (on-device feedback): renders
/// directly over [PartViewport]'s own 3D scene, anchored to [basis].origin
/// in real 3D space:
///  - an "up" arrow along [basis].yAxis and a "right" arrow along
///    [basis].xAxis - the sketch's own local +Y/+X (see
///    [SketchPlaneBasis.oriented]'s own doc comment) - both via
///    [worldToScreen], the same screen-space-billboard technique
///    `viewport3d/triad.dart`'s own compass gizmo uses.
///  - a semi-opaque white square standing in for the sketch canvas itself,
///    bottom-left corner pinned exactly at the origin and extending along
///    +xAxis/+yAxis, with "SKETCH" lettered on it - both genuinely laid
///    flat on the plane (not a screen-facing billboard label like the
///    arrows' own text), via [planeTransform]'s perspective-correct
///    local-to-pixel [Matrix4], so the square/word visibly rotate and
///    mirror exactly as [basis]'s own axes do when the user flips/rotates
///    - not just conceptually but literally, since both are built directly
///    from [basis].xAxis/[basis].yAxis with no separate flip/rotate logic
///    of their own.
///
/// [camera]/[viewportSize] must be fresh on every call for this to track
/// live as the user orbits - see [PartViewport.sketchOrientationBasis]'s
/// own doc comment for why this is rendered inside [PartViewport]'s own
/// build rather than as an externally-driven overlay.
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
        painter: _SketchOrientationPainter(
            camera: camera, viewportSize: viewportSize, basis: basis),
      ),
    );
  }
}

const Color _rightArrowColor =
    Color(0xFFE8364A); // matches triad.dart's triadColorX
const Color _upArrowColor =
    Color(0xFF27AE60); // matches triad.dart's triadColorY

/// Builds the perspective-correct [Matrix4] mapping a "local sketch-plane"
/// point `(u, v)` - measured in real world-length units along
/// [basis].xAxis/[basis].yAxis, origin at [basis].origin - directly to
/// pixel coordinates in [viewSize]. Composing this once and applying it via
/// [Canvas.transform] lets ordinary 2D drawing calls (`drawRect`,
/// [TextPainter.paint]) afterward act as if they were painting straight
/// onto the 3D plane, foreshortening/skewing correctly with the camera
/// angle - the same trick a texture-mapped quad uses, just built by hand
/// since this is a flat overlay [Canvas], not a textured [Scene] node.
///
/// Derivation: `pixel = pixelFromClip * (viewProjection * worldFromLocal) *
/// (u, v, 0, 1)`, where `worldFromLocal`'s columns are literally
/// [basis].xAxis/[basis].yAxis/[basis].normal/[basis].origin (a basis-change
/// matrix - local axis-aligned unit vectors map to whichever real 3D
/// direction each basis axis points), `viewProjection` is [camera]'s own
/// [PerspectiveCamera.getViewTransform], and `pixelFromClip` re-derives the
/// exact same NDC<->pixel mapping [worldToScreen] uses, just encoded as a
/// matrix (preserving clip-space `w` through to the final row) instead of
/// [worldToScreen]'s own explicit post-hoc divide - `Canvas.transform`
/// performs that division itself when rasterizing whatever gets drawn
/// through it, which is what makes the perspective-correct foreshortening
/// happen "for free" on every subsequent draw call.
@visibleForTesting
vm.Matrix4 planeTransform(
    PerspectiveCamera camera, Size viewSize, SketchPlaneBasis basis) {
  final worldFromLocal = vm.Matrix4.zero()
    ..setColumn(0, vm.Vector4(basis.xAxis.x, basis.xAxis.y, basis.xAxis.z, 0))
    ..setColumn(1, vm.Vector4(basis.yAxis.x, basis.yAxis.y, basis.yAxis.z, 0))
    ..setColumn(
        2, vm.Vector4(basis.normal.x, basis.normal.y, basis.normal.z, 0))
    ..setColumn(
        3, vm.Vector4(basis.origin.x, basis.origin.y, basis.origin.z, 1));

  final pixelFromClip = vm.Matrix4.zero()
    ..setRow(0, vm.Vector4(viewSize.width / 2, 0, 0, viewSize.width / 2))
    ..setRow(1, vm.Vector4(0, -viewSize.height / 2, 0, viewSize.height / 2))
    ..setRow(2, vm.Vector4(0, 0, 1, 0))
    ..setRow(3, vm.Vector4(0, 0, 0, 1));

  final clipFromLocal =
      camera.getViewTransform(viewSize) * worldFromLocal as vm.Matrix4;
  return pixelFromClip * clipFromLocal as vm.Matrix4;
}

class _SketchOrientationPainter extends CustomPainter {
  final PerspectiveCamera camera;
  final Size viewportSize;
  final SketchPlaneBasis basis;

  const _SketchOrientationPainter(
      {required this.camera, required this.viewportSize, required this.basis});

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

    final rightScreen = worldToScreen(
        camera, viewportSize, basis.origin + basis.xAxis * armLengthWorld);
    final upScreen = worldToScreen(
        camera, viewportSize, basis.origin + basis.yAxis * armLengthWorld);

    final rightPaint = Paint()
      ..color = _rightArrowColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    final upPaint = Paint()
      ..color = _upArrowColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    if (rightScreen != null) {
      canvas.drawLine(origin, rightScreen, rightPaint);
      _drawArrowhead(canvas, origin, rightScreen, _rightArrowColor);
      _drawLabel(
          canvas, rightScreen + const Offset(14, 0), 'RIGHT', _rightArrowColor);
    }
    if (upScreen != null) {
      canvas.drawLine(origin, upScreen, upPaint);
      _drawArrowhead(canvas, origin, upScreen, _upArrowColor);
      _drawLabel(canvas, upScreen + const Offset(0, -14), 'UP', _upArrowColor);
    }

    _paintCanvasPlate(canvas, armLengthWorld * 0.85);
  }

  /// The "SKETCH" plate: a semi-opaque white square, bottom-left corner at
  /// [basis].origin, extending [size] world-length-units along
  /// [basis].xAxis/[basis].yAxis, with "SKETCH" lettered across it - see
  /// this file's own header doc comment for why this is drawn through
  /// [planeTransform] rather than as a screen-facing label.
  void _paintCanvasPlate(Canvas canvas, double size) {
    final transform = planeTransform(camera, viewportSize, basis);
    canvas.save();
    // Canvas.transform needs a Float64List; Matrix4.storage is a
    // Float32List (vector_math's own internal representation) - an
    // explicit widen, not a no-op cast.
    canvas.transform(Float64List.fromList(transform.storage));

    final square = Rect.fromLTRB(0, 0, size, size);
    canvas.drawRect(
        square, Paint()..color = Colors.white.withValues(alpha: 0.75));
    canvas.drawRect(
      square,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = size * 0.01,
    );

    // Text is painted in its own locally-flipped sub-space: TextPainter
    // always lays glyphs out assuming +y is "down the page" from the paint
    // offset, but this outer transform's local +v is [basis].yAxis
    // ("sketch up") - without the extra flip here, "SKETCH" would render
    // upside-down whenever actually viewed right-side-up on the plane.
    final textPainter = TextPainter(
      text: TextSpan(
        text: 'SKETCH',
        style: TextStyle(
          color: Colors.black,
          fontSize: size * 0.22,
          fontWeight: FontWeight.bold,
          letterSpacing: size * 0.01,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    canvas.save();
    canvas.translate(size / 2, size / 2);
    canvas.scale(1, -1);
    textPainter.paint(
        canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
    canvas.restore();

    canvas.restore();
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

  void _drawLabel(Canvas canvas, Offset center, String text, Color color) {
    final textPainter = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
        canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _SketchOrientationPainter oldDelegate) =>
      oldDelegate.camera != camera ||
      oldDelegate.viewportSize != viewportSize ||
      oldDelegate.basis != basis;
}
