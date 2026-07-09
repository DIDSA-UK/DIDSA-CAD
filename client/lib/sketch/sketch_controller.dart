import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;

import '../api/sketch_api_client.dart';
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

  /// Bug-fix round 2: whether the most recent solve actually converged.
  /// `dof` is only meaningful when it did - py-slvs can (and does, for a
  /// genuinely redundant-but-consistent constraint set, e.g. two
  /// AtMidpoint constraints on the same Point that are only independent
  /// before a solve resolves them - see the rectangle tool's fix for
  /// exactly this) fail to converge (`result_code != 0`) while still
  /// reporting `dof == 0`, which - trusted blindly - showed a visibly
  /// under-constrained sketch as "fully constrained". [isUnderConstrained]
  /// treats a non-convergent solve as under-constrained regardless of what
  /// `dof` says, since a failed solve is never "fully constrained".
  bool _lastSolveConverged = true;
  bool get isUnderConstrained => _dof > 0 || !_lastSolveConverged;

  /// Whether this Sketch has any drawn entity at all (Lines/Circles) -
  /// bug-fix round: a brand-new, empty Sketch has `dof == 0` too (nothing
  /// but the pinned origin Point has any freedom to report), which used to
  /// make the "fully constrained" indicator light up before the user had
  /// drawn anything. That indicator should only ever appear once there's
  /// actually something to be fully constrained.
  bool get hasGeometry => lines.isNotEmpty || circles.isNotEmpty;

  /// [anchorPointIds] passes through to [SketchApiClient.solve] - see that
  /// method's doc comment. Defaults to none, which every call site except
  /// the drag-drop endings below wants (equal freedom for every Point).
  Future<void> _solveAndTrackDof({List<String> anchorPointIds = const []}) async {
    final result = await _api.solve(_sketchId!, anchorPointIds: anchorPointIds);
    _dof = result.dof;
    _lastSolveConverged = result.converged;
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

    return null;
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
        final center = points[circle.centerPointId]!;
        final radiusPoint = points[circle.radiusPointId]!;
        final distToCenter = math.pow(x - center.x, 2) + math.pow(y - center.y, 2);
        final distToRadius = math.pow(x - radiusPoint.x, 2) + math.pow(y - radiusPoint.y, 2);
        final nearerId = distToCenter <= distToRadius ? circle.centerPointId : circle.radiusPointId;
        // Mirrors the Line case above - the origin is never offered.
        return nearerId == _originPointId ? null : nearerId;
      case SelectionKind.constraint:
        return null;
    }
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
        final center = points[circle.centerPointId]!;
        final radiusPoint = points[circle.radiusPointId]!;
        final distToCenter = math.pow(x - center.x, 2) + math.pow(y - center.y, 2);
        final distToRadius = math.pow(x - radiusPoint.x, 2) + math.pow(y - radiusPoint.y, 2);
        final nearerId = distToCenter <= distToRadius ? circle.centerPointId : circle.radiusPointId;
        return nearerId == _originPointId
            ? null
            : SketchSelection(kind: SelectionKind.point, id: nearerId);
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
    if (_draggingLabelId != null || _draggingLineId != null) return false;
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
      await _refreshAllPoints();
      await _refreshConstraints();
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
    _draggingLineId = lineId;
    _dragOriginCursorX = cursorX;
    _dragOriginCursorY = cursorY;
    _dragOriginLineStartX = start.x;
    _dragOriginLineStartY = start.y;
    _dragOriginLineEndX = end.x;
    _dragOriginLineEndY = end.y;
    notifyListeners();
    return true;
  }

  /// [beginLineDrag]'s per-move update - both endpoints move by the same
  /// delta from where the drag started, applied to each endpoint's own
  /// origin position (same origin-relative math as [updatePointDrag], so
  /// the Line never "jumps" to be exactly under the cursor on the first
  /// move). PATCHes both endpoints immediately, same backend-is-truth
  /// tracking as [updatePointDrag].
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
      await _refreshAllPoints();
      await _refreshConstraints();
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
      _ => (pointIds: <String>{}, lineIds: <String>{}),
    };
  }

  /// Everything deleting [selection] would need to also delete, computed
  /// transitively: a Point pulls in every Line/Circle that references it
  /// (start/end or center/radius); every Point/Line actually being deleted
  /// (directly selected or pulled in) pulls in every Constraint that
  /// references it. Replaces the old behaviour of just disallowing deletion
  /// of a still-referenced Point/Line outright - the backend rejects
  /// (rather than auto-cascades) deleting something still referenced by
  /// other geometry, so the client now computes and performs the full
  /// cascade itself, with the UI layer (see sketch_ribbon.dart) responsible
  /// for warning the user what else is about to go.
  ({Set<String> points, Set<String> lines, Set<String> circles, Set<String> constraints})
      computeDeleteCascade(Iterable<SketchSelection> selection) {
    final pointIds = <String>{};
    final lineIds = <String>{};
    final circleIds = <String>{};
    final constraintIds = <String>{};
    for (final s in selection) {
      switch (s.kind) {
        case SelectionKind.point:
          if (s.id != _originPointId) pointIds.add(s.id);
        case SelectionKind.line:
          lineIds.add(s.id);
        case SelectionKind.circle:
          circleIds.add(s.id);
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
    for (final entry in constraints.entries) {
      final refs = _constraintReferences(entry.value);
      if (refs.pointIds.any(pointIds.contains) || refs.lineIds.any(lineIds.contains)) {
        constraintIds.add(entry.key);
      }
    }
    return (points: pointIds, lines: lineIds, circles: circleIds, constraints: constraintIds);
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
    final capturedConstraints = <ConstraintDto>[];
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
      // Backend rejects deleting a Point still referenced by a Line/Circle,
      // and a Line/Circle can itself still be referenced by a Constraint -
      // so deletion must run in the reverse of creation/dependency order
      // (Constraints, then Lines/Circles, then Points), regardless of the
      // order entities happened to be selected/tapped in. Mirrors
      // [_restoreDeletedEntities]'s own (forward) Points -> Lines/Circles ->
      // Constraints ordering.
      final constraintsToDelete = toDelete.where((s) => s.kind == SelectionKind.constraint);
      final linesCirclesToDelete = toDelete.where(
        (s) => s.kind == SelectionKind.line || s.kind == SelectionKind.circle,
      );
      final pointsToDelete = toDelete.where((s) => s.kind == SelectionKind.point);
      for (final current in [...constraintsToDelete, ...linesCirclesToDelete, ...pointsToDelete]) {
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
      _pushUndo(() => _restoreDeletedEntities(
            capturedPoints,
            capturedLines,
            capturedCircles,
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
      await _refreshConstraints();
      await _refreshAllPoints();
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
      );
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
        await _solveAndTrackDof();
      }
      await _refreshAllPoints();
      await _refreshConstraints();
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
        ConstraintOption(type: ConstraintOptionType.vertical, label: 'Vert.', wired: true),
        ConstraintOption(type: ConstraintOptionType.horizontal, label: 'Horiz.', wired: true),
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
      default:
        break;
    }
  }

  Future<void> addVerticalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      final constraint = await _api.createVerticalConstraint(_sketchId!, current.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
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
      final constraint = await _api.createHorizontalConstraint(_sketchId!, current.id);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
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
      if (existing != null) {
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
        _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
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
    Future<ConstraintDto> Function(String sketchId, String idA, String idB) create,
  ) async {
    if (_selectionSet.length != 2 || _busy || _sketchId == null) return;
    final idA = _selectionSet[0].id;
    final idB = _selectionSet[1].id;
    await _runGuarded(() async {
      final constraint = await create(_sketchId!, idA, idB);
      _pushUndo(() async => _api.deleteConstraint(_sketchId!, constraint.id));
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
      await _refreshAllPoints();
      await _refreshConstraints();
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
      _pushUndo(() async {
        await _api.deleteLine(_sketchId!, line.id);
        lines.remove(line.id);
      });

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
      _pushUndo(() async {
        await _api.deleteCircle(_sketchId!, circle.id);
        circles.remove(circle.id);
      });

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
      );
      _pushUndo(() async {
        await _api.deleteCircle(_sketchId!, circle.id);
        circles.remove(circle.id);
      });

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

  Future<void> _refreshAllPoints() async {
    for (final id in points.keys.toList()) {
      final fresh = await _api.getPoint(_sketchId!, id);
      points[id] = SketchPointView(id: fresh.id, x: fresh.x, y: fresh.y);
    }
    await _refreshProfile();
  }

  List<ProfileLoopDto> _closedProfileFills = const [];

  /// Every outer profile loop the sketch's closed-profile detection found,
  /// each already carrying its own holes - one entry for a single closed
  /// loop (C1, may have inner holes), 2+ for a MultiProfile of disjoint
  /// outer loops (C2, each with its own holes), or empty if there's no
  /// usable profile at all (no loop, an open chain, a branch, overlapping/
  /// invalid nesting). Refreshed alongside points/constraints on every
  /// [_refreshAllPoints] call via the existing
  /// `GET /sketch/sketches/{id}/profile` endpoint.
  ///
  /// Bug fix: previously this only ever held a single loop's Point ids and
  /// was null whenever `status != closed_loop`, so a sketch with a
  /// MultiProfile (or a hole) never got its area(s) filled in the 2D
  /// canvas at all - see [SketchCanvas._paintClosedProfileFill].
  List<ProfileLoopDto> get closedProfileFills => _closedProfileFills;

  Future<void> _refreshProfile() async {
    final profile = await _api.getProfile(_sketchId!);
    // >= 2, not >= 3: a Line-chain polygon loop needs at least 3 points,
    // but a standalone Circle profile (see app.sketch.profile._circle_profile)
    // is reported as exactly 2 points (center, radius point) - the same
    // 2-vs-3+ distinction SketchCanvas._profileLoopPath uses to tell a
    // circle loop apart from a polygon one. A >= 3 filter here silently
    // dropped every Circle profile - bug fix, previously untested since
    // earlier on-device rounds only exercised Line-chain rectangles.
    _closedProfileFills = profile.fillableLoops.where((loop) => loop.pointIds.length >= 2).toList();
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
      await _refreshAllPoints();
      await _refreshConstraints();
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
