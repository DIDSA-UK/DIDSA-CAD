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

/// [ConstraintRadialDimensionItem.defaultAngleOffsetDegrees]'s own rotation
/// - shared by [_ConstraintOverlayPainter._paintRadialDimension] and
/// [constraintOverlayItemLabelCenter] so a ghost's hit-test target always
/// matches wherever it's actually drawn.
///
/// Bug fix (on-device feedback: "[dimension lines] should remain connected
/// to the same part of the circle while orbiting - currently they slide
/// round"): this used to rotate the already-*projected* `rimScreen -
/// centerScreen` vector by [degrees] directly in screen space - but a
/// fixed screen-space rotation does not correspond to a fixed point on the
/// circle as the camera orbits, since the projection's own local "ellipse
/// basis" (see [radialDimensionTouchPoint]) itself changes shape with the
/// camera. Rotating [rim] around [center] in *sketch-local* space first
/// (this function), then letting the caller project the *result*, anchors
/// [degrees] to a genuinely fixed point on the circle instead - by the same
/// reasoning [radialDimensionTouchPoint] itself relies on: solving for (or
/// here, directly using) a sketch-local point and projecting it is exact
/// under any camera orientation, unlike approximating in screen space.
(double, double) _rotateSketchPointAroundCenter(
  (double, double) center,
  (double, double) point,
  double degrees,
) {
  if (degrees == 0.0) return point;
  final dx = point.$1 - center.$1;
  final dy = point.$2 - center.$2;
  final radius = math.sqrt(dx * dx + dy * dy);
  if (radius < 1e-9) return point;
  final angle = math.atan2(dy, dx) + degrees * math.pi / 180.0;
  return (center.$1 + radius * math.cos(angle), center.$2 + radius * math.sin(angle));
}

/// Bug fix (on-device feedback: "when I orbit, the radius and diameter
/// dimension lines look disconnected from the circle"): a circle's own
/// perspective/affine screen projection is an ellipse, not a scaled circle -
/// placing the leader's touch point by scaling [desiredDirection] by a
/// single "pixels per sketch unit" scalar only ever lands exactly on the
/// true rendered outline at whichever one sketch-local angle that scalar
/// was measured from (historically `rim`'s own angle), drifting further off
/// the actual rendered ellipse the more the current view foreshortens the
/// sketch plane as the camera orbits.
///
/// Fixed by treating [rimScreen]/[perpScreen] (the screen projections of
/// two points 90 degrees apart on the sketch-local circle, both already
/// resolved by the caller) as the ellipse's own pair of conjugate radius
/// vectors from [centerScreen] - together they exactly describe *any*
/// affine (and, very closely, perspective) projection of a circle. Solving
/// the 2x2 system `cosT*axisU + sinT*axisV = k*desiredDirection` for the
/// sketch-local unit parameter `(cosT, sinT)` (via the [axisU]/[axisV]
/// matrix inverse), then re-applying it as `centerScreen + cosT*axisU +
/// sinT*axisV`, places the touch point exactly on the true projected
/// ellipse in the desired direction - not merely close to it.
///
/// Falls back to the old scalar-circle approximation (`centerScreen +
/// desiredDirection * fallbackRadiusPixels`) only when [perpScreen] failed
/// to project or the view is genuinely edge-on/degenerate (the two
/// conjugate radius vectors collapse onto the same line, so there is no
/// well-defined ellipse to solve against). Returns `(touchScreen,
/// direction)` - `direction` is the outward unit vector from [centerScreen]
/// to the resolved touch point, screen-space, for arrowhead orientation.
(Offset, Offset) radialDimensionTouchPoint({
  required Offset centerScreen,
  required Offset rimScreen,
  required Offset? perpScreen,
  required Offset desiredDirection,
  required double fallbackRadiusPixels,
}) {
  final axisU = rimScreen - centerScreen;
  final axisV = perpScreen == null ? null : perpScreen - centerScreen;
  final param = _solveRadialParam(axisU: axisU, axisV: axisV, desiredDirection: desiredDirection);
  if (param == null) {
    return (centerScreen + desiredDirection * fallbackRadiusPixels, desiredDirection);
  }
  final (cosT, sinT) = param;
  final touchScreen = centerScreen + axisU * cosT + axisV! * sinT;
  final rawDirection = touchScreen - centerScreen;
  final direction = rawDirection.distance < 1e-6 ? desiredDirection : rawDirection / rawDirection.distance;
  return (touchScreen, direction);
}

