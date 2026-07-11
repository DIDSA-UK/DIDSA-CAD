import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_ribbon.dart';

/// A trimmed copy of `sketch_canvas_ghost_editor_test.dart`'s `_FakeBackend`
/// (same duplication convention - a private class, kept field-for-field
/// identical to the endpoints this flow needs: create sketch, create
/// point/line, list points/lines/constraints, create+update distance
/// constraints, solve).
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> lines = {};
  final Map<String, Map<String, dynamic>> sketches = {};
  final Map<String, Map<String, dynamic>> constraints = {};

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

    final constraintItemMatch = RegExp(r'^/sketch/sketches/[^/]+/constraints/(.+)$').firstMatch(path);
    if (constraintItemMatch != null && request.method == 'PATCH') {
      final constraint = constraints[constraintItemMatch.group(1)];
      if (constraint == null) return http.Response('not found', 404);
      constraint['distance'] = (body['distance'] as num).toDouble();
      return _json(constraint, 200);
    }

    final solveMatch = RegExp(r'^/sketch/sketches/[^/]+/solve$').hasMatch(path);
    if (solveMatch && request.method == 'POST') {
      return _json(_solveResultBody(), 200);
    }

    return http.Response('not found: ${request.method} $path', 404);
  }

  Map<String, dynamic> _solveResultBody() => {
        'converged': true,
        'dof': 0,
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
    'Confirming the ribbon\'s Set Length dialog removes the still-focused TextField without crashing',
    (tester) async {
      final backend = _FakeBackend();
      final mockClient = MockClient((request) async => backend.handle(request));
      final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
      await controller.ensureSketch();

      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      // Phase 6.1: off-axis (not (10, 0)) so placement doesn't try to
      // auto-add a HorizontalConstraint - this trimmed fake backend's
      // generic constraints POST handler assumes a `distance` field, which
      // a Horizontal/Vertical constraint payload doesn't have.
      await controller.handleCanvasTap(10, 3);
      controller.finishChain();
      controller.exitToSelectMode();

      // On the line, away from its midpoint and both endpoints - selects
      // just the Line, matching `sketch_controller_test.dart`'s convention
      // for isolating a single-Line selection.
      await controller.handleCanvasTap(8, 2.4);
      expect(controller.selectionSet.length, 1);
      expect(controller.selectionSet.first.kind, SelectionKind.line);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: SketchRibbon(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Length'));
      await tester.pumpAndSettle();

      // The dialog's autofocused TextField is now showing - tapping "Set"
      // here is exactly what removes it (popping the dialog route) while it
      // still has focus, which is the scenario that used to trip the
      // framework's '_dependents.isEmpty' assertion on a real device despite
      // an earlier unfocus()-before-pop fix.
      await tester.enterText(find.byType(TextField), '25.00');
      await tester.tap(find.widgetWithText(FilledButton, 'Set'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(backend.constraints.values.single['distance'], 25.00);
    },
  );
}
