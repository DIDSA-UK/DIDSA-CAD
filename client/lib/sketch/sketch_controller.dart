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

  const SketchLineView({required this.id, required this.startPointId, required this.endPointId});
}

class SketchCircleView {
  final String id;
  final String centerPointId;
  final String radiusPointId;

  const SketchCircleView({required this.id, required this.centerPointId, required this.radiusPointId});
}

/// Which entity the next Click commits. Selected via the tool-switcher FAB.
enum SketchTool { line, circle }

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

  final Map<String, SketchPointView> points = {};
  final Map<String, SketchLineView> lines = {};
  final Map<String, SketchCircleView> circles = {};

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

  Future<void> ensureSketch() async {
    if (_sketchId != null) return;
    await _runGuarded(() async {
      final sketch = await _api.createSketch(plane: 'XY');
      _sketchId = sketch.id;
      _originPointId = sketch.originPointId;
      points[sketch.originPointId] = SketchPointView(id: sketch.originPointId, x: 0, y: 0);
    });
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
      );

      // Same rule as a completed Line: one finished entity = one solve call.
      await _api.solve(_sketchId!);
      await _refreshAllPoints();

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
