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

/// Which entity the next Click commits. Selected via the tool-switcher FAB.
enum SketchTool { line, circle }

/// The kind of entity a [SketchSelection] refers to.
enum SelectionKind { point, line, circle }

/// The single hovered-or-selected entity, idle-state only (see
/// [SketchController.isIdle]) - distinct from the chain-start/circle-center
/// "in progress" highlighting, which applies only during active drawing.
class SketchSelection {
  final SelectionKind kind;
  final String id;

  const SketchSelection({required this.kind, required this.id});
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
  /// Point before a Click is treated as "close the loop" rather than
  /// "place a new point".
  static const double snapRadius = 0.5;

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

  /// Every Constraint currently on this Sketch, keyed by id - Stage 12 item
  /// 10's dimension overlays read straight from this. Render-only: there is
  /// no client-side action that creates/edits one yet (see
  /// [_refreshConstraints]'s doc comment), so this is only ever populated
  /// from the backend, never written to directly.
  final Map<String, ConstraintDto> constraints = {};

  double cursorX = 0;
  double cursorY = 0;

  SketchTool _activeTool = SketchTool.line;
  SketchTool get activeTool => _activeTool;

  void setTool(SketchTool tool) {
    if (_activeTool == tool) return;
    _activeTool = tool;
    notifyListeners();
  }

  String? _chainStartPointId;
  String? _chainFirstPointId;

  String? _circleCenterPointId;

  /// The center Point of a Circle placed but not yet completed (waiting on
  /// the radius-defining Click) - null if no Circle is in progress.
  String? get circleCenterPointId => _circleCenterPointId;
  bool get circleInProgress => _circleCenterPointId != null;

  /// The Point id the *next* line segment will start from, or null if no
  /// chain is currently in progress.
  String? get currentChainStartPointId => _chainStartPointId;

  /// The first Point of the current chain - the one a Click can snap back
  /// onto to close the loop.
  String? get chainFirstPointId => _chainFirstPointId;

  bool get chainInProgress => _chainStartPointId != null;

  bool _busy = false;
  bool get busy => _busy;

  String? errorMessage;

  /// True when the cursor is close enough to the chain's start Point that
  /// the next Click will close the loop using that Point's id, rather than
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
  /// that the next Click should land exactly on it, rather than creating a
  /// new coincident Point - the same snap-radius pattern as
  /// [isHoveringChainStart], applied to the origin instead of a chain start.
  bool get isHoveringOrigin {
    final origin = points[_originPointId];
    if (origin == null) return false;
    final dx = cursorX - origin.x;
    final dy = cursorY - origin.y;
    return (dx * dx + dy * dy) <= snapRadius * snapRadius;
  }

  SketchSelection? _selection;

  /// The currently selected entity, or null if nothing is selected - set by
  /// [handleCanvasTap], cleared whenever a new chain/circle starts being
  /// drawn (see [click]) or a delete succeeds.
  SketchSelection? get selection => _selection;

  bool _ribbonVisible = false;

  /// Whether the contextual ribbon panel should be showing - opened by any
  /// qualifying tap (see [handleCanvasTap]), closed as soon as drawing
  /// starts again, since the ribbon is for acting on a selection/idle
  /// canvas, not for drawing.
  bool get ribbonVisible => _ribbonVisible;

  /// True while nothing is currently being drawn - no chain in progress, no
  /// circle mid-placement. Hovering/selecting an existing entity, and the
  /// ribbon, only ever apply while idle; a bare tap during active drawing
  /// must not trigger either, per the Stage 6 interaction model.
  bool get isIdle => !chainInProgress && !circleInProgress;

