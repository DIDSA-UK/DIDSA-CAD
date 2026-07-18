import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' show Camera;

import '../sketch/sketch_controller.dart'
    show
        ConstraintOverlayItem,
        ConstraintLabelItem,
        ConstraintLineDistanceDimensionItem,
        ConstraintLinearDimensionItem,
        ConstraintRadialDimensionItem;
import 'screen_projection.dart';
import 'sketch_geometry_3d.dart' show SketchPlaneBasis, sketchPointToWorld;

/// P32 (2D-sketcher feature parity): constraint labels/glyphs/dimensions in
/// the 3D-embedded Orbit View, screen-space-billboarded over the live 3D
/// scene the same way [SketchOrientationIndicator] already is - see that
/// class's own doc comment for why this must be rendered inside
/// [PartViewport]'s own build (fresh [camera]/[viewportSize] every frame),
/// not as an externally-driven overlay.
///
/// Deliberate, narrow exception to this package's own "viewport3d never
/// imports sketch" boundary (see `sketch_geometry_3d.dart`'s doc comments
/// for that rule and its reasoning): [ConstraintOverlayItem] and its
/// subtypes are pure, stateless data (no [SketchController] dependency of
/// their own) built by [SketchController.constraintOverlayItems] -
/// importing just those types here (not [SketchController] itself) keeps
/// every other `viewport3d` file decoupled while avoiding a second,
/// parallel type hierarchy that would exist for no reason other than
/// import-direction purity.
///
/// [items]' own anchors are sketch-local - this widget alone is
/// responsible for the [sketchPointToWorld] + [worldToScreen] projection
/// step, then applies the exact same screen-space dimension-line/
/// arrowhead/label-chip layout math `sketch_canvas.dart`'s own
/// `_paintDimensionOverlays` and its helpers use (see each private
/// `_paint*` method below for the one-to-one mapping).
class ConstraintOverlay extends StatelessWidget {
  final Camera camera;
  final Size viewportSize;
  final SketchPlaneBasis basis;
  final List<ConstraintOverlayItem> items;

  const ConstraintOverlay({
    super.key,
    required this.camera,
    required this.viewportSize,
    required this.basis,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ConstraintOverlayPainter(camera: camera, viewportSize: viewportSize, basis: basis, items: items),
      ),
    );
  }
}

const Color _selectedColor = Colors.purple;
const Color _dimensionLineColor = Colors.black;
const Color _constraintBadgeColor = Color(0xFFF5A623);
const double _dimensionFontSize = 9.5;
const double _dimensionStrokeWidth = 1.125;
const double _extensionLineGap = 4.0;
const double _extensionLineOvershoot = 3.0;
const double _arrowheadLength = 8.0;
const double _arrowheadHalfWidth = 2.5;
const double _defaultDimensionOffset = 18.0;
const double _minDimensionOffsetMagnitude = 6.0;
const double _radialLegLength = 24.0;
const double _diameterSymbolScale = 1.35;

class _ConstraintOverlayPainter extends CustomPainter {
  final Camera camera;
  final Size viewportSize;
  final SketchPlaneBasis basis;
  final List<ConstraintOverlayItem> items;

  _ConstraintOverlayPainter({required this.camera, required this.viewportSize, required this.basis, required this.items});

