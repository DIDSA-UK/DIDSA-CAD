import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import 'sketch_controller.dart';
import 'sketch_viewport.dart';
import 'view_transform.dart';

/// The 2D sketch canvas: renders the cursor, Points, Lines, and the
/// snap-to-start indicator, and turns raw pointer events into the unified
/// cursor model (relative+scaled for touch, absolute 1:1 for a real mouse),
/// plus pan/zoom (pinch and two-finger drag on touch; scroll wheel and
/// right-click-drag on a mouse) that only ever adjusts [_viewport] - the
/// controller's cursor stays in sketch-space coordinates throughout, so it
/// is never "converted back" and is unaffected by how the view is panned
/// or zoomed.
class SketchCanvas extends StatefulWidget {
  final SketchController controller;

  const SketchCanvas({super.key, required this.controller});

  @override
  State<SketchCanvas> createState() => _SketchCanvasState();
}

class _SketchCanvasState extends State<SketchCanvas> {
  final SketchViewport _viewport = SketchViewport();

  /// Live touch pointers by id, for pinch-zoom/two-finger-pan - tracked
  /// separately from the single-finger cursor drag, which only applies
  /// while exactly one touch is active.
  final Map<int, Offset> _activeTouches = {};

  void _handlePointerHover(PointerHoverEvent event, ViewTransform transform) {
    // Hover events only fire for a mouse with no buttons pressed - real
    // mouse movement drives the cursor directly, 1:1.
    if (event.kind != PointerDeviceKind.mouse) return;
    widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      // Only the primary (left) button commits a point, same as the
      // on-screen Click button - a right-click starts a pan drag instead
      // (see _handlePointerMove) and must not also place a point.
      if (event.buttons & kPrimaryMouseButton != 0) {
        widget.controller.click();
      }
      return;
    }
    // Touch-down never moves the persistent cursor or commits a point -
    // only the Click button does that - but is tracked here so a second
    // finger touching down is seen by the pinch/pan handling below.
    _activeTouches[event.pointer] = event.localPosition;
  }

  void _handlePointerMove(PointerMoveEvent event, ViewTransform transform, Size size) {
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kSecondaryMouseButton != 0) {
        setState(() => _viewport.panByScreenDelta(event.delta));
      } else {
        widget.controller.moveCursorAbsoluteScreen(event.localPosition, transform);
      }
      return;
    }

    if (_activeTouches.length < 2) {
      // Single-finger: relative, scaled cursor movement - never jumps to
      // the touch point. Sensitivity scales with the current zoom so the
      // felt responsiveness stays consistent across zoom levels.
      widget.controller.moveCursorRelative(event.delta.dx, event.delta.dy, _viewport.zoom);
      return;
    }

    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches, size);
  }

  void _handlePointerEnd(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) _activeTouches.remove(event.pointer);
  }

  void _handlePointerSignal(PointerSignalEvent event, Size size) {
    if (event is PointerScrollEvent) {
      // Scrolling "down" (positive dy) zooms out, matching common map/CAD
      // tool conventions.
      final scaleFactor = event.scrollDelta.dy > 0 ? 0.9 : 1 / 0.9;
      setState(() => _viewport.zoomAtScreenPoint(event.localPosition, scaleFactor, size));
    }
  }

  void _applyPinchPan(Map<int, Offset> before, Map<int, Offset> after, Size size) {
    final beforeCentroid = _centroidOf(before.values);
    final afterCentroid = _centroidOf(after.values);
    final beforeSpread = _averageSpread(before.values, beforeCentroid);
    final afterSpread = _averageSpread(after.values, afterCentroid);
    final scaleFactor = beforeSpread > 1e-6 ? afterSpread / beforeSpread : 1.0;

    setState(() {
      _viewport.applyAnchoredZoomPan(
        anchorScreen: beforeCentroid,
        targetScreen: afterCentroid,
        scaleFactor: scaleFactor,
        size: size,
      );
    });
  }

  Offset _centroidOf(Iterable<Offset> points) {
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  double _averageSpread(Iterable<Offset> points, Offset centroid) {
    if (points.length < 2) return 0;
    var total = 0.0;
    for (final point in points) {
      total += (point - centroid).distance;
    }
    return total / points.length;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final transform = _viewport.transformFor(size);
        return Stack(
          children: [
            Listener(
              onPointerDown: _handlePointerDown,
              onPointerHover: (e) => _handlePointerHover(e, transform),
              onPointerMove: (e) => _handlePointerMove(e, transform, size),
              onPointerUp: _handlePointerEnd,
              onPointerCancel: _handlePointerEnd,
              onPointerSignal: (e) => _handlePointerSignal(e, size),
              child: AnimatedBuilder(
                animation: widget.controller,
                builder: (context, _) {
                  return CustomPaint(
                    size: size,
                    painter: _SketchPainter(controller: widget.controller, transform: transform),
                  );
                },
              ),
            ),
            if (_viewport.zoom != 1 || _viewport.panOffset != Offset.zero)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton.filled(
                  tooltip: 'Reset view',
                  icon: const Icon(Icons.center_focus_strong),
                  onPressed: () => setState(_viewport.reset),
                ),
              ),
          ],
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

    final circlePaint = Paint()
      ..color = Colors.blueGrey.shade700
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final circle in controller.circles.values) {
      final center = controller.points[circle.centerPointId];
      final radiusPoint = controller.points[circle.radiusPointId];
      if (center == null || radiusPoint == null) continue;
      final radius = math.sqrt(
        math.pow(radiusPoint.x - center.x, 2) + math.pow(radiusPoint.y - center.y, 2),
      );
      canvas.drawCircle(
        transform.sketchToScreen(center.x, center.y),
        radius * transform.pixelsPerUnit,
        circlePaint,
      );
    }

    final originId = controller.originPointId;
    if (originId != null) {
      final origin = controller.points[originId];
      if (origin != null) {
        final isSnappingToOrigin = controller.isHoveringOrigin;
        final originPaint = Paint()
          ..color = isSnappingToOrigin ? Colors.green : Colors.indigo
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        final halfSize = isSnappingToOrigin ? 10.0 : 7.0;
        final originScreen = transform.sketchToScreen(origin.x, origin.y);
        canvas.drawRect(
          Rect.fromCenter(center: originScreen, width: halfSize * 2, height: halfSize * 2),
          originPaint,
        );
      }
    }

    final chainFirstId = controller.chainFirstPointId;
    final isSnapping = controller.isHoveringChainStart;
    final circleCenterId = controller.circleCenterPointId;
    for (final point in controller.points.values) {
      if (point.id == originId) continue; // Drawn separately above, as a square marker.
      final isChainStart = controller.chainInProgress && point.id == chainFirstId;
      final isCircleCenter = controller.circleInProgress && point.id == circleCenterId;
      final screenPos = transform.sketchToScreen(point.x, point.y);
      Color color = Colors.black87;
      double radius = 4;
      if (isChainStart) {
        color = isSnapping ? Colors.green : Colors.deepOrange;
        radius = isSnapping ? 11 : 6;
      } else if (isCircleCenter) {
        color = Colors.deepOrange;
        radius = 6;
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
