// Touch-style drag gestures through the REAL SketchCanvas against the REAL backend (HTTP), no fake.
//
//   DIDSA_LIVE_URL=http://127.0.0.1:8000 DIDSA_LIVE_KEY=test-api-key flutter test test/live_touch_drag_test.dart
//
// (start the backend e.g. with tools/gui_harness/run.sh). Skipped without DIDSA_LIVE_URL, so CI never runs it.
//
// The pointers are genuine PointerDeviceKind.touch streams, so the canvas takes its touch path: relative cursor movement scaled
// by SketchController.touchSensitivity / zoom, a tap acts at the *cursor* (trackpad style), and in drag mode a tap grabs the
// entity under the cursor, a swipe moves it, a tap drops it. Not a physical touchscreen (Xvfb has no touch device), but the
// same gesture code the phone runs.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/config.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

final String? _url = Platform.environment['DIDSA_LIVE_URL'];
final String _key = Platform.environment['DIDSA_LIVE_KEY'] ?? 'test-api-key';

Future<Map<String, dynamic>> _post(http.Client c, String path, Map<String, dynamic> body) async {
  final r = await c.post(Uri.parse('$_url$path'),
      headers: {'X-API-Key': _key, 'Content-Type': 'application/json'}, body: jsonEncode(body));
  if (r.statusCode >= 300) fail('POST $path -> ${r.statusCode} ${r.body}');
  return jsonDecode(r.body) as Map<String, dynamic>;
}