/// Bug fix follow-up (on-device feedback: "the arrow should remain at the
/// same angular position when orbiting" - reported against a radial
/// dimension whose label had previously been dragged): [radialDimension
/// TouchPoint] resolves a *screen-space* desired direction into a touch
/// point for rendering, but a Constraint's own persisted drag offset
/// ([SketchController.labelOffsetFor]) is raw screen pixels - camera-frame
/// dependent, so a *stored* screen-pixel offset re-interpreted through a
/// *different* camera orientation (after orbiting) resolves to a different
/// point on the circle than the one the user actually dragged to.
///
/// This is the same ellipse solve as [radialDimensionTouchPoint], but
/// returns the resolved *sketch-local angle* itself (degrees, relative to
/// `rim`'s own angle around `center` - i.e. what [_rotateSketchPointAround
/// Center] expects back) instead of a screen point - a camera-independent
/// quantity safe to persist (see [SketchController.setRadialAngleOffset]).
/// The caller (only [PartViewport]'s own label-drag handling, which alone
/// has the live camera/projection context) is expected to call this once
/// per drag-move frame and persist the result in place of accumulating a
/// screen-pixel delta. Returns null exactly when [radialDimensionTouchPoint]
/// would have fallen back to its scalar approximation (no well-defined
/// ellipse to solve against) - the caller should simply skip that frame's
/// update rather than persist a meaningless angle.
double? radialDimensionAngleDegrees({
  required Offset centerScreen,
  required Offset rimScreen,
  required Offset? perpScreen,
  required Offset desiredDirection,
}) {
  final axisU = rimScreen - centerScreen;
  final axisV = perpScreen == null ? null : perpScreen - centerScreen;
  final param = _solveRadialParam(axisU: axisU, axisV: axisV, desiredDirection: desiredDirection);
  if (param == null) return null;
  final (cosT, sinT) = param;
  return math.atan2(sinT, cosT) * 180.0 / math.pi;
}

/// The shared 2x2 solve behind [radialDimensionTouchPoint]/
/// [radialDimensionAngleDegrees]: the sketch-local unit parameter `(cosT,
/// sinT)` such that `cosT*axisU + sinT*axisV` points the same way as
/// [desiredDirection] - or null if [axisV] is missing or the two vectors
/// are degenerate/collinear (no well-defined ellipse).
(double, double)? _solveRadialParam({
  required Offset axisU,
  required Offset? axisV,
  required Offset desiredDirection,
}) {
  if (axisV == null) return null;
  final det = axisU.dx * axisV.dy - axisU.dy * axisV.dx;
  if (det.abs() < 1e-9) return null;
  final cosTUnnorm = (axisV.dy * desiredDirection.dx - axisV.dx * desiredDirection.dy) / det;
  final sinTUnnorm = (axisU.dx * desiredDirection.dy - axisU.dy * desiredDirection.dx) / det;
  final paramLength = math.sqrt(cosTUnnorm * cosTUnnorm + sinTUnnorm * sinTUnnorm);
  if (paramLength < 1e-9) return (1.0, 0.0);
  return (cosTUnnorm / paramLength, sinTUnnorm / paramLength);
}

