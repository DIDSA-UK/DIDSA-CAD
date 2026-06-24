import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// A tiny in-memory fake of the backend's `/sketch` API (point/line/circle
/// creation, constraints, get, solve) good enough to exercise the
/// controller's chaining and dimension-ghost-confirmation logic without any
/// real network call.
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> lines = {};
  final Map<String, Map<String, dynamic>> circles = {};
  final Map<String, Map<String, dynamic>> sketches = {};
  final Map<String, Map<String, dynamic>> constraints = {};

  /// Point ids that should be rejected with a 400 if a delete is attempted -
  /// used to simulate a backend-only rejection reason (e.g. a Constraint)
  /// that the client doesn't track/check locally.
  final Set<String> blockedPointIds = {};

  String _newId(String prefix) => '$prefix-${_nextId++}';

  /// Seeds a Sketch (and its origin Point) as if it had already been
  /// created server-side - e.g. via a SketchFeature - so [adoptSketch] has
  /// something to GET without this fake backend having handled a prior
  /// `POST /sketch/sketches` itself.
  void seedSketch(String sketchId, String originPointId) {
    sketches[sketchId] = {'id': sketchId, 'plane': 'XY', 'origin_point_id': originPointId};
    points[originPointId] = {'id': originPointId, 'x': 0.0, 'y': 0.0};
  }

  http.Response handle(http.Request request) {
    final path = request.url.path;
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    final lineDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/(.+)$').firstMatch(path);
    if (lineDeleteMatch != null && request.method == 'DELETE') {
      return http.Response('', 204);
    }

    final circleDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/circles/(.+)$').firstMatch(path);
    if (circleDeleteMatch != null && request.method == 'DELETE') {
      return http.Response('', 204);
    }

    final pointDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/points/(.+)$').firstMatch(path);
    if (pointDeleteMatch != null && request.method == 'DELETE') {
      final id = pointDeleteMatch.group(1)!;
      if (blockedPointIds.contains(id)) {
        return _json({'detail': 'Point is still referenced by constraint constraint-1'}, 400);
      }
      points.remove(id);
      return http.Response('', 204);
    }

    final constraintPatchMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints/(.+)$').firstMatch(path);
    if (constraintPatchMatch != null && request.method == 'PATCH') {
      final id = constraintPatchMatch.group(1)!;
      final constraint = constraints[id];
      if (constraint == null) return http.Response('not found', 404);
      final value = (body['value'] as num).toDouble();
      if (constraint['type'] == 'angle') {
        constraint['angle_degrees'] = value;
      } else {
        constraint['distance'] = value;
      }
      return _json(_solveResultBody(), 200);
    }

    final constraintDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints/(.+)$').firstMatch(path);
    if (constraintDeleteMatch != null && request.method == 'DELETE') {
      constraints.remove(constraintDeleteMatch.group(1));
      return http.Response('', 204);
    }

    if (path == '/sketch/sketches' && request.method == 'POST') {
      // Mirror the real backend: the origin Point is a genuine Point the
      // server already knows about, so it must be GET-able too (e.g. via
      // the refresh-after-solve path), not just locally cached by the
      // client.
      points['origin-1'] = {'id': 'origin-1', 'x': 0.0, 'y': 0.0};
      return _json({'id': 'sketch-1', 'plane': body['plane'], 'origin_point_id': 'origin-1'}, 201);
    }

    final pointsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/points$').hasMatch(path);
    if (pointsCollectionMatch && request.method == 'POST') {
      final id = _newId('point');
      final point = {'id': id, 'x': body['x'], 'y': body['y']};
      points[id] = point;
      return _json(point, 201);
    }
    if (pointsCollectionMatch && request.method == 'GET') {
      return _jsonList(points.values.toList(), 200);
    }

    final pointGetMatch = RegExp(r'^/sketch/sketches/[^/]+/points/(.+)$').firstMatch(path);
    if (pointGetMatch != null && request.method == 'GET') {
      final point = points[pointGetMatch.group(1)];
      if (point == null) return http.Response('not found', 404);
      return _json(point, 200);
    }

    final sketchGetMatch = RegExp(r'^/sketch/sketches/([^/]+)$').firstMatch(path);
    if (sketchGetMatch != null && request.method == 'GET') {
      final sketch = sketches[sketchGetMatch.group(1)];
      if (sketch == null) return http.Response('not found', 404);
      return _json(sketch, 200);
    }

    final linesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/lines$').hasMatch(path);
    if (linesCollectionMatch && request.method == 'POST') {
      final id = _newId('line');
      final line = {
        'id': id,
        'start_point_id': body['start_point_id'],
        'end_point_id': body['end_point_id'],
        'length': 1.0,
        'construction': false,
      };
      lines[id] = line;
      return _json(line, 201);
    }
    if (linesCollectionMatch && request.method == 'GET') {
      return _jsonList(lines.values.toList(), 200);
    }

    final circlesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/circles$').hasMatch(path);
    if (circlesCollectionMatch && request.method == 'POST') {
      final id = _newId('circle');
      final circle = {
        'id': id,
        'center_point_id': body['center_point_id'],
        'radius_point_id': body['radius_point_id'],
        'radius': 1.0,
        'construction': false,
      };
      circles[id] = circle;
      // Mirrors the real backend's Sketch.add_circle, which auto-creates a
      // radius DistanceConstraint alongside the Circle.
      final constraintId = _newId('constraint');
      constraints[constraintId] = {
        'id': constraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': body['radius_point_id'],
        'distance': 1.0,
      };
      return _json(circle, 201);
    }
    if (circlesCollectionMatch && request.method == 'GET') {
      return _jsonList(circles.values.toList(), 200);
    }

    final constraintsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints$').hasMatch(path);
    if (constraintsCollectionMatch && request.method == 'POST') {
      final id = _newId('constraint');
      final type = body['type'] as String? ?? 'distance';
      Map<String, dynamic> constraint;
      switch (type) {
        case 'vertical':
          final line = lines[body['line_id']];
          constraint = {
            'id': id,
            'type': 'vertical',
            'line_id': body['line_id'],
            'point_a_id': line?['start_point_id'],
            'point_b_id': line?['end_point_id'],
          };
          break;
        case 'horizontal':
          final line = lines[body['line_id']];
          constraint = {
            'id': id,
            'type': 'horizontal',
            'line_id': body['line_id'],
            'point_a_id': line?['start_point_id'],
            'point_b_id': line?['end_point_id'],
          };
          break;
        case 'angle':
          constraint = {
            'id': id,
            'type': 'angle',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
            'angle_degrees': (body['angle_degrees'] as num).toDouble(),
          };
          break;
        default:
          constraint = {
            'id': id,
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': (body['distance'] as num).toDouble(),
          };
      }
      constraints[id] = constraint;
      return _json(constraint, 201);
    }
    if (constraintsCollectionMatch && request.method == 'GET') {
      return _jsonList(constraints.values.toList(), 200);
    }

    final solveMatch = RegExp(r'^/sketch/sketches/[^/]+/solve$').hasMatch(path);
    if (solveMatch && request.method == 'POST') {
      return _json(_solveResultBody(), 200);
    }

    return http.Response('not found: $path', 404);
  }

  Map<String, dynamic> _solveResultBody() => {
        'converged': true,
        'dof': 0,
        'result_code': 0,
        'blamed_constraint_ids': [],
        'solver_reported_failed_constraint_ids': [],
        'detail': 'ok',
      };

  http.Response _json(Map<String, dynamic> body, int statusCode) =>
      http.Response(jsonEncode(body), statusCode);

  http.Response _jsonList(List<Map<String, dynamic>> body, int statusCode) =>
      http.Response(jsonEncode(body), statusCode);
}

