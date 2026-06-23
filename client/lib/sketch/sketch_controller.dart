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
/// active. Selected via the FAB's "Sketch Entities" category.
enum SketchTool { line, circle }

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

/// The kind of entity a [SketchSelection] refers to.
enum SelectionKind { point, line, circle }

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
/// multi-entity [SketchController.selectionSet]. Only [vertical] and
/// [horizontal] are wired to the backend; every other type renders as a
/// greyed-out, non-tappable button - this Sketch model has no Arc entity
/// yet, so the prompt's "1 arc + 1 line -> Tangent" row is offered for
/// "1 circle + 1 line" instead, the closest available analog.
enum ConstraintOptionType {
  vertical,
  horizontal,
  parallel,
  perpendicular,
  equalLength,
  coincident,
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
/// [SketchController.confirmGhostValue].
enum GhostKind { length, vertical, horizontal, radius, diameter }

/// A client-side-only preview of a dimension that doesn't exist as a real
/// Constraint yet (or whose existing value hasn't been confirmed for
/// editing yet) - Stage 13 item 5. Nothing here is sent to the backend
/// until [SketchController.confirmGhostValue] runs; [key] is a stable
/// per-kind identifier ('length'/'v'/'h'/'radius'/'diameter') the UI uses to
/// address a specific ghost (e.g. which one was tapped, which one to render
/// active/dimmed).
class DimensionGhost {
  final String key;
  final GhostKind kind;
  final String pointAId;
  final String pointBId;

  const DimensionGhost({
    required this.key,
    required this.kind,
    required this.pointAId,
    required this.pointBId,
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

  SketchMode _mode = SketchMode.select;
  SketchMode get mode => _mode;

  /// A short label for the sketcher toolbar (Stage 13 item 5: "Show the
  /// current mode clearly in the sketcher toolbar label").
  String get modeLabel {
    switch (_mode) {
      case SketchMode.select:
        return 'Select';
      case SketchMode.draw:
        return _activeTool == SketchTool.line ? 'Draw: Line' : 'Draw: Circle';
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
  }

  String? _chainStartPointId;
  String? _chainFirstPointId;

  String? _circleCenterPointId;

  /// The center Point of a Circle placed but not yet completed (waiting on
  /// the radius-defining tap) - null if no Circle is in progress.
  String? get circleCenterPointId => _circleCenterPointId;
  bool get circleInProgress => _circleCenterPointId != null;

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

  /// The Point, Line, or Circle nearest [cursorX]/[cursorY] and within
  /// [radius], or null if nothing is close enough. Points are checked
  /// before Lines/Circles so a Point at a Line's endpoint or a Circle's
  /// center/radius always wins over the entity it belongs to. The shared
  /// core behind both [hoveredEntity] (continuous mouse hover, always
  /// [snapRadius]) and every discrete-tap hit-test (select/dimension mode,
  /// using the larger of [snapRadius] and the 44px touch target - see
  /// [hitRadiusForPixelsPerUnit]).
  SketchSelection? _entityAt(double x, double y, double radius) {
    for (final point in points.values) {
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
    return _entityAt(cursorX, cursorY, snapRadius);
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

  /// The single entry point for every tap on the 2D sketch canvas - Stage
  /// 13 item 3 replaces the old separate "move cursor, then press Click"
  /// flow with this: [sketchX]/[sketchY] is the tapped location, already
  /// converted from screen space by the caller. Dispatches on [mode]:
  /// drawing (replaces the old `click()`), selecting (replaces the old
  /// no-arg `handleCanvasTap()`), or picking a dimension target/ghost.
  /// Returns a [Future] so tests/callers that care can await the underlying
  /// network calls in [SketchMode.draw]; [SketchCanvas] itself fires this
  /// without awaiting, same as Stage 12's Click button did.
  Future<void> handleCanvasTap(double sketchX, double sketchY, [double? hitRadius]) async {
    cursorX = sketchX;
    cursorY = sketchY;
    final radius = hitRadius ?? snapRadius;
    switch (_mode) {
      case SketchMode.select:
        _handleSelectTap(radius);
        break;
      case SketchMode.draw:
        await _handleDrawTap();
        break;
      case SketchMode.dimension:
        _handleDimensionTap(radius);
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
  void _handleSelectTap(double hitRadius) {
    final hit = _entityAt(cursorX, cursorY, hitRadius);
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
        }
      }
      await _refreshAllPoints();
      _selectionSet.clear();
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
          break;
      }
    });
  }

  /// Stage 13 item 6: which constraint-type buttons the flyout should offer
  /// for the current [selectionSet], per the prompt's selection-set table.
  /// Every type besides Vertical/Horizontal is returned with `wired: false`
  /// so the flyout can render it greyed out rather than omit it entirely.
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
        ConstraintOption(type: ConstraintOptionType.parallel, label: 'Parallel', wired: false),
        ConstraintOption(
          type: ConstraintOptionType.perpendicular,
          label: 'Perpendicular',
          wired: false,
        ),
        ConstraintOption(type: ConstraintOptionType.equalLength, label: 'Equal length', wired: false),
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
      return const [ConstraintOption(type: ConstraintOptionType.coincident, label: 'Coincident', wired: false)];
    }

    return const [];
  }