/// Projects [item]'s own `center`/`rim`, plus the sketch-local point 90
/// degrees around the circle from `rim` (the same "conjugate radius
/// vector" pair [radialDimensionTouchPoint]/[radialDimensionAngleDegrees]
/// need) - exposed so [PartViewport]'s own radial label-drag handling can
/// resolve [radialDimensionAngleDegrees] without duplicating this
/// projection step, which otherwise lives entirely inside the private
/// painter/[constraintOverlayItemLabelCenter].
(Offset center, Offset rim, Offset? perp)? projectRadialDimensionBasis(
  Camera camera,
  Size viewportSize,
  SketchPlaneBasis basis,
  ConstraintRadialDimensionItem item,
) {
  Offset? project((double, double) sketchXY) =>
      worldToScreen(camera, viewportSize, sketchPointToWorld(basis, sketchXY.$1, sketchXY.$2));
  final centerScreen = project(item.center);
  final rimScreen = project(item.rim);
  if (centerScreen == null || rimScreen == null) return null;
  final rimSketchDx = item.rim.$1 - item.center.$1;
  final rimSketchDy = item.rim.$2 - item.center.$2;
  final perpSketch = (item.center.$1 - rimSketchDy, item.center.$2 + rimSketchDx);
  final perpScreen = project(perpSketch);
  return (centerScreen, rimScreen, perpScreen);
}

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

    // P52 follow-up (on-device feedback: "dimension fix is working on one
    // end of a linear dimension, but the other side still slides") - the
    // original P52 fix only covered the `default:` (general-direction)
    // orientation below; 'vertical'/'horizontal' (an axis-aligned
    // dimension, e.g. a rectangle's own width/height - a very common case
    // to hit in real testing) still used the raw camera-dependent
    // `_dimensionOffsetDistance(normal, item.labelOffset)` path, which is
    // very likely what the report's "other side" actually was. The scale
    // factor (known sketch-local length vs. its current screen
    // projection) is identical regardless of orientation, so it's resolved
    // once up front and reused by all three branches via
    // [_resolveDimensionOffsetMagnitude].
    final sketchDx = item.pointB.$1 - item.pointA.$1;
    final sketchDy = item.pointB.$2 - item.pointA.$2;
    final sketchLength = math.sqrt(sketchDx * sketchDx + sketchDy * sketchDy);
    final screenDelta = bScreen - aScreen;
    final screenLength = screenDelta.distance;

    final Offset p1;
    final Offset p2;
    switch (item.orientation) {
      case 'vertical':
        const normal = Offset(1, 0);
        final offsetX = math.max(aScreen.dx, bScreen.dx) +
            _resolveDimensionOffsetMagnitude(
              normal: normal,
              labelOffset: item.labelOffset,
              sketchLocalOffsetDistance: item.sketchLocalOffsetDistance,
              sketchReferenceLength: sketchLength,
              screenReferenceLength: screenLength,
            );
        p1 = Offset(offsetX, aScreen.dy);
        p2 = Offset(offsetX, bScreen.dy);
      case 'horizontal':
        const normal = Offset(0, 1);
        final offsetY = math.max(aScreen.dy, bScreen.dy) +
            _resolveDimensionOffsetMagnitude(
              normal: normal,
              labelOffset: item.labelOffset,
              sketchLocalOffsetDistance: item.sketchLocalOffsetDistance,
              sketchReferenceLength: sketchLength,
              screenReferenceLength: screenLength,
            );
        p1 = Offset(aScreen.dx, offsetY);
        p2 = Offset(bScreen.dx, offsetY);
      default:
        if (screenLength < 1e-6) return;
        final normal = _canonicalPerpendicular(screenDelta);
        final offsetVec = normal *
            _resolveDimensionOffsetMagnitude(
              normal: normal,
              labelOffset: item.labelOffset,
              sketchLocalOffsetDistance: item.sketchLocalOffsetDistance,
              sketchReferenceLength: sketchLength,
              screenReferenceLength: screenLength,
            );
        p1 = aScreen + offsetVec;
        p2 = bScreen + offsetVec;
    }

    _drawExtensionLine(canvas, aScreen, p1, dimPaint);
    _drawExtensionLine(canvas, bScreen, p2, dimPaint);
    canvas.drawLine(p1, p2, dimPaint);
    _drawDimensionArrows(canvas, p1, p2, color);
    // On-device feedback ("dimensions should be movable anywhere, leaders
    // and extension lines should work as expected") - see
    // [_dimensionLabelPlacement]'s own doc comment.
    final placement = _dimensionLabelPlacement(p1, p2, item.labelOffset);
    if (placement.leaderFrom != null) {
      canvas.drawLine(placement.leaderFrom!, placement.labelCenter, dimPaint);
    }
    _drawDimensionLabel(canvas, placement.labelCenter, item.text, color, plainBlackText: true);
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
    // P52 follow-up: this dimension kind (a Line-to-Line distance, e.g.
    // two parallel edges) was never covered by the original P52 fix at
    // all - see [ConstraintLineDistanceDimensionItem.sketchLocalOffsetDistance]'s
    // own doc comment. Line 1's own sketch-local length vs. its current
    // screen projection ([lengthA], already computed above) stands in for
    // [_paintLinearDimension]'s own pointA/pointB pair as the local
    // pixels-per-unit reference.
    final sketchDx = item.line1End.$1 - item.line1Start.$1;
    final sketchDy = item.line1End.$2 - item.line1Start.$2;
    final sketchLengthA = math.sqrt(sketchDx * sketchDx + sketchDy * sketchDy);
    final offset = alongA *
        _resolveDimensionOffsetMagnitude(
          normal: alongA,
          labelOffset: item.labelOffset,
          sketchLocalOffsetDistance: item.sketchLocalOffsetDistance,
          sketchReferenceLength: sketchLengthA,
          screenReferenceLength: lengthA,
        );

    final dimPaint = Paint()
      ..color = color
      ..strokeWidth = _dimensionStrokeWidth;
    final p1 = midA + offset;
    final p2 = midB + offset;
    _drawExtensionLine(canvas, midA, p1, dimPaint);
    _drawExtensionLine(canvas, midB, p2, dimPaint);
    canvas.drawLine(p1, p2, dimPaint);
    _drawDimensionArrows(canvas, p1, p2, color);
    final placement = _dimensionLabelPlacement(p1, p2, item.labelOffset);
    if (placement.leaderFrom != null) {
      canvas.drawLine(placement.leaderFrom!, placement.labelCenter, dimPaint);
    }
    _drawDimensionLabel(canvas, placement.labelCenter, item.text, color, plainBlackText: true);
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

    final defaultSketchPoint = _rotateSketchPointAroundCenter(item.center, item.rim, item.defaultAngleOffsetDegrees);
    final defaultScreen = _project(defaultSketchPoint);
    final defaultDelta = defaultScreen == null ? (rimScreen - centerScreen) : defaultScreen - centerScreen;
    final defaultLength = defaultDelta.distance;
    final defaultDirection = defaultLength < 1e-6 ? const Offset(1, 0) : defaultDelta / defaultLength;

    final labelCenter = centerScreen + defaultDirection * (radiusPixels + _radialLegLength) + item.labelOffset;
    final desiredDelta = labelCenter - centerScreen;
    final desiredDirection =
        desiredDelta.distance < 1e-6 ? defaultDirection : desiredDelta / desiredDelta.distance;

    // Bug fix (on-device feedback: "when I orbit, the radius and diameter
    // dimension lines look disconnected from the circle"): a circle's own
    // perspective/affine screen projection is an ellipse, not a scaled
    // circle - the touch point used to be placed by scaling
    // `desiredDirection` by the scalar `radiusPixels` above, which only
    // ever lands exactly on the true rendered outline at the `rim` angle
    // itself, drifting further off it the more the current view
    // foreshortens the sketch plane. Fixed by also projecting a second
    // sketch-local point 90 degrees around the circle from `rim`
    // (`perpSketch`/`perpScreen` below) - see [radialDimensionTouchPoint]'s
    // own doc comment for the actual ellipse solve.
    final perpSketch = (item.center.$1 - rimSketchDy, item.center.$2 + rimSketchDx);
    final perpScreen = _project(perpSketch);
    final (touchScreen, direction) = radialDimensionTouchPoint(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: perpScreen,
      desiredDirection: desiredDirection,
      fallbackRadiusPixels: radiusPixels,
    );
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

