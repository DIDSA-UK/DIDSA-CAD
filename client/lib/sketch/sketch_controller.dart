import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;

import '../api/sketch_api_client.dart';
import 'dof_analysis.dart';
import 'local_solver/local_sketch_solver.dart';
import 'local_solver/slvs_bindings.dart';
import 'view_transform.dart';

/// Returns [candidate] unchanged if it is within [canvasSize] bounds.
/// If [candidate] has escaped bounds in any direction, returns the canvas
/// centre. Does NOT clamp to edge - escaped means snap to centre, per
/// Prompt B item B0: edge-clamping makes the cursor visibly "stick" at the
/// boundary during a fast pan, which feels broken, while snapping to centre
/// makes the escape obvious and immediately recoverable. A point exactly on
/// the boundary (dx == 0, dx == canvasSize.width, ...) counts as in-bounds.
Offset clampCursorToCanvas(Offset candidate, Size canvasSize) {
  if (candidate.dx < 0 ||
      candidate.dx > canvasSize.width ||
      candidate.dy < 0 ||
      candidate.dy > canvasSize.height) {
    return Offset(canvasSize.width / 2, canvasSize.height / 2);
  }
  return candidate;
}

class SketchPointView {
  final String id;
  final double x;
  final double y;

  const SketchPointView({required this.id, required this.x, required this.y});
}

class SketchLineView {
  final String id;
  final String startPointId;
  final String endPointId;
  final bool construction;

  const SketchLineView({
    required this.id,
    required this.startPointId,
    required this.endPointId,
    this.construction = false,
  });
}

class SketchCircleView {
  final String id;
  final String centerPointId;
  final String radiusPointId;
  final bool construction;

  /// `[north, east, south, west]` - see the backend's
  /// `Circle.cardinal_point_ids` docstring for how each is solver-locked.
  /// Real, independently selectable/draggable Points, same as
  /// [radiusPointId] - added so a Circle has usable snap/pick targets
  /// beyond the single arbitrary [radiusPointId], always aligned to the
  /// sketch's own global axes regardless of where [radiusPointId] sits.
  final List<String> cardinalPointIds;

  const SketchCircleView({
    required this.id,
    required this.centerPointId,
    required this.radiusPointId,
    this.construction = false,
    this.cardinalPointIds = const [],
  });
}

class SketchArcView {
  final String id;
  final String centerPointId;
  final String startPointId;
  final String endPointId;
  final bool construction;

  const SketchArcView({
    required this.id,
    required this.centerPointId,
    required this.startPointId,
    required this.endPointId,
    this.construction = false,
  });
}

/// A regular Polygon - see the backend's `app.sketch.models.Polygon`
/// docstring for how [vertexPointIds]/[lineIds] are ordered and what the
/// solver constraint chain underneath them does. Bug fix (sketcher-roadmap
/// feedback round): the Polygon tool used to be a client-only shortcut with
/// no backend entity of its own (see the old `PlacedPolygon`'s doc comment,
/// which this replaces) - a real, persisted, single-atomic-call entity now
/// backs it, the same as Arc/Ellipse, letting [SketchController.
/// showPolygonGuideCircles] survive a fresh sketch reload (not just the
/// same session) and letting a vertex drag be reliably recognized as one
/// (see [beginPointDrag]).
class SketchPolygonView {
  final String id;
  final String centerPointId;
  final List<String> vertexPointIds;
  final List<String> lineIds;
  final int sides;
  final bool construction;

  const SketchPolygonView({
    required this.id,
    required this.centerPointId,
    required this.vertexPointIds,
    required this.lineIds,
    required this.sides,
    this.construction = false,
  });
}

class SketchEllipseView {
  final String id;
  final String centerPointId;
  final String majorPointId;
  final String majorPointNegId;
  final String minorPointId;
  final String minorPointNegId;
  final String majorAxisLineId;
  final String minorAxisLineId;
  final double minorRadius;
  final bool construction;

  const SketchEllipseView({
    required this.id,
    required this.centerPointId,
    required this.majorPointId,
    required this.majorPointNegId,
    required this.minorPointId,
    required this.minorPointNegId,
    required this.majorAxisLineId,
    required this.minorAxisLineId,
    required this.minorRadius,
    this.construction = false,
  });
}

class SketchSplineView {
  final String id;
  final List<String> throughPointIds;
  final List<String> controlPointIds;
  final bool construction;

  const SketchSplineView({
    required this.id,
    required this.throughPointIds,
    required this.controlPointIds,
    this.construction = false,
  });

  /// Every cubic segment's 4 defining Point ids (start, control 1,
  /// control 2, end), in order - the client-side mirror of the backend's
  /// `Spline.segments()`, used identically by rendering/hit-testing/drag.
  List<(String, String, String, String)> segments() => [
        for (var i = 0; i < throughPointIds.length - 1; i++)
          (
            throughPointIds[i],
            controlPointIds[2 * i],
            controlPointIds[2 * i + 1],
            throughPointIds[i + 1],
          ),
      ];
}

/// One glyph contour's outer/hole boundaries, cached as `(dx, dy)` offsets
/// from the owning Text's anchor Point *at the time the preview was
/// fetched* - not absolute sketch-space points. Kept anchor-relative
/// (rather than baking in the anchor's position) so dragging the anchor
/// Point - which never touches the Text entity's own fields, only the
/// Point's `(x, y)` - repositions every contour for free on the very next
/// frame, with no re-fetch: [SketchController.textAbsoluteContours] just
/// adds the anchor's *current* position back on read.
/// P32 (2D-sketcher feature parity): [SketchController.constraintOverlayItems]'
/// own output - deliberately renderer-agnostic (sketch-local anchors, no
/// screen-space math at all), since [SketchController] is shared by both
/// the flat 2D canvas and the 3D-embedded Orbit View. A caller projects
/// each item's own anchor(s) to its own coordinate space (2D:
/// `transform.sketchToScreen`; 3D: `sketchPointToWorld` + `worldToScreen`)
/// and only then applies the shared screen-space dimension-line/arrowhead/
/// label-chip layout math itself - see `sketch_canvas.dart`'s own
/// `_paintDimensionOverlays` and its helpers for that math (the layout
/// this mirrors exactly), and `sketch_constraint_overlay.dart`
/// (`viewport3d`) for the 3D port of it. [labelOffset] carries the same
/// *pixel* semantics [SketchController.labelOffsetFor] always has -
/// applied after projection, not before.
sealed class ConstraintOverlayItem {
  final String constraintId;
  final bool selected;
  const ConstraintOverlayItem({required this.constraintId, required this.selected});
}

/// A bare relationship glyph (V/H/Coinc./∥/⟂/=/Collin.) or a value-only
/// label with no dimension line (Angle, Point-Line distance) - a simple
/// chip at the midpoint between [anchorA]/[anchorB]. [plainBlackText]
/// mirrors `sketch_canvas.dart`'s own `_drawDimensionLabel` parameter:
/// true for a numeric measurement (near-white chip, black text), false for
/// a bare relationship glyph (solid-color-fill chip, white text).
class ConstraintLabelItem extends ConstraintOverlayItem {
  final (double, double) anchorA;
  final (double, double) anchorB;
  final String text;
  final Offset labelOffset;
  final bool plainBlackText;

  const ConstraintLabelItem({
    required super.constraintId,
    required super.selected,
    required this.anchorA,
    required this.anchorB,
    required this.text,
    required this.labelOffset,
    required this.plainBlackText,
  });

  @override
  bool operator ==(Object other) =>
      other is ConstraintLabelItem &&
      other.constraintId == constraintId &&
      other.selected == selected &&
      other.anchorA == anchorA &&
      other.anchorB == anchorB &&
      other.text == text &&
      other.labelOffset == labelOffset &&
      other.plainBlackText == plainBlackText;

  @override
  int get hashCode => Object.hash(constraintId, selected, anchorA, anchorB, text, labelOffset, plainBlackText);
}

/// A point-to-point (or Ellipse-axis) linear dimension - mirrors
/// `sketch_canvas.dart`'s own `_paintDistanceDimension`. [orientation] is
/// `DistanceConstraintDto.orientation` verbatim ('vertical'/'horizontal'/
/// null) - see that field's own doc comment for why a horizontal/vertical
/// dimension lays out along a fixed screen axis rather than along
/// [pointA]-[pointB]'s own direction.
class ConstraintLinearDimensionItem extends ConstraintOverlayItem {
  final (double, double) pointA;
  final (double, double) pointB;
  final String? orientation;
  final String text;
  final Offset labelOffset;

  const ConstraintLinearDimensionItem({
    required super.constraintId,
    required super.selected,
    required this.pointA,
    required this.pointB,
    required this.orientation,
    required this.text,
    required this.labelOffset,
  });

  @override
  bool operator ==(Object other) =>
      other is ConstraintLinearDimensionItem &&
      other.constraintId == constraintId &&
      other.selected == selected &&
      other.pointA == pointA &&
      other.pointB == pointB &&
      other.orientation == orientation &&
      other.text == text &&
      other.labelOffset == labelOffset;

  @override
  int get hashCode => Object.hash(constraintId, selected, pointA, pointB, orientation, text, labelOffset);
}

/// A Line-to-Line perpendicular-distance dimension - mirrors
/// `sketch_canvas.dart`'s own `_paintLineDistanceDimension`. Carries both
/// Lines' own endpoints (not just their midpoints) because the renderer
/// needs each Line's own direction to find the true perpendicular anchor
/// on Line 2 from Line 1's midpoint - see that method's own doc comment
/// for exactly why.
class ConstraintLineDistanceDimensionItem extends ConstraintOverlayItem {
  final (double, double) line1Start;
  final (double, double) line1End;
  final (double, double) line2Start;
  final (double, double) line2End;
  final String text;
  final Offset labelOffset;

  const ConstraintLineDistanceDimensionItem({
    required super.constraintId,
    required super.selected,
    required this.line1Start,
    required this.line1End,
    required this.line2Start,
    required this.line2End,
    required this.text,
    required this.labelOffset,
  });

  @override
  bool operator ==(Object other) =>
      other is ConstraintLineDistanceDimensionItem &&
      other.constraintId == constraintId &&
      other.selected == selected &&
      other.line1Start == line1Start &&
      other.line1End == line1End &&
      other.line2Start == line2Start &&
      other.line2End == line2End &&
      other.text == text &&
      other.labelOffset == labelOffset;

  @override
  int get hashCode =>
      Object.hash(constraintId, selected, line1Start, line1End, line2Start, line2End, text, labelOffset);
}

/// A radius/diameter dimension - mirrors `sketch_canvas.dart`'s own
/// `_paintRadiusDiameterDimension`/`_radialDimensionGeometry`. [rim] is only
/// ever used to derive the *default* leader angle before [labelOffset] has
/// ever been dragged - see `_radialDimensionGeometry`'s own doc comment for
/// why the leader otherwise sweeps freely around [center] as the label
/// moves, rather than staying pinned to a fixed Point. V1 scope: unlike the
/// 2D canvas's own `_paintArcExtensionIfNeeded`, an Arc's leader touching
/// outside its own drawn sweep does not (yet) draw a dashed extension arc -
/// a deliberate, documented gap, not a missed case.
class ConstraintRadialDimensionItem extends ConstraintOverlayItem {
  final (double, double) center;
  final (double, double) rim;
  final double radius;
  final bool isDiameter;
  final String text;
  final Offset labelOffset;

  const ConstraintRadialDimensionItem({
    required super.constraintId,
    required super.selected,
    required this.center,
    required this.rim,
    required this.radius,
    required this.isDiameter,
    required this.text,
    required this.labelOffset,
  });

  @override
  bool operator ==(Object other) =>
      other is ConstraintRadialDimensionItem &&
      other.constraintId == constraintId &&
      other.selected == selected &&
      other.center == center &&
      other.rim == rim &&
      other.radius == radius &&
      other.isDiameter == isDiameter &&
      other.text == text &&
      other.labelOffset == labelOffset;

  @override
  int get hashCode =>
      Object.hash(constraintId, selected, center, rim, radius, isDiameter, text, labelOffset);
}

class SketchTextContourOffsets {
  final List<(double, double)> outer;
  final List<List<(double, double)>> holes;

  const SketchTextContourOffsets({required this.outer, this.holes = const []});
}

/// The Text tool's own small, backend-bundled font allowlist, mirrored
/// here for the "Edit Text" dialog's font picker - see the backend's
/// `app.sketch.text_fonts.FONT_ALLOWLIST` (same names, same order,
/// deliberately not fetched from the server: a plain trusted-allowlist
/// mirror, the same pattern [setPolygonSides]'s own [3, 20] clamp mirrors
/// the backend's own range rather than round-tripping it). Feedback
/// round: expanded from Open Sans alone to a spread of registers a
/// mechanical/engineering drawing might reasonably want - see
/// text_fonts.py's own doc comment for the reasoning behind each one.
const List<String> textFontOptions = [
  'Open Sans',
  'Roboto',
  'Lato',
  'Fira Sans',
  'IBM Plex Serif',
  'IBM Plex Mono',
  'Space Mono',
  'Rajdhani',
];

class SketchTextView {
  final String id;
  final String content;
  final String font;
  final double size;
  final String anchorPointId;
  final double rotationDegrees;
  final bool construction;

  /// Null until the first [SketchController._refreshTextPreview] call
  /// completes (fired right after creation, and after every content/
  /// size/rotation edit) - see [SketchTextContourOffsets]'s own doc
  /// comment for why these are anchor-relative offsets, not absolute
  /// points.
  final List<SketchTextContourOffsets>? previewContoursRelative;

  const SketchTextView({
    required this.id,
    required this.content,
    required this.font,
    required this.size,
    required this.anchorPointId,
    this.rotationDegrees = 0,
    this.construction = false,
    this.previewContoursRelative,
  });
}

/// Which entity the next tap-to-place commits, while [SketchMode.draw] is
/// active. Selected via the FAB's "Sketch Entities" category. [point] is a
/// standalone, self-terminating placement (no chaining, no construction
/// method choice) - a single tap creates one Point and the tool is done.
enum SketchTool { line, circle, point, rectangle, arc, polygon, slot, ellipse, spline, text }

/// How a tap-to-place Line is built while [SketchTool.line] is active -
/// chosen from [SketchConstructionMethodBar]. [endToEnd] is the original
/// chained start/end placement; [midpoint] instead takes the first tap as
/// the line's center and the second as one end, mirroring it to compute the
/// other end (see [SketchController._clickMidpointLineTool]).
enum LineConstructionMethod { endToEnd, midpoint }

/// Phase 6.1: which axis a Line-in-progress is currently snapped to, or
/// null when its angle is outside [SketchController.lineSnapAngleDegrees]
/// of both. Drives both the dashed ghost preview (snapped to the axis
/// rather than the raw cursor) and, on placement, which constraint (if
/// any) [SketchController._applyLineSnapConstraint] auto-adds.
enum LineSnapAxis { horizontal, vertical }

/// How a tap-to-place Circle is built while [SketchTool.circle] is active.
/// [centerRadius] is the original center-then-radius-point placement;
/// [threePoint] instead takes three points on the circumference and solves
/// for the circle through them (see
/// [SketchController._clickThreePointCircleTool]).
enum CircleConstructionMethod { centerRadius, threePoint }

/// How a tap-to-place Rectangle is built while [SketchTool.rectangle] is
/// active (Stage 15 item 6) - chosen from [SketchConstructionMethodBar],
/// same pattern as [LineConstructionMethod]/[CircleConstructionMethod].
/// [twoCorner] (default) takes two opposite-corner taps and builds an
/// axis-aligned rectangle between them. [centreCorner] takes a center tap
/// (a construction aid only, never a real Point - same role as
/// [SketchController.midpointAnchorX]) then one corner tap, mirroring that
/// corner through the center for the other three. [threePoint] takes two
/// taps for one side (both real Points, like a Line's endpoints) plus a
/// third tap off that side to set the rectangle's height, support
/// non-axis-aligned rectangles - see
/// [SketchController._clickThreePointRectangleTool].
enum RectangleConstructionMethod { twoCorner, centreCorner, threePoint }

/// Stage 15 item 1: a live, dashed preview of the entity that the *next*
/// tap would commit, rendered every frame from [SketchController.cursorX]/
/// [cursorY] - never round-tripped through the backend, since it vanishes
/// the moment a real tap, tool switch, or mode switch happens. One sealed
/// subclass per drawable shape; [SketchController.activeDrawGhost] decides
/// which one (if any) applies right now.
sealed class DrawGhost {
  const DrawGhost();
}

/// Previews a Line from [startX]/[startY] (already a placed Point, or - for
/// [LineConstructionMethod.midpoint] - the mirror image of the cursor
/// through the not-yet-real midpoint anchor) to the cursor.
class LineGhost extends DrawGhost {
  final double startX;
  final double startY;
  final double endX;
  final double endY;

  const LineGhost({required this.startX, required this.startY, required this.endX, required this.endY});
}

/// Previews a Circle centered at [centerX]/[centerY] passing through the
/// cursor at [edgeX]/[edgeY] - the radius is implied by the distance between
/// the two, same as the real Circle that a confirming tap would create.
class CircleGhost extends DrawGhost {
  final double centerX;
  final double centerY;
  final double edgeX;
  final double edgeY;

  const CircleGhost({required this.centerX, required this.centerY, required this.edgeX, required this.edgeY});
}

/// Previews an Arc centered at [centerX]/[centerY], from the already-placed
/// start Point at [startX]/[startY] to [endX]/[endY] - the cursor's
/// position projected onto the circle of radius `dist(center, start)`
/// (see [SketchController._arcDrawGhost]), so the previewed end is always
/// a valid point on the same circle the real Arc would be created on,
/// never the raw cursor position. Only relevant once both center and
/// start are placed - the center-only stage instead reuses [CircleGhost]
/// (see [SketchController._arcDrawGhost]'s own doc comment).
class ArcGhost extends DrawGhost {
  final double centerX;
  final double centerY;
  final double startX;
  final double startY;
  final double endX;
  final double endY;

  const ArcGhost({
    required this.centerX,
    required this.centerY,
    required this.startX,
    required this.startY,
    required this.endX,
    required this.endY,
  });
}

/// Previews a regular Polygon's [vertices] (already in creation order),
/// computed live from [centerX]/[centerY] to the cursor acting as the
/// trial first vertex - see [SketchController._polygonVertices], the same
/// helper [SketchController._clickPolygonTool] uses for the real
/// placement, so the ghost never disagrees with what a confirming tap
/// would create.
class PolygonGhost extends DrawGhost {
  final double centerX;
  final double centerY;
  final List<(double, double)> vertices;

  /// Feedback round: whether to also preview the circumscribed/inscribed
  /// guide circles every vertex/edge-midpoint lands on - see
  /// [SketchController.showPolygonGuideCircles]'s own doc comment.
  final bool showGuideCircles;

  const PolygonGhost({
    required this.centerX,
    required this.centerY,
    required this.vertices,
    this.showGuideCircles = true,
  });
}

/// Previews a Slot's two semicircular caps (around [center1X]/[center1Y]
/// and [center2X]/[center2Y]) and two straight sides connecting [a]-[b]
/// (around center 1) and [c]-[d] (around center 2) - see
/// [SketchController._slotCorners]/[_clickSlotTool] for the CCW-outward-
/// bulge convention that fixes which of [a]/[b] is which.
class SlotGhost extends DrawGhost {
  final double center1X;
  final double center1Y;
  final double center2X;
  final double center2Y;
  final (double, double) a;
  final (double, double) b;
  final (double, double) c;
  final (double, double) d;

  const SlotGhost({
    required this.center1X,
    required this.center1Y,
    required this.center2X,
    required this.center2Y,
    required this.a,
    required this.b,
    required this.c,
    required this.d,
  });
}

/// Previews an Ellipse centered at [centerX]/[centerY] with its major-axis
/// Point at [majorX]/[majorY] (implying both the major radius and the
/// rotation, same as the real Ellipse a confirming tap would create) and
/// [minorRadius] - the perpendicular distance from the cursor to the
/// infinite line through the center along the major axis (see
/// [SketchController._perpendicularDistanceToLine], the same helper Slot's
/// width stage already uses), or `0` while only the center and major point
/// are placed and the cursor hasn't yet set a minor radius.
class EllipseGhost extends DrawGhost {
  final double centerX;
  final double centerY;
  final double majorX;
  final double majorY;
  final double minorRadius;

  const EllipseGhost({
    required this.centerX,
    required this.centerY,
    required this.majorX,
    required this.majorY,
    required this.minorRadius,
  });
}

/// Previews a Rectangle's 4 corners, in the same winding order
/// [SketchController._buildRectangle] would use to create its 4 Lines.
class RectGhost extends DrawGhost {
  final (double, double) corner0;
  final (double, double) corner1;
  final (double, double) corner2;
  final (double, double) corner3;

  const RectGhost({required this.corner0, required this.corner1, required this.corner2, required this.corner3});
}

/// Previews a Spline-in-progress: every through-point already tapped
/// ([throughPoints], real Points), plus the cursor as a trial next
/// through-point - rendered as a smooth [catmullRomPolyline] approximation
/// (see its own doc comment for why it's an approximation, not the exact
/// curve), so the shape reads clearly while placing points instead of the
/// straight-segment "rough outline" Slot/Polygon's own ghosts use. The real
/// smooth shape only exists once [SketchController.finishSpline] actually
/// creates the entity (control-handle positions are a backend
/// implementation detail of `Sketch.add_spline`, not something the client
/// computes ahead of time).
class SplineGhost extends DrawGhost {
  final List<(double, double)> throughPoints;
  final (double, double) cursor;

  const SplineGhost({required this.throughPoints, required this.cursor});
}

/// P17: [ghost]'s own preview outline, tessellated into sketch-local (x, y)
/// polylines - one polyline per open/closed curve making up the ghost (most
/// ghosts are a single polyline; [SlotGhost] is the one exception, at 4).
/// Deliberately returns plain local coordinates rather than 3D world points,
/// so this stays a pure sketch-package function with no dependency on
/// `viewport3d` - the 3D-embedded viewport (`sketch_screen.dart`, which
/// already imports both packages to bridge [SketchController] and
/// `PartViewport`) maps each point through its own `sketchPointToWorld`
/// separately. Segment counts/CCW-arc-sweep convention mirror
/// `viewport3d/sketch_geometry_3d.dart`'s `sketchGeometry3DFrom` (the
/// equivalent tessellation for already-*committed* Circle/Arc/Ellipse
/// entities), so a ghost never reads as a coarser/differently-shaped preview
/// of what a confirming tap would actually create. Rect/Polygon/Slot use a
/// straight-segment "rough outline" (mirroring `sketch_canvas.dart`'s own
/// 2D ghost painter, which does the same); Spline uses [catmullRomPolyline]
/// for the same reason that painter does (see [SplineGhost]'s own doc
/// comment).
List<List<(double, double)>> ghostPolylines(DrawGhost ghost) {
  const circleSegments = 32;
  const arcSegments = 24;

  List<(double, double)> arcPoints(
    double centerX,
    double centerY,
    double radius,
    double startAngle,
    double sweep,
    int segments,
  ) =>
      [
        for (var i = 0; i <= segments; i++)
          (
            centerX + radius * math.cos(startAngle + sweep * i / segments),
            centerY + radius * math.sin(startAngle + sweep * i / segments),
          ),
      ];

  double distance(double x0, double y0, double x1, double y1) => math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2));

  switch (ghost) {
    case LineGhost g:
      return [
        [(g.startX, g.startY), (g.endX, g.endY)],
      ];
    case CircleGhost g:
      final radius = distance(g.centerX, g.centerY, g.edgeX, g.edgeY);
      return [arcPoints(g.centerX, g.centerY, radius, 0, 2 * math.pi, circleSegments)];
    case ArcGhost g:
      final radius = distance(g.centerX, g.centerY, g.startX, g.startY);
      final startAngle = math.atan2(g.startY - g.centerY, g.startX - g.centerX);
      final endAngle = math.atan2(g.endY - g.centerY, g.endX - g.centerX);
      final sweep = normalizeSketchAngle(endAngle - startAngle);
      return [arcPoints(g.centerX, g.centerY, radius, startAngle, sweep, arcSegments)];
    case PolygonGhost g:
      if (g.vertices.isEmpty) return [];
      return [
        [...g.vertices, g.vertices.first],
      ];
    case SlotGhost g:
      final radius1 = distance(g.center1X, g.center1Y, g.a.$1, g.a.$2);
      final radius2 = distance(g.center2X, g.center2Y, g.c.$1, g.c.$2);
      final startAngle1 = math.atan2(g.a.$2 - g.center1Y, g.a.$1 - g.center1X);
      final endAngle1 = math.atan2(g.b.$2 - g.center1Y, g.b.$1 - g.center1X);
      final sweep1 = normalizeSketchAngle(endAngle1 - startAngle1);
      final startAngle2 = math.atan2(g.c.$2 - g.center2Y, g.c.$1 - g.center2X);
      final endAngle2 = math.atan2(g.d.$2 - g.center2Y, g.d.$1 - g.center2X);
      final sweep2 = normalizeSketchAngle(endAngle2 - startAngle2);
      return [
        arcPoints(g.center1X, g.center1Y, radius1, startAngle1, sweep1, arcSegments),
        [g.b, g.c],
        arcPoints(g.center2X, g.center2Y, radius2, startAngle2, sweep2, arcSegments),
        [g.d, g.a],
      ];
    case EllipseGhost g:
      final majorRadius = distance(g.centerX, g.centerY, g.majorX, g.majorY);
      final rotation = math.atan2(g.majorY - g.centerY, g.majorX - g.centerX);
      final cosR = math.cos(rotation);
      final sinR = math.sin(rotation);
      return [
        [
          for (var i = 0; i <= circleSegments; i++)
            () {
              final t = 2 * math.pi * i / circleSegments;
              final localX = majorRadius * math.cos(t);
              final localY = g.minorRadius * math.sin(t);
              return (
                g.centerX + localX * cosR - localY * sinR,
                g.centerY + localX * sinR + localY * cosR,
              );
            }(),
        ],
      ];
    case RectGhost g:
      return [
        [g.corner0, g.corner1, g.corner2, g.corner3, g.corner0],
      ];
    case SplineGhost g:
      return [catmullRomPolyline([...g.throughPoints, g.cursor])];
  }
}

/// P20 follow-up (2D-sketcher feature parity): [ghost]'s own secondary
/// "guide" geometry, tessellated the same way [ghostPolylines] tessellates
/// the shape's primary outline - empty for every ghost except
/// [PolygonGhost] with [PolygonGhost.showGuideCircles] set, which returns
/// the circumscribed circle (through the first vertex) and inscribed circle
/// (through the first edge's midpoint) every regular polygon's own geometry
/// always touches - mirrors `sketch_canvas.dart`'s own `_paintActiveDrawGhost`
/// `PolygonGhost` case exactly (same two distances), just computed in
/// sketch-local space instead of screen space. Kept as its own function
/// (not folded into [ghostPolylines]) since guide geometry is meant to
/// render with a visually distinct (fainter) style from the shape's own
/// outline - the caller renders the two return values through separate
/// GPU nodes/materials for exactly that reason.
List<List<(double, double)>> ghostGuidePolylines(DrawGhost ghost) {
  const circleSegments = 32;
  if (ghost is! PolygonGhost || !ghost.showGuideCircles || ghost.vertices.length < 3) return [];

  double distance(double x0, double y0, double x1, double y1) => math.sqrt(math.pow(x1 - x0, 2) + math.pow(y1 - y0, 2));
  List<(double, double)> circleAt(double radius) => [
        for (var i = 0; i <= circleSegments; i++)
          () {
            final angle = 2 * math.pi * i / circleSegments;
            return (ghost.centerX + radius * math.cos(angle), ghost.centerY + radius * math.sin(angle));
          }(),
      ];

  final v0 = ghost.vertices[0];
  final v1 = ghost.vertices[1];
  final circumradius = distance(ghost.centerX, ghost.centerY, v0.$1, v0.$2);
  final midX = (v0.$1 + v1.$1) / 2;
  final midY = (v0.$2 + v1.$2) / 2;
  final inradius = distance(ghost.centerX, ghost.centerY, midX, midY);
  return [circleAt(circumradius), circleAt(inradius)];
}

/// Normalizes [angle] (radians) into `[0, 2*pi)`.
double normalizeSketchAngle(double angle) {
  const twoPi = 2 * math.pi;
  final wrapped = angle % twoPi;
  return wrapped < 0 ? wrapped + twoPi : wrapped;
}

/// Whether [angle] falls within the counter-clockwise sweep from
/// [startAngle] to [endAngle] (all radians) - the shared definition of "on
/// this arc" used by both hit-testing ([SketchController._entityAt]) and
/// rendering (the canvas's real-Arc/[ArcGhost] painting), so what's drawn
/// and what's tappable never disagree about which of the two possible
/// arcs between two angles is "the" arc. Matches the backend's own
/// CCW-in-sketch-space convention (see the backend's `app.sketch.models.
/// Arc` docstring).
bool angleWithinArcSweep(double angle, double startAngle, double endAngle) {
  final offset = normalizeSketchAngle(angle - startAngle);
  final sweep = normalizeSketchAngle(endAngle - startAngle);
  return offset <= sweep;
}

/// Samples a smooth Catmull-Rom curve through [points] (at least 2, in
/// sketch-space coordinates) into a dense polyline - used for
/// [SplineGhost]'s live preview so it reads as a close approximation of the
/// eventual smooth curve while placing points, rather than a plain
/// straight-segment polyline connecting them literally. On-device feedback:
/// "the spline should preview as I drop points and move the cursor".
///
/// Purely a rendering approximation - the real Spline's own control-handle
/// positions are a backend implementation detail (see [SplineGhost]'s own
/// doc comment) this deliberately doesn't try to reproduce exactly, only to
/// look recognizably similar while the shape is still being placed.
///
/// Standard uniform Catmull-Rom-to-cubic-Bezier conversion: each span
/// between consecutive input points uses its two neighbours to shape the
/// curve, duplicating the first/last point as its own neighbour for the two
/// end spans (the common convention for an open curve). Passes through
/// every input point exactly; [segmentsPerSpan] straight sub-segments are
/// sampled per span (`points.length - 1` spans total).
List<(double, double)> catmullRomPolyline(List<(double, double)> points, {int segmentsPerSpan = 16}) {
  if (points.length < 2) return points;
  final result = <(double, double)>[points.first];
  for (var i = 0; i < points.length - 1; i++) {
    final p0 = points[i == 0 ? 0 : i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = points[i + 2 < points.length ? i + 2 : points.length - 1];
    final b1 = (p1.$1 + (p2.$1 - p0.$1) / 6, p1.$2 + (p2.$2 - p0.$2) / 6);
    final b2 = (p2.$1 - (p3.$1 - p1.$1) / 6, p2.$2 - (p3.$2 - p1.$2) / 6);
    for (var s = 1; s <= segmentsPerSpan; s++) {
      final t = s / segmentsPerSpan;
      final mt = 1 - t;
      final x = mt * mt * mt * p1.$1 + 3 * mt * mt * t * b1.$1 + 3 * mt * t * t * b2.$1 + t * t * t * p2.$1;
      final y = mt * mt * mt * p1.$2 + 3 * mt * mt * t * b1.$2 + 3 * mt * t * t * b2.$2 + t * t * t * p2.$2;
      result.add((x, y));
    }
  }
  return result;
}

/// Stage 13 item 3's feature-flag stub: scaffolds a future user preference
/// to revert tap-to-place back to Stage 12's explicit Click-button
/// placement. Always true for now - flipping it has no effect yet, since
/// nothing in this file branches on it.
const bool kTapToPlace = true;

/// The sketcher's top-level interaction mode (Stage 13 item 5). Distinct
/// from [SketchTool], which only matters while [draw] is active - picking a
/// tool from the FAB's "Sketch Entities" category both sets [SketchTool]
/// and enters [draw]; the FAB's "Dimensions" category enters [dimension]
/// directly, with no further tool choice.
enum SketchMode { select, draw, dimension, trim }

/// The kind of entity a [SketchSelection] refers to. [constraint] covers
/// both Dimensions (Distance/Angle, which carry an editable numeric value)
/// and bare relational Constraints (Vertical/Horizontal, which don't) -
/// the ribbon distinguishes the two via [SketchController.selectedConstraintHasValue].
enum SelectionKind { point, line, circle, constraint, arc, ellipse, spline, text }

/// The single hovered-or-selected entity, idle-state only (see
/// [SketchController.isIdle]) - distinct from the chain-start/circle-center
/// "in progress" highlighting, which applies only during active drawing.
class SketchSelection {
  final SelectionKind kind;
  final String id;

  const SketchSelection({required this.kind, required this.id});

  bool sameAs(SketchSelection other) => kind == other.kind && id == other.id;
}

/// The FAB's own open/closed/expanded state (Stage 13 item 4) - tracked on
/// the controller (rather than as `State` local to the FAB widget) so a
/// full-screen "tap outside closes it" barrier living elsewhere in the
/// widget tree can react to it via the same [SketchController].
enum FabMenuState { closed, categories, sketchEntities }

/// A constraint type the flyout (Stage 13 item 6) can offer for the current
/// multi-entity [SketchController.selectionSet]. [vertical], [horizontal],
/// [coincident], [parallel], [perpendicular], [equalLength], and [collinear]
/// are wired to the backend; [concentric]/[equalRadius]/[tangent] render as
/// greyed-out, non-tappable buttons - this Sketch model has no Arc/Concentric/
/// EqualRadius backend support yet, so the prompt's "1 arc + 1 line ->
/// Tangent" row is offered for "1 circle + 1 line" instead, the closest
/// available analog.
enum ConstraintOptionType {
  vertical,
  horizontal,
  parallel,
  perpendicular,
  equalLength,
  coincident,
  collinear,
  concentric,
  equalRadius,
  tangent,
  radius,
}

class ConstraintOption {
  final ConstraintOptionType type;
  final String label;

  /// Whether the backend actually supports creating this constraint type
  /// yet - only Vertical/Horizontal are, per Stage 13 item 6.
  final bool wired;

  const ConstraintOption({required this.type, required this.label, required this.wired});
}

/// The kind of dimension a [DimensionGhost] previews. [diameter] is always
/// backed by the same radius `DistanceConstraint` as [radius] - see
/// [SketchController.confirmGhostValue]. [linear] is the direct point-to-point
/// distance alongside a pair's [vertical]/[horizontal] components. [lineDistance]
/// (two parallel Lines) and [angle] (two non-parallel Lines) are the
/// dimension-mode revamp's line-pair ghosts - see
/// [SketchController._buildLinePairGhosts].
enum GhostKind { length, linear, vertical, horizontal, radius, diameter, lineDistance, angle }

/// A client-side-only preview of a dimension that doesn't exist as a real
/// Constraint yet (or whose existing value hasn't been confirmed for
/// editing yet) - Stage 13 item 5. Nothing here is sent to the backend
/// until [SketchController.confirmGhostValue] runs; [key] is a stable
/// per-kind identifier the UI uses to address a specific ghost (e.g. which
/// one was tapped, which one to render active/dimmed). Every ghost is
/// either Point-anchored ([pointAId]/[pointBId]) or Line-anchored
/// ([lineAId]/[lineBId]) - never both - per [kind].
class DimensionGhost {
  final String key;
  final GhostKind kind;
  final String? pointAId;
  final String? pointBId;
  final String? lineAId;
  final String? lineBId;

  const DimensionGhost({
    required this.key,
    required this.kind,
    this.pointAId,
    this.pointBId,
    this.lineAId,
    this.lineBId,
  });
}

/// Owns the sketch's client-side state (cursor, points, lines, the
/// in-progress chain) and talks to the backend via [SketchApiClient].
/// The backend's solved point positions are always treated as the source
/// of truth - see [_solveAndTrackDof], called after every mutation.
class SketchController extends ChangeNotifier {
  final SketchApiClient _api;

  /// [localSolverBindings] lets a test inject an already-loaded native
  /// library (e.g. the host desktop build under client/native/slvs/
  /// build-host/) so the in-process solve path itself - not just its
  /// server-round-trip fallback - can be exercised deterministically off
  /// Android. Production code never passes this; [_trySolveDuringDragLocally]
  /// lazily loads the real bundled library on first use instead.
  SketchController({SketchApiClient? api, SlvsNativeBindings? localSolverBindings})
      : _api = api ?? SketchApiClient(),
        _localSolverBindings = localSolverBindings;

  /// Touch drag moves the cursor relatively, scaled by this factor - not
  /// 1:1 with finger position, per the project brief's interaction model.
  static const double touchSensitivity = 0.05;

  /// How close (in sketch units) the cursor must be to a chain's start
  /// Point before a tap is treated as "close the loop" rather than "place
  /// a new point".
  static const double snapRadius = 0.5;

  /// Phase 6.1: how many degrees off true horizontal/vertical a Line's
  /// in-progress angle can be before [_lineSnapAxis] stops reporting a
  /// snap - a few degrees either side of each axis, per the scope doc.
  static const double lineSnapAngleDegrees = 4.0;

  /// The minimum tap hit target, in logical pixels, expressed as a radius.
  /// Entity hit-testing for a discrete tap (select, dimension-target
  /// picking) uses whichever is larger of this - converted to sketch units
  /// via the canvas's current zoom, see [hitRadiusForPixelsPerUnit] - or
  /// [snapRadius], so small/zoomed-out entities stay tappable on touch
  /// without shrinking precise mouse hover.
  ///
  /// Bug-fix round 3: was 22.0 (44px min touch target) - reduced after
  /// on-device feedback that the hit box felt too large, the same
  /// complaint (and roughly the same kind of fix) as the 3D viewport's
  /// `kSelectionHitRadiusPixels`/`kVertexSelectionHitRadiusPixels` unification.
  static const double minTapHitRadiusPixels = 14.0;

  /// How much wider than [minTapHitRadiusPixels]/[snapRadius] a Point's own
  /// hit-test radius is, in [_entityAt] - see that method's doc comment for
  /// why a single point needs the extra forgiveness a line/circle doesn't.
  ///
  /// Reduced from 1.6 after feedback that points were producing too many
  /// false-positive selections (a point's effective hit-circle overlapping
  /// nearby geometry it shouldn't). Still a first-pass value pending
  /// on-device tuning, not a final number.
  static const double pointHitRadiusMultiplier = 1.2;

  /// Converts [minTapHitRadiusPixels] into sketch-space units for the
  /// current zoom level - the canvas passes its [ViewTransform.pixelsPerUnit]
  /// in here before calling [handleCanvasTap].
  double hitRadiusForPixelsPerUnit(double pixelsPerUnit) {
    if (pixelsPerUnit <= 0) return snapRadius;
    return math.max(snapRadius, minTapHitRadiusPixels / pixelsPerUnit);
  }

  String? _sketchId;
  String? get sketchId => _sketchId;

  // Sketcher-roadmap Phase 4.3 v1 - see [adoptSketch]'s own doc comment.
  String? _documentPartId;
  String? _documentSketchFeatureId;

  String? _originPointId;

  /// The id of this Sketch's real backend origin Point (0, 0) - null until
  /// [ensureSketch] completes. Used both to render the origin marker and to
  /// snap onto it, the same way [chainFirstPointId] is used for chain-start
  /// snapping.
  String? get originPointId => _originPointId;

  String? _plane;

  /// This Sketch's reference plane (`'XY'`/`'XZ'`/`'YZ'`) - null until
  /// [ensureSketch]/[adoptSketch] completes. Drives [SketchCanvas]'s small
  /// plane-indicator overlay; otherwise unused, since every Sketch entity
  /// is still stored/solved in its own local 2D coordinates regardless of
  /// which 3D plane it's actually on.
  String? get plane => _plane;

  bool _flip = false;
  int _rotationQuarterTurns = 0;

  /// Sketcher-roadmap Phase 5: this Sketch's own discrete orientation
  /// within [plane] - see the backend's `SketchDto.flip`/
  /// `rotationQuarterTurns` (mirroring `app.sketch.models.Sketch`'s own
  /// fields). Drives [PlaneIndicator]'s axis labels; the flat 2D canvas
  /// itself is unaffected (a Sketch's own Points are always rendered in
  /// local (x, y), regardless of orientation - only the 3D embedding
  /// moves).
  bool get flip => _flip;
  int get rotationQuarterTurns => _rotationQuarterTurns;

  /// Sets this Sketch's orientation via the backend's retrospective-
  /// redefine endpoint - see `SketchApiClient.updateSketchOrientation`'s
  /// own doc comment. A no-op (returns immediately) while [_sketchId] is
  /// unresolved (mirrors every other backend-touching method here).
  Future<void> setOrientation({required bool flip, required int rotationQuarterTurns}) async {
    if (_sketchId == null) return;
    await _runGuarded(() async {
      final updated = await _api.updateSketchOrientation(
        _sketchId!,
        flip: flip,
        rotationQuarterTurns: rotationQuarterTurns,
      );
      _flip = updated.flip;
      _rotationQuarterTurns = updated.rotationQuarterTurns;
    });
  }

  final Map<String, SketchPointView> points = {};
  final Map<String, SketchLineView> lines = {};
  final Map<String, SketchCircleView> circles = {};
  final Map<String, SketchArcView> arcs = {};
  final Map<String, SketchEllipseView> ellipses = {};
  final Map<String, SketchPolygonView> polygons = {};
  final Map<String, SketchSplineView> splines = {};
  final Map<String, SketchTextView> texts = {};

  /// Stage 23b: the sketch-space bounding box of every Point, plus every
  /// Circle's full extent (center +/- radius, since a circle's own Points
  /// are just its center and radius handle, not its rim) - null when the
  /// sketch has no geometry at all. Feeds [SketchViewport.zoomToFit]; has
  /// no opinion on padding or screen size, just the raw geometry extents.
  Rect? get geometryBoundingBox {
    if (points.isEmpty) return null;

    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = -double.infinity;
    double maxY = -double.infinity;

    void include(double x, double y) {
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }

    for (final point in points.values) {
      include(point.x, point.y);
    }
    for (final circle in circles.values) {
      final center = points[circle.centerPointId];
      final radiusPoint = points[circle.radiusPointId];
      if (center == null || radiusPoint == null) continue;
      final radius = math.sqrt(
        math.pow(radiusPoint.x - center.x, 2) + math.pow(radiusPoint.y - center.y, 2),
      );
      include(center.x - radius, center.y - radius);
      include(center.x + radius, center.y + radius);
    }
    for (final arc in arcs.values) {
      final center = points[arc.centerPointId];
      final start = points[arc.startPointId];
      if (center == null || start == null) continue;
      final radius = math.sqrt(math.pow(start.x - center.x, 2) + math.pow(start.y - center.y, 2));
      // Conservative: the full circle's bounding box, same simplification
      // [selectInRect] uses - a superset of the arc's actual (smaller)
      // extent, so zoom-to-fit always shows the whole arc even though it
      // may include a little extra margin from the unswept side.
      include(center.x - radius, center.y - radius);
      include(center.x + radius, center.y + radius);
    }
    for (final ellipse in ellipses.values) {
      final center = points[ellipse.centerPointId];
      if (center == null) continue;
      // Conservative: a square of half-width majorRadius around the
      // center, same simplification the Arc case above uses - the major
      // radius is always >= the actual bounding-box half-width along
      // either axis regardless of rotation, since majorRadius >=
      // minorRadius (enforced at creation/update time).
      final major = points[ellipse.majorPointId];
      if (major == null) continue;
      final majorRadius = math.sqrt(
        math.pow(major.x - center.x, 2) + math.pow(major.y - center.y, 2),
      );
      include(center.x - majorRadius, center.y - majorRadius);
      include(center.x + majorRadius, center.y + majorRadius);
    }
    for (final spline in splines.values) {
      // A cubic Bezier curve never leaves its own control polygon's convex
      // hull, so including every through-point and control-handle Point
      // is an exact (not just conservative) bound - no sampling needed,
      // unlike Ellipse's own approximation above.
      for (final id in [...spline.throughPointIds, ...spline.controlPointIds]) {
        final point = points[id];
        if (point == null) continue;
        include(point.x, point.y);
      }
    }
    for (final text in texts.values) {
      // Every contour's own outer boundary already fully encloses its
      // holes, so only outer points are needed for a bound - exact once
      // the preview has loaded, simply skipped (falls back to whatever
      // the anchor Point alone already contributed above) before then.
      final contours = textAbsoluteContours(text);
      if (contours == null) continue;
      for (final contour in contours) {
        for (final p in contour.outer) {
          include(p.$1, p.$2);
        }
      }
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Every Constraint currently on this Sketch, keyed by id - the dimension
  /// overlays (Stage 12 item 10) read straight from this, and Stage 13's
  /// dimension-ghost confirm flow consults it (via [_findDistanceConstraint])
  /// to decide whether to PATCH an existing value or POST a new Constraint.
  final Map<String, ConstraintDto> constraints = {};

  /// Prompt B item B4: the id of the Point most recently auto-linked to an
  /// existing Point by a [CoincidentConstraint] (see [_clickPointTool]), or
  /// null - a brief, one-shot indicator the canvas highlights, cleared by
  /// the next [handleCanvasTap] (the next user action after the one that
  /// set it).
  String? _autoCoincidentIndicatorPointId;
  String? get autoCoincidentIndicatorPointId => _autoCoincidentIndicatorPointId;

  double cursorX = 0;
  double cursorY = 0;

  SketchTool _activeTool = SketchTool.line;
  SketchTool get activeTool => _activeTool;

  LineConstructionMethod _lineMethod = LineConstructionMethod.endToEnd;
  LineConstructionMethod get lineConstructionMethod => _lineMethod;

  /// Switches how the next Line is built - from
  /// [SketchConstructionMethodBar]. Abandons any in-progress chain/anchor,
  /// same as switching tools entirely, so a half-placed line under one
  /// method is never finished under the other.
  void setLineConstructionMethod(LineConstructionMethod method) {
    _lineMethod = method;
    _resetTransientDrawState();
    notifyListeners();
  }

  CircleConstructionMethod _circleMethod = CircleConstructionMethod.centerRadius;
  CircleConstructionMethod get circleConstructionMethod => _circleMethod;

  /// Switches how the next Circle is built - see
  /// [setLineConstructionMethod]'s doc comment, same reasoning.
  void setCircleConstructionMethod(CircleConstructionMethod method) {
    _circleMethod = method;
    _resetTransientDrawState();
    notifyListeners();
  }

  RectangleConstructionMethod _rectangleMethod = RectangleConstructionMethod.twoCorner;
  RectangleConstructionMethod get rectangleConstructionMethod => _rectangleMethod;

  /// Switches how the next Rectangle is built - see
  /// [setLineConstructionMethod]'s doc comment, same reasoning.
  void setRectangleConstructionMethod(RectangleConstructionMethod method) {
    _rectangleMethod = method;
    _resetTransientDrawState();
    notifyListeners();
  }

  SketchMode _mode = SketchMode.select;
  SketchMode get mode => _mode;

  /// A short label for the sketcher toolbar (Stage 13 item 5: "Show the
  /// current mode clearly in the sketcher toolbar label").
  String get modeLabel {
    switch (_mode) {
      case SketchMode.select:
        return 'Select';
      case SketchMode.draw:
        switch (_activeTool) {
          case SketchTool.line:
            return 'Draw: Line';
          case SketchTool.circle:
            return 'Draw: Circle';
          case SketchTool.point:
            return 'Draw: Point';
          case SketchTool.rectangle:
            return 'Draw: Rectangle';
          case SketchTool.arc:
            return 'Draw: Arc';
          case SketchTool.polygon:
            return 'Draw: Polygon';
          case SketchTool.slot:
            return 'Draw: Slot';
          case SketchTool.ellipse:
            return 'Draw: Ellipse';
          case SketchTool.spline:
            return 'Draw: Spline';
          case SketchTool.text:
            return 'Draw: Text';
        }
      case SketchMode.dimension:
        return 'Dimension';
      case SketchMode.trim:
        return 'Trim/Extend';
    }
  }

  FabMenuState _fabMenu = FabMenuState.closed;
  FabMenuState get fabMenu => _fabMenu;

  void openFabMenu() {
    _fabMenu = FabMenuState.categories;
    notifyListeners();
  }

  void closeFabMenu() {
    _fabMenu = FabMenuState.closed;
    notifyListeners();
  }

  void showSketchEntitiesCategory() {
    _fabMenu = FabMenuState.sketchEntities;
    notifyListeners();
  }

  /// Back navigation from the expanded "Sketch Entities" list to the
  /// top-level category list (Stage 13 item 4).
  void backToFabCategories() {
    _fabMenu = FabMenuState.categories;
    notifyListeners();
  }

  /// Picks a draw tool from the FAB's "Sketch Entities" category - enters
  /// [SketchMode.draw], closes the FAB (Stage 13 item 4: "FAB closes on
  /// tool selection"), and abandons any other in-progress mode state
  /// (selection, dimension picks) so the new tool starts clean.
  void selectDrawTool(SketchTool tool) {
    // Switching away from select mode mid-grab (e.g. tapping a draw tool
    // in the speed dial while a Point/Line is still grabbed via drag mode)
    // would otherwise leave it dangling - grabbing only ever happens in
    // select mode, but nothing previously stopped the *mode* from changing
    // out from under an active grab. Finalizes wherever it currently sits,
    // same as a normal drop.
    dropGrabbedEntity();
    _activeTool = tool;
    _mode = SketchMode.draw;
    _fabMenu = FabMenuState.closed;
    _resetTransientDrawState();
    _selectionSet.clear();
    _ribbonVisible = false;
    _dimensionSelection.clear();
    _ghosts = [];
    _activeGhostKey = null;
    notifyListeners();
  }

  /// FAB → Dimensions: enters [SketchMode.dimension] directly, with no
  /// further tool choice (Stage 13 item 5).
  void enterDimensionMode() {
    // Same dangling-grab guard as [selectDrawTool] - see its comment.
    dropGrabbedEntity();
    _mode = SketchMode.dimension;
    _fabMenu = FabMenuState.closed;
    _resetTransientDrawState();
    _selectionSet.clear();
    _ribbonVisible = false;
    _dimensionSelection.clear();
    _ghosts = [];
    _activeGhostKey = null;
    notifyListeners();
  }

  /// FAB → Trim/Extend (Phase 11): enters [SketchMode.trim] directly, same
  /// no-further-tool-choice shape as [enterDimensionMode] - every tap just
  /// picks a Line to trim/extend, there's nothing to pre-select.
  void enterTrimMode() {
    dropGrabbedEntity();
    _mode = SketchMode.trim;
    _fabMenu = FabMenuState.closed;
    _resetTransientDrawState();
    _selectionSet.clear();
    _ribbonVisible = false;
    _dimensionSelection.clear();
    _ghosts = [];
    _activeGhostKey = null;
    notifyListeners();
  }

  /// The only way back to [SketchMode.select] from [draw] or [dimension] -
  /// driven by tapping the mode label in the toolbar, tapping empty canvas
  /// with nothing selected (dimension mode only - see
  /// [_handleDimensionTap]), or the device back button (Stage 13 item 5).
  void exitToSelectMode() {
    _mode = SketchMode.select;
    _resetTransientDrawState();
    _dimensionSelection.clear();
    _ghosts = [];
    _activeGhostKey = null;
    notifyListeners();
  }

  void _resetTransientDrawState() {
    _chainStartPointId = null;
    _chainFirstPointId = null;
    _circleCenterPointId = null;
    _arcCenterPointId = null;
    _arcStartPointId = null;
    _resetArcSweepTracking();
    _polygonCenterPointId = null;
    _slotCenter1PointId = null;
    _slotCenter2PointId = null;
    _ellipseCenterPointId = null;
    _ellipseMajorPointId = null;
    _splineThroughPointIds.clear();
    _midpointAnchorX = null;
    _midpointAnchorY = null;
    _threePointFirstX = null;
    _threePointFirstY = null;
    _threePointSecondX = null;
    _threePointSecondY = null;
    _rectFirstX = null;
    _rectFirstY = null;
    _rectFirstPointId = null;
    _rectSecondX = null;
    _rectSecondY = null;
    _rectSecondPointId = null;
  }

  String? _chainStartPointId;
  String? _chainFirstPointId;

  String? _circleCenterPointId;

  /// The center Point of a Circle placed but not yet completed (waiting on
  /// the radius-defining tap) - null if no Circle is in progress.
  String? get circleCenterPointId => _circleCenterPointId;
  bool get circleInProgress => _circleCenterPointId != null;

  String? _arcCenterPointId;
  String? _arcStartPointId;

  /// The center/start Points of an Arc placed but not yet completed
  /// (waiting on the end-defining tap) - mirrors [circleCenterPointId],
  /// one tap stage further along. [arcStartPointId] is null while only
  /// the center has been placed (the in-progress ghost is then a plain
  /// [CircleGhost], same as the Circle tool's own first stage - see
  /// [_arcDrawGhost]).
  String? get arcCenterPointId => _arcCenterPointId;
  String? get arcStartPointId => _arcStartPointId;
  bool get arcInProgress => _arcCenterPointId != null;

  /// Net signed angle (radians, unwrapped - can exceed +-pi) the cursor has
  /// swept around [_arcCenterPointId] since [_arcStartPointId] was placed -
  /// positive is counter-clockwise (this app's sketch-space convention, see
  /// [normalizeSketchAngle]'s own doc comment), negative clockwise. Tracked
  /// incrementally (see [_trackArcSweep]) rather than derived from a single
  /// start-to-cursor snapshot, so a small clockwise swing reads as a small
  /// clockwise arc rather than always being (mis)interpreted as its
  /// complementary near-360-degree counter-clockwise sweep, which is what
  /// the backend's always-CCW-from-start-to-end Arc convention would
  /// otherwise produce from just the two endpoint angles alone. On-device
  /// feedback: "the direction of the arc should depend on the direction the
  /// user moves the cursor after placing the first point".
  double _arcSweepAccumulator = 0;
  double? _arcSweepLastAngle;

  /// Updates [_arcSweepAccumulator] for the current cursor position - a
  /// no-op unless an Arc's start Point is already placed and its end isn't
  /// yet (see [_arcStartPointId]). Called from every cursor-movement entry
  /// point ([moveCursorRelative]/[moveCursorAbsoluteScreen]), mirroring how
  /// those are already this class's sole "the cursor visibly moved" hooks.
  void _trackArcSweep() {
    final centerId = _arcCenterPointId;
    final startId = _arcStartPointId;
    if (centerId == null || startId == null) return;
    final center = points[centerId];
    if (center == null) return;
    final dx = cursorX - center.x;
    final dy = cursorY - center.y;
    if (dx * dx + dy * dy < 1e-18) return; // cursor exactly on center: no defined angle
    final angle = math.atan2(dy, dx);
    final lastAngle = _arcSweepLastAngle;
    if (lastAngle != null) {
      // Minimal signed delta, wrapped to (-pi, pi] - accumulating this
      // (rather than just diffing against the start angle each time) is
      // what lets the total tracked sweep exceed a single lap in either
      // direction, and correctly keeps accumulating even as the cursor
      // crosses the atan2 wrap-around seam.
      var delta = angle - lastAngle;
      delta -= 2 * math.pi * (delta / (2 * math.pi)).roundToDouble();
      _arcSweepAccumulator += delta;
    }
    _arcSweepLastAngle = angle;
  }

  void _resetArcSweepTracking() {
    _arcSweepAccumulator = 0;
    _arcSweepLastAngle = null;
  }

  String? _polygonCenterPointId;

  /// The center Point of a Polygon placed but not yet completed (waiting
  /// on the first-vertex-defining tap) - mirrors [circleCenterPointId];
  /// self-terminating in exactly 2 taps, same as
  /// [CircleConstructionMethod.centerRadius].
  String? get polygonCenterPointId => _polygonCenterPointId;
  bool get polygonInProgress => _polygonCenterPointId != null;

  int _polygonSides = 6;

  /// How many sides the next Polygon placement creates - a plain session
  /// setting (like [labelOffsetFor]'s drag offsets), not itself persisted
  /// per-Polygon, so changing it only affects Polygons drawn from then on.
  int get polygonSides => _polygonSides;

  /// Clamped to [3, 20] - fewer than 3 sides isn't a polygon, and there's
  /// no real use case above 20 for a sketch tool (it would just look like
  /// a circle at that point).
  void setPolygonSides(int sides) {
    _polygonSides = sides.clamp(3, 20);
    notifyListeners();
  }

  bool _showPolygonGuideCircles = true;

  /// Feedback round: while defining a Polygon, [_polygonDrawGhost] can
  /// additionally preview the circumscribed circle (through every vertex)
  /// and the inscribed circle (through every edge's midpoint) every real
  /// regular polygon's vertices/midpoints always land on - background
  /// construction-line guides only, toggleable, exactly as requested; not
  /// persisted *geometry* (the placed Polygon is locked onto these same two
  /// circles by its own real solver constraints regardless of whether this
  /// preview is shown - see [_clickPolygonTool]'s own doc comment). This
  /// same flag also gates [_SketchPainter]'s rendering of both guide
  /// circles for every already-placed Polygon in [polygons] (a real,
  /// persisted field - see [SketchPolygonView]'s own doc comment - declared
  /// alongside [arcs]/[ellipses] above), not just the in-progress ghost -
  /// Fix #7's own "toggle after placement" request.
  bool get showPolygonGuideCircles => _showPolygonGuideCircles;

  void togglePolygonGuideCircles() {
    _showPolygonGuideCircles = !_showPolygonGuideCircles;
    notifyListeners();
  }

  String? _slotCenter1PointId;
  String? _slotCenter2PointId;

  /// The two centerline-endpoint Points of a Slot placed but not yet
  /// completed (waiting on the width-defining tap) - one stage further
  /// than a Circle's own single center, mirroring Arc's center-then-start
  /// shape. [slotCenter2PointId] is null while only the first center has
  /// been placed (the in-progress ghost is then a plain [LineGhost]
  /// previewing the centerline - see [_slotDrawGhost]).
  String? get slotCenter1PointId => _slotCenter1PointId;
  String? get slotCenter2PointId => _slotCenter2PointId;
  bool get slotInProgress => _slotCenter1PointId != null;

  String? _ellipseCenterPointId;
  String? _ellipseMajorPointId;

  /// The center/major-axis Points of an Ellipse placed but not yet
  /// completed (waiting on the minor-radius-defining tap) - mirrors
  /// [arcCenterPointId]/[arcStartPointId], one tap stage further than a
  /// Circle's own single center. [ellipseMajorPointId] is null while only
  /// the center has been placed (the in-progress ghost is then a plain
  /// [CircleGhost], same as Arc's own first stage - see
  /// [_ellipseDrawGhost]).
  String? get ellipseCenterPointId => _ellipseCenterPointId;
  String? get ellipseMajorPointId => _ellipseMajorPointId;
  bool get ellipseInProgress => _ellipseCenterPointId != null;

  final List<String> _splineThroughPointIds = [];

  /// The through-point Points tapped so far for a Spline-in-progress, in
  /// tap order - unlike every other draw tool's in-progress state (all
  /// capped at a fixed tap count), this can grow indefinitely; the spline
  /// is only actually created (one entity, all points at once) by
  /// [finishSpline]. Mirrors [LineConstructionMethod.endToEnd]'s chain in
  /// spirit (open-ended repeated taps, an explicit Finish action) but not
  /// in mechanism - a Line chain creates one new Line entity per tap,
  /// while a Spline creates nothing at all until [finishSpline] commits
  /// the whole accumulated list as a single entity.
  List<String> get splineThroughPointIds => List.unmodifiable(_splineThroughPointIds);
  bool get splineInProgress => _splineThroughPointIds.isNotEmpty;

  double? _midpointAnchorX;
  double? _midpointAnchorY;

  /// The first tap's sketch-space location under
  /// [LineConstructionMethod.midpoint] - the line's eventual center, not
  /// itself a real Point - or null if no midpoint-line pick is in progress.
  double? get midpointAnchorX => _midpointAnchorX;
  double? get midpointAnchorY => _midpointAnchorY;
  bool get midpointLineInProgress => _midpointAnchorX != null;

  double? _threePointFirstX;
  double? _threePointFirstY;
  double? _threePointSecondX;
  double? _threePointSecondY;

  /// The taps picked so far under [CircleConstructionMethod.threePoint] (0,
  /// 1, or 2 entries) - none of these are real Points until the third tap
  /// completes the Circle.
  List<(double, double)> get threePointCirclePicksSoFar {
    final picks = <(double, double)>[];
    if (_threePointFirstX != null) picks.add((_threePointFirstX!, _threePointFirstY!));
    if (_threePointSecondX != null) picks.add((_threePointSecondX!, _threePointSecondY!));
    return picks;
  }

  double? _rectFirstX;
  double? _rectFirstY;
  String? _rectFirstPointId;
  double? _rectSecondX;
  double? _rectSecondY;
  String? _rectSecondPointId;

  /// The first tap's sketch-space location under any
  /// [RectangleConstructionMethod] - the picked corner/center for
  /// [RectangleConstructionMethod.twoCorner]/[RectangleConstructionMethod.centreCorner],
  /// or the first side-endpoint for [RectangleConstructionMethod.threePoint] -
  /// or null if no rectangle pick is in progress.
  double? get rectangleAnchorX => _rectFirstX;
  double? get rectangleAnchorY => _rectFirstY;
  bool get rectangleInProgress => _rectFirstX != null;

  /// The second tap's sketch-space location under
  /// [RectangleConstructionMethod.threePoint] only - the first side's other
  /// endpoint, picked before the third (height-defining) tap - or null.
  double? get rectangleSecondX => _rectSecondX;
  double? get rectangleSecondY => _rectSecondY;

  /// The Point id the *next* line segment will start from, or null if no
  /// chain is currently in progress.
  String? get currentChainStartPointId => _chainStartPointId;

  /// The first Point of the current chain - the one a tap can snap back
  /// onto to close the loop.
  String? get chainFirstPointId => _chainFirstPointId;

  bool get chainInProgress => _chainStartPointId != null;

  bool _busy = false;
  bool get busy => _busy;

  String? errorMessage;

  /// The whole-sketch degrees-of-freedom count from the most recent solve -
  /// 0 until the first solve actually runs (e.g. the very first Line/Circle
  /// created), which is accurate for a brand-new Sketch (nothing but a
  /// pinned origin Point has no freedom to report). The backend only ever
  /// reports one number for the entire system, not a per-entity breakdown,
  /// so [isUnderConstrained] - new work package item 8's drag-to-reposition
  /// gate - is necessarily a coarse, whole-sketch approximation: dragging
  /// is offered whenever *something* in the sketch still has slack, not
  /// verified against the specific Point being dragged.
  int _dof = 0;

  /// Bug-fix round 2: whether the most recent solve actually converged.
  /// `dof` is only meaningful when it did - py-slvs can (and does, for a
  /// genuinely redundant-but-consistent constraint set, e.g. two
  /// AtMidpoint constraints on the same Point that are only independent
  /// before a solve resolves them - see the rectangle tool's fix for
  /// exactly this) fail to converge (`result_code != 0`) while still
  /// reporting `dof == 0`, which - trusted blindly - showed a visibly
  /// under-constrained sketch as "fully constrained".
  bool _lastSolveConverged = true;

  /// Whether the backend's own numbers say there's nothing left to solve -
  /// `dof <= 0` (a genuinely negative dof, e.g. from a redundant Constraint
  /// counted twice, is just as "nothing left to solve" as exactly 0) and
  /// the solve actually converged. Deliberately says nothing about
  /// *grounding* - see [isFullyConstrained], which is the one that does.
  bool get _backendConfirmsSolved => _dof <= 0 && _lastSolveConverged;

  /// Whether this Sketch has any drawn entity at all (Lines/Circles) -
  /// bug-fix round: a brand-new, empty Sketch has `dof == 0` too (nothing
  /// but the pinned origin Point has any freedom to report), which used to
  /// make the "fully constrained" indicator light up before the user had
  /// drawn anything. That indicator should only ever appear once there's
  /// actually something to be fully constrained.
  bool get hasGeometry =>
      lines.isNotEmpty ||
      circles.isNotEmpty ||
      arcs.isNotEmpty ||
      ellipses.isNotEmpty ||
      splines.isNotEmpty ||
      texts.isNotEmpty;

  /// Whole-sketch "grounded and fully pinned" - what the padlock icon
  /// (sketch_screen.dart) shows, and (via [isUnderConstrained] below) what
  /// gates whether dragging is offered at all. Phase 3 bug-fix round: a
  /// fully dimensioned rectangle nowhere near the origin solves to
  /// `dof == 0` (confirmed directly against py-slvs - a floating rigid
  /// body's whole-body translate/rotate freedom reads as "no freedom left"
  /// by the same generic-rigidity convention py-slvs itself uses), but a
  /// shape that can still be dragged/rotated as a whole is *not* "fully
  /// constrained" from this app's point of view (raised directly against
  /// an on-device sketch) - so trusting the backend's raw `dof`/`converged`
  /// alone isn't enough here.
  ///
  /// Combines that authoritative backend signal (for "is everything
  /// numerically settled" - topology alone can never answer that, see
  /// dof_analysis.dart's own doc comment) with [SketchRigidity.
  /// isAnyPointGrounded] - just *one* Point anywhere in the Sketch needs
  /// to be grounded, not every individual entity's own Points: grounding
  /// propagates through a whole connected/rigid cluster's union-find (see
  /// [SketchRigidity.isPointGrounded]'s doc comment), and a genuinely
  /// separate, ungrounded piece of geometry can never coexist with a
  /// backend-confirmed `dof <= 0` for the *whole* Sketch - it would always
  /// contribute its own nonzero remaining freedom (confirmed directly
  /// against py-slvs: two disjoint rigid clusters, one grounded and one
  /// not, report `dof: 2`, not `0`). So checking for any single grounded
  /// Point, rather than looping every Line/Circle's own Points
  /// individually, is both simpler and exactly as correct given that
  /// precondition.
  bool get isFullyConstrained => hasGeometry && _backendConfirmsSolved && rigidity.isAnyPointGrounded;

  /// The inverse of [isFullyConstrained] - kept as its own getter (rather
  /// than inlining `!isFullyConstrained` at each call site) since it reads
  /// more naturally at the two drag-gating sites below ("is dragging worth
  /// offering") than the double negative would.
  bool get isUnderConstrained => !isFullyConstrained;

  /// Phase 3's client-side structural DOF/rigidity preview (see
  /// dof_analysis.dart's own doc comment for the full algorithm and its
  /// architecture rule) - recomputed fresh on every access rather than
  /// cached, since it's a fast union-find over this Sketch's local graph
  /// (small by construction - tens to low hundreds of entities) and a
  /// cached-and-invalidated version would need touching every mutation
  /// call site in this file to stay correct, for no real benefit at this
  /// scale. [isUnderConstrained] above stays the whole-sketch, backend-
  /// authoritative signal (built partly from this getter's own
  /// [SketchRigidity.isAnyPointGrounded]); this is the finer-grained,
  /// advisory-only, per-entity one `sketch_canvas.dart` renders from -
  /// together with [backendFlaggedOverConstrainedPointIds]/
  /// [degenerateConstraintPointIds] below (additional red sources
  /// [rigidity] alone can't produce).
  SketchRigidity get rigidity => SketchRigidity.analyze(
        pointIds: points.keys,
        fixedPointIds: {if (_originPointId != null) _originPointId!},
        lineStartPointId: {for (final line in lines.values) line.id: line.startPointId},
        lineEndPointId: {for (final line in lines.values) line.id: line.endPointId},
        constraints: constraints.values,
      );

  /// py-slvs's own report of which Constraints were implicated the last
  /// time a solve failed to converge (empty on a converged solve) - see
  /// `SolveResultDto.solverReportedFailedConstraintIds`'s doc comment.
  List<String> _solverReportedFailedConstraintIds = [];

  /// Phase 3 bug-fix round: the Point ids referenced by whichever
  /// Constraints py-slvs itself blamed for the most recent non-convergent
  /// solve - e.g. a rectangle dimensioned with mutually-impossible width/
  /// height/diagonal values (confirmed directly against py-slvs: this
  /// converges to `converged: false`, and [isUnderConstrained] already
  /// reflects that correctly, but [rigidity] has no way to know *why*,
  /// since it never looks at solved values - see dof_analysis.dart's
  /// KNOWN LIMITATIONS). `sketch_canvas.dart` colours any Line/Circle/
  /// Point referencing one of these ids red, on top of [rigidity]'s own
  /// (purely structural) over-constrained verdict.
  Set<String> get backendFlaggedOverConstrainedPointIds {
    final lineStartPointId = {for (final line in lines.values) line.id: line.startPointId};
    final lineEndPointId = {for (final line in lines.values) line.id: line.endPointId};
    final ids = <String>{};
    for (final constraintId in _solverReportedFailedConstraintIds) {
      final constraint = constraints[constraintId];
      if (constraint == null) continue;
      ids.addAll(describeConstraint(constraint, lineStartPointId, lineEndPointId).pointIds);
    }
    return ids;
  }

  /// Phase 3 bug-fix round: a Line carrying *both* a Vertical and a
  /// Horizontal Constraint is geometrically nonsensical (its two endpoints
  /// would have to share both their x and their y - a zero-length Line) -
  /// confirmed directly against py-slvs that this *does* still converge
  /// (it just collapses the Line to a degenerate point, `dof: 2`, not a
  /// solve failure), so neither [rigidity]'s structural count nor
  /// [backendFlaggedOverConstrainedPointIds] above catches it. Same for a
  /// Line pair carrying both a Parallel and a Perpendicular Constraint
  /// between them - two Lines cannot be both. Both are flagged red
  /// unconditionally, independent of whatever the solver actually does
  /// with them.
  Set<String> get degenerateConstraintPointIds {
    final verticalLineIds = <String>{};
    final horizontalLineIds = <String>{};
    final parallelPairs = <String>{};
    final perpendicularPairs = <String>{};
    String pairKey(String a, String b) => ([a, b]..sort()).join('|');
    for (final constraint in constraints.values) {
      if (constraint is VerticalConstraintDto) verticalLineIds.add(constraint.lineId);
      if (constraint is HorizontalConstraintDto) horizontalLineIds.add(constraint.lineId);
      if (constraint is ParallelConstraintDto) {
        parallelPairs.add(pairKey(constraint.line1Id, constraint.line2Id));
      }
      if (constraint is PerpendicularConstraintDto) {
        perpendicularPairs.add(pairKey(constraint.line1Id, constraint.line2Id));
      }
    }
    final degenerateLineIds = verticalLineIds.intersection(horizontalLineIds);
    final degeneratePairKeys = parallelPairs.intersection(perpendicularPairs);

    final ids = <String>{};
    for (final lineId in degenerateLineIds) {
      final line = lines[lineId];
      if (line == null) continue;
      ids.addAll([line.startPointId, line.endPointId]);
    }
    if (degeneratePairKeys.isNotEmpty) {
      for (final line in lines.values) {
        for (final otherLine in lines.values) {
          if (line.id == otherLine.id) continue;
          if (degeneratePairKeys.contains(pairKey(line.id, otherLine.id))) {
            ids.addAll([line.startPointId, line.endPointId, otherLine.startPointId, otherLine.endPointId]);
          }
        }
      }
    }
    return ids;
  }

  /// Whether [pointId] should be treated as over-constrained by *any* of
  /// the three red sources `sketch_canvas.dart` renders from - [rigidity]'s
  /// own structural verdict, [backendFlaggedOverConstrainedPointIds], or
  /// [degenerateConstraintPointIds]. The single check [beginPointDrag]/
  /// [beginLineDrag] use to refuse a grab, kept in sync with whatever the
  /// canvas colours red so a Point is never draggable while it's visibly
  /// flagged.
  bool isPointForcedOverConstrained(String pointId) =>
      rigidity.isPointOverConstrained(pointId) ||
      backendFlaggedOverConstrainedPointIds.contains(pointId) ||
      degenerateConstraintPointIds.contains(pointId);

  /// Whether dragging [pointId] would be pointless because it has no
  /// freedom left to move into - confirmed directly (raised on-device):
  /// a fully constrained *and* grounded Point should never be movable,
  /// even while some other, unrelated part of the same Sketch still has
  /// freedom. [isFullyConstrained] alone is too coarse for that second
  /// case - it's a whole-Sketch signal, true only once *every* connected
  /// piece of geometry is done - so this also checks [rigidity]'s own
  /// per-cluster verdict ([SketchRigidity.isPointFullyConstrained], which
  /// already requires grounding - see that method's own doc comment) for
  /// [pointId] specifically.
  bool isPointFullyPinned(String pointId) =>
      isFullyConstrained || rigidity.isPointFullyConstrained(pointId);

  /// [anchorPointIds] passes through to [SketchApiClient.solveAndRefresh] -
  /// see that method's doc comment. Defaults to none, which every call site
  /// except the drag-drop endings below wants (equal freedom for every
  /// Point).
  ///
  /// Phase 0 round-trip reduction: this is the finish-tail's single call -
  /// every prior `_solveAndTrackDof` + [_refreshAllPoints] +
  /// [_refreshConstraints] triple collapses into this one request, since
  /// [SketchApiClient.solveAndRefresh] already returns the post-solve
  /// Points/Constraints/profile alongside the solve result itself.
  Future<void> _solveAndTrackDof({List<String> anchorPointIds = const []}) async {
    final result = await _api.solveAndRefresh(_sketchId!, anchorPointIds: anchorPointIds);
    _dof = result.solve.dof;
    _lastSolveConverged = result.solve.converged;
    _solverReportedFailedConstraintIds = result.solve.solverReportedFailedConstraintIds;
    final freshIds = result.points.map((p) => p.id).toSet();
    points
      ..removeWhere((id, _) => !freshIds.contains(id))
      ..addEntries(result.points.map((p) => MapEntry(p.id, SketchPointView(id: p.id, x: p.x, y: p.y))));
    constraints
      ..clear()
      ..addEntries(result.constraints.map((c) => MapEntry(c.id, c)));
    // Same >= 2 filter as [_refreshProfile] (a standalone Circle profile is
    // exactly 2 points: center, radius point).
    _closedProfileFills = result.profile.fillableLoops.where((loop) => loop.pointIds.length >= 2).toList();
    _profileBranchPointIds = result.profile.branchPointIds;
  }

  /// True when the cursor is close enough to the chain's start Point that
  /// the next tap will close the loop using that Point's id, rather than
  /// creating a new coincident Point.
  bool get isHoveringChainStart {
    if (!chainInProgress || _chainFirstPointId == null) return false;
    if (_chainStartPointId == _chainFirstPointId) {
      return false; // First segment - nothing to close onto yet.
    }
    final start = points[_chainFirstPointId];
    if (start == null) return false;
    final dx = cursorX - start.x;
    final dy = cursorY - start.y;
    return (dx * dx + dy * dy) <= snapRadius * snapRadius;
  }

  /// True when the cursor is close enough to the Sketch's real origin Point
  /// that the next tap should land exactly on it, rather than creating a
  /// new coincident Point - the same snap-radius pattern as
  /// [isHoveringChainStart], applied to the origin instead of a chain start.
  bool get isHoveringOrigin {
    final origin = points[_originPointId];
    if (origin == null) return false;
    final dx = cursorX - origin.x;
    final dy = cursorY - origin.y;
    return (dx * dx + dy * dy) <= snapRadius * snapRadius;
  }

  final List<SketchSelection> _selectionSet = [];

  /// Every entity in the current multi-entity selection (Stage 13 item 6) -
  /// empty when nothing is selected. Populated by [_handleSelectTap].
  List<SketchSelection> get selectionSet => List.unmodifiable(_selectionSet);

  /// The first entity in [selectionSet], or null if it's empty - kept for
  /// every Stage 12-era single-selection consumer (ribbon heading, the
  /// canvas's selected-entity highlight to a `.contains`-style check, etc.)
  /// that only ever cared about one entity at a time.
  SketchSelection? get selection => _selectionSet.isEmpty ? null : _selectionSet.first;

  bool _ribbonVisible = false;

  /// Whether the contextual flyout panel should be showing - opened by any
  /// qualifying tap (see [_handleSelectTap]), closed as soon as drawing or
  /// dimensioning starts, since the flyout is for acting on a selection/idle
  /// canvas, not for drawing.
  bool get ribbonVisible => _ribbonVisible;

  /// True while nothing is currently being drawn - no chain in progress, no
  /// circle mid-placement. Hovering/selecting an existing entity, and the
  /// flyout, only ever apply while idle; a bare tap during active drawing
  /// must not trigger either, per the Stage 6 interaction model.
  bool get isIdle =>
      !chainInProgress && !circleInProgress && !arcInProgress && !polygonInProgress && !slotInProgress;

  /// Stage 15 item 1: the live preview of whatever the next tap would
  /// commit, or null when there's nothing in progress to preview (idle, or
  /// [SketchTool.point], which is a single self-terminating tap with
  /// nothing to preview beforehand). Recomputed fresh from [cursorX]/
  /// [cursorY] on every read, so the canvas painter calling this once per
  /// frame is exactly how it stays live.
  DrawGhost? get activeDrawGhost {
    if (_mode != SketchMode.draw) return null;
    switch (_activeTool) {
      case SketchTool.point:
        return null;
      case SketchTool.line:
        return _lineDrawGhost();
      case SketchTool.circle:
        return _circleDrawGhost();
      case SketchTool.rectangle:
        return _rectangleDrawGhost();
      case SketchTool.arc:
        return _arcDrawGhost();
      case SketchTool.polygon:
        return _polygonDrawGhost();
      case SketchTool.slot:
        return _slotDrawGhost();
      case SketchTool.ellipse:
        return _ellipseDrawGhost();
      case SketchTool.spline:
        return _splineDrawGhost();
      case SketchTool.text:
        // A single, self-terminating tap (see _clickTextTool) - same
        // "nothing to preview beforehand" reasoning as SketchTool.point.
        return null;
    }
  }

  /// Spline's tap sequence is open-ended (see [splineThroughPointIds]'s
  /// own doc comment) - the ghost previews every through-point tapped so
  /// far plus the cursor as a trial next one, as a plain straight-segment
  /// polyline (see [SplineGhost]'s own doc comment for why this doesn't
  /// try to preview the real smooth curve). Null before the first
  /// through-point is placed - nothing to preview yet.
  DrawGhost? _splineDrawGhost() {
    if (_splineThroughPointIds.isEmpty) return null;
    final throughPoints = <(double, double)>[];
    for (final id in _splineThroughPointIds) {
      final point = points[id];
      if (point == null) return null;
      throughPoints.add((point.x, point.y));
    }
    return SplineGhost(throughPoints: throughPoints, cursor: (cursorX, cursorY));
  }

  /// Ellipse's tap sequence is center, then major-axis point, then minor
  /// radius - one stage further than Circle's center-then-radius,
  /// mirroring Arc's center-then-start-then-end shape. While only the
  /// center is placed, there's no major radius/rotation yet, so the
  /// preview is a plain [CircleGhost] (identical to Circle/Arc's own
  /// first stage). Once the major-axis point is also placed, the minor
  /// radius is set by the cursor's *perpendicular* distance from the
  /// major axis (see [_perpendicularDistanceToLine], the same helper
  /// Slot's width stage uses) - dragging along the major axis itself
  /// doesn't widen the ellipse, only moving away from it does. Clamped to
  /// never exceed the major radius, so the ghost never previews something
  /// a confirming tap couldn't actually create (`gp_Elips` - and the
  /// backend's own validation - requires majorRadius >= minorRadius).
  DrawGhost? _ellipseDrawGhost() {
    final centerId = _ellipseCenterPointId;
    if (centerId == null) return null;
    final center = points[centerId];
    if (center == null) return null;

    final majorId = _ellipseMajorPointId;
    if (majorId == null) {
      return CircleGhost(centerX: center.x, centerY: center.y, edgeX: cursorX, edgeY: cursorY);
    }
    final major = points[majorId];
    if (major == null) return null;

    final majorRadius = math.sqrt(math.pow(major.x - center.x, 2) + math.pow(major.y - center.y, 2));
    if (majorRadius < 1e-9) return null;
    final rawMinorRadius = _perpendicularDistanceToLine(cursorX, cursorY, center.x, center.y, major.x, major.y);
    if (rawMinorRadius == null || rawMinorRadius < 1e-9) return null;
    return EllipseGhost(
      centerX: center.x,
      centerY: center.y,
      majorX: major.x,
      majorY: major.y,
      minorRadius: math.min(rawMinorRadius, majorRadius),
    );
  }

  /// Slot's tap sequence is centerline-start, then centerline-end, then
  /// width - one stage further than Arc's. While only the first center is
  /// placed, there's no orientation yet, so the preview is a plain
  /// [LineGhost] tracking the trial centerline (reusing that type rather
  /// than inventing a redundant one). Once both centers are placed, the
  /// width is set by the cursor's *perpendicular* distance from the
  /// centerline (see [_perpendicularDistanceToLine]) - dragging along the
  /// centerline itself doesn't widen the slot, only moving away from it
  /// does, matching how a real slot tool measures width.
  DrawGhost? _slotDrawGhost() {
    final c1Id = _slotCenter1PointId;
    if (c1Id == null) return null;
    final c1 = points[c1Id];
    if (c1 == null) return null;

    final c2Id = _slotCenter2PointId;
    if (c2Id == null) {
      return LineGhost(startX: c1.x, startY: c1.y, endX: cursorX, endY: cursorY);
    }
    final c2 = points[c2Id];
    if (c2 == null) return null;

    final radius = _perpendicularDistanceToLine(cursorX, cursorY, c1.x, c1.y, c2.x, c2.y);
    if (radius == null || radius < 1e-9) return null;
    final corners = _slotCorners(c1.x, c1.y, c2.x, c2.y, radius);
    if (corners == null) return null;
    return SlotGhost(
      center1X: c1.x,
      center1Y: c1.y,
      center2X: c2.x,
      center2Y: c2.y,
      a: corners.a,
      b: corners.b,
      c: corners.c,
      d: corners.d,
    );
  }

  /// The unsigned perpendicular distance from ([px], [py]) to the
  /// *infinite* line through ([ax], [ay])/([bx], [by]) - unlike
  /// [_distanceToSegment], this is never clamped to the segment's own
  /// endpoints, since a Slot's width is measured from the centerline's
  /// full extent, not just the nearer end. Null if `a`/`b` coincide (no
  /// line to measure against).
  double? _perpendicularDistanceToLine(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1e-9) return null;
    final cross = (px - ax) * dy - (py - ay) * dx;
    return (cross / length).abs();
  }

  /// The 4 corners of a Slot's boundary - `a`/`b` are the near/far
  /// (relative to center 2) ends of the straight side on one side of the
  /// centerline through ([c1x], [c1y])/([c2x], [c2y]), `c`/`d` the other
  /// side's, each offset [radius] perpendicular to that centerline. Fixed
  /// so that Arc 1 (center 1, sweeping `a` -> `b`) and Arc 2 (center 2,
  /// sweeping `c` -> `d`) each bulge *away* from the other center under
  /// this file's CCW-in-sketch-space Arc convention (see the backend's
  /// `app.sketch.models.Arc` docstring) - [_clickSlotTool] relies on this
  /// exact pairing, verified against a real OCC extrude of the same
  /// construction in the backend's own Arc tests. Null if the centerline
  /// is degenerate (the two centers coincide) or [radius] is zero.
  ({(double, double) a, (double, double) b, (double, double) c, (double, double) d})? _slotCorners(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double radius,
  ) {
    if (radius < 1e-9) return null;
    final dx = c2x - c1x;
    final dy = c2y - c1y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < 1e-9) return null;
    final dirX = dx / length;
    final dirY = dy / length;
    final normalX = -dirY;
    final normalY = dirX;
    return (
      a: (c1x + normalX * radius, c1y + normalY * radius),
      b: (c1x - normalX * radius, c1y - normalY * radius),
      c: (c2x - normalX * radius, c2y - normalY * radius),
      d: (c2x + normalX * radius, c2y + normalY * radius),
    );
  }

  /// Polygon's tap sequence is center, then first vertex - self-terminating
  /// in exactly 2 taps, same as [CircleConstructionMethod.centerRadius].
  /// While only the center is placed, there's no radius/rotation yet, so
  /// there's nothing to preview at all (unlike Arc/Circle, which show a
  /// plain circle first - a Polygon has no meaningful "just a center"
  /// preview shape). Once aiming the first vertex, the full N-vertex
  /// outline previews live via [_polygonVertices].
  DrawGhost? _polygonDrawGhost() {
    final centerId = _polygonCenterPointId;
    if (centerId == null) return null;
    final center = points[centerId];
    if (center == null) return null;
    final dx = cursorX - center.x;
    final dy = cursorY - center.y;
    if (math.sqrt(dx * dx + dy * dy) < 1e-9) return null;
    return PolygonGhost(
      centerX: center.x,
      centerY: center.y,
      vertices: _polygonVertices(center.x, center.y, cursorX, cursorY, _polygonSides),
      showGuideCircles: _showPolygonGuideCircles,
    );
  }

  /// [sides] vertices of a regular polygon centered at ([centerX],
  /// [centerY]), starting at ([firstX], [firstY]) - which fixes both the
  /// circumradius and rotation - and proceeding counter-clockwise at even
  /// `360/sides` degree increments. Shared by [_polygonDrawGhost]'s live
  /// preview and [_clickPolygonTool]'s actual placement, so the Polygon
  /// that gets created always exactly matches whatever the ghost last
  /// showed. Callers are responsible for checking ([firstX], [firstY]) is
  /// not coincident with the center themselves (a zero radius has no
  /// defined rotation) - this always returns [sides] entries, degenerate
  /// (all at center) or not.
  List<(double, double)> _polygonVertices(
    double centerX,
    double centerY,
    double firstX,
    double firstY,
    int sides,
  ) {
    final dx = firstX - centerX;
    final dy = firstY - centerY;
    final radius = math.sqrt(dx * dx + dy * dy);
    final baseAngle = math.atan2(dy, dx);
    return [
      for (var i = 0; i < sides; i++)
        (
          centerX + radius * math.cos(baseAngle + 2 * math.pi * i / sides),
          centerY + radius * math.sin(baseAngle + 2 * math.pi * i / sides),
        ),
    ];
  }

  /// Arc's tap sequence is center, then start, then end - one stage
  /// further than Circle's center-then-radius. While only the center is
  /// placed, the radius isn't fixed yet, so the preview is a plain
  /// [CircleGhost] (identical to Circle's own first stage - reusing that
  /// type rather than inventing a redundant one). Once the start Point is
  /// also placed, the radius is fixed and the preview becomes an
  /// [ArcGhost] whose end is the cursor's direction from center projected
  /// onto that same circle (see [_pointOnCircleTowardCursor]) - never the
  /// raw cursor position, so what's previewed always matches what a
  /// confirming tap would actually create.
  DrawGhost? _arcDrawGhost() {
    final centerId = _arcCenterPointId;
    if (centerId == null) return null;
    final center = points[centerId];
    if (center == null) return null;

    final startId = _arcStartPointId;
    if (startId == null) {
      return CircleGhost(centerX: center.x, centerY: center.y, edgeX: cursorX, edgeY: cursorY);
    }
    final start = points[startId];
    if (start == null) return null;

    final end = _pointOnCircleTowardCursor(center.x, center.y, start.x, start.y);
    if (end == null) return null;
    // On-device feedback: a net clockwise sweep since the start Point was
    // placed (see [_arcSweepAccumulator]) swaps which end reads as
    // "start"/"end" for preview purposes - matching [_clickArcTool]'s own
    // swap - so the ghost always shows the same small clockwise-looking arc
    // a confirming tap would actually create, not its complementary
    // near-360-degree counter-clockwise sweep.
    final sweptClockwise = _arcSweepAccumulator < 0;
    return ArcGhost(
      centerX: center.x,
      centerY: center.y,
      startX: sweptClockwise ? end.$1 : start.x,
      startY: sweptClockwise ? end.$2 : start.y,
      endX: sweptClockwise ? start.x : end.$1,
      endY: sweptClockwise ? start.y : end.$2,
    );
  }

  /// A point on the circle centered at ([centerX], [centerY]) with radius
  /// `dist(center, start)`, in the direction of the current cursor from
  /// center - or null if the radius is degenerate (start coincides with
  /// center) or the cursor is exactly on center (no defined direction).
  /// Shared by [_arcDrawGhost]'s live preview and [_clickArcTool]'s actual
  /// placement, so the Arc that gets created always exactly matches
  /// whatever the ghost last showed.
  (double, double)? _pointOnCircleTowardCursor(double centerX, double centerY, double startX, double startY) {
    final radius = math.sqrt(math.pow(startX - centerX, 2) + math.pow(startY - centerY, 2));
    if (radius < 1e-9) return null;
    final dx = cursorX - centerX;
    final dy = cursorY - centerY;
    final cursorDistance = math.sqrt(dx * dx + dy * dy);
    if (cursorDistance < 1e-9) return null;
    return (centerX + radius * dx / cursorDistance, centerY + radius * dy / cursorDistance);
  }

  DrawGhost? _lineDrawGhost() {
    switch (_lineMethod) {
      case LineConstructionMethod.endToEnd:
        final startId = _chainStartPointId;
        if (startId == null) return null;
        final start = points[startId];
        if (start == null) return null;
        final snapped = _snappedLineEnd(start.x, start.y, cursorX, cursorY);
        return LineGhost(startX: start.x, startY: start.y, endX: snapped.$1, endY: snapped.$2);
      case LineConstructionMethod.midpoint:
        final midX = _midpointAnchorX;
        final midY = _midpointAnchorY;
        if (midX == null || midY == null) return null;
        // Mirrors the real Line _clickMidpointLineTool would create: the
        // cursor becomes one end, its mirror image through the anchor the
        // other.
        final snapped = _snappedLineEnd(midX, midY, cursorX, cursorY);
        return LineGhost(
          startX: 2 * midX - snapped.$1,
          startY: 2 * midY - snapped.$2,
          endX: snapped.$1,
          endY: snapped.$2,
        );
    }
  }

  /// Phase 6.1: the axis a Line from ([x0], [y0]) to the cursor at
  /// ([x1], [y1]) would snap to, or null if its angle is more than
  /// [lineSnapAngleDegrees] from both horizontal and vertical. Degenerate
  /// (near-zero-length) segments never snap - there's no meaningful angle
  /// to measure yet.
  LineSnapAxis? _lineSnapAxis(double x0, double y0, double x1, double y1) {
    final dx = x1 - x0;
    final dy = y1 - y0;
    if (math.sqrt(dx * dx + dy * dy) < 1e-9) return null;
    final angleFromHorizontal = math.atan2(dy.abs(), dx.abs()) * 180 / math.pi;
    if (angleFromHorizontal <= lineSnapAngleDegrees) return LineSnapAxis.horizontal;
    if (angleFromHorizontal >= 90 - lineSnapAngleDegrees) return LineSnapAxis.vertical;
    return null;
  }

  /// The cursor position to actually draw/place the line's free end at,
  /// snapped onto ([x0], [y0])'s horizontal/vertical line through it when
  /// [_lineSnapAxis] reports one - otherwise the raw cursor position.
  (double, double) _snappedLineEnd(double x0, double y0, double x1, double y1) {
    switch (_lineSnapAxis(x0, y0, x1, y1)) {
      case LineSnapAxis.horizontal:
        return (x1, y0);
      case LineSnapAxis.vertical:
        return (x0, y1);
      case null:
        return (x1, y1);
    }
  }

  /// Phase 6.1: which axis the Line tool's current in-progress segment (if
  /// any) is snapped to - the canvas reads this to color the ghost
  /// preview, mirroring the existing point/chain-start snap-highlight
  /// pattern ([isHoveringChainStart]).
  LineSnapAxis? get activeLineSnapAxis {
    if (_mode != SketchMode.draw || _activeTool != SketchTool.line) return null;
    switch (_lineMethod) {
      case LineConstructionMethod.endToEnd:
        final startId = _chainStartPointId;
        if (startId == null) return null;
        final start = points[startId];
        if (start == null) return null;
        return _lineSnapAxis(start.x, start.y, cursorX, cursorY);
      case LineConstructionMethod.midpoint:
        final midX = _midpointAnchorX;
        final midY = _midpointAnchorY;
        if (midX == null || midY == null) return null;
        return _lineSnapAxis(midX, midY, cursorX, cursorY);
    }
  }

  DrawGhost? _circleDrawGhost() {
    switch (_circleMethod) {
      case CircleConstructionMethod.centerRadius:
        final centerId = _circleCenterPointId;
        if (centerId == null) return null;
        final center = points[centerId];
        if (center == null) return null;
        return CircleGhost(centerX: center.x, centerY: center.y, edgeX: cursorX, edgeY: cursorY);
      case CircleConstructionMethod.threePoint:
        final ax = _threePointFirstX;
        final ay = _threePointFirstY;
        if (ax == null || ay == null) return null;
        final bx = _threePointSecondX;
        final by = _threePointSecondY;
        if (bx == null || by == null) {
          return LineGhost(startX: ax, startY: ay, endX: cursorX, endY: cursorY);
        }
        final center = _circumcenter(ax, ay, bx, by, cursorX, cursorY);
        if (center == null) return null;
        return CircleGhost(centerX: center.$1, centerY: center.$2, edgeX: cursorX, edgeY: cursorY);
    }
  }

  DrawGhost? _rectangleDrawGhost() {
    switch (_rectangleMethod) {
      case RectangleConstructionMethod.twoCorner:
        final x0 = _rectFirstX;
        final y0 = _rectFirstY;
        if (x0 == null || y0 == null) return null;
        return RectGhost(
          corner0: (x0, y0),
          corner1: (cursorX, y0),
          corner2: (cursorX, cursorY),
          corner3: (x0, cursorY),
        );
      case RectangleConstructionMethod.centreCorner:
        final cx = _rectFirstX;
        final cy = _rectFirstY;
        if (cx == null || cy == null) return null;
        final dx = cursorX - cx;
        final dy = cursorY - cy;
        return RectGhost(
          corner0: (cursorX, cursorY),
          corner1: (cx - dx, cursorY),
          corner2: (cx - dx, cy - dy),
          corner3: (cursorX, cy - dy),
        );
      case RectangleConstructionMethod.threePoint:
        final ax = _rectFirstX;
        final ay = _rectFirstY;
        if (ax == null || ay == null) return null;
        final bx = _rectSecondX;
        final by = _rectSecondY;
        if (bx == null || by == null) {
          return LineGhost(startX: ax, startY: ay, endX: cursorX, endY: cursorY);
        }
        final abx = bx - ax;
        final aby = by - ay;
        final lenAB = math.sqrt(abx * abx + aby * aby);
        if (lenAB < 1e-9) return null;
        final nx = -aby / lenAB;
        final ny = abx / lenAB;
        final height = (cursorX - ax) * nx + (cursorY - ay) * ny;
        if (height.abs() < 1e-9) return null;
        return RectGhost(
          corner0: (ax, ay),
          corner1: (bx, by),
          corner2: (bx + height * nx, by + height * ny),
          corner3: (ax + height * nx, ay + height * ny),
        );
    }
  }

  /// The Point, Line, or Circle nearest [cursorX]/[cursorY] and within
  /// [radius], or null if nothing is close enough. Points are checked
  /// before Lines/Circles so a Point at a Line's endpoint or a Circle's
  /// center/radius always wins over the entity it belongs to. The shared
  /// core behind both [hoveredEntity] (continuous mouse hover) and every
  /// discrete-tap hit-test (select/dimension mode,
  /// using the larger of [snapRadius] and the 44px touch target - see
  /// [hitRadiusForPixelsPerUnit]).
  SketchSelection? _entityAt(double x, double y, double radius, {bool includeOrigin = false}) {
    // A point is a single discrete target, while a line/circle offers its
    // whole length/circumference to land on - the same radius that's
    // comfortably generous for "near this line" is a much smaller effective
    // target for "within this distance of one exact point". Widen just the
    // points pass by [pointHitRadiusMultiplier] so a point is realistically
    // tappable without needing pixel-perfect placement (mirrors the 3D
    // viewport's wider vertex-vs-edge hit radius, see
    // `kVertexSelectionHitRadiusPixels`).
    final pointRadius = radius * pointHitRadiusMultiplier;
    for (final point in points.values) {
      // The origin is a sketch fixture (always at (0, 0), pinned by the
      // solver - see Sketch.origin_point/solver.py's _FIXED_GROUP), not
      // user geometry: it must stay snappable (see
      // [_existingPointIdNear]/[isHoveringOrigin]) and selectable as a
      // constraint target (e.g. Coincident-to-origin), but [includeOrigin]
      // defaults to false so it's still excluded from drag targets
      // ([dragTargetPointIdAt], which never passes true) - deletion is
      // independently blocked regardless of selectability, see
      // [selectedPointDeleteBlockedReason].
      if (point.id == _originPointId && !includeOrigin) continue;
      final dx = x - point.x;
      final dy = y - point.y;
      if (dx * dx + dy * dy <= pointRadius * pointRadius) {
        return SketchSelection(kind: SelectionKind.point, id: point.id);
      }
    }

    for (final line in lines.values) {
      final start = points[line.startPointId];
      final end = points[line.endPointId];
      if (start == null || end == null) continue;
      if (_distanceToSegment(x, y, start.x, start.y, end.x, end.y) <= radius) {
        return SketchSelection(kind: SelectionKind.line, id: line.id);
      }
    }

    for (final circle in circles.values) {
      final center = points[circle.centerPointId];
      final radiusPoint = points[circle.radiusPointId];
      if (center == null || radiusPoint == null) continue;
      final r = math.sqrt(
        math.pow(radiusPoint.x - center.x, 2) + math.pow(radiusPoint.y - center.y, 2),
      );
      final distanceToCenter = math.sqrt(math.pow(x - center.x, 2) + math.pow(y - center.y, 2));
      if ((distanceToCenter - r).abs() <= radius) {
        return SketchSelection(kind: SelectionKind.circle, id: circle.id);
      }
    }

    for (final arc in arcs.values) {
      final center = points[arc.centerPointId];
      final start = points[arc.startPointId];
      final end = points[arc.endPointId];
      if (center == null || start == null || end == null) continue;
      final r = math.sqrt(math.pow(start.x - center.x, 2) + math.pow(start.y - center.y, 2));
      final distanceToCenter = math.sqrt(math.pow(x - center.x, 2) + math.pow(y - center.y, 2));
      final angle = math.atan2(y - center.y, x - center.x);
      final startAngle = math.atan2(start.y - center.y, start.x - center.x);
      final endAngle = math.atan2(end.y - center.y, end.x - center.x);
      // Off the swept range, the nearest point on the arc is whichever
      // endpoint is closer - not a point on the circle's *other*, unswept
      // arc, which the plain (distanceToCenter - r).abs() check Circle
      // uses would otherwise wrongly treat as "on" this Arc.
      final distanceToArc = angleWithinArcSweep(angle, startAngle, endAngle)
          ? (distanceToCenter - r).abs()
          : math.min(
              math.sqrt(math.pow(x - start.x, 2) + math.pow(y - start.y, 2)),
              math.sqrt(math.pow(x - end.x, 2) + math.pow(y - end.y, 2)),
            );
      if (distanceToArc <= radius) {
        return SketchSelection(kind: SelectionKind.arc, id: arc.id);
      }
    }

    for (final ellipse in ellipses.values) {
      final center = points[ellipse.centerPointId];
      final major = points[ellipse.majorPointId];
      final minor = points[ellipse.minorPointId];
      if (center == null || major == null || minor == null) continue;
      final liveMinorRadius = math.sqrt(math.pow(minor.x - center.x, 2) + math.pow(minor.y - center.y, 2));
      final distanceToEllipse = _approxDistanceToEllipseBoundary(
        x,
        y,
        center.x,
        center.y,
        major.x,
        major.y,
        liveMinorRadius,
      );
      if (distanceToEllipse != null && distanceToEllipse <= radius) {
        return SketchSelection(kind: SelectionKind.ellipse, id: ellipse.id);
      }
    }

    for (final spline in splines.values) {
      final sampled = _sampledSplinePoints(spline);
      if (sampled == null) continue;
      for (var i = 0; i < sampled.length - 1; i++) {
        final a = sampled[i];
        final b = sampled[i + 1];
        if (_distanceToSegment(x, y, a.$1, a.$2, b.$1, b.$2) <= radius) {
          return SketchSelection(kind: SelectionKind.spline, id: spline.id);
        }
      }
    }

    for (final text in texts.values) {
      final contours = textAbsoluteContours(text);
      if (contours == null) continue;
      // Any contour's filled interior counts as a hit (ignoring its own
      // holes - a tap landing exactly inside e.g. "o"'s counter is a rare
      // enough edge case that treating the whole glyph's outer shape as
      // the tap target, same simplification Circle/Ellipse's own ring-
      // only hit-test already makes, is an acceptable v1 approximation).
      for (final contour in contours) {
        if (_pointInPolygon(x, y, contour.outer)) {
          return SketchSelection(kind: SelectionKind.text, id: text.id);
        }
      }
    }

    return null;
  }

  /// An approximate Euclidean distance from ([x], [y]) to an Ellipse's
  /// boundary (center at [centerX]/[centerY], major-axis Point at
  /// [majorX]/[majorY], semi-minor radius [minorRadius]) - exact only when
  /// the ellipse is actually a circle (majorRadius == minorRadius).
  /// Computed by scaling ([x], [y]) into the ellipse's local, unrotated
  /// frame, then measuring how far its *normalized* radial position
  /// (`sqrt((lx/a)^2 + (ly/b)^2)`, 1.0 exactly on the boundary) is from 1,
  /// scaled back by the local radial distance - the same "how far off the
  /// boundary along this ray" idea [_entityAt]'s Circle/Arc cases use
  /// exactly (there, `a == b`, so this reduces to their identical
  /// `(distanceToCenter - r).abs()`). Close enough for hit-testing
  /// tolerance purposes; not used anywhere exactness matters (backend
  /// profile/extrude geometry is unaffected by this approximation). Null
  /// if [x]/[y] is exactly at the center (no defined radial direction) or
  /// the major/minor radius is degenerate.
  double? _approxDistanceToEllipseBoundary(
    double x,
    double y,
    double centerX,
    double centerY,
    double majorX,
    double majorY,
    double minorRadius,
  ) {
    final majorRadius = math.sqrt(math.pow(majorX - centerX, 2) + math.pow(majorY - centerY, 2));
    if (majorRadius < 1e-9 || minorRadius < 1e-9) return null;
    final rotation = math.atan2(majorY - centerY, majorX - centerX);
    final dx = x - centerX;
    final dy = y - centerY;
    final cosR = math.cos(-rotation);
    final sinR = math.sin(-rotation);
    final localX = dx * cosR - dy * sinR;
    final localY = dx * sinR + dy * cosR;
    final radialDistance = math.sqrt(localX * localX + localY * localY);
    if (radialDistance < 1e-9) return null;
    final normalized = math.sqrt(math.pow(localX / majorRadius, 2) + math.pow(localY / minorRadius, 2));
    if (normalized < 1e-9) return null;
    return (radialDistance - radialDistance / normalized).abs();
  }

  /// The entity nearest the cursor and within hit-test range, or null while
  /// not idle, not in [SketchMode.select]/[SketchMode.dimension], or if
  /// nothing is close enough.
  ///
  /// [pixelsPerUnit], when given, uses the exact same zoom-scaled radius as
  /// tap-to-select (see [hitRadiusForPixelsPerUnit]) - bug-fix round 3: this
  /// used to always hard-code [snapRadius] regardless of zoom, while a tap
  /// used the (usually larger, since it's a 44px/now-28px minimum touch
  /// target converted to sketch units) zoom-scaled radius - so what
  /// visually highlighted on hover and what a tap actually selected were
  /// two different sizes, most noticeably when zoomed out. Omitting
  /// [pixelsPerUnit] (as every existing unit test does, since none of them
  /// models a real zoom level) falls back to the flat [snapRadius],
  /// matching those tests' existing expectations unchanged.
  SketchSelection? hoveredEntity([double? pixelsPerUnit]) {
    if (_mode == SketchMode.draw || !isIdle) return null;
    final radius = pixelsPerUnit == null ? snapRadius : hitRadiusForPixelsPerUnit(pixelsPerUnit);
    return _entityAt(cursorX, cursorY, radius, includeOrigin: true);
  }

  /// The id of the existing Line whose midpoint is nearest the given
  /// location and within [radius], or null if none qualifies - the
  /// lookup behind making "Line midpoints usable when constraining or
  /// placing new entities" (new work package). A midpoint is never itself a
  /// stored Point until [_materializeMidpoint] actually creates one.
  String? _nearestLineMidpointId(double x, double y, double radius) {
    String? bestId;
    var bestDistSq = double.infinity;
    for (final line in lines.values) {
      final start = points[line.startPointId];
      final end = points[line.endPointId];
      if (start == null || end == null) continue;
      final mx = (start.x + end.x) / 2;
      final my = (start.y + end.y) / 2;
      final dx = x - mx;
      final dy = y - my;
      final distSq = dx * dx + dy * dy;
      if (distSq <= radius * radius && distSq < bestDistSq) {
        bestDistSq = distSq;
        bestId = line.id;
      }
    }
    return bestId;
  }

  /// The cursor-hovered Line's current midpoint, in sketch-space, or null
  /// if none is within [snapRadius] - drives the canvas's midpoint snap
  /// marker (new work package item 5's discoverability for an otherwise
  /// invisible snap target), reusing [_nearestLineMidpointId]'s own lookup
  /// so the marker and the actual snap behavior never disagree.
  (double, double)? get hoveredLineMidpoint {
    final lineId = _nearestLineMidpointId(cursorX, cursorY, snapRadius);
    if (lineId == null) return null;
    final line = lines[lineId]!;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return null;
    return ((start.x + end.x) / 2, (start.y + end.y) / 2);
  }

  /// Creates (or reuses, if one was already materialized at this exact
  /// location) a real backend Point at [lineId]'s current midpoint, kept
  /// coincident with the true midpoint via a native `at_midpoint` constraint
  /// (see [SketchApiClient.createAtMidpointConstraint]) as the Line's
  /// endpoints are later dragged/constrained. Used for midpoint-snap point
  /// placement only (Stage 16 item 9 moved the line-pair distance ghost off
  /// this path onto a real `LineDistanceConstraint` instead - see
  /// [confirmGhostValue]'s `lineDistance` branch - so a line-to-line
  /// dimension no longer creates any Points).
  Future<String> _materializeMidpoint(String lineId) async {
    final line = lines[lineId]!;
    final start = points[line.startPointId]!;
    final end = points[line.endPointId]!;
    final mx = (start.x + end.x) / 2;
    final my = (start.y + end.y) / 2;
    for (final existing in points.values) {
      final dx = existing.x - mx;
      final dy = existing.y - my;
      if (dx * dx + dy * dy <= 1e-9) return existing.id;
    }
    final created = await _api.createPoint(_sketchId!, mx, my);
    points[created.id] = SketchPointView(id: created.id, x: created.x, y: created.y);
    _pushUndo(() async {
      await _api.deletePoint(_sketchId!, created.id);
      points.remove(created.id);
    });

    // Midpoint: SLVS_C_AT_MIDPOINT — solver maintains point at geometric
    // midpoint of line as endpoints move
    final midpointConstraint = await _api.createAtMidpointConstraint(_sketchId!, created.id, lineId);
    _pushUndo(() async => _api.deleteConstraint(_sketchId!, midpointConstraint.id));

    return created.id;
  }

  /// The id of an existing Point within [snapRadius] of [x]/[y] (closest
  /// one wins), excluding [excludeId] - generalizes the old origin-only
  /// snap so a new entity's endpoint/center/radius point can reuse *any*
  /// nearby existing Point (new work package item 2), not just the origin
  /// (which is itself just another entry in [points], so this subsumes the
  /// old [isHoveringOrigin]-driven behaviour automatically).
  String? _existingPointIdNear(double x, double y, {String? excludeId}) {
    String? bestId;
    var bestDistSq = double.infinity;
    for (final point in points.values) {
      if (point.id == excludeId) continue;
      final dx = x - point.x;
      final dy = y - point.y;
      final distSq = dx * dx + dy * dy;
      if (distSq <= snapRadius * snapRadius && distSq < bestDistSq) {
        bestDistSq = distSq;
        bestId = point.id;
      }
    }
    return bestId;
  }

  /// Stage 15 item 4: the existing Point (if any) that the cursor is
  /// currently snapped to while placing a new entity - wraps
  /// [_existingPointIdNear] so the canvas's hover highlight and the actual
  /// snap a tap would commit to never disagree. Draw-mode only - select/
  /// dimension-mode taps don't place new entities, so there's nothing to
  /// preview snapping onto.
  String? get snapCandidatePointId {
    if (_mode != SketchMode.draw) return null;
    return _existingPointIdNear(cursorX, cursorY);
  }

  /// The resolved tap target for [SketchMode.select]/[SketchMode.dimension]:
  /// a direct Point/Line/Circle hit, or - if the tap instead landed on a
  /// Line's midpoint - a real Point materialized there on the spot (new
  /// work package item 5). Points still win over everything else, same
  /// priority order as plain [_entityAt].
  ///
  /// Bug-fix: the midpoint check below used to pass [radius] (the full,
  /// zoom-scaled tap-hit radius, generous enough to cover an entire short
  /// Line) instead of the tight [snapRadius] every other midpoint check in
  /// this file uses ([hoveredLineMidpoint], [_pointIdAt]) - so a tap
  /// anywhere along a Line within the generous tap radius of its midpoint
  /// silently materialized and selected the midpoint instead of the Line
  /// itself, and disagreed with the hover indicator ([hoveredLineMidpoint]),
  /// which only lit up when genuinely close. This was the confirmed root
  /// cause of "unintended selections of midpoints" - fixed by matching the
  /// tight radius every other midpoint check already uses.
  Future<SketchSelection?> _resolveSelectableAt(double radius) async {
    final direct = _entityAt(cursorX, cursorY, radius, includeOrigin: true);
    if (direct != null && direct.kind == SelectionKind.point) return direct;
    final midpointLineId = _nearestLineMidpointId(cursorX, cursorY, snapRadius);
    if (midpointLineId != null) {
      final pointId = await _materializeMidpoint(midpointLineId);
      return SketchSelection(kind: SelectionKind.point, id: pointId);
    }
    return direct;
  }

  /// Whether the drag-mode FAB is currently toggled on. While true, a tap
  /// picks up whichever Point/Line sits at the cursor (see [SketchCanvas]'s
  /// `_handleDragModeTap`/[dragGrabTargetAt]/[beginPointDrag]/
  /// [beginLineDrag]), a further tap drops it ([dropGrabbedEntity]), and
  /// any movement in between ("swipe", regardless of which touch/click
  /// gesture it's part of) repositions it via [updateGrabbedPosition] -
  /// replacing both the original timing-based "second tap within 350ms
  /// starts a drag" gesture and this controller's own first replacement
  /// (an immediate pointer-down grab), both of which produced false
  /// positives or felt like an awkward continuous hold. Sticky (stays on
  /// until toggled off again), matching every other tool-mode toggle in
  /// this controller (draw tools, construction methods).
  bool _dragModeEnabled = false;
  bool get dragModeEnabled => _dragModeEnabled;

  void toggleDragMode() {
    if (_dragModeEnabled) {
      // Turning drag mode off while something's grabbed would otherwise
      // strand it - the tap that drops it only fires while
      // dragModeEnabled is still true (see SketchCanvas._dispatchTap's
      // drag-mode branch), so it would never get another chance to drop.
      dropGrabbedEntity();
    }
    _dragModeEnabled = !_dragModeEnabled;
    notifyListeners();
  }

  /// New work package item 8's original double-click-drag target resolver:
  /// a directly-hit Point as-is, or - for a Line/Circle, neither of which
  /// is itself a Point - whichever of its constituent Points sits nearer
  /// [x]/[y], since a Line/Circle's shape is entirely defined by the Points
  /// it references and has no position of its own to drag. Returns null if
  /// nothing within [radius] qualifies, the sketch isn't in
  /// [SketchMode.select], or [isUnderConstrained] is false (nothing could
  /// move into anyway, so there's nothing to offer).
  ///
  /// Superseded by [dragGrabTargetAt] for the live drag-mode gesture (a
  /// Line now grabs as its own rigid body instead of collapsing to its
  /// nearest Point) - kept as-is, unused by [SketchCanvas] now, purely so
  /// the existing direct unit tests against it keep passing unchanged.
  String? dragTargetPointIdAt(double x, double y, double radius) {
    if (_mode != SketchMode.select || !isUnderConstrained) return null;
    final hit = _entityAt(x, y, radius);
    if (hit == null) return null;
    switch (hit.kind) {
      case SelectionKind.point:
        return hit.id;
      case SelectionKind.line:
        final line = lines[hit.id]!;
        final start = points[line.startPointId]!;
        final end = points[line.endPointId]!;
        final distToStart = math.pow(x - start.x, 2) + math.pow(y - start.y, 2);
        final distToEnd = math.pow(x - end.x, 2) + math.pow(y - end.y, 2);
        final nearerId = distToStart <= distToEnd ? line.startPointId : line.endPointId;
        // The origin is never a valid drag target (see _entityAt's own
        // exclusion for a direct hit) - if it's the nearer endpoint, there's
        // nothing to offer, not a silent fallback to the farther one.
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.circle:
        final circle = circles[hit.id]!;
        final nearerId = _nearestOf(
          x,
          y,
          [circle.centerPointId, circle.radiusPointId, ...circle.cardinalPointIds],
        );
        // Mirrors the Line case above - the origin is never offered.
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.arc:
        final arc = arcs[hit.id]!;
        final nearerId = _nearestOf(x, y, [arc.centerPointId, arc.startPointId, arc.endPointId]);
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.ellipse:
        final ellipse = ellipses[hit.id]!;
        final nearerId = _nearestOf(x, y, [ellipse.centerPointId, ellipse.majorPointId]);
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.spline:
        final spline = splines[hit.id]!;
        final nearerId = _nearestOf(x, y, [...spline.throughPointIds, ...spline.controlPointIds]);
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.text:
        final text = texts[hit.id]!;
        return text.anchorPointId == _originPointId ? null : text.anchorPointId;
      case SelectionKind.constraint:
        return null;
    }
  }

  /// The id, among [pointIds], whose Point sits nearest ([x], [y]) - shared
  /// by [dragTargetPointIdAt]/[dragGrabTargetAt]'s Circle (center/radius/
  /// four cardinal points) and Arc (center/start/end) cases, among others.
  String _nearestOf(double x, double y, List<String> pointIds) {
    var bestId = pointIds.first;
    var bestDistSq = double.infinity;
    for (final id in pointIds) {
      final point = points[id]!;
      final distSq = math.pow(x - point.x, 2) + math.pow(y - point.y, 2);
      if (distSq < bestDistSq) {
        bestDistSq = distSq.toDouble();
        bestId = id;
      }
    }
    return bestId;
  }

  /// Drag-mode's grab target at ([x], [y]): a directly-hit Point as a
  /// point-grab, or a directly-hit Line as a line-grab (see [beginLineDrag]
  /// - translated as a rigid body so its length/orientation stay fixed
  /// during the drag, unlike a Point's own single-endpoint grab). For a
  /// Circle, which has no rigid-body drag of its own yet, falls back to
  /// whichever of its center/radius Points sits nearer - the same
  /// fallback [dragTargetPointIdAt] used for both Lines and Circles before
  /// Lines got their own grab. Same gating as [dragTargetPointIdAt] (select
  /// mode + under-constrained).
  SketchSelection? dragGrabTargetAt(double x, double y, double radius) {
    if (_mode != SketchMode.select || !isUnderConstrained) return null;
    final hit = _entityAt(x, y, radius);
    if (hit == null) return null;
    switch (hit.kind) {
      case SelectionKind.point:
        return hit;
      case SelectionKind.line:
        return hit;
      case SelectionKind.circle:
        final circle = circles[hit.id]!;
        final nearerId = _nearestOf(
          x,
          y,
          [circle.centerPointId, circle.radiusPointId, ...circle.cardinalPointIds],
        );
        return nearerId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: nearerId);
      case SelectionKind.arc:
        final arc = arcs[hit.id]!;
        final nearerId = _nearestOf(x, y, [arc.centerPointId, arc.startPointId, arc.endPointId]);
        return nearerId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: nearerId);
      case SelectionKind.ellipse:
        final ellipse = ellipses[hit.id]!;
        final nearerId = _nearestOf(x, y, [ellipse.centerPointId, ellipse.majorPointId]);
        return nearerId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: nearerId);
      case SelectionKind.spline:
        final spline = splines[hit.id]!;
        final nearerId = _nearestOf(x, y, [...spline.throughPointIds, ...spline.controlPointIds]);
        return nearerId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: nearerId);
      case SelectionKind.text:
        final text = texts[hit.id]!;
        return text.anchorPointId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: text.anchorPointId);
      case SelectionKind.constraint:
        return null;
    }
  }

  String? _draggingPointId;

  /// [cursorX]/[cursorY] and the dragged Point's own position, both as of
  /// the moment [beginPointDrag] started the drag - the fixed reference
  /// [updatePointDrag] computes every subsequent position from (see its doc
  /// comment for why this, rather than the touch's raw position, is what
  /// gets PATCHed).
  double? _dragOriginCursorX;
  double? _dragOriginCursorY;
  double? _dragOriginPointX;
  double? _dragOriginPointY;

  /// Bug fix: dragging used to move only the dragged Point (an unconstrained
  /// PATCH) and never re-solve until the drag ended - one big single-step
  /// re-solve, anchored at wherever the cursor was finally dropped. For a
  /// tightly-coupled constraint system (e.g. a regular Polygon's equal-
  /// length/equal-radius/angle chain) that single big jump gives Newton's
  /// method no reason to stay on the same continuous branch it started on,
  /// so it can converge to a different, also-locally-valid but visually
  /// wrong root (a folded/self-intersecting polygon, a flipped dimension) -
  /// reported on-device as shapes "breaking" mid-drag. [updatePointDrag] now
  /// also re-solves periodically *during* the drag (throttled - a real
  /// network round trip per solve, not free), each step seeded from the
  /// last converged state, so it can't jump distant roots. [_lastDragSolveAt]
  /// resets per-drag so a fresh drag always solves on its first move rather
  /// than inheriting a previous drag's throttle timing; [_dragSolveInFlight]
  /// drops (rather than queues) a new solve while one's still outstanding,
  /// the same "stale requests are dropped, not queued" tradeoff every other
  /// unsequenced PATCH in this file already makes.
  DateTime? _lastDragSolveAt;
  bool _dragSolveInFlight = false;
  static const _dragSolveThrottle = Duration(milliseconds: 120);

  /// The Point currently being live-dragged via [beginPointDrag], or null if
  /// no drag is in progress - the canvas reads this to suppress its normal
  /// hover/cursor-move handling while a drag owns pointer-move events.
  String? get draggingPointId => _draggingPointId;

  /// The Polygon [pointId] is a vertex of, or null if it isn't one -
  /// [beginPointDrag]/[updatePointDrag]/[endPointDrag] use this to
  /// reinterpret a vertex drag as a circumradius-dimension edit rather than
  /// a free geometric move (see [updatePointDrag]'s own doc comment for
  /// why): every vertex, not just index 0, resizes the same shared circle.
  SketchPolygonView? _polygonForVertex(String pointId) {
    for (final polygon in polygons.values) {
      if (polygon.vertexPointIds.contains(pointId)) return polygon;
    }
    return null;
  }

  /// [polygon]'s one real circumradius `DistanceConstraint` (center to
  /// vertex 0) - identified the same way the controller's own tests do,
  /// by its two endpoint Points, since [SketchPolygonView] itself doesn't
  /// carry the constraint id (the API response only exposes the derived
  /// [PolygonDto.radius] value, not which Constraint produced it).
  DistanceConstraintDto? _polygonRadiusConstraint(SketchPolygonView polygon) {
    for (final constraint in constraints.values) {
      if (constraint is DistanceConstraintDto &&
          constraint.pointAId == polygon.centerPointId &&
          constraint.pointBId == polygon.vertexPointIds[0]) {
        return constraint;
      }
    }
    return null;
  }

  /// The confirmed (no longer provisional) circumradius `DistanceConstraint`
  /// for the Polygon [pointId] is a vertex of, or null if [pointId] isn't a
  /// Polygon vertex at all, or its Polygon's radius is still provisional -
  /// see [updatePointDrag]'s own doc comment for why only the *confirmed*
  /// case is reinterpreted as a dimension edit; a still-provisional radius
  /// already resizes correctly under an ordinary raw drag (it removes zero
  /// DOF), so bypassing the ordinary drag gating/behaviour for it would be
  /// both unnecessary and (per the bug this fixes) actively harmful.
  DistanceConstraintDto? _confirmedPolygonRadiusConstraint(String pointId) {
    final polygon = _polygonForVertex(pointId);
    if (polygon == null) return null;
    final radiusConstraint = _polygonRadiusConstraint(polygon);
    if (radiusConstraint == null || radiusConstraint.provisional) return null;
    return radiusConstraint;
  }

  /// Starts a live drag of [pointId] (new work package item 8) - false (and
  /// no-op) if busy, there's no sketch yet, or a label drag is already in
  /// progress (mutually exclusive with [beginLabelDrag] - Stage 15 item 2),
  /// since every other guard ([dragTargetPointIdAt]'s mode/dof checks)
  /// already ran by the time the canvas calls this.
  ///
  /// Only ever records where the drag started - [_dragOriginCursorX]/
  /// [_dragOriginCursorY] (the controller's own cursor, not this event's raw
  /// touch position) and [_dragOriginPointX]/[_dragOriginPointY] (the
  /// Point's position right now). It must never itself move the Point: a
  /// double-tap's second pointer-down typically lands a few pixels off the
  /// Point's actual (snapped) position (within the touch hit-radius, not
  /// pixel-exact), so issuing any PATCH here - to the touch position rather
  /// than a delta from it - would visibly teleport the Point on tap-down,
  /// before the user has dragged at all. See [updatePointDrag].
  bool beginPointDrag(String pointId) {
    if (_busy || _sketchId == null || !points.containsKey(pointId)) return false;
    if (_draggingLabelId != null || _draggingLineId != null) return false;
    // A Polygon vertex drag against an already-confirmed circumradius
    // dimension is reinterpreted as editing that dimension (see
    // [updatePointDrag]'s own doc comment), not a free geometric move - the
    // over/fully-constrained gating below exists to refuse drags that have
    // nowhere to go, which doesn't apply to changing a dimension's target
    // value (same as any other confirmed dimension, e.g. [confirmGhostValue],
    // never checks isFullyConstrained either). A still-provisional radius
    // isn't a dimension yet, so it goes through the ordinary gating below
    // like any other free Point.
    if (_confirmedPolygonRadiusConstraint(pointId) == null) {
      // Phase 3 (3.2): a Point in an over-constrained cluster already has a
      // redundant/conflicting Constraint pinning it - dragging it wouldn't
      // move it anywhere the solver would actually let it stay, so refuse
      // the grab rather than start a drag that's guaranteed to snap back.
      // sketch_canvas.dart colors these Points red so this isn't a silent
      // no-op. Checks every red source (see [isPointForcedOverConstrained]),
      // not just [rigidity]'s own structural verdict.
      if (isPointForcedOverConstrained(pointId)) return false;
      // Bug-fix round: a fully constrained *and* grounded Point (rendered
      // green - see [isPointFullyPinned]'s own doc comment) has nowhere
      // left to move into either, same reasoning as the over-constrained
      // case above but for the opposite ("done", not "broken") reason.
      if (isPointFullyPinned(pointId)) return false;
    }
    final point = points[pointId]!;
    _draggingPointId = pointId;
    _dragOriginCursorX = cursorX;
    _dragOriginCursorY = cursorY;
    _dragOriginPointX = point.x;
    _dragOriginPointY = point.y;
    _lastDragSolveAt = null;
    notifyListeners();
    return true;
  }

  /// Live-updates the dragged Point's position - called on every
  /// pointer-move while a [beginPointDrag] drag is active, with [x]/[y]
  /// being wherever the touch/cursor currently is in sketch space (same
  /// convention [beginPointDrag]'s [cursorX]/[cursorY] use). The Point is
  /// moved by the *delta* between [x]/[y] and [_dragOriginCursorX]/
  /// [_dragOriginCursorY] applied to [_dragOriginPointX]/[_dragOriginPointY]
  /// - never snapped directly to [x]/[y] - so it tracks the same offset from
  /// the touch throughout the drag that it started with, rather than
  /// jumping to be exactly under the touch on the first move (see
  /// [beginPointDrag]'s doc comment for why that offset exists at all).
  ///
  /// PATCHes the backend immediately rather than buffering until release,
  /// so every other on-canvas reader (the entity itself, any dimension
  /// overlay anchored to it) tracks the drag the same way it tracks any
  /// other backend-confirmed position - no separate "ghost position"
  /// concept. The dragged Point itself always shows the raw dragged
  /// position, exactly under the touch; every *other* Point is periodically
  /// re-solved into place as the drag continues (throttled - see
  /// [_maybeSolveDuringDrag]), rather than staying frozen until
  /// [endPointDrag]'s single final solve - the fix for constraint systems
  /// (a regular Polygon's equal-length/equal-radius/angle chain especially)
  /// that could converge to a different, wrong-looking root when solved as
  /// one big jump instead of many small ones. Rapid out-of-order responses
  /// are accepted silently, same tradeoff as every other unsequenced PATCH
  /// in this file.
  ///
  /// Task #94 (deferred item): dragging a Polygon vertex is reinterpreted
  /// as editing its circumradius dimension rather than moving the vertex
  /// freely, but ONLY once its own real circumradius `DistanceConstraint`
  /// is already confirmed (no longer provisional - see `DistanceConstraint.
  /// provisional`'s own doc comment) - a confirmed constraint actively
  /// resists a raw point PATCH exactly like any other confirmed dimension
  /// would, so a plain drag would just fight it back to the old size
  /// instead of resizing the shape. Bug fix: while still provisional (the
  /// common case - most Polygons are never explicitly dimensioned), the
  /// constraint already removes zero DOF, so an ordinary raw drag already
  /// resizes it correctly on its own; routing it through
  /// [_maybeUpdatePolygonRadiusDuringDrag] regardless used to *confirm* the
  /// constraint on every single drag (`update_constraint_value`'s own
  /// documented side effect), silently turning a "let me nudge this to look
  /// right" gesture into a real, DOF-removing size dimension the user never
  /// asked to set - which then over-constrains the sketch the moment they
  /// add a second, explicit dimension (e.g. an across-flats
  /// `LineDistanceConstraint` between two opposite edges) on top of it.
  /// See [_maybeUpdatePolygonRadiusDuringDrag].
  Future<void> updatePointDrag(double x, double y) async {
    final pointId = _draggingPointId;
    final originCursorX = _dragOriginCursorX;
    final originCursorY = _dragOriginCursorY;
    final originPointX = _dragOriginPointX;
    final originPointY = _dragOriginPointY;
    if (pointId == null ||
        _sketchId == null ||
        originCursorX == null ||
        originCursorY == null ||
        originPointX == null ||
        originPointY == null) {
      return;
    }
    final newX = originPointX + (x - originCursorX);
    final newY = originPointY + (y - originCursorY);

    final radiusConstraint = _confirmedPolygonRadiusConstraint(pointId);
    if (radiusConstraint != null) {
      final polygon = _polygonForVertex(pointId)!;
      final center = points[polygon.centerPointId];
      if (center == null) return;
      final newRadius = math.sqrt(math.pow(newX - center.x, 2) + math.pow(newY - center.y, 2));
      if (newRadius < 1e-9) return;
      // Speculative local move for immediate 1:1 cursor tracking, same as
      // the raw-PATCH case below - the throttled radius update then pulls
      // every vertex (including this one) onto the actual resized circle.
      points[pointId] = SketchPointView(id: pointId, x: newX, y: newY);
      notifyListeners();
      _maybeUpdatePolygonRadiusDuringDrag(radiusConstraint.id, newRadius, () => _draggingPointId == pointId);
      return;
    }

    try {
      final updated = await _api.updatePoint(_sketchId!, pointId, newX, newY);
      // [endPointDrag] clears _draggingPointId synchronously before it solves
      // and refreshes - if this PATCH straggles past that point (e.g. a
      // pointer-move fired right before pointer-up), applying it here would
      // clobber the just-solved, constraint-satisfying position with this
      // stale unconstrained drag position, which is exactly what made a
      // constraint (e.g. Vertical) look violated until some unrelated later
      // mutation forced a fresh refresh.
      if (_draggingPointId != pointId) return;
      points[pointId] = SketchPointView(id: updated.id, x: updated.x, y: updated.y);
      notifyListeners();
      // Sketcher restructure Phase 1 (Milestone E): the mid-drag reflow of
      // every *other* Point tries the in-process solver first - no network
      // round trip, so no throttle needed. Falls back to the existing
      // throttled server solve whenever the native library isn't
      // available (only bundled on Android today) or the local solve
      // throws for any reason, so this narrow landing can never produce
      // worse behaviour than before it existed, only better when it works.
      if (!_trySolveDuringDragLocally([pointId])) {
        _maybeSolveDuringDrag([pointId], () => _draggingPointId == pointId);
      }
    } on ApiException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  SlvsNativeBindings? _localSolverBindings;
  bool _localSolverUnavailable = false;

  /// Attempts the in-process local solve for [updatePointDrag]'s mid-drag
  /// reflow - returns false (never partially applied) if the native
  /// library isn't loadable or the solve itself throws, so the caller can
  /// fall back to the server round trip unconditionally. Deliberately
  /// scoped to the single-Point-drag path only (sketcher restructure plan
  /// Phase 1 item 4's "land behind one narrow, real interaction path
  /// first") - [updateLineDrag]'s own mid-drag solve is untouched.
  bool _trySolveDuringDragLocally(List<String> anchorPointIds) {
    var bindings = _localSolverBindings;
    if (bindings == null && !_localSolverUnavailable) {
      try {
        bindings = loadSlvsBindings();
        _localSolverBindings = bindings;
      } catch (_) {
        _localSolverUnavailable = true;
      }
    }
    if (bindings == null) return false;

    try {
      final pointXY = <String, (double, double)>{
        for (final entry in points.entries) entry.key: (entry.value.x, entry.value.y),
      };
      final lineEndpoints = <String, (String, String)>{
        for (final entry in lines.entries) entry.key: (entry.value.startPointId, entry.value.endPointId),
      };
      final result = solveSketchLocally(
        bindings: bindings,
        points: pointXY,
        constraints: constraints.values.toList(),
        lineEndpoints: (id) => lineEndpoints[id]!,
        originPointId: _originPointId,
        anchorPointIds: anchorPointIds.toSet(),
      );
      final anchorSet = anchorPointIds.toSet();
      for (final entry in result.solvedPoints.entries) {
        if (anchorSet.contains(entry.key)) continue;
        final (x, y) = entry.value;
        points[entry.key] = SketchPointView(id: entry.key, x: x, y: y);
      }
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fires a throttled solve anchored at [anchorPointIds] (the Point(s)
  /// currently being dragged - one for [updatePointDrag], both endpoints for
  /// [updateLineDrag]) - a no-op if one already ran within
  /// [_dragSolveThrottle], or one is still in flight (dropped, not queued,
  /// so a slow network never leaves a backlog of stale solves to work
  /// through after the user has already moved on). Deliberately
  /// fire-and-forget (not awaited by the caller) so a slow solve never
  /// delays the dragged Point(s)' own 1:1 cursor tracking. [isStillActive]
  /// re-checks that the same drag is still the one in progress once the
  /// (possibly slow) network round trip completes.
  void _maybeSolveDuringDrag(List<String> anchorPointIds, bool Function() isStillActive) {
    if (_dragSolveInFlight) return;
    final now = DateTime.now();
    if (_lastDragSolveAt != null && now.difference(_lastDragSolveAt!) < _dragSolveThrottle) return;
    _lastDragSolveAt = now;
    _dragSolveInFlight = true;
    unawaited(_solveDuringDrag(anchorPointIds, isStillActive));
  }

  Future<void> _solveDuringDrag(List<String> anchorPointIds, bool Function() isStillActive) async {
    try {
      await _api.solve(_sketchId!, anchorPointIds: anchorPointIds);
      // The drag may have ended (or moved to different geometry) while this
      // request was in flight - stale results are dropped, same convention
      // as every unsequenced PATCH in this file.
      if (!isStillActive()) return;
      final fresh = await _api.listPoints(_sketchId!);
      if (!isStillActive()) return;
      final anchorSet = anchorPointIds.toSet();
      for (final p in fresh) {
        // The anchored Point(s) keep tracking the cursor exactly (see
        // [updatePointDrag]/[updateLineDrag]'s own doc comments) - only
        // every *other* Point reflows here.
        if (anchorSet.contains(p.id)) continue;
        points[p.id] = SketchPointView(id: p.id, x: p.x, y: p.y);
      }
      notifyListeners();
    } on ApiException catch (_) {
      // Best-effort: a failed mid-drag solve just means the rest of the
      // Sketch doesn't reflow this tick - the drag's own final solve on
      // release is authoritative regardless of what happens here.
    } finally {
      _dragSolveInFlight = false;
    }
  }

  /// [_maybeSolveDuringDrag]'s counterpart for a Polygon-vertex drag (see
  /// [updatePointDrag]'s own doc comment) - throttled/dropped-not-queued the
  /// same way, sharing [_dragSolveInFlight]/[_lastDragSolveAt] with the
  /// regular drag path so the two can never both be in flight at once (a
  /// drag is always either a Polygon-vertex radius edit or a plain point
  /// move, never both).
  void _maybeUpdatePolygonRadiusDuringDrag(String constraintId, double radius, bool Function() isStillActive) {
    if (_dragSolveInFlight) return;
    final now = DateTime.now();
    if (_lastDragSolveAt != null && now.difference(_lastDragSolveAt!) < _dragSolveThrottle) return;
    _lastDragSolveAt = now;
    _dragSolveInFlight = true;
    unawaited(_updatePolygonRadiusDuringDrag(constraintId, radius, isStillActive));
  }

  /// Unlike [_solveDuringDrag] (which keeps the dragged Point(s) themselves
  /// exactly under the touch and only reflows every *other* Point), every
  /// vertex here - including the dragged one - takes whatever position the
  /// resize actually solved to: this is a dimension edit, not a free move,
  /// so the vertex belongs wherever the newly-sized circle actually put it,
  /// not wherever the cursor happens to be.
  Future<void> _updatePolygonRadiusDuringDrag(
    String constraintId,
    double radius,
    bool Function() isStillActive,
  ) async {
    try {
      await _api.updateConstraintValue(_sketchId!, constraintId, radius);
      if (!isStillActive()) return;
      final fresh = await _api.listPoints(_sketchId!);
      if (!isStillActive()) return;
      for (final p in fresh) {
        points[p.id] = SketchPointView(id: p.id, x: p.x, y: p.y);
      }
      notifyListeners();
    } on ApiException catch (_) {
      // Best-effort, same tradeoff as [_solveDuringDrag].
    } finally {
      _dragSolveInFlight = false;
    }
  }

  /// Ends the current Point drag (if any) and re-solves from the dropped
  /// position, same backend-is-truth refresh as every other mutation - any
  /// remaining constraints (e.g. a Line this Point anchors staying the
  /// right length) settle here rather than during the drag itself.
  ///
  /// Task #94 (deferred item): a Polygon-vertex drag against an already-
  /// confirmed circumradius dimension (see [updatePointDrag]'s own doc
  /// comment for why only the confirmed case is reinterpreted) ends by
  /// confirming that dimension at the dropped radius, instead of pinning
  /// the dropped position directly - undo restores the dimension's old
  /// value, not the vertex's old (x, y), same pattern [confirmGhostValue]
  /// already uses for every other confirmed dimension.
  Future<void> endPointDrag() async {
    final pointId = _draggingPointId;
    if (pointId == null) return;
    final originX = _dragOriginPointX!;
    final originY = _dragOriginPointY!;
    final droppedPoint = points[pointId]!;
    _draggingPointId = null;
    _dragOriginCursorX = null;
    _dragOriginCursorY = null;
    _dragOriginPointX = null;
    _dragOriginPointY = null;

    final radiusConstraint = _confirmedPolygonRadiusConstraint(pointId);
    if (radiusConstraint != null) {
      final polygon = _polygonForVertex(pointId)!;
      final center = points[polygon.centerPointId];
      await _runGuarded(() async {
        if (center != null) {
          final newRadius = math.sqrt(math.pow(droppedPoint.x - center.x, 2) + math.pow(droppedPoint.y - center.y, 2));
          if (newRadius >= 1e-9) {
            final oldRadius = radiusConstraint.distance;
            await _api.updateConstraintValue(_sketchId!, radiusConstraint.id, newRadius);
            _pushUndo(() async => _api.updateConstraintValue(_sketchId!, radiusConstraint.id, oldRadius));
          }
        }
        await _solveAndTrackDof();
      });
      return;
    }

    await _runGuarded(() async {
      _pushUndo(() async {
        final restored = await _api.updatePoint(_sketchId!, pointId, originX, originY);
        points[pointId] = SketchPointView(id: restored.id, x: restored.x, y: restored.y);
      });
      // Dropping a dragged Point onto another existing Point should link
      // them with a CoincidentConstraint, same as [_clickPointTool]'s
      // placement-time snap (Prompt B item B4) - previously only the
      // placement path did this, so dragging a Point onto another silently
      // did nothing. Checked against the position it was actually dropped
      // at (before any solve moves it), same convention as every other
      // proximity-snap check in this file.
      await _autoCoincideIfNear(pointId, droppedPoint.x, droppedPoint.y);
      // Anchored so the just-dropped Point stays exactly where the user put
      // it and the rest of the Sketch settles around it, instead of every
      // Point (including this one) being equally free to move - Phase 2 of
      // docs/sketcher-overhaul-scope.md. Also gives the auto-coincide above
      // its intuitive result: the *other*, pre-existing Point moves to meet
      // this one, not the other way around.
      await _solveAndTrackDof(anchorPointIds: [pointId]);
    });
  }

  String? _draggingLineId;
  double? _dragOriginLineStartX;
  double? _dragOriginLineStartY;
  double? _dragOriginLineEndX;
  double? _dragOriginLineEndY;

  /// The Line currently being live-dragged via [beginLineDrag], or null -
  /// mirrors [draggingPointId] for the drag-mode grab/drop gesture's
  /// rigid-body Line case (see sketch_canvas.dart's drag-mode dispatch).
  String? get draggingLineId => _draggingLineId;

  /// Starts a live rigid-body drag of [lineId]: both endpoints translate by
  /// the same delta on every subsequent [updateLineDrag] call, so the
  /// Line's length/orientation stay fixed for the duration of the drag
  /// (only [endLineDrag]'s solve may change them again, via whatever other
  /// Constraints apply) - same origin-tracking pattern as [beginPointDrag].
  bool beginLineDrag(String lineId) {
    if (_busy || _sketchId == null) return false;
    if (_draggingPointId != null || _draggingLabelId != null) return false;
    final line = lines[lineId];
    if (line == null) return false;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return false;
    // On-device feedback (bug fix): a Polygon's own edge Line is two of its
    // vertices, both anchored to the same fixed center by their own
    // equal-radius Constraint. This gesture's ordinary rigid-body
    // translation (both endpoints by the same delta) can't generally keep
    // both on that circle - unlike a pure rotation about the center, a
    // straight-line translation of a chord almost never does - so it fights
    // the equal-radius/equal-length/angle chain and visibly breaks the
    // shape. Redirected to a single-vertex [beginPointDrag] instead - the
    // exact same circumradius-scaling gesture a vertex drag already is (see
    // its own doc comment), matching the user's own "think of a Polygon
    // edge/vertex drag as a scaling operation" framing. [updateGrabbedPosition]/
    // [dropGrabbedEntity] already dispatch on whichever of
    // [_draggingPointId]/[_draggingLineId] ends up set, so no other call
    // site needs to know this happened.
    if (_polygonForVertex(line.startPointId) != null) {
      return beginPointDrag(line.startPointId);
    }
    // Phase 3 (3.2): mirrors [beginPointDrag]'s over-constrained refusal,
    // checked against both endpoints since either one being implicated is
    // enough to make the drag pointless.
    if (isPointForcedOverConstrained(line.startPointId) ||
        isPointForcedOverConstrained(line.endPointId)) {
      return false;
    }
    // Bug-fix round: mirrors [beginPointDrag]'s fully-pinned refusal.
    if (isPointFullyPinned(line.startPointId) || isPointFullyPinned(line.endPointId)) {
      return false;
    }
    _draggingLineId = lineId;
    _dragOriginCursorX = cursorX;
    _dragOriginCursorY = cursorY;
    _dragOriginLineStartX = start.x;
    _dragOriginLineStartY = start.y;
    _dragOriginLineEndX = end.x;
    _dragOriginLineEndY = end.y;
    _lastDragSolveAt = null;
    notifyListeners();
    return true;
  }

  /// [beginLineDrag]'s per-move update - both endpoints move by the same
  /// delta from where the drag started, applied to each endpoint's own
  /// origin position (same origin-relative math as [updatePointDrag], so
  /// the Line never "jumps" to be exactly under the cursor on the first
  /// move). PATCHes both endpoints immediately, same backend-is-truth
  /// tracking as [updatePointDrag] - including the same throttled mid-drag
  /// solve for every *other* Point (see [_maybeSolveDuringDrag]).
  Future<void> updateLineDrag(double x, double y) async {
    final lineId = _draggingLineId;
    final originCursorX = _dragOriginCursorX;
    final originCursorY = _dragOriginCursorY;
    final originStartX = _dragOriginLineStartX;
    final originStartY = _dragOriginLineStartY;
    final originEndX = _dragOriginLineEndX;
    final originEndY = _dragOriginLineEndY;
    if (lineId == null ||
        _sketchId == null ||
        originCursorX == null ||
        originCursorY == null ||
        originStartX == null ||
        originStartY == null ||
        originEndX == null ||
        originEndY == null) {
      return;
    }
    final line = lines[lineId];
    if (line == null) return;
    final dx = x - originCursorX;
    final dy = y - originCursorY;
    try {
      final updatedStart =
          await _api.updatePoint(_sketchId!, line.startPointId, originStartX + dx, originStartY + dy);
      if (_draggingLineId != lineId) return;
      points[line.startPointId] = SketchPointView(id: updatedStart.id, x: updatedStart.x, y: updatedStart.y);
      final updatedEnd =
          await _api.updatePoint(_sketchId!, line.endPointId, originEndX + dx, originEndY + dy);
      if (_draggingLineId != lineId) return;
      points[line.endPointId] = SketchPointView(id: updatedEnd.id, x: updatedEnd.x, y: updatedEnd.y);
      notifyListeners();
      _maybeSolveDuringDrag(
        [line.startPointId, line.endPointId],
        () => _draggingLineId == lineId,
      );
    } on ApiException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  /// Ends the current Line drag (if any) and re-solves from the dropped
  /// position - mirrors [endPointDrag], including auto-coincident snapping
  /// independently for each endpoint (dropping either end of a dragged Line
  /// onto an existing Point links them, same as a single dragged Point).
  Future<void> endLineDrag() async {
    final lineId = _draggingLineId;
    if (lineId == null) return;
    final line = lines[lineId];
    final originStartX = _dragOriginLineStartX!;
    final originStartY = _dragOriginLineStartY!;
    final originEndX = _dragOriginLineEndX!;
    final originEndY = _dragOriginLineEndY!;
    final droppedStart = line != null ? points[line.startPointId] : null;
    final droppedEnd = line != null ? points[line.endPointId] : null;
    _draggingLineId = null;
    _dragOriginCursorX = null;
    _dragOriginCursorY = null;
    _dragOriginLineStartX = null;
    _dragOriginLineStartY = null;
    _dragOriginLineEndX = null;
    _dragOriginLineEndY = null;
    if (line == null) return;
    await _runGuarded(() async {
      _pushUndo(() async {
        final restoredStart =
            await _api.updatePoint(_sketchId!, line.startPointId, originStartX, originStartY);
        points[line.startPointId] = SketchPointView(id: restoredStart.id, x: restoredStart.x, y: restoredStart.y);
        final restoredEnd = await _api.updatePoint(_sketchId!, line.endPointId, originEndX, originEndY);
        points[line.endPointId] = SketchPointView(id: restoredEnd.id, x: restoredEnd.x, y: restoredEnd.y);
      });
      if (droppedStart != null) {
        await _autoCoincideIfNear(line.startPointId, droppedStart.x, droppedStart.y);
      }
      if (droppedEnd != null) {
        await _autoCoincideIfNear(line.endPointId, droppedEnd.x, droppedEnd.y);
      }
      // Both endpoints anchored - mirrors [endPointDrag]'s reasoning, applied
      // to the whole dropped Line rather than a single Point.
      await _solveAndTrackDof(anchorPointIds: [line.startPointId, line.endPointId]);
    });
  }

  /// Whether something is currently grabbed via the drag-mode gesture (a
  /// Point, a Line, or a Constraint label) - the canvas hides its crosshair
  /// cursor and highlights the grabbed entity while this is true, and a
  /// further tap drops whatever's grabbed (see sketch_canvas.dart's
  /// drag-mode tap dispatch) instead of trying to grab something new.
  bool get isEntityGrabbed => _draggingPointId != null || _draggingLineId != null || _draggingLabelId != null;

  /// Feeds a cursor-position update to whichever entity is currently
  /// grabbed (a Point or a Line - see [isEntityGrabbed]) - lets the
  /// canvas's cursor-movement code stay agnostic to which kind of grab is
  /// active. A no-op if nothing's grabbed, or only a label is - a label's
  /// offset lives in screen space, not an absolute cursor position, so the
  /// canvas feeds it directly via [updateLabelDrag] instead of through
  /// here (see sketch_canvas.dart's `_feedMouseSwipeToGrabbedEntity` and
  /// its touch-branch equivalent).
  Future<void> updateGrabbedPosition(double x, double y) async {
    if (_draggingPointId != null) return updatePointDrag(x, y);
    if (_draggingLineId != null) return updateLineDrag(x, y);
  }

  /// Drops whichever entity is currently grabbed (Point, Line, or
  /// Constraint label - see [isEntityGrabbed]), finalizing it the same way
  /// its own end-drag method would.
  ///
  /// Bug-fix: the label branch was missing entirely - dropGrabbedEntity
  /// was written before label dragging was unified into this same
  /// grab/drop gesture, and never got updated when that happened, so a
  /// tap meant to drop a grabbed label silently did nothing (neither
  /// _draggingPointId nor _draggingLineId was ever set for a label grab).
  /// isEntityGrabbed stayed true forever after, leaving the label
  /// permanently stuck grabbed with no way to drop it.
  Future<void> dropGrabbedEntity() async {
    if (_draggingPointId != null) return endPointDrag();
    if (_draggingLineId != null) return endLineDrag();
    if (_draggingLabelId != null) return endLabelDrag();
  }

  /// Stage 15 item 2: per-Constraint screen-pixel offset from its default
  /// painted label position - purely a client-side display tweak (no
  /// backend call), so it survives a sketch refresh but not a fresh
  /// [ensureSketch]/[adoptSketch] (same lifetime as the controller itself).
  ///
  /// Dual meaning depending on Constraint type (both live in
  /// sketch_canvas.dart's `_SketchPainter`): for the value-less glyphs
  /// (V/H, parallel/perpendicular/equal/collinear, angle), it's applied
  /// directly as the label's own on-screen offset from its anchor, same as
  /// always. For a real dimension (distance, line-distance - the two with
  /// actual extension lines), it instead relocates *the dimension line
  /// itself* (its perpendicular offset from the measured geometry - see
  /// `_dimensionOffsetDistance`), so the extension lines stretch/shrink to
  /// reach it and the label sits on the line, rather than the label
  /// floating apart from a fixed dimension line connected by a leader
  /// line (removed - reported as an unwanted line traditional technical
  /// drawings don't have).
  final Map<String, Offset> _labelOffsets = {};

  /// [constraintId]'s current user-applied offset, or [Offset.zero] if it
  /// has never been dragged - read by the painter to place the label and
  /// by [dimensionLabelAt] (sketch_canvas.dart) to hit-test against where
  /// the label actually is, not just its un-offset default anchor.
  Offset labelOffsetFor(String constraintId) => _labelOffsets[constraintId] ?? Offset.zero;

  String? _draggingLabelId;

  /// The Constraint label currently being live-dragged via [beginLabelDrag],
  /// or null if no label drag is in progress - mirrors [draggingPointId]/
  /// [draggingLineId]; all three are mutually exclusive (see
  /// [beginPointDrag]/[beginLineDrag]/[beginLabelDrag]'s guards). Now uses
  /// the same tap-grab/swipe/tap-drop gesture as Point/Line grabbing (see
  /// sketch_canvas.dart's `_handleDragModeTap`) rather than its own
  /// separate continuous-hold mechanism.
  String? get draggingLabelId => _draggingLabelId;

  /// Starts a live drag of [constraintId]'s label - false (no-op) if a
  /// Point or Line drag is already active. Unlike [beginPointDrag] this
  /// never touches the backend, so there's no busy/sketch-id guard to fail
  /// on.
  bool beginLabelDrag(String constraintId) {
    if (_draggingPointId != null || _draggingLineId != null) return false;
    _draggingLabelId = constraintId;
    return true;
  }

  /// Live-updates the dragged label's offset by [canvasDelta] (screen
  /// pixels, same convention as a raw [PointerMoveEvent.delta] - never
  /// converted through a [ViewTransform], since the offset itself lives in
  /// screen space so a label stays a fixed number of pixels from its
  /// anchor regardless of zoom). Accumulates onto whatever offset the
  /// label already had, so repeated calls during one drag sum correctly.
  void updateLabelDrag(Offset canvasDelta) {
    final id = _draggingLabelId;
    if (id == null) return;
    _labelOffsets[id] = labelOffsetFor(id) + canvasDelta;
    notifyListeners();
  }

  /// Ends the current label drag (if any). The accumulated offset is kept
  /// as-is - a drag that actually moved the label leaves it wherever it
  /// was dropped.
  void endLabelDrag() {
    _draggingLabelId = null;
  }

  /// On-device feedback: session-only display-mode override for a circle's
  /// radius/diameter dimension - whether it currently reads as `R<value>`
  /// (false, the default) or `⌀<value*2>` (true), toggleable from the
  /// ribbon once the dimension is selected (see [toggleRadiusDiameterDisplay]).
  /// Needed because the underlying DistanceConstraint always stores the
  /// *radius* value either way (see [confirmGhostValue]'s `distanceValue` -
  /// a confirmed diameter ghost is halved before it's sent), so a radius-
  /// confirmed and a diameter-confirmed dimension of the same circle are
  /// otherwise indistinguishable from the persisted data alone - R/⌀ is
  /// purely a display choice layered on top of that one persisted value,
  /// not sent to the backend (matching this file's other session-only view
  /// preferences, e.g. [labelOffsetFor]'s drag offsets).
  final Map<String, bool> _showsDiameter = {};

  bool showsDiameterFor(String constraintId) => _showsDiameter[constraintId] ?? false;

  /// Flips [constraintId]'s R/⌀ display mode - only meaningful for a
  /// [circleForDistanceConstraint]-eligible dimension, but harmless to call
  /// for any id (just sets an unused map entry) since [SketchRibbon] only
  /// ever offers this action while such a dimension is selected.
  void toggleRadiusDiameterDisplay(String constraintId) {
    _showsDiameter[constraintId] = !showsDiameterFor(constraintId);
    notifyListeners();
  }

  /// The Circle a [DistanceConstraintDto] measures the radius/diameter of -
  /// true exactly when [c]'s point pair matches some Circle's own
  /// centerPointId/radiusPointId (however that DistanceConstraint was
  /// created - not just via the radius/diameter ghost flow), or null for
  /// an ordinary two-point linear/horizontal/vertical dimension. Used by
  /// [SketchCanvas] to route rendering to the radial leader instead of the
  /// generic two-point layout, and by [SketchRibbon] to gate the Radius/
  /// Diameter toggle.
  SketchCircleView? circleForDistanceConstraint(DistanceConstraintDto c) {
    for (final circle in circles.values) {
      if (circle.centerPointId == c.pointAId && circle.radiusPointId == c.pointBId) {
        return circle;
      }
    }
    return null;
  }

  /// The Arc a [DistanceConstraintDto] measures the radius of - mirrors
  /// [circleForDistanceConstraint] for the Arc case (center-start; the end
  /// Point is tied via EqualRadiusConstraint instead, see the backend's
  /// `app.sketch.models.Arc` docstring, so it's never reachable through this
  /// path). Used by [_SketchPainter]'s radius/diameter leader to know
  /// whether/how to dashed-arc-extend past the Arc's own drawn sweep.
  SketchArcView? arcForDistanceConstraint(DistanceConstraintDto c) {
    for (final arc in arcs.values) {
      if (arc.centerPointId == c.pointAId &&
          (arc.startPointId == c.pointBId || arc.endPointId == c.pointBId)) {
        return arc;
      }
    }
    return null;
  }

  /// The Polygon a [DistanceConstraintDto] measures the circumradius of -
  /// mirrors [circleForDistanceConstraint]/[arcForDistanceConstraint] for
  /// the Polygon case (center to vertex 0; every other vertex is tied via
  /// EqualRadiusConstraint instead - see `Polygon`'s own backend docstring -
  /// so it's never reachable through this path). Unlike an Ellipse's axes
  /// (deliberately excluded - see [ellipseAxisForDistanceConstraint]'s own
  /// doc comment), a regular Polygon *does* have one uniform radius by
  /// construction, so it renders/hit-tests as a radial leader exactly like
  /// a Circle/Arc, not an ordinary two-point dimension - see
  /// [isRadiusDistanceConstraint]. Also the fix for "is something hiding" -
  /// once confirmed, this constraint used to fall through to a generic
  /// linear dimension between the center Point and vertex 0 (an internal
  /// line with no drawn edge), easy to miss/misread as clutter rather than
  /// "the whole shape's size is now locked".
  SketchPolygonView? polygonForDistanceConstraint(DistanceConstraintDto c) {
    for (final polygon in polygons.values) {
      if (polygon.vertexPointIds.isNotEmpty &&
          polygon.centerPointId == c.pointAId &&
          polygon.vertexPointIds[0] == c.pointBId) {
        return polygon;
      }
    }
    return null;
  }

  /// The Ellipse axis (major or minor) a [DistanceConstraintDto] measures
  /// the centre-to-tip semi-length of - `(negPointId, posPointId)`, the
  /// axis's two real tip Points - or null for a constraint unrelated to any
  /// Ellipse. Technical-drawing-norms pass: an Ellipse has no uniform
  /// "radius" the way a Circle/Arc does, so its axes are no longer
  /// [isRadiusDistanceConstraint]-classified at all - each instead renders
  /// as an ordinary tip-to-tip length dimension (see [_SketchPainter.
  /// _paintDistanceDimension]), with the displayed value doubled from the
  /// underlying (still centre-based, semi-axis) constraint's own [c].distance
  /// - the same "double the stored value for display" trick a Circle's
  /// diameter display already uses, just applied to a straight dimension
  /// instead of a radial one. The underlying DistanceConstraint itself is
  /// unchanged (still centre-to-tip, still what the ghost-drag editor
  /// PATCHes) - this only changes how a *confirmed* axis constraint renders.
  (String, String)? ellipseAxisForDistanceConstraint(DistanceConstraintDto c) {
    for (final ellipse in ellipses.values) {
      if (ellipse.centerPointId != c.pointAId) continue;
      if (ellipse.majorPointId == c.pointBId) {
        return (ellipse.majorPointNegId, ellipse.majorPointId);
      }
      if (ellipse.minorPointId == c.pointBId) {
        return (ellipse.minorPointNegId, ellipse.minorPointId);
      }
    }
    return null;
  }

  /// Whether [c] measures the radius of a Circle, an Arc, or a Polygon's
  /// circumradius - [circleForDistanceConstraint]/[arcForDistanceConstraint]/
  /// [polygonForDistanceConstraint] recognize each case. An Ellipse's axes
  /// are deliberately excluded (see [ellipseAxisForDistanceConstraint]'s
  /// own doc comment) - used wherever rendering/hit-testing/the ribbon needs
  /// to know "is this a radial leader-style dimension" without caring which
  /// shape it belongs to.
  bool isRadiusDistanceConstraint(DistanceConstraintDto c) {
    return circleForDistanceConstraint(c) != null ||
        arcForDistanceConstraint(c) != null ||
        polygonForDistanceConstraint(c) != null;
  }

  /// Whether [c] is one of a Circle's cardinal-point axis-alignment
  /// constraints (see `app.sketch.models.Sketch._add_cardinal_points`) - a
  /// zero-value DistanceConstraint from the circle's centre to one of its
  /// north/east/south/west Points, pinning that point onto the horizontal or
  /// vertical axis through the centre. These exist purely as solver plumbing
  /// (so the cardinal points stay draggable-yet-locked-to-the-circle) and
  /// were never meant to be user-visible dimensions - always zero, always
  /// redundant with the circle's own radius, showing "0.00" on the canvas
  /// would just be distracting. Used by [_SketchPainter]/[_paintDimensionOverlays]
  /// and [_constraintLabelCenter] to skip these entirely (no render, no hit
  /// test), unlike [isRadiusDistanceConstraint]'s constraints which render as
  /// radial leaders.
  ///
  /// The centre-point circle tool's own mode (see [circleForDistanceConstraint]'s
  /// own doc comment) makes [c].distance load-bearing here, not just the
  /// point pair: that mode's radius point *is* the north cardinal point, so
  /// centre->north carries two distinct DistanceConstraints - the real,
  /// user-facing radius one (never hidden, whatever its value) and this
  /// method's own always-zero axis pin - both sharing the exact same point
  /// pair, indistinguishable by id alone since a Circle's own
  /// `cardinal_constraint_ids` are never sent to the client (see the
  /// backend's `CircleResponse`). Requiring [c].distance to be (near) zero
  /// is what tells them apart.
  bool isCardinalAxisConstraint(DistanceConstraintDto c) {
    if (c.distance.abs() > 1e-9) return false;
    for (final circle in circles.values) {
      if (circle.centerPointId == c.pointAId && circle.cardinalPointIds.contains(c.pointBId)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [lineAId]/[lineBId] are both edges of the *same* still-existing
  /// Polygon - the on-device feedback fix for the auto-created angle/equal-
  /// length ties (`add_polygon`'s own `equal_length_constraint_ids`/
  /// `angle_constraint_ids`) rendering a "45.0°"/"=" label at every vertex
  /// the instant a Polygon is placed: they're implicit structure (the shape
  /// wouldn't be a regular Polygon without them), not a user-facing
  /// dimension, the same way [isCardinalAxisConstraint]'s zero-value ties
  /// are already never shown. Identified by line membership (both edges
  /// found in the same Polygon's own [SketchPolygonView.lineIds]) rather
  /// than a stored id, matching how [circleForDistanceConstraint]/
  /// [arcForDistanceConstraint] already identify "mine" by Point/Line
  /// membership instead of the API exposing raw constraint ids.
  ///
  /// Deliberately forward-looking: a Polygon's own `delete_polygon`
  /// currently cascades every one of its Lines/Constraints away together
  /// (so this "hide" state and a "broken, no longer whole" state can't
  /// actually diverge *yet*), but a future trim/extend tool that shortens
  /// or removes just one edge Line without deleting the whole Polygon would
  /// leave its remaining implicit ties referencing a Line no longer in
  /// [SketchPolygonView.lineIds] - at that point this returns false again,
  /// and the label reappears as real, no-longer-implicit information the
  /// user needs to see (the shape isn't a regular Polygon anymore).
  bool isImplicitPolygonEdgeTie(String lineAId, String lineBId) {
    for (final polygon in polygons.values) {
      if (polygon.lineIds.contains(lineAId) && polygon.lineIds.contains(lineBId)) {
        return true;
      }
    }
    return false;
  }

  double _distanceToSegment(
    double px,
    double py,
    double ax,
    double ay,
    double bx,
    double by,
  ) {
    final abx = bx - ax;
    final aby = by - ay;
    final lengthSquared = abx * abx + aby * aby;
    var t = lengthSquared == 0 ? 0.0 : ((px - ax) * abx + (py - ay) * aby) / lengthSquared;
    t = t.clamp(0.0, 1.0);
    final closestX = ax + t * abx;
    final closestY = ay + t * aby;
    return math.sqrt(math.pow(px - closestX, 2) + math.pow(py - closestY, 2));
  }

  /// The point at cubic Bezier parameter [t] (in `[0, 1]`) along the curve
  /// defined by control points [p0]/[p1]/[p2]/[p3] - the standard cubic
  /// Bezier formula, matching exactly what `Geom_BezierCurve`
  /// (`app.document.extrude.wire_for_profile`'s own OCCT construction for
  /// a Spline segment) evaluates, so hit-testing/rendering never disagree
  /// with the real backend geometry.
  (double, double) _cubicBezierPoint(
    (double, double) p0,
    (double, double) p1,
    (double, double) p2,
    (double, double) p3,
    double t,
  ) {
    final mt = 1 - t;
    final a = mt * mt * mt;
    final b = 3 * mt * mt * t;
    final c = 3 * mt * t * t;
    final d = t * t * t;
    return (
      a * p0.$1 + b * p1.$1 + c * p2.$1 + d * p3.$1,
      a * p0.$2 + b * p1.$2 + c * p2.$2 + d * p3.$2,
    );
  }

  /// Samples every segment of [spline] into a single polyline (in the
  /// same order as [SketchSplineView.segments]) - shared by hit-testing
  /// and rendering fallbacks so what's tappable and what's (approximately)
  /// drawn never disagree. Null if any of the Spline's own defining
  /// Points is missing (a stale/in-flight response racing a local edit).
  static const int _splineSamplesPerSegment = 16;

  List<(double, double)>? _sampledSplinePoints(SketchSplineView spline) {
    final result = <(double, double)>[];
    for (final segment in spline.segments()) {
      final p0 = points[segment.$1];
      final p1 = points[segment.$2];
      final p2 = points[segment.$3];
      final p3 = points[segment.$4];
      if (p0 == null || p1 == null || p2 == null || p3 == null) return null;
      final a = (p0.x, p0.y);
      final b = (p1.x, p1.y);
      final c = (p2.x, p2.y);
      final d = (p3.x, p3.y);
      final startIndex = result.isEmpty ? 0 : 1; // avoid a duplicate point at each segment join
      for (var i = startIndex; i <= _splineSamplesPerSegment; i++) {
        result.add(_cubicBezierPoint(a, b, c, d, i / _splineSamplesPerSegment));
      }
    }
    return result;
  }

  /// [text]'s own cached preview contours (see [SketchTextView]'s own doc
  /// comment), repositioned to its anchor Point's *current* position - null
  /// before the first preview fetch completes, or if the anchor Point has
  /// since been deleted (a stale/in-flight response racing a local edit).
  /// Shared by rendering ([SketchCanvas]), hit-testing, and the bounding
  /// box above so what's drawn/tappable/measured never disagree.
  List<SketchTextContourOffsets>? textAbsoluteContours(SketchTextView text) {
    final relative = text.previewContoursRelative;
    final anchor = points[text.anchorPointId];
    if (relative == null || anchor == null) return null;
    return [
      for (final contour in relative)
        SketchTextContourOffsets(
          outer: [for (final p in contour.outer) (p.$1 + anchor.x, p.$2 + anchor.y)],
          holes: [
            for (final hole in contour.holes)
              [for (final p in hole) (p.$1 + anchor.x, p.$2 + anchor.y)],
          ],
        ),
    ];
  }

  /// The standard even-odd ray-cast point-in-polygon test, mirroring the
  /// backend's own `app.sketch.profile._loop_contains_point` - used to
  /// hit-test a tap against a Text entity's own (filled) glyph shape,
  /// since a Text tap target is its filled interior, not just a thin
  /// boundary the way every other entity's own hit-test radius is
  /// (Text is rendered as a solid fill - see [SketchCanvas] - matching
  /// what will actually be cut/embossed).
  bool _pointInPolygon(double x, double y, List<(double, double)> vertices) {
    var inside = false;
    for (var i = 0; i < vertices.length; i++) {
      final (x1, y1) = vertices[i];
      final (x2, y2) = vertices[(i + 1) % vertices.length];
      if ((y1 > y) != (y2 > y)) {
        final xIntersect = x1 + (y - y1) * (x2 - x1) / (y2 - y1);
        if (x < xIntersect) inside = !inside;
      }
    }
    return inside;
  }

  /// A human-readable reason [selection] (if it's a Point) cannot be
  /// deleted, or null if there's none. The sketch origin is the only entity
  /// that's still a hard block - a Point/Line/Circle still referenced by
  /// other geometry is no longer blocked here (see [computeDeleteCascade]/
  /// [deleteSelected], which now cascade the deletion instead, gated by a
  /// confirmation warning in the UI rather than an outright disable).
  String? get selectedPointDeleteBlockedReason {
    if (_selectionSet.length != 1) return null;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.point) return null;
    if (current.id == _originPointId) {
      return "Can't delete the sketch's origin point";
    }
    return null;
  }

  /// The Point/Line ids [constraint] directly references, regardless of its
  /// concrete type - used by [computeDeleteCascade] to find every
  /// Constraint that would be left dangling by deleting a given set of
  /// entities. Deliberately excludes Circle ids: no Constraint type
  /// references a Circle directly (a Circle's own radius DistanceConstraint
  /// references its center/radius Points instead, and is already
  /// auto-cascaded server-side when the Circle itself is deleted - see
  /// Sketch.delete_circle) - so a Circle never needs its own entry here.
  ({Set<String> pointIds, Set<String> lineIds}) _constraintReferences(ConstraintDto c) {
    return switch (c) {
      DistanceConstraintDto d => (pointIds: {d.pointAId, d.pointBId}, lineIds: <String>{}),
      VerticalConstraintDto d => (pointIds: {d.pointAId, d.pointBId}, lineIds: {d.lineId}),
      HorizontalConstraintDto d => (pointIds: {d.pointAId, d.pointBId}, lineIds: {d.lineId}),
      AngleConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      CoincidentConstraintDto d => (pointIds: {d.pointAId, d.pointBId}, lineIds: <String>{}),
      ParallelConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      PerpendicularConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      EqualLengthConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      CollinearConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      LineDistanceConstraintDto d => (pointIds: <String>{}, lineIds: {d.line1Id, d.line2Id}),
      PointLineDistanceConstraintDto d => (pointIds: {d.pointId}, lineIds: {d.lineId}),
      AtMidpointConstraintDto d => (pointIds: {d.pointId}, lineIds: {d.lineId}),
      // Bug fix: previously missing here meant deleting a Polygon vertex or
      // center Point (only ever referenced by this constraint type, since a
      // Polygon has no owning entity of its own to auto-cascade its own
      // ties on delete - unlike Arc/Ellipse/Slot's internal EqualRadius
      // ties, which ride along with their owning entity's own delete)
      // wouldn't pull its EqualRadiusConstraint ties into the cascade,
      // leaving the backend's own still-referenced-by-a-constraint check
      // (Sketch._point_deletion_blocker) reject the deletion outright.
      EqualRadiusConstraintDto d => (
          pointIds: {d.center1PointId, d.radius1PointId, d.center2PointId, d.radius2PointId},
          lineIds: <String>{},
        ),
      _ => (pointIds: <String>{}, lineIds: <String>{}),
    };
  }

  /// Everything deleting [selection] would need to also delete, computed
  /// transitively: a Point pulls in every Line/Circle/Arc that references
  /// it (start/end, center/radius, or center/start/end); every Point/Line/
  /// Arc actually being deleted (directly selected or pulled in) pulls in
  /// every Constraint that references it. Replaces the old behaviour of
  /// just disallowing deletion of a still-referenced Point/Line outright -
  /// the backend rejects (rather than auto-cascades) deleting something
  /// still referenced by other geometry, so the client now computes and
  /// performs the full cascade itself, with the UI layer (see
  /// sketch_ribbon.dart) responsible for warning the user what else is
  /// about to go.
  ({
    Set<String> points,
    Set<String> lines,
    Set<String> circles,
    Set<String> arcs,
    Set<String> ellipses,
    Set<String> polygons,
    Set<String> splines,
    Set<String> texts,
    Set<String> constraints
  }) computeDeleteCascade(Iterable<SketchSelection> selection) {
    final pointIds = <String>{};
    final lineIds = <String>{};
    final circleIds = <String>{};
    final arcIds = <String>{};
    final ellipseIds = <String>{};
    final polygonIds = <String>{};
    final splineIds = <String>{};
    final textIds = <String>{};
    final constraintIds = <String>{};
    for (final s in selection) {
      switch (s.kind) {
        case SelectionKind.point:
          if (s.id != _originPointId) pointIds.add(s.id);
        case SelectionKind.line:
          lineIds.add(s.id);
        case SelectionKind.circle:
          circleIds.add(s.id);
        case SelectionKind.arc:
          arcIds.add(s.id);
        case SelectionKind.ellipse:
          ellipseIds.add(s.id);
        case SelectionKind.spline:
          splineIds.add(s.id);
        case SelectionKind.text:
          textIds.add(s.id);
        case SelectionKind.constraint:
          constraintIds.add(s.id);
      }
    }
    for (final line in lines.values) {
      if (pointIds.contains(line.startPointId) || pointIds.contains(line.endPointId)) {
        lineIds.add(line.id);
      }
    }
    for (final circle in circles.values) {
      if (pointIds.contains(circle.centerPointId) || pointIds.contains(circle.radiusPointId)) {
        circleIds.add(circle.id);
      }
    }
    for (final arc in arcs.values) {
      if (pointIds.contains(arc.centerPointId) ||
          pointIds.contains(arc.startPointId) ||
          pointIds.contains(arc.endPointId)) {
        arcIds.add(arc.id);
      }
    }
    for (final ellipse in ellipses.values) {
      // Bug fix: an Ellipse's own axis Lines/minor-axis Point are real,
      // independently selectable/deletable geometry now (see the Ellipse
      // class's own docstring) - deleting just one of them while leaving
      // the Ellipse behind would strand it pointing at a Line/Point that
      // no longer exists. Cascade UP to the Ellipse from either direction,
      // exactly like every other entity here cascades from its own Points.
      if (pointIds.contains(ellipse.centerPointId) ||
          pointIds.contains(ellipse.majorPointId) ||
          pointIds.contains(ellipse.majorPointNegId) ||
          pointIds.contains(ellipse.minorPointId) ||
          pointIds.contains(ellipse.minorPointNegId) ||
          lineIds.contains(ellipse.majorAxisLineId) ||
          lineIds.contains(ellipse.minorAxisLineId)) {
        ellipseIds.add(ellipse.id);
      }
    }
    // The backend's own Sketch.delete_ellipse already deletes both axis
    // Lines as part of deleting the Ellipse itself - if one of them is also
    // independently queued in lineIds (selected directly, or pulled in via
    // a shared Point), deleting it *first* would leave delete_ellipse
    // trying to delete an already-gone Line. Drop them from lineIds here so
    // each axis Line is deleted exactly once, via its owning Ellipse.
    for (final ellipseId in ellipseIds) {
      final ellipse = ellipses[ellipseId];
      if (ellipse == null) continue;
      lineIds.remove(ellipse.majorAxisLineId);
      lineIds.remove(ellipse.minorAxisLineId);
    }
    for (final polygon in polygons.values) {
      // Same reasoning as the Ellipse block above - a Polygon's own edge
      // Lines/vertex Points are real, independently selectable/deletable
      // geometry, so cascade UP to the Polygon from either direction.
      if (pointIds.contains(polygon.centerPointId) ||
          polygon.vertexPointIds.any(pointIds.contains) ||
          polygon.lineIds.any(lineIds.contains)) {
        polygonIds.add(polygon.id);
      }
    }
    // The backend's own Sketch.delete_polygon already deletes every one of
    // its edge Lines as part of deleting the Polygon itself - same
    // "already-gone Line" concern the Ellipse block above avoids for its
    // own 2 axis Lines, generalized to all `sides` of them here.
    for (final polygonId in polygonIds) {
      final polygon = polygons[polygonId];
      if (polygon == null) continue;
      for (final lineId in polygon.lineIds) {
        lineIds.remove(lineId);
      }
    }
    for (final spline in splines.values) {
      if ([...spline.throughPointIds, ...spline.controlPointIds].any(pointIds.contains)) {
        splineIds.add(spline.id);
      }
    }
    for (final text in texts.values) {
      if (pointIds.contains(text.anchorPointId)) {
        textIds.add(text.id);
      }
    }
    for (final entry in constraints.entries) {
      final refs = _constraintReferences(entry.value);
      if (refs.pointIds.any(pointIds.contains) || refs.lineIds.any(lineIds.contains)) {
        constraintIds.add(entry.key);
      }
    }
    return (
      points: pointIds,
      lines: lineIds,
      circles: circleIds,
      arcs: arcIds,
      ellipses: ellipseIds,
      polygons: polygonIds,
      splines: splineIds,
      texts: textIds,
      constraints: constraintIds
    );
  }

  /// Session-scoped opt-out for the delete-cascade confirmation dialog (see
  /// sketch_ribbon.dart's `_confirmAndDelete`) - plain mutable field, same
  /// session-only/no-persistence convention as SketchScreen's other View
  /// toggles, just living on the controller since the ribbon (not the
  /// screen) is what needs to read/set it.
  bool suppressDeleteCascadeWarning = false;

  /// The single entry point for every click/tap on the 2D sketch canvas -
  /// Stage 13 item 3 replaces the old separate "move cursor, then press
  /// Click" flow with this: [sketchX]/[sketchY] is where the click commits,
  /// which is the controller's own persistent [cursorX]/[cursorY] (see
  /// [moveCursorRelative]/[moveCursorAbsoluteScreen]) - trackpad-style, a
  /// tap clicks wherever the cursor already sits, not wherever the tap
  /// itself physically landed. Dispatches on [mode]: drawing (replaces the
  /// old `click()`), selecting (replaces the old no-arg
  /// `handleCanvasTap()`), or picking a dimension target/ghost.
  /// Returns a [Future] so tests/callers that care can await the underlying
  /// network calls in [SketchMode.draw]; [SketchCanvas] itself fires this
  /// without awaiting, same as Stage 12's Click button did.
  Future<void> handleCanvasTap(double sketchX, double sketchY, [double? hitRadius]) async {
    cursorX = sketchX;
    cursorY = sketchY;
    // Prompt B item B4: dismiss the previous tap's auto-coincident
    // indicator (if any) - _clickPointTool below may set a fresh one for
    // *this* tap's own result.
    _autoCoincidentIndicatorPointId = null;
    final radius = hitRadius ?? snapRadius;
    switch (_mode) {
      case SketchMode.select:
        await _handleSelectTap(radius);
        break;
      case SketchMode.draw:
        await _handleDrawTap();
        break;
      case SketchMode.dimension:
        await _handleDimensionTap(radius);
        break;
      case SketchMode.trim:
        await _handleTrimTap(radius);
        break;
    }
  }

  /// [SketchMode.select]'s tap handling - hovering/tapping an entity selects
  /// it and opens/keeps open the flyout. While the flyout is already open,
  /// tapping a further entity adds it to [selectionSet] instead of
  /// replacing it (Stage 13 item 6's multi-entity selection); tapping blank
  /// space while the flyout is open dismisses it back to a clean idle
  /// state, matching how a tap-outside is expected to close a contextual
  /// panel. Stage 23d: tapping blank space while the flyout is already
  /// closed is now a no-op - it used to open the flyout showing only an
  /// "Exit Sketch" action, which has moved to the hamburger menu and is no
  /// longer reachable via the canvas at all.
  Future<void> _handleSelectTap(double hitRadius) async {
    if (_busy) return;
    SketchSelection? hit;
    await _runGuarded(() async {
      hit = await _resolveSelectableAt(hitRadius);
    });

    if (hit == null) {
      if (_ribbonVisible) {
        _selectionSet.clear();
        _ribbonVisible = false;
        notifyListeners();
      }
      return;
    }

    if (_ribbonVisible && _selectionSet.isNotEmpty) {
      if (!_selectionSet.any((s) => s.sameAs(hit!))) {
        _selectionSet.add(hit!);
      }
    } else {
      _selectionSet
        ..clear()
        ..add(hit!);
    }
    _ribbonVisible = true;
    notifyListeners();
  }

  /// Selects a Constraint directly by id - the entry point for tapping a
  /// dimension/constraint label on the canvas (Stage 13's hit-testing for
  /// those labels lives in [SketchCanvas], in screen space, since the
  /// controller only knows sketch-space coordinates - mirrors how ghost-label
  /// taps already short-circuit before reaching [handleCanvasTap]). Follows
  /// the same add-to-selection-vs-replace rule as [_handleSelectTap] (see
  /// [selectEntity], which this and the embedded 3D cursor mode's own
  /// selection-toggle path both now share).
  void selectConstraint(String constraintId) => selectEntity(SketchSelection(kind: SelectionKind.constraint, id: constraintId));

  /// P13: [selectConstraint]'s own add-to-selection-vs-replace body,
  /// generalized to any already-known [hit] rather than only a Constraint -
  /// the embedded 3D cursor mode's own tap-to-select (a [SelectionEntityRef]
  /// resolved via `PartViewport`'s ray-hit-testing, converted to a
  /// [SketchSelection] by the caller) needs the exact same rule with no
  /// hit-testing of its own to do, the same way [selectConstraint] never
  /// re-hit-tests either.
  void selectEntity(SketchSelection hit) {
    if (_ribbonVisible && _selectionSet.isNotEmpty) {
      if (!_selectionSet.any((s) => s.sameAs(hit))) {
        _selectionSet.add(hit);
      }
    } else {
      _selectionSet
        ..clear()
        ..add(hit);
    }
    _ribbonVisible = true;
    notifyListeners();
  }

  /// Explicitly closes the flyout (its close button) and clears any
  /// selection - the only way to dismiss it other than starting a new
  /// chain/circle/dimension pick, since a tap on blank idle canvas re-opens
  /// it rather than closing it (see [_handleSelectTap]).
  void closeRibbon() {
    _selectionSet.clear();
    _ribbonVisible = false;
    notifyListeners();
  }

  /// Stage 23h: removes one entity from [selectionSet] without disturbing
  /// the rest - the × on each row of the flyout's Selected Entities list.
  /// Closes the ribbon entirely once the last entity is removed this way,
  /// same as any other selection becoming empty.
  void deselect(SketchSelection selection) {
    _selectionSet.removeWhere((s) => s.sameAs(selection));
    _ribbonVisible = _selectionSet.isNotEmpty;
    notifyListeners();
  }

  /// Stage 23h: a short, human-friendly label for [selection] - e.g.
  /// "Line 2" - for the flyout's Selected Entities list. Purely derived
  /// from each entity map's current iteration order (i.e. creation order:
  /// [_loadExistingContent] seeds that order from the backend, and every
  /// later draw-tool method only ever appends new ids), not a separately
  /// persisted number - stable for this session only, and "Point" numbering
  /// excludes the origin Point, same as every other selection path
  /// ([selectAll]/[selectInRect]) excludes it from being selectable at all.
  String selectionLabel(SketchSelection selection) {
    switch (selection.kind) {
      case SelectionKind.point:
        final ids = points.keys.where((id) => id != _originPointId).toList();
        return 'Point ${ids.indexOf(selection.id) + 1}';
      case SelectionKind.line:
        return 'Line ${lines.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.circle:
        return 'Circle ${circles.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.arc:
        return 'Arc ${arcs.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.ellipse:
        return 'Ellipse ${ellipses.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.spline:
        return 'Spline ${splines.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.text:
        return 'Text ${texts.keys.toList().indexOf(selection.id) + 1}';
      case SelectionKind.constraint:
        return 'Constraint ${constraints.keys.toList().indexOf(selection.id) + 1}';
    }
  }

  /// Stage 19b item 5: selects every Line/Circle/Point - excluding the
  /// sketch's origin Point, which is pinned by the solver and so isn't a
  /// meaningful delete/constrain target - via the same multi-entity
  /// [selectionSet] every other multi-select path uses. Only meaningful in
  /// [SketchMode.select]; the toolbar button itself is hidden in draw mode.
  void selectAll() {
    if (_mode != SketchMode.select) return;
    _selectionSet
      ..clear()
      ..addAll(points.keys.where((id) => id != _originPointId).map(
            (id) => SketchSelection(kind: SelectionKind.point, id: id),
          ))
      ..addAll(lines.keys.map((id) => SketchSelection(kind: SelectionKind.line, id: id)))
      ..addAll(circles.keys.map((id) => SketchSelection(kind: SelectionKind.circle, id: id)))
      ..addAll(arcs.keys.map((id) => SketchSelection(kind: SelectionKind.arc, id: id)))
      ..addAll(ellipses.keys.map((id) => SketchSelection(kind: SelectionKind.ellipse, id: id)))
      ..addAll(splines.keys.map((id) => SketchSelection(kind: SelectionKind.spline, id: id)))
      ..addAll(texts.keys.map((id) => SketchSelection(kind: SelectionKind.text, id: id)))
      // Stage 21 item 4: without this, deleteSelected()'s constraints-first
      // ordering only ever covers constraints the user explicitly tapped -
      // any constraint on a selected Point/Line that select-all itself
      // didn't pick up still blocks that Point's deletion server-side
      // ("Point is still referenced by constraint ..."), since deleting a
      // Line never auto-deletes the constraints that reference it.
      ..addAll(constraints.keys.map((id) => SketchSelection(kind: SelectionKind.constraint, id: id)));
    _ribbonVisible = _selectionSet.isNotEmpty;
    notifyListeners();
  }

  /// Stage 23g: whether any selectable entity sits within [radius] of
  /// (x, y), in sketch coordinates - used to tell a long-press on truly
  /// empty canvas (which should start the marquee gesture) apart from one
  /// that lands on or near existing geometry (which shouldn't). Reuses the
  /// same hit-test core as ordinary tap-select/hover, including the origin
  /// Point.
  bool hasEntityNear(double x, double y, double radius) {
    return _entityAt(x, y, radius, includeOrigin: true) != null;
  }

  /// Stage 23g: replaces [selectionSet] with every Point/Line/Circle whose
  /// geometry falls *entirely* inside [sketchRect] (already converted to
  /// sketch coordinates by the caller) - the marquee-drag analogue of
  /// [selectAll]. The origin Point is excluded, same as [selectAll], since
  /// it's pinned by the solver and not a meaningful delete/constrain
  /// target. A Line/Circle only counts as "inside" when both its endpoints
  /// (or its full bounding box, for a Circle) lie within the rect.
  ///
  /// Deliberately does NOT auto-include each selected entity's
  /// Constraints the way [selectAll] does (see that method's Stage 21 item
  /// 4 comment) - the brief only asks for "entities fully inside the box,"
  /// and the ordinary tap-based multi-select path has the same
  /// constraints-not-auto-included limitation today, so this stays
  /// consistent with existing behavior rather than introducing new
  /// special-casing.
  void selectInRect(Rect sketchRect) {
    bool insideRect(double x, double y) {
      return x >= sketchRect.left &&
          x <= sketchRect.right &&
          y >= sketchRect.top &&
          y <= sketchRect.bottom;
    }

    final selected = <SketchSelection>[];
    for (final point in points.values) {
      if (point.id == _originPointId) continue;
      if (insideRect(point.x, point.y)) {
        selected.add(SketchSelection(kind: SelectionKind.point, id: point.id));
      }
    }
    for (final line in lines.values) {
      final start = points[line.startPointId];
      final end = points[line.endPointId];
      if (start == null || end == null) continue;
      if (insideRect(start.x, start.y) && insideRect(end.x, end.y)) {
        selected.add(SketchSelection(kind: SelectionKind.line, id: line.id));
      }
    }
    for (final circle in circles.values) {
      final center = points[circle.centerPointId];
      final edge = points[circle.radiusPointId];
      if (center == null || edge == null) continue;
      final radius = math.sqrt(
        math.pow(edge.x - center.x, 2) + math.pow(edge.y - center.y, 2),
      );
      if (insideRect(center.x - radius, center.y - radius) &&
          insideRect(center.x + radius, center.y + radius)) {
        selected.add(SketchSelection(kind: SelectionKind.circle, id: circle.id));
      }
    }
    for (final arc in arcs.values) {
      final center = points[arc.centerPointId];
      final start = points[arc.startPointId];
      final end = points[arc.endPointId];
      if (center == null || start == null || end == null) continue;
      final radius = math.sqrt(math.pow(start.x - center.x, 2) + math.pow(start.y - center.y, 2));
      // Conservative: the full circle's bounding box, same as Circle's
      // own check - a superset of the arc's actual (smaller) extent, so
      // this only ever under-selects a marquee-enclosed Arc, never
      // wrongly includes one that isn't fully inside.
      if (insideRect(center.x - radius, center.y - radius) &&
          insideRect(center.x + radius, center.y + radius)) {
        selected.add(SketchSelection(kind: SelectionKind.arc, id: arc.id));
      }
    }
    for (final ellipse in ellipses.values) {
      final center = points[ellipse.centerPointId];
      final major = points[ellipse.majorPointId];
      if (center == null || major == null) continue;
      // Conservative: a square of half-width majorRadius around the
      // center, same simplification [geometryBoundingBox] uses - this
      // only ever under-selects a marquee-enclosed Ellipse, never wrongly
      // includes one that isn't fully inside.
      final majorRadius = math.sqrt(
        math.pow(major.x - center.x, 2) + math.pow(major.y - center.y, 2),
      );
      if (insideRect(center.x - majorRadius, center.y - majorRadius) &&
          insideRect(center.x + majorRadius, center.y + majorRadius)) {
        selected.add(SketchSelection(kind: SelectionKind.ellipse, id: ellipse.id));
      }
    }
    for (final spline in splines.values) {
      // Exact, not conservative: a cubic Bezier never leaves its own
      // control polygon's convex hull, so "every defining Point is inside
      // the rect" is both necessary and sufficient.
      final definingPoints = [
        for (final id in [...spline.throughPointIds, ...spline.controlPointIds]) points[id],
      ];
      if (definingPoints.any((p) => p == null)) continue;
      if (definingPoints.every((p) => insideRect(p!.x, p.y))) {
        selected.add(SketchSelection(kind: SelectionKind.spline, id: spline.id));
      }
    }
    for (final text in texts.values) {
      // Conservative, mirroring Circle/Ellipse/Arc above: every outer
      // contour point must fall inside the rect (holes are always inside
      // their own outer boundary, so they need no separate check).
      final contours = textAbsoluteContours(text);
      if (contours == null) continue;
      if (contours.every((c) => c.outer.every((p) => insideRect(p.$1, p.$2)))) {
        selected.add(SketchSelection(kind: SelectionKind.text, id: text.id));
      }
    }
    _selectionSet
      ..clear()
      ..addAll(selected);
    _ribbonVisible = _selectionSet.isNotEmpty;
    notifyListeners();
  }

  /// Deletes every entity in [selectionSet], cascaded via
  /// [computeDeleteCascade] to also remove whatever depends on it (a Line/
  /// Circle a deleted Point still anchored, a Constraint any of that would
  /// leave dangling) - previously this only ever deleted the literal
  /// selection and let the backend reject anything still referenced; the UI
  /// layer (sketch_ribbon.dart's `_confirmAndDelete`) is responsible for
  /// warning the user what the cascade adds before calling this. Same
  /// backend-is-truth refresh as every other mutation; a rejected delete
  /// (e.g. a Constraint the client doesn't track locally) surfaces via
  /// [errorMessage], same as any other API failure, and entities already
  /// deleted before the failure stay removed.
  Future<void> deleteSelected() async {
    if (_selectionSet.isEmpty || _busy || _sketchId == null) return;
    final cascade = computeDeleteCascade(_selectionSet);
    final toDelete = <SketchSelection>[
      for (final id in cascade.points) SketchSelection(kind: SelectionKind.point, id: id),
      for (final id in cascade.lines) SketchSelection(kind: SelectionKind.line, id: id),
      for (final id in cascade.circles) SketchSelection(kind: SelectionKind.circle, id: id),
      for (final id in cascade.arcs) SketchSelection(kind: SelectionKind.arc, id: id),
      for (final id in cascade.ellipses) SketchSelection(kind: SelectionKind.ellipse, id: id),
      for (final id in cascade.splines) SketchSelection(kind: SelectionKind.spline, id: id),
      for (final id in cascade.texts) SketchSelection(kind: SelectionKind.text, id: id),
      for (final id in cascade.constraints) SketchSelection(kind: SelectionKind.constraint, id: id),
    ];
    if (toDelete.isEmpty) return;

    // Stage 19b item 4: captured before anything is actually removed, so
    // the undo entry pushed below has the data needed to recreate each one
    // (the backend always assigns fresh ids on recreation - see
    // [_restoreDeletedEntities]).
    final capturedPoints = <SketchPointView>[];
    final capturedLines = <SketchLineView>[];
    final capturedCircles = <SketchCircleView>[];
    final capturedArcs = <SketchArcView>[];
    final capturedEllipses = <SketchEllipseView>[];
    final capturedSplines = <SketchSplineView>[];
    final capturedTexts = <SketchTextView>[];
    final capturedConstraints = <ConstraintDto>[];
    // Polygon has no SelectionKind (see the comment on cascade.polygons'
    // own deletion loop below), so it's captured separately here rather
    // than inside the toDelete switch below.
    final capturedPolygons = [for (final id in cascade.polygons) polygons[id]].whereType<SketchPolygonView>().toList();
    for (final current in toDelete) {
      switch (current.kind) {
        case SelectionKind.line:
          final line = lines[current.id];
          if (line != null) capturedLines.add(line);
          break;
        case SelectionKind.circle:
          final circle = circles[current.id];
          if (circle != null) capturedCircles.add(circle);
          break;
        case SelectionKind.arc:
          final arc = arcs[current.id];
          if (arc != null) capturedArcs.add(arc);
          break;
        case SelectionKind.ellipse:
          final ellipse = ellipses[current.id];
          if (ellipse != null) capturedEllipses.add(ellipse);
          break;
        case SelectionKind.spline:
          final spline = splines[current.id];
          if (spline != null) capturedSplines.add(spline);
          break;
        case SelectionKind.text:
          final text = texts[current.id];
          if (text != null) capturedTexts.add(text);
          break;
        case SelectionKind.point:
          final point = points[current.id];
          if (point != null) capturedPoints.add(point);
          break;
        case SelectionKind.constraint:
          final constraint = constraints[current.id];
          if (constraint != null) capturedConstraints.add(constraint);
          break;
      }
    }

    await _runGuarded(() async {
      // Backend rejects deleting a Point still referenced by a Line/Circle/
      // Arc/Ellipse/Spline/Text, and a Line/Circle/Arc/Ellipse/Spline/Text
      // can itself still be referenced by a Constraint - so deletion must
      // run in the reverse of creation/dependency order (Constraints, then
      // Lines/Circles/Arcs/Ellipses/Splines/Texts, then Points), regardless
      // of the order entities happened to be selected/tapped in. Mirrors
      // [_restoreDeletedEntities]'s own (forward) Points ->
      // Lines/Circles/Arcs/Ellipses/Splines/Texts -> Constraints ordering.
      final constraintsToDelete = toDelete.where((s) => s.kind == SelectionKind.constraint);
      final shapesToDelete = toDelete.where(
        (s) =>
            s.kind == SelectionKind.line ||
            s.kind == SelectionKind.circle ||
            s.kind == SelectionKind.arc ||
            s.kind == SelectionKind.ellipse ||
            s.kind == SelectionKind.spline ||
            s.kind == SelectionKind.text,
      );
      final pointsToDelete = toDelete.where((s) => s.kind == SelectionKind.point);
      // Polygon isn't independently tap-selectable (no SelectionKind.polygon
      // - only its own vertex Points/edge Lines are, same as it always was
      // before it became a real entity), so it isn't routed through the
      // generic toDelete/SketchSelection list above - deleted directly here
      // instead, in the same "before its own Points" dependency slot
      // shapesToDelete already occupies. delete_polygon cascades its own
      // radius/equal-radius/equal-length/angle constraints server-side
      // regardless of whether this client's local cascade computation
      // identified them individually - refreshConstraints() below re-syncs
      // the local cache afterward, same as every other entity's own
      // internal constraints already rely on.
      for (final id in cascade.polygons) {
        await _api.deletePolygon(_sketchId!, id);
        polygons.remove(id);
      }
      // Bug fix (on-device feedback: "select all > delete doesn't work on
      // polygons, says constraint not found"): delete_polygon cascades its
      // own radius/equal-radius/equal-length/angle constraints server-side
      // (see the comment above) - if computeDeleteCascade also
      // independently identified one of those same constraint ids (e.g.
      // because the Polygon's own vertex Points/edge Lines were directly
      // in the selection too, which "select all" always includes), the
      // explicit deleteConstraint call below 404'd on an id the polygon's
      // own server-side cascade had already removed. Re-fetching here
      // (only when a polygon was actually involved, to avoid an
      // unnecessary round-trip otherwise) keeps the containsKey check just
      // below honest about what's actually still there to delete.
      if (cascade.polygons.isNotEmpty) {
        await _refreshConstraints();
      }
      for (final current in [...constraintsToDelete, ...shapesToDelete, ...pointsToDelete]) {
        switch (current.kind) {
          case SelectionKind.constraint:
            if (!constraints.containsKey(current.id)) break;
            await _api.deleteConstraint(_sketchId!, current.id);
            constraints.remove(current.id);
            break;
          case SelectionKind.line:
            await _api.deleteLine(_sketchId!, current.id);
            lines.remove(current.id);
            break;
          case SelectionKind.circle:
            await _api.deleteCircle(_sketchId!, current.id);
            circles.remove(current.id);
            break;
          case SelectionKind.arc:
            await _api.deleteArc(_sketchId!, current.id);
            arcs.remove(current.id);
            break;
          case SelectionKind.ellipse:
            final ellipse = ellipses[current.id];
            await _api.deleteEllipse(_sketchId!, current.id);
            ellipses.remove(current.id);
            if (ellipse != null) {
              lines.remove(ellipse.majorAxisLineId);
              lines.remove(ellipse.minorAxisLineId);
            }
            break;
          case SelectionKind.spline:
            await _api.deleteSpline(_sketchId!, current.id);
            splines.remove(current.id);
            break;
          case SelectionKind.text:
            await _api.deleteText(_sketchId!, current.id);
            texts.remove(current.id);
            break;
          case SelectionKind.point:
            await _api.deletePoint(_sketchId!, current.id);
            points.remove(current.id);
            break;
        }
      }
      _pushUndo(() => _restoreDeletedEntities(
            capturedPoints,
            capturedLines,
            capturedCircles,
            capturedArcs,
            capturedEllipses,
            capturedPolygons,
            capturedSplines,
            capturedTexts,
            capturedConstraints,
          ));
      // Bug-fix round 2: always re-solve/refresh here, not just when a
      // Constraint was directly in the selection (the old behaviour).
      // Deleting a Circle also cascades to remove its own radius
      // DistanceConstraint server-side (see Sketch.delete_circle) - that
      // changes the system's degrees of freedom exactly as much as an
      // explicit Constraint deletion does, but the old conditional only
      // looked at what the user actually selected, so this case fell
      // through it and left `_dof`/`isUnderConstrained` (and so the "fully
      // constrained" indicator) stale until some *other* mutation happened
      // to trigger a fresh solve.
      await _solveAndTrackDof();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  /// [deleteSelected]'s undo: recreates every captured entity in dependency
  /// order (Points, then Lines/Circles, then Constraints) since the backend
  /// always assigns fresh ids to a recreated entity - [idMap] tracks each
  /// old id -> new id as Points/Lines/Circles are recreated, so the Lines/
  /// Circles/Constraints recreated after them substitute the right (new) id
  /// for whichever endpoint they referenced; an id with no entry in [idMap]
  /// was never deleted, so the original id is still valid as-is.
  Future<void> _restoreDeletedEntities(
    List<SketchPointView> capturedPoints,
    List<SketchLineView> capturedLines,
    List<SketchCircleView> capturedCircles,
    List<SketchArcView> capturedArcs,
    List<SketchEllipseView> capturedEllipses,
    List<SketchPolygonView> capturedPolygons,
    List<SketchSplineView> capturedSplines,
    List<SketchTextView> capturedTexts,
    List<ConstraintDto> capturedConstraints,
  ) async {
    final idMap = <String, String>{};

    for (final point in capturedPoints) {
      final created = await _api.createPoint(_sketchId!, point.x, point.y);
      idMap[point.id] = created.id;
      points[created.id] = SketchPointView(id: created.id, x: created.x, y: created.y);
    }
    for (final line in capturedLines) {
      final created = await _api.createLine(
        _sketchId!,
        idMap[line.startPointId] ?? line.startPointId,
        idMap[line.endPointId] ?? line.endPointId,
        construction: line.construction,
      );
      idMap[line.id] = created.id;
      lines[created.id] = SketchLineView(
        id: created.id,
        startPointId: created.startPointId,
        endPointId: created.endPointId,
        construction: created.construction,
      );
    }
    for (final circle in capturedCircles) {
      final created = await _api.createCircle(
        _sketchId!,
        idMap[circle.centerPointId] ?? circle.centerPointId,
        idMap[circle.radiusPointId] ?? circle.radiusPointId,
        construction: circle.construction,
      );
      idMap[circle.id] = created.id;
      circles[created.id] = SketchCircleView(
        id: created.id,
        centerPointId: created.centerPointId,
        radiusPointId: created.radiusPointId,
        construction: created.construction,
        cardinalPointIds: created.cardinalPointIds,
      );
      // The four cardinal Points are always freshly created server-side
      // (see Circle.cardinal_point_ids' own docstring) - same
      // fetch-and-cache as Ellipse's own minor/negative-tip Points above.
      for (final id in created.cardinalPointIds) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
    }
    for (final arc in capturedArcs) {
      final created = await _api.createArc(
        _sketchId!,
        idMap[arc.centerPointId] ?? arc.centerPointId,
        idMap[arc.startPointId] ?? arc.startPointId,
        idMap[arc.endPointId] ?? arc.endPointId,
        construction: arc.construction,
      );
      idMap[arc.id] = created.id;
      arcs[created.id] = SketchArcView(
        id: created.id,
        centerPointId: created.centerPointId,
        startPointId: created.startPointId,
        endPointId: created.endPointId,
        construction: created.construction,
      );
    }
    for (final ellipse in capturedEllipses) {
      final created = await _api.createEllipse(
        _sketchId!,
        idMap[ellipse.centerPointId] ?? ellipse.centerPointId,
        idMap[ellipse.majorPointId] ?? ellipse.majorPointId,
        ellipse.minorRadius,
        construction: ellipse.construction,
      );
      idMap[ellipse.id] = created.id;
      ellipses[created.id] = SketchEllipseView(
        id: created.id,
        centerPointId: created.centerPointId,
        majorPointId: created.majorPointId,
        majorPointNegId: created.majorPointNegId,
        minorPointId: created.minorPointId,
        minorPointNegId: created.minorPointNegId,
        majorAxisLineId: created.majorAxisLineId,
        minorAxisLineId: created.minorAxisLineId,
        minorRadius: created.minorRadius,
        construction: created.construction,
      );
      lines[created.majorAxisLineId] = SketchLineView(
        id: created.majorAxisLineId,
        startPointId: created.majorPointNegId,
        endPointId: created.majorPointId,
        construction: true,
      );
      lines[created.minorAxisLineId] = SketchLineView(
        id: created.minorAxisLineId,
        startPointId: created.minorPointNegId,
        endPointId: created.minorPointId,
        construction: true,
      );
      // The new minor-axis and negative-tip Points aren't locally known
      // yet - see the main Ellipse-tool creation flow's own comment for
      // why this needs an explicit fetch.
      for (final id in [created.minorPointId, created.majorPointNegId, created.minorPointNegId]) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
    }
    for (final polygon in capturedPolygons) {
      final created = await _api.createPolygon(
        _sketchId!,
        idMap[polygon.centerPointId] ?? polygon.centerPointId,
        idMap[polygon.vertexPointIds[0]] ?? polygon.vertexPointIds[0],
        polygon.sides,
        construction: polygon.construction,
      );
      idMap[polygon.id] = created.id;
      polygons[created.id] = SketchPolygonView(
        id: created.id,
        centerPointId: created.centerPointId,
        vertexPointIds: created.vertexPointIds,
        lineIds: created.lineIds,
        sides: created.sides,
        construction: created.construction,
      );
      for (var i = 0; i < created.lineIds.length; i++) {
        lines[created.lineIds[i]] = SketchLineView(
          id: created.lineIds[i],
          startPointId: created.vertexPointIds[i],
          endPointId: created.vertexPointIds[(i + 1) % created.vertexPointIds.length],
        );
      }
      // Vertex 0 is the (already-restored) first vertex passed above -
      // vertices 1..sides-1 are freshly created server-side by
      // add_polygon and aren't locally known yet, same as Ellipse's own
      // minor/negative-tip Points above.
      for (final id in created.vertexPointIds.skip(1)) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
    }
    for (final spline in capturedSplines) {
      // Unlike Circle/Arc/Ellipse, only the through-points are passed
      // back in - the backend always creates a fresh set of
      // control-handle Points for a new Spline (see Sketch.add_spline),
      // so the originals' own ids/positions aren't recreated or reused.
      final created = await _api.createSpline(
        _sketchId!,
        [for (final id in spline.throughPointIds) idMap[id] ?? id],
        construction: spline.construction,
      );
      idMap[spline.id] = created.id;
      // Same fetch-and-cache as [finishSpline] - these fresh control-handle
      // Points are new to the client; fetched eagerly here so they're
      // available for immediate local use before [_refreshAllPoints] (called
      // after this by [undo]) resolves, even though that call would also
      // pick them up itself now.
      for (final id in created.controlPointIds) {
        final point = await _api.getPoint(_sketchId!, id);
        points[id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      splines[created.id] = SketchSplineView(
        id: created.id,
        throughPointIds: created.throughPointIds,
        controlPointIds: created.controlPointIds,
        construction: created.construction,
      );
    }
    for (final text in capturedTexts) {
      final created = await _api.createText(
        _sketchId!,
        text.content,
        idMap[text.anchorPointId] ?? text.anchorPointId,
        size: text.size,
        rotationDegrees: text.rotationDegrees,
        construction: text.construction,
      );
      idMap[text.id] = created.id;
      texts[created.id] = SketchTextView(
        id: created.id,
        content: created.content,
        font: created.font,
        size: created.size,
        anchorPointId: created.anchorPointId,
        rotationDegrees: created.rotationDegrees,
        construction: created.construction,
      );
      await _refreshTextPreview(created.id);
    }
    for (final constraint in capturedConstraints) {
      await _recreateConstraint(constraint, idMap);
    }
  }

  /// [_restoreDeletedEntities]'s per-subtype dispatcher - each
  /// [ConstraintDto] subtype needs a different [SketchApiClient]
  /// `create*Constraint` call, with its Point/Line ids substituted through
  /// [idMap] (falling back to the original id when it was never deleted).
  Future<void> _recreateConstraint(ConstraintDto dto, Map<String, String> idMap) async {
    String mapped(String id) => idMap[id] ?? id;
    if (dto is VerticalConstraintDto) {
      await _api.createVerticalConstraint(_sketchId!, mapped(dto.lineId));
    } else if (dto is HorizontalConstraintDto) {
      await _api.createHorizontalConstraint(_sketchId!, mapped(dto.lineId));
    } else if (dto is AngleConstraintDto) {
      await _api.createAngleConstraint(
        _sketchId!,
        mapped(dto.line1Id),
        mapped(dto.line2Id),
        dto.angleDegrees,
      );
    } else if (dto is CoincidentConstraintDto) {
      await _api.createCoincidentConstraint(_sketchId!, mapped(dto.pointAId), mapped(dto.pointBId));
    } else if (dto is ParallelConstraintDto) {
      await _api.createParallelConstraint(_sketchId!, mapped(dto.line1Id), mapped(dto.line2Id));
    } else if (dto is PerpendicularConstraintDto) {
      await _api.createPerpendicularConstraint(_sketchId!, mapped(dto.line1Id), mapped(dto.line2Id));
    } else if (dto is EqualLengthConstraintDto) {
      await _api.createEqualLengthConstraint(_sketchId!, mapped(dto.line1Id), mapped(dto.line2Id));
    } else if (dto is CollinearConstraintDto) {
      await _api.createCollinearConstraint(_sketchId!, mapped(dto.line1Id), mapped(dto.line2Id));
    } else if (dto is LineDistanceConstraintDto) {
      await _api.createLineDistanceConstraint(
        _sketchId!,
        mapped(dto.line1Id),
        mapped(dto.line2Id),
        dto.distance,
      );
    } else if (dto is PointLineDistanceConstraintDto) {
      await _api.createPointLineDistanceConstraint(
        _sketchId!,
        mapped(dto.pointId),
        mapped(dto.lineId),
        dto.distance,
      );
    } else if (dto is AtMidpointConstraintDto) {
      await _api.createAtMidpointConstraint(_sketchId!, mapped(dto.pointId), mapped(dto.lineId));
    } else if (dto is DistanceConstraintDto) {
      await _api.createDistanceConstraint(
        _sketchId!,
        mapped(dto.pointAId),
        mapped(dto.pointBId),
        dto.distance,
        orientation: dto.orientation,
      );
    }
  }

  /// The currently selected single Constraint's editable numeric value
  /// (Distance's `distance` or Angle's `angle_degrees`), or null if the
  /// selection isn't exactly one Constraint, or that Constraint has no
  /// value (Vertical/Horizontal) - drives the ribbon's change-value editor
  /// (new work package item 3).
  double? get selectedConstraintValue {
    if (_selectionSet.length != 1 || _selectionSet.first.kind != SelectionKind.constraint) {
      return null;
    }
    final constraint = constraints[_selectionSet.first.id];
    if (constraint is DistanceConstraintDto) return constraint.distance;
    if (constraint is AngleConstraintDto) return constraint.angleDegrees;
    return null;
  }

  /// Whether [selectedConstraintValue] has a value worth showing an editor
  /// for - false (not just null) for a non-Constraint or no selection too,
  /// so the ribbon can use this directly as a render condition.
  bool get selectedConstraintHasValue => selectedConstraintValue != null;

  /// Whether the selected single Constraint is an Angle (drives the
  /// ribbon's value-editor suffix, "°" vs "mm").
  bool get selectedConstraintIsAngle {
    if (_selectionSet.length != 1 || _selectionSet.first.kind != SelectionKind.constraint) {
      return false;
    }
    return constraints[_selectionSet.first.id] is AngleConstraintDto;
  }

  /// The selected single Constraint's id, if it's a circle radius/diameter
  /// dimension (see [circleForDistanceConstraint]) - drives the ribbon's
  /// Radius/Diameter toggle, matching [selectedConstraintValue]'s
  /// single-Constraint-selection gating exactly.
  String? get selectedRadiusDiameterConstraintId {
    if (_selectionSet.length != 1 || _selectionSet.first.kind != SelectionKind.constraint) {
      return null;
    }
    final id = _selectionSet.first.id;
    final constraint = constraints[id];
    if (constraint is DistanceConstraintDto && isRadiusDistanceConstraint(constraint)) {
      return id;
    }
    return null;
  }

  /// [lineId]'s current length in sketch units, or null if it isn't a known
  /// Line - drives Stage 19b item 6's "Set Length" dialog's pre-filled
  /// value.
  double? lineLength(String lineId) {
    final line = lines[lineId];
    if (line == null) return null;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return null;
    return math.sqrt(math.pow(end.x - start.x, 2) + math.pow(end.y - start.y, 2));
  }

  /// Stage 19b item 6's ribbon "Set Length" action: the same flow
  /// [confirmGhostValue]'s `length` ghost would run (a plain
  /// `DistanceConstraint` between the Line's two endpoints - the backend's
  /// only way to represent a Line's length, see [_buildLineLengthGhost]),
  /// callable directly from the ribbon without first entering Dimension mode
  /// and tapping the ghost label.
  Future<void> setLineLength(String lineId, double value) async {
    if (_busy || _sketchId == null) return;
    final line = lines[lineId];
    if (line == null) return;
    final pointAId = line.startPointId;
    final pointBId = line.endPointId;

    await _runGuarded(() async {
      final existing = _findDistanceConstraint(pointAId, pointBId);
      if (existing != null) {
        final oldValue = existing.distance;
        await _api.updateConstraintValue(_sketchId!, existing.id, value);
        _pushUndo(() async => _api.updateConstraintValue(_sketchId!, existing.id, oldValue));
      } else {
        final constraint = await _api.createDistanceConstraint(_sketchId!, pointAId, pointBId, value);
        _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
      }
      // On-device feedback (bug fix): this used to only solve in the
      // new-constraint branch above - PATCHing an *existing* constraint's
      // value still re-solves server-side (update_constraint_value's own
      // response is a fresh SolveResultResponse), but this client's own
      // cached _dof/_lastSolveConverged (everything isFullyConstrained/
      // isUnderConstrained/the green-red coloring reads) never picked that
      // up, so it kept showing whatever the *previous* solve reported until
      // some later, unrelated mutation forced a fresh one - or the sketch
      // was closed and reopened, which does a full re-adopt.
      await _solveAndTrackDof();
    });
  }

  /// PATCHes the selected single Constraint's value (new work package item
  /// 3's "change value" ribbon action) - mirrors [confirmGhostValue]'s
  /// PATCH-existing-constraint path, then deselects and closes the ribbon on
  /// success, same as every other constraint mutation (item 7).
  Future<void> updateSelectedConstraintValue(double value) async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.constraint) return;

    final oldValue = selectedConstraintValue;
    await _runGuarded(() async {
      await _api.updateConstraintValue(_sketchId!, current.id, value);
      if (oldValue != null) {
        _pushUndo(() async => _api.updateConstraintValue(_sketchId!, current.id, oldValue));
      }
      // On-device feedback (bug fix): never called here at all, so editing
      // an existing Constraint's value via the ribbon left _dof/
      // _lastSolveConverged (and so isFullyConstrained/isUnderConstrained/
      // the green-red coloring) stuck on whatever the last unrelated solve
      // reported - see [setLineLength]'s own matching fix for the full
      // reasoning (update_constraint_value already re-solves server-side;
      // this client-side cache just never picked it up).
      await _solveAndTrackDof();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  /// Whether [selection] is a Line/Circle currently marked construction -
  /// drives the flyout's Make-Construction/Make-Solid toggle label. Null
  /// (rather than false) when there isn't exactly one Line/Circle selected,
  /// so the flyout knows not to show the toggle for a Point selection or a
  /// multi-entity selection.
  bool? get selectedIsConstruction {
    if (_selectionSet.length != 1) return null;
    return _constructionFlagOf(_selectionSet.first);
  }

  /// The one entity kind -> current-construction-flag lookup shared by
  /// [selectedIsConstruction], [availableConstructionToggles], and every
  /// construction-toggling method below - `null` for a kind with no such
  /// flag at all (Point/Constraint).
  bool? _constructionFlagOf(SketchSelection selection) => switch (selection.kind) {
        SelectionKind.line => lines[selection.id]?.construction,
        SelectionKind.circle => circles[selection.id]?.construction,
        SelectionKind.arc => arcs[selection.id]?.construction,
        SelectionKind.ellipse => ellipses[selection.id]?.construction,
        SelectionKind.spline => splines[selection.id]?.construction,
        SelectionKind.text => texts[selection.id]?.construction,
        SelectionKind.point || SelectionKind.constraint => null,
      };

  /// Sets [target]'s construction flag to [construction] via the backend
  /// PATCH endpoint and updates local state - the single-entity core
  /// [toggleSelectedConstruction]/[setSelectedConstruction] both apply
  /// per target, factored out once those two calling shapes (exactly-one
  /// vs. every-applicable-entity-in-a-multi-selection) needed to share it.
  /// Caller's responsibility to wrap in [_runGuarded] and to have already
  /// confirmed [target]'s kind actually has a construction flag.
  Future<void> _applyConstruction(SketchSelection target, bool construction) async {
    switch (target.kind) {
      case SelectionKind.line:
        final updated = await _api.updateLine(_sketchId!, target.id, construction: construction);
        lines[target.id] = SketchLineView(
          id: updated.id,
          startPointId: updated.startPointId,
          endPointId: updated.endPointId,
          construction: updated.construction,
        );
      case SelectionKind.circle:
        final updated = await _api.updateCircle(_sketchId!, target.id, construction: construction);
        circles[target.id] = SketchCircleView(
          id: updated.id,
          centerPointId: updated.centerPointId,
          radiusPointId: updated.radiusPointId,
          construction: updated.construction,
          cardinalPointIds: updated.cardinalPointIds,
        );
      case SelectionKind.arc:
        final updated = await _api.updateArc(_sketchId!, target.id, construction: construction);
        arcs[target.id] = SketchArcView(
          id: updated.id,
          centerPointId: updated.centerPointId,
          startPointId: updated.startPointId,
          endPointId: updated.endPointId,
          construction: updated.construction,
        );
      case SelectionKind.ellipse:
        final updated = await _api.updateEllipse(_sketchId!, target.id, construction: construction);
        ellipses[target.id] = SketchEllipseView(
          id: updated.id,
          centerPointId: updated.centerPointId,
          majorPointId: updated.majorPointId,
          majorPointNegId: updated.majorPointNegId,
          minorPointId: updated.minorPointId,
          minorPointNegId: updated.minorPointNegId,
          majorAxisLineId: updated.majorAxisLineId,
          minorAxisLineId: updated.minorAxisLineId,
          minorRadius: updated.minorRadius,
          construction: updated.construction,
        );
      case SelectionKind.spline:
        final updated = await _api.updateSpline(_sketchId!, target.id, construction: construction);
        splines[target.id] = SketchSplineView(
          id: updated.id,
          throughPointIds: updated.throughPointIds,
          controlPointIds: updated.controlPointIds,
          construction: updated.construction,
        );
      case SelectionKind.text:
        final updated = await _api.updateText(_sketchId!, target.id, construction: construction);
        texts[target.id] = SketchTextView(
          id: updated.id,
          content: updated.content,
          font: updated.font,
          size: updated.size,
          anchorPointId: updated.anchorPointId,
          rotationDegrees: updated.rotationDegrees,
          construction: updated.construction,
          previewContoursRelative: texts[target.id]?.previewContoursRelative,
        );
      case SelectionKind.point:
      case SelectionKind.constraint:
        break;
    }
  }

  /// Flips [selection]'s construction flag via the backend PATCH endpoint -
  /// immediate, no confirmation, mirroring [deleteSelected]'s
  /// backend-is-truth pattern. A no-op if nothing applicable is selected.
  Future<void> toggleSelectedConstruction() async {
    final currentlyConstruction = selectedIsConstruction;
    if (currentlyConstruction == null || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    await _runGuarded(() => _applyConstruction(current, !currentlyConstruction));
  }

  /// On-device feedback: which of Make-Construction/Make-Solid the ribbon
  /// should offer for the current (possibly multi-entity) [selectionSet] -
  /// [selectedIsConstruction]'s multi-selection sibling. Both come back
  /// true when the selection mixes construction and solid entities (there's
  /// no single "next state" to toggle to at that point, so both directions
  /// are offered as separate actions instead - see [setSelectedConstruction]).
  ({bool showMakeConstruction, bool showMakeSolid}) get availableConstructionToggles {
    final flags = _selectionSet.map(_constructionFlagOf).whereType<bool>().toList();
    if (flags.isEmpty) return (showMakeConstruction: false, showMakeSolid: false);
    return (showMakeConstruction: flags.contains(false), showMakeSolid: flags.contains(true));
  }

  /// Sets every applicable entity in [selectionSet] (Line/Circle/Arc/
  /// Ellipse/Spline/Text - anything [_constructionFlagOf] resolves) to
  /// [construction], skipping any already in that state. [toggleSelected
  /// Construction]'s multi-selection sibling - see [availableConstruction
  /// Toggles]'s own doc comment for when the ribbon offers this instead of
  /// (or alongside) the single toggle.
  Future<void> setSelectedConstruction(bool construction) async {
    if (_busy || _sketchId == null) return;
    final targets = _selectionSet
        .where((selection) => _constructionFlagOf(selection) == !construction)
        .toList();
    if (targets.isEmpty) return;
    await _runGuarded(() async {
      for (final target in targets) {
        await _applyConstruction(target, construction);
      }
    });
  }

  /// Stage 13 item 6 (extended by Stage 16 item 7): which constraint-type
  /// buttons the flyout should offer for the current [selectionSet], per the
  /// prompt's selection-set table. Coincident/Parallel/Perpendicular/
  /// EqualLength/Collinear are wired here (Stage 16 item 7 moved them out of
  /// the dimension tool's now-removed button row - see
  /// [SketchDimensionBar]); Concentric/EqualRadius/Tangent remain
  /// `wired: false` since there's no backend Concentric/EqualRadius/Tangent
  /// constraint support yet.
  List<ConstraintOption> get availableConstraintOptions {
    final sel = _selectionSet;

    if (sel.length == 1 && sel.first.kind == SelectionKind.line) {
      return const [
        ConstraintOption(type: ConstraintOptionType.vertical, label: 'Vert.', wired: true),
        ConstraintOption(type: ConstraintOptionType.horizontal, label: 'Horiz.', wired: true),
      ];
    }

    // P35 (on-device feedback: selecting a Circle/Arc offered nothing at
    // all here - not even a way to give it a size) - offered whenever
    // there's no radius/diameter DistanceConstraint on it yet (skip if one
    // already exists so this doesn't invite creating a redundant/
    // conflicting second one; the existing one is edited via its own label
    // drag/ribbon value box instead, same as every other confirmed
    // dimension already is).
    if (sel.length == 1 &&
        (sel.first.kind == SelectionKind.circle || sel.first.kind == SelectionKind.arc) &&
        !_hasRadiusDimension(sel.first)) {
      return const [
        ConstraintOption(type: ConstraintOptionType.radius, label: 'Radius', wired: true),
      ];
    }

    if (sel.length != 2) return const [];

    final kinds = sel.map((s) => s.kind).toSet();

    if (kinds.length == 1 && kinds.single == SelectionKind.line) {
      return const [
        ConstraintOption(type: ConstraintOptionType.parallel, label: 'Parallel', wired: true),
        ConstraintOption(
          type: ConstraintOptionType.perpendicular,
          label: 'Perp.',
          wired: true,
        ),
        ConstraintOption(type: ConstraintOptionType.equalLength, label: 'Equal', wired: true),
        ConstraintOption(type: ConstraintOptionType.collinear, label: 'Collinear', wired: true),
      ];
    }

    if (kinds.length == 1 && kinds.single == SelectionKind.circle) {
      return const [
        ConstraintOption(type: ConstraintOptionType.concentric, label: 'Concentric', wired: false),
        ConstraintOption(type: ConstraintOptionType.equalRadius, label: 'Equal radius', wired: false),
      ];
    }

    if (kinds.contains(SelectionKind.circle) && kinds.contains(SelectionKind.line)) {
      return const [ConstraintOption(type: ConstraintOptionType.tangent, label: 'Tangent', wired: false)];
    }

    if (kinds.every((k) => k == SelectionKind.point || k == SelectionKind.line)) {
      return const [ConstraintOption(type: ConstraintOptionType.coincident, label: 'Coinc.', wired: true)];
    }

    return const [];
  }

  /// Applies a wired [ConstraintOption] from the flyout - a no-op (besides
  /// being unreachable from the UI, since unwired options render
  /// non-tappable) for Concentric/EqualRadius/Tangent.
  Future<void> applyConstraintOption(ConstraintOptionType type) async {
    switch (type) {
      case ConstraintOptionType.vertical:
        await addVerticalConstraint();
        break;
      case ConstraintOptionType.horizontal:
        await addHorizontalConstraint();
        break;
      case ConstraintOptionType.coincident:
        await addCoincidentConstraint();
        break;
      case ConstraintOptionType.parallel:
        await addParallelConstraint();
        break;
      case ConstraintOptionType.perpendicular:
        await addPerpendicularConstraint();
        break;
      case ConstraintOptionType.equalLength:
        await addEqualLengthConstraint();
        break;
      case ConstraintOptionType.collinear:
        await addCollinearConstraint();
        break;
      case ConstraintOptionType.radius:
        await addRadiusDimensionFor(_selectionSet.first);
        break;
      default:
        break;
    }
  }

  /// [availableConstraintOptions]'s own "does [selection] already have a
  /// radius/diameter dimension" check - true if any [DistanceConstraintDto]
  /// resolves to it via [circleForDistanceConstraint]/[arcForDistanceConstraint].
  bool _hasRadiusDimension(SketchSelection selection) {
    for (final constraint in constraints.values) {
      if (constraint is! DistanceConstraintDto) continue;
      // A provisional constraint (see its own doc comment) is invisible to
      // the user - a freshly-placed Circle/Arc already carries one, but it
      // must not itself count as "already has a dimension" here, or the
      // Radius option would never be offered on anything just drawn.
      if (constraint.provisional) continue;
      final ownerId = circleForDistanceConstraint(constraint)?.id ?? arcForDistanceConstraint(constraint)?.id;
      if (ownerId == selection.id) return true;
    }
    return false;
  }

  /// P35 (on-device feedback: selecting a Circle/Arc offered no way to add
  /// its radius/diameter without first switching to the Dimension tool and
  /// re-tapping it): the ribbon's own fast path - jumps straight into
  /// [SketchMode.dimension] with [selection] already picked, exactly the
  /// state a user would reach by switching tools and tapping the same
  /// entity once, so every existing ghost-building/value-entry/undo path
  /// ([SketchDimensionBar], [_rebuildDimensionGhosts], [confirmGhostValue])
  /// already works completely unmodified - this only ever fast-forwards
  /// into that same flow, never duplicates any of its logic.
  Future<void> addRadiusDimensionFor(SketchSelection selection) async {
    if (_busy || _sketchId == null) return;
    if (selection.kind != SelectionKind.circle && selection.kind != SelectionKind.arc) return;
    dropGrabbedEntity();
    _mode = SketchMode.dimension;
    _fabMenu = FabMenuState.closed;
    _resetTransientDrawState();
    _selectionSet.clear();
    _ribbonVisible = false;
    _dimensionSelection
      ..clear()
      ..add(selection);
    _activeGhostKey = null;
    _rebuildDimensionGhosts();
    notifyListeners();
  }

  Future<void> addVerticalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      final constraint = await _api.createVerticalConstraint(_sketchId!, current.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
      await _solveAndTrackDof();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  Future<void> addHorizontalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      final constraint = await _api.createHorizontalConstraint(_sketchId!, current.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
      await _solveAndTrackDof();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  // --- Stage 13 item 5: Dimension mode --------------------------------

  final List<SketchSelection> _dimensionSelection = [];

  /// The entity/entities picked so far in [SketchMode.dimension] - shown as
  /// a running list in [SketchDimensionBar] (new work package item 6).
  /// Capped at two entries - every combination rule below is pairwise, so a
  /// third tap starts a fresh pick rather than accumulating further.
  List<SketchSelection> get dimensionSelection => List.unmodifiable(_dimensionSelection);

  List<DimensionGhost> _ghosts = [];

  /// The ghost dimension(s) currently shown for [dimensionSelection] - one
  /// (length) for a Line, two (V/H or radius/diameter) otherwise. Empty
  /// when nothing is picked.
  List<DimensionGhost> get ghosts => List.unmodifiable(_ghosts);

  String? _activeGhostKey;

  /// The [DimensionGhost.key] the user tapped to start editing, or null if
  /// none - drives the active/dimmed ghost colouring (Stage 13 item 6) and
  /// which ghost the inline text input is attached to.
  String? get activeGhostKey => _activeGhostKey;

  /// [SketchMode.dimension]'s tap handling (revamped per the new work
  /// package): resolves the tap (including line-midpoint materialization,
  /// same as [_handleSelectTap]) and hands it to [_applyDimensionHit].
  Future<void> _handleDimensionTap(double hitRadius) async {
    if (_busy) return;
    SketchSelection? hit;
    await _runGuarded(() async {
      hit = await _resolveSelectableAt(hitRadius);
    });
    _applyDimensionHit(hit);
  }

  /// [SketchMode.trim]'s tap handling (Phase 11, extended by the on-device
  /// feedback round that added Circle/Arc/split-Line support) - reuses
  /// [_entityAt] (the same nearest-entity hit-test Select mode's own tap
  /// handling uses) rather than a Line-only search, then dispatches by
  /// kind: [_handleTrimLineTap]/[_handleTrimCircleTap]/[_handleTrimArcTap].
  /// Point/Ellipse/Spline/Text/Constraint hits are silently ignored (not
  /// valid trim targets - Spline/Ellipse have no backend intersection
  /// support at all, see `intersections.py`'s own module doc comment).
  /// Stays in trim mode after every tap, hit or miss - a miss is silently
  /// ignored, and a 400/422 from the backend surfaces via [errorMessage]
  /// exactly like any other API failure - both leave the tool "hot" for
  /// another attempt rather than exiting, mirroring a real CAD trim tool.
  Future<void> _handleTrimTap(double hitRadius) async {
    if (_busy || _sketchId == null) return;
    final hit = _entityAt(cursorX, cursorY, hitRadius);
    if (hit == null) return;
    switch (hit.kind) {
      case SelectionKind.line:
        await _handleTrimLineTap(hit.id);
      case SelectionKind.circle:
        await _handleTrimCircleTap(hit.id);
      case SelectionKind.arc:
        await _handleTrimArcTap(hit.id);
      default:
        return;
    }
  }

  /// P37 (on-device feedback: "trim/extend should prioritize the part of
  /// the line clicked, it maybe the middle, eg. a line completely crossing
  /// through a circle"): tries [SketchApiClient.splitTrimLine] first
  /// (click-position-based - removes just the clicked segment when it's
  /// genuinely bracketed by two interior crossings), falling back to the
  /// original nearest-endpoint [SketchApiClient.trimLine] behaviour on a
  /// 422 (see that method's own doc comment for exactly what 422 means
  /// here) - every other failure propagates normally. This preserves 100%
  /// of the original single-endpoint trim/extend behaviour for every case
  /// split-trim doesn't apply to, additive rather than a replacement.
  Future<void> _handleTrimLineTap(String lineId) async {
    final line = lines[lineId];
    if (line == null) return;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return;
    final originalConstruction = line.construction;
    final originalStartPointId = line.startPointId;
    final originalEndPointId = line.endPointId;

    await _runGuarded(() async {
      try {
        final result = await _api.splitTrimLine(_sketchId!, lineId, cursorX, cursorY);
        lines.remove(lineId);
        for (final split in [result.line1, result.line2]) {
          lines[split.id] = SketchLineView(
            id: split.id,
            startPointId: split.startPointId,
            endPointId: split.endPointId,
            construction: split.construction,
          );
        }
        // The two new boundary Points (one per split line, at each
        // crossing) aren't in `points` yet - `_solveAndTrackDof` below
        // fully refreshes `points` from the backend's own authoritative
        // solve response (see its own doc comment), so they land correctly
        // without needing to be staged here first.
        final newLine1Id = result.line1.id;
        final newLine2Id = result.line2.id;
        _pushUndo(() async {
          await _api.deleteLine(_sketchId!, newLine1Id);
          lines.remove(newLine1Id);
          await _api.deleteLine(_sketchId!, newLine2Id);
          lines.remove(newLine2Id);
          final restored = await _api.createLine(
            _sketchId!,
            originalStartPointId,
            originalEndPointId,
            construction: originalConstruction,
          );
          lines[restored.id] = SketchLineView(
            id: restored.id,
            startPointId: restored.startPointId,
            endPointId: restored.endPointId,
            construction: restored.construction,
          );
        });
        await _solveAndTrackDof();
        return;
      } on ApiException catch (e) {
        if (e.statusCode != 422) rethrow;
        // Not bracketed by two interior crossings - fall through to the
        // original single-endpoint trim/extend below, unmodified.
      }

      final toStartSq =
          (cursorX - start.x) * (cursorX - start.x) + (cursorY - start.y) * (cursorY - start.y);
      final toEndSq = (cursorX - end.x) * (cursorX - end.x) + (cursorY - end.y) * (cursorY - end.y);
      final movedPointId = toStartSq <= toEndSq ? line.startPointId : line.endPointId;
      final keptPointId = movedPointId == line.startPointId ? line.endPointId : line.startPointId;
      final movedPointOldX = movedPointId == line.startPointId ? start.x : end.x;
      final movedPointOldY = movedPointId == line.startPointId ? start.y : end.y;

      final result = await _api.trimLine(_sketchId!, lineId, movedPointId);
      lines[result.line.id] = SketchLineView(
        id: result.line.id,
        startPointId: result.line.startPointId,
        endPointId: result.line.endPointId,
        construction: result.line.construction,
      );
      points[result.movedPoint.id] = SketchPointView(
        id: result.movedPoint.id,
        x: result.movedPoint.x,
        y: result.movedPoint.y,
      );
      if (result.createdNewPoint) {
        // The shared-Point case: the trimmed Line (same id, per
        // `trim_or_extend_line`) now points at a brand-new Point instead of
        // `movedPointId`, which is left untouched (still possibly shared
        // with other geometry) - there's no API to repoint a Line's
        // endpoint id directly (`PATCH .../lines/{id}` only takes
        // `length`/`construction`), so undo deletes this Line and its new
        // Point, then recreates the Line fresh between the two *original*
        // endpoints, same fresh-id-on-recreation convention as
        // [_restoreDeletedEntities].
        final newPointId = result.movedPoint.id;
        _pushUndo(() async {
          await _api.deleteLine(_sketchId!, lineId);
          lines.remove(lineId);
          await _api.deletePoint(_sketchId!, newPointId);
          points.remove(newPointId);
          final restored = await _api.createLine(
            _sketchId!,
            movedPointId,
            keptPointId,
            construction: originalConstruction,
          );
          lines[restored.id] = SketchLineView(
            id: restored.id,
            startPointId: restored.startPointId,
            endPointId: restored.endPointId,
            construction: restored.construction,
          );
        });
      } else {
        // The unshared-endpoint case: `movedPointId` itself moved in place,
        // so undo is a plain position revert.
        _pushUndo(() async {
          await _api.updatePoint(_sketchId!, movedPointId, movedPointOldX, movedPointOldY);
          points[movedPointId] = SketchPointView(id: movedPointId, x: movedPointOldX, y: movedPointOldY);
        });
      }

      await _solveAndTrackDof();
    });
  }

  /// P36 (on-device feedback: "trim/extend should work on circles curves
  /// and splines"): [SketchApiClient.trimArc] mirrors [trimLine]'s own
  /// nearest-endpoint contract exactly, so this handler is a near-verbatim
  /// copy of the Line case above (split-trim doesn't apply to a curved
  /// entity - there's no equivalent "clicked the middle segment" case for
  /// an Arc the way there is for a straight Line).
  Future<void> _handleTrimArcTap(String arcId) async {
    final arc = arcs[arcId];
    if (arc == null) return;
    final start = points[arc.startPointId];
    final end = points[arc.endPointId];
    if (start == null || end == null) return;
    final originalConstruction = arc.construction;

    await _runGuarded(() async {
      final toStartSq =
          (cursorX - start.x) * (cursorX - start.x) + (cursorY - start.y) * (cursorY - start.y);
      final toEndSq = (cursorX - end.x) * (cursorX - end.x) + (cursorY - end.y) * (cursorY - end.y);
      final movedPointId = toStartSq <= toEndSq ? arc.startPointId : arc.endPointId;
      final keptPointId = movedPointId == arc.startPointId ? arc.endPointId : arc.startPointId;
      final movedPointOldX = movedPointId == arc.startPointId ? start.x : end.x;
      final movedPointOldY = movedPointId == arc.startPointId ? start.y : end.y;
      final centerPointId = arc.centerPointId;

      final result = await _api.trimArc(_sketchId!, arcId, movedPointId);
      arcs[result.arc.id] = SketchArcView(
        id: result.arc.id,
        centerPointId: result.arc.centerPointId,
        startPointId: result.arc.startPointId,
        endPointId: result.arc.endPointId,
        construction: result.arc.construction,
      );
      points[result.movedPoint.id] = SketchPointView(
        id: result.movedPoint.id,
        x: result.movedPoint.x,
        y: result.movedPoint.y,
      );
      if (result.createdNewPoint) {
        final newPointId = result.movedPoint.id;
        _pushUndo(() async {
          await _api.deleteArc(_sketchId!, arcId);
          arcs.remove(arcId);
          await _api.deletePoint(_sketchId!, newPointId);
          points.remove(newPointId);
          final restored = await _api.createArc(
            _sketchId!,
            centerPointId,
            movedPointId,
            keptPointId,
            construction: originalConstruction,
          );
          arcs[restored.id] = SketchArcView(
            id: restored.id,
            centerPointId: restored.centerPointId,
            startPointId: restored.startPointId,
            endPointId: restored.endPointId,
            construction: restored.construction,
          );
        });
      } else {
        _pushUndo(() async {
          await _api.updatePoint(_sketchId!, movedPointId, movedPointOldX, movedPointOldY);
          points[movedPointId] = SketchPointView(id: movedPointId, x: movedPointOldX, y: movedPointOldY);
        });
      }

      await _solveAndTrackDof();
    });
  }

  /// P36: a Circle has no endpoint to move - trimming it converts it into
  /// an Arc excluding whichever segment [cursorX]/[cursorY] falls on (see
  /// the backend's `Sketch.trim_circle`). Undo recreates a plain Circle at
  /// the original centre/radius Points (both untouched by the trim, per
  /// `delete_circle`'s own doc comment) - a real, accepted imperfection:
  /// the original Circle's own cardinal Points/constraints are gone for
  /// good (a fresh `createCircle` call makes brand-new ones), left as
  /// orphaned geometry rather than chased down and restored, the same
  /// "additive, not exhaustive" scope this whole round of trim work has
  /// kept to elsewhere.
  Future<void> _handleTrimCircleTap(String circleId) async {
    final circle = circles[circleId];
    if (circle == null) return;
    final centerPointId = circle.centerPointId;
    final radiusPointId = circle.radiusPointId;
    final originalConstruction = circle.construction;

    await _runGuarded(() async {
      final arcDto = await _api.trimCircle(_sketchId!, circleId, cursorX, cursorY);
      circles.remove(circleId);
      arcs[arcDto.id] = SketchArcView(
        id: arcDto.id,
        centerPointId: arcDto.centerPointId,
        startPointId: arcDto.startPointId,
        endPointId: arcDto.endPointId,
        construction: arcDto.construction,
      );
      final newArcId = arcDto.id;
      _pushUndo(() async {
        await _api.deleteArc(_sketchId!, newArcId);
        arcs.remove(newArcId);
        final restored = await _api.createCircle(
          _sketchId!,
          centerPointId,
          radiusPointId,
          construction: originalConstruction,
        );
        circles[restored.id] = SketchCircleView(
          id: restored.id,
          centerPointId: restored.centerPointId,
          radiusPointId: restored.radiusPointId,
          construction: restored.construction,
          cardinalPointIds: restored.cardinalPointIds,
        );
      });
      await _solveAndTrackDof();
    });
  }

  /// Tapping an already-picked entity again removes it from the pick (so a
  /// mis-tap is easy to undo without exiting the tool); tapping a third,
  /// new entity starts a fresh pick with just that one; tapping empty
  /// canvas clears the current pick, or exits to [SketchMode.select] if
  /// nothing was picked at all (unchanged from Stage 13 item 5). Every
  /// successful pick re-derives the ghost set from scratch via
  /// [_rebuildDimensionGhosts] - there's no incremental ghost state to keep
  /// in sync.
  void _applyDimensionHit(SketchSelection? hit) {
    if (hit == null) {
      if (_dimensionSelection.isEmpty) {
        exitToSelectMode();
      } else {
        _dimensionSelection.clear();
        _ghosts = [];
        _activeGhostKey = null;
        notifyListeners();
      }
      return;
    }

    if (_dimensionSelection.any((s) => s.sameAs(hit))) {
      _dimensionSelection.removeWhere((s) => s.sameAs(hit));
    } else if (_dimensionSelection.length >= 2) {
      _dimensionSelection
        ..clear()
        ..add(hit);
    } else {
      _dimensionSelection.add(hit);
    }
    _activeGhostKey = null;
    _rebuildDimensionGhosts();
    notifyListeners();
  }

  // Sketcher-roadmap Phase 4.3 v1: "bodyId:vertexIndex" -> the real Point
  // id [pickReferenceGhostVertex] already materialized for it, so re-
  // picking the same ghost vertex (e.g. after cancelling a pick, or to
  // dimension a second thing off the same corner) reuses that Point
  // rather than creating a duplicate. Session-only, like every other
  // client-side view cache in this file - reset on reload, never sent to
  // the backend (the backend's own source of truth is `Sketch.
  // external_references`, keyed by Point id in the other direction).
  final Map<String, String> _externalReferencePointIds = {};

  /// Sketcher-roadmap Phase 4.3 v1: dimension-mode's own body-vertex pick -
  /// called by [SketchCanvas] when a tap lands on one of its own
  /// `referenceGhostVertices` markers rather than any real sketch entity
  /// (see that widget's own hit-testing). Materializes the vertex as a
  /// real backend Point on first pick (reusing the same Point on every
  /// later re-pick, via [_externalReferencePointIds]), then hands it
  /// straight to [_applyDimensionHit] as an ordinary [SelectionKind.point]
  /// hit - a materialized external-reference Point is indistinguishable
  /// from any other Point from this call onward, so every existing ghost-
  /// building/confirm/undo path already works against it unmodified. A
  /// no-op if this Sketch wasn't opened from a Part (no [_documentPartId]/
  /// [_documentSketchFeatureId] to call the endpoint with) - there are no
  /// Bodies to reference at all in that case.
  Future<void> pickReferenceGhostVertex(String bodyId, int vertexIndex) async {
    if (_busy || _sketchId == null) return;
    final partId = _documentPartId;
    final sketchFeatureId = _documentSketchFeatureId;
    if (partId == null || sketchFeatureId == null) return;

    final cacheKey = '$bodyId:$vertexIndex';
    final existingId = _externalReferencePointIds[cacheKey];
    if (existingId != null && points.containsKey(existingId)) {
      _applyDimensionHit(SketchSelection(kind: SelectionKind.point, id: existingId));
      return;
    }

    SketchSelection? hit;
    await _runGuarded(() async {
      final point = await _api.createExternalVertexReference(partId, sketchFeatureId, bodyId, vertexIndex);
      points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      _externalReferencePointIds[cacheKey] = point.id;
      hit = SketchSelection(kind: SelectionKind.point, id: point.id);
    });
    _applyDimensionHit(hit);
  }

  // Sketcher-roadmap Phase 4.3 v2: "bodyId:edgeIndex" -> the real Line id
  // [pickReferenceGhostEdge] already materialized for it - same reuse-on-
  // re-pick reasoning as [_externalReferencePointIds].
  final Map<String, String> _externalReferenceLineIds = {};

  /// Sketcher-roadmap Phase 4.3 v2: dimension-mode's own body-edge pick -
  /// [pickReferenceGhostVertex]'s sibling, called by [SketchCanvas] when a
  /// tap lands on the dashed ghost outline itself rather than one of its
  /// vertex markers. Materializes the whole edge as a real, pinned Line
  /// (via two external-reference Points - see the backend's
  /// `create_external_edge_reference` doc comment) on first pick, reusing
  /// the same Line on every later re-pick via
  /// [_externalReferenceLineIds], then hands it straight to
  /// [_applyDimensionHit] as an ordinary [SelectionKind.line] hit - once
  /// materialized, a picked ghost edge is indistinguishable from any other
  /// Line, so every existing ghost-building/confirm/undo path (length,
  /// parallel/perpendicular, LineDistance, ...) already works against it
  /// unmodified. Same no-op guard as [pickReferenceGhostVertex] for a bare,
  /// non-Part Sketch.
  Future<void> pickReferenceGhostEdge(String bodyId, int edgeIndex) async {
    if (_busy || _sketchId == null) return;
    final partId = _documentPartId;
    final sketchFeatureId = _documentSketchFeatureId;
    if (partId == null || sketchFeatureId == null) return;

    final cacheKey = '$bodyId:$edgeIndex';
    final existingId = _externalReferenceLineIds[cacheKey];
    if (existingId != null && lines.containsKey(existingId)) {
      _applyDimensionHit(SketchSelection(kind: SelectionKind.line, id: existingId));
      return;
    }

    SketchSelection? hit;
    await _runGuarded(() async {
      final result = await _api.createExternalEdgeReference(partId, sketchFeatureId, bodyId, edgeIndex);
      points[result.startPoint.id] =
          SketchPointView(id: result.startPoint.id, x: result.startPoint.x, y: result.startPoint.y);
      points[result.endPoint.id] =
          SketchPointView(id: result.endPoint.id, x: result.endPoint.x, y: result.endPoint.y);
      lines[result.line.id] = SketchLineView(
        id: result.line.id,
        startPointId: result.line.startPointId,
        endPointId: result.line.endPointId,
        construction: result.line.construction,
      );
      _externalReferenceLineIds[cacheKey] = result.line.id;
      hit = SketchSelection(kind: SelectionKind.line, id: result.line.id);
    });
    _applyDimensionHit(hit);
  }

  /// Dispatches [_dimensionSelection]'s current shape onto a ghost set, per
  /// the new work package's combination table: one Line -> length; one
  /// Circle or Arc -> radius+diameter; two Points, or a Point+Line
  /// (substituting the Line's nearer endpoint - the backend has no
  /// point-to-line distance constraint, see [_buildPointLineGhosts]) ->
  /// vertical/horizontal/linear distance; two Lines -> a line-pair distance
  /// ghost if they're (near-)parallel, otherwise an angle ghost (see
  /// [_buildLinePairGhosts]). Any other shape (a bare Point/Circle/Arc
  /// alone, or anything with more than two entities) shows no ghosts.
  void _rebuildDimensionGhosts() {
    final sel = _dimensionSelection;

    if (sel.length == 1) {
      switch (sel.first.kind) {
        case SelectionKind.line:
          _buildLineLengthGhost(sel.first.id);
          return;
        case SelectionKind.circle:
          final circle = circles[sel.first.id];
          if (circle == null) {
            _ghosts = [];
          } else {
            _buildRadiusGhosts(circle.centerPointId, circle.radiusPointId);
          }
          return;
        case SelectionKind.arc:
          final arc = arcs[sel.first.id];
          if (arc == null) {
            _ghosts = [];
          } else {
            _buildRadiusGhosts(arc.centerPointId, arc.startPointId);
          }
          return;
        case SelectionKind.ellipse:
          // Feedback round: both axes are now real, independently
          // dimensionable DistanceConstraints (see the Ellipse class's
          // docstring) - selecting the whole Ellipse offers both axes'
          // radius+diameter ghosts at once, distinguished by keyPrefix so
          // they don't collide in the same _ghosts list.
          final ellipse = ellipses[sel.first.id];
          if (ellipse == null) {
            _ghosts = [];
          } else {
            _ghosts = [
              ..._radiusGhosts(ellipse.centerPointId, ellipse.majorPointId, keyPrefix: 'major'),
              ..._radiusGhosts(ellipse.centerPointId, ellipse.minorPointId, keyPrefix: 'minor'),
            ];
          }
          return;
        case SelectionKind.spline:
          // A Spline has no single dimension of its own to build a ghost
          // for - its shape comes entirely from its through-point/
          // control-handle Points' own positions (each independently
          // dimensionable as an ordinary Point) and its
          // SplineTangentConstraints, which aren't user-editable numeric
          // values.
        case SelectionKind.text:
          // Likewise, a Text entity's content/size/rotation are plain
          // direct edits (see setTextProperties, wired to the ribbon's own
          // "Edit Text" action), not a DistanceConstraint-backed dimension -
          // nothing to build a ghost for here.
        case SelectionKind.point:
        case SelectionKind.constraint:
          _ghosts = [];
          return;
      }
    }

    if (sel.length == 2) {
      final a = sel[0];
      final b = sel[1];
      final kinds = {a.kind, b.kind};

      if (kinds.length == 1 && kinds.single == SelectionKind.point) {
        _buildPointDistanceGhosts(a.id, b.id);
        return;
      }
      if (kinds.length == 1 && kinds.single == SelectionKind.line) {
        _buildLinePairGhosts(a.id, b.id);
        return;
      }
      if (kinds.contains(SelectionKind.point) && kinds.contains(SelectionKind.line)) {
        final pointSel = a.kind == SelectionKind.point ? a : b;
        final lineSel = a.kind == SelectionKind.line ? a : b;
        _buildPointLineGhosts(pointSel.id, lineSel.id);
        return;
      }
      _ghosts = [];
      return;
    }

    _ghosts = [];
  }

  void _buildLineLengthGhost(String lineId) {
    final line = lines[lineId];
    _ghosts = line == null
        ? []
        : [
            DimensionGhost(
              key: 'length',
              kind: GhostKind.length,
              pointAId: line.startPointId,
              pointBId: line.endPointId,
            ),
          ];
  }

  /// Two Points: vertical/horizontal components plus the direct
  /// point-to-point ("linear") distance - new work package item 6's
  /// "distance (vertical, horizontal and linear)".
  void _buildPointDistanceGhosts(String pointAId, String pointBId) {
    _ghosts = [
      DimensionGhost(key: 'v', kind: GhostKind.vertical, pointAId: pointAId, pointBId: pointBId),
      DimensionGhost(key: 'h', kind: GhostKind.horizontal, pointAId: pointAId, pointBId: pointBId),
      DimensionGhost(key: 'linear', kind: GhostKind.linear, pointAId: pointAId, pointBId: pointBId),
    ];
  }

  /// A Point + a Line: the backend's `DistanceConstraint` only ever
  /// connects two Points, so this substitutes the Line's nearer endpoint
  /// for the Line itself and reuses the two-Point ghost set - a documented
  /// scoping tradeoff (true point-to-line distance isn't representable as
  /// a live constraint in this backend), not point-to-line distance.
  void _buildPointLineGhosts(String pointId, String lineId) {
    final line = lines[lineId];
    final point = points[pointId];
    if (line == null || point == null) {
      _ghosts = [];
      return;
    }
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) {
      _ghosts = [];
      return;
    }
    final distToStart = math.pow(point.x - start.x, 2) + math.pow(point.y - start.y, 2);
    final distToEnd = math.pow(point.x - end.x, 2) + math.pow(point.y - end.y, 2);
    final nearestEndpointId = distToStart <= distToEnd ? line.startPointId : line.endPointId;
    _buildPointDistanceGhosts(pointId, nearestEndpointId);
  }

  /// How close to parallel (in radians, via the cross product of the two
  /// direction vectors) two Lines must be to offer a distance ghost instead
  /// of an angle ghost - about 1.1 degrees of slack for taps that aren't
  /// pixel-perfectly aligned.
  static const double _parallelToleranceRadians = 0.02;

  bool _linesAreParallel(SketchLineView lineA, SketchLineView lineB) {
    final a1 = points[lineA.startPointId];
    final a2 = points[lineA.endPointId];
    final b1 = points[lineB.startPointId];
    final b2 = points[lineB.endPointId];
    if (a1 == null || a2 == null || b1 == null || b2 == null) return false;
    final ax = a2.x - a1.x;
    final ay = a2.y - a1.y;
    final bx = b2.x - b1.x;
    final by = b2.y - b1.y;
    final lenA = math.sqrt(ax * ax + ay * ay);
    final lenB = math.sqrt(bx * bx + by * by);
    if (lenA == 0 || lenB == 0) return false;
    final cross = (ax * by - ay * bx) / (lenA * lenB);
    return cross.abs() <= math.sin(_parallelToleranceRadians);
  }

  /// Two Lines: a distance ghost (between their current midpoints - see
  /// [confirmGhostValue]'s `lineDistance` branch) if they're parallel,
  /// otherwise an angle ghost - new work package item 6's "two parallel
  /// lines or points distance, two non-parallel lines, angle".
  void _buildLinePairGhosts(String lineAId, String lineBId) {
    final lineA = lines[lineAId];
    final lineB = lines[lineBId];
    if (lineA == null || lineB == null) {
      _ghosts = [];
      return;
    }
    _ghosts = _linesAreParallel(lineA, lineB)
        ? [DimensionGhost(key: 'lineDistance', kind: GhostKind.lineDistance, lineAId: lineAId, lineBId: lineBId)]
        : [DimensionGhost(key: 'angle', kind: GhostKind.angle, lineAId: lineAId, lineBId: lineBId)];
  }

  /// Radius+diameter ghosts for a Circle (center/radiusPointId) or an Arc
  /// (center/startPointId - either of an Arc's two radius-defining Points
  /// works equally, see [isRadiusDistanceConstraint]'s own doc comment) -
  /// [centerPointId]/[edgePointId] generalize both shapes' "center Point,
  /// Point on the circle" pair to one shared builder. [keyPrefix] keeps
  /// each pair's ghost keys unique when more than one radius ghost pair
  /// coexists in the same selection (an Ellipse's major and minor axes -
  /// see [_rebuildDimensionGhosts]'s `SelectionKind.ellipse` case).
  List<DimensionGhost> _radiusGhosts(String centerPointId, String edgePointId, {String keyPrefix = ''}) => [
        DimensionGhost(
          key: '${keyPrefix}radius',
          kind: GhostKind.radius,
          pointAId: centerPointId,
          pointBId: edgePointId,
        ),
        DimensionGhost(
          key: '${keyPrefix}diameter',
          kind: GhostKind.diameter,
          pointAId: centerPointId,
          pointBId: edgePointId,
        ),
      ];

  void _buildRadiusGhosts(String centerPointId, String edgePointId) {
    _ghosts = _radiusGhosts(centerPointId, edgePointId);
  }

  /// The angle (degrees, 0-180) between two Lines' direction vectors - the
  /// `angle` ghost's preview value, and the value sent to
  /// [SketchApiClient.createAngleConstraint]/[SketchApiClient.updateConstraintValue].
  double? _angleBetweenLinesDegrees(SketchLineView lineA, SketchLineView lineB) {
    final a1 = points[lineA.startPointId];
    final a2 = points[lineA.endPointId];
    final b1 = points[lineB.startPointId];
    final b2 = points[lineB.endPointId];
    if (a1 == null || a2 == null || b1 == null || b2 == null) return null;
    final ax = a2.x - a1.x;
    final ay = a2.y - a1.y;
    final bx = b2.x - b1.x;
    final by = b2.y - b1.y;
    final lenA = math.sqrt(ax * ax + ay * ay);
    final lenB = math.sqrt(bx * bx + by * by);
    if (lenA == 0 || lenB == 0) return null;
    final cosAngle = ((ax * bx + ay * by) / (lenA * lenB)).clamp(-1.0, 1.0);
    return math.acos(cosAngle) * 180 / math.pi;
  }

  AngleConstraintDto? _findAngleConstraint(String line1Id, String line2Id) {
    for (final constraint in constraints.values) {
      if (constraint is AngleConstraintDto &&
          ((constraint.line1Id == line1Id && constraint.line2Id == line2Id) ||
              (constraint.line1Id == line2Id && constraint.line2Id == line1Id))) {
        return constraint;
      }
    }
    return null;
  }

  /// The current solved value a ghost would prefill its inline text input
  /// with - the ghost's own ? label (Stage 13 item 5/6's visual spec) is
  /// unaffected by this; it's still always "?" until a value is confirmed.
  double? currentGhostValue(DimensionGhost ghost) {
    if (ghost.kind == GhostKind.lineDistance) {
      final lineA = lines[ghost.lineAId];
      final lineB = lines[ghost.lineBId];
      if (lineA == null || lineB == null) return null;
      final startA = points[lineA.startPointId];
      final endA = points[lineA.endPointId];
      final startB = points[lineB.startPointId];
      final endB = points[lineB.endPointId];
      if (startA == null || endA == null || startB == null || endB == null) return null;
      final midAX = (startA.x + endA.x) / 2;
      final midAY = (startA.y + endA.y) / 2;
      final midBX = (startB.x + endB.x) / 2;
      final midBY = (startB.y + endB.y) / 2;
      return math.sqrt(math.pow(midBX - midAX, 2) + math.pow(midBY - midAY, 2));
    }
    if (ghost.kind == GhostKind.angle) {
      final lineA = lines[ghost.lineAId];
      final lineB = lines[ghost.lineBId];
      if (lineA == null || lineB == null) return null;
      return _angleBetweenLinesDegrees(lineA, lineB);
    }

    final a = points[ghost.pointAId];
    final b = points[ghost.pointBId];
    if (a == null || b == null) return null;
    switch (ghost.kind) {
      case GhostKind.length:
      case GhostKind.linear:
      case GhostKind.radius:
        return math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
      case GhostKind.diameter:
        return 2 * math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
      case GhostKind.vertical:
        return (b.y - a.y).abs();
      case GhostKind.horizontal:
        return (b.x - a.x).abs();
      case GhostKind.lineDistance:
      case GhostKind.angle:
        return null; // handled above.
    }
  }

  /// Marks [key] as the actively-edited ghost - tapping a ghost label opens
  /// its inline text input (Stage 13 item 5) and dims the other ghost, if
  /// any (item 6's visual spec).
  void tapGhost(String key) {
    if (!_ghosts.any((g) => g.key == key)) return;
    _activeGhostKey = key;
    notifyListeners();
  }

  /// Tap-away/keyboard-cancel from the inline text input - returns to
  /// showing both ghosts at their default (non-active) colour.
  void cancelGhostEdit() {
    _activeGhostKey = null;
    notifyListeners();
  }

  /// Finds an existing `DistanceConstraint` between [pointAId]/[pointBId]
  /// (either order). [orientation], when given, additionally requires an
  /// exact orientation match - bug-fix round: [confirmGhostValue] used to
  /// call this ignoring orientation entirely, so re-tapping e.g. a
  /// "horizontal" ghost for a point pair that already had a "linear"
  /// DistanceConstraint from an earlier placement would silently just PATCH
  /// that existing linear constraint's *value* (orientation is never part
  /// of what a PATCH changes - see `update_constraint_value`), never
  /// actually creating/switching to the horizontal one the user picked -
  /// the dimension stayed linear ("diagonal") no matter what was tapped.
  DistanceConstraintDto? _findDistanceConstraint(String pointAId, String pointBId, {String? orientation}) {
    for (final constraint in constraints.values) {
      if (constraint is DistanceConstraintDto &&
          ((constraint.pointAId == pointAId && constraint.pointBId == pointBId) ||
              (constraint.pointAId == pointBId && constraint.pointBId == pointAId)) &&
          (orientation == null || constraint.orientation == orientation)) {
        return constraint;
      }
    }
    return null;
  }

  LineDistanceConstraintDto? _findLineDistanceConstraint(String lineAId, String lineBId) {
    for (final constraint in constraints.values) {
      if (constraint is LineDistanceConstraintDto &&
          ((constraint.line1Id == lineAId && constraint.line2Id == lineBId) ||
              (constraint.line1Id == lineBId && constraint.line2Id == lineAId))) {
        return constraint;
      }
    }
    return null;
  }

  /// Confirms [key]'s ghost with [value] (Stage 13 item 5): creates a new
  /// `DistanceConstraint` between the ghost's two Points if none exists yet,
  /// or PATCHes the existing one's value otherwise. A diameter ghost is
  /// always stored as a radius `DistanceConstraint` - [value] is halved
  /// before it's sent. Solves and refreshes on success, then dismisses
  /// every ghost and clears the dimension pick, same as the unchosen ghost
  /// in a V/H or radius/diameter pair (Stage 13 item 5: "The unchosen ghost
  /// dismisses on confirm").
  Future<void> confirmGhostValue(String key, double value) async {
    if (_busy || _sketchId == null) return;
    DimensionGhost? ghost;
    for (final candidate in _ghosts) {
      if (candidate.key == key) {
        ghost = candidate;
        break;
      }
    }
    if (ghost == null) return;
    final target = ghost;

    if (target.kind == GhostKind.angle) {
      await _runGuarded(() async {
        final existing = _findAngleConstraint(target.lineAId!, target.lineBId!);
        if (existing != null) {
          final oldValue = existing.angleDegrees;
          await _api.updateConstraintValue(_sketchId!, existing.id, value);
          _pushUndo(() async => _api.updateConstraintValue(_sketchId!, existing.id, oldValue));
        } else {
          final constraint =
              await _api.createAngleConstraint(_sketchId!, target.lineAId!, target.lineBId!, value);
          _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
        }
        await _solveAndTrackDof();
        _ghosts = [];
        _dimensionSelection.clear();
        _activeGhostKey = null;
      });
      return;
    }

    if (target.kind == GhostKind.lineDistance) {
      // Stage 16 item 9: a `LineDistanceConstraint` (backend's
      // SLVS_C_PT_LINE_DISTANCE-equivalent) pins the two Lines directly -
      // no materialized midpoint Points are created, so dragging this
      // dimension moves the Lines themselves, same as every other
      // line-to-line constraint (Parallel, Perpendicular, ...).
      await _runGuarded(() async {
        final existing = _findLineDistanceConstraint(target.lineAId!, target.lineBId!);
        if (existing != null) {
          final oldValue = existing.distance;
          await _api.updateConstraintValue(_sketchId!, existing.id, value);
          _pushUndo(() async => _api.updateConstraintValue(_sketchId!, existing.id, oldValue));
        } else {
          final constraint = await _api.createLineDistanceConstraint(
            _sketchId!,
            target.lineAId!,
            target.lineBId!,
            value,
          );
          _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
        }
        await _solveAndTrackDof();
        _ghosts = [];
        _dimensionSelection.clear();
        _activeGhostKey = null;
      });
      return;
    }

    final pointAId = target.pointAId!;
    final pointBId = target.pointBId!;
    final distanceValue = target.kind == GhostKind.diameter ? value / 2 : value;
    // Prompt B item B3: a horizontal/vertical dimension must keep its H/V
    // nature after solve, not degrade into a plain linear distance - see
    // SketchApiClient.createDistanceConstraint's doc comment.
    final orientation = switch (target.kind) {
      GhostKind.horizontal => 'horizontal',
      GhostKind.vertical => 'vertical',
      _ => 'linear',
    };

    await _runGuarded(() async {
      final existing = _findDistanceConstraint(pointAId, pointBId, orientation: orientation);
      final String constraintId;
      if (existing != null) {
        constraintId = existing.id;
        final oldValue = existing.distance;
        await _api.updateConstraintValue(_sketchId!, existing.id, distanceValue);
        _pushUndo(() async => _api.updateConstraintValue(_sketchId!, existing.id, oldValue));
      } else {
        // Bug-fix round: a DistanceConstraint between these two points
        // *does* already exist, just with a different orientation (e.g. the
        // user first placed a linear dimension here, and is now placing a
        // horizontal one instead) - replace it outright rather than
        // creating a second, conflicting DistanceConstraint alongside it
        // (having both a linear and a horizontal constraint on the same
        // pair simultaneously over-constrains them).
        final mismatched = _findDistanceConstraint(pointAId, pointBId);
        if (mismatched != null) {
          await _api.deleteConstraint(_sketchId!, mismatched.id);
          _pushUndo(() async {
            await _api.createDistanceConstraint(
              _sketchId!,
              mismatched.pointAId,
              mismatched.pointBId,
              mismatched.distance,
              orientation: mismatched.orientation,
            );
          });
        }
        final constraint = await _api.createDistanceConstraint(
          _sketchId!,
          pointAId,
          pointBId,
          distanceValue,
          orientation: orientation,
        );
        constraintId = constraint.id;
        _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
      }
      if (target.kind == GhostKind.radius || target.kind == GhostKind.diameter) {
        _showsDiameter[constraintId] = target.kind == GhostKind.diameter;
      }
      // On-device feedback (bug fix): used to only solve in the new-
      // constraint branch above (the angle/lineDistance branches earlier in
      // this method already solve unconditionally) - re-confirming an
      // *existing* dimension left dof/isFullyConstrained stale exactly the
      // way [setLineLength]/[updateSelectedConstraintValue]'s matching
      // fixes describe.
      await _solveAndTrackDof();
      _ghosts = [];
      _dimensionSelection.clear();
      _activeGhostKey = null;
    });
  }

  /// Stage 15 item 5 (repointed by Stage 16 item 7): whether [type] is both
  /// offered for the current [selectionSet] shape *and* actually wired to
  /// the backend, per [availableConstraintOptions]' selection-set table -
  /// delegating to that getter (rather than re-deriving the same shape
  /// logic here) keeps the two impossible to disagree, e.g. two selected
  /// Lines can never satisfy Coincident's "Point and/or Line" row just
  /// because Lines also happen to match that row's kind check, since
  /// [availableConstraintOptions] already returns its Parallel/
  /// Perpendicular/EqualLength/Collinear row first for that exact shape and
  /// never reaches the Coincident row at all.
  bool canApplyConstraint(ConstraintOptionType type) {
    return availableConstraintOptions.any((option) => option.type == type && option.wired);
  }

  /// Shared by the five methods below: clears [selectionSet] and closes the
  /// flyout on success, same as [addVerticalConstraint]/[addHorizontalConstraint]
  /// - solver errors surface via the existing [_runGuarded]/[errorMessage]
  /// path, nothing new there.
  Future<void> _createSelectionSetConstraint(
    Future<ConstraintDto> Function(String sketchId, String idA, String idB) create,
  ) async {
    if (_selectionSet.length != 2 || _busy || _sketchId == null) return;
    final idA = _selectionSet[0].id;
    final idB = _selectionSet[1].id;
    await _runGuarded(() async {
      final constraint = await create(_sketchId!, idA, idB);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
      await _solveAndTrackDof();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  Future<void> addCoincidentConstraint() async {
    if (!canApplyConstraint(ConstraintOptionType.coincident)) return;
    await _createSelectionSetConstraint(_api.createCoincidentConstraint);
  }

  Future<void> addParallelConstraint() async {
    if (!canApplyConstraint(ConstraintOptionType.parallel)) return;
    await _createSelectionSetConstraint(_api.createParallelConstraint);
  }

  Future<void> addPerpendicularConstraint() async {
    if (!canApplyConstraint(ConstraintOptionType.perpendicular)) return;
    await _createSelectionSetConstraint(_api.createPerpendicularConstraint);
  }

  Future<void> addEqualLengthConstraint() async {
    if (!canApplyConstraint(ConstraintOptionType.equalLength)) return;
    await _createSelectionSetConstraint(_api.createEqualLengthConstraint);
  }

  Future<void> addCollinearConstraint() async {
    if (!canApplyConstraint(ConstraintOptionType.collinear)) return;
    await _createSelectionSetConstraint(_api.createCollinearConstraint);
  }

  Future<void> ensureSketch() async {
    if (_sketchId != null) return;
    await _runGuarded(() async {
      final sketch = await _api.createSketch(plane: 'XY');
      _adoptSketchDto(sketch);
    });
  }

  /// Initializes this controller from an already-created Sketch (e.g. one
  /// wrapped by a SketchFeature via the document API) instead of creating a
  /// brand-new one. Unlike [ensureSketch], the adopted Sketch may already
  /// have real content from a previous editing session, so this also loads
  /// every existing Point/Line/Circle - re-entering a Sketch must reflect
  /// what the backend actually has, not start from an empty canvas.
  ///
  /// Sketcher-roadmap Phase 4.3 v1: [partId]/[sketchFeatureId] (both null
  /// unless this Sketch was opened from [PartScreen] - see
  /// `SketchScreen.documentPartId`/`sketchFeatureId`'s own doc comment) are
  /// only ever needed for [pickReferenceGhostVertex]'s materialize-a-Body-
  /// vertex call, which only makes sense for a Sketch that actually belongs
  /// to a Part with Bodies to reference in the first place.
  Future<void> adoptSketch(String sketchId, {String? partId, String? sketchFeatureId}) async {
    if (_sketchId != null) return;
    _documentPartId = partId;
    _documentSketchFeatureId = sketchFeatureId;
    await _runGuarded(() async {
      final sketch = await _api.getSketch(sketchId);
      _adoptSketchDto(sketch);
      await _loadExistingContent(sketchId);
    });
  }

  Future<void> _loadExistingContent(String sketchId) async {
    for (final point in await _api.listPoints(sketchId)) {
      points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
    }
    for (final line in await _api.listLines(sketchId)) {
      lines[line.id] = SketchLineView(
        id: line.id,
        startPointId: line.startPointId,
        endPointId: line.endPointId,
        construction: line.construction,
      );
    }
    for (final circle in await _api.listCircles(sketchId)) {
      circles[circle.id] = SketchCircleView(
        id: circle.id,
        centerPointId: circle.centerPointId,
        radiusPointId: circle.radiusPointId,
        construction: circle.construction,
        cardinalPointIds: circle.cardinalPointIds,
      );
    }
    for (final arc in await _api.listArcs(sketchId)) {
      arcs[arc.id] = SketchArcView(
        id: arc.id,
        centerPointId: arc.centerPointId,
        startPointId: arc.startPointId,
        endPointId: arc.endPointId,
        construction: arc.construction,
      );
    }
    for (final ellipse in await _api.listEllipses(sketchId)) {
      ellipses[ellipse.id] = SketchEllipseView(
        id: ellipse.id,
        centerPointId: ellipse.centerPointId,
        majorPointId: ellipse.majorPointId,
        majorPointNegId: ellipse.majorPointNegId,
        minorPointId: ellipse.minorPointId,
        minorPointNegId: ellipse.minorPointNegId,
        majorAxisLineId: ellipse.majorAxisLineId,
        minorAxisLineId: ellipse.minorAxisLineId,
        minorRadius: ellipse.minorRadius,
        construction: ellipse.construction,
      );
    }
    for (final polygon in await _api.listPolygons(sketchId)) {
      polygons[polygon.id] = SketchPolygonView(
        id: polygon.id,
        centerPointId: polygon.centerPointId,
        vertexPointIds: polygon.vertexPointIds,
        lineIds: polygon.lineIds,
        sides: polygon.sides,
        construction: polygon.construction,
      );
    }
    for (final spline in await _api.listSplines(sketchId)) {
      splines[spline.id] = SketchSplineView(
        id: spline.id,
        throughPointIds: spline.throughPointIds,
        controlPointIds: spline.controlPointIds,
        construction: spline.construction,
      );
    }
    for (final text in await _api.listTexts(sketchId)) {
      texts[text.id] = SketchTextView(
        id: text.id,
        content: text.content,
        font: text.font,
        size: text.size,
        anchorPointId: text.anchorPointId,
        rotationDegrees: text.rotationDegrees,
        construction: text.construction,
      );
    }
    for (final constraint in await _api.listConstraints(sketchId)) {
      constraints[constraint.id] = constraint;
    }
    // Fetched after every other collection above (so a Text's own anchor
    // Point is already in [points] to compute anchor-relative offsets
    // against - see [_refreshTextPreview]) and concurrently, since these
    // are independent network calls with nothing left to sequence against
    // each other.
    await Future.wait([for (final id in texts.keys) _refreshTextPreview(id)]);
  }

  /// Fetches [textId]'s current server-side outline and re-caches it as
  /// anchor-relative offsets (see [SketchTextContourOffsets]'s own doc
  /// comment) - called right after creating a Text, after every
  /// content/size/rotation edit ([setTextProperties]), and once per Text
  /// while loading an existing sketch ([_loadExistingContent]). A no-op if
  /// [textId] or its own anchor Point isn't (yet) known locally - a stale/
  /// in-flight call racing a local delete.
  Future<void> _refreshTextPreview(String textId) async {
    if (_sketchId == null) return;
    final text = texts[textId];
    final anchor = text == null ? null : points[text.anchorPointId];
    if (text == null || anchor == null) return;
    final contours = await _api.getTextPreview(_sketchId!, textId);
    texts[textId] = SketchTextView(
      id: text.id,
      content: text.content,
      font: text.font,
      size: text.size,
      anchorPointId: text.anchorPointId,
      rotationDegrees: text.rotationDegrees,
      construction: text.construction,
      previewContoursRelative: [
        for (final contour in contours)
          SketchTextContourOffsets(
            outer: [for (final p in contour.outer) (p.$1 - anchor.x, p.$2 - anchor.y)],
            holes: [
              for (final hole in contour.holes)
                [for (final p in hole) (p.$1 - anchor.x, p.$2 - anchor.y)],
            ],
          ),
      ],
    );
    notifyListeners();
  }

  /// Re-fetches every Constraint from the backend - called after anything
  /// that can create/update one server-side, so [constraints] stays current
  /// within the same session without a full [adoptSketch] re-entry.
  Future<void> _refreshConstraints() async {
    if (_sketchId == null) return;
    final fetched = await _api.listConstraints(_sketchId!);
    constraints.clear();
    for (final constraint in fetched) {
      constraints[constraint.id] = constraint;
    }
  }

  void _adoptSketchDto(SketchDto sketch) {
    _sketchId = sketch.id;
    _originPointId = sketch.originPointId;
    _plane = sketch.plane;
    _flip = sketch.flip;
    _rotationQuarterTurns = sketch.rotationQuarterTurns;
    points[sketch.originPointId] = SketchPointView(id: sketch.originPointId, x: 0, y: 0);
  }

  /// Touch input: relative movement, scaled by [touchSensitivity] and the
  /// current [zoom] level so that dragging across the same fraction of the
  /// visible canvas covers roughly the same fraction of visible sketch-space
  /// regardless of zoom - zoomed out (zoom < 1) means more sketch-space is
  /// visible per pixel, so the same drag should move the cursor further,
  /// and vice versa zoomed in. The cursor's absolute position persists
  /// across separate touches - this only ever adds a delta. Trackpad-style:
  /// a tap always commits at wherever this cursor currently sits (see
  /// [SketchController.handleCanvasTap]), not at the tap's own location.
  ///
  /// Never itself clamped/snapped/reset - a cursor that drifts off-canvas
  /// (see [isCursorVisible]) simply keeps going, and simply disappears from
  /// the crosshair painting, exactly like every other cursor-movement path
  /// in this class, which stays purely in sketch-space and is otherwise
  /// unaffected by pan/zoom.
  ///
  /// Bug-fix round 2: this used to check [isCursorVisible] itself and, if
  /// already off-canvas, reset to centre right here - but that ran on
  /// *every* relative-move event, not just the start of a new gesture. A
  /// fast drag toward an edge can overshoot past canvas bounds for a single
  /// frame before RTS edge-pan's own ticker (which runs independently of
  /// pointer events, see sketch_canvas.dart's `_onEdgePanTick`) has a
  /// chance to compensate - that was enough to trip the reset on the very
  /// next move event of the *same* continuing drag, which is what caused
  /// the reported "keeps jumping to the middle" during active RTS panning.
  /// The reset-to-centre-if-hidden behaviour now lives in
  /// [resetCursorToCentreIfHidden] instead, called only once, at the start
  /// of a brand new touch gesture (see sketch_canvas.dart's
  /// `_handlePointerDown`) - never mid-drag.
  void moveCursorRelative(double dxPixels, double dyPixels, double zoom) {
    final scale = touchSensitivity / zoom;
    cursorX += dxPixels * scale;
    cursorY -= dyPixels * scale; // screen y is down; sketch y is up.
    _trackArcSweep();
    notifyListeners();
  }

  /// Mouse input: absolute, 1:1 with device position - drives the crosshair
  /// preview ahead of a click. Always on-canvas already (pointer events only
  /// fire within the canvas's own hit-test area), so - unlike
  /// [moveCursorRelative] - there is never a stale/off-canvas position to
  /// reconcile here.
  void moveCursorAbsoluteScreen(Offset screenPosition, ViewTransform transform) {
    final coord = transform.screenToSketch(screenPosition.dx, screenPosition.dy);
    cursorX = coord.x;
    cursorY = coord.y;
    _trackArcSweep();
    notifyListeners();
  }

  /// P17: the 3D-embedded sketcher's own cursor-movement entry point -
  /// unlike [moveCursorAbsoluteScreen]/[moveCursorRelative], the caller
  /// (`PartViewport`'s draw-cursor raycast, converted via
  /// [worldPointToSketch] in `sketch_screen.dart`) has already resolved a
  /// real sketch-space point, so there's no screen-to-sketch conversion left
  /// to do here - just the same [_trackArcSweep]/[notifyListeners] tail
  /// every other cursor-movement entry point already shares.
  void moveCursorToSketchPoint(double sketchX, double sketchY) {
    cursorX = sketchX;
    cursorY = sketchY;
    _trackArcSweep();
    notifyListeners();
  }

  /// Whether the cursor's current on-screen position - under [transform] -
  /// falls within [canvasSize], per [clampCursorToCanvas]. The cursor's own
  /// sketch-space position is never itself touched by panning or zooming
  /// (see this class's/[SketchCanvas]'s doc comments), so a pan/zoom that
  /// moves the view out from under a stationary cursor is exactly what
  /// makes this false - the sketch canvas's crosshair painting hides the
  /// cursor entirely in that case, and [moveCursorRelative] uses this to
  /// reset to centre on the next drag rather than resuming from off-canvas.
  bool isCursorVisible(Size canvasSize, ViewTransform transform) {
    final screen = transform.sketchToScreen(cursorX, cursorY);
    return clampCursorToCanvas(screen, canvasSize) == screen;
  }

  /// Bug-fix round 2: resets the cursor to canvas centre if - and only if -
  /// it's currently off-canvas (see [isCursorVisible]), implementing "the
  /// cursor reappears at centre the next time you interact with it".
  /// Deliberately called only once per gesture, from the very start of a
  /// brand new single-finger touch (see sketch_canvas.dart's
  /// `_handlePointerDown`) - never from [moveCursorRelative] itself (which
  /// runs on every move event of an already-in-progress drag) - see that
  /// method's doc comment for the bug this ordering fixes.
  void resetCursorToCentreIfHidden(Size canvasSize, ViewTransform transform) {
    if (isCursorVisible(canvasSize, transform)) return;
    final centre = transform.screenToSketch(canvasSize.width / 2, canvasSize.height / 2);
    cursorX = centre.x;
    cursorY = centre.y;
    notifyListeners();
  }

  /// [SketchMode.draw]'s tap handling - dispatches by [activeTool] and then
  /// by that tool's construction method ([lineConstructionMethod]/
  /// [circleConstructionMethod]). [cursorX]/[cursorY] have already been set
  /// to the tapped location by [handleCanvasTap] before this runs, so every
  /// snap/point-coincidence check in the methods below (which all read
  /// those fields) applies unchanged regardless of which method is active.
  Future<void> _handleDrawTap() async {
    if (_busy || _sketchId == null) return;

    if (_activeTool == SketchTool.point) {
      await _clickPointTool();
      return;
    }

    if (_activeTool == SketchTool.circle) {
      switch (_circleMethod) {
        case CircleConstructionMethod.centerRadius:
          await _clickCircleTool();
        case CircleConstructionMethod.threePoint:
          await _clickThreePointCircleTool();
      }
      return;
    }

    if (_activeTool == SketchTool.rectangle) {
      switch (_rectangleMethod) {
        case RectangleConstructionMethod.twoCorner:
          await _clickTwoCornerRectangleTool();
        case RectangleConstructionMethod.centreCorner:
          await _clickCentreCornerRectangleTool();
        case RectangleConstructionMethod.threePoint:
          await _clickThreePointRectangleTool();
      }
      return;
    }

    if (_activeTool == SketchTool.arc) {
      await _clickArcTool();
      return;
    }

    if (_activeTool == SketchTool.polygon) {
      await _clickPolygonTool();
      return;
    }

    if (_activeTool == SketchTool.slot) {
      await _clickSlotTool();
      return;
    }

    if (_activeTool == SketchTool.ellipse) {
      await _clickEllipseTool();
      return;
    }

    if (_activeTool == SketchTool.spline) {
      await _clickSplineTool();
      return;
    }

    if (_activeTool == SketchTool.text) {
      await _clickTextTool();
      return;
    }

    switch (_lineMethod) {
      case LineConstructionMethod.endToEnd:
        await _clickEndToEndLineTool();
      case LineConstructionMethod.midpoint:
        await _clickMidpointLineTool();
    }
  }

  /// Creates a CoincidentConstraint linking [pointId] to the nearest
  /// existing Point within [snapRadius] of ([x], [y]), if any - shared by
  /// every path that places a *computed/derived* Point (a rectangle's
  /// tracked centre, a 3-point circle's circumcenter-derived centre) rather
  /// than a Point the user tapped directly, so it still snaps onto nearby
  /// geometry (e.g. landing exactly on the sketch origin) the same way
  /// [_clickPointTool]'s directly-tapped placement already does. Bug-fix:
  /// these derived-point paths previously called [_api.createPoint]
  /// directly with no proximity check at all - confirmed on-device by
  /// placing a Rectangle's centre exactly on the origin and observing no
  /// constraint was created.
  Future<void> _autoCoincideIfNear(String pointId, double x, double y) async {
    final existingId = _existingPointIdNear(x, y, excludeId: pointId);
    if (existingId == null) return;
    final constraint = await _api.createCoincidentConstraint(_sketchId!, pointId, existingId);
    _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
    _autoCoincidentIndicatorPointId = pointId;
  }

  /// [SketchTool.point]: a single, self-terminating tap that places one
  /// Point. Still snaps onto a nearby Line's midpoint via
  /// [_materializeMidpoint] (same as every other placement path, through
  /// [_nearestLineMidpointId]) - but unlike [_pointIdAt]'s generic
  /// existing-Point reuse (appropriate for a Line/Circle/Rectangle's
  /// endpoint, which genuinely *is* the same geometry as whatever it
  /// shares), a standalone Point landing within [snapRadius] of an
  /// already-existing Point is deliberately kept distinct and linked by an
  /// auto-created [CoincidentConstraint] instead of being merged into the
  /// same Point id (Prompt B item B4) - this Point tool's whole purpose is
  /// placing an independently-addressable (and later independently
  /// draggable, re-constrainable) Point, so silently collapsing it into
  /// whatever it happens to land on would defeat that. If multiple
  /// existing Points are within range, the nearest one wins (see
  /// [_existingPointIdNear]).
  Future<void> _clickPointTool() async {
    _selectionSet.clear();
    _ribbonVisible = false;
    await _runGuarded(() async {
      final midpointLineId = _nearestLineMidpointId(cursorX, cursorY, snapRadius);
      String pointId;
      if (midpointLineId != null) {
        pointId = await _materializeMidpoint(midpointLineId);
      } else {
        final point = await _api.createPoint(_sketchId!, cursorX, cursorY);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
        _pushUndo(() async {
          await _api.deletePoint(_sketchId!, point.id);
          points.remove(point.id);
        });
        pointId = point.id;

        final existingId = _existingPointIdNear(cursorX, cursorY, excludeId: pointId);
        if (existingId != null) {
          final constraint = await _api.createCoincidentConstraint(_sketchId!, pointId, existingId);
          _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
          _autoCoincidentIndicatorPointId = pointId;
        }
      }
      // A midpoint-snapped or auto-coincident placement adds a new
      // Constraint, which a plain new Point never did before - solve and
      // refresh unconditionally, same as every other entity-placement
      // tool, so it's reflected immediately.
      await _solveAndTrackDof();
    });
  }

  /// [LineConstructionMethod.endToEnd]: the original chained placement - one
  /// tap starts the chain at a Point, every following tap creates a Line
  /// from the previous tap's Point to a new one (or closes the loop back
  /// onto the chain's start, see [isHoveringChainStart]), continuing until
  /// [finishChain] or a mode/tool switch ends it.
  Future<void> _clickEndToEndLineTool() async {
    if (!chainInProgress) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        final pointId = await _pointIdAtCursor();
        _chainStartPointId = pointId;
        _chainFirstPointId = pointId;
      });
      return;
    }

    final closingLoop = isHoveringChainStart;
    // Phase 6.1: captured from the start Point and the tap's cursor
    // position *before* the loop-closing case swaps in a fixed endpoint -
    // a closing edge's slope is dictated by the loop, not freely aimed, so
    // it never auto-snaps.
    final chainStart = points[_chainStartPointId!];
    final snapAxis =
        (!closingLoop && chainStart != null) ? _lineSnapAxis(chainStart.x, chainStart.y, cursorX, cursorY) : null;
    await _runGuarded(() async {
      final endPointId =
          closingLoop ? _chainFirstPointId! : await _pointIdAtCursor(excludeId: _chainStartPointId);

      final line = await _api.createLine(_sketchId!, _chainStartPointId!, endPointId);
      lines[line.id] = SketchLineView(
        id: line.id,
        startPointId: line.startPointId,
        endPointId: line.endPointId,
        construction: line.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, line.id);
        lines.remove(line.id);
      });
      await _applyLineSnapConstraint(line.id, snapAxis);

      // One user action (this tap, now that the line is fully placed) = one
      // solve call - never on intermediate cursor movement.
      await _solveAndTrackDof();

      if (closingLoop) {
        _chainStartPointId = null;
        _chainFirstPointId = null;
      } else {
        _chainStartPointId = endPointId;
      }
    });
  }

  /// [LineConstructionMethod.midpoint]: the first tap picks the line's
  /// center (a construction aid only - never itself a real Point); the
  /// second tap places one end as a real Point, and the other end is a
  /// freshly created Point at that end's mirror image through the center.
  /// Self-terminating, like a Circle tap pair - there is no chaining under
  /// this method.
  Future<void> _clickMidpointLineTool() async {
    if (_midpointAnchorX == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      _midpointAnchorX = cursorX;
      _midpointAnchorY = cursorY;
      notifyListeners();
      return;
    }

    final midX = _midpointAnchorX!;
    final midY = _midpointAnchorY!;
    final snapAxis = _lineSnapAxis(midX, midY, cursorX, cursorY);
    await _runGuarded(() async {
      final endAId = await _pointIdAtCursor();
      final endA = points[endAId]!;
      final mirrored = await _api.createPoint(_sketchId!, 2 * midX - endA.x, 2 * midY - endA.y);
      points[mirrored.id] = SketchPointView(id: mirrored.id, x: mirrored.x, y: mirrored.y);
      _pushUndo(() async {
        await _api.deletePoint(_sketchId!, mirrored.id);
        points.remove(mirrored.id);
      });

      final line = await _api.createLine(_sketchId!, endAId, mirrored.id);
      lines[line.id] = SketchLineView(
        id: line.id,
        startPointId: line.startPointId,
        endPointId: line.endPointId,
        construction: line.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, line.id);
        lines.remove(line.id);
      });
      await _applyLineSnapConstraint(line.id, snapAxis);

      await _solveAndTrackDof();
      _midpointAnchorX = null;
      _midpointAnchorY = null;
    });
  }

  /// Phase 6.1: adds the Horizontal/Vertical constraint [axis] implies to
  /// the just-created [lineId] (a no-op if [axis] is null, i.e. the
  /// in-progress segment wasn't within [lineSnapAngleDegrees] of either
  /// axis) - reuses the same backend calls
  /// [addHorizontalConstraint]/[addVerticalConstraint] make from the
  /// flyout, just triggered by placement instead of an explicit selection.
  Future<void> _applyLineSnapConstraint(String lineId, LineSnapAxis? axis) async {
    if (axis == null) return;
    final constraint = axis == LineSnapAxis.horizontal
        ? await _api.createHorizontalConstraint(_sketchId!, lineId)
        : await _api.createVerticalConstraint(_sketchId!, lineId);
    _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
  }

  /// Circle tool's tap handling: first tap places the center Point, second
  /// tap only ever measures a *distance* from it (never an angle - see
  /// [SketchApiClient.createCircleWithVerticalRadius]'s own doc comment),
  /// creates the Circle (which auto-creates its radius DistanceConstraint
  /// server-side, on what becomes the circle's own north cardinal point),
  /// and solves - self-terminating, unlike a Line chain, so there is no
  /// separate "finish" step.
  Future<void> _clickCircleTool() async {
    if (!circleInProgress) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        _circleCenterPointId = await _pointIdAtCursor();
      });
      return;
    }

    await _runGuarded(() async {
      final center = points[_circleCenterPointId!]!;
      final radius = math.sqrt(math.pow(cursorX - center.x, 2) + math.pow(cursorY - center.y, 2));
      if (radius < 1e-9) {
        errorMessage = 'Cannot place a circle with zero radius';
        _circleCenterPointId = null;
        return;
      }

      final circle = await _api.createCircleWithVerticalRadius(_sketchId!, _circleCenterPointId!, radius);
      circles[circle.id] = SketchCircleView(
        id: circle.id,
        centerPointId: circle.centerPointId,
        radiusPointId: circle.radiusPointId,
        construction: circle.construction,
        cardinalPointIds: circle.cardinalPointIds,
      );
      // The four cardinal Points are always freshly created server-side -
      // see Circle.cardinal_point_ids' own docstring (same fetch-and-cache
      // pattern _restoreDeletedEntities' own circle case uses).
      for (final id in circle.cardinalPointIds) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      _pushUndo(() async {
        await _api.deleteCircle(_sketchId!, circle.id);
        circles.remove(circle.id);
      });

      // Same rule as a completed Line: one finished entity = one solve call.
      await _solveAndTrackDof();

      _circleCenterPointId = null;
    });
  }

  /// Arc tool's tap handling: first tap places the center Point, second
  /// tap places the start Point (together fixing the radius, same as
  /// Circle's center+radius Point pair), third tap places the end Point -
  /// always exactly on the same circle as start, in the cursor's
  /// direction from center (see [_pointOnCircleTowardCursor]), never the
  /// raw cursor position - and creates the Arc (which auto-creates its
  /// pair of radius DistanceConstraints server-side, see the backend's
  /// `Sketch.add_arc`). Self-terminating, like Circle, so there is no
  /// separate "finish" step.
  Future<void> _clickArcTool() async {
    if (_arcCenterPointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        _arcCenterPointId = await _pointIdAtCursor();
      });
      return;
    }

    if (_arcStartPointId == null) {
      await _runGuarded(() async {
        _arcStartPointId = await _pointIdAtCursor(excludeId: _arcCenterPointId);
        final startId = _arcStartPointId;
        if (startId != null) {
          // Re-anchors sweep tracking at the start Point's own angle,
          // rather than wherever the cursor happened to be mid-placement -
          // see [_arcSweepAccumulator]'s own doc comment.
          final center = points[_arcCenterPointId!]!;
          final start = points[startId]!;
          _arcSweepLastAngle = math.atan2(start.y - center.y, start.x - center.x);
          _arcSweepAccumulator = 0;
        }
      });
      return;
    }

    final centerId = _arcCenterPointId!;
    final startId = _arcStartPointId!;
    await _runGuarded(() async {
      final center = points[centerId]!;
      final start = points[startId]!;
      final end = _pointOnCircleTowardCursor(center.x, center.y, start.x, start.y);
      if (end == null) {
        errorMessage = 'Cannot place an arc end point directly on its own center';
        _arcCenterPointId = null;
        _arcStartPointId = null;
        _resetArcSweepTracking();
        return;
      }

      final endPoint = await _api.createPoint(_sketchId!, end.$1, end.$2);
      points[endPoint.id] = SketchPointView(id: endPoint.id, x: endPoint.x, y: endPoint.y);
      _pushUndo(() async {
        await _api.deletePoint(_sketchId!, endPoint.id);
        points.remove(endPoint.id);
      });

      // On-device feedback: the backend's Arc always sweeps counter-
      // clockwise from its own startPointId to endPointId (see the
      // backend's app.sketch.models.Arc docstring) - a net-clockwise
      // cursor sweep since the start Point was placed
      // (_arcSweepAccumulator < 0) needs the two rim points swapped here so
      // that CCW interpretation still produces the small clockwise-looking
      // arc the user actually swept, instead of silently substituting its
      // complementary near-360-degree counter-clockwise sweep.
      final sweptClockwise = _arcSweepAccumulator < 0;
      final arcStartId = sweptClockwise ? endPoint.id : startId;
      final arcEndId = sweptClockwise ? startId : endPoint.id;

      final arc = await _api.createArc(_sketchId!, centerId, arcStartId, arcEndId);
      arcs[arc.id] = SketchArcView(
        id: arc.id,
        centerPointId: arc.centerPointId,
        startPointId: arc.startPointId,
        endPointId: arc.endPointId,
        construction: arc.construction,
      );
      _pushUndo(() async {
        await _api.deleteArc(_sketchId!, arc.id);
        arcs.remove(arc.id);
      });

      // Same rule as a completed Circle: one finished entity = one solve call.
      await _solveAndTrackDof();

      _arcCenterPointId = null;
      _arcStartPointId = null;
      _resetArcSweepTracking();
    });
  }

  /// Polygon tool's tap handling: first tap places the center Point,
  /// second tap places the first vertex (fixing circumradius and
  /// rotation) and immediately completes the shape - self-terminating,
  /// like Circle. Only the center and first-vertex Points are placed/
  /// snapped client-side (reusing [_pointIdAt]'s existing-point/midpoint
  /// snapping, same as every other multi-point placement path) - every
  /// other vertex, the [polygonSides] edge Lines, and the whole radius/
  /// equal-radius/equal-length/angle solver constraint chain that locks
  /// the shape rigid under drag (see the backend's `Sketch.add_polygon`
  /// docstring for the constraint reasoning) are created atomically by a
  /// single [SketchApiClient.createPolygon] call - a real, persisted
  /// Polygon entity, not the old multi-call client orchestration this
  /// replaces (see [SketchPolygonView]'s own doc comment for why that
  /// mattered).
  Future<void> _clickPolygonTool() async {
    if (_polygonCenterPointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        _polygonCenterPointId = await _pointIdAtCursor();
      });
      return;
    }

    final centerId = _polygonCenterPointId!;
    await _runGuarded(() async {
      final center = points[centerId]!;
      final dx = cursorX - center.x;
      final dy = cursorY - center.y;
      if (math.sqrt(dx * dx + dy * dy) < 1e-9) {
        errorMessage = 'Cannot place a polygon vertex directly on its own center';
        _polygonCenterPointId = null;
        return;
      }

      final firstVertexId = await _pointIdAt(cursorX, cursorY, excludeId: centerId);

      final polygon = await _api.createPolygon(_sketchId!, centerId, firstVertexId, _polygonSides);
      polygons[polygon.id] = SketchPolygonView(
        id: polygon.id,
        centerPointId: polygon.centerPointId,
        vertexPointIds: polygon.vertexPointIds,
        lineIds: polygon.lineIds,
        sides: polygon.sides,
        construction: polygon.construction,
      );
      for (var i = 0; i < polygon.lineIds.length; i++) {
        lines[polygon.lineIds[i]] = SketchLineView(
          id: polygon.lineIds[i],
          startPointId: polygon.vertexPointIds[i],
          endPointId: polygon.vertexPointIds[(i + 1) % polygon.vertexPointIds.length],
        );
      }
      // Vertex 0 is the (already-known) firstVertexId placed/snapped above -
      // vertices 1..sides-1 are freshly created server-side by add_polygon
      // and aren't locally known yet, same as Ellipse's own minor/negative-
      // tip Points. Fetched eagerly so `lines[...]` below (which references
      // these ids immediately, synchronously) has them; the later
      // [_refreshAllPoints] call would also pick them up itself now.
      for (final id in polygon.vertexPointIds.skip(1)) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      _pushUndo(() async {
        await _api.deletePolygon(_sketchId!, polygon.id);
        polygons.remove(polygon.id);
        for (final lineId in polygon.lineIds) {
          lines.remove(lineId);
        }
      });

      // Same rule as a completed Circle/Arc: one finished entity = one solve
      // call.
      await _solveAndTrackDof();

      _polygonCenterPointId = null;
    });
  }

  /// Slot tool's tap handling: first tap places the centerline's start
  /// Point, second tap places its end Point (fixing length and
  /// orientation), third tap sets the width via its perpendicular
  /// distance from the centerline and immediately completes the shape -
  /// self-terminating, like Arc. Builds two Arcs (auto-creating their own
  /// radius DistanceConstraint pairs server-side, see the backend's
  /// `Sketch.add_arc`) and two Lines connecting them into one closed loop
  /// (see [_slotCorners]'s doc comment for the a/b/c/d pairing).
  ///
  /// Bug-fix-shaped limitation, accepted for v1: the two Arcs' radii are
  /// independently constrained (each internally circular, same as any
  /// standalone Arc), not tied to each other - there's no existing
  /// constraint primitive for "these two point-pair distances stay equal"
  /// short of adding real spoke Line entities purely to hang an
  /// EqualLengthConstraint off of them, which felt like real complexity
  /// for a v1 tool. Dragging one end of a placed Slot can therefore make
  /// its two caps different radii; the shape is still exactly correct as
  /// placed. Same class of pragmatic simplification as Polygon's own
  /// equal-length-only (not equal-angle) regularity.
  Future<void> _clickSlotTool() async {
    if (_slotCenter1PointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        _slotCenter1PointId = await _pointIdAtCursor();
      });
      return;
    }

    if (_slotCenter2PointId == null) {
      await _runGuarded(() async {
        _slotCenter2PointId = await _pointIdAtCursor(excludeId: _slotCenter1PointId);
      });
      return;
    }

    final c1Id = _slotCenter1PointId!;
    final c2Id = _slotCenter2PointId!;
    await _runGuarded(() async {
      final c1 = points[c1Id]!;
      final c2 = points[c2Id]!;
      final radius = _perpendicularDistanceToLine(cursorX, cursorY, c1.x, c1.y, c2.x, c2.y);
      final corners = radius == null ? null : _slotCorners(c1.x, c1.y, c2.x, c2.y, radius);
      if (corners == null) {
        errorMessage = 'Cannot place a slot with a zero-length centerline or zero width';
        _slotCenter1PointId = null;
        _slotCenter2PointId = null;
        return;
      }

      final aId = await _pointIdAt(corners.a.$1, corners.a.$2, excludeId: c1Id);
      final bId = await _pointIdAt(corners.b.$1, corners.b.$2, excludeId: c1Id);
      final cId = await _pointIdAt(corners.c.$1, corners.c.$2, excludeId: c2Id);
      final dId = await _pointIdAt(corners.d.$1, corners.d.$2, excludeId: c2Id);

      // Feedback round: a visible construction line between the two centres,
      // like every other CAD package's Slot tool - purely a visual/reference
      // aid, carries no constraint of its own.
      final centerline = await _api.createLine(_sketchId!, c1Id, c2Id, construction: true);
      lines[centerline.id] = SketchLineView(
        id: centerline.id,
        startPointId: centerline.startPointId,
        endPointId: centerline.endPointId,
        construction: centerline.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, centerline.id);
        lines.remove(centerline.id);
      });

      final arc1 = await _api.createArc(_sketchId!, c1Id, aId, bId);
      arcs[arc1.id] = SketchArcView(
        id: arc1.id,
        centerPointId: arc1.centerPointId,
        startPointId: arc1.startPointId,
        endPointId: arc1.endPointId,
        construction: arc1.construction,
      );
      _pushUndo(() async {
        await _api.deleteArc(_sketchId!, arc1.id);
        arcs.remove(arc1.id);
      });

      final line1 = await _api.createLine(_sketchId!, bId, cId);
      lines[line1.id] = SketchLineView(
        id: line1.id,
        startPointId: line1.startPointId,
        endPointId: line1.endPointId,
        construction: line1.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, line1.id);
        lines.remove(line1.id);
      });

      final arc2 = await _api.createArc(_sketchId!, c2Id, cId, dId);
      arcs[arc2.id] = SketchArcView(
        id: arc2.id,
        centerPointId: arc2.centerPointId,
        startPointId: arc2.startPointId,
        endPointId: arc2.endPointId,
        construction: arc2.construction,
      );
      _pushUndo(() async {
        await _api.deleteArc(_sketchId!, arc2.id);
        arcs.remove(arc2.id);
      });

      final line2 = await _api.createLine(_sketchId!, dId, aId);
      lines[line2.id] = SketchLineView(
        id: line2.id,
        startPointId: line2.startPointId,
        endPointId: line2.endPointId,
        construction: line2.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, line2.id);
        lines.remove(line2.id);
      });

      // Feedback round: a Slot should carry a single editable radius
      // dimension, not one per end-cap arc. arc2's own two auto-created
      // radius DistanceConstraints (see Sketch.add_arc) are replaced with
      // EqualRadiusConstraints tying arc2's radius back to arc1's - arc1's
      // own two constraints stay untouched and remain the one visible/
      // editable dimension (mirrors a plain Arc's existing two-constraint
      // circularity, just shared across both end caps).
      await _refreshConstraints();
      final arc2Radius = _findDistanceConstraint(c2Id, cId);
      final arc2EndRadius = _findDistanceConstraint(c2Id, dId);
      if (arc2Radius != null) {
        await _api.deleteConstraint(_sketchId!, arc2Radius.id);
        _pushUndo(() async {
          await _api.createDistanceConstraint(
            _sketchId!,
            c2Id,
            cId,
            arc2Radius.distance,
            provisional: arc2Radius.provisional,
          );
        });
      }
      if (arc2EndRadius != null) {
        await _api.deleteConstraint(_sketchId!, arc2EndRadius.id);
        _pushUndo(() async {
          await _api.createDistanceConstraint(
            _sketchId!,
            c2Id,
            dId,
            arc2EndRadius.distance,
            provisional: arc2EndRadius.provisional,
          );
        });
      }

      for (final radiusPointId in [cId, dId]) {
        final equalRadius = await _api.createEqualRadiusConstraint(
          _sketchId!,
          arc1.id,
          arc2.id,
          radius2PointId: radiusPointId,
        );
        _pushUndo(() async => _api.deleteConstraint(_sketchId!, equalRadius.id));
      }

      // Feedback round: real Tangent constraints (not a hand-placed guess)
      // pin both arcs flush against both connecting lines - see backend
      // TangentConstraint's doc comment for why this needs no native
      // arc-of-circle solver entity. All 4 (one per arc/line pair) are
      // required for a geometrically valid closed slot; the last 2 are
      // mathematically implied by the first 2 plus the EqualRadius ties
      // above, which is why solve_sketch treats that redundancy as still
      // converged (see solver.py's own comment on result_code 4/5).
      for (final (arc, line) in [(arc1, line1), (arc1, line2), (arc2, line1), (arc2, line2)]) {
        final tangent = await _api.createTangentConstraint(_sketchId!, arc.id, line.id);
        _pushUndo(() async => _api.deleteConstraint(_sketchId!, tangent.id));
      }

      // Same rule as a completed Circle/Arc/Polygon: one finished entity = one solve call.
      await _solveAndTrackDof();

      _slotCenter1PointId = null;
      _slotCenter2PointId = null;
    });
  }

  /// Ellipse tool's tap handling: first tap places the center Point,
  /// second tap places the major-axis Point (together fixing the major
  /// radius and rotation, same as Arc's center+start Point pair), third
  /// tap sets the minor radius as the cursor's perpendicular distance
  /// from the major axis (see [_perpendicularDistanceToLine], the same
  /// measure [_ellipseDrawGhost] previews) and creates the Ellipse.
  /// Self-terminating, like Circle/Arc/Slot, so there is no separate
  /// "finish" step.
  Future<void> _clickEllipseTool() async {
    if (_ellipseCenterPointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        _ellipseCenterPointId = await _pointIdAtCursor();
      });
      return;
    }

    if (_ellipseMajorPointId == null) {
      await _runGuarded(() async {
        _ellipseMajorPointId = await _pointIdAtCursor(excludeId: _ellipseCenterPointId);
      });
      return;
    }

    final centerId = _ellipseCenterPointId!;
    final majorId = _ellipseMajorPointId!;
    await _runGuarded(() async {
      final center = points[centerId]!;
      final major = points[majorId]!;
      final majorRadius = math.sqrt(math.pow(major.x - center.x, 2) + math.pow(major.y - center.y, 2));
      final rawMinorRadius = _perpendicularDistanceToLine(cursorX, cursorY, center.x, center.y, major.x, major.y);
      final minorRadius = rawMinorRadius == null ? null : math.min(rawMinorRadius, majorRadius);
      if (minorRadius == null || minorRadius < 1e-9) {
        errorMessage = 'Cannot place an ellipse with a zero-length major axis or zero minor radius';
        _ellipseCenterPointId = null;
        _ellipseMajorPointId = null;
        return;
      }

      final ellipse = await _api.createEllipse(_sketchId!, centerId, majorId, minorRadius);
      ellipses[ellipse.id] = SketchEllipseView(
        id: ellipse.id,
        centerPointId: ellipse.centerPointId,
        majorPointId: ellipse.majorPointId,
        majorPointNegId: ellipse.majorPointNegId,
        minorPointId: ellipse.minorPointId,
        minorPointNegId: ellipse.minorPointNegId,
        majorAxisLineId: ellipse.majorAxisLineId,
        minorAxisLineId: ellipse.minorAxisLineId,
        minorRadius: ellipse.minorRadius,
        construction: ellipse.construction,
      );
      // Feedback round: the backend now also creates a real minor-axis
      // Point and two negative-tip Points (placed exactly perpendicular to
      // the major axis / diametrically opposite each positive tip)
      // alongside the Ellipse - not locally known yet, unlike
      // centerId/majorId which the earlier taps already placed, so they
      // need an explicit fetch (_refreshAllPoints only refreshes
      // already-known Points).
      for (final id in [ellipse.minorPointId, ellipse.majorPointNegId, ellipse.minorPointNegId]) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      // Two real, full-diameter construction Lines (major/minor axis,
      // spanning negative tip to positive tip) - mirrors the Slot tool's
      // own centerline registration.
      lines[ellipse.majorAxisLineId] = SketchLineView(
        id: ellipse.majorAxisLineId,
        startPointId: ellipse.majorPointNegId,
        endPointId: ellipse.majorPointId,
        construction: true,
      );
      lines[ellipse.minorAxisLineId] = SketchLineView(
        id: ellipse.minorAxisLineId,
        startPointId: ellipse.minorPointNegId,
        endPointId: ellipse.minorPointId,
        construction: true,
      );
      _pushUndo(() async {
        await _api.deleteEllipse(_sketchId!, ellipse.id);
        ellipses.remove(ellipse.id);
        lines.remove(ellipse.majorAxisLineId);
        lines.remove(ellipse.minorAxisLineId);
      });

      // Same rule as a completed Circle/Arc/Polygon/Slot: one finished entity = one solve call.
      await _solveAndTrackDof();

      _ellipseCenterPointId = null;
      _ellipseMajorPointId = null;
    });
  }

  /// Spline tool's tap handling: every tap places one more through-point
  /// Point and appends it to [splineThroughPointIds] - unlike every other
  /// draw tool, nothing is actually created server-side until
  /// [finishSpline] commits the whole accumulated list as one Spline
  /// entity (see [splineThroughPointIds]'s own doc comment for why).
  /// Guards against tapping the immediately-previous through-point again
  /// (same `excludeId` guard every other multi-tap tool uses) but not
  /// against revisiting an *earlier* one - same as a Line chain, which
  /// allows exactly that (e.g. to close a loop). The backend itself
  /// rejects a spline with any duplicate through-point anywhere in the
  /// list, surfaced via [errorMessage] from [finishSpline] in that rare
  /// case, rather than the client trying to pre-validate the whole
  /// accumulated list against every past tap.
  Future<void> _clickSplineTool() async {
    final isFirstTap = _splineThroughPointIds.isEmpty;
    if (isFirstTap) {
      _selectionSet.clear();
      _ribbonVisible = false;
    }
    await _runGuarded(() async {
      final excludeId = _splineThroughPointIds.isEmpty ? null : _splineThroughPointIds.last;
      final pointId = await _pointIdAtCursor(excludeId: excludeId);
      _splineThroughPointIds.add(pointId);
      notifyListeners();
    });
  }

  /// Commits [splineThroughPointIds] as one real Spline entity (a no-op,
  /// silently clearing state, if fewer than 2 through-points were tapped -
  /// nothing to create). Mirrors [finishChain] in spirit (ends the
  /// in-progress tap sequence, stays in [SketchMode.draw] with the Spline
  /// tool still active for the next one) but does real work first, unlike
  /// [finishChain]'s pure state-clear - a Spline's Points are collected
  /// without creating the entity itself until this is called (see
  /// [splineThroughPointIds]'s own doc comment), so this is where the
  /// actual API call happens.
  Future<void> finishSpline() async {
    if (_splineThroughPointIds.length < 2) {
      _splineThroughPointIds.clear();
      notifyListeners();
      return;
    }
    final throughPointIds = List<String>.from(_splineThroughPointIds);
    await _runGuarded(() async {
      final spline = await _api.createSpline(_sketchId!, throughPointIds);
      // Unlike every other entity here, a Spline's control-handle Points
      // are never tapped by the user - the server creates them from
      // scratch inside Sketch.add_spline (see [splineThroughPointIds]'s
      // own doc comment) - so, unlike Circle/Arc/Ellipse's own defining
      // Points, they aren't already in [points] by the time the entity
      // itself is created. [_refreshAllPoints] alone wouldn't pick them
      // up either: it only re-fetches ids already in [points], not brand
      // new ones - so they're fetched and cached here explicitly.
      for (final id in spline.controlPointIds) {
        final point = await _api.getPoint(_sketchId!, id);
        points[id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      splines[spline.id] = SketchSplineView(
        id: spline.id,
        throughPointIds: spline.throughPointIds,
        controlPointIds: spline.controlPointIds,
        construction: spline.construction,
      );
      _pushUndo(() async {
        await _api.deleteSpline(_sketchId!, spline.id);
        splines.remove(spline.id);
      });

      // Same rule as any other completed entity: one finished entity = one solve call.
      await _solveAndTrackDof();

      _splineThroughPointIds.clear();
    });
  }

  /// The initial content a freshly-placed Text entity is created with -
  /// unlike every other entity here, Text has no tap sequence that could
  /// meaningfully preview its final shape (glyph outlines aren't
  /// something a user "aims" the way a Circle's radius or a Line's
  /// endpoint is), so [SketchTool.text] is a single, self-terminating tap
  /// (see [_clickTextTool]) that commits immediately with this
  /// placeholder, exactly like [SketchTool.point]'s own single-tap
  /// commit - refined afterward via the ribbon's "Edit Text" action
  /// ([setTextProperties]).
  static const String _defaultTextContent = 'Text';

  /// [SketchTool.text]: a single, self-terminating tap that places the
  /// anchor Point (via [_pointIdAtCursor], so it snaps onto/shares an
  /// existing Point exactly like Circle/Arc/Ellipse/Spline's own anchor
  /// Points do - unlike [SketchTool.point]'s deliberately-distinct
  /// Coincident-linked placement) and creates the Text entity immediately
  /// with [_defaultTextContent] at the backend's own default font/size.
  Future<void> _clickTextTool() async {
    _selectionSet.clear();
    _ribbonVisible = false;
    await _runGuarded(() async {
      final anchorPointId = await _pointIdAtCursor();
      final text = await _api.createText(_sketchId!, _defaultTextContent, anchorPointId);
      texts[text.id] = SketchTextView(
        id: text.id,
        content: text.content,
        font: text.font,
        size: text.size,
        anchorPointId: text.anchorPointId,
        rotationDegrees: text.rotationDegrees,
        construction: text.construction,
      );
      _pushUndo(() async {
        await _api.deleteText(_sketchId!, text.id);
        texts.remove(text.id);
      });

      // Same rule as any other completed entity: one finished entity = one solve call.
      await _solveAndTrackDof();
      await _refreshTextPreview(text.id);
    });
  }

  /// The ribbon's "Edit Text" action: PATCHes whichever of
  /// [content]/[font]/[size]/[rotationDegrees] are non-null, then
  /// re-fetches the preview outline (see [_refreshTextPreview]) since any
  /// of those can change the actual glyph geometry. Reversible, the same
  /// PATCH-to-the-old-values undo shape used throughout this file.
  Future<void> setTextProperties(
    String textId, {
    String? content,
    String? font,
    double? size,
    double? rotationDegrees,
  }) async {
    if (_busy || _sketchId == null) return;
    final text = texts[textId];
    if (text == null) return;
    final oldContent = text.content;
    final oldFont = text.font;
    final oldSize = text.size;
    final oldRotation = text.rotationDegrees;

    await _runGuarded(() async {
      final updated = await _api.updateText(
        _sketchId!,
        textId,
        content: content,
        font: font,
        size: size,
        rotationDegrees: rotationDegrees,
      );
      texts[textId] = SketchTextView(
        id: updated.id,
        content: updated.content,
        font: updated.font,
        size: updated.size,
        anchorPointId: updated.anchorPointId,
        rotationDegrees: updated.rotationDegrees,
        construction: updated.construction,
      );
      _pushUndo(() async {
        final reverted = await _api.updateText(
          _sketchId!,
          textId,
          content: oldContent,
          font: oldFont,
          size: oldSize,
          rotationDegrees: oldRotation,
        );
        texts[textId] = SketchTextView(
          id: reverted.id,
          content: reverted.content,
          font: reverted.font,
          size: reverted.size,
          anchorPointId: reverted.anchorPointId,
          rotationDegrees: reverted.rotationDegrees,
          construction: reverted.construction,
        );
        await _refreshTextPreview(textId);
      });
      await _refreshTextPreview(textId);
    });
  }

  /// [CircleConstructionMethod.threePoint]: the first two taps are
  /// construction aids only (never real Points); the third tap becomes a
  /// real Point on the circumference, paired with a freshly created center
  /// Point solved from all three tapped locations (see [_circumcenter]).
  /// Three collinear taps have no circumcenter - that attempt is silently
  /// abandoned (the picks are cleared, surfaced via [errorMessage]) rather
  /// than left to retry against a degenerate state.
  Future<void> _clickThreePointCircleTool() async {
    if (_threePointFirstX == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      _threePointFirstX = cursorX;
      _threePointFirstY = cursorY;
      notifyListeners();
      return;
    }
    if (_threePointSecondX == null) {
      _threePointSecondX = cursorX;
      _threePointSecondY = cursorY;
      notifyListeners();
      return;
    }

    final ax = _threePointFirstX!, ay = _threePointFirstY!;
    final bx = _threePointSecondX!, by = _threePointSecondY!;
    final cx = cursorX, cy = cursorY;
    _threePointFirstX = null;
    _threePointFirstY = null;
    _threePointSecondX = null;
    _threePointSecondY = null;

    final center = _circumcenter(ax, ay, bx, by, cx, cy);
    if (center == null) {
      errorMessage = 'Pick three non-collinear points to define a circle';
      notifyListeners();
      return;
    }

    await _runGuarded(() async {
      final centerPoint = await _api.createPoint(_sketchId!, center.$1, center.$2);
      points[centerPoint.id] = SketchPointView(id: centerPoint.id, x: centerPoint.x, y: centerPoint.y);
      _pushUndo(() async {
        await _api.deletePoint(_sketchId!, centerPoint.id);
        points.remove(centerPoint.id);
      });
      await _autoCoincideIfNear(centerPoint.id, center.$1, center.$2);
      final radiusPoint = await _api.createPoint(_sketchId!, cx, cy);
      points[radiusPoint.id] = SketchPointView(id: radiusPoint.id, x: radiusPoint.x, y: radiusPoint.y);
      _pushUndo(() async {
        await _api.deletePoint(_sketchId!, radiusPoint.id);
        points.remove(radiusPoint.id);
      });

      final circle = await _api.createCircle(_sketchId!, centerPoint.id, radiusPoint.id);
      circles[circle.id] = SketchCircleView(
        id: circle.id,
        centerPointId: circle.centerPointId,
        radiusPointId: circle.radiusPointId,
        construction: circle.construction,
        cardinalPointIds: circle.cardinalPointIds,
      );
      // The four cardinal Points are always freshly created server-side -
      // see Circle.cardinal_point_ids' own docstring.
      for (final id in circle.cardinalPointIds) {
        final point = await _api.getPoint(_sketchId!, id);
        points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
      }
      _pushUndo(() async {
        await _api.deleteCircle(_sketchId!, circle.id);
        circles.remove(circle.id);
      });

      await _solveAndTrackDof();
    });
  }

  /// The center of the circle through three points, or null if they're
  /// (near-)collinear and have no unique circumcenter.
  (double, double)? _circumcenter(double ax, double ay, double bx, double by, double cx, double cy) {
    final d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (d.abs() < 1e-9) return null;
    final ux = ((ax * ax + ay * ay) * (by - cy) +
            (bx * bx + by * by) * (cy - ay) +
            (cx * cx + cy * cy) * (ay - by)) /
        d;
    final uy = ((ax * ax + ay * ay) * (cx - bx) +
            (bx * bx + by * by) * (ax - cx) +
            (cx * cx + cy * cy) * (bx - ax)) /
        d;
    return (ux, uy);
  }

  /// Resolves the Point id a tap at the current cursor should use: the
  /// real origin Point's id if the cursor is hovering it (and that id isn't
  /// [excludeId] - e.g. an entity's own center/chain-start id, which it can
  /// never coincide with), otherwise a freshly created Point at the cursor.
  /// The single place every tap-to-place path goes through to place/reuse a
  /// Point, so origin-snapping applies uniformly to chain starts, chain
  /// continuations, and both Circle taps.
  Future<String> _pointIdAtCursor({String? excludeId}) =>
      _pointIdAt(cursorX, cursorY, excludeId: excludeId);

  /// [_pointIdAtCursor]'s logic, generalized to an arbitrary sketch-space
  /// location - the Rectangle tool's computed (non-tapped) corners go
  /// through this directly, since they aren't necessarily at the cursor's
  /// current position.
  Future<String> _pointIdAt(double x, double y, {String? excludeId}) async {
    final existing = _existingPointIdNear(x, y, excludeId: excludeId);
    if (existing != null) return existing;
    final midpointLineId = _nearestLineMidpointId(x, y, snapRadius);
    if (midpointLineId != null) {
      return await _materializeMidpoint(midpointLineId);
    }
    final point = await _api.createPoint(_sketchId!, x, y);
    points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
    _pushUndo(() async {
      await _api.deletePoint(_sketchId!, point.id);
      points.remove(point.id);
    });
    return point.id;
  }

  /// Stage 15 item 6: creates the 4 shared corner Points (snapping/reusing
  /// per [_pointIdAt], same as every other entity placement) and the 4
  /// connecting Lines for a Rectangle, going around in order (so each
  /// consecutive pair of corners shares an edge), then solves once.
  /// [corner0Id]/[corner1Id] let a caller pass in a Point already placed by
  /// an earlier tap (so it isn't re-created/re-snapped) - null means
  /// "create/snap fresh at this coordinate".
  ///
  /// [axisAligned] (Prompt B item B1) selects how the 4 sides are
  /// constrained: true (the default, used by the two-corner and
  /// centre-corner methods, whose corners are always axis-aligned by
  /// construction - corner0/corner1 share a Y, corner1/corner2 share an X,
  /// and so on around the loop) applies Horizontal to line1/line3 and
  /// Vertical to line2/line4 directly, which pins orientation more directly
  /// than 3 Perpendicular constraints (the old approach) and degrades
  /// better as the rectangle is resized. false (the 3-point method, whose
  /// rectangle can sit at an arbitrary angle) keeps the original 3
  /// Perpendicular constraints between consecutive edges - a quadrilateral's
  /// interior angles sum to 360 degrees, so constraining 3 of its 4 corners
  /// to 90 degrees forces the last corner to 90 degrees too, no fourth/
  /// redundant constraint needed.
  ///
  /// [axisAligned] also gates Prompt B item B2's construction geometry: two
  /// corner-to-corner construction diagonals (never part of any profile -
  /// see profile.py's construction filter) plus a real, non-construction
  /// center Point pinned to *one* diagonal's midpoint via
  /// [SketchApiClient.createAtMidpointConstraint] - so the center tracks
  /// correctly as the rectangle scales, and stays referenceable for future
  /// constraints. Bug-fix round 2: a second AtMidpoint pinning the same
  /// center Point to the *other* diagonal too was removed - both diagonals
  /// share the same true midpoint once the H/V constraints above hold, so
  /// the second constraint was redundant, and verified (against the real
  /// py-slvs wheel) to make the whole solve fail to converge outright
  /// rather than just being harmlessly ignored. Skipped for the 3-point
  /// method: an arbitrary-angle rectangle has no axis-aligned "center"
  /// concept this item is scoped to.
  Future<void> _buildRectangle({
    String? corner0Id,
    String? corner1Id,
    required (double, double) corner0,
    required (double, double) corner1,
    required (double, double) corner2,
    required (double, double) corner3,
    bool axisAligned = true,
  }) async {
    final p0 = corner0Id ?? await _pointIdAt(corner0.$1, corner0.$2);
    final p1 = corner1Id ?? await _pointIdAt(corner1.$1, corner1.$2);
    final p2 = await _pointIdAt(corner2.$1, corner2.$2);
    final p3 = await _pointIdAt(corner3.$1, corner3.$2);

    final line1 = await _api.createLine(_sketchId!, p0, p1);
    lines[line1.id] = SketchLineView(
      id: line1.id,
      startPointId: line1.startPointId,
      endPointId: line1.endPointId,
      construction: line1.construction,
    );
    _pushUndo(() async {
      await _api.deleteLine(_sketchId!, line1.id);
      lines.remove(line1.id);
    });
    final line2 = await _api.createLine(_sketchId!, p1, p2);
    lines[line2.id] = SketchLineView(
      id: line2.id,
      startPointId: line2.startPointId,
      endPointId: line2.endPointId,
      construction: line2.construction,
    );
    _pushUndo(() async {
      await _api.deleteLine(_sketchId!, line2.id);
      lines.remove(line2.id);
    });
    final line3 = await _api.createLine(_sketchId!, p2, p3);
    lines[line3.id] = SketchLineView(
      id: line3.id,
      startPointId: line3.startPointId,
      endPointId: line3.endPointId,
      construction: line3.construction,
    );
    _pushUndo(() async {
      await _api.deleteLine(_sketchId!, line3.id);
      lines.remove(line3.id);
    });
    final line4 = await _api.createLine(_sketchId!, p3, p0);
    lines[line4.id] = SketchLineView(
      id: line4.id,
      startPointId: line4.startPointId,
      endPointId: line4.endPointId,
      construction: line4.construction,
    );
    _pushUndo(() async {
      await _api.deleteLine(_sketchId!, line4.id);
      lines.remove(line4.id);
    });

    if (axisAligned) {
      final horiz1 = await _api.createHorizontalConstraint(_sketchId!, line1.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, horiz1.id));
      final vert1 = await _api.createVerticalConstraint(_sketchId!, line2.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, vert1.id));
      final horiz2 = await _api.createHorizontalConstraint(_sketchId!, line3.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, horiz2.id));
      final vert2 = await _api.createVerticalConstraint(_sketchId!, line4.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, vert2.id));

      final diagonal1 = await _api.createLine(_sketchId!, p0, p2, construction: true);
      lines[diagonal1.id] = SketchLineView(
        id: diagonal1.id,
        startPointId: diagonal1.startPointId,
        endPointId: diagonal1.endPointId,
        construction: diagonal1.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, diagonal1.id);
        lines.remove(diagonal1.id);
      });
      final diagonal2 = await _api.createLine(_sketchId!, p1, p3, construction: true);
      lines[diagonal2.id] = SketchLineView(
        id: diagonal2.id,
        startPointId: diagonal2.startPointId,
        endPointId: diagonal2.endPointId,
        construction: diagonal2.construction,
      );
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, diagonal2.id);
        lines.remove(diagonal2.id);
      });

      final centerX = (corner0.$1 + corner1.$1 + corner2.$1 + corner3.$1) / 4;
      final centerY = (corner0.$2 + corner1.$2 + corner2.$2 + corner3.$2) / 4;
      final centerPoint = await _api.createPoint(_sketchId!, centerX, centerY);
      points[centerPoint.id] = SketchPointView(id: centerPoint.id, x: centerPoint.x, y: centerPoint.y);
      _pushUndo(() async {
        await _api.deletePoint(_sketchId!, centerPoint.id);
        points.remove(centerPoint.id);
      });
      await _autoCoincideIfNear(centerPoint.id, centerX, centerY);

      // Bug-fix round 2: only one AtMidpoint constraint, not two. Both
      // diagonals share the same true midpoint once the H/V constraints
      // above hold (that's what makes it a rectangle), so a second
      // AtMidpoint pinning the same center Point to diagonal2 is
      // mathematically redundant, not just harmlessly so - verified
      // against the real py-slvs wheel that it makes the whole solve fail
      // to converge outright (a singular system), and py-slvs reports
      // `dof == 0` in that failure state, which made an under-constrained
      // rectangle (nothing pins its width/height/position) show as
      // "fully constrained". One AtMidpoint constraint alone already keeps
      // the center Point tracking the rectangle's true center correctly as
      // it's resized/moved - diagonal2 stays purely a construction visual.
      final mid1 = await _api.createAtMidpointConstraint(_sketchId!, centerPoint.id, diagonal1.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, mid1.id));
    } else {
      final perp1 = await _api.createPerpendicularConstraint(_sketchId!, line1.id, line2.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, perp1.id));
      final perp2 = await _api.createPerpendicularConstraint(_sketchId!, line2.id, line3.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, perp2.id));
      final perp3 = await _api.createPerpendicularConstraint(_sketchId!, line3.id, line4.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, perp3.id));
    }

    await _solveAndTrackDof();
  }

  /// [RectangleConstructionMethod.twoCorner]: the first tap places one real
  /// corner Point; the second tap is the opposite corner's location (not
  /// itself snapped/placed until [_buildRectangle] runs) - the other two
  /// corners are derived to keep the rectangle axis-aligned.
  Future<void> _clickTwoCornerRectangleTool() async {
    if (_rectFirstPointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        final pointId = await _pointIdAtCursor();
        _rectFirstPointId = pointId;
        _rectFirstX = points[pointId]!.x;
        _rectFirstY = points[pointId]!.y;
      });
      return;
    }

    final x0 = _rectFirstX!;
    final y0 = _rectFirstY!;
    final firstPointId = _rectFirstPointId!;
    final x2 = cursorX;
    final y2 = cursorY;
    _rectFirstX = null;
    _rectFirstY = null;
    _rectFirstPointId = null;

    await _runGuarded(() async {
      await _buildRectangle(
        corner0Id: firstPointId,
        corner0: (x0, y0),
        corner1: (x2, y0),
        corner2: (x2, y2),
        corner3: (x0, y2),
      );
    });
  }

  /// [RectangleConstructionMethod.centreCorner]: the first tap is a
  /// construction aid only (the rectangle's center, never itself a real
  /// Point - same role as [_midpointAnchorX]); the second tap places one
  /// real corner, mirrored through the center for the opposite corner, with
  /// the remaining two corners derived to stay axis-aligned.
  Future<void> _clickCentreCornerRectangleTool() async {
    if (_rectFirstX == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      _rectFirstX = cursorX;
      _rectFirstY = cursorY;
      notifyListeners();
      return;
    }

    final cx = _rectFirstX!;
    final cy = _rectFirstY!;
    _rectFirstX = null;
    _rectFirstY = null;

    await _runGuarded(() async {
      final cornerId = await _pointIdAtCursor();
      final corner = points[cornerId]!;
      final dx = corner.x - cx;
      final dy = corner.y - cy;
      await _buildRectangle(
        corner0Id: cornerId,
        corner0: (corner.x, corner.y),
        corner1: (cx - dx, corner.y),
        corner2: (cx - dx, cy - dy),
        corner3: (corner.x, cy - dy),
      );
    });
  }

  /// [RectangleConstructionMethod.threePoint]: the first two taps place the
  /// rectangle's first side as two real Points (like a Line's endpoints);
  /// the third tap is off that side and sets the rectangle's height via its
  /// perpendicular distance from the first side - the only construction
  /// method that doesn't force an axis-aligned result. Mirrors
  /// [_clickThreePointCircleTool]'s "abandon on a degenerate pick" handling:
  /// two coincident first-side taps, or a third tap that lands back on the
  /// first side, can't define a rectangle and are surfaced via
  /// [errorMessage] rather than retried.
  Future<void> _clickThreePointRectangleTool() async {
    if (_rectFirstPointId == null) {
      _selectionSet.clear();
      _ribbonVisible = false;
      await _runGuarded(() async {
        final pointId = await _pointIdAtCursor();
        _rectFirstPointId = pointId;
        _rectFirstX = points[pointId]!.x;
        _rectFirstY = points[pointId]!.y;
      });
      return;
    }

    if (_rectSecondPointId == null) {
      await _runGuarded(() async {
        final pointId = await _pointIdAtCursor(excludeId: _rectFirstPointId);
        _rectSecondPointId = pointId;
        _rectSecondX = points[pointId]!.x;
        _rectSecondY = points[pointId]!.y;
      });
      return;
    }

    final ax = _rectFirstX!, ay = _rectFirstY!;
    final bx = _rectSecondX!, by = _rectSecondY!;
    final pointAId = _rectFirstPointId!;
    final pointBId = _rectSecondPointId!;
    final px = cursorX, py = cursorY;
    _rectFirstX = null;
    _rectFirstY = null;
    _rectFirstPointId = null;
    _rectSecondX = null;
    _rectSecondY = null;
    _rectSecondPointId = null;

    final abx = bx - ax;
    final aby = by - ay;
    final lenAB = math.sqrt(abx * abx + aby * aby);
    if (lenAB < 1e-9) {
      errorMessage = "Pick two distinct points to define the rectangle's first side";
      notifyListeners();
      return;
    }
    final nx = -aby / lenAB;
    final ny = abx / lenAB;
    final height = (px - ax) * nx + (py - ay) * ny;
    if (height.abs() < 1e-9) {
      errorMessage = 'Pick a third point off the first side to give the rectangle some height';
      notifyListeners();
      return;
    }

    await _runGuarded(() async {
      await _buildRectangle(
        corner0Id: pointAId,
        corner1Id: pointBId,
        corner0: (ax, ay),
        corner1: (bx, by),
        corner2: (bx + height * nx, by + height * ny),
        corner3: (ax + height * nx, ay + height * ny),
        axisAligned: false,
      );
    });
  }

  /// Ends the current chain without closing a loop - the next tap starts an
  /// unrelated new chain. Stays in [SketchMode.draw] - only the chain ends,
  /// not the tool/mode.
  void finishChain() {
    _chainStartPointId = null;
    _chainFirstPointId = null;
    notifyListeners();
  }

  List<ProfileLoopDto> _closedProfileFills = const [];

  /// Every outer profile loop the sketch's closed-profile detection found,
  /// each already carrying its own holes - one entry for a single closed
  /// loop (C1, may have inner holes), 2+ for a MultiProfile of disjoint
  /// outer loops (C2, each with its own holes), or empty if there's no
  /// usable profile at all (no loop, an open chain, a branch, overlapping/
  /// invalid nesting). Refreshed alongside points/constraints on every
  /// [_solveAndTrackDof] call - its response already bundles the profile
  /// (Phase 0 round-trip reduction; this used to be a separate
  /// `GET /sketch/sketches/{id}/profile` call).
  ///
  /// Bug fix: previously this only ever held a single loop's Point ids and
  /// was null whenever `status != closed_loop`, so a sketch with a
  /// MultiProfile (or a hole) never got its area(s) filled in the 2D
  /// canvas at all - see [SketchCanvas._paintClosedProfileFill].
  List<ProfileLoopDto> get closedProfileFills => _closedProfileFills;

  List<String> _profileBranchPointIds = const [];

  /// Bug fix (on-device feedback: a shape that looked closed on screen
  /// wasn't picked up as a profile, with no clue why): every Point the
  /// backend's closed-loop detection found connected to 3+ non-construction
  /// Lines/Arcs/Splines - a real T-junction, not a rendering glitch, most
  /// often created by an auto-Coincident drag-snap (see
  /// [ProfileDetectionDto.branchPointIds]'s own doc comment) landing on an
  /// existing joint instead of a chain's one true open end. Empty whenever
  /// the last profile check wasn't `branch`. [SketchCanvas] renders a
  /// distinct marker at each id so the offending point is visible without
  /// leaving the sketcher.
  List<String> get profileBranchPointIds => _profileBranchPointIds;

  /// Segment counts for [profileLoopOutline]'s own tessellation - kept local
  /// to this file (rather than reusing a `viewport3d`-side constant) per
  /// this package's own data-flow direction: `sketch` must never depend on
  /// `viewport3d`.
  static const int _profileLoopCircleSegments = 48;
  static const int _profileLoopArcSegments = 24;
  static const int _profileLoopSplineSegments = 16;

  /// P31 (2D-sketcher feature parity): [loop]'s own boundary, tessellated
  /// into a flat sketch-local (x, y) polygon - the pure, sketch-space
  /// counterpart of `sketch_canvas.dart`'s own `_addLoopBoundary` (same
  /// per-hop straight-vs-curved distinction, same Arc/Ellipse trace-
  /// direction resolution against [loop.pointIds]/[loop.lineIds]'s own
  /// convention - see that method's own doc comment), just producing plain
  /// points instead of a screen-space `Path`. V1 scope: [loop]'s own
  /// boundary only - a caller wanting holes calls this again per entry in
  /// [ProfileLoopDto.innerLoops] separately; this method never looks at
  /// that field itself. Returns null if any referenced Point/entity is
  /// missing (same "degrade gracefully, not throw" contract
  /// `_addLoopBoundary` already has) or the loop is degenerate (fewer than
  /// 2 Points).
  List<(double, double)>? profileLoopOutline(ProfileLoopDto loop) {
    final anchors = <SketchPointView>[];
    for (final id in loop.pointIds) {
      final point = points[id];
      if (point == null) return null;
      anchors.add(point);
    }
    if (anchors.length < 2) return null;

    // Ellipse-loop special case: a whole-Ellipse profile is packed as
    // exactly 2 Points (centre, major-axis) referencing the Ellipse's own
    // single id - mirrors _addLoopBoundary's identical special case.
    final soleEntityId = loop.lineIds.length == 1 ? loop.lineIds[0] : null;
    final ellipse = soleEntityId == null ? null : ellipses[soleEntityId];
    if (ellipse != null && anchors.length == 2) {
      final center = anchors[0];
      final major = anchors[1];
      final majorRadius = _sketchPointDistanceXY(center, major);
      final minorPoint = points[ellipse.minorPointId];
      if (minorPoint == null) return null;
      final minorRadius = _sketchPointDistanceXY(center, minorPoint);
      final rotation = math.atan2(major.y - center.y, major.x - center.x);
      final cosR = math.cos(rotation);
      final sinR = math.sin(rotation);
      return [
        // Exclusive of `_profileLoopCircleSegments` itself so the ring
        // isn't explicitly closed - same "implicit closure, no duplicate
        // final point" convention every other case below uses.
        for (var i = 0; i < _profileLoopCircleSegments; i++)
          () {
            final t = 2 * math.pi * i / _profileLoopCircleSegments;
            final localX = majorRadius * math.cos(t);
            final localY = minorRadius * math.sin(t);
            return (center.x + localX * cosR - localY * sinR, center.y + localX * sinR + localY * cosR);
          }(),
      ];
    }

    final hasArc = loop.lineIds.any((id) => arcs.containsKey(id));
    final hasSpline = loop.lineIds.any((id) => splines.containsKey(id));
    if (!hasArc && !hasSpline) {
      // A whole-Circle profile is packed as exactly 2 Points (centre,
      // radius) referencing the Circle's own single id, same convention as
      // the Ellipse case above.
      if (anchors.length == 2) {
        final center = anchors[0];
        final radius = _sketchPointDistanceXY(center, anchors[1]);
        return [
          for (var i = 0; i < _profileLoopCircleSegments; i++)
            () {
              final angle = 2 * math.pi * i / _profileLoopCircleSegments;
              return (center.x + radius * math.cos(angle), center.y + radius * math.sin(angle));
            }(),
        ];
      }
      // A plain Line-only polygon - the Points themselves are the outline.
      return [for (final p in anchors) (p.x, p.y)];
    }

    // A Line/Arc/Spline-mixed loop (e.g. a rounded-corner rectangle) - each
    // hop tessellated as its own straight or curved run, mirroring
    // _addLoopBoundary's identical per-hop distinction exactly (including
    // its Arc/Spline trace-direction resolution against loop.pointIds).
    final outline = <(double, double)>[(anchors[0].x, anchors[0].y)];
    final n = anchors.length;
    for (var i = 0; i < n; i++) {
      final entityId = i < loop.lineIds.length ? loop.lineIds[i] : null;
      final spline = entityId == null ? null : splines[entityId];
      if (spline != null) {
        var segments = spline.segments();
        if (loop.pointIds[i] == spline.throughPointIds.last) {
          segments = [for (final s in segments.reversed) (s.$4, s.$3, s.$2, s.$1)];
        }
        for (final segment in segments) {
          final p0 = outline.last;
          final c1 = points[segment.$2];
          final c2 = points[segment.$3];
          final end = points[segment.$4];
          if (c1 == null || c2 == null || end == null) return null;
          for (var step = 1; step <= _profileLoopSplineSegments; step++) {
            final t = step / _profileLoopSplineSegments;
            final mt = 1 - t;
            final x = mt * mt * mt * p0.$1 +
                3 * mt * mt * t * c1.x +
                3 * mt * t * t * c2.x +
                t * t * t * end.x;
            final y = mt * mt * mt * p0.$2 +
                3 * mt * mt * t * c1.y +
                3 * mt * t * t * c2.y +
                t * t * t * end.y;
            outline.add((x, y));
          }
        }
        continue;
      }
      final arc = entityId == null ? null : arcs[entityId];
      final arcCenter = arc == null ? null : points[arc.centerPointId];
      final arcStart = arc == null ? null : points[arc.startPointId];
      final arcEnd = arc == null ? null : points[arc.endPointId];
      final next = anchors[(i + 1) % n];
      if (arc == null || arcCenter == null || arcStart == null || arcEnd == null) {
        outline.add((next.x, next.y));
        continue;
      }
      final radius = _sketchPointDistanceXY(arcCenter, arcStart);
      final startAngle = math.atan2(arcStart.y - arcCenter.y, arcStart.x - arcCenter.x);
      final endAngle = math.atan2(arcEnd.y - arcCenter.y, arcEnd.x - arcCenter.x);
      final sweep = normalizeSketchAngle(endAngle - startAngle);
      final forward = loop.pointIds[i] == arc.startPointId;
      final fromAngle = forward ? startAngle : endAngle;
      final actualSweep = forward ? sweep : -sweep;
      for (var step = 1; step <= _profileLoopArcSegments; step++) {
        final angle = fromAngle + actualSweep * step / _profileLoopArcSegments;
        outline.add((arcCenter.x + radius * math.cos(angle), arcCenter.y + radius * math.sin(angle)));
      }
    }
    // The walk above always lands back on anchors[0] (loop.pointIds wraps),
    // duplicating outline's own first point - drop it so every case shares
    // the same "implicit closure, no duplicate final point" convention.
    outline.removeLast();
    return outline;
  }

  double _sketchPointDistanceXY(SketchPointView a, SketchPointView b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// P42 (on-device feedback: "a punch out in a profile doesn't show on the
  /// shaded area in the sketcher"): [profileLoopOutline]'s own outer
  /// boundary, with every one of [loop]'s own [ProfileLoopDto.innerLoops]
  /// (holes) merged into it via the standard "bridge" technique - a hole is
  /// spliced into the outer sequence as `..., O, hole[0], hole[1], ...,
  /// hole[0], O, ...` (walk out to the hole's own nearest vertex, all the
  /// way around it, back to that same vertex, back to the outer vertex),
  /// turning "simple polygon with a hole" into one ordinary simple polygon
  /// [earClipTriangleIndices] (`sketch_geometry_3d.dart`) already knows how
  /// to triangulate, with no changes needed there at all - the zero-width
  /// slit this leaves is exactly why that function's own hard iteration cap
  /// matters here (a real, if degenerate, edge case it already has to
  /// tolerate, not a new risk introduced by this).
  ///
  /// V1 scope, matching [profileLoopOutline]'s own doc comment: only
  /// [loop]'s own *direct* holes - a hole's own further-nested holes
  /// (`innerLoops` recursively) are not bridged in turn, an accepted,
  /// documented gap for the rare "hole inside a hole" case, not every real
  /// sketch this is meant to fix. Multiple sibling holes are each bridged
  /// independently to whichever outer/already-merged vertex is nearest -
  /// correct for the common case (holes that don't touch or overlap each
  /// other), not a fully general, crossing-proof solver.
  List<(double, double)>? profileLoopOutlineWithHoles(ProfileLoopDto loop) {
    var outline = profileLoopOutline(loop);
    if (outline == null) return null;
    final outlineIsCcw = _signedArea(outline) >= 0;
    for (final hole in loop.innerLoops) {
      var holeOutline = profileLoopOutline(hole);
      if (holeOutline == null || holeOutline.length < 3) continue;
      // A hole must wind opposite the outer boundary for the bridge/keyhole
      // technique below to leave a genuinely simple (non-self-crossing)
      // polygon behind - reverse it if [profileLoopOutline] happened to
      // hand back the same winding as the outer loop.
      final holeIsCcw = _signedArea(holeOutline) >= 0;
      if (holeIsCcw == outlineIsCcw) holeOutline = holeOutline.reversed.toList();
      outline = _bridgeHoleIntoOutline(outline!, holeOutline);
    }
    return outline;
  }

  double _signedArea(List<(double, double)> polygon) {
    var area = 0.0;
    for (var i = 0; i < polygon.length; i++) {
      final (x1, y1) = polygon[i];
      final (x2, y2) = polygon[(i + 1) % polygon.length];
      area += x1 * y2 - x2 * y1;
    }
    return area / 2;
  }

  List<(double, double)> _bridgeHoleIntoOutline(
    List<(double, double)> outline,
    List<(double, double)> hole,
  ) {
    var bestOuterIndex = 0;
    var bestHoleIndex = 0;
    var bestDistSq = double.infinity;
    for (var oi = 0; oi < outline.length; oi++) {
      for (var hi = 0; hi < hole.length; hi++) {
        final dx = outline[oi].$1 - hole[hi].$1;
        final dy = outline[oi].$2 - hole[hi].$2;
        final distSq = dx * dx + dy * dy;
        if (distSq < bestDistSq) {
          bestDistSq = distSq;
          bestOuterIndex = oi;
          bestHoleIndex = hi;
        }
      }
    }
    final holeLength = hole.length;
    final reorderedHole = [
      for (var i = 0; i <= holeLength; i++) hole[(bestHoleIndex + i) % holeLength],
    ];
    return [
      ...outline.sublist(0, bestOuterIndex + 1),
      ...reorderedHole,
      outline[bestOuterIndex],
      ...outline.sublist(bestOuterIndex + 1),
    ];
  }

  /// P32 (2D-sketcher feature parity): every visible constraint's own
  /// overlay layout, in sketch-local space - mirrors `sketch_canvas.dart`'s
  /// own `_paintDimensionOverlays` dispatch/filtering exactly (same
  /// [isCardinalAxisConstraint]/`provisional`/[isImplicitPolygonEdgeTie]
  /// skips), just producing [ConstraintOverlayItem] data instead of
  /// drawing. See that type's own doc comment for why this stays
  /// renderer-agnostic (no screen-space math here at all).
  List<ConstraintOverlayItem> constraintOverlayItems() {
    final items = <ConstraintOverlayItem>[];
    for (final entry in constraints.entries) {
      final isSelected = selectionSet.any((s) => s.kind == SelectionKind.constraint && s.id == entry.key);
      final labelOffset = labelOffsetFor(entry.key);
      switch (entry.value) {
        case DistanceConstraintDto c:
          if (isCardinalAxisConstraint(c)) break;
          if (c.provisional) break;
          if (isRadiusDistanceConstraint(c)) {
            final center = points[c.pointAId];
            final rim = points[c.pointBId];
            if (center == null || rim == null) break;
            final showsDiameter = showsDiameterFor(entry.key);
            items.add(ConstraintRadialDimensionItem(
              constraintId: entry.key,
              selected: isSelected,
              center: (center.x, center.y),
              rim: (rim.x, rim.y),
              radius: c.distance,
              isDiameter: showsDiameter,
              text: showsDiameter ? '⌀${(c.distance * 2).toStringAsFixed(2)}' : 'R${c.distance.toStringAsFixed(2)}',
              labelOffset: labelOffset,
            ));
            break;
          }
          final ellipseAxis = ellipseAxisForDistanceConstraint(c);
          final String pointAId;
          final String pointBId;
          final double displayValue;
          if (ellipseAxis != null) {
            (pointAId, pointBId) = ellipseAxis;
            displayValue = c.distance * 2;
          } else {
            pointAId = c.pointAId;
            pointBId = c.pointBId;
            displayValue = c.distance;
          }
          final a = points[pointAId];
          final b = points[pointBId];
          if (a == null || b == null) break;
          items.add(ConstraintLinearDimensionItem(
            constraintId: entry.key,
            selected: isSelected,
            pointA: (a.x, a.y),
            pointB: (b.x, b.y),
            orientation: c.orientation,
            text: displayValue.toStringAsFixed(2),
            labelOffset: labelOffset,
          ));
        case VerticalConstraintDto c:
          final labelItem = _pairMidpointLabel(c.pointAId, c.pointBId, 'V', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case HorizontalConstraintDto c:
          final labelItem = _pairMidpointLabel(c.pointAId, c.pointBId, 'H', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case AngleConstraintDto c:
          if (isImplicitPolygonEdgeTie(c.line1Id, c.line2Id)) break;
          final labelItem = _lineMidpointPairLabel(
            c.line1Id,
            c.line2Id,
            '${c.angleDegrees.toStringAsFixed(1)}°',
            entry.key,
            isSelected,
            labelOffset,
            plainBlackText: true,
          );
          if (labelItem != null) items.add(labelItem);
        case LineDistanceConstraintDto c:
          final line1 = lines[c.line1Id];
          final line2 = lines[c.line2Id];
          if (line1 == null || line2 == null) break;
          final line1Start = points[line1.startPointId];
          final line1End = points[line1.endPointId];
          final line2Start = points[line2.startPointId];
          final line2End = points[line2.endPointId];
          if (line1Start == null || line1End == null || line2Start == null || line2End == null) break;
          items.add(ConstraintLineDistanceDimensionItem(
            constraintId: entry.key,
            selected: isSelected,
            line1Start: (line1Start.x, line1Start.y),
            line1End: (line1End.x, line1End.y),
            line2Start: (line2Start.x, line2Start.y),
            line2End: (line2End.x, line2End.y),
            text: c.distance.toStringAsFixed(2),
            labelOffset: labelOffset,
          ));
        case CoincidentConstraintDto c:
          final labelItem = _pairMidpointLabel(c.pointAId, c.pointBId, 'Coinc.', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case ParallelConstraintDto c:
          final labelItem =
              _lineMidpointPairLabel(c.line1Id, c.line2Id, '∥', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case PerpendicularConstraintDto c:
          final labelItem =
              _lineMidpointPairLabel(c.line1Id, c.line2Id, '⟂', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case EqualLengthConstraintDto c:
          if (isImplicitPolygonEdgeTie(c.line1Id, c.line2Id)) break;
          final labelItem = _lineMidpointPairLabel(c.line1Id, c.line2Id, '=', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case CollinearConstraintDto c:
          final labelItem =
              _lineMidpointPairLabel(c.line1Id, c.line2Id, 'Collin.', entry.key, isSelected, labelOffset);
          if (labelItem != null) items.add(labelItem);
        case PointLineDistanceConstraintDto c:
          final point = points[c.pointId];
          final line = lines[c.lineId];
          if (point == null || line == null) break;
          final lineStart = points[line.startPointId];
          final lineEnd = points[line.endPointId];
          if (lineStart == null || lineEnd == null) break;
          final lineMid = ((lineStart.x + lineEnd.x) / 2, (lineStart.y + lineEnd.y) / 2);
          items.add(ConstraintLabelItem(
            constraintId: entry.key,
            selected: isSelected,
            anchorA: (point.x, point.y),
            anchorB: lineMid,
            text: c.distance.toStringAsFixed(2),
            labelOffset: labelOffset,
            plainBlackText: true,
          ));
        default:
          break;
      }
    }
    return items;
  }

  /// P39 (2D-sketcher feature parity): [ghosts]' own overlay layout, in the
  /// same sketch-local, renderer-agnostic [ConstraintOverlayItem] shapes
  /// [constraintOverlayItems] already produces for *confirmed* constraints -
  /// mirrors `sketch_canvas.dart`'s own `_paintGhosts` (every ghost dashed
  /// and labeled a literal `?`/`⌀?`, never the live geometric value - see
  /// [currentGhostValue]'s own doc comment for why), just reusing the fuller
  /// witness-line/arrowhead layout every other dimension already renders
  /// with here, rather than `_paintGhosts`'s own plainer dashed-segment-only
  /// look - a deliberate simplification: once a ghost is confirmed (see
  /// [confirmGhostValue]), it becomes an ordinary constraint rendered by
  /// this exact same machinery anyway, so the two now look consistent
  /// throughout a dimension's whole lifecycle instead of changing style the
  /// moment it's confirmed. [selected] carries "this is the active ghost"
  /// (see [activeGhostKey]) rather than "this is a selected constraint" -
  /// the same emphasis-color meaning, different trigger.
  List<ConstraintOverlayItem> dimensionGhostOverlayItems() {
    final items = <ConstraintOverlayItem>[];
    for (final ghost in _ghosts) {
      final isActive = ghost.key == _activeGhostKey;
      final labelOffset = labelOffsetFor(ghost.key);
      switch (ghost.kind) {
        case GhostKind.length:
        case GhostKind.linear:
        case GhostKind.vertical:
        case GhostKind.horizontal:
          final a = points[ghost.pointAId];
          final b = points[ghost.pointBId];
          if (a == null || b == null) continue;
          items.add(ConstraintLinearDimensionItem(
            constraintId: ghost.key,
            selected: isActive,
            pointA: (a.x, a.y),
            pointB: (b.x, b.y),
            orientation: switch (ghost.kind) {
              GhostKind.vertical => 'vertical',
              GhostKind.horizontal => 'horizontal',
              _ => 'linear',
            },
            text: '?',
            labelOffset: labelOffset,
          ));
        case GhostKind.radius:
        case GhostKind.diameter:
          final center = points[ghost.pointAId];
          final rim = points[ghost.pointBId];
          if (center == null || rim == null) continue;
          final isDiameter = ghost.kind == GhostKind.diameter;
          items.add(ConstraintRadialDimensionItem(
            constraintId: ghost.key,
            selected: isActive,
            center: (center.x, center.y),
            rim: (rim.x, rim.y),
            radius: _sketchPointDistanceXY(center, rim),
            isDiameter: isDiameter,
            text: isDiameter ? '⌀?' : '?',
            labelOffset: labelOffset,
          ));
        case GhostKind.lineDistance:
          final lineA = lines[ghost.lineAId];
          final lineB = lines[ghost.lineBId];
          if (lineA == null || lineB == null) continue;
          final line1Start = points[lineA.startPointId];
          final line1End = points[lineA.endPointId];
          final line2Start = points[lineB.startPointId];
          final line2End = points[lineB.endPointId];
          if (line1Start == null || line1End == null || line2Start == null || line2End == null) continue;
          items.add(ConstraintLineDistanceDimensionItem(
            constraintId: ghost.key,
            selected: isActive,
            line1Start: (line1Start.x, line1Start.y),
            line1End: (line1End.x, line1End.y),
            line2Start: (line2Start.x, line2Start.y),
            line2End: (line2End.x, line2End.y),
            text: '?',
            labelOffset: labelOffset,
          ));
        case GhostKind.angle:
          final mid1 = _lineMidpointXY(ghost.lineAId ?? '');
          final mid2 = _lineMidpointXY(ghost.lineBId ?? '');
          if (mid1 == null || mid2 == null) continue;
          items.add(ConstraintLabelItem(
            constraintId: ghost.key,
            selected: isActive,
            anchorA: mid1,
            anchorB: mid2,
            text: '?',
            labelOffset: labelOffset,
            plainBlackText: true,
          ));
      }
    }
    return items;
  }

  ConstraintLabelItem? _pairMidpointLabel(
    String pointAId,
    String pointBId,
    String text,
    String constraintId,
    bool selected,
    Offset labelOffset,
  ) {
    final a = points[pointAId];
    final b = points[pointBId];
    if (a == null || b == null) return null;
    return ConstraintLabelItem(
      constraintId: constraintId,
      selected: selected,
      anchorA: (a.x, a.y),
      anchorB: (b.x, b.y),
      text: text,
      labelOffset: labelOffset,
      plainBlackText: false,
    );
  }

  ConstraintLabelItem? _lineMidpointPairLabel(
    String line1Id,
    String line2Id,
    String text,
    String constraintId,
    bool selected,
    Offset labelOffset, {
    bool plainBlackText = false,
  }) {
    final mid1 = _lineMidpointXY(line1Id);
    final mid2 = _lineMidpointXY(line2Id);
    if (mid1 == null || mid2 == null) return null;
    return ConstraintLabelItem(
      constraintId: constraintId,
      selected: selected,
      anchorA: mid1,
      anchorB: mid2,
      text: text,
      labelOffset: labelOffset,
      plainBlackText: plainBlackText,
    );
  }

  (double, double)? _lineMidpointXY(String lineId) {
    final line = lines[lineId];
    if (line == null) return null;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return null;
    return ((start.x + end.x) / 2, (start.y + end.y) / 2);
  }

  // --- Stage 19b item 4: undo --------------------------------------------

  /// Client-side-only undo (Stage 19b item 4). The backend is the source of
  /// truth for every entity (see this class's own doc comment), so a literal
  /// "snapshot the local maps and restore them" undo would desync from it -
  /// instead each mutating method below pushes a closure that performs the
  /// real backend-and-local *inverse* of what it just did; [undo] pops and
  /// runs the most recent one through the same solve/refresh pipeline every
  /// other mutation already uses. Capped at 50 entries (oldest dropped once
  /// full) - fresh per [SketchController] instance, so never shared across
  /// sketches.
  final List<Future<void> Function()> _undoStack = [];
  static const int _maxUndoStackEntries = 50;

  bool get canUndo => _undoStack.isNotEmpty;

  void _pushUndo(Future<void> Function() inverse) {
    _undoStack.add(inverse);
    if (_undoStack.length > _maxUndoStackEntries) {
      _undoStack.removeAt(0);
    }
  }

  // TODO: redo

  /// Pops and runs the most recent undo entry pushed by [_pushUndo], then
  /// re-solves/refreshes exactly like any other mutation - a no-op if the
  /// stack is empty, already busy, or there's no active sketch.
  Future<void> undo() async {
    if (_undoStack.isEmpty || _busy || _sketchId == null) return;
    final inverse = _undoStack.removeLast();
    await _runGuarded(() async {
      await inverse();
      await _solveAndTrackDof();
    });
  }

  Future<void> _runGuarded(Future<void> Function() body) async {
    _busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await body();
    } on ApiException catch (e) {
      errorMessage = e.message;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }
}