  /// Applies a wired [ConstraintOption] from the flyout - a no-op (besides
  /// being unreachable from the UI, since unwired options render
  /// non-tappable) for any type besides Vertical/Horizontal.
  Future<void> applyConstraintOption(ConstraintOptionType type) async {
    switch (type) {
      case ConstraintOptionType.vertical:
        await addVerticalConstraint();
        break;
      case ConstraintOptionType.horizontal:
        await addHorizontalConstraint();
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
      await _api.solve(_sketchId!);
      await _refreshAllPoints();
      await _refreshConstraints();
    });
  }

  Future<void> addHorizontalConstraint() async {
    if (_selectionSet.length != 1 || _busy || _sketchId == null) return;
    final current = _selectionSet.first;
    if (current.kind != SelectionKind.line) return;

    await _runGuarded(() async {
      await _api.createHorizontalConstraint(_sketchId!, current.id);
      await _api.solve(_sketchId!);
      await _refreshAllPoints();
      await _refreshConstraints();
    });
  }

  // --- Stage 13 item 5: Dimension mode --------------------------------

  final List<SketchSelection> _dimensionSelection = [];

  /// The entity/entities picked so far in [SketchMode.dimension] - one Line
  /// or Circle, or up to two Points (see [_handleDimensionTap]).
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