void main() {
  late _FakeBackend backend;
  late SketchController controller;

  setUp(() async {
    backend = _FakeBackend();
    final mockClient = MockClient((request) async => backend.handle(request));
    controller = SketchController(api: SketchApiClient(httpClient: mockClient));
    await controller.ensureSketch();
  });

  test('first tap in Line mode starts a chain with a single point and no line', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(1, 2);

    // 2, not 1: the Sketch's real origin Point is already present from
    // ensureSketch(), and this tap is far enough from it to create a
    // distinct new Point rather than snapping onto the origin.
    expect(controller.points.length, 2);
    expect(controller.lines.length, 0);
    expect(controller.chainInProgress, isTrue);
    expect(controller.errorMessage, isNull);
  });

  test('second tap creates a line sharing the chain start point and solves', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    final firstPointId = controller.chainFirstPointId;

    await controller.handleCanvasTap(5, 0);

    expect(controller.points.length, 2);
    expect(controller.lines.length, 1);
    expect(controller.lines.values.first.startPointId, firstPointId);
    expect(controller.currentChainStartPointId, isNot(firstPointId));
    expect(controller.errorMessage, isNull);
  });

  test('chain continues from the shared end point for a third segment', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // start point
    await controller.handleCanvasTap(5, 0); // first line
    final secondPointId = controller.currentChainStartPointId;

    await controller.handleCanvasTap(5, 5); // second line

    expect(controller.lines.length, 2);
    final secondLine = controller.lines.values.last;
    expect(secondLine.startPointId, secondPointId);
    expect(controller.points.length, 3);
  });

  test('tapping back near the chain start closes the loop using its real point id', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    final startId = controller.chainFirstPointId;

    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(5, 5);

    // Hover back close to the start point - within snapRadius.
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    expect(controller.isHoveringChainStart, isTrue);

    await controller.handleCanvasTap(0.1, 0.1);

    expect(controller.lines.length, 3);
    expect(controller.lines.values.last.endPointId, startId);
    expect(controller.chainInProgress, isFalse);
    expect(controller.points.length, 3); // no new coincident point created
  });

  test('finishChain ends the chain without closing a loop', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    expect(controller.chainInProgress, isTrue);

    controller.finishChain();

    expect(controller.chainInProgress, isFalse);
    expect(controller.points.length, 1);
    expect(controller.lines.length, 0);
  });

  test('selecting a different draw tool abandons an in-progress chain, starting clean', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // starts a line chain
    expect(controller.chainInProgress, isTrue);

    controller.selectDrawTool(SketchTool.circle);

    expect(controller.activeTool, SketchTool.circle);
    expect(controller.chainInProgress, isFalse);
  });

  test('first tap in circle tool places only a center point, no circle yet', () async {
    controller.selectDrawTool(SketchTool.circle);

    await controller.handleCanvasTap(3, 4);

    // 2, not 1: the origin Point already exists, and (3, 4) is outside its
    // snap radius, so this places a genuinely new center Point.
    expect(controller.points.length, 2);
    expect(controller.circles.length, 0);
    expect(controller.circleInProgress, isTrue);
    expect(controller.errorMessage, isNull);
  });

  test('second tap in circle tool creates the circle, solves, and ends the in-progress circle', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    final centerId = controller.circleCenterPointId;

    await controller.handleCanvasTap(5, 0);

    expect(controller.points.length, 2);
    expect(controller.circles.length, 1);
    final circle = controller.circles.values.first;
    expect(circle.centerPointId, centerId);
    expect(circle.radiusPointId, isNot(centerId));
    expect(controller.circleInProgress, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test('a third tap after a completed circle starts a fresh circle', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 0);
    expect(controller.circles.length, 1);

    await controller.handleCanvasTap(20, 20);

    expect(controller.circleInProgress, isTrue);
    expect(controller.circles.length, 1);
  });

  test('ensureSketch tracks the real backend origin Point at (0, 0)', () {
    expect(controller.originPointId, isNotNull);
    final origin = controller.points[controller.originPointId];
    expect(origin, isNotNull);
    expect(origin!.x, 0);
    expect(origin.y, 0);
  });

  test('ensureSketch also exposes the Sketch\'s plane', () {
    expect(controller.plane, 'XY');
  });

  test('tapping within the snap radius of the origin lands exactly on its real point id', () async {
    controller.selectDrawTool(SketchTool.line);

    await controller.handleCanvasTap(0.1, 0.1);

    expect(controller.chainFirstPointId, controller.originPointId);
    expect(controller.points.length, 1); // reused the origin - no new coincident point
    expect(controller.errorMessage, isNull);
  });

  test('a line cannot snap both ends onto the origin - the second tap still places a new point', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // chain starts at the origin
    final startId = controller.chainFirstPointId;
    expect(startId, controller.originPointId);

    // Still hovering the origin for the second tap of the same segment.
    await controller.handleCanvasTap(0, 0);

    expect(controller.lines.length, 1);
    final line = controller.lines.values.first;
    expect(line.startPointId, startId);
    expect(line.endPointId, isNot(startId)); // excluded - falls back to a new Point
    expect(controller.errorMessage, isNull);
  });

  test('a circle cannot snap both center and radius onto the origin', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // center snaps to the origin
    expect(controller.circleCenterPointId, controller.originPointId);

    // Still hovering the origin for the radius tap.
    await controller.handleCanvasTap(0, 0);

    expect(controller.circles.length, 1);
    final circle = controller.circles.values.first;
    expect(circle.centerPointId, controller.originPointId);
    expect(circle.radiusPointId, isNot(controller.originPointId));
    expect(controller.errorMessage, isNull);
  });

  test('moveCursorRelative sensitivity scales inversely with zoom', () {
    controller.cursorX = 0;
    controller.cursorY = 0;
    controller.moveCursorRelative(100, 0, 1);
    final atDefaultZoom = controller.cursorX;

    controller.cursorX = 0;
    controller.moveCursorRelative(100, 0, 2);
    final atDoubleZoom = controller.cursorX;

    controller.cursorX = 0;
    controller.moveCursorRelative(100, 0, 0.5);
    final atHalfZoom = controller.cursorX;

    // Zoomed in (zoom 2): same drag covers less sketch-space.
    expect(atDoubleZoom, closeTo(atDefaultZoom / 2, 1e-9));
    // Zoomed out (zoom 0.5): same drag covers more sketch-space.
    expect(atHalfZoom, closeTo(atDefaultZoom * 2, 1e-9));
  });

  test('hitRadiusForPixelsPerUnit grows the hit radius for small/zoomed-out geometry', () {
    final farZoomedOut = controller.hitRadiusForPixelsPerUnit(10);
    final zoomedIn = controller.hitRadiusForPixelsPerUnit(100);

    expect(farZoomedOut, greaterThan(zoomedIn));
    expect(zoomedIn, greaterThanOrEqualTo(SketchController.snapRadius));
  });

  test('a failed request surfaces a visible error message, not a silent failure', () async {
    final failingClient = MockClient((request) async => http.Response('boom', 500));
    final failingController = SketchController(api: SketchApiClient(httpClient: failingClient));

    await failingController.ensureSketch();

    expect(failingController.sketchId, isNull);
    expect(failingController.errorMessage, isNotNull);
    expect(failingController.busy, isFalse);
  });

  // --- Stage 6: hover, selection, ribbon, delete ----------------------------

  test('hoveredEntity is null while a chain is in progress, even right on top of an entity', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // starts a chain at the origin

    expect(controller.chainInProgress, isTrue);
    expect(controller.hoveredEntity, isNull);
  });

  test('hoveredEntity is null in draw mode even when idle', () {
    controller.selectDrawTool(SketchTool.line);
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    expect(controller.hoveredEntity, isNull);
  });

  test('hoveredEntity detects a nearby Point while idle in select mode', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    final hovered = controller.hoveredEntity;
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.point);
    expect(hovered.id, controller.originPointId);
  });

  test('hoveredEntity detects a nearby Line while idle in select mode', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // chain start, snaps to the origin
    await controller.handleCanvasTap(5, 0); // creates the line
    controller.finishChain();
    controller.exitToSelectMode();
    final lineId = controller.lines.keys.first;

    // Midpoint of the line, just off-axis - not within snap radius of
    // either endpoint Point.
    controller.cursorX = 2.5;
    controller.cursorY = 0.1;

    final hovered = controller.hoveredEntity;
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.line);
    expect(hovered.id, lineId);
  });

  test('hoveredEntity detects a nearby Circle edge while idle in select mode', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // center snaps to the origin
    await controller.handleCanvasTap(5, 0); // radius point, creates the circle
    controller.exitToSelectMode();
    final circleId = controller.circles.keys.first;

    // On the circle's edge (radius 5, centered on the origin) but not near
    // either of its two real Points.
    controller.cursorX = 0;
    controller.cursorY = 5;

    final hovered = controller.hoveredEntity;
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.circle);
    expect(hovered.id, circleId);
  });

  test('handleCanvasTap selects the hovered entity and opens the ribbon while idle', () async {
    await controller.handleCanvasTap(0.1, 0.1);

    expect(controller.selection, isNotNull);
    expect(controller.selection!.kind, SelectionKind.point);
    expect(controller.selection!.id, controller.originPointId);
    expect(controller.ribbonVisible, isTrue);
  });

  test('handleCanvasTap on blank space opens the idle ribbon panel when it was closed', () async {
    expect(controller.ribbonVisible, isFalse);

    await controller.handleCanvasTap(50, 50);

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isTrue);
  });

  test('handleCanvasTap on blank space dismisses the ribbon when it is already open', () async {
    await controller.handleCanvasTap(0.1, 0.1);
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    await controller.handleCanvasTap(50, 50);

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('a second tap on a different entity while the ribbon is open adds to the selection set', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final lineId = controller.lines.keys.first;

    await controller.handleCanvasTap(0, 0); // selects the origin point
    expect(controller.selectionSet.length, 1);

    // Away from the line's midpoint (2.5, 0) - a tap there now snaps to/
    // materializes the midpoint Point instead of selecting the Line itself.
    await controller.handleCanvasTap(4, 0.1); // adds the line
    expect(controller.selectionSet.length, 2);
    expect(
      controller.selectionSet.any((s) => s.kind == SelectionKind.line && s.id == lineId),
      isTrue,
    );
  });

  test('closeRibbon clears the selection and hides the ribbon', () async {
    await controller.handleCanvasTap(0.1, 0.1);
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    controller.closeRibbon();

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('selecting a draw tool hides the ribbon, clears any selection, and the next tap starts a chain', () async {
    await controller.handleCanvasTap(0.1, 0.1);
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    controller.selectDrawTool(SketchTool.line);
    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);

    await controller.handleCanvasTap(0, 0);

    expect(controller.chainInProgress, isTrue);
    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('selectedPointDeleteBlockedReason flags the origin point', () async {
    await controller.handleCanvasTap(0, 0);

    expect(controller.selection!.id, controller.originPointId);
    expect(controller.selectedPointDeleteBlockedReason, isNotNull);
  });

  test('selectedPointDeleteBlockedReason flags a point referenced by a line', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(10, 10);
    final startId = controller.chainFirstPointId;
    await controller.handleCanvasTap(15, 10);
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(10, 10);

    expect(controller.selection!.id, startId);
    expect(controller.selectedPointDeleteBlockedReason, contains('line'));
  });

  test('selectedPointDeleteBlockedReason flags a point referenced by a circle', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(10, 10);
    final centerId = controller.circleCenterPointId;
    await controller.handleCanvasTap(15, 10);
    controller.exitToSelectMode();

    await controller.handleCanvasTap(10, 10);

    expect(controller.selection!.id, centerId);
    expect(controller.selectedPointDeleteBlockedReason, contains('circle'));
  });

  test('selectedPointDeleteBlockedReason is null for a genuinely unreferenced point', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(20, 20); // chain start only - no Line created yet
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(20, 20);

    expect(controller.selection, isNotNull);
    expect(controller.selectedPointDeleteBlockedReason, isNull);
  });

  test('deleteSelected removes a selected line and clears the selection', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final lineId = controller.lines.keys.first;

    // Away from the line's midpoint (2.5, 0) - see the selection-set test
    // above for why.
    await controller.handleCanvasTap(4, 0.1);
    expect(controller.selection!.id, lineId);

    await controller.deleteSelected();

    expect(controller.lines.containsKey(lineId), isFalse);
    expect(controller.selection, isNull);
    expect(controller.errorMessage, isNull);
  });

  test('deleteSelected removes a genuinely unreferenced point and clears the selection', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(20, 20);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.points.keys.last;

    await controller.handleCanvasTap(20, 20);
    expect(controller.selection!.id, pointId);

    await controller.deleteSelected();

    expect(controller.points.containsKey(pointId), isFalse);
    expect(controller.selection, isNull);
    expect(controller.errorMessage, isNull);
  });

  test('deleteSelected surfaces a backend rejection reason and keeps the selection', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(20, 20);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.points.keys.last;
    backend.blockedPointIds.add(pointId);

    await controller.handleCanvasTap(20, 20);
    expect(controller.selection!.id, pointId);
    expect(controller.selectedPointDeleteBlockedReason, isNull); // not locally tracked

    await controller.deleteSelected();

    expect(controller.points.containsKey(pointId), isTrue);
    expect(controller.selection, isNotNull);
    expect(controller.selection!.id, pointId);
    expect(controller.errorMessage, contains('constraint'));
  });

  test('adoptSketch loads an existing Sketch instead of creating a new one', () async {
    // A fresh controller, not the shared one from setUp - that one has
    // already called ensureSketch(), and adoptSketch() is a no-op once a
    // Sketch is already adopted.
    final freshBackend = _FakeBackend();
    freshBackend.seedSketch('sketch-99', 'origin-99');
    final mockClient = MockClient((request) async => freshBackend.handle(request));
    final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));

    await freshController.adoptSketch('sketch-99');

    expect(freshController.points.keys, ['origin-99']);
    expect(freshController.points['origin-99']!.x, 0);
    expect(freshController.points['origin-99']!.y, 0);
    expect(freshController.errorMessage, isNull);
  });

  test('adoptSketch loads an existing Sketch\'s Points, Lines, and Circles, not just its origin', () async {
    final freshBackend = _FakeBackend();
    freshBackend.seedSketch('sketch-100', 'origin-100');
    freshBackend.points['point-a'] = {'id': 'point-a', 'x': 3.0, 'y': 4.0};
    freshBackend.points['point-b'] = {'id': 'point-b', 'x': 6.0, 'y': 4.0};
    freshBackend.lines['line-a'] = {
      'id': 'line-a',
      'start_point_id': 'point-a',
      'end_point_id': 'point-b',
      'length': 3.0,
      'construction': false,
    };
    freshBackend.circles['circle-a'] = {
      'id': 'circle-a',
      'center_point_id': 'point-a',
      'radius_point_id': 'point-b',
      'radius': 5.0,
      'construction': false,
    };
    final mockClient = MockClient((request) async => freshBackend.handle(request));
    final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));

    await freshController.adoptSketch('sketch-100');

    expect(freshController.points.keys, containsAll(['origin-100', 'point-a', 'point-b']));
    expect(freshController.lines.keys, contains('line-a'));
    expect(freshController.lines['line-a']!.startPointId, 'point-a');
    expect(freshController.lines['line-a']!.endPointId, 'point-b');
    expect(freshController.circles.keys, contains('circle-a'));
    expect(freshController.circles['circle-a']!.centerPointId, 'point-a');
    expect(freshController.circles['circle-a']!.radiusPointId, 'point-b');
    expect(freshController.errorMessage, isNull);
  });

  // --- Stage 13 item 4: FAB categories --------------------------------------

  test('the FAB menu opens to categories, expands into Sketch Entities, and can go back', () {
    expect(controller.fabMenu, FabMenuState.closed);

    controller.openFabMenu();
    expect(controller.fabMenu, FabMenuState.categories);

    controller.showSketchEntitiesCategory();
    expect(controller.fabMenu, FabMenuState.sketchEntities);

    controller.backToFabCategories();
    expect(controller.fabMenu, FabMenuState.categories);

    controller.closeFabMenu();
    expect(controller.fabMenu, FabMenuState.closed);
  });

  test('selectDrawTool enters draw mode, sets the active tool, and closes the FAB', () {
    controller.openFabMenu();
    controller.showSketchEntitiesCategory();

    controller.selectDrawTool(SketchTool.circle);

    expect(controller.mode, SketchMode.draw);
    expect(controller.activeTool, SketchTool.circle);
    expect(controller.fabMenu, FabMenuState.closed);
  });

  test('enterDimensionMode enters dimension mode, closes the FAB, and updates the mode label', () {
    controller.openFabMenu();

    controller.enterDimensionMode();

    expect(controller.mode, SketchMode.dimension);
    expect(controller.fabMenu, FabMenuState.closed);
    expect(controller.modeLabel, 'Dimension');
  });

  test('exitToSelectMode returns to select mode and discards any dimension pick', () async {
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0.1, 0.1); // picks the origin point - no ghost yet

    controller.exitToSelectMode();

    expect(controller.mode, SketchMode.select);
    expect(controller.dimensionSelection, isEmpty);
    expect(controller.ghosts, isEmpty);
  });

  // --- Stage 13 item 6: Vertical/Horizontal constraint UX -------------------

  test('availableConstraintOptions offers wired Vertical/Horizontal for a single selected line', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();

    // Away from the line's midpoint (2.5, 2.5) - a tap there now snaps to/
    // materializes the midpoint Point instead of selecting the Line itself.
    await controller.handleCanvasTap(4, 4);

    final options = controller.availableConstraintOptions;
    expect(
      options.map((o) => o.type),
      containsAll([ConstraintOptionType.vertical, ConstraintOptionType.horizontal]),
    );
    expect(options.every((o) => o.wired), isTrue);
  });

  test('availableConstraintOptions is empty for a single selected point', () async {
    await controller.handleCanvasTap(0, 0); // selects the origin point

    expect(controller.availableConstraintOptions, isEmpty);
  });

  test('applyConstraintOption(vertical) creates a VerticalConstraint and re-solves', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(4, 4); // away from the line's midpoint

    await controller.applyConstraintOption(ConstraintOptionType.vertical);

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<VerticalConstraintDto>(), isNotEmpty);
  });

  test('applyConstraintOption(horizontal) creates a HorizontalConstraint and re-solves', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(4, 4); // away from the line's midpoint

    await controller.applyConstraintOption(ConstraintOptionType.horizontal);

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<HorizontalConstraintDto>(), isNotEmpty);
  });

  // --- Stage 13 item 5: Dimension mode + ghost dimensions -------------------

  test('tapping a line in dimension mode shows a single length ghost', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();

    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)

    expect(controller.ghosts.length, 1);
    expect(controller.ghosts.first.kind, GhostKind.length);
  });

  test('confirmGhostValue on a fresh line-length ghost creates a DistanceConstraint and clears ghosts', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)
    controller.tapGhost('length');
    expect(controller.activeGhostKey, 'length');

    await controller.confirmGhostValue('length', 25.0);

    expect(controller.errorMessage, isNull);
    expect(controller.ghosts, isEmpty);
    expect(controller.activeGhostKey, isNull);
    expect(
      controller.constraints.values
          .whereType<DistanceConstraintDto>()
          .any((c) => c.distance == 25.0),
      isTrue,
    );
  });

  test('cancelGhostEdit clears the active ghost without dismissing the ghosts themselves', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)
    controller.tapGhost('length');

    controller.cancelGhostEdit();

    expect(controller.activeGhostKey, isNull);
    expect(controller.ghosts, isNotEmpty);
  });

  test('tapping two distinct points in dimension mode shows simultaneous V, H, and linear ghosts', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();

    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);

    expect(controller.ghosts.map((g) => g.key).toSet(), {'v', 'h', 'linear'});
  });

  test(
      'tapping a circle in dimension mode shows radius and diameter ghosts; '
      'confirming diameter halves the stored distance', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // radius point -> radius 10
    controller.enterDimensionMode();

    await controller.handleCanvasTap(0, 10); // on the circle's edge

    expect(controller.ghosts.map((g) => g.key).toSet(), {'radius', 'diameter'});

    await controller.confirmGhostValue('diameter', 40.0);

    expect(controller.errorMessage, isNull);
    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>();
    expect(distanceConstraints.single.distance, 20.0); // halved from the 40.0 diameter entered
  });

  test('tapping empty canvas with nothing picked in dimension mode exits to select mode', () async {
    controller.enterDimensionMode();

    await controller.handleCanvasTap(50, 50);

    expect(controller.mode, SketchMode.select);
  });

  test('tapping empty canvas after a pick in dimension mode clears the pick but stays in dimension mode', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)
    expect(controller.ghosts, isNotEmpty);

    await controller.handleCanvasTap(50, 50);

    expect(controller.mode, SketchMode.dimension);
    expect(controller.ghosts, isEmpty);
  });

  // --- New work package item 1: Point tool ----------------------------------

  test('the point tool places a single Point and self-terminates (no chain)', () async {
    controller.selectDrawTool(SketchTool.point);

    await controller.handleCanvasTap(3, 4);

    expect(controller.points.length, 2); // origin + the new point
    expect(controller.points.values.any((p) => p.x == 3 && p.y == 4), isTrue);
    expect(controller.chainInProgress, isFalse);
    expect(controller.circleInProgress, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test('the point tool snaps onto an existing Point instead of creating a duplicate', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 4);
    expect(controller.points.length, 2);

    await controller.handleCanvasTap(3.1, 4.1); // within snapRadius of the point just placed

    expect(controller.points.length, 2); // no new point created
  });

  // --- New work package item 5: line-midpoint snapping ----------------------

  test('a draw-mode tap near a Line\'s midpoint reuses the materialized midpoint Point', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();

    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(5.1, 0.1); // within snapRadius of the line's midpoint (5, 0)

    expect(controller.points.length, 3); // origin + 2 line endpoints + midpoint, no extra
  });

  // --- New work package items 3 & 4: constraint selection/delete/edit -------

  test('selectConstraint selects a Constraint by id and opens the ribbon', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(4, 4); // selects the line, away from its midpoint
    await controller.applyConstraintOption(ConstraintOptionType.vertical);
    final constraintId = controller.constraints.keys.single;

    controller.selectConstraint(constraintId);

    expect(controller.selectionSet.length, 1);
    expect(controller.selectionSet.first.kind, SelectionKind.constraint);
    expect(controller.selectionSet.first.id, constraintId);
  });

  test('deleteSelected removes a selected Constraint and re-solves', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(4, 4);
    await controller.applyConstraintOption(ConstraintOptionType.vertical);
    final constraintId = controller.constraints.keys.single;
    controller.selectConstraint(constraintId);

    await controller.deleteSelected();

    expect(controller.constraints, isEmpty);
    expect(controller.selectionSet, isEmpty);
    expect(controller.errorMessage, isNull);
  });

  test('selectedConstraintValue/selectedConstraintHasValue are null/false for a Vertical constraint', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(4, 4);
    await controller.applyConstraintOption(ConstraintOptionType.vertical);
    controller.selectConstraint(controller.constraints.keys.single);

    expect(controller.selectedConstraintValue, isNull);
    expect(controller.selectedConstraintHasValue, isFalse);
    expect(controller.selectedConstraintIsAngle, isFalse);
  });

  test(
      'selectedConstraintValue exposes a Distance constraint\'s value, and '
      'updateSelectedConstraintValue PATCHes it then deselects', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint
    await controller.confirmGhostValue('length', 25.0);
    controller.exitToSelectMode();
    final constraintId = controller.constraints.keys.single;
    controller.selectConstraint(constraintId);

    expect(controller.selectedConstraintValue, 25.0);
    expect(controller.selectedConstraintHasValue, isTrue);
    expect(controller.selectedConstraintIsAngle, isFalse);

    await controller.updateSelectedConstraintValue(50.0);

    expect(controller.errorMessage, isNull);
    expect(controller.constraints[constraintId], isA<DistanceConstraintDto>());
    expect((controller.constraints[constraintId] as DistanceConstraintDto).distance, 50.0);
    expect(controller.selectionSet, isEmpty);
  });

  // --- New work package item 6: line-pair ghosts (lineDistance/angle) -------

  test('two parallel Lines selected in dimension mode show a lineDistance ghost', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(10, 5);
    controller.finishChain();
    controller.enterDimensionMode();

    await controller.handleCanvasTap(8, 0.1); // first line, away from its midpoint
    await controller.handleCanvasTap(8, 5.1); // second line, away from its midpoint

    expect(controller.ghosts.map((g) => g.key).toSet(), {'lineDistance'});
    expect(controller.ghosts.single.kind, GhostKind.lineDistance);
    expect(controller.currentGhostValue(controller.ghosts.single), closeTo(5.0, 1e-9));
  });

  test(
      'confirming a lineDistance ghost materializes both midpoints and creates a '
      'DistanceConstraint between them', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(10, 5);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(8, 5.1);

    await controller.confirmGhostValue('lineDistance', 7.0);

    expect(controller.errorMessage, isNull);
    expect(controller.ghosts, isEmpty);
    expect(
      controller.constraints.values.whereType<DistanceConstraintDto>().any((c) => c.distance == 7.0),
      isTrue,
    );
  });

  test('two non-parallel Lines selected in dimension mode show an angle ghost', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    controller.enterDimensionMode();

    await controller.handleCanvasTap(8, 0.1); // horizontal line, away from its midpoint
    await controller.handleCanvasTap(0.1, 8); // vertical line, away from its midpoint

    expect(controller.ghosts.map((g) => g.key).toSet(), {'angle'});
    expect(controller.ghosts.single.kind, GhostKind.angle);
    expect(controller.currentGhostValue(controller.ghosts.single), closeTo(90.0, 1e-6));
  });

  test('confirming an angle ghost creates an AngleConstraint between the two Lines', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(0.1, 8);

    await controller.confirmGhostValue('angle', 90.0);

    expect(controller.errorMessage, isNull);
    expect(controller.ghosts, isEmpty);
    expect(controller.dimensionSelection, isEmpty);
    final angleConstraints = controller.constraints.values.whereType<AngleConstraintDto>();
    expect(angleConstraints.single.angleDegrees, 90.0);
  });

  test(
      'confirming an existing angle ghost a second time PATCHes the existing '
      'AngleConstraint instead of creating a second one', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(0.1, 8);
    await controller.confirmGhostValue('angle', 90.0);

    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(0.1, 8);
    await controller.confirmGhostValue('angle', 45.0);

    expect(controller.errorMessage, isNull);
    final angleConstraints = controller.constraints.values.whereType<AngleConstraintDto>();
    expect(angleConstraints.length, 1);
    expect(angleConstraints.single.angleDegrees, 45.0);
  });

  // --- New work package item 6: point+line ghost substitution ---------------

  test(
      'selecting a Point and a Line in dimension mode substitutes the Line\'s '
      'nearer endpoint for point-distance ghosts', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();

    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 5); // a free-standing point above the line's start

    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 5); // the point
    await controller.handleCanvasTap(8, 0.1); // the line, away from its midpoint (nearer to its end)

    expect(controller.ghosts.map((g) => g.key).toSet(), {'v', 'h', 'linear'});
    // The line's start point (0, 0) is nearer to (0, 5) than its end point
    // (10, 0) is - distance 5 vs sqrt(125) - so the ghost set is built
    // against the start point, giving a linear distance of 5.
    final linearGhost = controller.ghosts.firstWhere((g) => g.key == 'linear');
    expect(controller.currentGhostValue(linearGhost), closeTo(5.0, 1e-9));
  });
}
