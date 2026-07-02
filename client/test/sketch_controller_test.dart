import 'dart:convert';

import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart' show dimensionLabelAt;
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/view_transform.dart';

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

  /// Every request `handle` has seen so far, as `"METHOD path"` - lets a test
  /// assert a controller call issued *no* HTTP request at all (e.g.
  /// [SketchController.beginPointDrag], which must only record local drag
  /// state - see Stage 16 item 5) without needing a full mock-verify library.
  final List<String> requestLog = [];

  /// Point ids that should be rejected with a 400 if a delete is attempted -
  /// used to simulate a backend-only rejection reason (e.g. a Constraint)
  /// that the client doesn't track/check locally.
  final Set<String> blockedPointIds = {};

  /// The `dof` every solve response reports - new work package item 8's
  /// drag tests flip this to simulate an under-constrained sketch, since
  /// [SketchController.isUnderConstrained] (and so [dragTargetPointIdAt])
  /// gates entirely on the last-seen solve result.
  int dof = 0;

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
    requestLog.add('${request.method} $path');
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    final lineDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/(.+)$').firstMatch(path);
    if (lineDeleteMatch != null && request.method == 'DELETE') {
      lines.remove(lineDeleteMatch.group(1));
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

    final pointPatchMatch = RegExp(r'^/sketch/sketches/[^/]+/points/(.+)$').firstMatch(path);
    if (pointPatchMatch != null && request.method == 'PATCH') {
      final id = pointPatchMatch.group(1)!;
      final point = points[id];
      if (point == null) return http.Response('not found', 404);
      point['x'] = (body['x'] as num).toDouble();
      point['y'] = (body['y'] as num).toDouble();
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
        'construction': body['construction'] as bool? ?? false,
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
        case 'coincident':
          constraint = {
            'id': id,
            'type': 'coincident',
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
          };
          break;
        case 'parallel':
          constraint = {
            'id': id,
            'type': 'parallel',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
          };
          break;
        case 'perpendicular':
          constraint = {
            'id': id,
            'type': 'perpendicular',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
          };
          break;
        case 'equal_length':
          constraint = {
            'id': id,
            'type': 'equal_length',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
          };
          break;
        case 'collinear':
          constraint = {
            'id': id,
            'type': 'collinear',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
          };
          break;
        case 'line_distance':
          constraint = {
            'id': id,
            'type': 'line_distance',
            'line1_id': body['line1_id'],
            'line2_id': body['line2_id'],
            'distance': (body['distance'] as num).toDouble(),
          };
          break;
        case 'at_midpoint':
          constraint = {
            'id': id,
            'type': 'at_midpoint',
            'point_id': body['point_id'],
            'line_id': body['line_id'],
          };
          break;
        default:
          constraint = {
            'id': id,
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': (body['distance'] as num).toDouble(),
            'orientation': body['orientation'] as String? ?? 'linear',
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

    final profileMatch = RegExp(r'^/sketch/sketches/[^/]+/profile$').hasMatch(path);
    if (profileMatch && request.method == 'GET') {
      return _json(_profileBody(), 200);
    }

    return http.Response('not found: $path', 404);
  }

  /// A minimal stand-in for the backend's real profile-detection algorithm:
  /// good enough to flip between a single simple closed loop (every
  /// involved Point has degree 2, and the line count matches the point
  /// count) and "not a loop" for these tests, without reimplementing the
  /// server's general multi-loop/branch-point logic.
  Map<String, dynamic> _profileBody() {
    final degree = <String, int>{};
    final adjacency = <String, List<String>>{};
    for (final line in lines.values) {
      final a = line['start_point_id'] as String;
      final b = line['end_point_id'] as String;
      degree[a] = (degree[a] ?? 0) + 1;
      degree[b] = (degree[b] ?? 0) + 1;
      adjacency.putIfAbsent(a, () => []).add(b);
      adjacency.putIfAbsent(b, () => []).add(a);
    }
    final involved = degree.keys.toList();
    final isClosedLoop = involved.length >= 3 &&
        degree.values.every((d) => d == 2) &&
        lines.length == involved.length;
    if (!isClosedLoop) {
      // Mirrors the real backend's app.sketch.profile._circle_profile: a
      // standalone Circle (no Lines at all) is its own closed profile,
      // reported as exactly 2 Points (center, radius point) rather than an
      // ordered polygon boundary - needed to test the fix for the client
      // silently never filling a Circle profile's area (see
      // SketchController._refreshProfile / SketchCanvas._addLoopBoundary).
      if (lines.isEmpty && circles.length == 1) {
        final circle = circles.values.first;
        return {
          'status': 'closed_loop',
          'detail': 'ok',
          'profile': {
            'point_ids': [circle['center_point_id'], circle['radius_point_id']],
            'line_ids': [circle['id']],
          },
          'branch_point_ids': <String>[],
          'loops': <Map<String, dynamic>>[],
        };
      }
      return {
        'status': 'open',
        'detail': 'not a closed loop',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      };
    }
    final ordered = <String>[involved.first];
    String prev = involved.first;
    String curr = adjacency[involved.first]!.first;
    while (curr != involved.first) {
      ordered.add(curr);
      final neighbors = adjacency[curr]!;
      final next = neighbors[0] == prev ? neighbors[1] : neighbors[0];
      prev = curr;
      curr = next;
    }
    return {
      'status': 'closed_loop',
      'detail': 'ok',
      'profile': {'point_ids': ordered, 'line_ids': lines.keys.toList()},
      'branch_point_ids': <String>[],
      'loops': <Map<String, dynamic>>[],
    };
  }

  Map<String, dynamic> _solveResultBody() => {
        'converged': true,
        'dof': dof,
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

  test('Two Corner rectangle: first tap places only a point, second tap completes the rectangle', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);

    await controller.handleCanvasTap(2, 2);

    expect(controller.rectangleInProgress, isTrue);
    expect(controller.lines.length, 0);
    // 2: the real origin Point plus this first corner.
    expect(controller.points.length, 2);

    await controller.handleCanvasTap(10, 8);

    expect(controller.rectangleInProgress, isFalse);
    // 6: the 4 sides plus B2's 2 construction diagonals.
    expect(controller.lines.length, 6);
    expect(controller.lines.values.where((l) => l.construction).length, 2);
    // 6: origin + the two tapped corners (2,2) and (10,8) + the two
    // computed corners (10,2) and (2,8) + B2's new center Point.
    expect(controller.points.length, 6);
    expect(
      controller.constraints.values.whereType<PerpendicularConstraintDto>().length,
      0,
    );
    expect(
      controller.constraints.values.whereType<HorizontalConstraintDto>().length,
      2,
    );
    expect(
      controller.constraints.values.whereType<VerticalConstraintDto>().length,
      2,
    );
    // Bug-fix round 2: only one, not two - see _buildRectangle's doc
    // comment (a second AtMidpoint on the same centre Point is redundant
    // once H/V hold, and made the whole solve fail to converge).
    expect(
      controller.constraints.values.whereType<AtMidpointConstraintDto>().length,
      1,
    );
    expect(controller.errorMessage, isNull);
  });

  test('a two-corner rectangle\'s new center Point starts at the average of its 4 corners', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);

    await controller.handleCanvasTap(2, 2);
    await controller.handleCanvasTap(10, 8);

    // Corners are (2,2), (10,2), (10,8), (2,8) - average (6, 5). The center
    // Point is created last (after the 4 corners and 2 diagonals), and
    // `points` is insertion-ordered, so it's the final entry.
    final centerPoint = controller.points.values.last;
    expect(centerPoint.x, closeTo(6.0, 1e-9));
    expect(centerPoint.y, closeTo(5.0, 1e-9));
  });

  test('Centre + Corner rectangle: first tap is a virtual centre, second tap mirrors it into 4 corners', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.centreCorner);

    await controller.handleCanvasTap(5, 5);

    expect(controller.rectangleInProgress, isTrue);
    // The centre tap is virtual - no Point created for it yet.
    expect(controller.points.length, 1);
    expect(controller.lines.length, 0);

    await controller.handleCanvasTap(8, 8);

    expect(controller.rectangleInProgress, isFalse);
    // 6: the 4 sides plus B2's 2 construction diagonals.
    expect(controller.lines.length, 6);
    expect(controller.lines.values.where((l) => l.construction).length, 2);
    // 6: origin + the tapped corner (8,8) + the 3 mirrored corners
    // (2,8), (2,2), (8,2) + B2's new center Point.
    expect(controller.points.length, 6);
    final xs = controller.points.values.map((p) => p.x).toSet();
    final ys = controller.points.values.map((p) => p.y).toSet();
    expect(xs.containsAll([2, 8]), isTrue);
    expect(ys.containsAll([2, 8]), isTrue);
    expect(
      controller.constraints.values.whereType<PerpendicularConstraintDto>().length,
      0,
    );
    expect(
      controller.constraints.values.whereType<HorizontalConstraintDto>().length,
      2,
    );
    expect(
      controller.constraints.values.whereType<VerticalConstraintDto>().length,
      2,
    );
    // Bug-fix round 2: only one, not two - see _buildRectangle's doc
    // comment (a second AtMidpoint on the same centre Point is redundant
    // once H/V hold, and made the whole solve fail to converge).
    expect(
      controller.constraints.values.whereType<AtMidpointConstraintDto>().length,
      1,
    );
    expect(controller.errorMessage, isNull);
  });

  test('3-Point rectangle: builds a non-axis-aligned rectangle from two corners plus a height pick', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.threePoint);

    await controller.handleCanvasTap(1, 1);
    expect(controller.rectangleInProgress, isTrue);
    expect(controller.rectangleSecondX, isNull);

    await controller.handleCanvasTap(5, 4);
    expect(controller.rectangleSecondX, 5);
    expect(controller.lines.length, 0);

    // A 3-4-5 right triangle's normal off the first side, scaled by 5, so
    // the resulting rectangle's far corners land on clean coordinates.
    await controller.handleCanvasTap(-2, 5);

    expect(controller.rectangleInProgress, isFalse);
    expect(controller.lines.length, 4);
    // 5: origin + the two side-defining taps (1,1)/(5,4) + the two
    // computed far corners (2,8)/(-2,5).
    expect(controller.points.length, 5);
    final coords = controller.points.values.map((p) => (p.x, p.y)).toSet();
    expect(coords.contains((1.0, 1.0)), isTrue);
    expect(coords.contains((5.0, 4.0)), isTrue);
    expect(
      coords.any((c) => (c.$1 - 2.0).abs() < 1e-6 && (c.$2 - 8.0).abs() < 1e-6),
      isTrue,
    );
    expect(
      coords.any((c) => (c.$1 - (-2.0)).abs() < 1e-6 && (c.$2 - 5.0).abs() < 1e-6),
      isTrue,
    );
    expect(
      controller.constraints.values.whereType<PerpendicularConstraintDto>().length,
      3,
    );
    expect(controller.errorMessage, isNull);
  });

  test('3-Point rectangle rejects a degenerate first side (two identical points)', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.threePoint);

    await controller.handleCanvasTap(1, 1);
    await controller.handleCanvasTap(1, 1);
    await controller.handleCanvasTap(5, 5);

    expect(controller.lines.length, 0);
    expect(controller.errorMessage, isNotNull);
  });

  test('a rectangle corner snaps onto an existing nearby Point instead of duplicating it', () async {
    // Place a real Point at (10, 2) via the line tool first.
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(10, 2);
    final preplacedId = controller.chainFirstPointId;
    expect(controller.points.length, 2); // origin + this Point

    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);

    await controller.handleCanvasTap(2, 2);
    await controller.handleCanvasTap(10, 8);

    // The computed corner at (10, 2) should reuse the pre-placed Point
    // rather than creating a new one (6: origin + the reused Point + the
    // two tapped corners + the other computed corner + B2's center Point).
    expect(controller.points.length, 6);
    expect(controller.points.containsKey(preplacedId), isTrue);
    final reused = controller.points[preplacedId]!;
    expect(reused.x, 10);
    expect(reused.y, 2);
    final cornerLines = controller.lines.values
        .where((l) => l.startPointId == preplacedId || l.endPointId == preplacedId)
        .toList();
    // The reused corner's own 2 sides, plus the 1 construction diagonal
    // (B2) that runs through it (the other diagonal connects the opposite
    // corner pair).
    expect(cornerLines.length, 3);
  });

  test('snapCandidatePointId is null outside draw mode and when nothing is nearby', () {
    controller.cursorX = 0;
    controller.cursorY = 0;
    expect(controller.snapCandidatePointId, isNull); // select mode by default

    controller.selectDrawTool(SketchTool.line);
    controller.cursorX = 50;
    controller.cursorY = 50;
    expect(controller.snapCandidatePointId, isNull); // nothing within snapRadius
  });

  test('snapCandidatePointId reports the nearby existing Point while in draw mode', () {
    controller.selectDrawTool(SketchTool.line);
    expect(controller.snapCandidatePointId, controller.originPointId); // cursor starts at (0, 0)

    controller.cursorX = 10;
    controller.cursorY = 10;
    expect(controller.snapCandidatePointId, isNull);
  });

  test('activeDrawGhost is null when idle and tracks the cursor for an end-to-end line', () async {
    expect(controller.activeDrawGhost, isNull); // select mode by default

    controller.selectDrawTool(SketchTool.line);
    controller.setLineConstructionMethod(LineConstructionMethod.endToEnd);
    expect(controller.activeDrawGhost, isNull); // no first point placed yet

    await controller.handleCanvasTap(1, 1);
    controller.cursorX = 4;
    controller.cursorY = 5;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<LineGhost>());
    final line = ghost as LineGhost;
    expect(line.startX, 1);
    expect(line.startY, 1);
    expect(line.endX, 4);
    expect(line.endY, 5);
  });

  test('activeDrawGhost previews a center-radius circle from its center to the cursor', () async {
    controller.selectDrawTool(SketchTool.circle);
    controller.setCircleConstructionMethod(CircleConstructionMethod.centerRadius);

    await controller.handleCanvasTap(2, 2);
    controller.cursorX = 6;
    controller.cursorY = 2;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<CircleGhost>());
    final circle = ghost as CircleGhost;
    expect(circle.centerX, 2);
    expect(circle.centerY, 2);
    expect(circle.edgeX, 6);
    expect(circle.edgeY, 2);
  });

  test('activeDrawGhost previews a two-corner rectangle from its first corner to the cursor', () async {
    controller.selectDrawTool(SketchTool.rectangle);
    controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);

    await controller.handleCanvasTap(1, 1);
    controller.cursorX = 5;
    controller.cursorY = 4;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<RectGhost>());
    final rect = ghost as RectGhost;
    expect(rect.corner0, (1.0, 1.0));
    expect(rect.corner1, (5.0, 1.0));
    expect(rect.corner2, (5.0, 4.0));
    expect(rect.corner3, (1.0, 4.0));
  });

  test('dimensionLabelAt hits a dragged label at its offset position and misses its old default anchor', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)
    controller.tapGhost('length');
    await controller.confirmGhostValue('length', 25.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // Default anchor for this Line's DistanceConstraint label, per
    // _paintDistanceDimension's own layout: the two Points' screen
    // positions, each nudged 18px along the perpendicular normal, averaged.
    const defaultAnchor = Offset(500, 318);

    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), constraintId);

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(30, -10));
    controller.endLabelDrag();

    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), isNull);
    expect(dimensionLabelAt(controller, transform, const Offset(530, 308), 5), constraintId);
  });

  test('updateLabelDrag sums successive deltas onto the offset', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    controller.tapGhost('length');
    await controller.confirmGhostValue('length', 25.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(5, 3));
    controller.updateLabelDrag(const Offset(-2, 7));

    expect(controller.labelOffsetFor(constraintId), const Offset(3, 10));
  });

  test('endLabelDrag retains the accumulated offset and clears draggingLabelId', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    controller.tapGhost('length');
    await controller.confirmGhostValue('length', 25.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(12, -4));
    controller.endLabelDrag();

    expect(controller.draggingLabelId, isNull);
    expect(controller.labelOffsetFor(constraintId), const Offset(12, -4));
  });

  test('resetLabelOffset (the double-tap-without-drag gesture) snaps a label back to zero', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1);
    controller.tapGhost('length');
    await controller.confirmGhostValue('length', 25.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(2, 1)); // tiny - under the 4px reset threshold
    controller.endLabelDrag();
    expect(controller.labelOffsetFor(constraintId), const Offset(2, 1));

    controller.resetLabelOffset(constraintId);

    expect(controller.labelOffsetFor(constraintId), Offset.zero);
  });

  test('closedProfileFills is populated with the ordered loop once a chain closes', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    expect(controller.closedProfileFills, isEmpty);

    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(5, 5);
    expect(controller.closedProfileFills, isEmpty); // still open

    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    await controller.handleCanvasTap(0.1, 0.1); // closes the loop

    expect(controller.closedProfileFills, hasLength(1));
    expect(controller.closedProfileFills.single.pointIds, hasLength(3));
    expect(controller.closedProfileFills.single.pointIds.toSet(), controller.points.keys.toSet());
  });

  test(
    'closedProfileFills is populated for a standalone Circle profile (bug fix: '
    'a >= 3 point-count filter previously dropped every Circle, which is reported '
    'as exactly 2 points)',
    () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(5, 0);

      expect(controller.closedProfileFills, hasLength(1));
      expect(controller.closedProfileFills.single.pointIds, hasLength(2));
    },
  );

  test('closedProfileFills reverts to empty once the loop is broken by deleting a line', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(5, 5);
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    await controller.handleCanvasTap(0.1, 0.1); // closes the loop
    expect(controller.closedProfileFills, isNotEmpty);

    controller.exitToSelectMode();
    final lineToDelete = controller.lines.keys.first; // the (0, 0)-(5, 0) edge

    // Away from the line's midpoint (2.5, 0) - see the deleteSelected line
    // test above for why.
    await controller.handleCanvasTap(4, 0.1);
    expect(controller.selection!.id, lineToDelete);

    await controller.deleteSelected();

    expect(controller.closedProfileFills, isEmpty);
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

  group('clampCursorToCanvas', () {
    const canvasSize = Size(400, 300);

    test('in-bounds input is returned unchanged', () {
      const candidate = Offset(200, 150);
      expect(clampCursorToCanvas(candidate, canvasSize), candidate);
    });

    test('escaping left (dx < 0) snaps to the canvas centre', () {
      final result = clampCursorToCanvas(const Offset(-1, 150), canvasSize);
      expect(result, const Offset(200, 150));
    });

    test('escaping right (dx > width) snaps to the canvas centre', () {
      final result = clampCursorToCanvas(const Offset(401, 150), canvasSize);
      expect(result, const Offset(200, 150));
    });

    test('escaping up (dy < 0) snaps to the canvas centre', () {
      final result = clampCursorToCanvas(const Offset(200, -1), canvasSize);
      expect(result, const Offset(200, 150));
    });

    test('escaping down (dy > height) snaps to the canvas centre', () {
      final result = clampCursorToCanvas(const Offset(200, 301), canvasSize);
      expect(result, const Offset(200, 150));
    });

    test('points exactly on the boundary count as in-bounds', () {
      expect(clampCursorToCanvas(const Offset(0, 0), canvasSize), const Offset(0, 0));
      expect(clampCursorToCanvas(const Offset(400, 0), canvasSize), const Offset(400, 0));
      expect(clampCursorToCanvas(const Offset(0, 300), canvasSize), const Offset(0, 300));
      expect(clampCursorToCanvas(const Offset(400, 300), canvasSize), const Offset(400, 300));
    });
  });

  test('moveCursorRelative never clamps/resets, even across many consecutive calls (bug-fix '
      'round 2: doing so here, rather than only at a fresh gesture start, is what caused the '
      'cursor to visibly teleport to centre mid-drag during active RTS panning)', () {
    // originScreen at the canvas centre, 10px/unit - a cursor more than 20
    // sketch-units off in X escapes a 400-wide canvas (200px either side).
    const transform = ViewTransform(pixelsPerUnit: 10, originScreen: Offset(200, 150));
    const canvasSize = Size(400, 300);
    controller.cursorX = 0;
    controller.cursorY = 0;

    controller.moveCursorRelative(5000, 0, 1);
    // touchSensitivity (0.05) * 5000 = 250 sketch units - genuinely off-canvas
    // now, and that's fine; it isn't yanked back.
    expect(controller.cursorX, closeTo(250, 1e-9));
    expect(controller.isCursorVisible(canvasSize, transform), isFalse);

    // A second, further delta - simulating the same continuous drag - must
    // keep accumulating normally, not snap back to centre just because the
    // cursor was already off-canvas from the previous call.
    controller.moveCursorRelative(100, 0, 1);
    expect(controller.cursorX, closeTo(255, 1e-9));
  });

  group('resetCursorToCentreIfHidden', () {
    const transform = ViewTransform(pixelsPerUnit: 10, originScreen: Offset(200, 150));
    const canvasSize = Size(400, 300);

    test('resets an off-canvas cursor to canvas centre', () {
      controller.cursorX = 1000;
      controller.cursorY = 0;

      controller.resetCursorToCentreIfHidden(canvasSize, transform);

      final screen = transform.sketchToScreen(controller.cursorX, controller.cursorY);
      expect(screen.dx, closeTo(200, 1e-9));
      expect(screen.dy, closeTo(150, 1e-9));
    });

    test('leaves an on-canvas cursor untouched', () {
      controller.cursorX = 5;
      controller.cursorY = 5;

      controller.resetCursorToCentreIfHidden(canvasSize, transform);

      expect(controller.cursorX, 5);
      expect(controller.cursorY, 5);
    });
  });

  group('isCursorVisible', () {
    const transform = ViewTransform(pixelsPerUnit: 10, originScreen: Offset(200, 150));
    const canvasSize = Size(400, 300);

    test('is true for a cursor within canvas bounds', () {
      controller.cursorX = 0;
      controller.cursorY = 0;
      expect(controller.isCursorVisible(canvasSize, transform), isTrue);
    });

    test('is false once the cursor has drifted off-canvas', () {
      controller.cursorX = 1000;
      controller.cursorY = 0;
      expect(controller.isCursorVisible(canvasSize, transform), isFalse);
    });
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
    expect(controller.hoveredEntity(), isNull);
  });

  test('hoveredEntity is null in draw mode even when idle', () {
    controller.selectDrawTool(SketchTool.line);
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    expect(controller.hoveredEntity(), isNull);
  });

  test('hoveredEntity detects a nearby Point while idle in select mode', () {
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;

    final hovered = controller.hoveredEntity();
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

    final hovered = controller.hoveredEntity();
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

    final hovered = controller.hoveredEntity();
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.circle);
    expect(hovered.id, circleId);
  });

  test('bug-fix round 3: hoveredEntity(pixelsPerUnit) uses the exact same zoom-scaled radius as '
      'tap-to-select, instead of always the flat snapRadius', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final lineId = controller.lines.keys.first;

    // Zoomed out enough that minTapHitRadiusPixels/pixelsPerUnit exceeds
    // snapRadius - far enough from the line that the old flat-snapRadius
    // hover would miss it, but still within the zoom-scaled tap radius
    // (matching what handleCanvasTap would actually select here). The cursor
    // sits at the line's midpoint, far from either endpoint, so this
    // exercises the line branch rather than pointHitRadiusMultiplier's
    // larger endpoint radius snapping to a Point instead.
    const pixelsPerUnit = 5.0; // 14px / 5 = 2.8 sketch units
    controller.cursorX = 10;
    controller.cursorY = 2.0; // 2.0 sketch units off the line - past snapRadius (0.5)

    expect(controller.hoveredEntity(), isNull); // old flat-snapRadius behaviour
    final hovered = controller.hoveredEntity(pixelsPerUnit);
    expect(hovered, isNotNull);
    expect(hovered!.kind, SelectionKind.line);
    expect(hovered.id, lineId);
    expect(
      controller.hitRadiusForPixelsPerUnit(pixelsPerUnit),
      closeTo(SketchController.minTapHitRadiusPixels / pixelsPerUnit, 1e-9),
    );
  });

  test('handleCanvasTap selects the hovered entity and opens the ribbon while idle', () async {
    await controller.handleCanvasTap(0.1, 0.1);

    expect(controller.selection, isNotNull);
    expect(controller.selection!.kind, SelectionKind.point);
    expect(controller.selection!.id, controller.originPointId);
    expect(controller.ribbonVisible, isTrue);
  });

  test('handleCanvasTap on blank space is a no-op when the ribbon was already closed', () async {
    // Stage 23d: tapping blank canvas no longer surfaces the idle ribbon
    // (which used to offer only "Exit Sketch") - that action moved to the
    // hamburger menu.
    expect(controller.ribbonVisible, isFalse);

    await controller.handleCanvasTap(50, 50);

    expect(controller.selection, isNull);
    expect(controller.ribbonVisible, isFalse);
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

  test('confirming a vertical/horizontal/linear ghost creates a DistanceConstraint with the '
      'matching orientation (Prompt B item B3)', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);

    await controller.confirmGhostValue('v', 4.0);

    final created = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(created.orientation, 'vertical');
  });

  test('confirming a horizontal ghost sends orientation "horizontal"', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);

    await controller.confirmGhostValue('h', 3.0);

    final created = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(created.orientation, 'horizontal');
  });

  test('confirming a linear ghost sends orientation "linear" (the default)', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);

    await controller.confirmGhostValue('linear', 5.0);

    final created = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(created.orientation, 'linear');
  });

  test('bug-fix round: re-confirming a different orientation for the same point pair replaces '
      'the existing DistanceConstraint instead of just patching its value in place', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('linear', 5.0);
    final firstId = controller.constraints.values.whereType<DistanceConstraintDto>().single.id;

    // Re-pick the same two points and confirm a *different* orientation.
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('h', 3.0);

    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>();
    expect(distanceConstraints.length, 1); // the old linear one was deleted, not left in place
    final replaced = distanceConstraints.single;
    expect(replaced.id, isNot(firstId));
    expect(replaced.orientation, 'horizontal');
    expect(replaced.distance, 3.0);
  });

  test(
      'bug-fix: a confirmed horizontal DistanceConstraint renders/hit-tests at its '
      'orientation-aware anchor, not the plain diagonal linear-dimension layout '
      '(this is what made a horizontal dimension look like it "became linear" on-device)',
      () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('h', 3.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // Points at screen (400, 300) and (460, 220). A horizontal dimension's
    // anchor sits at their midpoint-x, offset down to the lower of the two
    // - not the diagonal parallel-offset midpoint a linear dimension uses.
    const horizontalAnchor = Offset(430, 318);
    expect(dimensionLabelAt(controller, transform, horizontalAnchor, 5), constraintId);

    // The old (pre-fix) diagonal-layout anchor no longer matches, since the
    // dimension is no longer rendered there.
    const oldDiagonalLayoutAnchor = Offset(444.4, 270.8);
    expect(dimensionLabelAt(controller, transform, oldDiagonalLayoutAnchor, 5), isNull);
  });

  test(
      'bug-fix: a confirmed vertical DistanceConstraint renders/hit-tests at its '
      'orientation-aware anchor, not the plain diagonal linear-dimension layout', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('v', 4.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // A vertical dimension's anchor sits at their midpoint-y, offset right
    // to whichever Point is further right on screen.
    const verticalAnchor = Offset(478, 260);
    expect(dimensionLabelAt(controller, transform, verticalAnchor, 5), constraintId);

    const oldDiagonalLayoutAnchor = Offset(444.4, 270.8);
    expect(dimensionLabelAt(controller, transform, oldDiagonalLayoutAnchor, 5), isNull);
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

  test('Prompt B item B4: placing a point on top of an existing Point creates a distinct Point '
      'auto-linked by a CoincidentConstraint, not a silent reuse', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 4);
    final firstId = controller.points.values.last.id;
    expect(controller.points.length, 2);

    await controller.handleCanvasTap(3.1, 4.1); // within snapRadius of the point just placed

    // 3: origin + the first Point + a genuinely new, distinct second Point.
    expect(controller.points.length, 3);
    final secondId = controller.points.values.last.id;
    expect(secondId, isNot(firstId));
    final created = controller.constraints.values.whereType<CoincidentConstraintDto>().single;
    expect({created.pointAId, created.pointBId}, {firstId, secondId});
    expect(controller.autoCoincidentIndicatorPointId, secondId);
  });

  test('placing a point well outside the snap threshold of any existing Point creates no '
      'CoincidentConstraint', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 4);

    await controller.handleCanvasTap(30, 40); // far outside snapRadius

    expect(controller.points.length, 3);
    expect(controller.constraints.values.whereType<CoincidentConstraintDto>(), isEmpty);
    expect(controller.autoCoincidentIndicatorPointId, isNull);
  });

  test('undo after an auto-coincident point placement removes the CoincidentConstraint, then '
      'the Point, in two steps', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 4);
    await controller.handleCanvasTap(3.1, 4.1);
    expect(controller.constraints.values.whereType<CoincidentConstraintDto>().length, 1);
    final placedCount = controller.points.length;

    await controller.undo();

    expect(controller.constraints.values.whereType<CoincidentConstraintDto>(), isEmpty);
    expect(controller.points.length, placedCount); // the Point itself is still there

    await controller.undo();

    expect(controller.points.length, placedCount - 1); // now the Point is gone too
  });

  test('the auto-coincident indicator clears on the next canvas tap', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 4);
    await controller.handleCanvasTap(3.1, 4.1);
    expect(controller.autoCoincidentIndicatorPointId, isNotNull);

    await controller.handleCanvasTap(50, 50);

    expect(controller.autoCoincidentIndicatorPointId, isNull);
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
      'confirming a lineDistance ghost creates a LineDistanceConstraint between the two '
      'Lines directly, with no new Points (Stage 16 item 9)', () async {
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
    final pointCountBefore = backend.points.length;

    await controller.confirmGhostValue('lineDistance', 7.0);

    expect(controller.errorMessage, isNull);
    expect(controller.ghosts, isEmpty);
    expect(backend.points.length, pointCountBefore); // no midpoint Point materialized
    final lineDistanceConstraints = controller.constraints.values.whereType<LineDistanceConstraintDto>();
    expect(lineDistanceConstraints.single.distance, 7.0);
  });

  test(
      'confirming an existing lineDistance ghost a second time PATCHes the existing '
      'LineDistanceConstraint instead of creating a second one', () async {
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

    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(8, 5.1);
    await controller.confirmGhostValue('lineDistance', 9.0);

    expect(controller.errorMessage, isNull);
    final lineDistanceConstraints = controller.constraints.values.whereType<LineDistanceConstraintDto>();
    expect(lineDistanceConstraints.length, 1);
    expect(lineDistanceConstraints.single.distance, 9.0);
  });

  test(
      'dimensionLabelAt finds a LineDistanceConstraint label at its default anchor, and '
      'follows it after a drag (Stage 16 item 9\'s leader-line fix)', () async {
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
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is LineDistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // Default anchor for this LineDistanceConstraint's label, per
    // _paintLineDistanceDimension's own layout: each Line's screen-space
    // midpoint, each nudged 18px along the perpendicular normal, averaged -
    // mirrors the point-pair DistanceConstraint test above, just anchored on
    // Line midpoints instead of Points.
    const defaultAnchor = Offset(518, 250);

    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), constraintId);

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(30, -10));
    controller.endLabelDrag();

    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), isNull);
    expect(dimensionLabelAt(controller, transform, const Offset(548, 240), 5), constraintId);
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

  // --- New work package item 8: double-click-and-drag -----------------------
  //
  // isUnderConstrained only ever changes on a solve response (see
  // _solveAndTrackDof), and the Point tool's placement path doesn't solve at
  // all (see _clickPointTool) - so these tests draw a two-tap Line, whose
  // second tap's _clickEndToEndLineTool does solve, to drive backend.dof.

  test('dragTargetPointIdAt is null while the sketch is fully constrained', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0); // backend.dof defaults to 0
    controller.finishChain();
    controller.exitToSelectMode();

    expect(controller.isUnderConstrained, isFalse);
    expect(controller.dragTargetPointIdAt(0, 0, 1), isNull);
  });

  test('dragTargetPointIdAt returns a directly-hit Point once the sketch is under-constrained',
      () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final line = controller.lines.values.last;

    expect(controller.isUnderConstrained, isTrue);
    expect(controller.dragTargetPointIdAt(0, 0, 1), line.startPointId);
  });

  test('dragTargetPointIdAt is null outside select mode even when under-constrained', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    // Still in draw mode (finishChain above doesn't exit it).

    expect(controller.dragTargetPointIdAt(0, 0, 1), isNull);
  });

  test('dragTargetPointIdAt resolves a Line to whichever endpoint is nearer the hit', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final line = controller.lines.values.last;

    expect(controller.dragTargetPointIdAt(8, 0, 1), line.endPointId);
    expect(controller.dragTargetPointIdAt(2, 0, 1), line.startPointId);
  });

  test('beginPointDrag sets draggingPointId for a known Point and rejects an unknown id', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.lines.values.last.startPointId;

    expect(controller.beginPointDrag('does-not-exist'), isFalse);
    expect(controller.draggingPointId, isNull);

    expect(controller.beginPointDrag(pointId), isTrue);
    expect(controller.draggingPointId, pointId);
  });

  test('beginPointDrag only records local drag state - no HTTP call, no Point movement', () async {
    // Stage 16 item 5 regression test: a double-tap's second pointer-down
    // typically lands within the hit-radius of the Point rather than
    // pixel-exact on it, so beginPointDrag must record that offset (via
    // _dragOriginCursorX/Y vs _dragOriginPointX/Y) rather than ever PATCHing
    // the touch-down position - otherwise the Point visibly jumps to the
    // touch position before any drag motion happens.
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.lines.values.last.startPointId;
    final pointBefore = controller.points[pointId]!;

    backend.requestLog.clear();
    expect(controller.beginPointDrag(pointId), isTrue);

    expect(backend.requestLog, isEmpty);
    expect(controller.points[pointId]!.x, pointBefore.x);
    expect(controller.points[pointId]!.y, pointBefore.y);
  });

  test('updatePointDrag PATCHes the dragged Point, offset from the touch by where the drag started', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.lines.values.last.startPointId;
    // The chain's last tap left the controller's persistent cursor at
    // (10, 0); this Point (the line's start) sits at (0, 0). beginPointDrag
    // records that 10-unit offset, so updatePointDrag must apply moves
    // relative to it rather than snapping the Point to the raw touch
    // position - see beginPointDrag's doc comment.
    controller.beginPointDrag(pointId);

    backend.dof = 7; // would surface in isUnderConstrained if a solve ran
    await controller.updatePointDrag(12, 34);

    expect(controller.points[pointId]!.x, 2); // 0 + (12 - 10)
    expect(controller.points[pointId]!.y, 34); // 0 + (34 - 0)
    expect(controller.isUnderConstrained, isTrue); // unchanged: still the dof=1 from the line's solve
    expect(controller.errorMessage, isNull);
  });

  test('endPointDrag clears draggingPointId and re-solves from the dropped position', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.lines.values.last.startPointId;
    controller.beginPointDrag(pointId);
    await controller.updatePointDrag(12, 34); // lands at (2, 34) - see the test above

    backend.dof = 0; // simulates the drop settling the sketch fully
    await controller.endPointDrag();

    expect(controller.draggingPointId, isNull);
    expect(controller.isUnderConstrained, isFalse);
    expect(controller.points[pointId]!.x, 2);
    expect(controller.points[pointId]!.y, 34);
    expect(controller.errorMessage, isNull);
  });

  // --- Stage 16 item 7: Coincident/Parallel/Perpendicular/EqualLength/
  // Collinear moved from the dimension tool's button row to the select-mode
  // flyout, driven by [SketchController.selectionSet] (not
  // [SketchController.dimensionSelection]) via [availableConstraintOptions]/
  // [canApplyConstraint]. -----------------------------------------------

  test('canApplyConstraint(coincident) is true for two selected Points, false for the two-Line '
      'types', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(3, 9);
    controller.exitToSelectMode();

    expect(controller.canApplyConstraint(ConstraintOptionType.coincident), isFalse);
    await controller.handleCanvasTap(0, 5);
    expect(controller.canApplyConstraint(ConstraintOptionType.coincident), isFalse);

    await controller.handleCanvasTap(3, 9);

    expect(controller.canApplyConstraint(ConstraintOptionType.coincident), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.parallel), isFalse);
    expect(controller.canApplyConstraint(ConstraintOptionType.perpendicular), isFalse);
    expect(controller.canApplyConstraint(ConstraintOptionType.equalLength), isFalse);
    expect(controller.canApplyConstraint(ConstraintOptionType.collinear), isFalse);
  });

  test(
      'canApplyConstraint(parallel/perpendicular/equalLength/collinear) is true for two selected '
      'Lines, false for coincident', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(8, 0.1); // horizontal line, away from its midpoint
    await controller.handleCanvasTap(0.1, 8); // vertical line, away from its midpoint

    expect(controller.canApplyConstraint(ConstraintOptionType.parallel), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.perpendicular), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.equalLength), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.collinear), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.coincident), isFalse);
  });

  test('canApplyConstraint(coincident) is true for a selected Point and Line pair', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 5);
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(20, 0);
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(0, 5); // the Point
    await controller.handleCanvasTap(15, 0.1); // the Line, away from its midpoint

    expect(controller.canApplyConstraint(ConstraintOptionType.coincident), isTrue);
    expect(controller.canApplyConstraint(ConstraintOptionType.parallel), isFalse);
    expect(controller.canApplyConstraint(ConstraintOptionType.collinear), isFalse);
  });

  test('canApplyConstraint is false for every wired type when two Circles are selected '
      '(Concentric/EqualRadius are offered but not wired)', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(20, 0);
    await controller.handleCanvasTap(23, 0);
    controller.exitToSelectMode();

    await controller.handleCanvasTap(0, 5); // first circle's edge, away from center/radius point
    await controller.handleCanvasTap(20, 3); // second circle's edge

    expect(controller.selectionSet.length, 2);
    for (final type in ConstraintOptionType.values) {
      expect(controller.canApplyConstraint(type), isFalse, reason: '$type');
    }
  });

  test('canApplyConstraint is false for every wired type when a Circle and a Line are selected '
      '(Tangent is offered but not wired)', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(20, 10);
    await controller.handleCanvasTap(30, 10);
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(0, 5); // the circle's edge
    await controller.handleCanvasTap(25, 10.1); // the line, away from its midpoint

    expect(controller.selectionSet.length, 2);
    for (final type in ConstraintOptionType.values) {
      expect(controller.canApplyConstraint(type), isFalse, reason: '$type');
    }
  });

  test('addCoincidentConstraint creates a CoincidentConstraint between the two selected Points '
      'and clears the selection set', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(3, 9);
    final pointA = controller.points.values.firstWhere((p) => p.x == 0 && p.y == 5).id;
    final pointB = controller.points.values.firstWhere((p) => p.x == 3 && p.y == 9).id;
    controller.exitToSelectMode();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(3, 9);

    await controller.addCoincidentConstraint();

    expect(controller.errorMessage, isNull);
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
    final created = controller.constraints.values.whereType<CoincidentConstraintDto>().single;
    expect({created.pointAId, created.pointBId}, {pointA, pointB});
  });

  test('the origin is selectable so a Point can be constrained Coincident to it', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(3, 9);
    final pointB = controller.points.values.firstWhere((p) => p.x == 3 && p.y == 9).id;
    controller.exitToSelectMode();

    await controller.handleCanvasTap(0, 0); // the origin
    expect(controller.selection!.kind, SelectionKind.point);
    expect(controller.selection!.id, controller.originPointId);

    await controller.handleCanvasTap(3, 9); // adds the second Point to the selection

    await controller.addCoincidentConstraint();

    expect(controller.errorMessage, isNull);
    final created = controller.constraints.values.whereType<CoincidentConstraintDto>().single;
    expect({created.pointAId, created.pointBId}, {controller.originPointId, pointB});
  });

  test('dragTargetPointIdAt never offers the origin as a drag target, even under-constrained',
      () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // chain start, snaps to the origin
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();

    expect(controller.isUnderConstrained, isTrue);
    expect(controller.dragTargetPointIdAt(0, 0, 1), isNull);
  });

  test('addParallelConstraint creates a ParallelConstraint between the two selected Lines and '
      'clears the selection set', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(10, 6);
    controller.finishChain();
    final lineIds = controller.lines.keys.toSet();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1); // first line, away from its midpoint (5, 0)
    await controller.handleCanvasTap(8, 5.8); // second line, away from its midpoint (5, 5.5)

    await controller.addParallelConstraint();

    expect(controller.errorMessage, isNull);
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
    final created = controller.constraints.values.whereType<ParallelConstraintDto>().single;
    expect({created.line1Id, created.line2Id}, lineIds);
  });

  test('addPerpendicularConstraint creates a PerpendicularConstraint between the two selected '
      'Lines and clears the selection set', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(3, 3);
    await controller.handleCanvasTap(5, 9);
    controller.finishChain();
    final lineIds = controller.lines.keys.toSet();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(3.5, 4.5); // second line, away from its midpoint (4, 6)

    await controller.addPerpendicularConstraint();

    expect(controller.errorMessage, isNull);
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
    final created = controller.constraints.values.whereType<PerpendicularConstraintDto>().single;
    expect({created.line1Id, created.line2Id}, lineIds);
  });

  test('addEqualLengthConstraint creates an EqualLengthConstraint between the two selected Lines '
      'and clears the selection set', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(0, 8);
    controller.finishChain();
    final lineIds = controller.lines.keys.toSet();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(0.1, 7.5); // second line, away from its midpoint (0, 6.5)

    await controller.addEqualLengthConstraint();

    expect(controller.errorMessage, isNull);
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
    final created = controller.constraints.values.whereType<EqualLengthConstraintDto>().single;
    expect({created.line1Id, created.line2Id}, lineIds);
  });

  test('addCollinearConstraint creates a CollinearConstraint between the two selected Lines and '
      'clears the selection set', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(2, 3);
    await controller.handleCanvasTap(8, 3);
    controller.finishChain();
    final lineIds = controller.lines.keys.toSet();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1); // first line, away from its midpoint (5, 0)
    await controller.handleCanvasTap(5, 3.1); // second line, away from its midpoint (5, 3)

    await controller.addCollinearConstraint();

    expect(controller.errorMessage, isNull);
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
    final created = controller.constraints.values.whereType<CollinearConstraintDto>().single;
    expect({created.line1Id, created.line2Id}, lineIds);
  });

  test('addCoincidentConstraint is a no-op when the current selection set is not a valid '
      'Coincident shape', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(10, 6);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1); // two Lines, not two Points
    await controller.handleCanvasTap(8, 5.8);

    await controller.addCoincidentConstraint();

    expect(controller.constraints.values.whereType<CoincidentConstraintDto>(), isEmpty);
    expect(controller.selectionSet.length, 2); // left untouched by the no-op
  });

  test('applyConstraintOption(collinear) dispatches to addCollinearConstraint', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(2, 3);
    await controller.handleCanvasTap(8, 3);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(5, 3.1);

    await controller.applyConstraintOption(ConstraintOptionType.collinear);

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<CollinearConstraintDto>().length, 1);
  });

  // --- Stage 23g/23h: marquee selection and the Selected Entities list ------

  test('hasEntityNear is true near existing geometry and false on truly empty canvas', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(10, 10);
    await controller.handleCanvasTap(20, 10);
    controller.finishChain();
    controller.exitToSelectMode();

    expect(controller.hasEntityNear(10, 10, 1), isTrue);
    expect(controller.hasEntityNear(500, 500, 1), isFalse);
  });

  test('hasEntityNear is true near the origin Point even though it is never selectable',
      () async {
    expect(controller.hasEntityNear(0, 0, 1), isTrue);
  });

  test('selectInRect selects a Line and its endpoints when fully inside the rect, and excludes '
      'a Line that falls outside it', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(5, 5);
    await controller.handleCanvasTap(15, 5);
    controller.finishChain();
    final insideLine = controller.lines.values.first;
    await controller.handleCanvasTap(50, 50);
    await controller.handleCanvasTap(60, 50);
    controller.finishChain();
    final outsideLine = controller.lines.values.last;
    controller.exitToSelectMode();

    controller.selectInRect(const Rect.fromLTRB(4, 4, 16, 6));

    final selectedIds = controller.selectionSet.map((s) => s.id).toSet();
    expect(selectedIds, contains(insideLine.id));
    expect(selectedIds, isNot(contains(outsideLine.id)));
    expect(
      controller.selectionSet.where((s) => s.kind == SelectionKind.point).length,
      2, // the inside Line's two endpoints
    );
    expect(controller.ribbonVisible, isTrue);
  });

  test('selectInRect never selects the origin Point even when the rect contains it', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(50, 50);
    await controller.handleCanvasTap(60, 50);
    controller.finishChain();
    controller.exitToSelectMode();

    controller.selectInRect(const Rect.fromLTRB(-1, -1, 1, 1));

    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
  });

  test('selectInRect selects a Circle only once its full bounding box is inside the rect',
      () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(30, 30); // center
    await controller.handleCanvasTap(35, 30); // radius point - radius 5
    final circle = controller.circles.values.first;
    controller.exitToSelectMode();

    controller.selectInRect(const Rect.fromLTRB(40, 40, 60, 60)); // misses the circle entirely
    expect(controller.selectionSet.any((s) => s.kind == SelectionKind.circle), isFalse);

    controller.selectInRect(const Rect.fromLTRB(20, 20, 40, 40)); // fully contains it
    expect(
      controller.selectionSet,
      contains(predicate<SketchSelection>((s) => s.kind == SelectionKind.circle && s.id == circle.id)),
    );
  });

  test('deselect removes one entity from a multi-selection and closes the ribbon once the last '
      'one is removed', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(5, 5);
    await controller.handleCanvasTap(15, 5);
    controller.finishChain();
    await controller.handleCanvasTap(5, 50);
    await controller.handleCanvasTap(15, 50);
    controller.finishChain();
    controller.exitToSelectMode();
    controller.selectInRect(const Rect.fromLTRB(0, 0, 20, 60));
    expect(controller.selectionSet.length, greaterThanOrEqualTo(2));
    final toRemove = controller.selectionSet.first;

    controller.deselect(toRemove);

    expect(controller.selectionSet.any((s) => s.sameAs(toRemove)), isFalse);
    expect(controller.ribbonVisible, isTrue);

    for (final remaining in List<SketchSelection>.from(controller.selectionSet)) {
      controller.deselect(remaining);
    }
    expect(controller.selectionSet, isEmpty);
    expect(controller.ribbonVisible, isFalse);
  });

  test('selectionLabel names Lines, Points and Circles by creation order, excluding the origin '
      'Point from Point numbering', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(5, 5);
    await controller.handleCanvasTap(15, 5);
    controller.finishChain();
    final line = controller.lines.values.first;
    final linePoints = controller.points.values.where((p) => p.x != 0 || p.y != 0).toList();

    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(30, 30);
    await controller.handleCanvasTap(35, 30);
    final circle = controller.circles.values.first;
    controller.exitToSelectMode();

    expect(
      controller.selectionLabel(SketchSelection(kind: SelectionKind.line, id: line.id)),
      'Line 1',
    );
    expect(
      controller.selectionLabel(SketchSelection(kind: SelectionKind.point, id: linePoints.first.id)),
      'Point 1',
    );
    expect(
      controller.selectionLabel(SketchSelection(kind: SelectionKind.circle, id: circle.id)),
      'Circle 1',
    );
  });
}
