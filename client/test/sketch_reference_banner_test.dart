import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Reference-identity overhaul (`docs/reference-identity-design.md`): the strip under the sketch app bar that makes a lost / potentially-moved reference
/// impossible to miss, and its Fix / Keep all / Cancel actions. A minimal fake backend: one sketch with its origin and one reference Point, the health
/// list `GET .../external-references` reports, and the confirm call.
class _Backend {
  List<Map<String, dynamic>> statuses;
  final List<String> confirmed = [];

  _Backend(this.statuses);

  http.Response handle(http.Request request) {
    final path = request.url.path;
    http.Response json(Object body, [int code = 200]) => http.Response(jsonEncode(body), code);
    if (path == '/sketch/sketches/sketch-1' && request.method == 'GET') {
      return json({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'});
    }
    if (path == '/sketch/sketches/sketch-1/points' && request.method == 'GET') {
      return json([
        {'id': 'origin-1', 'x': 0.0, 'y': 0.0},
        {'id': 'p-ref', 'x': 4.0, 'y': 3.0, 'is_locked': true},
      ]);
    }
    if (path.endsWith('/external-references') && request.method == 'GET') return json(statuses);
    final confirm = RegExp(r'/external-references/([^/]+)/confirm$').firstMatch(path);
    if (confirm != null && request.method == 'POST') {
      confirmed.add(confirm.group(1)!);
      statuses = [];
      return json({'id': confirm.group(1), 'x': 4.0, 'y': 3.0, 'is_locked': true});
    }
    if (request.method == 'GET') return json([]); // every other collection is empty
    return http.Response('not found: ${request.method} $path', 404);
  }
}

Map<String, dynamic> _status(String state, {String reason = ''}) => {
      'point_id': 'p-ref',
      'body_id': 'body-1',
      'vertex_index': 3,
      'status': state,
      'reason': reason,
      'method': 'signature',
      'candidates': <int>[],
    };

Future<(SketchController, _Backend)> _open(WidgetTester tester, List<Map<String, dynamic>> statuses) async {
  final backend = _Backend(statuses);
  final controller = SketchController(api: SketchApiClient(httpClient: MockClient((r) async => backend.handle(r))));
  await controller.adoptSketch('sketch-1', partId: 'part-1', sketchFeatureId: 'feat-1');
  await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller, standalone: true)));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return (controller, backend);
}

void main() {
  const banner = ValueKey('reference-health-banner');

  testWidgets('a healthy sketch shows no reference banner', (tester) async {
    await _open(tester, []);
    expect(find.byKey(banner), findsNothing);
  });

  testWidgets('a lost reference shows a red banner with the reason; Fix starts re-attaching and Cancel leaves it', (tester) async {
    final (controller, _) = await _open(tester, [_status('lost', reason: 'consumed_by_fillet-1')]);

    expect(find.byKey(banner), findsOneWidget);
    expect(find.textContaining('lost'), findsWidgets);
    expect(find.textContaining('removed by an earlier feature'), findsOneWidget);

    await tester.tap(find.text('Fix'));
    await tester.pump();
    expect(controller.isReattaching, isTrue);
    expect(controller.reattachPointId, 'p-ref');
    expect(find.textContaining('Tap the replacement corner'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(controller.isReattaching, isFalse);
    expect(find.text('Fix'), findsOneWidget); // back to the lost-reference banner
  });

  testWidgets('a potentially-moved reference shows an orange banner; Keep all confirms it and the banner goes away', (tester) async {
    final (controller, backend) = await _open(tester, [_status('potentially_moved', reason: 'nearest_of_identical_vertices')]);

    expect(find.byKey(banner), findsOneWidget);
    expect(find.textContaining('may have moved'), findsOneWidget);

    await tester.tap(find.text('Keep all'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.confirmed, ['p-ref']);
    expect(controller.hasFlaggedReferences, isFalse);
    expect(find.byKey(banner), findsNothing);
  });
}