double _dimensionOffsetDistance(Offset normal, Offset labelOffset) {
  if (labelOffset == Offset.zero) return _defaultDimensionOffset;
  final projected = labelOffset.dx * normal.dx + labelOffset.dy * normal.dy;
  final raw = _defaultDimensionOffset + projected;
  if (raw.abs() < _minDimensionOffsetMagnitude) {
    return raw.isNegative ? -_minDimensionOffsetMagnitude : _minDimensionOffsetMagnitude;
  }
  return raw;
}

/// A unit vector perpendicular to [delta], canonicalized to a fixed
/// screen-relative sign regardless of [delta]'s own direction - mirrors
/// `sketch_canvas.dart`'s identical fix/doc comment for the flat 2D canvas
/// (duplicated rather than imported - this package deliberately never
/// imports from `sketch/`, see this file's own header doc comment).
///
/// On-device feedback ("swiping up/down moves the dimension in the wrong
/// direction"): the diagonal/generic dimension case used to derive its
/// offset normal from `Offset(-delta.dy, delta.dx)`, whose sign flips
/// depending on which of the two constrained Points happens to be stored
/// as A vs B - roughly half of all diagonal dimensions offset from an
/// identical drag gesture in the visually opposite direction from their
/// siblings. This was fixed in the flat 2D canvas; this is the 3D-embedded
/// sketcher's own copy of the same bug, found and fixed in the same pass.
Offset _canonicalPerpendicular(Offset delta) {
  final length = delta.distance;
  if (length < 1e-6) return const Offset(0, -1);
  var normal = Offset(-delta.dy, delta.dx) / length;
  if (normal.dy > 1e-9 || (normal.dy.abs() <= 1e-9 && normal.dx < 0)) {
    normal = -normal;
  }
  return normal;
}

