import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// A copy of `sketch_controller_test.dart`'s `_FakeBackend` (trimmed to just
/// the endpoints this file's flow needs: create sketch, create point,
/// create line, list/get points, create+list distance constraints, solve,
/// profile) - duplicated rather than imported since it's a private class,
/// kept field-for-field identical to the original so this test exercises
/// the exact same `confirmGhostValue('length', ...)` request/response shapes
/// already proven against the real client code there.
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> lines = {};
  final Map<String, Map<String, dynamic>> sketches = {};
  final Map<String, Map<String, dynamic>> constraints = {};
  int dof = 0;

  String _newId(String prefix) => '$prefix-${_nextId++}';

  http.Response handle(http.Request request) {
    final path = request.url.path;
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    if (path == '/sketch/sketches' && request.method == 'POST') {
      points['origin-1'] = {'id': 'origin-1', 'x': 0.0, 'y': 0.0};
      sketches['sketch-1'] = {'id': 'sketch-1', 'plane': body['plane'], 'origin_point_id': 'origin-1'};
      return _json(sketches['sketch-1']!, 201);
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

    final constraintsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints$').hasMatch(path);
    if (constraintsCollectionMatch && request.method == 'POST') {
      final id = _newId('constraint');
      final constraint = {
        'id': id,
        'point_a_id': body['point_a_id'],
        'point_b_id': body['point_b_id'],
        'distance': (body['distance'] as num).toDouble(),
      };
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
      return _json({
        'status': 'open',
        'detail': 'not a closed loop',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      }, 200);
    }

    return http.Response('not found: ${request.method} $path', 404);
  }

  Map<String, dynamic> _solveResultBody() => {
        'converged': true,
        'dof': dof,
        'result_code': 0,
        'blamed_constraint_ids': [],
        'solver_reported_failed_constraint_ids': [],
        'detail': 'ok',
      };

  http.Response _json(Map<String, dynamic> body, int statusCode) => http.Response(jsonEncode(body), statusCode);
  http.Response _jsonList(List<Map<String, dynamic>> body, int statusCode) =>
      http.Response(jsonEncode(body), statusCode);
}

void main() {
  testWidgets(
    'Confirming a ghost-dimension value removes the still-focused inline editor without crashing',
    (tester) async {
      final backend = _FakeBackend();
      final mockClient = MockClient((request) async => backend.handle(request));
      final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
      await controller.ensureSketch();

      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.finishChain();
      controller.enterDimensionMode();
      await controller.handleCanvasTap(8, 0.1); // away from the line's midpoint (5, 0)
      controller.tapGhost('length');
      expect(controller.activeGhostKey, 'length');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: SketchCanvas(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      // The inline value editor's autofocused TextField is now showing -
      // tapping Confirm here is exactly what removes it
      // (controller.activeGhostKey reverts to null) while it still has
      // focus, which is the scenario that used to trip the framework's
      // '_dependents.isEmpty' assertion.
      await tester.enterText(find.byType(TextField), '25.00');
      await tester.tap(find.widgetWithIcon(IconButton, Icons.check));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.activeGhostKey, isNull);
      expect(controller.ghosts, isEmpty);
    },
  );
}
