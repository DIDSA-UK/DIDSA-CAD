import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset;

import '../api/sketch_api_client.dart';
import 'view_transform.dart';

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

  const SketchCircleView({
    required this.id,
    required this.centerPointId,
    required this.radiusPointId,
    this.construction = false,
  });
}

/// Which entity the next tap-to-place commits, while [SketchMode.draw] is
/// active. Selected via the FAB's "Sketch Entities" category. [point] is a
/// standalone, self-terminating placement (no chaining, no construction
/// method choice) - a single tap creates one Point and the tool is done.
enum SketchTool { line, circle, point, rectangle }

/// How a tap-to-place Line is built while [SketchTool.line] is active -
/// chosen from [SketchConstructionMethodBar]. [endToEnd] is the original
/// chained start/end placement; [midpoint] instead takes the first tap as
/// the line's center and the second as one end, mirroring it to compute the
/// other end (see [SketchController._clickMidpointLineTool]).
enum LineConstructionMethod { endToEnd, midpoint }

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

/// Previews a Rectangle's 4 corners, in the same winding order
/// [SketchController._buildRectangle] would use to create its 4 Lines.
class RectGhost extends DrawGhost {
  final (double, double) corner0;
  final (double, double) corner1;
  final (double, double) corner2;
  final (double, double) corner3;

  const RectGhost({required this.corner0, required this.corner1, required this.corner2, required this.corner3});
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
enum SketchMode { select, draw, dimension }

/// The kind of entity a [SketchSelection] refers to. [constraint] covers
/// both Dimensions (Distance/Angle, which carry an editable numeric value)
/// and bare relational Constraints (Vertical/Horizontal, which don't) -
/// the ribbon distinguishes the two via [SketchController.selectedConstraintHasValue].
enum SelectionKind { point, line, circle, constraint }

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
/// of truth - see [_refreshAllPoints], called after every solve.
class SketchController extends ChangeNotifier {
  final SketchApiClient _api;

  SketchController({SketchApiClient? api}) : _api = api ?? SketchApiClient();

  /// Touch drag moves the cursor relatively, scaled by this factor - not
  /// 1:1 with finger position, per the project brief's interaction model.
  static const double touchSensitivity = 0.05;

  /// How close (in sketch units) the cursor must be to a chain's start
  /// Point before a tap is treated as "close the loop" rather than "place
  /// a new point".
  static const double snapRadius = 0.5;

  /// Stage 13 item 3's minimum tap hit target, in logical pixels (44x44),
  /// expressed as a radius. Entity hit-testing for a discrete tap (select,
  /// dimension-target picking) uses whichever is larger of this - converted
  /// to sketch units via the canvas's current zoom, see
  /// [hitRadiusForPixelsPerUnit] - or [snapRadius], so small/zoomed-out
  /// entities stay tappable on touch without shrinking precise mouse hover.
  static const double minTapHitRadiusPixels = 22.0;

  /// Converts [minTapHitRadiusPixels] into sketch-space units for the
  /// current zoom level - the canvas passes its [ViewTransform.pixelsPerUnit]
  /// in here before calling [handleCanvasTap].
  double hitRadiusForPixelsPerUnit(double pixelsPerUnit) {
    if (pixelsPerUnit <= 0) return snapRadius;
    return math.max(snapRadius, minTapHitRadiusPixels / pixelsPerUnit);
  }

  String? _sketchId;
  String? get sketchId => _sketchId;

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

  final Map<String, SketchPointView> points = {};
  final Map<String, SketchLineView> lines = {};
  final Map<String, SketchCircleView> circles = {};

  /// Every Constraint currently on this Sketch, keyed by id - the dimension
  /// overlays (Stage 12 item 10) read straight from this, and Stage 13's
  /// dimension-ghost confirm flow consults it (via [_findDistanceConstraint])
  /// to decide whether to PATCH an existing value or POST a new Constraint.
  final Map<String, ConstraintDto> constraints = {};

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
        }
      case SketchMode.dimension:
        return 'Dimension';
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
  bool get isUnderConstrained => _dof > 0;

