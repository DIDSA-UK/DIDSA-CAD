import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'sketch_controller.dart';
import 'view_transform.dart';

/// The 2D sketch canvas: renders the cursor, Points, Lines, and the
/// snap-to-start indicator, and turns raw pointer events into the unified
/// cursor model (relative+scaled for touch, absolute 1:1 for a real mouse).
class SketchCanvas extends StatefulWidget {
  final SketchController controller;

  const SketchCanvas({super.key, required this.controller});

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  static const double _pixelsPerUnit = 20;

  ViewTransform _transformFor(Size size) => ViewTransform(
        pixelsPerUnit: _pixelsPerUnit,
        originScreen: Offset(size.width / 2, size.height / 2),
      );

  void _handlePointerHover(PointerHoverEvent event, ViewTransform transform) {
    // Hover events only fire for a mouse with no buttons pressed - real
    // mouse movement drives the cursor directly, 1:1.
    if (event.kind != PointerDeviceKind.mouse) return;
    widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
  }

  void _handlePointerMove(PointerMoveEvent event, ViewTransform transform) {
    if (event.kind == PointerDeviceKind.mouse) {
      widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
    } else {
      // Touch: relative, scaled movement - never jumps to the touch point.
      widget.controller.moveCursorRelative(event.delta.dx, event.delta.dy);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    // A real mouse click does the same thing as the on-screen Click
    // button. Touch-down intentionally does nothing else: per the
    // interaction model, only the Click button commits a point, and
    // touching down must not move the persistent cursor.
    if (event.kind == PointerDeviceKind.mouse) {
      widget.controller.click();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final transform = _transformFor(size);
        return Listener(
          onPointerDown: _handlePointerDown,
          onPointerHover: (e) => _handlePointerHover(e, transform),
          onPointerMove: (e) => _handlePointerMove(e, transform),
          child: AnimatedBuilder(
            animation: widget.controller,
            builder: (context, _) {
              return CustomPaint(
                size: size,
                painter: _SketchPainter(controller: widget.controller, transform: transform),
              );
            },
          ),
        );
      },
    );
  }
}

class _SketchPainter extends CustomPainter {
  final SketchController controller;
  final ViewTransform transform;

  _SketchPainter({required this.controller, required this.transform});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF2F2F2));

    final linePaint = Paint()
      ..color = Colors.blueGrey.shade700
      ..strokeWidth = 2;
    for (final line in controller.lines.values) {
      final start = controller.points[line.startPointId];
      final end = controller.points[line.endPointId];
      if (start == null || end == null) continue;
      canvas.drawLine(
        transform.sketchToScreen(start.x, start.y),
        transform.sketchToScreen(end.x, end.y),
        linePaint,
      );
    }

    final chainFirstId = controller.chainFirstPointId;
    final isSnapping = controller.isHoveringChainStart;
    for (final point in controller.points.values) {
      final isChainStart = controller.chainInProgress && point.id == chainFirstId;
      final screenPos = transform.sketchToScreen(point.x, point.y);
      Color color = Colors.black87;
      double radius = 4;
      if (isChainStart) {
        color = isSnapping ? Colors.green : Colors.deepOrange;
        radius = isSnapping ? 11 : 6;
      }
      canvas.drawCircle(screenPos, radius, Paint()..color = color);
    }

    final cursorScreen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
    final crosshairPaint = Paint()
      ..color = Colors.red
      ..strokeWidth = 1.5;
    const armLength = 12.0;
    canvas.drawLine(
      cursorScreen.translate(-armLength, 0),
      cursorScreen.translate(armLength, 0),
      crosshairPaint,
    );
    canvas.drawLine(
      cursorScreen.translate(0, -armLength),
      cursorScreen.translate(0, armLength),
      crosshairPaint,
    );
    canvas.drawCircle(cursorScreen, 3, crosshairPaint);
  }

  @override
  bool shouldRepaint(covariant _SketchPainter oldDelegate) => true;
}