  Offset? _project((double, double) sketchXY) =>
      worldToScreen(camera, viewportSize, sketchPointToWorld(basis, sketchXY.$1, sketchXY.$2));

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      final color = item.selected ? _selectedColor : (item is ConstraintLabelItem ? _constraintBadgeColor : _dimensionLineColor);
      switch (item) {
        case ConstraintLabelItem it:
          _paintLabel(canvas, it, color);
        case ConstraintLinearDimensionItem it:
          _paintLinearDimension(canvas, it, color);
        case ConstraintLineDistanceDimensionItem it:
          _paintLineDistanceDimension(canvas, it, color);
        case ConstraintRadialDimensionItem it:
          _paintRadialDimension(canvas, it, color);
      }
    }
  }

  void _paintLabel(Canvas canvas, ConstraintLabelItem item, Color color) {
    final a = _project(item.anchorA);
    final b = _project(item.anchorB);
    if (a == null || b == null) return;
    final midpoint = (a + b) / 2;
    _drawDimensionLabel(canvas, midpoint + item.labelOffset, item.text, color, plainBlackText: item.plainBlackText);
  }

  void _paintLinearDimension(Canvas canvas, ConstraintLinearDimensionItem item, Color color) {
    final aScreen = _project(item.pointA);
    final bScreen = _project(item.pointB);
    if (aScreen == null || bScreen == null) return;

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;

    final Offset p1;
    final Offset p2;
    switch (item.orientation) {
      case 'vertical':
        const normal = Offset(1, 0);
        final offsetX = math.max(aScreen.dx, bScreen.dx) + _dimensionOffsetDistance(normal, item.labelOffset);
        p1 = Offset(offsetX, aScreen.dy);
        p2 = Offset(offsetX, bScreen.dy);
      case 'horizontal':
        const normal = Offset(0, 1);
        final offsetY = math.max(aScreen.dy, bScreen.dy) + _dimensionOffsetDistance(normal, item.labelOffset);
        p1 = Offset(aScreen.dx, offsetY);
        p2 = Offset(bScreen.dx, offsetY);
      default:
        final delta = bScreen - aScreen;
        final length = delta.distance;
        if (length < 1e-6) return;
        final normal = Offset(-delta.dy, delta.dx) / length;
        final offsetVec = normal * _dimensionOffsetDistance(normal, item.labelOffset);
        p1 = aScreen + offsetVec;
        p2 = bScreen + offsetVec;
    }

    _drawExtensionLine(canvas, aScreen, p1, dimPaint);
    _drawExtensionLine(canvas, bScreen, p2, dimPaint);
    canvas.drawLine(p1, p2, dimPaint);
    _drawDimensionArrows(canvas, p1, p2, color);
    _drawDimensionLabel(canvas, (p1 + p2) / 2, item.text, color, plainBlackText: true);
  }

  void _paintLineDistanceDimension(Canvas canvas, ConstraintLineDistanceDimensionItem item, Color color) {
    final line1Start = _project(item.line1Start);
    final line1End = _project(item.line1End);
    final line2Start = _project(item.line2Start);
    final line2End = _project(item.line2End);
    if (line1Start == null || line1End == null || line2Start == null || line2End == null) return;

    final midA = (line1Start + line1End) / 2;
    final dirA = line1End - line1Start;
    final lengthA = dirA.distance;
    if (lengthA < 1e-6) return;
    final alongA = dirA / lengthA;
    final perpToA = Offset(-dirA.dy, dirA.dx) / lengthA;
    final toLineB = line2Start - midA;
    final t = toLineB.dx * perpToA.dx + toLineB.dy * perpToA.dy;
    final midB = midA + perpToA * t;

    final delta = midB - midA;
    if (delta.distance < 1e-6) return;
    final offset = alongA * _dimensionOffsetDistance(alongA, item.labelOffset);

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;
    _drawExtensionLine(canvas, midA, midA + offset, dimPaint);
    _drawExtensionLine(canvas, midB, midB + offset, dimPaint);
    canvas.drawLine(midA + offset, midB + offset, dimPaint);
    _drawDimensionArrows(canvas, midA + offset, midB + offset, color);
    _drawDimensionLabel(canvas, (midA + offset + midB + offset) / 2, item.text, color, plainBlackText: true);
  }

  void _paintRadialDimension(Canvas canvas, ConstraintRadialDimensionItem item, Color color) {
    final centerScreen = _project(item.center);
    final rimScreen = _project(item.rim);
    if (centerScreen == null || rimScreen == null) return;

    // No single "pixels per sketch unit" scalar exists in a perspective 3D
    // view (it varies with camera distance) - approximated locally by
    // measuring the already-projected centre->rim screen distance against
    // the rim Point's own known sketch-space distance from centre, which is
    // exact at the rim's own depth and a very close approximation anywhere
    // else on a near-planar dimension circle.
    final rimSketchDx = item.rim.$1 - item.center.$1;
    final rimSketchDy = item.rim.$2 - item.center.$2;
    final rimSketchDistance = math.sqrt(rimSketchDx * rimSketchDx + rimSketchDy * rimSketchDy);
    if (rimSketchDistance < 1e-9) return;
    final pixelsPerUnit = (rimScreen - centerScreen).distance / rimSketchDistance;
    final radiusPixels = item.radius * pixelsPerUnit;
    if (radiusPixels < 1e-6) return;

    final defaultDelta = rimScreen - centerScreen;
    final defaultLength = defaultDelta.distance;
    final defaultDirection = defaultLength < 1e-6 ? const Offset(1, 0) : defaultDelta / defaultLength;

    final labelCenter = centerScreen + defaultDirection * (radiusPixels + _radialLegLength) + item.labelOffset;
    final desiredDelta = labelCenter - centerScreen;
    final touchAngle = desiredDelta.distance < 1e-6
        ? math.atan2(defaultDirection.dy, defaultDirection.dx)
        : math.atan2(desiredDelta.dy, desiredDelta.dx);
    final direction = Offset(math.cos(touchAngle), math.sin(touchAngle));
    final touchScreen = centerScreen + direction * radiusPixels;
    final oppositeTouchScreen = centerScreen * 2 - touchScreen;

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;

    if (item.isDiameter) {
      canvas.drawLine(oppositeTouchScreen, touchScreen, dimPaint);
      canvas.drawLine(touchScreen, labelCenter, dimPaint);
      _drawArrowhead(canvas, touchScreen, direction, color);
      _drawArrowhead(canvas, oppositeTouchScreen, -direction, color);
    } else {
      canvas.drawLine(touchScreen, labelCenter, dimPaint);
      _drawArrowhead(canvas, touchScreen, -direction, color);
    }
    _drawDimensionLabel(canvas, labelCenter, item.text, color, plainBlackText: true);
  }

  double _dimensionOffsetDistance(Offset normal, Offset labelOffset) {
    if (labelOffset == Offset.zero) return _defaultDimensionOffset;
    final projected = labelOffset.dx * normal.dx + labelOffset.dy * normal.dy;
    final raw = _defaultDimensionOffset + projected;
    if (raw.abs() < _minDimensionOffsetMagnitude) {
      return raw.isNegative ? -_minDimensionOffsetMagnitude : _minDimensionOffsetMagnitude;
    }
    return raw;
  }

  void _drawExtensionLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    final delta = to - from;
    final length = delta.distance;
    if (length < 1e-6) return;
    final direction = delta / length;
    canvas.drawLine(from + direction * _extensionLineGap, to + direction * _extensionLineOvershoot, paint);
  }

  void _drawArrowhead(Canvas canvas, Offset tip, Offset direction, Color color) {
    final normal = Offset(-direction.dy, direction.dx);
    final base = tip - direction * _arrowheadLength;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((base + normal * _arrowheadHalfWidth).dx, (base + normal * _arrowheadHalfWidth).dy)
      ..lineTo((base - normal * _arrowheadHalfWidth).dx, (base - normal * _arrowheadHalfWidth).dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawDimensionArrows(Canvas canvas, Offset p1, Offset p2, Color color) {
    final delta = p2 - p1;
    final length = delta.distance;
    if (length < 1e-6) return;
    final unit = delta / length;
    _drawArrowhead(canvas, p1, -unit, color);
    _drawArrowhead(canvas, p2, unit, color);
  }

  void _drawDimensionLabel(Canvas canvas, Offset center, String text, Color color, {bool plainBlackText = false}) {
    final baseStyle = TextStyle(
      color: plainBlackText ? Colors.black : Colors.white,
      fontSize: _dimensionFontSize,
      fontWeight: FontWeight.w600,
    );
    final isDiameter = text.startsWith('⌀');
    final textSpan = isDiameter
        ? TextSpan(
            children: [
              TextSpan(text: '⌀', style: baseStyle.copyWith(fontSize: _dimensionFontSize * _diameterSymbolScale)),
              TextSpan(text: text.substring(1), style: baseStyle),
            ],
          )
        : TextSpan(text: text, style: baseStyle);
    final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr)..layout();
    const horizontalPadding = 4.0;
    const verticalPadding = 2.0;
    final chipRect = Rect.fromCenter(
      center: center,
      width: textPainter.width + horizontalPadding * 2,
      height: textPainter.height + verticalPadding * 2,
    );
    final chipRRect = RRect.fromRectAndRadius(chipRect, const Radius.circular(3));
    if (plainBlackText) {
      canvas.drawRRect(chipRRect, Paint()..color = const Color(0xFFF5F5F5));
    } else {
      canvas.drawRRect(chipRRect, Paint()..color = color);
    }
    textPainter.paint(canvas, center - Offset(textPainter.width / 2, textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ConstraintOverlayPainter oldDelegate) {
    return oldDelegate.camera != camera || oldDelegate.viewportSize != viewportSize || oldDelegate.items != items;
  }
}