/// On-device feedback ("dimensions should be movable anywhere, leaders and
/// extension lines should work as expected") - the 3D-embedded sketcher's
/// own copy of `sketch_canvas.dart`'s `_dimensionLabelPlacement`, ported
/// verbatim: once a linear/line-distance dimension's own dimension line has
/// been positioned ([p1]/[p2], already offset perpendicular to the
/// measured geometry), this places the label itself - honoring whatever's
/// left of [labelOffset] *along* that line, with a short leader back to the
/// line once the label has actually moved off it, mirroring the radial
/// dimension's own already-existing shoulder/landing-leg pattern. Pure
/// screen-space math - identical either way regardless of whether [p1]/[p2]
/// came from a flat [ViewTransform] or a 3D camera projection, so no
/// camera-specific adaptation was needed to port this.
const double _dimensionLeaderThreshold = 4.0;

({Offset labelCenter, Offset? leaderFrom}) _dimensionLabelPlacement(
  Offset p1,
  Offset p2,
  Offset labelOffset,
) {
  final anchor = (p1 + p2) / 2;
  final delta = p2 - p1;
  final length = delta.distance;
  if (length < 1e-6) return (labelCenter: anchor, leaderFrom: null);
  final tangent = delta / length;
  final along = labelOffset.dx * tangent.dx + labelOffset.dy * tangent.dy;
  if (along.abs() < _dimensionLeaderThreshold) return (labelCenter: anchor, leaderFrom: null);
  return (labelCenter: anchor + tangent * along, leaderFrom: anchor);
}

/// P52 follow-up (on-device feedback: "dimension fix is working on one end
/// of a linear dimension, but the other side still slides") - shared by
/// every dimension-offset call site in this file ([_paintLinearDimension]'s
/// three orientation branches and [_paintLineDistanceDimension]), not just
/// the one P52 originally touched. Mirrors [_paintRadialDimension]'s own
/// already-proven technique: no single "pixels per sketch unit" scalar
/// exists in a perspective 3D view, but it's exactly recoverable locally by
/// comparing a dimension-specific known sketch-space reference length
/// ([sketchReferenceLength]) against its current on-screen projection
/// ([screenReferenceLength]), then scaling the user's stored sketch-local
/// offset distance ([sketchLocalOffsetDistance], set by
/// [SketchController.setLinearOffsetDistance]) by that ratio - unlike
/// [labelOffset], a raw screen-pixel delta captured under whatever camera
/// orientation was live at drag time, which goes stale (and visibly drifts)
/// the instant the camera orbits.
///
/// Falls back to the legacy [_dimensionOffsetDistance] (camera-dependent,
/// but the only option before the label has ever been dragged) whenever
/// [sketchLocalOffsetDistance] is null or [sketchReferenceLength] is too
/// small to divide by safely.
double _resolveDimensionOffsetMagnitude({
  required Offset normal,
  required Offset labelOffset,
  required double? sketchLocalOffsetDistance,
  required double sketchReferenceLength,
  required double screenReferenceLength,
}) {
  if (sketchLocalOffsetDistance == null || sketchReferenceLength < 1e-9) {
    return _dimensionOffsetDistance(normal, labelOffset);
  }
  return sketchLocalOffsetDistance * (screenReferenceLength / sketchReferenceLength);
}

