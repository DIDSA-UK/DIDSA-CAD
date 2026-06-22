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

/// The two axes spanning each reference plane, in a fixed (not
/// camera-derived - there is no camera here, just a flat 2D canvas) screen
/// layout: the plane's first letter always points right, its second always
/// points up.
const Map<String, List<_PlaneAxis>> _axesByPlane = {
  'XY': [
    _PlaneAxis(label: 'X', color: Colors.red, direction: Offset(1, 0)),
    _PlaneAxis(label: 'Y', color: Colors.green, direction: Offset(0, -1)),
  ],
  'XZ': [
    _PlaneAxis(label: 'X', color: Colors.red, direction: Offset(1, 0)),
    _PlaneAxis(label: 'Z', color: Colors.blue, direction: Offset(0, -1)),
  ],
  'YZ': [
    _PlaneAxis(label: 'Y', color: Colors.green, direction: Offset(1, 0)),
    _PlaneAxis(label: 'Z', color: Colors.blue, direction: Offset(0, -1)),
  ],
};

/// [SketchCanvas]'s small "which plane is this Sketch on" indicator - not
/// the full 3D triad [PartViewport] draws, just [plane]'s label plus a
/// 2-axis arrow pair in the same colors, per the project brief's "at
/// minimum a visible label or 2-axis indicator". Renders nothing while
/// [plane] is still null (before [SketchController.ensureSketch]/
/// [SketchController.adoptSketch] resolves).
class PlaneIndicator extends StatelessWidget {
  final String? plane;

  const PlaneIndicator({super.key, required this.plane});

  @override
  Widget build(BuildContext context) {
    final axes = _axesByPlane[plane];
    if (axes == null) return const SizedBox.shrink();

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
