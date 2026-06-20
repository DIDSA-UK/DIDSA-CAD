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

  String _newId(String prefix) => '$prefix-${_nextId++}';

  http.Response handle(http.Request request) {
    final path = request.url.path;
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    if (path == '/sketch/sketches' && request.method == 'POST') {
      return _json({'id': 'sketch-1', 'plane': body['plane']}, 201);
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

    expect(controller.points.length, 1);
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

    expect(controller.points.length, 1);
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

  test('a failed request surfaces a visible error message, not a silent failure', () async {
    final failingClient = MockClient((request) async => http.Response('boom', 500));
    final failingController = SketchController(api: SketchApiClient(httpClient: failingClient));

    await failingController.ensureSketch();

    expect(failingController.sketchId, isNull);
    expect(failingController.errorMessage, isNotNull);
    expect(failingController.busy, isFalse);
  });
}