  Future<void> _solveAndTrackDof() async {
    final result = await _api.solve(_sketchId!);
    _dof = result.dof;
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
  bool get isIdle => !chainInProgress && !circleInProgress;

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
    }
  }

  DrawGhost? _lineDrawGhost() {
    switch (_lineMethod) {
      case LineConstructionMethod.endToEnd:
        final startId = _chainStartPointId;
        if (startId == null) return null;
        final start = points[startId];
        if (start == null) return null;
        return LineGhost(startX: start.x, startY: start.y, endX: cursorX, endY: cursorY);
      case LineConstructionMethod.midpoint:
        final midX = _midpointAnchorX;
        final midY = _midpointAnchorY;
        if (midX == null || midY == null) return null;
        // Mirrors the real Line _clickMidpointLineTool would create: the
        // cursor becomes one end, its mirror image through the anchor the
        // other.
        return LineGhost(
          startX: 2 * midX - cursorX,
          startY: 2 * midY - cursorY,
          endX: cursorX,
          endY: cursorY,
        );
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
  /// core behind both [hoveredEntity] (continuous mouse hover, always
  /// [snapRadius]) and every discrete-tap hit-test (select/dimension mode,
  /// using the larger of [snapRadius] and the 44px touch target - see
  /// [hitRadiusForPixelsPerUnit]).
  SketchSelection? _entityAt(double x, double y, double radius, {bool includeOrigin = false}) {
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
      if (dx * dx + dy * dy <= radius * radius) {
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

    return null;
  }

  /// The entity nearest the cursor and within [snapRadius], or null while
  /// not idle, not in [SketchMode.select]/[SketchMode.dimension], or if
  /// nothing is close enough.
  SketchSelection? get hoveredEntity {
    if (_mode == SketchMode.draw || !isIdle) return null;
    return _entityAt(cursorX, cursorY, snapRadius, includeOrigin: true);
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
  /// location) a real backend Point at [lineId]'s current midpoint. Not
  /// kept coincident with the midpoint if the Line is later resized/moved -
  /// the backend has no "Point at midpoint of Line" constraint type, so
  /// this is a one-off snapshot. Used for midpoint-snap point placement only
  /// (Stage 16 item 9 moved the line-pair distance ghost off this path onto
  /// a real `LineDistanceConstraint` instead - see [confirmGhostValue]'s
  /// `lineDistance` branch - so a line-to-line dimension no longer creates
  /// any Points).
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
  Future<SketchSelection?> _resolveSelectableAt(double radius) async {
    final direct = _entityAt(cursorX, cursorY, radius, includeOrigin: true);
    if (direct != null && direct.kind == SelectionKind.point) return direct;
    final midpointLineId = _nearestLineMidpointId(cursorX, cursorY, radius);
    if (midpointLineId != null) {
      final pointId = await _materializeMidpoint(midpointLineId);
      return SketchSelection(kind: SelectionKind.point, id: pointId);
    }
    return direct;
  }

  /// New work package item 8's double-click-drag target resolver: a
  /// directly-hit Point as-is, or - for a Line/Circle, neither of which is
  /// itself a Point - whichever of its constituent Points sits nearer
  /// [x]/[y], since a Line/Circle's shape is entirely defined by the Points
  /// it references and has no position of its own to drag. Returns null if
  /// nothing within [radius] qualifies, the sketch isn't in
  /// [SketchMode.select], or [isUnderConstrained] is false (nothing could
  /// move into anyway, so there's nothing to offer).
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
        return distToStart <= distToEnd ? line.startPointId : line.endPointId;
      case SelectionKind.circle:
        final circle = circles[hit.id]!;
        final center = points[circle.centerPointId]!;
        final radiusPoint = points[circle.radiusPointId]!;
        final distToCenter = math.pow(x - center.x, 2) + math.pow(y - center.y, 2);
        final distToRadius = math.pow(x - radiusPoint.x, 2) + math.pow(y - radiusPoint.y, 2);
        return distToCenter <= distToRadius ? circle.centerPointId : circle.radiusPointId;
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

  /// The Point currently being live-dragged via [beginPointDrag], or null if
  /// no drag is in progress - the canvas reads this to suppress its normal
  /// hover/cursor-move handling while a drag owns pointer-move events.
  String? get draggingPointId => _draggingPointId;

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
    if (_draggingLabelId != null) return false;
    final point = points[pointId]!;
    _draggingPointId = pointId;
    _dragOriginCursorX = cursorX;
    _dragOriginCursorY = cursorY;
    _dragOriginPointX = point.x;
    _dragOriginPointY = point.y;
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
  /// concept. Solving is deferred to [endPointDrag]; mid-drag the raw
  /// dragged position is shown as-is; rapid out-of-order responses are
  /// accepted silently, same tradeoff as every other unsequenced PATCH in
  /// this file.
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
    try {
      final updated = await _api.updatePoint(_sketchId!, pointId, newX, newY);
      points[pointId] = SketchPointView(id: updated.id, x: updated.x, y: updated.y);
      notifyListeners();
    } on ApiException catch (e) {
      errorMessage = e.message;
      notifyListeners();
    }
  }

  /// Ends the current Point drag (if any) and re-solves from the dropped
  /// position, same backend-is-truth refresh as every other mutation - any
  /// remaining constraints (e.g. a Line this Point anchors staying the
  /// right length) settle here rather than during the drag itself.
  Future<void> endPointDrag() async {
    if (_draggingPointId == null) return;
    _draggingPointId = null;
    _dragOriginCursorX = null;
    _dragOriginCursorY = null;
    _dragOriginPointX = null;
    _dragOriginPointY = null;
    await _runGuarded(() async {
      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();
    });
  }

  /// Stage 15 item 2: per-Constraint screen-pixel offset from its default
  /// painted label position, applied by the painter on top of whichever
  /// anchor it would otherwise use - purely a client-side display tweak
  /// (no backend call), so it survives a sketch refresh but not a fresh
  /// [ensureSketch]/[adoptSketch] (same lifetime as the controller itself).
  final Map<String, Offset> _labelOffsets = {};

  /// [constraintId]'s current user-applied offset, or [Offset.zero] if it
  /// has never been dragged - read by the painter to place the label and
  /// by [dimensionLabelAt] (sketch_canvas.dart) to hit-test against where
  /// the label actually is, not just its un-offset default anchor.
  Offset labelOffsetFor(String constraintId) => _labelOffsets[constraintId] ?? Offset.zero;

  String? _draggingLabelId;

  /// The Constraint label currently being live-dragged via [beginLabelDrag],
  /// or null if no label drag is in progress - mirrors [draggingPointId];
  /// the two are mutually exclusive within a single double-click-drag
  /// gesture (see [beginPointDrag]/[beginLabelDrag]'s guards).
  String? get draggingLabelId => _draggingLabelId;

  /// Starts a live drag of [constraintId]'s label - false (no-op) if a
  /// Point drag is already active. Unlike [beginPointDrag] this never
  /// touches the backend, so there's no busy/sketch-id guard to fail on.
  bool beginLabelDrag(String constraintId) {
    if (_draggingPointId != null) return false;
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
  /// was dropped; see [resetLabelOffset] for the separate "double-tap
  /// without dragging" gesture that snaps a label back to its default.
  void endLabelDrag() {
    _draggingLabelId = null;
  }

  /// Clears [constraintId]'s offset back to its default painted anchor -
  /// Stage 15 item 2's double-tap-without-drag reset gesture.
  void resetLabelOffset(String constraintId) {
    if (_labelOffsets.remove(constraintId) != null) notifyListeners();
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

  /// A human-readable reason [selection] (if it's a Point) cannot be
  /// deleted, mirroring the backend's own Line/Circle/origin checks so the
  /// flyout can grey out Delete without a round-trip - or null if this
  /// client-side check sees no reason to block it. Only meaningful for a
  /// single-Point selection - the backend is still the final authority
  /// (e.g. for Constraints, which the client doesn't track locally) - see
  /// [deleteSelected]'s error handling for that fallback, so a null result
  /// here is not a guarantee the backend will accept it.
  String? get selectedPointDeleteBlockedReason {
    if (_selectionSet.length != 1) return null;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.point) return null;
    final pointId = current.id;
    if (pointId == _originPointId) {
      return "Can't delete the sketch's origin point";
    }
    for (final line in lines.values) {
      if (line.startPointId == pointId || line.endPointId == pointId) {
        return 'Still used by a line';
      }
    }
    for (final circle in circles.values) {
      if (circle.centerPointId == pointId || circle.radiusPointId == pointId) {
        return 'Still used by a circle';
      }
    }
    return null;
  }

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
    }
  }

  /// [SketchMode.select]'s tap handling - hovering/tapping an entity selects
  /// it and opens/keeps open the flyout. While the flyout is already open,
  /// tapping a further entity adds it to [selectionSet] instead of
  /// replacing it (Stage 13 item 6's multi-entity selection); tapping blank
  /// space while the flyout is open dismisses it back to a clean idle
  /// state, matching how a tap-outside is expected to close a contextual
  /// panel; tapping blank space while the flyout is closed instead opens it
  /// showing the idle actions (e.g. Exit Sketch), same as Stage 6.
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
      } else {
        _ribbonVisible = true;
      }
      notifyListeners();
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
  /// the same add-to-selection-vs-replace rule as [_handleSelectTap].
  void selectConstraint(String constraintId) {
    final hit = SketchSelection(kind: SelectionKind.constraint, id: constraintId);
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

  /// Deletes every entity in [selectionSet] via the matching backend DELETE
  /// endpoint, then refreshes from backend state - same backend-is-truth
  /// pattern as every other mutation. A rejected delete (e.g. a Constraint
  /// the client doesn't track locally) surfaces via [errorMessage], same as
  /// any other API failure; entities already deleted before the failure
  /// stay removed, and the selection is left in place so the flyout keeps
  /// showing it.
  Future<void> deleteSelected() async {
    if (_selectionSet.isEmpty || _busy || _sketchId == null) return;
    final toDelete = List<SketchSelection>.from(_selectionSet);
    final deletedConstraint = toDelete.any((s) => s.kind == SelectionKind.constraint);

    await _runGuarded(() async {
      for (final current in toDelete) {
        switch (current.kind) {
          case SelectionKind.line:
            await _api.deleteLine(_sketchId!, current.id);
            lines.remove(current.id);
            break;
          case SelectionKind.circle:
            await _api.deleteCircle(_sketchId!, current.id);
            circles.remove(current.id);
            break;
          case SelectionKind.point:
            await _api.deletePoint(_sketchId!, current.id);
            points.remove(current.id);
            break;
          case SelectionKind.constraint:
            await _api.deleteConstraint(_sketchId!, current.id);
            constraints.remove(current.id);
            break;
        }
      }
      // Removing a Constraint changes the system's degrees of freedom, so
      // unlike deleting a Point/Line/Circle (which only ever removes
      // geometry the solver already accounted for) this needs an explicit
      // re-solve to reflect the now-looser system.
      if (deletedConstraint) {
        await _solveAndTrackDof();
        await _refreshConstraints();
      }
      await _refreshAllPoints();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
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

  /// PATCHes the selected single Constraint's value (new work package item
  /// 3's "change value" ribbon action) - mirrors [confirmGhostValue]'s
  /// PATCH-existing-constraint path, then deselects and closes the ribbon on
  /// success, same as every other constraint mutation (item 7).
  Future<void> updateSelectedConstraintValue(double value) async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.constraint) return;

    await _runGuarded(() async {
      await _api.updateConstraintValue(_sketchId!, current.id, value);
      await _refreshAllPoints();
      await _refreshConstraints();
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
    final current = _selectionSet.first;
    switch (current.kind) {
      case SelectionKind.line:
        return lines[current.id]?.construction;
      case SelectionKind.circle:
        return circles[current.id]?.construction;
      case SelectionKind.point:
      case SelectionKind.constraint:
        return null;
    }
  }

  /// Flips [selection]'s construction flag via the backend PATCH endpoint -
  /// immediate, no confirmation, mirroring [deleteSelected]'s
  /// backend-is-truth pattern. A no-op if nothing applicable is selected.
  Future<void> toggleSelectedConstruction() async {
    final currentlyConstruction = selectedIsConstruction;
    if (currentlyConstruction == null || _busy || _sketchId == null) return;
    final current = _selectionSet.first;

    await _runGuarded(() async {
      final next = !currentlyConstruction;
      switch (current.kind) {
        case SelectionKind.line:
          final updated = await _api.updateLine(_sketchId!, current.id, construction: next);
          lines[current.id] = SketchLineView(
            id: updated.id,
            startPointId: updated.startPointId,
            endPointId: updated.endPointId,
            construction: updated.construction,
          );
          break;
        case SelectionKind.circle:
          final updated = await _api.updateCircle(_sketchId!, current.id, construction: next);
          circles[current.id] = SketchCircleView(
            id: updated.id,
            centerPointId: updated.centerPointId,
            radiusPointId: updated.radiusPointId,
            construction: updated.construction,
          );
          break;
        case SelectionKind.point:
        case SelectionKind.constraint:
          break;
      }
    });
  }

  /// Stage 13 item 6 (extended by Stage 16 item 7): which constraint-type
  /// buttons the flyout should offer for the current [selectionSet], per the
  /// prompt's selection-set table. Coincident/Parallel/Perpendicular/
  /// EqualLength/Collinear are wired here (Stage 16 item 7 moved them out of
  /// the dimension tool's now-removed button row - see
  /// [SketchDimensionBar]); Concentric/EqualRadius/Tangent remain
  /// `wired: false` since this Sketch model has no Arc entity or
  /// Concentric/EqualRadius backend support yet.
  List<ConstraintOption> get availableConstraintOptions {
    final sel = _selectionSet;

    if (sel.length == 1 && sel.first.kind == SelectionKind.line) {
      return const [
        ConstraintOption(type: ConstraintOptionType.vertical, label: 'Vertical', wired: true),
        ConstraintOption(type: ConstraintOptionType.horizontal, label: 'Horizontal', wired: true),
      ];
    }

    if (sel.length != 2) return const [];

    final kinds = sel.map((s) => s.kind).toSet();

    if (kinds.length == 1 && kinds.single == SelectionKind.line) {
      return const [
        ConstraintOption(type: ConstraintOptionType.parallel, label: 'Parallel', wired: true),
        ConstraintOption(
          type: ConstraintOptionType.perpendicular,
          label: 'Perpendicular',
          wired: true,
        ),
        ConstraintOption(type: ConstraintOptionType.equalLength, label: 'Equal length', wired: true),
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
      return const [ConstraintOption(type: ConstraintOptionType.coincident, label: 'Coincident', wired: true)];
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
      default:
        break;
    }
  }

  Future<void> addVerticalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      await _api.createVerticalConstraint(_sketchId!, current.id);
      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();
      _selectionSet.clear();
      _ribbonVisible = false;
    });
  }

  Future<void> addHorizontalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      await _api.createHorizontalConstraint(_sketchId!, current.id);
      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();
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

  /// Dispatches [_dimensionSelection]'s current shape onto a ghost set, per
  /// the new work package's combination table: one Line -> length; one
  /// Circle -> radius+diameter; two Points, or a Point+Line (substituting
  /// the Line's nearer endpoint - the backend has no point-to-line distance
  /// constraint, see [_buildPointLineGhosts]) -> vertical/horizontal/linear
  /// distance; two Lines -> a line-pair distance ghost if they're
  /// (near-)parallel, otherwise an angle ghost (see [_buildLinePairGhosts]).
  /// Any other shape (a bare Point or Circle alone, or anything with more
  /// than two entities) shows no ghosts.
  void _rebuildDimensionGhosts() {
    final sel = _dimensionSelection;

    if (sel.length == 1) {
      switch (sel.first.kind) {
        case SelectionKind.line:
          _buildLineLengthGhost(sel.first.id);
          return;
        case SelectionKind.circle:
          _buildRadiusGhosts(sel.first.id);
          return;
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

  void _buildRadiusGhosts(String circleId) {
    final circle = circles[circleId];
    _ghosts = circle == null
        ? []
        : [
            DimensionGhost(
              key: 'radius',
              kind: GhostKind.radius,
              pointAId: circle.centerPointId,
              pointBId: circle.radiusPointId,
            ),
            DimensionGhost(
              key: 'diameter',
              kind: GhostKind.diameter,
              pointAId: circle.centerPointId,
              pointBId: circle.radiusPointId,
            ),
          ];
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

  DistanceConstraintDto? _findDistanceConstraint(String pointAId, String pointBId) {
    for (final constraint in constraints.values) {
      if (constraint is DistanceConstraintDto &&
          ((constraint.pointAId == pointAId && constraint.pointBId == pointBId) ||
              (constraint.pointAId == pointBId && constraint.pointBId == pointAId))) {
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
          await _api.updateConstraintValue(_sketchId!, existing.id, value);
        } else {
          await _api.createAngleConstraint(_sketchId!, target.lineAId!, target.lineBId!, value);
        }
        await _solveAndTrackDof();
        await _refreshAllPoints();
        await _refreshConstraints();
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
          await _api.updateConstraintValue(_sketchId!, existing.id, value);
        } else {
          await _api.createLineDistanceConstraint(_sketchId!, target.lineAId!, target.lineBId!, value);
        }
        await _solveAndTrackDof();
        await _refreshAllPoints();
        await _refreshConstraints();
        _ghosts = [];
        _dimensionSelection.clear();
        _activeGhostKey = null;
      });
      return;
    }

    final pointAId = target.pointAId!;
    final pointBId = target.pointBId!;
    final distanceValue = target.kind == GhostKind.diameter ? value / 2 : value;

    await _runGuarded(() async {
      final existing = _findDistanceConstraint(pointAId, pointBId);
      if (existing != null) {
        await _api.updateConstraintValue(_sketchId!, existing.id, distanceValue);
      } else {
        await _api.createDistanceConstraint(_sketchId!, pointAId, pointBId, distanceValue);
        await _solveAndTrackDof();
      }
      await _refreshAllPoints();
      await _refreshConstraints();
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
    Future<void> Function(String sketchId, String idA, String idB) create,
  ) async {
    if (_selectionSet.length != 2 || _busy || _sketchId == null) return;
    final idA = _selectionSet[0].id;
    final idB = _selectionSet[1].id;
    await _runGuarded(() async {
      await create(_sketchId!, idA, idB);
      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();
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
  Future<void> adoptSketch(String sketchId) async {
    if (_sketchId != null) return;
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
      );
    }
    for (final constraint in await _api.listConstraints(sketchId)) {
      constraints[constraint.id] = constraint;
    }
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
  void moveCursorRelative(double dxPixels, double dyPixels, double zoom) {
    final scale = touchSensitivity / zoom;
    cursorX += dxPixels * scale;
    cursorY -= dyPixels * scale; // screen y is down; sketch y is up.
    notifyListeners();
  }

  /// Mouse input: absolute, 1:1 with device position - drives the crosshair
  /// preview ahead of a click.
  void moveCursorAbsoluteScreen(Offset screenPosition, ViewTransform transform) {
    final coord = transform.screenToSketch(screenPosition.dx, screenPosition.dy);
    cursorX = coord.x;
    cursorY = coord.y;
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

    switch (_lineMethod) {
      case LineConstructionMethod.endToEnd:
        await _clickEndToEndLineTool();
      case LineConstructionMethod.midpoint:
        await _clickMidpointLineTool();
    }
  }

  /// [SketchTool.point]: a single, self-terminating tap that places one
  /// Point - reuses [_pointIdAtCursor] so it shares the same snap-to-existing-
  /// Point/snap-to-midpoint behaviour every other placement path gets, even
  /// though here that mostly means "do nothing new" (snapping onto an
  /// already-existing Point creates nothing).
  Future<void> _clickPointTool() async {
    _selectionSet.clear();
    _ribbonVisible = false;
    await _runGuarded(() async {
      await _pointIdAtCursor();
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

      // One user action (this tap, now that the line is fully placed) = one
      // solve call - never on intermediate cursor movement.
      await _solveAndTrackDof();
      await _refreshAllPoints();

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
    await _runGuarded(() async {
      final endAId = await _pointIdAtCursor();
      final endA = points[endAId]!;
      final mirrored = await _api.createPoint(_sketchId!, 2 * midX - endA.x, 2 * midY - endA.y);
      points[mirrored.id] = SketchPointView(id: mirrored.id, x: mirrored.x, y: mirrored.y);

      final line = await _api.createLine(_sketchId!, endAId, mirrored.id);
      lines[line.id] = SketchLineView(
        id: line.id,
        startPointId: line.startPointId,
        endPointId: line.endPointId,
        construction: line.construction,
      );

      await _solveAndTrackDof();
      await _refreshAllPoints();
      _midpointAnchorX = null;
      _midpointAnchorY = null;
    });
  }

  /// Circle tool's tap handling: first tap places the center Point, second
  /// tap places the radius Point, creates the Circle (which auto-creates
  /// its radius DistanceConstraint server-side), and solves -
  /// self-terminating, unlike a Line chain, so there is no separate
  /// "finish" step.
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
      final radiusPointId = await _pointIdAtCursor(excludeId: _circleCenterPointId);

      final circle = await _api.createCircle(_sketchId!, _circleCenterPointId!, radiusPointId);
      circles[circle.id] = SketchCircleView(
        id: circle.id,
        centerPointId: circle.centerPointId,
        radiusPointId: circle.radiusPointId,
        construction: circle.construction,
      );

      // Same rule as a completed Line: one finished entity = one solve call.
      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();

      _circleCenterPointId = null;
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
      final radiusPoint = await _api.createPoint(_sketchId!, cx, cy);
      points[radiusPoint.id] = SketchPointView(id: radiusPoint.id, x: radiusPoint.x, y: radiusPoint.y);

      final circle = await _api.createCircle(_sketchId!, centerPoint.id, radiusPoint.id);
      circles[circle.id] = SketchCircleView(
        id: circle.id,
        centerPointId: circle.centerPointId,
        radiusPointId: circle.radiusPointId,
        construction: circle.construction,
      );

      await _solveAndTrackDof();
      await _refreshAllPoints();
      await _refreshConstraints();
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
    return point.id;
  }

  /// Stage 15 item 6: creates the 4 shared corner Points (snapping/reusing
  /// per [_pointIdAt], same as every other entity placement) and the 4
  /// connecting Lines for a Rectangle, going around in order (so each
  /// consecutive pair of corners shares an edge), then auto-applies 3
  /// [SketchApiClient.createPerpendicularConstraint] calls between
  /// consecutive edges and solves once. [corner0Id]/[corner1Id] let a
  /// caller pass in a Point already placed by an earlier tap (so it isn't
  /// re-created/re-snapped) - null means "create/snap fresh at this
  /// coordinate". A quadrilateral's interior angles sum to 360 degrees, so
  /// constraining 3 of its 4 corners to 90 degrees forces the last corner
  /// to 90 degrees too - no fourth/redundant perpendicular constraint
  /// needed.
  Future<void> _buildRectangle({
    String? corner0Id,
    String? corner1Id,
    required (double, double) corner0,
    required (double, double) corner1,
    required (double, double) corner2,
    required (double, double) corner3,
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
    final line2 = await _api.createLine(_sketchId!, p1, p2);
    lines[line2.id] = SketchLineView(
      id: line2.id,
      startPointId: line2.startPointId,
      endPointId: line2.endPointId,
      construction: line2.construction,
    );
    final line3 = await _api.createLine(_sketchId!, p2, p3);
    lines[line3.id] = SketchLineView(
      id: line3.id,
      startPointId: line3.startPointId,
      endPointId: line3.endPointId,
      construction: line3.construction,
    );
    final line4 = await _api.createLine(_sketchId!, p3, p0);
    lines[line4.id] = SketchLineView(
      id: line4.id,
      startPointId: line4.startPointId,
      endPointId: line4.endPointId,
      construction: line4.construction,
    );

    await _api.createPerpendicularConstraint(_sketchId!, line1.id, line2.id);
    await _api.createPerpendicularConstraint(_sketchId!, line2.id, line3.id);
    await _api.createPerpendicularConstraint(_sketchId!, line3.id, line4.id);

    await _solveAndTrackDof();
    await _refreshAllPoints();
    await _refreshConstraints();
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

  Future<void> _refreshAllPoints() async {
    for (final id in points.keys.toList()) {
      final fresh = await _api.getPoint(_sketchId!, id);
      points[id] = SketchPointView(id: fresh.id, x: fresh.x, y: fresh.y);
    }
    await _refreshProfile();
  }

  List<String>? _closedProfilePointIds;

  /// The ordered Point ids of the sketch's single closed loop, or null if
  /// there isn't exactly one (no loop, an open chain, or multiple loops).
  /// Refreshed alongside points/constraints on every [_refreshAllPoints]
  /// call via the existing `GET /sketch/sketches/{id}/profile` endpoint.
  List<String>? get closedProfilePointIds => _closedProfilePointIds;

  Future<void> _refreshProfile() async {
    final profile = await _api.getProfile(_sketchId!);
    final ids = profile.pointIds;
    _closedProfilePointIds = profile.isClosedLoop && ids != null && ids.isNotEmpty ? ids : null;
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