  /// The Point, Line, or Circle nearest the cursor and within [snapRadius],
  /// or null while not idle, or if nothing is close enough. Points are
  /// checked before Lines/Circles so a Point at a Line's endpoint or a
  /// Circle's center/radius always wins over the entity it belongs to.
  SketchSelection? get hoveredEntity {
    if (!isIdle) return null;

    for (final point in points.values) {
      final dx = cursorX - point.x;
      final dy = cursorY - point.y;
      if (dx * dx + dy * dy <= snapRadius * snapRadius) {
        return SketchSelection(kind: SelectionKind.point, id: point.id);
      }
    }

    for (final line in lines.values) {
      final start = points[line.startPointId];
      final end = points[line.endPointId];
      if (start == null || end == null) continue;
      if (_distanceToSegment(cursorX, cursorY, start.x, start.y, end.x, end.y) <= snapRadius) {
        return SketchSelection(kind: SelectionKind.line, id: line.id);
      }
    }

    for (final circle in circles.values) {
      final center = points[circle.centerPointId];
      final radiusPoint = points[circle.radiusPointId];
      if (center == null || radiusPoint == null) continue;
      final radius = math.sqrt(
        math.pow(radiusPoint.x - center.x, 2) + math.pow(radiusPoint.y - center.y, 2),
      );
      final distanceToCenter = math.sqrt(
        math.pow(cursorX - center.x, 2) + math.pow(cursorY - center.y, 2),
      );
      if ((distanceToCenter - radius).abs() <= snapRadius) {
        return SketchSelection(kind: SelectionKind.circle, id: circle.id);
      }
    }

    return null;
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
  /// ribbon can grey out Delete without a round-trip - or null if this
  /// client-side check sees no reason to block it. The backend is still the
  /// final authority (e.g. for Constraints, which the client doesn't track
  /// locally) - see [deleteSelected]'s error handling for that fallback, so
  /// a null result here is not a guarantee the backend will accept it.
  String? get selectedPointDeleteBlockedReason {
    final current = _selection;
    if (current == null || current.kind != SelectionKind.point) return null;
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

  /// The "select / tap blank space" gesture - a bare tap/click on the
  /// canvas, as distinct from the Click button (see [click]). A no-op
  /// while drawing is in progress, since drawing-mode interaction must be
  /// unaffected by selection. While idle: hovering an entity selects it and
  /// opens/keeps open the ribbon. Tapping blank space (nothing hovered)
  /// while the ribbon is already open dismisses it back to a clean idle
  /// state, matching how a tap-outside is expected to close a contextual
  /// panel; tapping blank space while the ribbon is closed instead opens it
  /// showing the idle actions (e.g. Exit Sketch), same as Stage 6.
  void handleCanvasTap() {
    if (!isIdle) return;
    final hovered = hoveredEntity;
    if (hovered == null && _ribbonVisible) {
      _selection = null;
      _ribbonVisible = false;
    } else {
      _selection = hovered;
      _ribbonVisible = true;
    }
    notifyListeners();
  }

  /// Explicitly closes the ribbon (its close button) and clears any
  /// selection - the only way to dismiss the ribbon other than starting a
  /// new chain/circle, since a tap on blank idle canvas re-opens it rather
  /// than closing it (see [handleCanvasTap]).
  void closeRibbon() {
    _selection = null;
    _ribbonVisible = false;
    notifyListeners();
  }

  /// Deletes [selection] via the matching backend DELETE endpoint, then
  /// refreshes from backend state - same backend-is-truth pattern as every
  /// other mutation. A rejected Point delete (e.g. a Constraint the client
  /// doesn't track locally) surfaces via [errorMessage], same as any other
  /// API failure, and the selection is left in place so the ribbon keeps
  /// showing it.
  Future<void> deleteSelected() async {
    final current = _selection;
    if (current == null || _busy || _sketchId == null) return;

    await _runGuarded(() async {
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
      await _refreshAllPoints();
      _selection = null;
    });
  }

  /// Whether [selection] is a Line/Circle currently marked construction -
  /// drives the ribbon's Make-Construction/Make-Solid toggle label. Null
  /// (rather than false) when the selection isn't a Line/Circle at all, so
  /// the ribbon knows not to show the toggle for a Point selection.
  bool? get selectedIsConstruction {
    final current = _selection;
    if (current == null) return null;
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
    final current = _selection;
    final currentlyConstruction = selectedIsConstruction;
    if (current == null || currentlyConstruction == null || _busy || _sketchId == null) return;

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
  /// that can create one server-side as a side effect (so far, only
  /// [_clickCircleTool]'s auto-created radius DistanceConstraint - see
  /// `Sketch.add_circle`), so [constraints] stays current within the same
  /// session without a full [adoptSketch] re-entry. There is no
  /// client-side UI yet for adding a Vertical/Horizontal/Angle/standalone
  /// Distance constraint directly - those only ever appear after
  /// [adoptSketch] re-loads a Sketch that already has them (e.g. created
  /// via the API directly).
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
  /// across separate touches - this only ever adds a delta.
  void moveCursorRelative(double dxPixels, double dyPixels, double zoom) {
    final scale = touchSensitivity / zoom;
    cursorX += dxPixels * scale;
    cursorY -= dyPixels * scale; // screen y is down; sketch y is up.
    notifyListeners();
  }

  /// Windows mouse input: absolute, 1:1 with device position.
  void moveCursorAbsoluteScreen(Offset screenPosition, ViewTransform transform) {
    final coord = transform.screenToSketch(screenPosition.dx, screenPosition.dy);
    cursorX = coord.x;
    cursorY = coord.y;
    notifyListeners();
  }

  /// The single "commit an action at the cursor" entry point - driven by
  /// either the on-screen Click button or a real mouse click on Windows.
  /// What it commits depends on [activeTool].
  Future<void> click() async {
    if (_busy || _sketchId == null) return;

    if (_activeTool == SketchTool.circle) {
      await _clickCircleTool();
      return;
    }

    if (!chainInProgress) {
      _selection = null;
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

      // One user action (this Click, now that the line is fully placed) =
      // one solve call - never on intermediate cursor movement.
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

  /// Circle tool's Click handling: first Click places the center Point,
  /// second Click places the radius Point, creates the Circle (which
  /// auto-creates its radius DistanceConstraint server-side), and solves -
  /// self-terminating, unlike a Line chain, so there is no separate
  /// "finish" step.
  Future<void> _clickCircleTool() async {
    if (!circleInProgress) {
      _selection = null;
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

  /// Resolves the Point id a Click at the current cursor should use: the
  /// real origin Point's id if the cursor is hovering it (and that id isn't
  /// [excludeId] - e.g. an entity's own center/chain-start id, which it can
  /// never coincide with), otherwise a freshly created Point at the cursor.
  /// The single place every Click path goes through to place/reuse a Point,
  /// so origin-snapping applies uniformly to chain starts, chain
  /// continuations, and both Circle clicks.
  Future<String> _pointIdAtCursor({String? excludeId}) async {
    if (isHoveringOrigin && _originPointId != excludeId) {
      return _originPointId!;
    }
    final point = await _api.createPoint(_sketchId!, cursorX, cursorY);
    points[point.id] = SketchPointView(id: point.id, x: point.x, y: point.y);
    return point.id;
  }

  /// Ends the current chain without closing a loop - the next Click starts
  /// an unrelated new chain.
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