  /// [SketchMode.dimension]'s tap handling. Tapping a Line or Circle/point
  /// shows that entity's ghost(s) immediately; tapping a second Point while
  /// exactly one Point is already picked shows the V/H distance ghosts
  /// between them instead. Tapping empty canvas clears any current pick, or
  /// exits to [SketchMode.select] if nothing was picked at all (Stage 13
  /// item 5: "tap empty canvas with no entity selected").
  void _handleDimensionTap(double hitRadius) {
    final hit = _entityAt(cursorX, cursorY, hitRadius);
    if (hit == null) {
      if (_dimensionSelection.isEmpty && _ghosts.isEmpty) {
        exitToSelectMode();
      } else {
        _dimensionSelection.clear();
        _ghosts = [];
        _activeGhostKey = null;
        notifyListeners();
      }
      return;
    }

    if (hit.kind == SelectionKind.point &&
        _dimensionSelection.length == 1 &&
        _dimensionSelection.first.kind == SelectionKind.point &&
        _dimensionSelection.first.id != hit.id) {
      _dimensionSelection.add(hit);
      _activeGhostKey = null;
      _buildDistanceGhosts(_dimensionSelection[0].id, hit.id);
      notifyListeners();
      return;
    }

    _dimensionSelection
      ..clear()
      ..add(hit);
    _activeGhostKey = null;
    switch (hit.kind) {
      case SelectionKind.line:
        _buildLineLengthGhost(hit.id);
        break;
      case SelectionKind.circle:
        _buildRadiusGhosts(hit.id);
        break;
      case SelectionKind.point:
        _ghosts = [];
        break;
    }
    notifyListeners();
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

  void _buildDistanceGhosts(String pointAId, String pointBId) {
    _ghosts = [
      DimensionGhost(key: 'v', kind: GhostKind.vertical, pointAId: pointAId, pointBId: pointBId),
      DimensionGhost(key: 'h', kind: GhostKind.horizontal, pointAId: pointAId, pointBId: pointBId),
    ];
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

  /// The current solved value a ghost would prefill its inline text input
  /// with - the ghost's own ? label (Stage 13 item 5/6's visual spec) is
  /// unaffected by this; it's still always "?" until a value is confirmed.
  double? currentGhostValue(DimensionGhost ghost) {
    final a = points[ghost.pointAId];
    final b = points[ghost.pointBId];
    if (a == null || b == null) return null;
    switch (ghost.kind) {
      case GhostKind.length:
      case GhostKind.radius:
        return math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
      case GhostKind.diameter:
        return 2 * math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
      case GhostKind.vertical:
        return (b.y - a.y).abs();
      case GhostKind.horizontal:
        return (b.x - a.x).abs();
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
    final distanceValue = target.kind == GhostKind.diameter ? value / 2 : value;

    await _runGuarded(() async {
      final existing = _findDistanceConstraint(target.pointAId, target.pointBId);
      if (existing != null) {
        await _api.updateConstraintValue(_sketchId!, existing.id, distanceValue);
      } else {
        await _api.createDistanceConstraint(_sketchId!, target.pointAId, target.pointBId, distanceValue);
        await _api.solve(_sketchId!);
      }
      await _refreshAllPoints();
      await _refreshConstraints();
      _ghosts = [];
      _dimensionSelection.clear();
      _activeGhostKey = null;
    });
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
  /// across separate touches - this only ever adds a delta. Purely a visual
  /// preview now that tap-to-place commits at the tap's own location (Stage
  /// 13 item 3) rather than at this cursor.
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

  /// [SketchMode.draw]'s tap handling - what it commits depends on
  /// [activeTool]. [cursorX]/[cursorY] have already been set to the tapped
  /// location by [handleCanvasTap] before this runs, so every existing
  /// snap/point-coincidence check below (which all read those fields)
  /// applies unchanged.
  Future<void> _handleDrawTap() async {
    if (_busy || _sketchId == null) return;

    if (_activeTool == SketchTool.circle) {
      await _clickCircleTool();
      return;
    }

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
      await _api.solve(_sketchId!);
      await _refreshAllPoints();

      if (closingLoop) {
        _chainStartPointId = null;
        _chainFirstPointId = null;
      } else {
        _chainStartPointId = endPointId;
      }
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
      await _api.solve(_sketchId!);
      await _refreshAllPoints();
      await _refreshConstraints();

      _circleCenterPointId = null;
    });
  }

  /// Resolves the Point id a tap at the current cursor should use: the
  /// real origin Point's id if the cursor is hovering it (and that id isn't
  /// [excludeId] - e.g. an entity's own center/chain-start id, which it can
  /// never coincide with), otherwise a freshly created Point at the cursor.
  /// The single place every tap-to-place path goes through to place/reuse a
  /// Point, so origin-snapping applies uniformly to chain starts, chain
  /// continuations, and both Circle taps.
  Future<String> _pointIdAtCursor({String? excludeId}) async {
    if (isHoveringOrigin && _originPointId != excludeId) {
      return _originPointId!;
    }
    final point = await _api.createPoint(_sketchId!, cursorX, cursorY);
    points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
    return point.id;
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