void main() {
  if (_url == null) {
    test('live touch drag (set DIDSA_LIVE_URL)', () {}, skip: true);
    return;
  }

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiConfig.save(baseUrl: _url!, apiKey: _key);
  });

  Future<void> tap(WidgetTester tester) async {
    final g = await tester.startGesture(const Offset(640, 360), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 40));
    await g.up();
    await tester.pump(const Duration(milliseconds: 40));
  }

  /// One finger swipe of [steps] moves of [delta] pixels each, with [onStep] after every move.
  Future<void> swipe(WidgetTester tester, int steps, Offset Function(int) delta, void Function(int) onStep) async {
    final g = await tester.startGesture(const Offset(640, 360), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 16));
    for (var i = 0; i < steps; i++) {
      await g.moveBy(delta(i));
      await tester.pump(const Duration(milliseconds: 16));
      onStep(i);
    }
    await g.up();
    await tester.pump(const Duration(milliseconds: 40));
  }

  double dist(SketchController c, String a, String b) {
    final pa = c.points[a]!, pb = c.points[b]!;
    return math.sqrt(math.pow(pb.x - pa.x, 2) + math.pow(pb.y - pa.y, 2));
  }

  testWidgets('hexagon with a horizontal edge: a touch grab-swipe-drop of a vertex keeps it regular and horizontal', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      final http.Client client = IOClient(HttpClient());
      final creator = SketchController(api: SketchApiClient(httpClient: client));
      await creator.ensureSketch();
      final sid = creator.sketchId!;
      final B = '/sketch/sketches/$sid';
      final c = await _post(client, '$B/points', {'x': -4.0, 'y': 6.0});
      final v = await _post(client, '$B/points', {'x': 4.0, 'y': 6.0});
      final poly = await _post(client, '$B/polygons', {'center_point_id': c['id'], 'first_vertex_point_id': v['id'], 'sides': 6});
      await _post(client, '$B/constraints', {'type': 'horizontal', 'line_id': (poly['line_ids'] as List)[1]});
      // open it the way the app opens an existing sketch: a fresh controller adopting it from the backend
      final controller = SketchController(api: SketchApiClient(httpClient: client));
      await controller.adoptSketch(sid);
      final polygon = controller.polygons.values.single;
      expect(polygon.structuralConstraintIds, isNotEmpty, reason: 'the client learned the polygon from the real backend');

      final viewport = await pumpCanvasAsync(tester, controller);
      controller.toggleDragMode();
      final vertex = polygon.vertexPointIds[0];
      final p0 = controller.points[vertex]!;
      controller.cursorX = p0.x;
      controller.cursorY = p0.y;
      await tap(tester); // touch tap at the cursor: grab
      expect(controller.isEntityGrabbed, isTrue, reason: 'a touch tap in drag mode grabs the vertex under the cursor');

      controller.dragStats.reset();
      final steps = <double>[];
      var last = (p0.x, p0.y);
      // swipe in an arc: 70 moves of ~9 px, turning 4 degrees per move
      await swipe(tester, 70, (i) {
        final a = i * 4 * math.pi / 180;
        return Offset(9 * math.cos(a), -9 * math.sin(a));
      }, (i) {
        final pt = controller.points[vertex]!;
        steps.add(math.sqrt(math.pow(pt.x - last.$1, 2) + math.pow(pt.y - last.$2, 2)));
        last = (pt.x, pt.y);
        final e = controller.lines[polygon.lineIds[1]]!;
        final a = controller.points[e.startPointId]!, b = controller.points[e.endPointId]!;
        expect((b.y - a.y).abs(), lessThan(1e-3), reason: 'the horizontal edge holds on every touch frame ($i)');
        final radii = [for (final id in polygon.vertexPointIds) dist(controller, polygon.centerPointId, id)];
        for (final r in radii) {
          expect(r, closeTo(radii.first, 1e-3), reason: 'still regular on frame $i');
        }
      });
      await tap(tester); // drop
      expect(controller.isEntityGrabbed, isFalse);
      // ignore: avoid_print
      print('touch hexagon: zoom=${viewport.zoom().toStringAsFixed(2)} ${controller.dragStats} moved=${steps.fold<double>(0, (s, e) => s + e).toStringAsFixed(2)} units');
      expect(controller.dragStats.frames, greaterThan(30), reason: 'the swipe produced clamped drag frames');
      expect(controller.dragStats.rejected, 0);
      expect(controller.errorMessage, isNull);
      // the backend's authoritative state after the drop
      await Future<void>.delayed(const Duration(milliseconds: 800)); // the drop's solve is fire-and-forget in the canvas
      final pts = await client.get(Uri.parse('$_url$B/points'), headers: {'X-API-Key': _key});
      expect(pts.statusCode, 200);
      final byId = {for (final p in jsonDecode(pts.body) as List) (p as Map<String, dynamic>)['id'] as String: p};
      for (final id in polygon.vertexPointIds) {
        final client_ = controller.points[id]!;
        expect((byId[id]!['x'] as num).toDouble(), closeTo(client_.x, 1e-3), reason: 'backend vertex x == client after the drop');
        expect((byId[id]!['y'] as num).toDouble(), closeTo(client_.y, 1e-3), reason: 'backend vertex y == client after the drop');
      }
    });
  });

  testWidgets('circle with its centre dimensioned to a point: a touch swipe slides the centre along the dimension', (tester) async {
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      final http.Client client = IOClient(HttpClient());
      final creator = SketchController(api: SketchApiClient(httpClient: client));
      await creator.ensureSketch();
      final sid = creator.sketchId!;
      final B = '/sketch/sketches/$sid';
      final anchor = await _post(client, '$B/points', {'x': 9.0, 'y': 0.0});
      final centre = await _post(client, '$B/points', {'x': -6.0, 'y': 0.0});
      final rim = await _post(client, '$B/points', {'x': -2.0, 'y': 0.0});
      await _post(client, '$B/circles', {'center_point_id': centre['id'], 'radius_point_id': rim['id']});
      await _post(client, '$B/constraints', {'point_a_id': centre['id'], 'point_b_id': anchor['id'], 'distance': 15.0});
      // open it the way the app opens an existing sketch: a fresh controller adopting it from the backend
      final controller = SketchController(api: SketchApiClient(httpClient: client));
      await controller.adoptSketch(sid);
      final circle = controller.circles.values.single;

      await pumpCanvasAsync(tester, controller);
      controller.toggleDragMode();
      final c0 = controller.points[circle.centerPointId]!;
      controller.cursorX = c0.x;
      controller.cursorY = c0.y;
      await tap(tester);
      expect(controller.isEntityGrabbed, isTrue);
      controller.dragStats.reset();
      await swipe(tester, 60, (i) => Offset(-8 * math.cos(i * 0.05), -8 * math.sin(i * 0.05) - 4), (i) {
        expect(dist(controller, circle.centerPointId, anchor['id'] as String), closeTo(15, 1e-3), reason: 'dimension holds on frame $i');
        expect(dist(controller, circle.centerPointId, circle.radiusPointId), closeTo(4, 0.05), reason: 'circle keeps its size');
      });
      await tap(tester);
      // ignore: avoid_print
      print('touch circle: ${controller.dragStats}');
      expect(controller.dragStats.frames, greaterThan(20));
      expect(controller.dragStats.rejected, 0);
      expect(controller.errorMessage, isNull);
    });
  });

  // Reference-geometry sketch (needs the harness backend with tools/gui_harness/scenarios/ref_part.py already run; DIDSA_REF_IDS points
  // at the ref_ids.json it wrote). Free end dimensioned (8.00) to a LOCKED reference at the box's far corner.
  final refIds = Platform.environment['DIDSA_REF_IDS'];
  testWidgets('reference sketch: the free end orbits the locked reference, the reference refuses a grab, upstream edits are reported', (tester) async {
    if (refIds == null) return;
    await tester.runAsync(() async {
      HttpOverrides.global = null;
      final http.Client client = IOClient(HttpClient());
      final ids = jsonDecode(File(refIds).readAsStringSync()) as Map<String, dynamic>;
      final part = ids['part'] as String, feat = ids['sketch2'] as String;
      final controller = SketchController(api: SketchApiClient(httpClient: client));
      await controller.adoptSketch(ids['sketch2_sk'] as String, partId: part, sketchFeatureId: feat);
      final ref = ids['ref'] as String, free = ids['free'] as String;
      final r0 = controller.points[ref]!;

      // grabbing the locked reference is refused
      controller.cursorX = r0.x;
      controller.cursorY = r0.y;
      expect(controller.beginPointDrag(ref), isFalse);

      // the free end: orbit it 270 degrees around the reference at 8 units, then pull it far away (radial)
      final f0 = controller.points[free]!;
      controller.cursorX = f0.x;
      controller.cursorY = f0.y;
      expect(controller.beginPointDrag(free), isTrue);
      controller.dragStats.reset();
      final a0 = math.atan2(f0.y - r0.y, f0.x - r0.x);
      var worstLen = 0.0, worstRef = 0.0;
      for (var i = 1; i <= 90; i++) {
        final a = a0 + i * 3 * math.pi / 180;
        final rad = i < 60 ? 8.0 : 8.0 + (i - 60) * 0.5; // the last 30 frames pull outwards: must stay on the 8.00 circle
        await controller.updatePointDrag(r0.x + rad * math.cos(a), r0.y + rad * math.sin(a));
        final f = controller.points[free]!, r = controller.points[ref]!;
        worstLen = math.max(worstLen, (math.sqrt(math.pow(f.x - r.x, 2) + math.pow(f.y - r.y, 2)) - 8).abs());
        worstRef = math.max(worstRef, math.sqrt(math.pow(r.x - r0.x, 2) + math.pow(r.y - r0.y, 2)));
      }
      await controller.endPointDrag();
      // ignore: avoid_print
      print('reference orbit: ${controller.dragStats} worst |len-8|=${worstLen.toStringAsExponential(2)} reference moved=${worstRef.toStringAsExponential(2)}');
      expect(worstLen, lessThan(1e-3));
      expect(worstRef, 0.0, reason: 'the locked reference never moves');
      expect(controller.dragStats.rejected, 0);
      expect(controller.errorMessage, isNull);

      // upstream edit: change the extrude height (moves nothing in XY, the corner stays) then re-target the fillet to another edge
      Future<Map<String, dynamic>> patch(String path, Map<String, dynamic> body) async {
        final r = await client.patch(Uri.parse('$_url$path'), headers: {'X-API-Key': _key, 'Content-Type': 'application/json'}, body: jsonEncode(body));
        return {'status': r.statusCode, 'body': r.body};
      }
      final e = await patch('/document/parts/$part/extrude-features/${ids['extrude']}', {'end_distance': 14.0});
      // ignore: avoid_print
      print('extrude PATCH -> ${e['status']}');
      await controller.refreshReferenceStatuses();
      // ignore: avoid_print
      print('after extrude edit: lost=${controller.lostReferencePointIds} moved=${controller.movedReferencePointIds} status=${controller.referenceStatusOf(ref)?.status}');
    });
  });
}

Future<({double Function() zoom, Offset Function() pan})> pumpCanvasAsync(WidgetTester tester, SketchController controller) async {
  var zoom = 1.0;
  var pan = Offset.zero;
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SketchCanvas(
        controller: controller,
        onViewportChanged: (p, z, s) {
          pan = p;
          zoom = z;
        },
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 200));
  return (zoom: () => zoom, pan: () => pan);
}
