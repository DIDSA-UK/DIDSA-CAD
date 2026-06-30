import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// Prompt B item B5: a sketch canvas widget test for the fully-constrained
/// padlock indicator. A trimmed copy of `sketch_canvas_ghost_editor_test.dart`'s
/// `_FakeBackend` - just the endpoints needed to place a Point and solve
/// (which is enough to drive [SketchController.isUnderConstrained] off the
/// fake's controllable `dof` field).
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> sketches = {};
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

    final constraintsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints$').hasMatch(path);
    if (constraintsCollectionMatch && request.method == 'GET') {
      return _jsonList(const [], 200);
    }

    final solveMatch = RegExp(r'^/sketch/sketches/[^/]+/solve$').hasMatch(path);
    if (solveMatch && request.method == 'POST') {
      return _json(_solveResultBody(), 200);
    }

    final profileMatch = RegExp(r'^/sketch/sketches/[^/]+/profile$').hasMatch(path);
    if (profileMatch && request.method == 'GET') {
      return _json({
        'status': 'no_loop',
        'detail': 'no entities',
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

Future<SketchController> _controllerAfterASolve(int dof) async {
  final backend = _FakeBackend()..dof = dof;
  final mockClient = MockClient((request) async => backend.handle(request));
  final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
  await controller.ensureSketch();

  controller.selectDrawTool(SketchTool.point);
  await controller.handleCanvasTap(3, 4); // any placement triggers _solveAndTrackDof
  return controller;
}

void main() {
  testWidgets('the fully-constrained padlock badge renders when the last solve reports dof == 0',
      (tester) async {
    final controller = await _controllerAfterASolve(0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 400, child: SketchCanvas(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.text('Fully constrained'), findsOneWidget);
  });

  testWidgets('the fully-constrained padlock badge does not render when dof > 0', (tester) async {
    final controller = await _controllerAfterASolve(1);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 400, child: SketchCanvas(controller: controller)),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.lock), findsNothing);
    expect(find.text('Fully constrained'), findsNothing);
  });
}
