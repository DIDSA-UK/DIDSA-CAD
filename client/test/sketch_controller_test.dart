import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// A tiny in-memory fake of the backend's `/sketch` API (point/line
/// creation, get, solve) good enough to exercise the controller's chaining
/// logic without any real network call.
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};

  /// Point ids that should be rejected with a 400 if a delete is attempted -
  /// used to simulate a backend-only rejection reason (e.g. a Constraint)
  /// that the client doesn't track/check locally.
  final Set<String> blockedPointIds = {};

  String _newId(String prefix) => '$prefix-${_nextId++}';

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

    if (path == '/sketch/sketches' && request.method == 'POST') {
      // Mirror the real backend: the origin Point is a genuine Point the
      // server already knows about, so it must be GET-able too (e.g. via
      // the refresh-after-solve path), not just locally cached by the
      // client.
      points['origin-1'] = {'id': 'origin-1', 'x': 0.0, 'y': 0.0};
      return _json({'id': 'sketch-1', 'plane': body['plane'], 'origin_point_id': 'origin-1'}, 201);
    }

    final pointsMatch = RegExp(r'^/sketch/sketches/[^/]+/points$').hasMatch(path);
    if (pointsMatch && request.method == 'POST') {
      final id = _newId('point');
      final point = {'id': id, 'x': body['x'], 'y': body['y']};
      points[id] = point;
      return _json(point, 201);
    }

    final pointGetMatch = RegExp(r'^/sketch/sketches/[^/]+/points/(.+)$').firstMatch(path);
    if (pointGetMatch != null && request.method == 'GET') {
      final point = points[pointGetMatch.group(1)];
      if (point == null) return http.Response('not found', 404);
      return _json(point, 200);
    }

    final linesMatch = RegExp(r'^/sketch/sketches/[^/]+/lines$').hasMatch(path);
    if (linesMatch && request.method == 'POST') {
      return _json({
        'id': _newId('line'),
        'start_point_id': body['start_point_id'],
        'end_point_id': body['end_point_id'],
        'length': 1.0,
      }, 201);
    }

    final circlesMatch = RegExp(r'^/sketch/sketches/[^/]+/circles$').hasMatch(path);
    if (circlesMatch && request.method == 'POST') {
      return _json({
        'id': _newId('circle'),
        'center_point_id': body['center_point_id'],
        'radius_point_id': body['radius_point_id'],
        'radius': 1.0,
      }, 201);
    }

    final solveMatch = RegExp(r'^/sketch/sketches/[^/]+/solve$').hasMatch(path);
    if (solveMatch && request.method == 'POST') {
      return _json({
        'converged': true,
        'dof': 0,
        'result_code': 0,
        'blamed_constraint_ids': [],
        'solver_reported_failed_constraint_ids': [],
        'detail': 'ok',
      }, 200);
    }

    return http.Response('not found: $path', 404);
  }

  http.Response _json(Map<String, dynamic> body, int statusCode) =>
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

  test('first click starts a chain with a single point and no line', () async {
    controller.cursorX = 1;
    controller.cursorY = 2;
    await controller.click();

    // 2, not 1: the Sketch's real origin Point is already present from
    // ensureSketch(), and this click is far enough from it to create a
    // distinct new Point rather than snapping onto the origin.
    expect(controller.points.length, 2);
    expect(controller.lines.length, 0);
    expect(controller.chainInProgress, isTrue);
    expect(controller.errorMessage, isNull);
  });

  test('second click creates a line sharing the chain start point and solves', () async {
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click();
    final firstPointId = controller.chainFirstPointId;

    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click();

    expect(controller.points.length, 2);
    expect(controller.lines.length, 1);
    expect(controller.lines.values.first.startPointId, firstPointId);
    expect(controller.currentChainStartPointId, isNot(firstPointId));
    expect(controller.errorMessage, isNull);
  });

  test('chain continues from the shared end point for a third segment', () async {
    await controller.click(); // start point
    controller.cursorX = 5;
    await controller.click(); // first line
    final secondPointId = controller.currentChainStartPointId;

    controller.cursorX = 5;
    controller.cursorY = 5;
    await controller.click(); // second line

    expect(controller.lines.length, 2);
    final secondLine = controller.lines.values.last;
    expect(secondLine.startPointId, secondPointId);
    expect(controller.points.length, 3);
  });

  test('clicking back near the chain start closes the loop using its real point id', () async {
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click();
    final startId = controller.chainFirstPointId;

    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click();

    controller.cursorX = 5;
    controller.cursorY = 5;
    await controller.click();

    // Hover back close to the start point - within snapRadius.
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    expect(controller.isHoveringChainStart, isTrue);

    await controller.click();

    expect(controller.lines.length, 3);
    expect(controller.lines.values.last.endPointId, startId);
    expect(controller.chainInProgress, isFalse);
    expect(controller.points.length, 3); // no new coincident point created
  });

  test('finishChain ends the chain without closing a loop', () async {
    await controller.click();
    expect(controller.chainInProgress, isTrue);

    controller.finishChain();

    expect(controller.chainInProgress, isFalse);
    expect(controller.points.length, 1);
    expect(controller.lines.length, 0);
  });

  test('selecting the circle tool does not disturb an in-progress line chain state', () async {
    await controller.click(); // starts a line chain
    expect(controller.chainInProgress, isTrue);

    controller.setTool(SketchTool.circle);

    expect(controller.activeTool, SketchTool.circle);
    expect(controller.chainInProgress, isTrue);
  });

  test('first click in circle tool places only a center point, no circle yet', () async {
    controller.setTool(SketchTool.circle);
    controller.cursorX = 3;
    controller.cursorY = 4;

    await controller.click();

    // 2, not 1: the origin Point already exists, and (3, 4) is outside its
    // snap radius, so this places a genuinely new center Point.
    expect(controller.points.length, 2);
    expect(controller.circles.length, 0);
    expect(controller.circleInProgress, isTrue);
    expect(controller.errorMessage, isNull);
  });

  test('second click in circle tool creates the circle, solves, and ends the in-progress circle', () async {
    controller.setTool(SketchTool.circle);
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click();
    final centerId = controller.circleCenterPointId;

    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click();

    expect(controller.points.length, 2);
    expect(controller.circles.length, 1);
    final circle = controller.circles.values.first;
    expect(circle.centerPointId, centerId);
    expect(circle.radiusPointId, isNot(centerId));
    expect(controller.circleInProgress, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test('a third click after a completed circle starts a fresh circle', () async {
    controller.setTool(SketchTool.circle);
    await controller.click();
    await controller.click();
    expect(controller.circles.length, 1);

    controller.cursorX = 20;
    controller.cursorY = 20;
    await controller.click();

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

  test('clicking within the snap radius of the origin lands exactly on its real point id', () async {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    await controller.click();

    expect(controller.chainFirstPointId, controller.originPointId);
    expect(controller.points.length, 1); // reused the origin - no new coincident point
    expect(controller.errorMessage, isNull);
  });

  test('a line cannot snap both ends onto the origin - the second click still places a new point', () async {
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click(); // chain starts at the origin
    final startId = controller.chainFirstPointId;
    expect(startId, controller.originPointId);

    // Still hovering the origin for the second click of the same segment.
    await controller.click();

    expect(controller.lines.length, 1);
    final line = controller.lines.values.first;
    expect(line.startPointId, startId);
    expect(line.endPointId, isNot(startId)); // excluded - falls back to a new Point
    expect(controller.errorMessage, isNull);
  });

  test('a circle cannot snap both center and radius onto the origin', () async {
    controller.setTool(SketchTool.circle);
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click(); // center snaps to the origin
    expect(controller.circleCenterPointId, controller.originPointId);

    // Still hovering the origin for the radius click.
    await controller.click();

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
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click(); // starts a chain at the origin

    expect(controller.chainInProgress, isTrue);
    expect(controller.hoveredEntity, isNull);
  });

  test('hoveredEntity detects a nearby Point while idle', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    final hovered = controller.hoveredEntity;
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.point);
    expect(hovered.id, controller.originPointId);
  });

  test('hoveredEntity detects a nearby Line while idle', () async {
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click(); // chain start, snaps to the origin
    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click(); // creates the line
    controller.finishChain();
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

  test('hoveredEntity detects a nearby Circle edge while idle', () async {
    controller.setTool(SketchTool.circle);
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click(); // center snaps to the origin
    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click(); // radius point, creates the circle
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

  test('handleCanvasTap is a no-op while a chain is in progress', () async {
    await controller.click(); // starts a chain
    expect(controller.chainInProgress, isTrue);

    controller.handleCanvasTap();

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('handleCanvasTap selects the hovered entity and opens the ribbon while idle', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    controller.handleCanvasTap();

    expect(controller.selection, isNotNull);
    expect(controller.selection!.kind, SelectionKind.point);
    expect(controller.selection!.id, controller.originPointId);
    expect(controller.ribbonVisible, isTrue);
  });

  test('handleCanvasTap on blank space opens the idle ribbon panel when it was closed', () {
    controller.cursorX = 50;
    controller.cursorY = 50;
    expect(controller.ribbonVisible, isFalse);

    controller.handleCanvasTap();

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isTrue);
  });

  test('handleCanvasTap on blank space dismisses the ribbon when it is already open', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    controller.handleCanvasTap();
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    controller.cursorX = 50;
    controller.cursorY = 50;
    controller.handleCanvasTap();

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('closeRibbon clears the selection and hides the ribbon', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    controller.handleCanvasTap();
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    controller.closeRibbon();

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('starting a new chain via click hides the ribbon and clears any selection', () async {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    controller.handleCanvasTap();
    expect(controller.selection, isNotNull);
    expect(controller.ribbonVisible, isTrue);

    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click();

    expect(controller.chainInProgress, isTrue);
    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
  });

  test('selectedPointDeleteBlockedReason flags the origin point', () {
    controller.cursorX = 0;
    controller.cursorY = 0;
    controller.handleCanvasTap();

    expect(controller.selection!.id, controller.originPointId);
    expect(controller.selectedPointDeleteBlockedReason, isNotNull);
  });

  test('selectedPointDeleteBlockedReason flags a point referenced by a line', () async {
    controller.cursorX = 10;
    controller.cursorY = 10;
    await controller.click();
    final startId = controller.chainFirstPointId;
    controller.cursorX = 15;
    controller.cursorY = 10;
    await controller.click();
    controller.finishChain();

    controller.cursorX = 10;
    controller.cursorY = 10;
    controller.handleCanvasTap();

    expect(controller.selection!.id, startId);
    expect(controller.selectedPointDeleteBlockedReason, contains('line'));
  });

  test('selectedPointDeleteBlockedReason flags a point referenced by a circle', () async {
    controller.setTool(SketchTool.circle);
    controller.cursorX = 10;
    controller.cursorY = 10;
    await controller.click();
    final centerId = controller.circleCenterPointId;
    controller.cursorX = 15;
    controller.cursorY = 10;
    await controller.click();

    controller.cursorX = 10;
    controller.cursorY = 10;
    controller.handleCanvasTap();

    expect(controller.selection!.id, centerId);
    expect(controller.selectedPointDeleteBlockedReason, contains('circle'));
  });

  test('selectedPointDeleteBlockedReason is null for a genuinely unreferenced point', () async {
    controller.cursorX = 20;
    controller.cursorY = 20;
    await controller.click(); // chain start only - no Line created yet
    controller.finishChain();

    controller.cursorX = 20;
    controller.cursorY = 20;
    controller.handleCanvasTap();

    expect(controller.selection, isNotNull);
    expect(controller.selectedPointDeleteBlockedReason, isNull);
  });

  test('deleteSelected removes a selected line and clears the selection', () async {
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.click();
    controller.cursorX = 5;
    controller.cursorY = 0;
    await controller.click();
    controller.finishChain();
    final lineId = controller.lines.keys.first;

    controller.cursorX = 2.5;
    controller.cursorY = 0.1;
    controller.handleCanvasTap();
    expect(controller.selection!.id, lineId);

    await controller.deleteSelected();

    expect(controller.lines.containsKey(lineId), isFalse);
    expect(controller.selection, isNull);
    expect(controller.errorMessage, isNull);
  });

  test('deleteSelected removes a genuinely unreferenced point and clears the selection', () async {
    controller.cursorX = 20;
    controller.cursorY = 20;
    await controller.click();
    controller.finishChain();
    final pointId = controller.points.keys.last;

    controller.cursorX = 20;
    controller.cursorY = 20;
    controller.handleCanvasTap();
    expect(controller.selection!.id, pointId);

    await controller.deleteSelected();

    expect(controller.points.containsKey(pointId), isFalse);
    expect(controller.selection, isNull);
    expect(controller.errorMessage, isNull);
  });

  test('deleteSelected surfaces a backend rejection reason and keeps the selection', () async {
    controller.cursorX = 20;
    controller.cursorY = 20;
    await controller.click();
    controller.finishChain();
    final pointId = controller.points.keys.last;
    backend.blockedPointIds.add(pointId);

    controller.cursorX = 20;
    controller.cursorY = 20;
    controller.handleCanvasTap();
    expect(controller.selection!.id, pointId);
    expect(controller.selectedPointDeleteBlockedReason, isNull); // not locally tracked

    await controller.deleteSelected();

    expect(controller.points.containsKey(pointId), isTrue);
    expect(controller.selection, isNotNull);
    expect(controller.selection!.id, pointId);
    expect(controller.errorMessage, contains('constraint'));
  });
}