/// P41 (on-device feedback: "I can't grab them or pick a ghost dimension"):
/// [item]'s own screen-space label centre, projected via [camera]/
/// [viewportSize]/[basis] - the exact same position each `_paint*` method
/// above draws its label chip at (this function is the standalone,
/// hit-testable twin of that math, not a separate approximation of it), so
/// a caller can reliably tell "did this tap land on item's own rendered
/// label" without needing to actually paint anything. Returns null if
/// [item]'s own anchors don't resolve (missing entity, behind the camera,
/// or a degenerate direction-vector case none of the paint methods can
/// draw either).
Offset? constraintOverlayItemLabelCenter(
  Camera camera,
  Size viewportSize,
  SketchPlaneBasis basis,
  ConstraintOverlayItem item,
) {
  Offset? project((double, double) sketchXY) =>
      worldToScreen(camera, viewportSize, sketchPointToWorld(basis, sketchXY.$1, sketchXY.$2));

  switch (item) {
    case ConstraintLabelItem it:
      final a = project(it.anchorA);
      final b = project(it.anchorB);
      if (a == null || b == null) return null;
      return (a + b) / 2 + it.labelOffset;

    case ConstraintLinearDimensionItem it:
      final aScreen = project(it.pointA);
      final bScreen = project(it.pointB);
      if (aScreen == null || bScreen == null) return null;
      // Calls the exact same [_resolveDimensionOffsetMagnitude]/
      // [_canonicalPerpendicular]/[_dimensionLabelPlacement] helpers
      // [_ConstraintOverlayPainter._paintLinearDimension] does, so this can
      // never drift from where the dimension is actually drawn - fixes two
      // bugs at once: the order-dependent normal sign in the diagonal case,
      // and a real paint/hit-test mismatch the earlier P52 camera-
      // independent-offset fix introduced (the painter already used
      // [_resolveDimensionOffsetMagnitude], this hit-test never did, so the
      // two disagreed the instant the camera moved since the label was last
      // dragged).
      final sketchDx = it.pointB.$1 - it.pointA.$1;
      final sketchDy = it.pointB.$2 - it.pointA.$2;
      final sketchLength = math.sqrt(sketchDx * sketchDx + sketchDy * sketchDy);
      final screenDelta = bScreen - aScreen;
      final screenLength = screenDelta.distance;
      final Offset p1;
      final Offset p2;
      switch (it.orientation) {
        case 'vertical':
          const normal = Offset(1, 0);
          final offsetX = math.max(aScreen.dx, bScreen.dx) +
              _resolveDimensionOffsetMagnitude(
                normal: normal,
                labelOffset: it.labelOffset,
                sketchLocalOffsetDistance: it.sketchLocalOffsetDistance,
                sketchReferenceLength: sketchLength,
                screenReferenceLength: screenLength,
              );
          p1 = Offset(offsetX, aScreen.dy);
          p2 = Offset(offsetX, bScreen.dy);
        case 'horizontal':
          const normal = Offset(0, 1);
          final offsetY = math.max(aScreen.dy, bScreen.dy) +
              _resolveDimensionOffsetMagnitude(
                normal: normal,
                labelOffset: it.labelOffset,
                sketchLocalOffsetDistance: it.sketchLocalOffsetDistance,
                sketchReferenceLength: sketchLength,
                screenReferenceLength: screenLength,
              );
          p1 = Offset(aScreen.dx, offsetY);
          p2 = Offset(bScreen.dx, offsetY);
        default:
          if (screenLength < 1e-6) return null;
          final normal = _canonicalPerpendicular(screenDelta);
          final offsetVec = normal *
              _resolveDimensionOffsetMagnitude(
                normal: normal,
                labelOffset: it.labelOffset,
                sketchLocalOffsetDistance: it.sketchLocalOffsetDistance,
                sketchReferenceLength: sketchLength,
                screenReferenceLength: screenLength,
              );
          p1 = aScreen + offsetVec;
          p2 = bScreen + offsetVec;
      }
      return _dimensionLabelPlacement(p1, p2, it.labelOffset).labelCenter;

    case ConstraintLineDistanceDimensionItem it:
      final line1Start = project(it.line1Start);
      final line1End = project(it.line1End);
      final line2Start = project(it.line2Start);
      if (line1Start == null || line1End == null || line2Start == null) return null;
      final midA = (line1Start + line1End) / 2;
      final dirA = line1End - line1Start;
      final lengthA = dirA.distance;
      if (lengthA < 1e-6) return null;
      final alongA = dirA / lengthA;
      final perpToA = Offset(-dirA.dy, dirA.dx) / lengthA;
      final toLineB = line2Start - midA;
      final t = toLineB.dx * perpToA.dx + toLineB.dy * perpToA.dy;
      final midB = midA + perpToA * t;
      if ((midB - midA).distance < 1e-6) return null;
      final sketchDx = it.line1End.$1 - it.line1Start.$1;
      final sketchDy = it.line1End.$2 - it.line1Start.$2;
      final sketchLengthA = math.sqrt(sketchDx * sketchDx + sketchDy * sketchDy);
      final offset = alongA *
          _resolveDimensionOffsetMagnitude(
            normal: alongA,
            labelOffset: it.labelOffset,
            sketchLocalOffsetDistance: it.sketchLocalOffsetDistance,
            sketchReferenceLength: sketchLengthA,
            screenReferenceLength: lengthA,
          );
      return _dimensionLabelPlacement(midA + offset, midB + offset, it.labelOffset).labelCenter;

    case ConstraintRadialDimensionItem it:
      final centerScreen = project(it.center);
      final rimScreen = project(it.rim);
      if (centerScreen == null || rimScreen == null) return null;
      final rimSketchDx = it.rim.$1 - it.center.$1;
      final rimSketchDy = it.rim.$2 - it.center.$2;
      final rimSketchDistance = math.sqrt(rimSketchDx * rimSketchDx + rimSketchDy * rimSketchDy);
      if (rimSketchDistance < 1e-9) return null;
      final pixelsPerUnit = (rimScreen - centerScreen).distance / rimSketchDistance;
      final radiusPixels = it.radius * pixelsPerUnit;
      if (radiusPixels < 1e-6) return null;
      final defaultSketchPoint = _rotateSketchPointAroundCenter(it.center, it.rim, it.defaultAngleOffsetDegrees);
      final defaultScreen = project(defaultSketchPoint);
      final defaultDelta = defaultScreen == null ? (rimScreen - centerScreen) : defaultScreen - centerScreen;
      final defaultLength = defaultDelta.distance;
      final defaultDirection = defaultLength < 1e-6 ? const Offset(1, 0) : defaultDelta / defaultLength;
      return centerScreen + defaultDirection * (radiusPixels + _radialLegLength) + it.labelOffset;
  }
}

/// P41: the [ConstraintOverlayItem.constraintId] of whichever of [items]'
/// own rendered label [screenPos] landed within [radius] of, checked in
/// reverse paint order (last-drawn/topmost first, standard hit-test
/// convention) - or null if it missed every one. Mirrors
/// `sketch_canvas.dart`'s own `dimensionLabelAt`, just resolving anchors
/// through [camera]/[viewportSize]/[basis] instead of a flat
/// `ViewTransform`.
String? constraintOverlayItemAt(
  Camera camera,
  Size viewportSize,
  SketchPlaneBasis basis,
  List<ConstraintOverlayItem> items,
  Offset screenPos, {
  double radius = 20.0, // matches sketch_canvas.dart's own _ghostHitRadiusPixels
}) {
  for (final item in items.reversed) {
    final center = constraintOverlayItemLabelCenter(camera, viewportSize, basis, item);
    if (center != null && (screenPos - center).distance <= radius) {
      return item.constraintId;
    }
  }
  return null;
}
