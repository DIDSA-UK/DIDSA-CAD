import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Bug-fix round: a widget test for the "fully constrained" padlock
/// indicator, now in [SketchScreen]'s AppBar title (moved out of the
/// canvas overlay, where it used to render behind the Exit Sketch FAB). A
/// trimmed copy of `sketch_canvas_ghost_editor_test.dart`'s `_FakeBackend` -
/// just the endpoints needed to place a Line and solve (which is enough to
/// drive [SketchController.isUnderConstrained]/[SketchController.hasGeometry]
/// off the fake's controllable `dof` field).
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> lines = {};
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

Future<SketchController> _controllerWithALineAfterASolve(int dof) async {
  final backend = _FakeBackend()..dof = dof;
  final mockClient = MockClient((request) async => backend.handle(request));
  final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
  await controller.ensureSketch();

  controller.selectDrawTool(SketchTool.line);
  await controller.handleCanvasTap(0, 0);
  await controller.handleCanvasTap(10, 0);
  controller.finishChain();
  return controller;
}

Future<void> _pumpSketchScreen(WidgetTester tester, SketchController controller) async {
  await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
  await tester.pump();
}

void main() {
  testWidgets('the closed padlock icon renders in the title bar when the sketch has geometry '
      'and the last solve reports dof == 0', (tester) async {
    final controller = await _controllerWithALineAfterASolve(0);

    await _pumpSketchScreen(tester, controller);

    expect(find.byIcon(Icons.lock), findsOneWidget);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });

  testWidgets(
      'bug-fix: the open padlock icon renders (rather than no icon at all) when dof > 0, so '
      'under-constrained is visibly distinct from "no geometry yet"', (tester) async {
    final controller = await _controllerWithALineAfterASolve(1);

    await _pumpSketchScreen(tester, controller);

    expect(find.byIcon(Icons.lock_open), findsOneWidget);
    expect(find.byIcon(Icons.lock), findsNothing);
  });

  testWidgets(
      'neither padlock icon renders for an empty sketch, even though dof == 0 (bug-fix round: '
      'a brand-new sketch has nothing to be "fully constrained" or "under-constrained")', (tester) async {
    final backend = _FakeBackend()..dof = 0;
    final mockClient = MockClient((request) async => backend.handle(request));
    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
    await controller.ensureSketch();

    await _pumpSketchScreen(tester, controller);

    expect(controller.hasGeometry, isFalse);
    expect(find.byIcon(Icons.lock), findsNothing);
    expect(find.byIcon(Icons.lock_open), findsNothing);
  });
}
