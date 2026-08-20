import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_existing_part_summary.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';

/// AI Modelling: [summarizeExistingPartForPrompt] - on-device feedback fix
/// (the LLM previously saw only "a sketch has been extruded," never the
/// sketch's real shape/size). Covers: real geometry actually reaches the
/// summary, construction-only geometry is skipped, an empty Sketch reads as
/// empty rather than blank, and a Body-producing Feature points back at the
/// Sketch it came from.
void main() {
  http.Response jsonResponse(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  MockClient buildMock(Map<String, Object> sketchEntitiesByPath) {
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/document/parts/part-1/features') {
        return jsonResponse([
          {'type': 'sketch', 'id': 'feat-sk1', 'locked': false, 'sketch_id': 'sketch-1', 'produces': 'sketch'},
          {
            'type': 'extrude',
            'id': 'feat-ex1',
            'locked': false,
            'sketch_feature_id': 'feat-sk1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'produces': 'body',
          },
        ]);
      }
      if (sketchEntitiesByPath.containsKey(path)) return jsonResponse(sketchEntitiesByPath[path]!);
      if (path.startsWith('/sketch/sketches/sketch-1/')) return jsonResponse(<Object>[]);
      return http.Response('not found', 404);
    });
  }

  test('a rectangle profile reaches the summary with its real width/height', () async {
    final mock = buildMock({
      '/sketch/sketches/sketch-1/points': [
        {'id': 'p1', 'x': 0.0, 'y': 0.0},
        {'id': 'p2', 'x': 60.0, 'y': 0.0},
        {'id': 'p3', 'x': 60.0, 'y': 40.0},
        {'id': 'p4', 'x': 0.0, 'y': 40.0},
      ],
      '/sketch/sketches/sketch-1/rectangles': [
        {
          'id': 'r1',
          'corner_point_ids': ['p1', 'p2', 'p3', 'p4'],
          'line_ids': ['l1', 'l2', 'l3', 'l4'],
          'axis_aligned': true,
        },
      ],
    });
    final documentApi = DocumentApiClient(httpClient: mock);
    final sketchApi = SketchApiClient(httpClient: mock);
    final features = await documentApi.listFeatures('part-1');

    final summary = await summarizeExistingPartForPrompt(sketchApi, features);

    expect(summary, contains('rectangle 60x40mm'));
    // The extrude points back at the sketch it came from, not just its own
    // boss/cut numbers in isolation.
    expect(summary, contains('from existing:feat-sk1'));
    expect(summary, contains('existing:feat-sk1'));
    expect(summary, contains('existing:feat-ex1'));
  });

  test('a circle profile reaches the summary with its real radius and center', () async {
    final mock = buildMock({
      '/sketch/sketches/sketch-1/points': [
        {'id': 'p1', 'x': 10.0, 'y': 5.0},
        {'id': 'p2', 'x': 18.0, 'y': 5.0},
      ],
      '/sketch/sketches/sketch-1/circles': [
        {'id': 'c1', 'center_point_id': 'p1', 'radius_point_id': 'p2', 'radius': 8.0},
      ],
    });
    final documentApi = DocumentApiClient(httpClient: mock);
    final sketchApi = SketchApiClient(httpClient: mock);
    final features = await documentApi.listFeatures('part-1');

    final summary = await summarizeExistingPartForPrompt(sketchApi, features);

    expect(summary, contains('circle r=8mm'));
    expect(summary, contains('centered at (10,5)'));
  });

  test('construction-only geometry is excluded from the summary', () async {
    final mock = buildMock({
      '/sketch/sketches/sketch-1/points': [
        {'id': 'p1', 'x': 0.0, 'y': 0.0},
        {'id': 'p2', 'x': 5.0, 'y': 0.0},
      ],
      '/sketch/sketches/sketch-1/circles': [
        {'id': 'c1', 'center_point_id': 'p1', 'radius_point_id': 'p2', 'radius': 5.0, 'construction': true},
      ],
    });
    final documentApi = DocumentApiClient(httpClient: mock);
    final sketchApi = SketchApiClient(httpClient: mock);
    final features = await documentApi.listFeatures('part-1');

    final summary = await summarizeExistingPartForPrompt(sketchApi, features);

    expect(summary, isNot(contains('circle')));
    expect(summary, contains('empty (no real geometry yet)'));
  });

  test('a Sketch with no entities at all reads as empty, not blank', () async {
    final mock = buildMock({});
    final documentApi = DocumentApiClient(httpClient: mock);
    final sketchApi = SketchApiClient(httpClient: mock);
    final features = await documentApi.listFeatures('part-1');

    final summary = await summarizeExistingPartForPrompt(sketchApi, features);

    expect(summary, contains('empty (no real geometry yet)'));
  });
}
