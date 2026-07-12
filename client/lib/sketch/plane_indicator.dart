import 'package:flutter/material.dart';

/// One axis of [PlaneIndicator]'s 2-axis indicator: its label/color (the
/// same X=red/Y=green/Z=blue convention `viewport3d/triad.dart` and
/// `viewport3d/reference_planes.dart` already use) and which screen
/// direction it points.
class _PlaneAxis {
  final String label;
  final Color color;
  final Offset direction;

  const _PlaneAxis({required this.label, required this.color, required this.direction});
}

/// A plain `(x, y, z)` triple - deliberately *not* `vector_math`'s
/// `Vector3` (or anything from `viewport3d/sketch_geometry_3d.dart`/
/// `reference_planes.dart`, both of which pull in `package:flutter_scene`
/// transitively): this file sits deep in the 2D-only sketch canvas's own
/// import graph (reached by every sketch widget test, several of which
/// deliberately avoid the viewport3d/flutter_scene/flutter_gpu chain - see
/// e.g. `sketch_canvas_ghost_editor_test.dart`), so it can't afford to
/// import anything that would drag that chain in, mirroring the backend's
/// own `app.document.plane_geometry._sketch_point_to_world`'s identical
/// "OCCT-free callers can't afford it" reasoning for the same kind of
/// per-plane axis table.
typedef _Vec3 = (double, double, double);

/// Sketcher-roadmap Phase 5's own per-plane basis table - a small,
/// deliberate duplicate of `app.document.plane_geometry._PLANE_BASIS`/
/// `viewport3d/sketch_geometry_3d.dart`'s `SketchPlaneBasis.fixed` (see
/// this file's own `_Vec3` doc comment for why it can't just import that
/// instead). Only the two in-plane axes matter here (this widget never
/// needs `origin`/`normal`), each `(x, y, z)` a unit vector along a world
/// axis - matches every one of those two tables exactly, so re-derive
/// this alongside them if either ever changes (XZ's `x_axis` really is
/// `(-1, 0, 0)`, not `(1, 0, 0)` - see either of those doc comments for
/// the right-handedness derivation).
const Map<String, (_Vec3, _Vec3)> _fixedAxesByPlane = {
  'XY': ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0)),
  'XZ': ((-1.0, 0.0, 0.0), (0.0, 0.0, 1.0)),
  'YZ': ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0)),
};

_Vec3 _negate(_Vec3 v) => (-v.$1, -v.$2, -v.$3);

/// Sketcher-roadmap Phase 5: [_fixedAxesByPlane]'s own (x, y) axis pair for
/// [plane], with [flip]/[rotationQuarterTurns] applied - mirrors the
/// backend's `app.document.plane_geometry.oriented_basis_for_plane`
/// exactly (same flip-then-rotate order, same "a 90-degree CCW turn maps
/// xAxis -> yAxis, yAxis -> -xAxis" formula - see that function's own doc
/// comment for the full derivation).
(_Vec3, _Vec3) _orientedAxes(String plane, {required bool flip, required int rotationQuarterTurns}) {
  final base = _fixedAxesByPlane[plane]!;
  var xAxis = flip ? _negate(base.$1) : base.$1;
  var yAxis = base.$2;
  for (var i = 0; i < rotationQuarterTurns % 4; i++) {
    final nextX = yAxis;
    final nextY = _negate(xAxis);
    xAxis = nextX;
    yAxis = nextY;
  }
  return (xAxis, yAxis);
}

/// Which world axis (label/color, plus sign) [worldDirection] represents -
/// always axis-aligned (a unit vector along exactly one of x/y/z) since
/// every fixed plane's own basis is axis-aligned and flip/rotation only
/// ever produces another axis-aligned unit vector (negation and
/// 90-degree-multiple swaps, never a genuinely diagonal direction).
(String label, Color color, bool negative) _worldAxisLabel(_Vec3 worldDirection) {
  final (x, y, z) = worldDirection;
  if (x.abs() > 0.5) return ('X', Colors.red, x < 0);
  if (y.abs() > 0.5) return ('Y', Colors.green, y < 0);
  return ('Z', Colors.blue, z < 0);
}

/// [SketchCanvas]'s small "which plane is this Sketch on" indicator - not
/// the full 3D triad [PartViewport] draws, just [plane]'s label plus a
/// 2-axis arrow pair in the same colors, per the project brief's "at
/// minimum a visible label or 2-axis indicator". Renders nothing while
/// [plane] is still null (before [SketchController.ensureSketch]/
/// [SketchController.adoptSketch] resolves).
///
/// Sketcher-roadmap Phase 5: [flip]/[rotationQuarterTurns] (see
/// [SketchController.flip]/[SketchController.rotationQuarterTurns])
/// change which world axis each arrow represents - the arrows themselves
/// always point screen-right/screen-up (a Sketch's own local +X/+Y are
/// always rendered that way on the flat 2D canvas, regardless of
/// orientation - only the *label* naming which world axis that direction
/// now maps to changes), computed live via this file's own [_orientedAxes]
/// (a deliberate small duplicate of `viewport3d/sketch_geometry_3d.dart`'s
/// `SketchPlaneBasis.oriented` - see [_Vec3]'s own doc comment for why)
/// rather than a hardcoded-to-the-unoriented-default per-plane table, so
/// this indicator stays accurate after a flip/rotate.
class PlaneIndicator extends StatelessWidget {
  final String? plane;
  final bool flip;
  final int rotationQuarterTurns;

  const PlaneIndicator({
    super.key,
    required this.plane,
    this.flip = false,
    this.rotationQuarterTurns = 0,
  });

  @override
  Widget build(BuildContext context) {
    if (plane == null || !_fixedAxesByPlane.containsKey(plane)) return const SizedBox.shrink();

    final (xAxis, yAxis) =
        _orientedAxes(plane!, flip: flip, rotationQuarterTurns: rotationQuarterTurns);
    final (xLabel, xColor, xNegative) = _worldAxisLabel(xAxis);
    final (yLabel, yColor, yNegative) = _worldAxisLabel(yAxis);
    final axes = [
      _PlaneAxis(label: xNegative ? '-$xLabel' : xLabel, color: xColor, direction: const Offset(1, 0)),
      _PlaneAxis(label: yNegative ? '-$yLabel' : yLabel, color: yColor, direction: const Offset(0, -1)),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(plane!, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
          const SizedBox(width: 6),
          CustomPaint(size: const Size(28, 28), painter: _PlaneAxesPainter(axes)),
        ],
      ),
    );
  }
}

class _PlaneAxesPainter extends CustomPainter {
  final List<_PlaneAxis> axes;

  const _PlaneAxesPainter(this.axes);

  @override
  void paint(Canvas canvas, Size size) {
    final origin = Offset(4, size.height - 4);
    const armLength = 18.0;
    for (final axis in axes) {
      final tip = origin + axis.direction * armLength;
      canvas.drawLine(
        origin,
        tip,
        Paint()
          ..color = axis.color
          ..strokeWidth = 2,
      );
      final textPainter = TextPainter(
        text: TextSpan(text: axis.label, style: TextStyle(color: axis.color, fontSize: 10, fontWeight: FontWeight.bold)),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, tip - Offset(textPainter.width / 2, textPainter.height / 2) + axis.direction * 6);
    }
  }

  @override
  bool shouldRepaint(covariant _PlaneAxesPainter oldDelegate) => false;
}
