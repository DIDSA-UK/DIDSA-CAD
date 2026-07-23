import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/local_solver/slvs_bindings.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart' show dimensionLabelAt;
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/view_transform.dart';

/// Milestone B/E's host-built didsa_slvs_ffi library, if it's been built
/// (see client/native/slvs/CMakeLists.txt's own header comment for the
/// two-step recipe) - lets the tests below exercise the actual in-process
/// solve path engaging during a drag, not just its server-round-trip
/// fallback (which every other drag test in this file already covers).
String? _findHostSlvsLibrary() {
  for (final relative in [
    'native/slvs/build-host/libdidsa_slvs_ffi.dll',
    'native/slvs/build-host/libdidsa_slvs_ffi.so',
    'native/slvs/build-host/libdidsa_slvs_ffi.dylib',
  ]) {
    final file = File(relative);
    if (file.existsSync()) return file.absolute.path;
  }
  return null;
}

/// A tiny in-memory fake of the backend's `/sketch` API (point/line/circle
/// creation, constraints, get, solve) good enough to exercise the
/// controller's chaining and dimension-ghost-confirmation logic without any
/// real network call.
class _FakeBackend {
  int _nextId = 1;
  final Map<String, Map<String, dynamic>> points = {};
  final Map<String, Map<String, dynamic>> lines = {};
  final Map<String, Map<String, dynamic>> circles = {};
  final Map<String, Map<String, dynamic>> arcs = {};
  final Map<String, Map<String, dynamic>> ellipses = {};
  final Map<String, Map<String, dynamic>> polygons = {};
  final Map<String, Map<String, dynamic>> slots = {};
  final Map<String, Map<String, dynamic>> rectangles = {};
  final Map<String, Map<String, dynamic>> splines = {};
  final Map<String, Map<String, dynamic>> texts = {};
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

  /// Sketcher-roadmap Phase 4.3 v1: how many times the materialize-a-
  /// Body-vertex endpoint has actually been hit - lets a test assert a
  /// re-pick of the same ghost vertex reused the cached Point rather than
  /// making a second network round trip.
  int externalReferenceRequestCount = 0;

  /// Sketcher-roadmap Phase 4.3 v2: the materialize-a-Body-edge endpoint's
  /// own request counter, mirroring [externalReferenceRequestCount].
  int externalEdgeReferenceRequestCount = 0;

  /// P48 (Sketcher-roadmap Phase 9 v1, Convert Entities): the convert-a-
  /// Body-vertex endpoint's own request counter, mirroring
  /// [externalReferenceRequestCount].
  int convertVertexRequestCount = 0;

  /// P48's edge-shaped sibling to [convertVertexRequestCount].
  int convertEdgeRequestCount = 0;

  /// On-device feedback ("when deleting lines, curves, trimming I end up
  /// with floating, redundant points"): every fake `DELETE .../lines|
  /// circles|arcs|ellipses|polygons|splines|texts/{id}` route reports this
  /// as its own `pruned_point_ids` - empty by default (matching every
  /// existing test's own assumption that nothing gets auto-pruned), set by
  /// a test that specifically wants to exercise the controller's own
  /// pruned-id handling for a single delete call. Shared across every
  /// entity kind (not per-kind) since no existing test deletes more than
  /// one entity kind in the same assertion window.
  List<String> prunedPointIdsOnNextDelete = const [];

  /// Actually removes [prunedPointIdsOnNextDelete] from this fake's own
  /// `points` storage (not just reporting them in a delete response) -
  /// mirrors the real backend's `Sketch._prune_orphaned_points` truly
  /// deleting them, so a later `solveAndRefresh` (which re-fetches every
  /// Point wholesale, see `SketchController._solveAndTrackDof`) doesn't
  /// resurrect one this fake only pretended to prune. Every delete route
  /// below should return this (not read the field directly), so the
  /// side effect and the reported ids can never drift apart.
  List<String> _reportAndApplyPrunedPoints() {
    final pruned = prunedPointIdsOnNextDelete;
    for (final id in pruned) {
      points.remove(id);
    }
    return pruned;
  }

  /// P48: mirrors the real backend's `Sketch.add_or_reuse_point` - keyed by
  /// `'bodyId:vertexIndex'` (this fake's deterministic x/y derivation from
  /// those two values makes that an equivalent key to the real thing's
  /// position-epsilon match), so a test can exercise the client's own
  /// "backend returned an id I already have - don't double it up" handling.
  final Map<String, String> _convertedVertexPointIds = {};

  /// Sketcher-roadmap Phase 11: the coordinate `/lines/{id}/trim` should
  /// report as the chosen intersection - set by the test before calling
  /// [SketchController.handleCanvasTap] in trim mode, mirroring the real
  /// `Sketch.trim_or_extend_line`'s own "nearest intersection" result
  /// without reimplementing its geometry here. Null means "nothing to
  /// trim/extend to" (a 422, same as the real endpoint's
  /// `NoIntersectionFoundError`).
  (double, double)? trimTargetPoint;

  /// On-device feedback follow-up (P37): the two crossing coordinates
  /// `/lines/{id}/split-trim` should report - set by a test that wants to
  /// exercise the split path; null (the default) means "not bracketed by
  /// two interior crossings" (a 422), matching every existing trim test's
  /// own single-endpoint-only setup via [trimTargetPoint] - the client's
  /// own fallback to `/trim` is exercised by every one of those, not just
  /// a dedicated split test.
  ((double, double), (double, double))? splitTrimTargets;

  /// On-device feedback follow-up (P36): the resolved touch point
  /// `/circles/{id}/trim`/`/arcs/{id}/trim` should report - mirrors
  /// [trimTargetPoint]'s own "set by the test, null means 422" contract.
  (double, double)? curveTrimTargetPoint;

  String _newId(String prefix) => '$prefix-${_nextId++}';

  /// A deterministic fake outline for [text]'s preview endpoint - a single
  /// rectangle (no holes), sized from its content length/size and placed
  /// relative to its anchor Point via the same rotate-then-translate
  /// formula the real backend's `place_local_point` uses, so tests
  /// exercising rotation/anchor-drag see a real (if not font-accurate)
  /// shape rather than a hardcoded stand-in.
  List<Map<String, dynamic>> textPreviewContours(Map<String, dynamic> text) {
    final anchor = points[text['anchor_point_id'] as String]!;
    final ax = (anchor['x'] as num).toDouble();
    final ay = (anchor['y'] as num).toDouble();
    final size = (text['size'] as num).toDouble();
    final content = text['content'] as String;
    final width = content.length * size * 0.6;
    final rotation = (text['rotation_degrees'] as num).toDouble() * math.pi / 180;
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final localCorners = [(0.0, 0.0), (width, 0.0), (width, size), (0.0, size)];
    final placed = [
      for (final (x, y) in localCorners) [ax + x * cosR - y * sinR, ay + x * sinR + y * cosR],
    ];
    return [
      {'outer': placed, 'holes': <List<List<double>>>[]},
    ];
  }

  /// Seeds a Sketch (and its origin Point) as if it had already been
  /// created server-side - e.g. via a SketchFeature - so [adoptSketch] has
  /// something to GET without this fake backend having handled a prior
  /// `POST /sketch/sketches` itself.
  void seedSketch(String sketchId, String originPointId) {
    sketches[sketchId] = {'id': sketchId, 'plane': 'XY', 'origin_point_id': originPointId};
    points[originPointId] = {'id': originPointId, 'x': 0.0, 'y': 0.0};
  }

  /// Resolves a Circle or Arc id to its (centre, radius-defining rim) Point
  /// id pair - mirrors the real backend's Sketch._center_radius_point_ids
  /// (an Arc's own start Point, a Circle's own radius Point), just enough
  /// for this fake's 'tangent'/'equal_radius' constraint cases below.
  (String, String) _centerRadiusPointIds(String entityId) {
    final circle = circles[entityId];
    if (circle != null) {
      return (circle['center_point_id'] as String, circle['radius_point_id'] as String);
    }
    final arc = arcs[entityId]!;
    return (arc['center_point_id'] as String, arc['start_point_id'] as String);
  }

  http.Response handle(http.Request request) {
    final path = request.url.path;
    requestLog.add('${request.method} $path');
    final body = request.body.isEmpty ? <String, dynamic>{} : jsonDecode(request.body) as Map<String, dynamic>;

    final lineDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/(.+)$').firstMatch(path);
    if (lineDeleteMatch != null && request.method == 'DELETE') {
      lines.remove(lineDeleteMatch.group(1));
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final linePatchMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/(.+)$').firstMatch(path);
    if (linePatchMatch != null && request.method == 'PATCH') {
      final line = lines[linePatchMatch.group(1)];
      if (line == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        line['construction'] = body['construction'] as bool;
      }
      if (body.containsKey('length')) {
        line['length'] = (body['length'] as num).toDouble();
      }
      return _json(line, 200);
    }

    final circleDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/circles/(.+)$').firstMatch(path);
    if (circleDeleteMatch != null && request.method == 'DELETE') {
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final arcDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/arcs/(.+)$').firstMatch(path);
    if (arcDeleteMatch != null && request.method == 'DELETE') {
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final ellipseDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/ellipses/(.+)$').firstMatch(path);
    if (ellipseDeleteMatch != null && request.method == 'DELETE') {
      ellipses.remove(ellipseDeleteMatch.group(1));
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final ellipsePatchMatch = RegExp(r'^/sketch/sketches/[^/]+/ellipses/(.+)$').firstMatch(path);
    if (ellipsePatchMatch != null && request.method == 'PATCH') {
      final ellipse = ellipses[ellipsePatchMatch.group(1)];
      if (ellipse == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        ellipse['construction'] = body['construction'] as bool;
      }
      return _json(ellipse, 200);
    }

    final polygonDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/polygons/(.+)$').firstMatch(path);
    if (polygonDeleteMatch != null && request.method == 'DELETE') {
      final polygon = polygons.remove(polygonDeleteMatch.group(1));
      if (polygon != null) {
        for (final lineId in (polygon['line_ids'] as List).cast<String>()) {
          lines.remove(lineId);
        }
        for (final constraintId in (polygon['_constraint_ids'] as List).cast<String>()) {
          constraints.remove(constraintId);
        }
      }
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    // On-device feedback ("cascadeing deletion needs more finesse..."):
    // discards only the wrapper bookkeeping record - its own Lines/Arcs/
    // Points/Constraints are left untouched, mirroring the real backend's
    // `Sketch.collapse_polygon`/`collapse_slot`/`collapse_rectangle`.
    final polygonCollapseMatch = RegExp(r'^/sketch/sketches/[^/]+/polygons/([^/]+)/collapse$').firstMatch(path);
    if (polygonCollapseMatch != null && request.method == 'POST') {
      polygons.remove(polygonCollapseMatch.group(1));
      return http.Response('', 204);
    }

    final polygonPatchMatch = RegExp(r'^/sketch/sketches/[^/]+/polygons/(.+)$').firstMatch(path);
    if (polygonPatchMatch != null && request.method == 'PATCH') {
      final polygon = polygons[polygonPatchMatch.group(1)];
      if (polygon == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        polygon['construction'] = body['construction'] as bool;
      }
      return _json(polygon, 200);
    }

    final slotDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/slots/(.+)$').firstMatch(path);
    if (slotDeleteMatch != null && request.method == 'DELETE') {
      final slot = slots.remove(slotDeleteMatch.group(1));
      if (slot != null) {
        for (final entityId in [
          slot['centerline_id'],
          slot['arc1_id'],
          slot['arc2_id'],
          slot['line1_id'],
          slot['line2_id'],
        ]) {
          lines.remove(entityId);
          arcs.remove(entityId);
        }
        for (final constraintId in (slot['_constraint_ids'] as List).cast<String>()) {
          constraints.remove(constraintId);
        }
      }
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final slotCollapseMatch = RegExp(r'^/sketch/sketches/[^/]+/slots/([^/]+)/collapse$').firstMatch(path);
    if (slotCollapseMatch != null && request.method == 'POST') {
      slots.remove(slotCollapseMatch.group(1));
      return http.Response('', 204);
    }

    final slotPatchMatch = RegExp(r'^/sketch/sketches/[^/]+/slots/(.+)$').firstMatch(path);
    if (slotPatchMatch != null && request.method == 'PATCH') {
      final slot = slots[slotPatchMatch.group(1)];
      if (slot == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        slot['construction'] = body['construction'] as bool;
      }
      return _json(slot, 200);
    }

    final rectangleDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/rectangles/(.+)$').firstMatch(path);
    if (rectangleDeleteMatch != null && request.method == 'DELETE') {
      final rectangle = rectangles.remove(rectangleDeleteMatch.group(1));
      if (rectangle != null) {
        for (final lineId in (rectangle['line_ids'] as List).cast<String>()) {
          lines.remove(lineId);
        }
        final diagonalLineId = rectangle['diagonal_line_id'] as String?;
        if (diagonalLineId != null) lines.remove(diagonalLineId);
        final diagonal2LineId = rectangle['diagonal2_line_id'] as String?;
        if (diagonal2LineId != null) lines.remove(diagonal2LineId);
        for (final constraintId in (rectangle['_constraint_ids'] as List).cast<String>()) {
          constraints.remove(constraintId);
        }
      }
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final rectangleCollapseMatch =
        RegExp(r'^/sketch/sketches/[^/]+/rectangles/([^/]+)/collapse$').firstMatch(path);
    if (rectangleCollapseMatch != null && request.method == 'POST') {
      rectangles.remove(rectangleCollapseMatch.group(1));
      return http.Response('', 204);
    }

    final rectanglePatchMatch = RegExp(r'^/sketch/sketches/[^/]+/rectangles/(.+)$').firstMatch(path);
    if (rectanglePatchMatch != null && request.method == 'PATCH') {
      final rectangle = rectangles[rectanglePatchMatch.group(1)];
      if (rectangle == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        rectangle['construction'] = body['construction'] as bool;
      }
      return _json(rectangle, 200);
    }

    final splineDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/splines/(.+)$').firstMatch(path);
    if (splineDeleteMatch != null && request.method == 'DELETE') {
      splines.remove(splineDeleteMatch.group(1));
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final splinePatchMatch = RegExp(r'^/sketch/sketches/[^/]+/splines/(.+)$').firstMatch(path);
    if (splinePatchMatch != null && request.method == 'PATCH') {
      final spline = splines[splinePatchMatch.group(1)];
      if (spline == null) return http.Response('not found', 404);
      if (body.containsKey('construction')) {
        spline['construction'] = body['construction'] as bool;
      }
      return _json(spline, 200);
    }

    final textPreviewMatch =
        RegExp(r'^/sketch/sketches/[^/]+/texts/([^/]+)/preview$').firstMatch(path);
    if (textPreviewMatch != null && request.method == 'GET') {
      final text = texts[textPreviewMatch.group(1)];
      if (text == null) return http.Response('not found', 404);
      return _json({'contours': textPreviewContours(text)}, 200);
    }

    final textDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/texts/(.+)$').firstMatch(path);
    if (textDeleteMatch != null && request.method == 'DELETE') {
      texts.remove(textDeleteMatch.group(1));
      return _json({'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final textPatchMatch = RegExp(r'^/sketch/sketches/[^/]+/texts/(.+)$').firstMatch(path);
    if (textPatchMatch != null && request.method == 'PATCH') {
      final text = texts[textPatchMatch.group(1)];
      if (text == null) return http.Response('not found', 404);
      if (body.containsKey('content')) text['content'] = body['content'] as String;
      if (body.containsKey('font')) text['font'] = body['font'] as String;
      if (body.containsKey('size')) text['size'] = (body['size'] as num).toDouble();
      if (body.containsKey('rotation_degrees')) {
        text['rotation_degrees'] = (body['rotation_degrees'] as num).toDouble();
      }
      if (body.containsKey('construction')) text['construction'] = body['construction'] as bool;
      return _json(text, 200);
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
        // Mirrors the real backend: any explicit value PATCH confirms the
        // constraint, clearing `provisional` (see update_constraint_value).
        constraint['provisional'] = false;
        // Task #94: a Polygon/Slot's own circumradius DistanceConstraint
        // (centre to vertex 0 / centre1 to corner a) is the *only* thing
        // pinning the shape's absolute size - equal-length/equal-radius/
        // angle/tangent alone only fix its shape, not its scale - so
        // resizing it uniformly scales every vertex/corner about the
        // centre, same as a real solve would settle to. Good enough to
        // exercise the client's own vertex-drag-as-dimension-edit logic
        // against real, moved geometry rather than just a stored
        // constraint value. Scaled from each vertex's own *current* actual
        // distance from centre, not the constraint's old stored value -
        // the sketcher rebuild's closed-form drag path already PATCHes
        // every point to its correct final position directly, *before*
        // this PATCH fires (see SketchController._settleClosedFormShapeDrag),
        // so scaling from the old stored value here would double-apply the
        // resize on top of already-correct geometry.
        double distance(Map<String, dynamic> a, Map<String, dynamic> b) => math.sqrt(
              math.pow((b['x'] as num).toDouble() - (a['x'] as num).toDouble(), 2) +
                  math.pow((b['y'] as num).toDouble() - (a['y'] as num).toDouble(), 2),
            );
        void scaleAbout(Map<String, dynamic> center, Iterable<String> vertexIds, double currentRadius) {
          if (currentRadius <= 1e-9) return;
          final cx = (center['x'] as num).toDouble();
          final cy = (center['y'] as num).toDouble();
          final scale = value / currentRadius;
          for (final vertexId in vertexIds) {
            final vertex = points[vertexId]!;
            vertex['x'] = cx + ((vertex['x'] as num).toDouble() - cx) * scale;
            vertex['y'] = cy + ((vertex['y'] as num).toDouble() - cy) * scale;
          }
        }

        for (final polygon in polygons.values) {
          final vertexPointIds = (polygon['vertex_point_ids'] as List).cast<String>();
          if (polygon['center_point_id'] == constraint['point_a_id'] &&
              vertexPointIds.first == constraint['point_b_id']) {
            final center = points[polygon['center_point_id']]!;
            scaleAbout(center, vertexPointIds, distance(center, points[vertexPointIds.first]!));
            break;
          }
        }
        for (final slot in slots.values) {
          if (slot['center1_point_id'] == constraint['point_a_id'] && slot['a_point_id'] == constraint['point_b_id']) {
            final center1 = points[slot['center1_point_id'] as String]!;
            final center2 = points[slot['center2_point_id'] as String]!;
            final aId = slot['a_point_id'] as String;
            final currentRadius = distance(center1, points[aId]!);
            scaleAbout(center1, [slot['a_point_id'], slot['b_point_id']].cast<String>(), currentRadius);
            scaleAbout(center2, [slot['c_point_id'], slot['d_point_id']].cast<String>(), currentRadius);
            break;
          }
        }
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

    // Sketcher-roadmap Phase 4.3 v1: materializes a Body vertex as a real
    // Point - the fake backend doesn't have real Bodies to resolve
    // against, so it just deterministically derives an (x, y) from
    // body_id/vertex_index, good enough to exercise the client's own
    // materialize-once/reuse-on-repick logic.
    final externalReferenceMatch =
        RegExp(r'^/document/parts/[^/]+/features/sketch/[^/]+/external-references$').hasMatch(path);
    if (externalReferenceMatch && request.method == 'POST') {
      externalReferenceRequestCount++;
      final id = _newId('point');
      final point = {
        'id': id,
        'x': (body['body_id'] as String).length.toDouble(),
        'y': (body['vertex_index'] as num).toDouble(),
      };
      points[id] = point;
      return _json(point, 201);
    }

    // Sketcher-roadmap Phase 4.3 v2: materializes a Body edge as a real,
    // pinned Line (two fresh Points plus a Line between them) - same
    // "fake backend has no real Bodies, just deterministically derive
    // something from body_id/edge_index" reasoning as the vertex route
    // above.
    final externalEdgeReferenceMatch = RegExp(
      r'^/document/parts/[^/]+/features/sketch/[^/]+/external-references/edge$',
    ).hasMatch(path);
    if (externalEdgeReferenceMatch && request.method == 'POST') {
      externalEdgeReferenceRequestCount++;
      final bodyId = body['body_id'] as String;
      final edgeIndex = (body['edge_index'] as num).toDouble();
      final startId = _newId('point');
      final endId = _newId('point');
      final startPoint = {'id': startId, 'x': bodyId.length.toDouble(), 'y': edgeIndex};
      final endPoint = {'id': endId, 'x': bodyId.length.toDouble() + 10, 'y': edgeIndex};
      points[startId] = startPoint;
      points[endId] = endPoint;
      final lineId = _newId('line');
      final line = {
        'id': lineId,
        'start_point_id': startId,
        'end_point_id': endId,
        'length': 10.0,
        // On-device feedback (bug fix): a materialized Body edge is a
        // reference to dimension against, not new solid geometry - mirrors
        // create_external_edge_reference's own construction=True.
        'construction': true,
      };
      lines[lineId] = line;
      return _json({'line': line, 'start_point': startPoint, 'end_point': endPoint}, 201);
    }

    // P48 (Sketcher-roadmap Phase 9 v1, Convert Entities): materializes a
    // Body vertex as an ordinary, real (non-construction) Point - same
    // "derive something deterministic from body_id/vertex_index" fake as
    // the external-reference route above, but a real Point, not one this
    // fake needs to track any back-link for.
    final convertVertexMatch = RegExp(
      r'^/document/parts/[^/]+/features/sketch/[^/]+/convert-entities/vertex$',
    ).hasMatch(path);
    if (convertVertexMatch && request.method == 'POST') {
      convertVertexRequestCount++;
      final key = '${body['body_id']}:${body['vertex_index']}';
      final reusedId = _convertedVertexPointIds[key];
      if (reusedId != null && points.containsKey(reusedId)) {
        return _json(points[reusedId]!, 201);
      }
      final id = _newId('point');
      final point = {
        'id': id,
        'x': (body['body_id'] as String).length.toDouble(),
        'y': (body['vertex_index'] as num).toDouble(),
      };
      points[id] = point;
      _convertedVertexPointIds[key] = id;
      return _json(point, 201);
    }

    // P48's edge-shaped sibling to the vertex route above.
    final convertEdgeMatch = RegExp(
      r'^/document/parts/[^/]+/features/sketch/[^/]+/convert-entities/edge$',
    ).hasMatch(path);
    if (convertEdgeMatch && request.method == 'POST') {
      convertEdgeRequestCount++;
      final bodyId = body['body_id'] as String;
      final edgeIndex = (body['edge_index'] as num).toDouble();
      final startId = _newId('point');
      final endId = _newId('point');
      final startPoint = {'id': startId, 'x': bodyId.length.toDouble(), 'y': edgeIndex};
      final endPoint = {'id': endId, 'x': bodyId.length.toDouble() + 10, 'y': edgeIndex};
      points[startId] = startPoint;
      points[endId] = endPoint;
      // On-device feedback ("when I offset a curved edge it creates a
      // straight line"): edgeIndex 99 is this fake's own sentinel for "the
      // real backend detected a coplanar circular edge" - returns an arc
      // instead of a line, exercising the client's own dispatch on
      // whichever of the two the response actually carries.
      if (edgeIndex == 99) {
        final centerId = _newId('point');
        final centerPoint = {'id': centerId, 'x': bodyId.length.toDouble() + 5, 'y': edgeIndex};
        points[centerId] = centerPoint;
        final arcId = _newId('arc');
        final arc = {
          'id': arcId,
          'center_point_id': centerId,
          'start_point_id': startId,
          'end_point_id': endId,
          'radius': 5.0,
          'construction': false,
        };
        arcs[arcId] = arc;
        return _json(
          {'arc': arc, 'start_point': startPoint, 'end_point': endPoint, 'center_point': centerPoint},
          201,
        );
      }
      final lineId = _newId('line');
      final line = {
        'id': lineId,
        'start_point_id': startId,
        'end_point_id': endId,
        'length': 10.0,
        'construction': false,
      };
      lines[lineId] = line;
      return _json({'line': line, 'start_point': startPoint, 'end_point': endPoint}, 201);
    }

    // P49 (Sketcher-roadmap Phase 9 v1, Offset Entities): a new, real Line
    // - the fake doesn't replicate the real perpendicular-offset math
    // (covered directly by the real, executable `Sketch.offset_line`
    // tests), just returns a plausible, deterministic result good enough
    // to exercise the controller's own response handling. Reuse (an
    // already-known point/line) is opted into per-test by seeding
    // `points`/`lines` at the exact id this fake will derive, mirroring
    // how the convert-entities routes above let a test simulate reuse.
    final offsetLineMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/[^/]+/offset$').firstMatch(path);
    if (offsetLineMatch != null && request.method == 'POST') {
      final distance = (body['distance'] as num).toDouble();
      final startId = 'offset-start-$distance';
      final endId = 'offset-end-$distance';
      final startPoint = points[startId] ?? {'id': startId, 'x': distance, 'y': 0.0};
      final endPoint = points[endId] ?? {'id': endId, 'x': distance, 'y': 10.0};
      points[startId] = startPoint;
      points[endId] = endPoint;
      final lineId = _newId('line');
      final line = {
        'id': lineId,
        'start_point_id': startId,
        'end_point_id': endId,
        'length': 10.0,
        'construction': false,
      };
      lines[lineId] = line;
      return _json({'line': line, 'start_point': startPoint, 'end_point': endPoint}, 201);
    }

    // P49's Circle-shaped sibling to the Line-offset route above.
    final offsetCircleMatch = RegExp(r'^/sketch/sketches/[^/]+/circles/([^/]+)/offset$').firstMatch(path);
    if (offsetCircleMatch != null && request.method == 'POST') {
      final sourceCircle = circles[offsetCircleMatch.group(1)]!;
      final distance = (body['distance'] as num).toDouble();
      final radiusPointId = 'offset-radius-$distance';
      final radiusPoint = points[radiusPointId] ?? {'id': radiusPointId, 'x': distance, 'y': 0.0};
      points[radiusPointId] = radiusPoint;
      final circleId = _newId('circle');
      final circle = {
        'id': circleId,
        'center_point_id': sourceCircle['center_point_id'],
        'radius_point_id': radiusPointId,
        'radius': (sourceCircle['radius'] as num).toDouble() + distance,
        'construction': false,
        'cardinal_point_ids': <String>[],
      };
      circles[circleId] = circle;
      return _json({'circle': circle, 'radius_point': radiusPoint}, 201);
    }

    // P49's Arc-shaped sibling to the Circle-offset route above.
    final offsetArcMatch = RegExp(r'^/sketch/sketches/[^/]+/arcs/([^/]+)/offset$').firstMatch(path);
    if (offsetArcMatch != null && request.method == 'POST') {
      final sourceArc = arcs[offsetArcMatch.group(1)]!;
      final distance = (body['distance'] as num).toDouble();
      final startId = 'offset-arc-start-$distance';
      final endId = 'offset-arc-end-$distance';
      final startPoint = points[startId] ?? {'id': startId, 'x': distance, 'y': 0.0};
      final endPoint = points[endId] ?? {'id': endId, 'x': 0.0, 'y': distance};
      points[startId] = startPoint;
      points[endId] = endPoint;
      final arcId = _newId('arc');
      final arc = {
        'id': arcId,
        'center_point_id': sourceArc['center_point_id'],
        'start_point_id': startId,
        'end_point_id': endId,
        'radius': (sourceArc['radius'] as num).toDouble() + distance,
        'construction': false,
      };
      arcs[arcId] = arc;
      return _json({'arc': arc, 'start_point': startPoint, 'end_point': endPoint}, 201);
    }

    // P54 (Offset Entities v2, chain-aware/corner-joining Offset) - same
    // "the fake doesn't replicate the real math, just a plausible
    // deterministic result" contract as offsetLineMatch/offsetArcMatch
    // above (the real corner-join math is covered directly by the real,
    // executable `Sketch.offset_chain` tests). Simulates a joined corner
    // by deriving each new Point's id from the *original* shared Point id
    // (`offset-chain-<original id>`) rather than from distance - two
    // entities that shared an original Point naturally derive the exact
    // same new Point id here, the same "same id = same join" signal the
    // real backend's own `add_or_reuse_point` produces.
    final offsetChainMatch = RegExp(r'^/sketch/sketches/[^/]+/offset-chain$').firstMatch(path);
    if (offsetChainMatch != null && request.method == 'POST') {
      final entityIds = (body['entity_ids'] as List).cast<String>();
      final distance = (body['distance'] as num).toDouble();
      final construction = body['construction'] as bool? ?? false;
      final newLines = <Map<String, dynamic>>[];
      final newArcs = <Map<String, dynamic>>[];
      final newPoints = <Map<String, dynamic>>[];
      final seenPointIds = <String>{};
      void addPoint(Map<String, dynamic> point) {
        if (seenPointIds.add(point['id'] as String)) newPoints.add(point);
      }

      for (final entityId in entityIds) {
        final sourceLine = lines[entityId];
        final sourceArc = arcs[entityId];
        if (sourceLine != null) {
          final startId = 'offset-chain-${sourceLine['start_point_id']}';
          final endId = 'offset-chain-${sourceLine['end_point_id']}';
          final startPoint = points[startId] ?? {'id': startId, 'x': distance, 'y': 0.0};
          final endPoint = points[endId] ?? {'id': endId, 'x': distance, 'y': 10.0};
          points[startId] = startPoint;
          points[endId] = endPoint;
          final lineId = _newId('line');
          final line = {
            'id': lineId,
            'start_point_id': startId,
            'end_point_id': endId,
            'length': 10.0,
            'construction': construction,
          };
          lines[lineId] = line;
          newLines.add(line);
          addPoint(startPoint);
          addPoint(endPoint);
        } else if (sourceArc != null) {
          final startId = 'offset-chain-${sourceArc['start_point_id']}';
          final endId = 'offset-chain-${sourceArc['end_point_id']}';
          final startPoint = points[startId] ?? {'id': startId, 'x': distance, 'y': 0.0};
          final endPoint = points[endId] ?? {'id': endId, 'x': 0.0, 'y': distance};
          points[startId] = startPoint;
          points[endId] = endPoint;
          final arcId = _newId('arc');
          final arc = {
            'id': arcId,
            'center_point_id': sourceArc['center_point_id'],
            'start_point_id': startId,
            'end_point_id': endId,
            'radius': (sourceArc['radius'] as num).toDouble() + distance,
            'construction': construction,
          };
          arcs[arcId] = arc;
          newArcs.add(arc);
          addPoint(startPoint);
          addPoint(endPoint);
        }
      }
      return _json({'lines': newLines, 'arcs': newArcs, 'points': newPoints}, 201);
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

    final trimMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/([^/]+)/trim$').firstMatch(path);
    if (trimMatch != null && request.method == 'POST') {
      final lineId = trimMatch.group(1)!;
      final line = lines[lineId];
      if (line == null) return http.Response('not found', 404);
      final movedPointId = body['moved_point_id'] as String;
      final startId = line['start_point_id'] as String;
      final endId = line['end_point_id'] as String;
      if (movedPointId != startId && movedPointId != endId) {
        return _json({'detail': 'moved_point_id is not one of this Line\'s own endpoints'}, 400);
      }
      final target = trimTargetPoint;
      if (target == null) {
        return _json({'detail': 'Nothing found to trim/extend this Line to'}, 422);
      }
      // Mirrors the real backend's shared-Point rule: an endpoint
      // referenced by another Line gets a fresh Point instead of being
      // moved in place.
      final sharedElsewhere = lines.values.any(
        (other) => other != line && (other['start_point_id'] == movedPointId || other['end_point_id'] == movedPointId),
      );
      if (sharedElsewhere) {
        final newPointId = _newId('point');
        points[newPointId] = {'id': newPointId, 'x': target.$1, 'y': target.$2};
        if (movedPointId == startId) {
          line['start_point_id'] = newPointId;
        } else {
          line['end_point_id'] = newPointId;
        }
        return _json({'line': line, 'moved_point': points[newPointId], 'created_new_point': true}, 200);
      }
      final movedPoint = points[movedPointId]!;
      movedPoint['x'] = target.$1;
      movedPoint['y'] = target.$2;
      return _json({'line': line, 'moved_point': movedPoint, 'created_new_point': false}, 200);
    }

    final splitTrimMatch = RegExp(r'^/sketch/sketches/[^/]+/lines/([^/]+)/split-trim$').firstMatch(path);
    if (splitTrimMatch != null && request.method == 'POST') {
      final lineId = splitTrimMatch.group(1)!;
      final line = lines[lineId];
      if (line == null) return http.Response('not found', 404);
      final targets = splitTrimTargets;
      if (targets == null) {
        return _json({'detail': 'Click on line isn\'t bracketed by two interior crossings to split at'}, 422);
      }
      final startId = line['start_point_id'] as String;
      final endId = line['end_point_id'] as String;
      final leftId = _newId('point');
      points[leftId] = {'id': leftId, 'x': targets.$1.$1, 'y': targets.$1.$2};
      final rightId = _newId('point');
      points[rightId] = {'id': rightId, 'x': targets.$2.$1, 'y': targets.$2.$2};
      final line1Id = _newId('line');
      final line1 = {
        'id': line1Id,
        'start_point_id': startId,
        'end_point_id': leftId,
        'length': 0.0,
        'construction': line['construction'],
      };
      final line2Id = _newId('line');
      final line2 = {
        'id': line2Id,
        'start_point_id': rightId,
        'end_point_id': endId,
        'length': 0.0,
        'construction': line['construction'],
      };
      lines.remove(lineId);
      lines[line1Id] = line1;
      lines[line2Id] = line2;
      return _json({'line1': line1, 'line2': line2}, 200);
    }

    final circleTrimMatch = RegExp(r'^/sketch/sketches/[^/]+/circles/([^/]+)/trim$').firstMatch(path);
    if (circleTrimMatch != null && request.method == 'POST') {
      final circleId = circleTrimMatch.group(1)!;
      final circle = circles[circleId];
      if (circle == null) return http.Response('not found', 404);
      final target = curveTrimTargetPoint;
      if (target == null) {
        return _json({'detail': 'Fewer than 2 crossings found to trim circle at'}, 422);
      }
      final startId = _newId('point');
      points[startId] = {'id': startId, 'x': target.$1, 'y': target.$2};
      final endId = _newId('point');
      points[endId] = {'id': endId, 'x': target.$1, 'y': target.$2};
      final arcId = _newId('arc');
      final arc = {
        'id': arcId,
        'center_point_id': circle['center_point_id'],
        'start_point_id': startId,
        'end_point_id': endId,
        'radius': circle['radius'],
        'construction': circle['construction'],
      };
      arcs[arcId] = arc;
      circles.remove(circleId);
      return _json({'arc': arc, 'pruned_point_ids': _reportAndApplyPrunedPoints()}, 200);
    }

    final arcTrimMatch = RegExp(r'^/sketch/sketches/[^/]+/arcs/([^/]+)/trim$').firstMatch(path);
    if (arcTrimMatch != null && request.method == 'POST') {
      final arcId = arcTrimMatch.group(1)!;
      final arc = arcs[arcId];
      if (arc == null) return http.Response('not found', 404);
      final movedPointId = body['moved_point_id'] as String;
      final startId = arc['start_point_id'] as String;
      final endId = arc['end_point_id'] as String;
      if (movedPointId != startId && movedPointId != endId) {
        return _json({'detail': 'moved_point_id is not one of this Arc\'s own endpoints'}, 400);
      }
      final target = curveTrimTargetPoint;
      if (target == null) {
        return _json({'detail': 'Nothing found to trim/extend this Arc to'}, 422);
      }
      final sharedElsewhere = lines.values.any(
            (other) => other['start_point_id'] == movedPointId || other['end_point_id'] == movedPointId,
          ) ||
          arcs.values.any(
            (other) => other != arc && (other['start_point_id'] == movedPointId || other['end_point_id'] == movedPointId),
          );
      if (sharedElsewhere) {
        final newPointId = _newId('point');
        points[newPointId] = {'id': newPointId, 'x': target.$1, 'y': target.$2};
        if (movedPointId == startId) {
          arc['start_point_id'] = newPointId;
        } else {
          arc['end_point_id'] = newPointId;
        }
        return _json({'arc': arc, 'moved_point': points[newPointId], 'created_new_point': true}, 200);
      }
      final movedPoint = points[movedPointId]!;
      movedPoint['x'] = target.$1;
      movedPoint['y'] = target.$2;
      return _json({'arc': arc, 'moved_point': movedPoint, 'created_new_point': false}, 200);
    }

    final circlesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/circles$').hasMatch(path);
    if (circlesCollectionMatch && request.method == 'POST') {
      final id = _newId('circle');
      var radiusPointId = body['radius_point_id'] as String?;
      final requestedRadius = (body['radius'] as num?)?.toDouble() ?? 1.0;
      final cardinalPointIds = <String>[];
      final center = points[body['center_point_id'] as String]!;
      final centerX = (center['x'] as num).toDouble();
      final centerY = (center['y'] as num).toDouble();
      if (radiusPointId == null) {
        // Centre-point circle tool's own mode (bare radius, no
        // radius_point_id/angle) - mirrors the real backend's
        // Sketch.add_circle: the new Point becomes the circle's own north
        // cardinal point directly.
        radiusPointId = _newId('point');
        points[radiusPointId] = {
          'id': radiusPointId,
          'x': centerX,
          'y': centerY + requestedRadius,
        };
        cardinalPointIds.add(radiusPointId);
      }
      // Mirrors the real backend's _add_cardinal_points: North/East/South/
      // West always exist regardless of creation mode - North is either the
      // bare-radius Point above or created below alongside the rest.
      final cardinalOffsets = <String, (double, double)>{
        'north': (centerX, centerY + requestedRadius),
        'east': (centerX + requestedRadius, centerY),
        'south': (centerX, centerY - requestedRadius),
        'west': (centerX - requestedRadius, centerY),
      };
      final remaining = cardinalPointIds.isEmpty
          ? ['north', 'east', 'south', 'west']
          : ['east', 'south', 'west'];
      for (final key in remaining) {
        final newId = _newId('point');
        final offset = cardinalOffsets[key]!;
        points[newId] = {'id': newId, 'x': offset.$1, 'y': offset.$2};
        cardinalPointIds.add(newId);
      }
      final circle = {
        'id': id,
        'center_point_id': body['center_point_id'],
        'radius_point_id': radiusPointId,
        'radius': requestedRadius,
        'construction': false,
        'cardinal_point_ids': cardinalPointIds,
      };
      circles[id] = circle;
      // Mirrors the real backend's Sketch.add_circle, which auto-creates a
      // radius DistanceConstraint alongside the Circle, starting
      // provisional (see DistanceConstraint.provisional).
      final constraintId = _newId('constraint');
      constraints[constraintId] = {
        'id': constraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': radiusPointId,
        'distance': requestedRadius,
        'provisional': true,
      };
      return _json(circle, 201);
    }
    if (circlesCollectionMatch && request.method == 'GET') {
      return _jsonList(circles.values.toList(), 200);
    }

    final arcsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/arcs$').hasMatch(path);
    if (arcsCollectionMatch && request.method == 'POST') {
      final id = _newId('arc');
      final arc = {
        'id': id,
        'center_point_id': body['center_point_id'],
        'start_point_id': body['start_point_id'],
        'end_point_id': body['end_point_id'],
        'radius': 1.0,
        'construction': false,
      };
      arcs[id] = arc;
      // Mirrors the real backend's Sketch.add_arc: a single real radius
      // DistanceConstraint (centre-start), plus the end Point tied to it
      // via an EqualRadiusConstraint instead of a second independent
      // DistanceConstraint - see the Arc class's own docstring.
      final startConstraintId = _newId('constraint');
      constraints[startConstraintId] = {
        'id': startConstraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': body['start_point_id'],
        'distance': 1.0,
        'provisional': true,
      };
      final endConstraintId = _newId('constraint');
      constraints[endConstraintId] = {
        'id': endConstraintId,
        'type': 'equal_radius',
        'center1_point_id': body['center_point_id'],
        'radius1_point_id': body['start_point_id'],
        'center2_point_id': body['center_point_id'],
        'radius2_point_id': body['end_point_id'],
      };
      return _json(arc, 201);
    }
    if (arcsCollectionMatch && request.method == 'GET') {
      return _jsonList(arcs.values.toList(), 200);
    }

    final ellipsesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/ellipses$').hasMatch(path);
    if (ellipsesCollectionMatch && request.method == 'POST') {
      final id = _newId('ellipse');
      final centerPoint = points[body['center_point_id']]!;
      final majorPoint = points[body['major_point_id']]!;
      final majorRadius = math.sqrt(
        math.pow((majorPoint['x'] as num) - (centerPoint['x'] as num), 2) +
            math.pow((majorPoint['y'] as num) - (centerPoint['y'] as num), 2),
      );
      final rotation = math.atan2(
        (majorPoint['y'] as num) - (centerPoint['y'] as num),
        (majorPoint['x'] as num) - (centerPoint['x'] as num),
      );
      final minorRadius = (body['minor_radius'] as num).toDouble();
      // Mirrors the real backend's Sketch.add_ellipse: a new minor-axis
      // Point placed exactly perpendicular to the major axis, plus a
      // negative-tip Point per axis (diametrically opposite the positive
      // tip) so each axis Line spans its full diameter.
      final minorAngle = rotation + math.pi / 2;
      final minorPointId = _newId('point');
      points[minorPointId] = {
        'id': minorPointId,
        'x': (centerPoint['x'] as num) + minorRadius * math.cos(minorAngle),
        'y': (centerPoint['y'] as num) + minorRadius * math.sin(minorAngle),
      };
      final majorPointNegId = _newId('point');
      points[majorPointNegId] = {
        'id': majorPointNegId,
        'x': (centerPoint['x'] as num) - majorRadius * math.cos(rotation),
        'y': (centerPoint['y'] as num) - majorRadius * math.sin(rotation),
      };
      final minorPointNegId = _newId('point');
      points[minorPointNegId] = {
        'id': minorPointNegId,
        'x': (centerPoint['x'] as num) - minorRadius * math.cos(minorAngle),
        'y': (centerPoint['y'] as num) - minorRadius * math.sin(minorAngle),
      };
      final majorAxisLineId = _newId('line');
      lines[majorAxisLineId] = {
        'id': majorAxisLineId,
        'start_point_id': majorPointNegId,
        'end_point_id': body['major_point_id'],
        'length': majorRadius * 2,
        'construction': true,
      };
      final minorAxisLineId = _newId('line');
      lines[minorAxisLineId] = {
        'id': minorAxisLineId,
        'start_point_id': minorPointNegId,
        'end_point_id': minorPointId,
        'length': minorRadius * 2,
        'construction': true,
      };
      final ellipse = {
        'id': id,
        'center_point_id': body['center_point_id'],
        'major_point_id': body['major_point_id'],
        'major_point_neg_id': majorPointNegId,
        'minor_point_id': minorPointId,
        'minor_point_neg_id': minorPointNegId,
        'major_axis_line_id': majorAxisLineId,
        'minor_axis_line_id': minorAxisLineId,
        'major_radius': majorRadius,
        'minor_radius': minorRadius,
        'rotation': rotation,
        'construction': body['construction'] as bool? ?? false,
      };
      ellipses[id] = ellipse;
      // Mirrors the real backend's Sketch.add_ellipse, which auto-creates
      // major-axis and minor-axis DistanceConstraints, an AtMidpointConstraint
      // per axis (pinning center as the midpoint of the full axis Line), plus
      // a PerpendicularConstraint tying the two axis Lines together.
      final majorConstraintId = _newId('constraint');
      constraints[majorConstraintId] = {
        'id': majorConstraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': body['major_point_id'],
        'distance': majorRadius,
        'provisional': true,
      };
      final minorConstraintId = _newId('constraint');
      constraints[minorConstraintId] = {
        'id': minorConstraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': minorPointId,
        'distance': minorRadius,
        'provisional': true,
      };
      final majorMidpointConstraintId = _newId('constraint');
      constraints[majorMidpointConstraintId] = {
        'id': majorMidpointConstraintId,
        'type': 'at_midpoint',
        'point_id': body['center_point_id'],
        'line_id': majorAxisLineId,
      };
      final minorMidpointConstraintId = _newId('constraint');
      constraints[minorMidpointConstraintId] = {
        'id': minorMidpointConstraintId,
        'type': 'at_midpoint',
        'point_id': body['center_point_id'],
        'line_id': minorAxisLineId,
      };
      final perpendicularConstraintId = _newId('constraint');
      constraints[perpendicularConstraintId] = {
        'id': perpendicularConstraintId,
        'type': 'perpendicular',
        'line1_id': majorAxisLineId,
        'line2_id': minorAxisLineId,
      };
      return _json(ellipse, 201);
    }
    if (ellipsesCollectionMatch && request.method == 'GET') {
      return _jsonList(ellipses.values.toList(), 200);
    }

    final polygonsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/polygons$').hasMatch(path);
    if (polygonsCollectionMatch && request.method == 'POST') {
      final id = _newId('polygon');
      final sides = body['sides'] as int;
      final centerPoint = points[body['center_point_id']]!;
      final firstVertex = points[body['first_vertex_point_id']]!;
      final cx = (centerPoint['x'] as num).toDouble();
      final cy = (centerPoint['y'] as num).toDouble();
      final radius = math.sqrt(
        math.pow((firstVertex['x'] as num) - cx, 2) + math.pow((firstVertex['y'] as num) - cy, 2),
      );
      final baseAngle = math.atan2((firstVertex['y'] as num) - cy, (firstVertex['x'] as num) - cx);
      // Mirrors the real backend's Sketch.add_polygon: the first vertex is
      // reused as-is, every other vertex is a fresh Point placed evenly
      // around the circle.
      final vertexPointIds = <String>[body['first_vertex_point_id'] as String];
      for (var i = 1; i < sides; i++) {
        final angle = baseAngle + 2 * math.pi * i / sides;
        final vertexId = _newId('point');
        points[vertexId] = {'id': vertexId, 'x': cx + radius * math.cos(angle), 'y': cy + radius * math.sin(angle)};
        vertexPointIds.add(vertexId);
      }
      final lineIds = <String>[];
      for (var i = 0; i < sides; i++) {
        final lineId = _newId('line');
        lines[lineId] = {
          'id': lineId,
          'start_point_id': vertexPointIds[i],
          'end_point_id': vertexPointIds[(i + 1) % sides],
          'length': 1.0,
          'construction': false,
        };
        lineIds.add(lineId);
      }
      final constraintIds = <String>[];
      final radiusConstraintId = _newId('constraint');
      constraints[radiusConstraintId] = {
        'id': radiusConstraintId,
        'point_a_id': body['center_point_id'],
        'point_b_id': vertexPointIds[0],
        'distance': radius,
        'provisional': true,
      };
      constraintIds.add(radiusConstraintId);
      for (var i = 1; i < sides; i++) {
        final equalRadiusId = _newId('constraint');
        constraints[equalRadiusId] = {
          'id': equalRadiusId,
          'type': 'equal_radius',
          'center1_point_id': body['center_point_id'],
          'radius1_point_id': vertexPointIds[0],
          'center2_point_id': body['center_point_id'],
          'radius2_point_id': vertexPointIds[i],
        };
        constraintIds.add(equalRadiusId);
      }
      for (var i = 1; i < sides; i++) {
        final equalLengthId = _newId('constraint');
        constraints[equalLengthId] = {
          'id': equalLengthId,
          'type': 'equal_length',
          'line1_id': lineIds[i - 1],
          'line2_id': lineIds[i],
        };
        constraintIds.add(equalLengthId);
        final angleId = _newId('constraint');
        constraints[angleId] = {
          'id': angleId,
          'type': 'angle',
          'line1_id': lineIds[i - 1],
          'line2_id': lineIds[i],
          'angle_degrees': 360.0 / sides,
        };
        constraintIds.add(angleId);
      }
      String? circumscribedCircleId;
      String? inscribedCircleId;
      // Mirrors the real backend's Sketch.add_polygon own reference_circles
      // option (on-device feedback: "the 2 construction circles should be
      // drawn and visible to the user to dimension and use in the
      // sketch") - a minimal stand-in for the full circle-creation POST
      // handler above (same shape: cardinal points + a provisional radius
      // DistanceConstraint), just inlined rather than reused since that's
      // structured as its own HTTP handler.
      Map<String, dynamic> makeReferenceCircle(String radiusPointId, double circleRadius) {
        final circleId = _newId('circle');
        final cardinalPointIds = <String>[];
        final cardinalOffsets = <String, (double, double)>{
          'north': (cx, cy + circleRadius),
          'east': (cx + circleRadius, cy),
          'south': (cx, cy - circleRadius),
          'west': (cx - circleRadius, cy),
        };
        for (final key in ['north', 'east', 'south', 'west']) {
          final newId = _newId('point');
          final offset = cardinalOffsets[key]!;
          points[newId] = {'id': newId, 'x': offset.$1, 'y': offset.$2};
          cardinalPointIds.add(newId);
        }
        circles[circleId] = {
          'id': circleId,
          'center_point_id': body['center_point_id'],
          'radius_point_id': radiusPointId,
          'radius': circleRadius,
          'construction': true,
          'cardinal_point_ids': cardinalPointIds,
        };
        final constraintId = _newId('constraint');
        constraints[constraintId] = {
          'id': constraintId,
          'point_a_id': body['center_point_id'],
          'point_b_id': radiusPointId,
          'distance': circleRadius,
          'provisional': true,
        };
        return circles[circleId]!;
      }

      if (body['reference_circles'] == true) {
        circumscribedCircleId = makeReferenceCircle(vertexPointIds[0], radius)['id'] as String;
        final inradius = radius * math.cos(math.pi / sides);
        final inscribedRadiusPointId = _newId('point');
        points[inscribedRadiusPointId] = {'id': inscribedRadiusPointId, 'x': cx + inradius, 'y': cy};
        inscribedCircleId = makeReferenceCircle(inscribedRadiusPointId, inradius)['id'] as String;
      }

      final polygon = {
        'id': id,
        'center_point_id': body['center_point_id'],
        'vertex_point_ids': vertexPointIds,
        'line_ids': lineIds,
        'radius': radius,
        'sides': sides,
        'construction': body['construction'] as bool? ?? false,
        'circumscribed_circle_id': circumscribedCircleId,
        'inscribed_circle_id': inscribedCircleId,
        // Not part of the real API response - kept only so this fake's own
        // DELETE handler above knows which Constraints to cascade, mirroring
        // the real backend's Sketch.delete_polygon.
        '_constraint_ids': constraintIds,
      };
      polygons[id] = polygon;
      return _json(polygon, 201);
    }
    if (polygonsCollectionMatch && request.method == 'GET') {
      return _jsonList(polygons.values.toList(), 200);
    }

    final slotsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/slots$').hasMatch(path);
    if (slotsCollectionMatch && request.method == 'POST') {
      final id = _newId('slot');
      final center1Id = body['center1_point_id'] as String;
      final center2Id = body['center2_point_id'] as String;
      final radius = (body['radius'] as num).toDouble();
      final c1 = points[center1Id]!;
      final c2 = points[center2Id]!;
      final c1x = (c1['x'] as num).toDouble(), c1y = (c1['y'] as num).toDouble();
      final c2x = (c2['x'] as num).toDouble(), c2y = (c2['y'] as num).toDouble();
      final dx = c2x - c1x, dy = c2y - c1y;
      final length = math.sqrt(dx * dx + dy * dy);
      final dirX = dx / length, dirY = dy / length;
      final normalX = -dirY, normalY = dirX;
      // Mirrors the real backend's Sketch.add_slot exactly - see that
      // method's own doc comment for the corner-pairing geometry.
      String newPointAt(double x, double y) {
        final pid = _newId('point');
        points[pid] = {'id': pid, 'x': x, 'y': y};
        return pid;
      }

      final aId = newPointAt(c1x + normalX * radius, c1y + normalY * radius);
      final bId = newPointAt(c1x - normalX * radius, c1y - normalY * radius);
      final cId = newPointAt(c2x - normalX * radius, c2y - normalY * radius);
      final dId = newPointAt(c2x + normalX * radius, c2y + normalY * radius);

      final centerlineId = _newId('line');
      lines[centerlineId] = {
        'id': centerlineId,
        'start_point_id': center1Id,
        'end_point_id': center2Id,
        'length': length,
        'construction': true,
      };

      final constraintIds = <String>[];
      String newArc(String centerId, String startId, String endId) {
        final arcId = _newId('arc');
        arcs[arcId] = {
          'id': arcId,
          'center_point_id': centerId,
          'start_point_id': startId,
          'end_point_id': endId,
          'radius': radius,
          'construction': false,
        };
        final radiusConstraintId = _newId('constraint');
        constraints[radiusConstraintId] = {
          'id': radiusConstraintId,
          'point_a_id': centerId,
          'point_b_id': startId,
          'distance': radius,
          'provisional': true,
        };
        arcs[arcId]!['_radius_constraint_id'] = radiusConstraintId;
        final endConstraintId = _newId('constraint');
        constraints[endConstraintId] = {
          'id': endConstraintId,
          'type': 'equal_radius',
          'center1_point_id': centerId,
          'radius1_point_id': startId,
          'center2_point_id': centerId,
          'radius2_point_id': endId,
        };
        constraintIds.add(endConstraintId);
        return arcId;
      }

      final arc1Id = newArc(center1Id, aId, bId);
      final line1Id = _newId('line');
      lines[line1Id] = {'id': line1Id, 'start_point_id': bId, 'end_point_id': cId, 'length': 1.0, 'construction': false};
      final arc2Id = newArc(center2Id, cId, dId);
      final line2Id = _newId('line');
      lines[line2Id] = {'id': line2Id, 'start_point_id': dId, 'end_point_id': aId, 'length': 1.0, 'construction': false};

      // arc2's own provisional radius DistanceConstraint is replaced with
      // ties back to arc1's, same as the real backend.
      final arc2RadiusConstraintId = arcs[arc2Id]!.remove('_radius_constraint_id') as String;
      constraints.remove(arc2RadiusConstraintId);
      final radiusConstraintId = arcs[arc1Id]!.remove('_radius_constraint_id') as String;
      for (final radiusPointId in [cId, dId]) {
        final equalRadiusId = _newId('constraint');
        constraints[equalRadiusId] = {
          'id': equalRadiusId,
          'type': 'equal_radius',
          'center1_point_id': center1Id,
          'radius1_point_id': aId,
          'center2_point_id': center2Id,
          'radius2_point_id': radiusPointId,
        };
        constraintIds.add(equalRadiusId);
      }
      for (final entry in [(arc1Id, line1Id), (arc1Id, line2Id), (arc2Id, line1Id), (arc2Id, line2Id)]) {
        final tangentId = _newId('constraint');
        constraints[tangentId] = {
          'id': tangentId,
          'type': 'tangent',
          'center_point_id': entry.$1 == arc1Id ? center1Id : center2Id,
          'radius_point_id': entry.$1 == arc1Id ? aId : cId,
          'line_id': entry.$2,
        };
        constraintIds.add(tangentId);
      }
      constraintIds.add(radiusConstraintId);

      final slot = {
        'id': id,
        'center1_point_id': center1Id,
        'center2_point_id': center2Id,
        'centerline_id': centerlineId,
        'arc1_id': arc1Id,
        'arc2_id': arc2Id,
        'line1_id': line1Id,
        'line2_id': line2Id,
        'a_point_id': aId,
        'b_point_id': bId,
        'c_point_id': cId,
        'd_point_id': dId,
        'radius': radius,
        'construction': body['construction'] as bool? ?? false,
        // Not part of the real API response - kept only so this fake's own
        // DELETE handler knows which Constraints to cascade.
        '_constraint_ids': constraintIds,
      };
      slots[id] = slot;
      return _json(slot, 201);
    }
    if (slotsCollectionMatch && request.method == 'GET') {
      return _jsonList(slots.values.toList(), 200);
    }

    final rectanglesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/rectangles$').hasMatch(path);
    if (rectanglesCollectionMatch && request.method == 'POST') {
      final id = _newId('rectangle');
      final cornerIds = (body['corner_point_ids'] as List).cast<String>();
      final axisAligned = body['axis_aligned'] as bool? ?? true;
      // Mirrors the real backend's Sketch.add_rectangle exactly - see that
      // method's own doc comment for the fixed corner0->1->2->3->0 edge
      // order and the axis-aligned-vs-free constraint chains.
      final lineIds = <String>[];
      for (var i = 0; i < 4; i++) {
        final lineId = _newId('line');
        lines[lineId] = {
          'id': lineId,
          'start_point_id': cornerIds[i],
          'end_point_id': cornerIds[(i + 1) % 4],
          'length': 1.0,
          'construction': false,
        };
        lineIds.add(lineId);
      }

      final constraintIds = <String>[];
      String? centerPointId;
      String? diagonalLineId;
      String? diagonal2LineId;
      if (axisAligned) {
        for (final lineId in [lineIds[0], lineIds[2]]) {
          final line = lines[lineId]!;
          final cid = _newId('constraint');
          constraints[cid] = {
            'id': cid,
            'type': 'horizontal',
            'line_id': lineId,
            'point_a_id': line['start_point_id'],
            'point_b_id': line['end_point_id'],
          };
          constraintIds.add(cid);
        }
        for (final lineId in [lineIds[1], lineIds[3]]) {
          final line = lines[lineId]!;
          final cid = _newId('constraint');
          constraints[cid] = {
            'id': cid,
            'type': 'vertical',
            'line_id': lineId,
            'point_a_id': line['start_point_id'],
            'point_b_id': line['end_point_id'],
          };
          constraintIds.add(cid);
        }
        diagonalLineId = _newId('line');
        lines[diagonalLineId] = {
          'id': diagonalLineId,
          'start_point_id': cornerIds[0],
          'end_point_id': cornerIds[2],
          'length': 1.0,
          'construction': true,
        };
        diagonal2LineId = _newId('line');
        lines[diagonal2LineId] = {
          'id': diagonal2LineId,
          'start_point_id': cornerIds[1],
          'end_point_id': cornerIds[3],
          'length': 1.0,
          'construction': true,
        };
        final corner0 = points[cornerIds[0]]!;
        final corner1 = points[cornerIds[1]]!;
        final corner2 = points[cornerIds[2]]!;
        final corner3 = points[cornerIds[3]]!;
        final centerX = ((corner0['x'] as num).toDouble() +
                (corner1['x'] as num).toDouble() +
                (corner2['x'] as num).toDouble() +
                (corner3['x'] as num).toDouble()) /
            4;
        final centerY = ((corner0['y'] as num).toDouble() +
                (corner1['y'] as num).toDouble() +
                (corner2['y'] as num).toDouble() +
                (corner3['y'] as num).toDouble()) /
            4;
        centerPointId = _newId('point');
        points[centerPointId] = {'id': centerPointId, 'x': centerX, 'y': centerY};
        final midCid = _newId('constraint');
        constraints[midCid] = {
          'id': midCid,
          'type': 'at_midpoint',
          'point_id': centerPointId,
          'line_id': diagonalLineId,
        };
        constraintIds.add(midCid);
      } else {
        for (final pair in [(lineIds[0], lineIds[1]), (lineIds[1], lineIds[2]), (lineIds[2], lineIds[3])]) {
          final cid = _newId('constraint');
          constraints[cid] = {'id': cid, 'type': 'perpendicular', 'line1_id': pair.$1, 'line2_id': pair.$2};
          constraintIds.add(cid);
        }
      }

      final rectangle = {
        'id': id,
        'corner_point_ids': cornerIds,
        'line_ids': lineIds,
        'axis_aligned': axisAligned,
        'center_point_id': centerPointId,
        'diagonal_line_id': diagonalLineId,
        'diagonal2_line_id': diagonal2LineId,
        'construction': body['construction'] as bool? ?? false,
        // Not part of the real API response - kept only so this fake's own
        // DELETE handler knows which Constraints to cascade.
        '_constraint_ids': constraintIds,
      };
      rectangles[id] = rectangle;
      return _json(rectangle, 201);
    }
    if (rectanglesCollectionMatch && request.method == 'GET') {
      return _jsonList(rectangles.values.toList(), 200);
    }

    final splinesCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/splines$').hasMatch(path);
    if (splinesCollectionMatch && request.method == 'POST') {
      final id = _newId('spline');
      final throughPointIds = (body['through_point_ids'] as List).cast<String>();
      final controlPointIds = <String>[];
      // Mirrors the real backend's Sketch.add_spline, which places 2 control
      // points per segment at a 1/3-offset along each through-point chord,
      // plus a spline_tangent constraint per interior joint.
      for (var i = 0; i < throughPointIds.length - 1; i++) {
        final p0 = points[throughPointIds[i]]!;
        final p3 = points[throughPointIds[i + 1]]!;
        final x0 = p0['x'] as num, y0 = p0['y'] as num;
        final x3 = p3['x'] as num, y3 = p3['y'] as num;
        final c1Id = _newId('point');
        points[c1Id] = {'id': c1Id, 'x': x0 + (x3 - x0) / 3, 'y': y0 + (y3 - y0) / 3};
        final c2Id = _newId('point');
        points[c2Id] = {'id': c2Id, 'x': x0 + 2 * (x3 - x0) / 3, 'y': y0 + 2 * (y3 - y0) / 3};
        controlPointIds.addAll([c1Id, c2Id]);
      }
      final tangentConstraintIds = <String>[];
      for (var i = 0; i < throughPointIds.length - 2; i++) {
        final constraintId = _newId('constraint');
        constraints[constraintId] = {
          'id': constraintId,
          'type': 'spline_tangent',
          'spline_id': id,
          'segment_a_p0': throughPointIds[i],
          'segment_a_p1': controlPointIds[2 * i],
          'segment_a_p2': controlPointIds[2 * i + 1],
          'segment_a_p3': throughPointIds[i + 1],
          'segment_b_p0': throughPointIds[i + 1],
          'segment_b_p1': controlPointIds[2 * (i + 1)],
          'segment_b_p2': controlPointIds[2 * (i + 1) + 1],
          'segment_b_p3': throughPointIds[i + 2],
        };
        tangentConstraintIds.add(constraintId);
      }
      final spline = {
        'id': id,
        'through_point_ids': throughPointIds,
        'control_point_ids': controlPointIds,
        'tangent_constraint_ids': tangentConstraintIds,
        'construction': body['construction'] as bool? ?? false,
      };
      splines[id] = spline;
      return _json(spline, 201);
    }
    if (splinesCollectionMatch && request.method == 'GET') {
      return _jsonList(splines.values.toList(), 200);
    }

    final textsCollectionMatch = RegExp(r'^/sketch/sketches/[^/]+/texts$').hasMatch(path);
    if (textsCollectionMatch && request.method == 'POST') {
      final id = _newId('text');
      final text = {
        'id': id,
        'content': body['content'] as String,
        'font': 'Open Sans',
        'size': (body['size'] as num?)?.toDouble() ?? 10.0,
        'anchor_point_id': body['anchor_point_id'] as String,
        'rotation_degrees': (body['rotation_degrees'] as num?)?.toDouble() ?? 0.0,
        'construction': body['construction'] as bool? ?? false,
      };
      texts[id] = text;
      return _json(text, 201);
    }
    if (textsCollectionMatch && request.method == 'GET') {
      return _jsonList(texts.values.toList(), 200);
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
        case 'tangent':
          final radiusPointId = _centerRadiusPointIds(body['circle_or_arc_id'] as String).$2;
          constraint = {
            'id': id,
            'type': 'tangent',
            'center_point_id': _centerRadiusPointIds(body['circle_or_arc_id'] as String).$1,
            'radius_point_id': radiusPointId,
            'line_id': body['line_id'],
          };
          break;
        case 'equal_radius':
          final radius1 = _centerRadiusPointIds(body['entity1_id'] as String);
          final entity2Id = body['entity2_id'] as String;
          final radius2PointId = body['radius2_point_id'] as String? ?? _centerRadiusPointIds(entity2Id).$2;
          constraint = {
            'id': id,
            'type': 'equal_radius',
            'center1_point_id': radius1.$1,
            'radius1_point_id': radius1.$2,
            'center2_point_id': _centerRadiusPointIds(entity2Id).$1,
            'radius2_point_id': radius2PointId,
          };
          break;
        case 'equal_radius_points':
          // Mirrors the real backend's Sketch.add_equal_radius_constraint_
          // from_points - the Polygon tool's own raw-Point equal-radius
          // ties, reporting back as a plain 'equal_radius' type same as the
          // entity-based case above (the two creation paths produce the
          // same EqualRadiusConstraint shape server-side).
          constraint = {
            'id': id,
            'type': 'equal_radius',
            'center1_point_id': body['center1_point_id'],
            'radius1_point_id': body['radius1_point_id'],
            'center2_point_id': body['center2_point_id'],
            'radius2_point_id': body['radius2_point_id'],
          };
          break;
        default:
          constraint = {
            'id': id,
            'point_a_id': body['point_a_id'],
            'point_b_id': body['point_b_id'],
            'distance': (body['distance'] as num).toDouble(),
            'orientation': body['orientation'] as String? ?? 'linear',
            'provisional': body['provisional'] as bool? ?? false,
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

    // Phase 0 round-trip reduction: bundles the same solve result with the
    // current Points/Constraints/profile, mirroring the real backend's
    // POST .../solve-and-refresh (SketchStateResponse).
    final solveAndRefreshMatch = RegExp(r'^/sketch/sketches/[^/]+/solve-and-refresh$').hasMatch(path);
    if (solveAndRefreshMatch && request.method == 'POST') {
      return _json({
        'solve': _solveResultBody(),
        'points': points.values.toList(),
        'constraints': constraints.values.toList(),
        'profile': _profileBody(),
      }, 200);
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
    final branchPointIds = degree.entries.where((e) => e.value > 2).map((e) => e.key).toList();
    if (branchPointIds.isNotEmpty) {
      // Mirrors the real backend's BRANCH status: a Point used by 3+ Lines
      // (a T-junction) excludes the whole component from loop tracing -
      // needed to test SketchController.profileBranchPointIds /
      // SketchCanvas._paintProfileBranchPoints.
      return {
        'status': 'branch',
        'detail': '${branchPointIds.length} point(s) are used by more than two entities.',
        'profile': null,
        'branch_point_ids': branchPointIds,
        'loops': <Map<String, dynamic>>[],
      };
    }
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

  /// Phase 3 bug-fix round: lets a test simulate a non-convergent solve
  /// (`converged: false`) and py-slvs's own list of implicated Constraint
  /// ids, same pattern as [dof] above.
  bool converged = true;
  List<String> solverReportedFailedConstraintIds = [];

  Map<String, dynamic> _solveResultBody() => {
        'converged': converged,
        'dof': dof,
        'result_code': converged ? 0 : 1,
        'blamed_constraint_ids': [],
        'solver_reported_failed_constraint_ids': solverReportedFailedConstraintIds,
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

    // Origin/centre (shared, since (0, 0) snaps onto the origin) + all four
    // North/East/South/West cardinal Points (see Sketch._add_cardinal_points).
    expect(controller.points.length, 5);
    expect(controller.circles.length, 1);
    final circle = controller.circles.values.first;
    expect(circle.centerPointId, centerId);
    expect(circle.radiusPointId, isNot(centerId));
    expect(controller.circleInProgress, isFalse);
    expect(controller.errorMessage, isNull);
  });

  test(
      'feedback round: a freshly-drawn circle\'s auto-created radius dimension starts hidden, '
      'and only becomes visible once the user explicitly confirms it via the ghost flow', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(radiusConstraint.provisional, isTrue);

    controller.enterDimensionMode();
    // On the boundary but off every cardinal axis (see
    // Sketch._add_cardinal_points).
    await controller.handleCanvasTap(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4));
    await controller.confirmGhostValue('radius', 5.0);

    final confirmed = controller.constraints[radiusConstraint.id] as DistanceConstraintDto;
    expect(confirmed.provisional, isFalse);
  });

  test('a third tap after a completed circle starts a fresh circle', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
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

  group('Rectangle closed-form drag (parity follow-up: extends the same solver-free drag pattern '
      'already shipped for Polygon/Slot/Circle/Arc/Ellipse to the newly-promoted Rectangle entity - '
      'unlike those, a Rectangle has no provisional-radius collapse risk (its H/V constraints are '
      'always real, never provisional), but the same "drag a corner and let a formula place the rest" '
      'approach still eliminates the solver from the hot drag path entirely)', () {
    test('dragging the centre translates every corner by the same delta, with zero solver/network '
        'calls', () async {
      controller.selectDrawTool(SketchTool.rectangle);
      controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);
      await controller.handleCanvasTap(2, 2);
      await controller.handleCanvasTap(10, 8);
      controller.exitToSelectMode();
      final rectangle = controller.rectangles.values.single;
      final cornersBefore = [for (final id in rectangle.cornerPointIds) controller.points[id]!];

      backend.requestLog.clear();
      final centerId = rectangle.centerPointId!;
      final center0 = controller.points[centerId]!;
      controller.cursorX = center0.x;
      controller.cursorY = center0.y;
      expect(controller.beginPointDrag(centerId), isTrue);
      await controller.updatePointDrag(center0.x + 5, center0.y + 5);

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse,
          reason: 'the closed-form path never needs to solve anything');
      for (var i = 0; i < 4; i++) {
        final after = controller.points[rectangle.cornerPointIds[i]]!;
        expect(after.x, closeTo(cornersBefore[i].x + 5, 1e-9));
        expect(after.y, closeTo(cornersBefore[i].y + 5, 1e-9));
      }
    });

    test('dragging a corner keeps the opposite corner fixed and recomputes the other two to stay '
        'axis-aligned - the exact formula the Rectangle\'s own Horizontal/Vertical constraint chain '
        'enforces, evaluated directly instead of via a solve', () async {
      controller.selectDrawTool(SketchTool.rectangle);
      controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);
      await controller.handleCanvasTap(2, 2);
      await controller.handleCanvasTap(10, 8);
      controller.exitToSelectMode();
      final rectangle = controller.rectangles.values.single;
      // Corners are (2,2), (10,2), (10,8), (2,8) in that cycle order - see
      // the "Two Corner rectangle" test above. Corner 0 is dragged below;
      // corner 2 (opposite) is its fixed anchor.
      final corner0Id = rectangle.cornerPointIds[0];
      final corner1Id = rectangle.cornerPointIds[1];
      final corner2Id = rectangle.cornerPointIds[2];
      final corner3Id = rectangle.cornerPointIds[3];
      expect(controller.points[corner0Id]!.x, closeTo(2, 1e-9));
      expect(controller.points[corner0Id]!.y, closeTo(2, 1e-9));
      expect(controller.points[corner2Id]!.x, closeTo(10, 1e-9));
      expect(controller.points[corner2Id]!.y, closeTo(8, 1e-9));

      backend.requestLog.clear();
      controller.cursorX = 2;
      controller.cursorY = 2;
      expect(controller.beginPointDrag(corner0Id), isTrue);
      await controller.updatePointDrag(0, 0);

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse);
      expect(controller.points[corner0Id]!.x, closeTo(0, 1e-9));
      expect(controller.points[corner0Id]!.y, closeTo(0, 1e-9));
      // Opposite corner (2) never moved.
      expect(controller.points[corner2Id]!.x, closeTo(10, 1e-9));
      expect(controller.points[corner2Id]!.y, closeTo(8, 1e-9));
      // Corner 1 shares Y with the dragged corner, X with the fixed anchor.
      expect(controller.points[corner1Id]!.x, closeTo(10, 1e-9));
      expect(controller.points[corner1Id]!.y, closeTo(0, 1e-9));
      // Corner 3 shares X with the dragged corner, Y with the fixed anchor.
      expect(controller.points[corner3Id]!.x, closeTo(0, 1e-9));
      expect(controller.points[corner3Id]!.y, closeTo(8, 1e-9));
      // The centre must track the new true centre too.
      final center = controller.points[rectangle.centerPointId!]!;
      expect(center.x, closeTo(5, 1e-9));
      expect(center.y, closeTo(4, 1e-9));
    });

    test('once the centre Point is gone (no longer intact), dragging a corner falls back to the '
        'ordinary drag path instead of the closed-form one', () async {
      controller.selectDrawTool(SketchTool.rectangle);
      controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);
      await controller.handleCanvasTap(2, 2);
      await controller.handleCanvasTap(10, 8);
      controller.exitToSelectMode();
      final rectangle = controller.rectangles.values.single;
      // Direct local removal (see the analogous Ellipse fallback test's own
      // doc comment) - exactly what [_intactRectangleForPoint]'s live
      // points-map check reads, with no other side effects.
      controller.points.remove(rectangle.centerPointId);
      final corner1Before = controller.points[rectangle.cornerPointIds[1]]!;

      final corner0Id = rectangle.cornerPointIds[0];
      final corner0 = controller.points[corner0Id]!;
      controller.cursorX = corner0.x;
      controller.cursorY = corner0.y;
      expect(controller.beginPointDrag(corner0Id), isTrue);
      await controller.updatePointDrag(0, 0);

      // The closed-form path (which would have moved it instantly, per the
      // test above) didn't run - corner 1 never moved.
      final corner1After = controller.points[rectangle.cornerPointIds[1]]!;
      expect(corner1After.x, closeTo(corner1Before.x, 1e-9));
      expect(corner1After.y, closeTo(corner1Before.y, 1e-9));
    });
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

  // --- Phase 6.1: line snap-to-horizontal/vertical --------------------------

  test('activeLineSnapAxis and the ghost preview snap to horizontal within the angle threshold', () async {
    controller.selectDrawTool(SketchTool.line);
    controller.setLineConstructionMethod(LineConstructionMethod.endToEnd);
    await controller.handleCanvasTap(0, 0);

    // atan2(0.3, 10) ~= 1.7 degrees off horizontal - within the 4 degree
    // threshold.
    controller.cursorX = 10;
    controller.cursorY = 0.3;
    expect(controller.activeLineSnapAxis, LineSnapAxis.horizontal);
    final ghost = controller.activeDrawGhost as LineGhost;
    expect(ghost.endX, 10);
    expect(ghost.endY, 0); // snapped flat, not the raw cursor's 0.3
  });

  test('activeLineSnapAxis and the ghost preview snap to vertical within the angle threshold', () async {
    controller.selectDrawTool(SketchTool.line);
    controller.setLineConstructionMethod(LineConstructionMethod.endToEnd);
    await controller.handleCanvasTap(0, 0);

    controller.cursorX = 0.3;
    controller.cursorY = 10;
    expect(controller.activeLineSnapAxis, LineSnapAxis.vertical);
    final ghost = controller.activeDrawGhost as LineGhost;
    expect(ghost.endX, 0);
    expect(ghost.endY, 10);
  });

  test('activeLineSnapAxis is null once the angle is outside the snap threshold', () async {
    controller.selectDrawTool(SketchTool.line);
    controller.setLineConstructionMethod(LineConstructionMethod.endToEnd);
    await controller.handleCanvasTap(0, 0);

    controller.cursorX = 4;
    controller.cursorY = 5; // far from either axis
    expect(controller.activeLineSnapAxis, isNull);
    final ghost = controller.activeDrawGhost as LineGhost;
    expect(ghost.endX, 4);
    expect(ghost.endY, 5);
  });

  // --- Phase 6.2.1: Arc tool -------------------------------------------------

  test('activeDrawGhost previews a plain circle while only the arc center is placed', () async {
    controller.selectDrawTool(SketchTool.arc);
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

  test('activeDrawGhost previews an arc snapped onto the fixed radius once center and start are both placed',
      () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(5, 0); // start - fixes the radius at 5

    // Cursor far off the circle - the ghost's end must still land exactly
    // on the radius-5 circle, in the cursor's direction from center.
    controller.cursorX = 0;
    controller.cursorY = 100;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<ArcGhost>());
    final arc = ghost as ArcGhost;
    expect(arc.centerX, 0);
    expect(arc.centerY, 0);
    expect(arc.startX, 5);
    expect(arc.startY, 0);
    expect(arc.endX, closeTo(0, 1e-9));
    expect(arc.endY, closeTo(5, 1e-9));
  });

  test('the arc tool places center, start, then end across three taps, creating one Arc and two radius '
      'constraints', () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0); // center
    expect(controller.arcInProgress, isTrue);
    await controller.handleCanvasTap(5, 0); // start - radius 5
    expect(controller.arcCenterPointId, isNotNull);
    expect(controller.arcStartPointId, isNotNull);

    // Aimed far past the circle - the created end Point must still land
    // exactly on the radius-5 circle, not the raw tap position.
    await controller.handleCanvasTap(0, 100);

    expect(controller.errorMessage, isNull);
    expect(controller.arcInProgress, isFalse);
    expect(controller.arcs.length, 1);
    final arc = controller.arcs.values.single;
    final end = controller.points[arc.endPointId]!;
    expect(end.x, closeTo(0, 1e-9));
    expect(end.y, closeTo(5, 1e-9));
    // Two independent radius DistanceConstraints: center-start, center-end.
    expect(controller.constraints.length, 2);
  });

  test('on-device feedback: a small clockwise cursor sweep after placing the start Point creates a '
      'small clockwise-looking arc, not its complementary ~350-degree counter-clockwise sweep',
      () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(5, 0); // start, angle 0 degrees, radius 5

    // A real cursor-movement event (unlike handleCanvasTap, which jumps
    // straight to the tap position with no tracked movement in between) -
    // 10 degrees clockwise from the start Point's own angle.
    controller.cursorX = 5 * math.cos(-10 * math.pi / 180);
    controller.cursorY = 5 * math.sin(-10 * math.pi / 180);
    controller.moveCursorRelative(0, 0, 1);

    final ghost = controller.activeDrawGhost as ArcGhost;
    // Swapped for preview: the new (swept-to) point reads as "start", the
    // originally-placed Point reads as "end" - so the backend's own
    // always-counter-clockwise-from-start-to-end convention still produces
    // this same small 10-degree arc, not its ~350-degree complement.
    expect(ghost.startX, closeTo(5 * math.cos(-10 * math.pi / 180), 1e-6));
    expect(ghost.startY, closeTo(5 * math.sin(-10 * math.pi / 180), 1e-6));
    expect(ghost.endX, closeTo(5, 1e-6));
    expect(ghost.endY, closeTo(0, 1e-6));

    await controller.handleCanvasTap(
      5 * math.cos(-10 * math.pi / 180),
      5 * math.sin(-10 * math.pi / 180),
    );

    expect(controller.errorMessage, isNull);
    expect(controller.arcs.length, 1);
    final arc = controller.arcs.values.single;
    final start = controller.points[arc.startPointId]!;
    final end = controller.points[arc.endPointId]!;
    expect(start.x, closeTo(5 * math.cos(-10 * math.pi / 180), 1e-6));
    expect(start.y, closeTo(5 * math.sin(-10 * math.pi / 180), 1e-6));
    expect(end.x, closeTo(5, 1e-6));
    expect(end.y, closeTo(0, 1e-6));
  });

  test('on-device feedback: continuing a clockwise cursor sweep past 180 degrees keeps building the '
      'same clockwise arc instead of snapping back to the short counter-clockwise interpretation',
      () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(5, 0); // start, angle 0 degrees, radius 5

    // Sweeps clockwise through -90, -179 degrees, in small steps (each
    // individually far short of 180 degrees, so every step's own shortest-
    // path delta is unambiguous), ending at -179 degrees - net just under a
    // half-circle swept clockwise.
    for (final degrees in [-30, -60, -90, -120, -150, -179]) {
      controller.cursorX = 5 * math.cos(degrees * math.pi / 180);
      controller.cursorY = 5 * math.sin(degrees * math.pi / 180);
      controller.moveCursorRelative(0, 0, 1);
    }

    await controller.handleCanvasTap(
      5 * math.cos(-179 * math.pi / 180),
      5 * math.sin(-179 * math.pi / 180),
    );

    expect(controller.errorMessage, isNull);
    final arc = controller.arcs.values.single;
    final start = controller.points[arc.startPointId]!;
    final end = controller.points[arc.endPointId]!;
    // Swapped, same as the small-sweep case: the swept-to point is "start",
    // the originally-placed Point is "end" - so the backend's own CCW-from-
    // start-to-end convention reconstructs this as a ~181-degree sweep
    // (clockwise-intended), not the short ~179-degree counter-clockwise arc
    // the raw endpoint angles alone would otherwise suggest.
    expect(start.x, closeTo(5 * math.cos(-179 * math.pi / 180), 1e-6));
    expect(start.y, closeTo(5 * math.sin(-179 * math.pi / 180), 1e-6));
    expect(end.x, closeTo(5, 1e-6));
    expect(end.y, closeTo(0, 1e-6));
  });

  group('catmullRomPolyline', () {
    test('fewer than 2 points passes through unchanged (nothing to draw a curve between)', () {
      expect(catmullRomPolyline([]), isEmpty);
      expect(catmullRomPolyline([(1, 2)]), [(1, 2)]);
    });

    test('passes through every input point exactly, at each span boundary', () {
      final points = [(0.0, 0.0), (2.0, 3.0), (5.0, 1.0), (7.0, 4.0)];
      final sampled = catmullRomPolyline(points, segmentsPerSpan: 8);
      // Each span contributes 8 new samples after the shared starting
      // point, so span boundaries land at 0, 8, 16, 24.
      expect(sampled[0], points[0]);
      expect(sampled[8].$1, closeTo(points[1].$1, 1e-9));
      expect(sampled[8].$2, closeTo(points[1].$2, 1e-9));
      expect(sampled[16].$1, closeTo(points[2].$1, 1e-9));
      expect(sampled[16].$2, closeTo(points[2].$2, 1e-9));
      expect(sampled[24].$1, closeTo(points[3].$1, 1e-9));
      expect(sampled[24].$2, closeTo(points[3].$2, 1e-9));
      expect(sampled.length, 25);
    });

    test('exactly 2 points degenerates to a straight line (no neighbours to curve toward)', () {
      final sampled = catmullRomPolyline([(0.0, 0.0), (10.0, 0.0)], segmentsPerSpan: 4);
      for (final p in sampled) {
        expect(p.$2, closeTo(0, 1e-9)); // stays exactly on the straight line y=0
      }
      expect(sampled.last.$1, closeTo(10, 1e-9));
    });
  });

  test('tapping an Arc in select mode, away from its defining Points, recognizes SelectionKind.arc', () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(5, 0); // start, angle 0 degrees
    await controller.handleCanvasTap(0, 5); // end, angle 90 degrees
    controller.exitToSelectMode();

    // On the rim at 45 degrees - within the swept quarter-circle, away
    // from center/start/end.
    final onRim = 5 * math.sqrt(0.5);
    await controller.handleCanvasTap(onRim, onRim);

    expect(controller.selectionSet.length, 1);
    expect(controller.selectionSet.first.kind, SelectionKind.arc);
  });

  test('selecting an Arc in dimension mode builds radius+diameter ghosts', () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(0, 5);
    final arcId = controller.arcs.keys.single;
    controller.enterDimensionMode();

    final onRim = 5 * math.sqrt(0.5);
    await controller.handleCanvasTap(onRim, onRim);

    expect(controller.dimensionSelection.single.kind, SelectionKind.arc);
    expect(controller.dimensionSelection.single.id, arcId);
    expect(controller.ghosts.map((g) => g.kind), containsAll([GhostKind.radius, GhostKind.diameter]));
  });

  test('confirming a new radius for an Arc updates its one real DistanceConstraint - feedback round: '
      'an Arc now has a single editable radius, with the end Point tied via EqualRadiusConstraint '
      'instead of a second independent DistanceConstraint the solver had to be kept in sync by hand',
      () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(0, 5);
    controller.enterDimensionMode();
    final onRim = 5 * math.sqrt(0.5);
    await controller.handleCanvasTap(onRim, onRim);

    await controller.confirmGhostValue('radius', 8.0);

    expect(controller.errorMessage, isNull);
    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>();
    expect(distanceConstraints, hasLength(1));
    expect(distanceConstraints.single.distance, closeTo(8.0, 1e-9));
    expect(controller.constraints.values.whereType<EqualRadiusConstraintDto>(), hasLength(1));
  });

  test('computeDeleteCascade for a directly-selected Arc reports just the Arc - its center/start/end '
      'Points stay (same as Circle) and its own radius constraints are backend-auto-cascaded, not '
      'client-cascaded', () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(0, 5);
    final arc = controller.arcs.values.single;
    controller.exitToSelectMode();

    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.arc, id: arc.id)],
    );

    expect(cascade.arcs, {arc.id});
    expect(cascade.points, isEmpty);
    expect(cascade.constraints, isEmpty);
  });

  test('computeDeleteCascade cascades a deleted Point to the Arc that references it', () async {
    controller.selectDrawTool(SketchTool.arc);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(0, 5);
    final arc = controller.arcs.values.single;
    controller.exitToSelectMode();

    // The start Point specifically, not the center (which snapped onto the
    // origin on the first tap - the origin is never a deletable selection,
    // see [SketchController.selectAll]'s own exclusion).
    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.point, id: arc.startPointId)],
    );

    expect(cascade.arcs, {arc.id});
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
    // positions, each nudged 18px along the perpendicular normal, then
    // averaged - the normal here is _canonicalPerpendicular's fixed
    // "prefer up-screen" convention (negative dy), not raw
    // Offset(-delta.dy, delta.dx), so a rightward line offsets *up* (300 -
    // 18 = 282), not down.
    const defaultAnchor = Offset(500, 282);

    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), constraintId);

    controller.beginLabelDrag(constraintId);
    controller.updateLabelDrag(const Offset(30, -10));
    controller.endLabelDrag();

    // On-device feedback ("dimensions should be movable anywhere"): the
    // drag's perpendicular component (-10 along the up-pointing normal, so
    // the line itself moves a further 10px up: 282 - 10 = 272) and its
    // tangential component (+30 along the line's own rightward direction,
    // sliding the label - not just the whole line - 30px right) are now
    // both honored, computed once by _dimensionLabelPlacement and reused
    // identically by the painter and this hit-test.
    expect(dimensionLabelAt(controller, transform, defaultAnchor, 5), isNull);
    expect(dimensionLabelAt(controller, transform, const Offset(530, 272), 5), constraintId);
  });

  test(
      'P52 bug fix: setLinearOffsetDistance flows through constraintOverlayItems as '
      'sketchLocalOffsetDistance for a confirmed DistanceConstraint, camera-independent unlike '
      'labelOffset', () async {
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

    final beforeItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintLinearDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(beforeItem.sketchLocalOffsetDistance, isNull);
    expect(controller.linearOffsetDistanceFor(constraintId), isNull);

    controller.setLinearOffsetDistance(constraintId, 3.5);

    final afterItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintLinearDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(afterItem.sketchLocalOffsetDistance, 3.5);
    expect(controller.linearOffsetDistanceFor(constraintId), 3.5);
  });

  test(
      'bug fix (on-device feedback: "radius and diameter dimensions are locked a set distance '
      'from the arc or circle - I should be able to move them anywhere"): setRadialLegLength '
      'flows through constraintOverlayItems as sketchLocalLegLength for a confirmed radial '
      'DistanceConstraint, camera-independent unlike labelOffset', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4));
    await controller.confirmGhostValue('radius', 5.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    final beforeItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintRadialDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(beforeItem.sketchLocalLegLength, isNull);
    expect(controller.radialLegLengthFor(constraintId), isNull);

    controller.setRadialLegLength(constraintId, 12.0);

    final afterItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintRadialDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(afterItem.sketchLocalLegLength, 12.0);
    expect(controller.radialLegLengthFor(constraintId), 12.0);
  });

  test(
      'bug fix (on-device feedback: "dimensions should match technical drawing conventions"): '
      'setAngleArcRadius flows through constraintOverlayItems as sketchLocalArcRadius for a '
      'confirmed AngleConstraint', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 0.1); // horizontal line, away from its own midpoint
    await controller.handleCanvasTap(0.1, 8); // vertical line, away from its own midpoint
    await controller.confirmGhostValue('angle', 90.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is AngleConstraintDto).key;

    final beforeItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintAngleDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(beforeItem.sketchLocalArcRadius, isNull);
    expect(controller.angleArcRadiusFor(constraintId), isNull);

    controller.setAngleArcRadius(constraintId, 2.5);

    final afterItem = controller
        .constraintOverlayItems()
        .whereType<ConstraintAngleDimensionItem>()
        .singleWhere((i) => i.constraintId == constraintId);
    expect(afterItem.sketchLocalArcRadius, 2.5);
    expect(controller.angleArcRadiusFor(constraintId), 2.5);
  });

  test(
      'bug fix (on-device feedback: "when zooming in and out, the dimensions should not move '
      'relative to the geometry"): labelOffsetForZoom rescales a raw screen-pixel offset recorded '
      'at one pixelsPerUnit back to the same effective sketch-local vector at a different one',
      () {
    controller.beginLabelDrag('c0');
    controller.updateLabelDrag(const Offset(20, 0), 10.0); // 2.0 sketch units at 10 px/unit
    controller.endLabelDrag();

    expect(controller.labelOffsetFor('c0'), const Offset(20, 0));
    // Same pixelsPerUnit it was recorded at - unchanged.
    expect(controller.labelOffsetForZoom('c0', 10.0), const Offset(20, 0));
    // Zoomed in 2x since the drag - the same 2.0 sketch-unit offset is now
    // 40px, not still 20px (the pre-fix bug: it used to stay a fixed 20px
    // regardless of zoom, silently drifting relative to the geometry).
    expect(controller.labelOffsetForZoom('c0', 20.0), const Offset(40, 0));
    // Zoomed out 4x - correspondingly smaller.
    expect(controller.labelOffsetForZoom('c0', 2.5), const Offset(5, 0));
  });

  test(
      'labelOffsetForZoom falls back to the raw, unscaled offset when there is no recorded zoom '
      'reference yet (e.g. a label offset written before this fix shipped, or via the embedded 3D '
      'viewport\'s own fallback drag path, which passes no pixelsPerUnit)', () {
    controller.beginLabelDrag('c0');
    controller.updateLabelDrag(const Offset(15, 5)); // no pixelsPerUnit passed
    controller.endLabelDrag();

    expect(controller.labelOffsetForZoom('c0', 999.0), const Offset(15, 5));
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

  test(
      'P44c bug fix: beginLabelDrag and endLabelDrag both notify listeners, so a widget-prop-driven '
      'consumer (PartViewport.isDraggingConstraintLabel) sees the grab/drop immediately - on-device '
      'feedback: "when I try to grab a constraint glyph, nothing happens" traced to this being missing',
      () async {
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

    var notifyCount = 0;
    controller.addListener(() => notifyCount++);

    controller.beginLabelDrag(constraintId);
    expect(notifyCount, greaterThan(0), reason: 'beginLabelDrag must notify so isDraggingConstraintLabel flips');

    notifyCount = 0;
    controller.endLabelDrag();
    expect(notifyCount, greaterThan(0), reason: 'endLabelDrag must notify so isDraggingConstraintLabel flips back');
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

  test(
    'P35/P45: availableConstraintOptions offers Radius and Diameter for a lone Circle with no '
    'dimension yet, and addRadiusDimensionFor jumps straight into Dimension mode with it '
    'pre-picked and the matching ghost pre-activated',
    () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(5, 0);
      final circleId = controller.circles.keys.single;

      controller.selectEntity(SketchSelection(kind: SelectionKind.circle, id: circleId));
      final options = controller.availableConstraintOptions;
      expect(options, hasLength(2));
      expect(options.map((o) => o.type), [ConstraintOptionType.radius, ConstraintOptionType.diameter]);

      await controller.applyConstraintOption(ConstraintOptionType.radius);

      expect(controller.mode, SketchMode.dimension);
      expect(controller.dimensionSelection, hasLength(1));
      expect(controller.dimensionSelection.single.kind, SelectionKind.circle);
      expect(controller.dimensionSelection.single.id, circleId);
      expect(controller.ghosts, isNotEmpty);
      expect(controller.activeGhostKey, 'radius');
    },
  );

  test(
    'P45: applyConstraintOption(diameter) jumps into Dimension mode with the diameter ghost '
    'pre-activated instead of radius',
    () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(5, 0);
      final circleId = controller.circles.keys.single;

      controller.selectEntity(SketchSelection(kind: SelectionKind.circle, id: circleId));
      await controller.applyConstraintOption(ConstraintOptionType.diameter);

      expect(controller.mode, SketchMode.dimension);
      expect(controller.activeGhostKey, 'diameter');
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

  test(
      'Bug fix: profileBranchPointIds surfaces the T-junction Point when a third Line lands on an '
      'existing closed-loop corner, so a visually-closed shape shows why it is not picked up as a '
      'profile', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(5, 5);
    controller.cursorX = 0.1;
    controller.cursorY = 0.1;
    await controller.handleCanvasTap(0.1, 0.1); // closes the triangle at (0, 0)
    expect(controller.closedProfileFills, isNotEmpty);
    expect(controller.profileBranchPointIds, isEmpty);

    final corner = controller.lines.values
        .map((l) => l.startPointId)
        .toSet()
        .intersection(controller.lines.values.map((l) => l.endPointId).toSet())
        .first;
    final cornerPoint = controller.points[corner]!;

    // A third Line landing on that same corner (not a new, separate Point)
    // makes it a real T-junction - three non-construction Lines meeting at
    // one Point - which correctly excludes the loop from closed-profile
    // detection, unlike the earlier "closing an open chain" case.
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(cornerPoint.x, cornerPoint.y);
    await controller.handleCanvasTap(10, 10);

    expect(controller.closedProfileFills, isEmpty);
    expect(controller.profileBranchPointIds, contains(corner));
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

  test('a circle cannot be completed with a zero radius - tapping back on the centre is rejected', () async {
    // Feedback round: the second tap now only ever measures a *distance*
    // from the centre (see SketchController._clickCircleTool's own doc
    // comment) - there is no more point-snap/reuse-avoidance step to test
    // here, so tapping back on the exact centre position is simply a
    // zero-radius circle, rejected outright rather than silently falling
    // back to some other nearby Point the way a Line's second tap does.
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // center snaps to the origin
    expect(controller.circleCenterPointId, controller.originPointId);

    // Still hovering the origin for the radius tap.
    await controller.handleCanvasTap(0, 0);

    expect(controller.circles.length, 0);
    expect(controller.circleInProgress, isFalse);
    expect(controller.errorMessage, isNotNull);
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

  // --- Phase 6.2.2: Polygon tool ----------------------------------------------

  test('activeDrawGhost is null while only the polygon center is placed, then previews the full '
      'N-vertex outline once aiming the first vertex', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(4);
    await controller.handleCanvasTap(0, 0); // center
    expect(controller.polygonInProgress, isTrue);

    controller.cursorX = 0;
    controller.cursorY = 0;
    expect(controller.activeDrawGhost, isNull); // cursor exactly on center: no defined rotation

    controller.cursorX = 5;
    controller.cursorY = 0;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<PolygonGhost>());
    final polygon = ghost as PolygonGhost;
    expect(polygon.centerX, 0);
    expect(polygon.centerY, 0);
    expect(polygon.vertices.length, 4);
    expect(polygon.vertices[0].$1, closeTo(5, 1e-9));
    expect(polygon.vertices[0].$2, closeTo(0, 1e-9));
    // A square's opposite vertex, 180 degrees around.
    expect(polygon.vertices[2].$1, closeTo(-5, 1e-9));
    expect(polygon.vertices[2].$2, closeTo(0, 1e-9));
  });

  test('the polygon tool places center then first vertex across two taps, creating N Points, N Lines, '
      'N-1 EqualLengthConstraints, one real circumradius DistanceConstraint, and N-1 '
      'EqualRadiusConstraint ties locking every vertex onto the same circle (feedback round: form is '
      'now locked, not free-floating)', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(5);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // first vertex - radius 10

    expect(controller.errorMessage, isNull);
    expect(controller.polygonInProgress, isFalse);
    expect(controller.lines.length, 5);
    expect(
      controller.points.length,
      1 /* origin/center */ + 5,
    );
    expect(controller.constraints.values.whereType<EqualLengthConstraintDto>().length, 4);
    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>().toList();
    expect(distanceConstraints.length, 1);
    expect(distanceConstraints.single.distance, closeTo(10, 1e-9));
    expect(controller.constraints.values.whereType<EqualRadiusConstraintDto>().length, 4);
  });

  test('a regular polygon survives a vertex drag - equal radii and equal edge lengths are preserved '
      '(feedback round: dragging used to destroy the shape)', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    // Away from the origin, so the shape isn't topologically grounded to it
    // and this fake backend's default dof: 0 doesn't make beginPointDrag
    // treat it as already fully pinned - see isPointFullyPinned.
    await controller.handleCanvasTap(20, 20);
    await controller.handleCanvasTap(30, 20);
    controller.exitToSelectMode();
    // The circumradius DistanceConstraint's own two points are exactly the
    // center and the first vertex - the most direct way to identify either
    // one without guessing at Line ordering.
    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    final vertexId = radiusConstraint.pointBId;

    expect(controller.beginPointDrag(vertexId), isTrue);
    controller.updatePointDrag(8, 6);
    await controller.endPointDrag();

    expect(controller.errorMessage, isNull);
  });

  test(
      'a Polygon edge drag is redirected to a vertex drag on its own start Point, not a '
      'rigid-body line drag (bug fix: independently PATCHing both endpoints used to fight the '
      "equal-radius chain and break the shape - see beginLineDrag)", () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(20, 20);
    await controller.handleCanvasTap(30, 20);
    controller.exitToSelectMode();

    final polygon = controller.polygons.values.single;
    final edgeLineId = polygon.lineIds.first;
    final edgeLine = controller.lines[edgeLineId]!;

    expect(controller.beginLineDrag(edgeLineId), isTrue);

    expect(controller.draggingPointId, edgeLine.startPointId);
    expect(controller.draggingLineId, isNull);
    controller.dropGrabbedEntity(); // clean up the started drag for this assertion-only test.
  });

  test(
      'dragging a Polygon edge (via the beginLineDrag redirect) resizes its circumradius '
      'dimension the same way dragging its vertex directly already does - task #94\'s own '
      'shape-preserving behaviour, reached through the edge-drag entry point too', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(20, 20); // center
    await controller.handleCanvasTap(30, 20); // first vertex - radius 10

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    // Confirming first, same as task #94's own test - see its doc comment
    // for why only the confirmed case resizes deterministically against
    // this fake backend (a still-provisional radius relies on a real
    // constraint solve to reflow the *other* vertices, which this fake
    // doesn't simulate - see updateConstraintValue's own polygon-scaling
    // special case below instead).
    controller.selectConstraint(radiusConstraint.id);
    await controller.updateSelectedConstraintValue(10);
    controller.exitToSelectMode();

    final polygon = controller.polygons.values.single;
    final edgeLineId = polygon.lineIds.first;
    final edgeLine = controller.lines[edgeLineId]!;
    final startVertex = controller.points[edgeLine.startPointId]!;
    controller.cursorX = startVertex.x;
    controller.cursorY = startVertex.y;

    expect(controller.beginLineDrag(edgeLineId), isTrue);
    controller.updatePointDrag(45, 20); // 25 units from the (20, 20) center
    await controller.endPointDrag();

    expect(controller.errorMessage, isNull);
    final updatedRadiusConstraint =
        controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(updatedRadiusConstraint.distance, closeTo(25, 1e-6));

    final center = controller.points[polygon.centerPointId]!;
    for (final id in polygon.vertexPointIds) {
      final vertex = controller.points[id]!;
      final radius = math.sqrt(math.pow(vertex.x - center.x, 2) + math.pow(vertex.y - center.y, 2));
      expect(radius, closeTo(25, 1e-6));
    }
  });

  test(
      'task #94: dragging a Polygon vertex resizes its circumradius dimension instead of the '
      'confirmed DistanceConstraint fighting it back to the old size', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(20, 20); // center
    await controller.handleCanvasTap(30, 20); // first vertex - radius 10

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    final vertexId = radiusConstraint.pointBId;
    // Confirming the radius dimension first (mirrors a user having already
    // set it via the dimension-ghost flow) clears `provisional`, which is
    // exactly the state where a plain point drag used to just fight the
    // now-real DistanceConstraint back to the old radius.
    controller.selectConstraint(radiusConstraint.id);
    await controller.updateSelectedConstraintValue(10);
    controller.exitToSelectMode();

    // Origin cursor set to the vertex's own current position first, so
    // updatePointDrag's (x, y) argument below lands the vertex at exactly
    // that absolute sketch-space position (see [updatePointDrag]'s own doc
    // comment: it moves the Point by the *delta* from this origin cursor,
    // not directly to (x, y)).
    final startVertex = controller.points[vertexId]!;
    controller.cursorX = startVertex.x;
    controller.cursorY = startVertex.y;
    expect(controller.beginPointDrag(vertexId), isTrue);
    controller.updatePointDrag(35, 20); // 15 units from the (20, 20) center
    await controller.endPointDrag();

    expect(controller.errorMessage, isNull);
    final updatedRadiusConstraint =
        controller.constraints.values.whereType<DistanceConstraintDto>().single;
    // The drag grew the circumradius from 10 to 15 - it didn't snap back.
    expect(updatedRadiusConstraint.distance, closeTo(15, 1e-6));

    final center = controller.points[controller.polygons.values.single.centerPointId]!;
    for (final id in controller.polygons.values.single.vertexPointIds) {
      final vertex = controller.points[id]!;
      final radius = math.sqrt(math.pow(vertex.x - center.x, 2) + math.pow(vertex.y - center.y, 2));
      expect(radius, closeTo(15, 1e-6));
    }
  });

  test('task #94: undo after a Polygon vertex-drag-as-circumradius-edit restores the original radius',
      () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(5);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // first vertex - radius 10

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    final vertexId = radiusConstraint.pointBId;
    // Bug fix: only an *already-confirmed* circumradius dimension is
    // reinterpreted as a drag target (see [updatePointDrag]'s own doc
    // comment) - a still-provisional one already resizes correctly under
    // an ordinary drag without needing to be confirmed first, so this test
    // confirms it explicitly to exercise the actual drag-as-dimension-edit
    // path being tested here.
    controller.selectConstraint(radiusConstraint.id);
    await controller.updateSelectedConstraintValue(10);
    controller.exitToSelectMode();

    final startVertex = controller.points[vertexId]!;
    controller.cursorX = startVertex.x;
    controller.cursorY = startVertex.y;
    expect(controller.beginPointDrag(vertexId), isTrue);
    controller.updatePointDrag(20, 0); // 20 units from the (0, 0) center
    await controller.endPointDrag();
    expect(
      controller.constraints.values.whereType<DistanceConstraintDto>().single.distance,
      closeTo(20, 1e-6),
    );

    await controller.undo();

    expect(
      controller.constraints.values.whereType<DistanceConstraintDto>().single.distance,
      closeTo(10, 1e-6),
    );
  });

  test(
      'bug fix: dragging a Polygon vertex while its circumradius is still provisional does not '
      'silently confirm the dimension (a plain drag already resizes it correctly via the '
      'equal-radius chain - confirming it on every drag used to over-constrain the sketch the '
      'moment a second dimension, e.g. an across-flats one, was added on top)', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(20, 20); // center
    await controller.handleCanvasTap(30, 20); // first vertex - radius 10
    controller.exitToSelectMode();

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(radiusConstraint.provisional, isTrue);
    final vertexId = radiusConstraint.pointBId;

    final startVertex = controller.points[vertexId]!;
    controller.cursorX = startVertex.x;
    controller.cursorY = startVertex.y;
    expect(controller.beginPointDrag(vertexId), isTrue);
    controller.updatePointDrag(38, 20);
    await controller.endPointDrag();

    expect(controller.errorMessage, isNull);
    expect(
      controller.constraints.values.whereType<DistanceConstraintDto>().single.provisional,
      isTrue,
      reason: 'a provisional radius drag must not confirm the dimension',
    );
    expect(
      backend.requestLog.any((r) => r.startsWith('PATCH') && r.contains('/constraints/')),
      isFalse,
      reason: 'a provisional radius drag must never PATCH the circumradius constraint at all',
    );
  });

  test(
      'togglePolygonReferenceCircles flips createPolygonReferenceCircles, reflected in the next '
      'ghost preview', () async {
    expect(controller.createPolygonReferenceCircles, isFalse);
    controller.selectDrawTool(SketchTool.polygon);
    await controller.handleCanvasTap(0, 0);
    controller.cursorX = 5;
    controller.cursorY = 0;
    expect((controller.activeDrawGhost as PolygonGhost).showGuideCircles, isFalse);

    controller.togglePolygonReferenceCircles();

    expect(controller.createPolygonReferenceCircles, isTrue);
    expect((controller.activeDrawGhost as PolygonGhost).showGuideCircles, isTrue);
  });

  test(
      'Fix #7: a placed polygon is tracked in controller.polygons so its guide circles can keep '
      'rendering after placement, and undo removes the tracking entry', () async {
    expect(controller.polygons, isEmpty);

    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(5);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);

    expect(controller.polygons, hasLength(1));
    final polygon = controller.polygons.values.single;
    expect(polygon.centerPointId, isNotEmpty);
    expect(polygon.vertexPointIds, hasLength(5));

    await controller.undo();

    expect(controller.polygons, isEmpty);
  });

  test(
      'bug fix (on-device feedback: "the 2 construction circles should be drawn and visible to the '
      'user to dimension and use in the sketch - at the moment they are not shown after placing '
      'the polygon"): with createPolygonReferenceCircles toggled on, placing a Polygon also '
      'creates two real, selectable Circles in controller.circles, and undo removes them too',
      () async {
    expect(controller.createPolygonReferenceCircles, isFalse, reason: 'off by default');
    controller.togglePolygonReferenceCircles();
    expect(controller.circles, isEmpty);

    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);

    final polygon = controller.polygons.values.single;
    expect(polygon.circumscribedCircleId, isNotNull);
    expect(polygon.inscribedCircleId, isNotNull);
    expect(controller.circles.keys, containsAll([polygon.circumscribedCircleId, polygon.inscribedCircleId]));

    final circumscribed = controller.circles[polygon.circumscribedCircleId]!;
    expect(circumscribed.centerPointId, polygon.centerPointId);
    expect(circumscribed.radiusPointId, polygon.vertexPointIds[0]);
    // Every cardinal Point must have actually been fetched into
    // controller.points, not just referenced by id.
    for (final id in circumscribed.cardinalPointIds) {
      expect(controller.points.containsKey(id), isTrue);
    }

    final inscribed = controller.circles[polygon.inscribedCircleId]!;
    expect(inscribed.centerPointId, polygon.centerPointId);
    final inscribedRadiusPoint = controller.points[inscribed.radiusPointId];
    expect(inscribedRadiusPoint, isNotNull);
    final center = controller.points[polygon.centerPointId]!;
    final actualInradius = math.sqrt(
      math.pow(inscribedRadiusPoint!.x - center.x, 2) + math.pow(inscribedRadiusPoint.y - center.y, 2),
    );
    expect(actualInradius, closeTo(10.0 * math.cos(math.pi / 6), 1e-6));

    await controller.undo();

    expect(controller.circles.keys, isNot(containsAll([polygon.circumscribedCircleId, polygon.inscribedCircleId])));
  });

  test(
      'createPolygonReferenceCircles off (the default) creates a Polygon with no reference '
      'circles at all', () async {
    expect(controller.createPolygonReferenceCircles, isFalse);

    controller.selectDrawTool(SketchTool.polygon);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);

    final polygon = controller.polygons.values.single;
    expect(polygon.circumscribedCircleId, isNull);
    expect(polygon.inscribedCircleId, isNull);
    expect(controller.circles, isEmpty);
  });

  test('a placed polygon drops out of controller.polygons once one of its Points is deleted',
      () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(4);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 0);
    expect(controller.polygons, hasLength(1));

    final vertexId = controller.polygons.values.single.vertexPointIds.first;
    controller.exitToSelectMode();
    final vertex = controller.points[vertexId]!;
    await controller.handleCanvasTap(vertex.x, vertex.y);
    expect(controller.selection!.id, vertexId);

    await controller.deleteSelected();

    expect(controller.polygons, isEmpty);
  });

  test('deleteSelected on a directly-selected polygon vertex Point cascades to its tied '
      'EqualRadiusConstraint (bug fix: _constraintReferences used to omit EqualRadiusConstraintDto, '
      'so the backend rejected the deletion as still-referenced)', () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(5);
    await controller.handleCanvasTap(20, 20);
    await controller.handleCanvasTap(30, 20);
    // A vertex tied only via EqualRadiusConstraint (not the single real
    // DistanceConstraint, which is already covered by the drag test above) -
    // any of the equal-radius ties' own radius2_point_id works.
    final equalRadius = controller.constraints.values.whereType<EqualRadiusConstraintDto>().first;
    final vertexId = equalRadius.radius2PointId;
    controller.exitToSelectMode();

    final cascade = controller.computeDeleteCascade([SketchSelection(kind: SelectionKind.point, id: vertexId)]);
    expect(cascade.constraints, contains(equalRadius.id));

    final vertex = controller.points[vertexId]!;
    await controller.handleCanvasTap(vertex.x, vertex.y);
    expect(controller.selection!.id, vertexId);

    await controller.deleteSelected();

    expect(controller.errorMessage, isNull);
    expect(controller.points.containsKey(vertexId), isFalse);
  });

  test('setPolygonSides clamps to [3, 20]', () {
    controller.setPolygonSides(1);
    expect(controller.polygonSides, 3);
    controller.setPolygonSides(50);
    expect(controller.polygonSides, 20);
    controller.setPolygonSides(8);
    expect(controller.polygonSides, 8);
  });

  // --- Phase 6.2.3: Slot tool -------------------------------------------------

  test('activeDrawGhost previews the centerline while only the first slot center is placed', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    expect(controller.slotInProgress, isTrue);

    controller.cursorX = 20;
    controller.cursorY = 0;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<LineGhost>());
    final line = ghost as LineGhost;
    expect(line.startX, 0);
    expect(line.startY, 0);
    expect(line.endX, 20);
    expect(line.endY, 0);
  });

  test('activeDrawGhost previews the full slot outline (2 arc caps + 2 straight sides) once both '
      'centers are placed', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    expect(controller.slotCenter1PointId, isNotNull);
    expect(controller.slotCenter2PointId, isNotNull);

    // Perpendicular distance from (10, 5) to the y=0 centerline is 5.
    controller.cursorX = 10;
    controller.cursorY = 5;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<SlotGhost>());
    final slot = ghost as SlotGhost;
    expect(slot.a.$1, closeTo(0, 1e-9));
    expect(slot.a.$2, closeTo(5, 1e-9));
    expect(slot.b.$1, closeTo(0, 1e-9));
    expect(slot.b.$2, closeTo(-5, 1e-9));
    expect(slot.c.$1, closeTo(20, 1e-9));
    expect(slot.c.$2, closeTo(-5, 1e-9));
    expect(slot.d.$1, closeTo(20, 1e-9));
    expect(slot.d.$2, closeTo(5, 1e-9));
  });

  test('the slot tool places both centers then width across three taps, creating 2 Arcs, 2 Lines, and a '
      'construction centerline, wired with a single shared radius and real tangency', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    await controller.handleCanvasTap(10, 5);

    expect(controller.errorMessage, isNull);
    expect(controller.slotInProgress, isFalse);
    expect(controller.arcs.length, 2);
    // 2 straight sides + 1 construction centerline between the two centres.
    expect(controller.lines.length, 3);
    final centerline = controller.lines.values.firstWhere((line) => line.construction);
    expect(centerline.startPointId, isNotNull);
    expect(centerline.endPointId, isNotNull);
    // A single real, editable radius dimension for the whole Slot: arc1's
    // own one real DistanceConstraint (feedback round: an Arc now has
    // exactly one, with its own end Point tied via EqualRadiusConstraint
    // instead of a second independent DistanceConstraint). Every other
    // radius tie - arc1's own end, arc2's own internal tie (kept - its own
    // radius DistanceConstraint was deleted, not this), and the 2 new ties
    // back to arc1 - is an EqualRadiusConstraint instead.
    expect(controller.constraints.values.whereType<DistanceConstraintDto>().length, 1);
    expect(controller.constraints.values.whereType<EqualRadiusConstraintDto>().length, 4);
    expect(controller.constraints.values.whereType<TangentConstraintDto>().length, 4);

    final arc1 = controller.arcs.values.first; // centered at center 1 (the origin)
    final arc2 = controller.arcs.values.last; // centered at center 2
    expect(controller.points[arc1.centerPointId]!.x, closeTo(0, 1e-9));
    expect(controller.points[arc1.centerPointId]!.y, closeTo(0, 1e-9));
    expect(controller.points[arc2.centerPointId]!.x, closeTo(20, 1e-9));
    expect(controller.points[arc2.centerPointId]!.y, closeTo(0, 1e-9));

    // The two non-construction Lines close the loop: arc1's end -> arc2's
    // start, and arc2's end back to arc1's start.
    final sides = controller.lines.values.where((line) => !line.construction).toList();
    expect(sides.length, 2);
    final line1 = sides.first;
    final line2 = sides.last;
    expect(line1.startPointId, arc1.endPointId);
    expect(line1.endPointId, arc2.startPointId);
    expect(line2.startPointId, arc2.endPointId);
    expect(line2.endPointId, arc1.startPointId);
  });

  test(
      'dragging an intact Slot corner recomputes every other corner instantly via the closed-form '
      'path - no constraint solve involved at all (sketcher rebuild: "the most robust method for '
      'defining these shapes" - a formula has exactly one answer, so there is no wrong root for a '
      'solver to find in the first place). Confirmed by the complete absence of any /solve call '
      'during the drag itself, not just by the end result looking right', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    await controller.handleCanvasTap(10, 5); // radius 5
    controller.exitToSelectMode();
    final arc1 = controller.arcs.values.first;
    final arc2 = controller.arcs.values.last;
    final aId = arc1.startPointId;
    final cIdBefore = arc2.startPointId;
    final cPointBefore = controller.points[cIdBefore]!;

    backend.requestLog.clear();
    expect(controller.beginPointDrag(aId), isTrue);
    await controller.updatePointDrag(2, 8); // (0,5) dragged to (2,8) - a bigger radius

    expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse,
        reason: 'the closed-form path never needs to solve anything');
    // Every corner recomputed instantly, in the very same call - not just
    // the touched one.
    final cPointAfter = controller.points[cIdBefore]!;
    expect(cPointAfter.y, isNot(closeTo(cPointBefore.y, 1e-9)));
    final newRadius = math.sqrt(math.pow(controller.points[aId]!.x - 0, 2) + math.pow(controller.points[aId]!.y, 2));
    final cRadius = math.sqrt(
      math.pow(cPointAfter.x - 20, 2) + math.pow(cPointAfter.y, 2),
    );
    expect(cRadius, closeTo(newRadius, 1e-6));
  });

  test(
      'once a Slot is no longer intact (one of its own Lines individually gone), dragging its '
      'remaining corners falls back to the ordinary drag path instead of the closed-form one - '
      'the shape is no longer intact, so the formula that assumed it still had all its own pieces '
      'no longer applies. Confirmed by the sibling corner staying put instead of being instantly '
      'recomputed, which only the closed-form path ever does synchronously', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    await controller.handleCanvasTap(10, 5); // radius 5
    controller.exitToSelectMode();
    final arc1 = controller.arcs.values.first;
    final arc2 = controller.arcs.values.last;
    final aId = arc1.startPointId;
    final cId = arc2.startPointId;

    final line1 = controller.lines.values.firstWhere(
      (line) => !line.construction && (line.startPointId == arc1.endPointId || line.endPointId == arc1.endPointId),
    );
    // Direct local removal, not deleteSelected(): a real delete now
    // correctly cascades the *whole* Slot away (computeDeleteCascade's own
    // Slot block - see the on-device feedback fix for "some points are not
    // deleting because they are part of a slot but the slot has been
    // deleted"), so there's no longer a "partially trimmed but the Slot
    // record still hangs around" state reachable that way. Removing the
    // Line directly from the local cache is exactly what
    // [_intactSlotForPoint]'s live lines-map check reads, with no other
    // side effects - the same pattern the Ellipse/Rectangle fallback tests
    // already use for the same reason.
    controller.lines.remove(line1.id);
    final cPointBefore = controller.points[cId]!;

    expect(controller.beginPointDrag(aId), isTrue);
    await controller.updatePointDrag(2, 8);

    // The sibling corner never moved - the closed-form path (which would
    // have recomputed it instantly, same as the test above) didn't run,
    // because the Slot is no longer intact.
    final cPointAfter = controller.points[cId]!;
    expect(cPointAfter.x, closeTo(cPointBefore.x, 1e-9));
    expect(cPointAfter.y, closeTo(cPointBefore.y, 1e-9));
  });

  group('Circle closed-form drag (on-device feedback: "when dragging a circle it jumps around '
      'instead of moving smoothly. I think it\'s struggling with the solve" - reproduced directly '
      'against the real solver: a freshly-drawn Circle\'s radius DistanceConstraint is provisional, '
      'so nothing pins it during a general-path drag and the radius can collapse toward zero in a '
      'single step. Closed-form eliminates the solver from this drag entirely, the same fix already '
      'shipped for Polygon/Slot)', () {
    test('dragging the centre translates every cardinal Point by the same delta, radius unchanged, '
        'with zero solver/network calls', () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(20, 20); // centre
      await controller.handleCanvasTap(30, 20); // radius 10 (always placed north regardless of tap angle)
      controller.exitToSelectMode();
      final circle = controller.circles.values.single;
      final northBefore = controller.points[circle.cardinalPointIds[0]]!;
      final eastBefore = controller.points[circle.cardinalPointIds[1]]!;

      backend.requestLog.clear();
      // Origin cursor set to the centre's own current position first, so
      // updatePointDrag's (x, y) argument below lands the centre at exactly
      // that absolute sketch-space position.
      final centre0 = controller.points[circle.centerPointId]!;
      controller.cursorX = centre0.x;
      controller.cursorY = centre0.y;
      expect(controller.beginPointDrag(circle.centerPointId), isTrue);
      await controller.updatePointDrag(25, 25); // centre moves (5, 5)

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse,
          reason: 'the closed-form path never needs to solve anything');
      final northAfter = controller.points[circle.cardinalPointIds[0]]!;
      final eastAfter = controller.points[circle.cardinalPointIds[1]]!;
      expect(northAfter.x, closeTo(northBefore.x + 5, 1e-9));
      expect(northAfter.y, closeTo(northBefore.y + 5, 1e-9));
      expect(eastAfter.x, closeTo(eastBefore.x + 5, 1e-9));
      expect(eastAfter.y, closeTo(eastBefore.y + 5, 1e-9));
    });

    test('dragging the radius Point (north) resizes every other cardinal Point too - the exact '
        'scenario that used to collapse toward zero under the general solver path', () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(20, 20); // centre
      await controller.handleCanvasTap(30, 20); // radius 10
      controller.exitToSelectMode();
      final circle = controller.circles.values.single;
      expect(circle.radiusPointId, circle.cardinalPointIds.first, reason: 'sanity check: this tool always places the radius point north');

      backend.requestLog.clear();
      // Origin cursor set to north's own current position first, so
      // updatePointDrag's (x, y) argument below lands north at exactly that
      // absolute sketch-space position.
      final north0 = controller.points[circle.radiusPointId]!;
      controller.cursorX = north0.x;
      controller.cursorY = north0.y;
      expect(controller.beginPointDrag(circle.radiusPointId), isTrue);
      await controller.updatePointDrag(20, 45); // north dragged out to radius 25

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse);
      final north = controller.points[circle.radiusPointId]!;
      expect(north.x, closeTo(20, 1e-6));
      expect(north.y, closeTo(45, 1e-6));
      for (final id in circle.cardinalPointIds.skip(1)) {
        final p = controller.points[id]!;
        final radius = math.sqrt(math.pow(p.x - 20, 2) + math.pow(p.y - 20, 2));
        expect(radius, closeTo(25, 1e-6), reason: 'every cardinal Point must track the new radius exactly, not collapse');
      }
    });

    test('once a cardinal Point is individually deleted (no longer intact), dragging the centre '
        'falls back to the ordinary drag path instead of the closed-form one', () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(20, 20);
      await controller.handleCanvasTap(30, 20);
      controller.exitToSelectMode();
      final circle = controller.circles.values.single;
      final eastId = circle.cardinalPointIds[1];
      controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: eastId));
      await controller.deleteSelected();
      final northBefore = controller.points[circle.cardinalPointIds[0]]!;

      expect(controller.beginPointDrag(circle.centerPointId), isTrue);
      await controller.updatePointDrag(25, 25);

      // The closed-form path (which would have translated it instantly, per
      // the test above) didn't run - north never moved.
      final northAfter = controller.points[circle.cardinalPointIds[0]]!;
      expect(northAfter.x, closeTo(northBefore.x, 1e-9));
      expect(northAfter.y, closeTo(northBefore.y, 1e-9));
    });
  });

  group('Arc closed-form drag (same on-device bug/fix as Circle - see that group\'s own doc comment - '
      'an Arc\'s own radius DistanceConstraint is provisional too, so the general solver path left it '
      'genuinely free during a drag)', () {
    test('dragging the centre translates start and end by the same delta, radius and sweep unchanged, '
        'with zero solver/network calls', () async {
      controller.selectDrawTool(SketchTool.arc);
      // Off the origin on purpose - the origin itself can never be dragged
      // (see beginPointDrag's own origin guard), and this test drags the
      // centre.
      await controller.handleCanvasTap(20, 20); // center
      await controller.handleCanvasTap(25, 20); // start, radius 5
      await controller.handleCanvasTap(20, 120); // end, lands at (20, 25)
      controller.exitToSelectMode();
      final arc = controller.arcs.values.single;
      final startBefore = controller.points[arc.startPointId]!;
      final endBefore = controller.points[arc.endPointId]!;

      backend.requestLog.clear();
      final center0 = controller.points[arc.centerPointId]!;
      controller.cursorX = center0.x;
      controller.cursorY = center0.y;
      expect(controller.beginPointDrag(arc.centerPointId), isTrue);
      await controller.updatePointDrag(center0.x + 10, center0.y + 10); // centre moves (10, 10)

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse,
          reason: 'the closed-form path never needs to solve anything');
      final startAfter = controller.points[arc.startPointId]!;
      final endAfter = controller.points[arc.endPointId]!;
      expect(startAfter.x, closeTo(startBefore.x + 10, 1e-9));
      expect(startAfter.y, closeTo(startBefore.y + 10, 1e-9));
      expect(endAfter.x, closeTo(endBefore.x + 10, 1e-9));
      expect(endAfter.y, closeTo(endBefore.y + 10, 1e-9));
    });

    test('dragging the start Point resizes the radius and rescales the end Point, preserving the '
        'end Point\'s own angle from centre exactly rather than recomputing it - the exact scenario '
        'that used to collapse toward zero under the general solver path', () async {
      controller.selectDrawTool(SketchTool.arc);
      await controller.handleCanvasTap(0, 0); // center
      await controller.handleCanvasTap(5, 0); // start, radius 5
      await controller.handleCanvasTap(0, 100); // end, lands at (0, 5) - 90 degrees from start
      controller.exitToSelectMode();
      final arc = controller.arcs.values.single;

      backend.requestLog.clear();
      final start0 = controller.points[arc.startPointId]!;
      controller.cursorX = start0.x;
      controller.cursorY = start0.y;
      expect(controller.beginPointDrag(arc.startPointId), isTrue);
      await controller.updatePointDrag(25, 0); // start dragged out to radius 25

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse);
      final start = controller.points[arc.startPointId]!;
      expect(start.x, closeTo(25, 1e-6));
      expect(start.y, closeTo(0, 1e-6));
      final end = controller.points[arc.endPointId]!;
      final endRadius = math.sqrt(math.pow(end.x, 2) + math.pow(end.y, 2));
      expect(endRadius, closeTo(25, 1e-6), reason: 'end Point must track the new radius exactly, not collapse');
      final endAngle = math.atan2(end.y, end.x);
      expect(endAngle, closeTo(math.pi / 2, 1e-6), reason: 'end Point\'s own angle from centre must be preserved');
    });

    test('once the end Point is deleted (no longer intact), dragging the centre falls back to the '
        'ordinary drag path instead of the closed-form one', () async {
      controller.selectDrawTool(SketchTool.arc);
      // Off the origin on purpose - see the test above's own doc comment.
      await controller.handleCanvasTap(20, 20);
      await controller.handleCanvasTap(25, 20);
      await controller.handleCanvasTap(20, 120);
      controller.exitToSelectMode();
      final arc = controller.arcs.values.single;
      controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: arc.endPointId));
      await controller.deleteSelected();
      final startBefore = controller.points[arc.startPointId]!;

      final center0 = controller.points[arc.centerPointId]!;
      controller.cursorX = center0.x;
      controller.cursorY = center0.y;
      expect(controller.beginPointDrag(arc.centerPointId), isTrue);
      await controller.updatePointDrag(center0.x + 5, center0.y + 5);

      // The closed-form path (which would have translated it instantly, per
      // the test above) didn't run - start never moved.
      final startAfter = controller.points[arc.startPointId]!;
      expect(startAfter.x, closeTo(startBefore.x, 1e-9));
      expect(startAfter.y, closeTo(startBefore.y, 1e-9));
    });
  });

  test(
      'dragging a Slot corner reflows the rest of the shape sanely, even when the Slot was drawn '
      'starting at the sketch origin (on-device feedback: "dragging constrained entities is still '
      'horrible... one of the tangent constraints found the wrong solution" - the local solver pins '
      'both the dragged Point *and* the sketch origin into the fixed group every drag-solve; when '
      'the Slot\'s own first center happens to be the origin Point (this test\'s (0, 0) first tap '
      'snaps onto it, same as any real drag started on the visible crosshair), that\'s two fixed '
      'Points on one redundant Tangent+EqualRadius web instead of one, which a diagnostic probe '
      'reproducing this exact fixture found could converge (resultCode 5) to a wildly wrong root - '
      'a non-anchor Point landing thousands of units away - without the anchor-drift check above '
      'ever seeing it, since the anchors themselves land exactly where pinned)', () async {
    final libraryPath = _findHostSlvsLibrary();
    if (libraryPath == null) {
      markTestSkipped('host didsa_slvs_ffi library not built - see client/native/slvs/CMakeLists.txt');
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));
    final localBackend = _FakeBackend();
    final localClient = MockClient((request) async => localBackend.handle(request));
    final localController =
        SketchController(api: SketchApiClient(httpClient: localClient), localSolverBindings: bindings);
    await localController.ensureSketch();

    localController.selectDrawTool(SketchTool.slot);
    await localController.handleCanvasTap(0, 0); // snaps onto the sketch origin Point
    await localController.handleCanvasTap(20, 0);
    await localController.handleCanvasTap(10, 5); // radius 5
    localController.exitToSelectMode();

    final arc1 = localController.arcs.values.first; // centered at the origin
    final arc2 = localController.arcs.values.last; // centered at (20, 0)
    expect(localController.points[arc1.centerPointId]!.x, closeTo(0, 1e-9));
    expect(localController.points[arc1.centerPointId]!.y, closeTo(0, 1e-9));
    final aId = arc1.startPointId;

    final grabbed = localController.beginPointDrag(aId);
    expect(grabbed, isTrue);
    // Gentle incremental drag - the same shape the diagnostic probe used to
    // reproduce the blow-up, expressed as raw cursor positions (the drag
    // started with the cursor at (10, 5), 'a' at (0, 5) - see
    // updatePointDrag's own doc comment for the offset math).
    for (final cursor in [(10.0, 6.0), (8.0, 8.0), (6.0, 10.0), (4.0, 12.0), (2.0, 14.0)]) {
      await localController.updatePointDrag(cursor.$1, cursor.$2);
    }

    // The whole point of the fix: no other Point may land somewhere wildly
    // far from the Slot's own actual size (a ~20x10 shape), whether that
    // came from a (correctly-guarded-against) local blow-up or a sane
    // fallback - a difference of thousands of units is never a legitimate
    // reflow of a 5-unit drag.
    for (final id in [arc1.centerPointId, arc1.endPointId, arc2.centerPointId, arc2.startPointId, arc2.endPointId]) {
      final p = localController.points[id]!;
      expect(p.x.abs() < 500 && p.y.abs() < 500, isTrue,
          reason: 'Point $id blew up to (${p.x}, ${p.y})');
    }
  });

  test(
      'dragging a Polygon vertex through many small steps never lets its EqualLength chain drift '
      'out of tolerance (on-device feedback, round 2: a raw, zero-user-dimension hexagon dragged '
      'into a shape with a visibly short sliver edge - a real EqualLength violation the anchor-drift '
      'and blow-up guards above cannot see, since a Polygon drag never moves anything far or flips '
      'an Arc side. Root-caused via a diagnostic probe reusing this exact 6-side EqualLength + '
      'EqualRadius + AngleConstraint fixture: many small incremental re-seeded local solves in a '
      'row - an ordinary long finger-drag, not any single big jump - compound real, geometry-visible '
      'drift in this redundant constraint chain even while every individual step reports converged)',
      () async {
    final libraryPath = _findHostSlvsLibrary();
    if (libraryPath == null) {
      markTestSkipped('host didsa_slvs_ffi library not built - see client/native/slvs/CMakeLists.txt');
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));
    final localBackend = _FakeBackend();
    final localClient = MockClient((request) async => localBackend.handle(request));
    final localController =
        SketchController(api: SketchApiClient(httpClient: localClient), localSolverBindings: bindings);
    await localController.ensureSketch();

    localController.selectDrawTool(SketchTool.polygon);
    localController.setPolygonSides(6);
    await localController.handleCanvasTap(0, 0); // centre snaps onto the sketch origin Point
    await localController.handleCanvasTap(10, 0); // first vertex - radius 10
    localController.exitToSelectMode();

    final polygon = localController.polygons.values.single;
    final v0Id = polygon.vertexPointIds.first;
    final grabbed = localController.beginPointDrag(v0Id);
    expect(grabbed, isTrue);

    // The same wobbling-circle drag path the diagnostic probe used to
    // reproduce the drift - many tiny re-seeded steps, not one big jump.
    // The drag started with the cursor at (10, 0), v0 also at (10, 0), so
    // updatePointDrag's own origin-offset math (see its doc comment)
    // collapses to "cursor position == target position" here.
    for (var i = 1; i <= 200; i++) {
      final angle = 2 * math.pi * i / 200 * 3; // 3 full loops
      final radius = 10.0 + 3.0 * math.sin(i * 0.37); // wobble the radius too
      await localController.updatePointDrag(radius * math.cos(angle), radius * math.sin(angle));
    }

    double length(String lineId) {
      final line = localController.lines[lineId]!;
      final a = localController.points[line.startPointId]!;
      final b = localController.points[line.endPointId]!;
      return math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
    }

    final lengths = polygon.lineIds.map(length).toList();
    final maxLength = lengths.reduce(math.max);
    final minLength = lengths.reduce(math.min);
    expect(maxLength - minLength, lessThan(1e-2), reason: 'EqualLength chain drifted: $lengths');
  });

  group('On-device feedback: deleting a Point/Line that belongs to a Slot/Rectangle no longer leaves '
      'the owning entity behind, still referencing it server-side ("some points are not deleting '
      'because they are part of a slot but the slot has been deleted")', () {
    test('computeDeleteCascade routes a *partial* hit (one Slot corner Point) to collapsedSlots, not '
        'slots, and leaves its own directly-touched Arc/Line in the ordinary arcs/lines cascade '
        'undeduped - only the pieces actually selected/pulled in are slated for deletion, everything '
        'else the Slot owns must survive', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();
      final slot = controller.slots.values.single;

      final cascade = controller.computeDeleteCascade([SketchSelection(kind: SelectionKind.point, id: slot.aPointId)]);

      expect(cascade.slots, isEmpty);
      expect(cascade.collapsedSlots, {slot.id});
      // aPointId is arc1's own start Point and line2's own end Point - both
      // pulled in and left in the ordinary cascade, not deduped away.
      expect(cascade.arcs, contains(slot.arc1Id));
      expect(cascade.lines, contains(slot.line2Id));
      // Nothing else the Slot owns was touched by this selection - must NOT
      // be swept in too.
      expect(cascade.arcs, isNot(contains(slot.arc2Id)));
      expect(cascade.lines, isNot(contains(slot.centerlineId)));
      expect(cascade.lines, isNot(contains(slot.line1Id)));
    });

    test('deleting a single Slot corner Point succeeds with no error, collapses just the Slot '
        'bookkeeping record, and leaves the rest of the Slot\'s own geometry (its other Arc, other '
        'Lines, other corners) exactly as it was - on-device feedback ("a previous fix went against a '
        'design requirement... cascadeing deletion needs more finesse. if an entity from a rectangle, '
        'slot, polygon is deleted it should collapse into lines and constraints"). Previously this '
        '400ed outright ("Point is still referenced by slot ..."), then a later (now-reverted) fix '
        'cascade-deleted the *whole* Slot instead of just the one Point - both wrong.', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();
      final slot = controller.slots.values.single;
      final aId = slot.aPointId;

      controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: aId));
      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      // The wrapper bookkeeping is gone - it no longer means anything once
      // one of its own pieces went away directly.
      expect(controller.slots, isEmpty);
      expect(controller.points.containsKey(aId), isFalse);
      // Only what actually referenced aPointId (arc1, line2) is gone with
      // it - everything else the Slot used to own survives untouched.
      expect(controller.arcs.containsKey(slot.arc1Id), isFalse);
      expect(controller.lines.containsKey(slot.line2Id), isFalse);
      expect(controller.arcs.containsKey(slot.arc2Id), isTrue);
      expect(controller.lines.containsKey(slot.centerlineId), isTrue);
      expect(controller.lines.containsKey(slot.line1Id), isTrue);
      expect(controller.points.containsKey(slot.bPointId), isTrue);
      expect(controller.points.containsKey(slot.cPointId), isTrue);
      expect(controller.points.containsKey(slot.dPointId), isTrue);
    });

    test('deleting a single Polygon edge Line collapses just the Polygon bookkeeping record - the '
        'other N-1 edges and every vertex survive untouched', () async {
      controller.selectDrawTool(SketchTool.polygon);
      controller.setPolygonSides(5);
      await controller.handleCanvasTap(30, 0); // center
      await controller.handleCanvasTap(40, 0); // first vertex
      controller.exitToSelectMode();
      final polygon = controller.polygons.values.single;
      final deletedLineId = polygon.lineIds[0];

      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: deletedLineId));
      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      expect(controller.polygons, isEmpty);
      expect(controller.lines.containsKey(deletedLineId), isFalse);
      for (final lineId in polygon.lineIds.skip(1)) {
        expect(controller.lines.containsKey(lineId), isTrue);
      }
      for (final vertexId in polygon.vertexPointIds) {
        expect(controller.points.containsKey(vertexId), isTrue);
      }
      expect(controller.points.containsKey(polygon.centerPointId), isTrue);
    });

    test('deleting a single Rectangle edge Line (the exact on-device repro: "if I create a rectangle '
        'and I delete one line the whole rectangle gets deleted") collapses just the Rectangle '
        'bookkeeping record - the other 3 edges, both diagonals, and all 4 corners survive untouched',
        () async {
      controller.selectDrawTool(SketchTool.rectangle);
      controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);
      await controller.handleCanvasTap(2, 2);
      await controller.handleCanvasTap(10, 8);
      controller.exitToSelectMode();
      final rectangle = controller.rectangles.values.single;
      final deletedLineId = rectangle.lineIds[0];

      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: deletedLineId));
      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      expect(controller.rectangles, isEmpty);
      expect(controller.lines.containsKey(deletedLineId), isFalse);
      for (final lineId in rectangle.lineIds.skip(1)) {
        expect(controller.lines.containsKey(lineId), isTrue);
      }
      final diagonalLineId = rectangle.diagonalLineId;
      if (diagonalLineId != null) expect(controller.lines.containsKey(diagonalLineId), isTrue);
      final diagonal2LineId = rectangle.diagonal2LineId;
      if (diagonal2LineId != null) expect(controller.lines.containsKey(diagonal2LineId), isTrue);
      for (final cornerId in rectangle.cornerPointIds) {
        expect(controller.points.containsKey(cornerId), isTrue);
      }
    });

    test('undoing a single-Line delete that collapsed a Rectangle restores that one Line generically '
        '- the Rectangle wrapper itself is not resurrected (there is no backend primitive to reattach '
        'a wrapper to already-existing geometry), but nothing is lost or duplicated: the same corners '
        'and every other edge/diagonal were never touched in the first place', () async {
      controller.selectDrawTool(SketchTool.rectangle);
      controller.setRectangleConstructionMethod(RectangleConstructionMethod.twoCorner);
      await controller.handleCanvasTap(2, 2);
      await controller.handleCanvasTap(10, 8);
      controller.exitToSelectMode();
      final rectangle = controller.rectangles.values.single;
      final deletedLineId = rectangle.lineIds[0];
      final startId = controller.lines[deletedLineId]!.startPointId;
      final endId = controller.lines[deletedLineId]!.endPointId;

      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: deletedLineId));
      await controller.deleteSelected();
      expect(controller.rectangles, isEmpty);
      expect(controller.lines.containsKey(deletedLineId), isFalse);

      await controller.undo();

      expect(controller.errorMessage, isNull);
      expect(controller.rectangles, isEmpty); // wrapper stays gone - documented trade-off.
      final restoredLine = controller.lines.values.singleWhere(
        (l) =>
            (l.startPointId == startId && l.endPointId == endId) ||
            (l.startPointId == endId && l.endPointId == startId),
      );
      expect(restoredLine, isNotNull);
      // No duplicate lines were created between these two corners.
      expect(
        controller.lines.values.where(
          (l) =>
              (l.startPointId == startId && l.endPointId == endId) ||
              (l.startPointId == endId && l.endPointId == startId),
        ),
        hasLength(1),
      );
    });

    test('undoing a fully-consumed Slot delete (every one of its own Points selected, e.g. Select '
        'All) still recreates the whole Slot with a new id, its own radius intact - the original, '
        'well-tested add_slot-based undo path, unaffected by the partial-delete/collapse fix above',
        () async {
      controller.selectDrawTool(SketchTool.slot);
      // Off the origin (0,0) deliberately - a tap there would snap/reuse
      // the sketch's own origin Point instead of creating a fresh centre1
      // Point, and the origin is always excluded from a Point selection
      // (see computeDeleteCascade's own selection switch), which would
      // make this selection wrongly look partial (5 of 6 own Points, not
      // 6 of 6) rather than the "every one of its own Points" case this
      // test means to exercise.
      await controller.handleCanvasTap(30, 0);
      await controller.handleCanvasTap(50, 0);
      await controller.handleCanvasTap(40, 5); // radius 5
      controller.exitToSelectMode();
      final slot = controller.slots.values.single;

      for (final id in [
        slot.center1PointId,
        slot.center2PointId,
        slot.aPointId,
        slot.bPointId,
        slot.cPointId,
        slot.dPointId,
      ]) {
        controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: id));
      }
      final cascade = controller.computeDeleteCascade(controller.selectionSet);
      expect(cascade.slots, {slot.id});
      expect(cascade.collapsedSlots, isEmpty);

      await controller.deleteSelected();
      expect(controller.slots, isEmpty);

      await controller.undo();

      expect(controller.errorMessage, isNull);
      expect(controller.slots.length, 1);
      final restored = controller.slots.values.single;
      final center1 = controller.points[restored.center1PointId]!;
      final a = controller.points[restored.aPointId]!;
      final radius = math.sqrt(math.pow(a.x - center1.x, 2) + math.pow(a.y - center1.y, 2));
      expect(radius, closeTo(5, 1e-6));
    });

    test('Select All then Delete on a Slot does not 404 on a corner Point the Slot\'s own cascade '
        'already pruned - on-device feedback: "Server returned 404: Point not found" after Select '
        'All then Delete on a Slot. Root cause: delete_slot prunes its own now-orphaned corner '
        'Points server-side, exactly like every other shape-delete already does, but the Slot/'
        'Rectangle/Polygon loops were the only ones not feeding that back into the "already gone, '
        'do not delete it again" tracking every other shape-delete loop relies on - Select All '
        'always puts every Point directly in the selection too, so the later explicit per-Point '
        'delete retried one the Slot loop had already removed', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();
      final slot = controller.slots.values.single;

      // Select All: every Point directly in the selection, exactly as
      // sketch_ribbon.dart's own Select All does - not just the one that
      // happens to trigger the Slot's own cascade.
      for (final id in [
        slot.center1PointId,
        slot.center2PointId,
        slot.aPointId,
        slot.bPointId,
        slot.cPointId,
        slot.dPointId,
      ]) {
        controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: id));
      }
      // Mirrors the real backend's delete_slot: its own corner Points are
      // pruned as part of deleting the Slot itself (nothing else
      // references them), reported back the same way delete_line/
      // delete_circle/etc. already do.
      backend.prunedPointIdsOnNextDelete = [
        slot.center1PointId,
        slot.center2PointId,
        slot.aPointId,
        slot.bPointId,
        slot.cPointId,
        slot.dPointId,
      ];

      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      expect(controller.slots, isEmpty);
      expect(controller.points.containsKey(slot.aPointId), isFalse);
      backend.prunedPointIdsOnNextDelete = const [];
    });
  });

  // --- Phase 6.2.4: Ellipse tool ------------------------------------------

  test('activeDrawGhost previews a plain circle while only the ellipse center is placed', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(2, 2);
    expect(controller.ellipseInProgress, isTrue);

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

  test('activeDrawGhost previews the ellipse outline (clamped minor radius) once center and major '
      'point are both placed', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // major point - major radius 10
    expect(controller.ellipseCenterPointId, isNotNull);
    expect(controller.ellipseMajorPointId, isNotNull);

    // Perpendicular distance from (5, 4) to the y=0 major axis is 4.
    controller.cursorX = 5;
    controller.cursorY = 4;
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<EllipseGhost>());
    final ellipse = ghost as EllipseGhost;
    expect(ellipse.centerX, 0);
    expect(ellipse.centerY, 0);
    expect(ellipse.majorX, 10);
    expect(ellipse.majorY, 0);
    expect(ellipse.minorRadius, closeTo(4, 1e-9));

    // Clamped: a cursor further from the axis than the major radius (10)
    // never previews a minor radius exceeding it.
    controller.cursorX = 5;
    controller.cursorY = 50;
    final clamped = controller.activeDrawGhost as EllipseGhost;
    expect(clamped.minorRadius, closeTo(10, 1e-9));
  });

  test('the ellipse tool places center, major point, then minor radius across three taps, creating '
      'one Ellipse with real major+minor axis Points, construction Lines, and constraints', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // major point - major radius 10
    await controller.handleCanvasTap(5, 4); // minor radius 4 (perpendicular distance)

    expect(controller.errorMessage, isNull);
    expect(controller.ellipseInProgress, isFalse);
    expect(controller.ellipses.length, 1);
    final ellipse = controller.ellipses.values.single;
    expect(ellipse.minorRadius, closeTo(4, 1e-9));
    expect(controller.points[ellipse.majorPointId]!.x, closeTo(10, 1e-9));
    expect(controller.points[ellipse.majorPointId]!.y, closeTo(0, 1e-9));
    // The minor-axis Point is real and placed exactly perpendicular to the
    // major axis (feedback round: no longer a bare stored float).
    expect(controller.points[ellipse.minorPointId]!.x, closeTo(0, 1e-9));
    expect(controller.points[ellipse.minorPointId]!.y, closeTo(4, 1e-9));
    // Two full-diameter construction axis Lines (negative tip to positive
    // tip), not center-to-tip spokes - feedback round.
    final majorAxisLine = controller.lines[ellipse.majorAxisLineId]!;
    final minorAxisLine = controller.lines[ellipse.minorAxisLineId]!;
    expect(majorAxisLine.construction, isTrue);
    expect(minorAxisLine.construction, isTrue);
    expect({majorAxisLine.startPointId, majorAxisLine.endPointId},
        {ellipse.majorPointNegId, ellipse.majorPointId});
    expect({minorAxisLine.startPointId, minorAxisLine.endPointId},
        {ellipse.minorPointNegId, ellipse.minorPointId});
    // Major-axis DistanceConstraint, minor-axis DistanceConstraint, 2
    // AtMidpointConstraints (center pinned to each axis Line's midpoint),
    // and the PerpendicularConstraint tying the two axis Lines together.
    expect(controller.constraints.length, 5);
  });

  test('tapping an Ellipse in select mode, away from its defining Points, recognizes SelectionKind.ellipse',
      () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // major point
    await controller.handleCanvasTap(5, 4); // minor radius 4
    controller.exitToSelectMode();

    // On the ellipse's boundary at 45 degrees - away from the centre,
    // major-axis Point, AND minor-axis Point (feedback round: the minor
    // axis is now real, independently-selectable geometry too, so tapping
    // exactly on it would hit SelectionKind.point instead).
    const angle = math.pi / 4;
    final boundaryX = 10 * math.cos(angle);
    final boundaryY = 4 * math.sin(angle);
    controller.cursorX = boundaryX;
    controller.cursorY = boundaryY;
    await controller.handleCanvasTap(boundaryX, boundaryY);

    expect(controller.selectionSet.length, 1);
    expect(controller.selectionSet.first.kind, SelectionKind.ellipse);
  });

  test('selecting an Ellipse in dimension mode builds radius+diameter ghosts for both its major and '
      'minor axes', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipseId = controller.ellipses.keys.single;
    controller.enterDimensionMode();

    // 45 degrees around the boundary - away from the centre, major-axis
    // Point, AND minor-axis Point (see the select-mode test's own comment).
    const angle = math.pi / 4;
    await controller.handleCanvasTap(10 * math.cos(angle), 4 * math.sin(angle));

    expect(controller.dimensionSelection.single.kind, SelectionKind.ellipse);
    expect(controller.dimensionSelection.single.id, ellipseId);
    expect(controller.ghosts.map((g) => g.kind), containsAll([GhostKind.radius, GhostKind.diameter]));
    expect(controller.ghosts.map((g) => g.key), containsAll(['majorradius', 'majordiameter', 'minorradius', 'minordiameter']));
  });

  test('confirming the minor-axis radius ghost PATCHes its DistanceConstraint, feedback round: the '
      'minor axis is now real solver-tracked geometry, not a bare field', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipseId = controller.ellipses.keys.single;
    final ellipse = controller.ellipses[ellipseId]!;
    expect(ellipse.minorRadius, closeTo(4, 1e-9));
    controller.enterDimensionMode();
    const angle = math.pi / 4;
    await controller.handleCanvasTap(10 * math.cos(angle), 4 * math.sin(angle));

    await controller.confirmGhostValue('minorradius', 7.0);

    expect(controller.errorMessage, isNull);
    // Feedback round: the minor radius is now PATCHed via its own real
    // DistanceConstraint (this fake backend doesn't re-solve/move Points on
    // a constraint edit, mirroring the equivalent Circle radius test above -
    // the real backend does move the actual Points, exercised end-to-end by
    // the backend's own pytest suite).
    final minorConstraint = controller.constraints.values.firstWhere(
      (c) =>
          c is DistanceConstraintDto &&
          ((c.pointAId == ellipse.centerPointId && c.pointBId == ellipse.minorPointId) ||
              (c.pointAId == ellipse.minorPointId && c.pointBId == ellipse.centerPointId)),
    ) as DistanceConstraintDto;
    expect(minorConstraint.distance, closeTo(7.0, 1e-9));
    // Major-axis DistanceConstraint, minor-axis DistanceConstraint, 2
    // AtMidpointConstraints, and the PerpendicularConstraint tying the two
    // axis Lines together.
    expect(controller.constraints.length, 5);
  });

  test('computeDeleteCascade for a directly-selected Ellipse reports just the Ellipse - its own '
      'major-axis constraint is auto-cascaded server-side, not something the client separately '
      'queues for deletion', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipseId = controller.ellipses.keys.single;

    final cascade =
        controller.computeDeleteCascade([SketchSelection(kind: SelectionKind.ellipse, id: ellipseId)]);

    expect(cascade.ellipses, {ellipseId});
    expect(cascade.points, isEmpty);
    expect(cascade.constraints, isEmpty);
  });

  test('computeDeleteCascade cascades a deleted Point to the Ellipse that references it', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipse = controller.ellipses.values.single;

    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.point, id: ellipse.majorPointId)],
    );

    expect(cascade.ellipses, {ellipse.id});
  });

  test('computeDeleteCascade cascades a deleted minor-axis Point to the Ellipse that references it '
      '(bug fix: this used to only check the major-axis Point)', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipse = controller.ellipses.values.single;

    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.point, id: ellipse.minorPointId)],
    );

    expect(cascade.ellipses, {ellipse.id});
  });

  test('computeDeleteCascade cascades a directly-selected axis Line up to its owning Ellipse, and '
      'drops the Line from its own cascade set - bug fix: deleting the Line first would otherwise '
      'leave delete_ellipse trying to delete an already-gone Line (the on-device 404)', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipse = controller.ellipses.values.single;

    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.line, id: ellipse.majorAxisLineId)],
    );

    expect(cascade.ellipses, {ellipse.id});
    expect(cascade.lines, isNot(contains(ellipse.majorAxisLineId)));
  });

  test('deleteSelected on a directly-selected axis Line deletes the whole Ellipse cleanly with no '
      'error - end-to-end regression test for the on-device 404', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);
    final ellipseId = controller.ellipses.keys.single;
    final ellipse = controller.ellipses[ellipseId]!;
    controller.exitToSelectMode();
    // A point 1/4 of the way along the major axis Line (centre (0,0) to
    // major point (10,0)) - avoiding the exact midpoint, which hit-tests
    // as its own materializable midpoint target rather than the Line.
    await controller.handleCanvasTap(2.5, 0);
    expect(controller.selectionSet.single.kind, SelectionKind.line);
    expect(controller.selectionSet.single.id, ellipse.majorAxisLineId);

    await controller.deleteSelected();

    expect(controller.errorMessage, isNull);
    expect(controller.ellipses.containsKey(ellipseId), isFalse);
    expect(controller.lines.containsKey(ellipse.majorAxisLineId), isFalse);
    expect(controller.lines.containsKey(ellipse.minorAxisLineId), isFalse);
  });

  group('deleteSelected auto-pruned Point handling (on-device feedback: "when deleting lines, '
      'curves, trimming I end up with floating, redundant points")', () {
    test('a Point the backend reports as auto-pruned is dropped from local state too', () async {
      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.exitToSelectMode();
      final line = controller.lines.values.single;
      final endPointId = line.endPointId;
      // Off the exact midpoint (which hit-tests as its own materializable
      // target, not the Line - see the Ellipse regression test's own
      // comment above for the same pitfall).
      await controller.handleCanvasTap(3, 0); // selects the Line
      expect(controller.selectionSet.single.kind, SelectionKind.line);
      // Simulate the real backend's own auto-prune (Sketch.delete_line):
      // this Line's own endpoint isn't referenced by anything else, so the
      // backend reports it pruned in the same response.
      backend.prunedPointIdsOnNextDelete = [endPointId];

      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      expect(controller.lines.containsKey(line.id), isFalse);
      expect(controller.points.containsKey(endPointId), isFalse);
      backend.prunedPointIdsOnNextDelete = const [];
    });

    test('undo after an auto-pruned delete recreates both the Line and its pruned Point', () async {
      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.exitToSelectMode();
      final line = controller.lines.values.single;
      final endPointId = line.endPointId;
      await controller.handleCanvasTap(3, 0);
      backend.prunedPointIdsOnNextDelete = [endPointId];
      await controller.deleteSelected();
      expect(controller.canUndo, isTrue);
      backend.prunedPointIdsOnNextDelete = const [];

      await controller.undo();

      expect(controller.errorMessage, isNull);
      expect(controller.lines, hasLength(1));
      final restored = controller.lines.values.single;
      expect(controller.points.containsKey(restored.startPointId), isTrue);
      expect(controller.points.containsKey(restored.endPointId), isTrue);
      expect(controller.points[restored.endPointId]!.x, 10.0);
      expect(controller.points[restored.endPointId]!.y, 0.0);
    });

    test('a Point both directly selected and reported as auto-pruned is never deleted twice (no 404)',
        () async {
      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.exitToSelectMode();
      final line = controller.lines.values.single;
      final endPointId = line.endPointId;
      // Directly select both the Line and its own endpoint Point (e.g. a
      // "select all" style selection) - the endpoint would otherwise get a
      // second, explicit DELETE call after the Line's own delete already
      // auto-pruned it server-side, which would 404 against the real
      // backend.
      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: line.id));
      controller.selectEntity(SketchSelection(kind: SelectionKind.point, id: endPointId));
      backend.prunedPointIdsOnNextDelete = [endPointId];

      await controller.deleteSelected();

      expect(controller.errorMessage, isNull);
      expect(controller.points.containsKey(endPointId), isFalse);
      backend.prunedPointIdsOnNextDelete = const [];
    });
  });

  group('Ellipse closed-form drag (same on-device bug/fix as Circle/Arc - both of an Ellipse\'s own '
      'radius DistanceConstraints are provisional too, see the backend Ellipse docstring)', () {
    test('dragging the centre translates every axis Point by the same delta, both radii and the '
        'rotation unchanged, with zero solver/network calls', () async {
      controller.selectDrawTool(SketchTool.ellipse);
      // Off the origin on purpose - the origin itself can never be dragged
      // (see beginPointDrag's own origin guard), and this test drags the
      // centre.
      await controller.handleCanvasTap(20, 20); // center
      await controller.handleCanvasTap(30, 20); // major point - radius 10
      await controller.handleCanvasTap(25, 24); // minor radius 4
      controller.exitToSelectMode();
      final ellipse = controller.ellipses.values.single;
      final majorBefore = controller.points[ellipse.majorPointId]!;
      final majorNegBefore = controller.points[ellipse.majorPointNegId]!;
      final minorBefore = controller.points[ellipse.minorPointId]!;
      final minorNegBefore = controller.points[ellipse.minorPointNegId]!;

      backend.requestLog.clear();
      final center0 = controller.points[ellipse.centerPointId]!;
      controller.cursorX = center0.x;
      controller.cursorY = center0.y;
      expect(controller.beginPointDrag(ellipse.centerPointId), isTrue);
      await controller.updatePointDrag(center0.x + 5, center0.y + 5); // centre moves (5, 5)

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse,
          reason: 'the closed-form path never needs to solve anything');
      final majorAfter = controller.points[ellipse.majorPointId]!;
      final majorNegAfter = controller.points[ellipse.majorPointNegId]!;
      final minorAfter = controller.points[ellipse.minorPointId]!;
      final minorNegAfter = controller.points[ellipse.minorPointNegId]!;
      expect(majorAfter.x, closeTo(majorBefore.x + 5, 1e-9));
      expect(majorAfter.y, closeTo(majorBefore.y + 5, 1e-9));
      expect(majorNegAfter.x, closeTo(majorNegBefore.x + 5, 1e-9));
      expect(majorNegAfter.y, closeTo(majorNegBefore.y + 5, 1e-9));
      expect(minorAfter.x, closeTo(minorBefore.x + 5, 1e-9));
      expect(minorAfter.y, closeTo(minorBefore.y + 5, 1e-9));
      expect(minorNegAfter.x, closeTo(minorNegBefore.x + 5, 1e-9));
      expect(minorNegAfter.y, closeTo(minorNegBefore.y + 5, 1e-9));
    });

    test('dragging the major-axis Point resizes and rotates the whole ellipse, carrying the minor '
        'radius along at its old magnitude rather than recomputing it - the exact scenario that used '
        'to collapse toward zero under the general solver path', () async {
      controller.selectDrawTool(SketchTool.ellipse);
      await controller.handleCanvasTap(0, 0); // center
      await controller.handleCanvasTap(10, 0); // major point, angle 0, radius 10
      await controller.handleCanvasTap(5, 4); // minor radius 4
      controller.exitToSelectMode();
      final ellipse = controller.ellipses.values.single;

      backend.requestLog.clear();
      final major0 = controller.points[ellipse.majorPointId]!;
      controller.cursorX = major0.x;
      controller.cursorY = major0.y;
      expect(controller.beginPointDrag(ellipse.majorPointId), isTrue);
      // Rotate the major axis to 90 degrees and stretch it to radius 20.
      await controller.updatePointDrag(0, 20);

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse);
      final major = controller.points[ellipse.majorPointId]!;
      expect(major.x, closeTo(0, 1e-6));
      expect(major.y, closeTo(20, 1e-6));
      final majorNeg = controller.points[ellipse.majorPointNegId]!;
      expect(majorNeg.x, closeTo(0, 1e-6));
      expect(majorNeg.y, closeTo(-20, 1e-6));
      // Minor axis rotates to stay perpendicular (now pointing along -X/+X)
      // but keeps its own old radius (4), not the major's new one.
      final minor = controller.points[ellipse.minorPointId]!;
      final minorRadius = math.sqrt(math.pow(minor.x, 2) + math.pow(minor.y, 2));
      expect(minorRadius, closeTo(4, 1e-6), reason: 'minor radius must track its own old value, not collapse');
      expect(minor.y, closeTo(0, 1e-6), reason: 'minor axis must stay perpendicular to the new major axis');
    });

    test('dragging the minor-axis Point rescales only the minor radius, projected onto the '
        'perpendicular axis - the major axis is untouched', () async {
      controller.selectDrawTool(SketchTool.ellipse);
      await controller.handleCanvasTap(0, 0); // center
      await controller.handleCanvasTap(10, 0); // major point, radius 10
      await controller.handleCanvasTap(5, 4); // minor radius 4
      controller.exitToSelectMode();
      final ellipse = controller.ellipses.values.single;

      backend.requestLog.clear();
      final minor0 = controller.points[ellipse.minorPointId]!;
      controller.cursorX = minor0.x;
      controller.cursorY = minor0.y;
      expect(controller.beginPointDrag(ellipse.minorPointId), isTrue);
      await controller.updatePointDrag(0, 9); // minor point dragged out to radius 9

      expect(backend.requestLog.any((r) => r.contains('/solve')), isFalse);
      final minor = controller.points[ellipse.minorPointId]!;
      expect(minor.x, closeTo(0, 1e-6));
      expect(minor.y, closeTo(9, 1e-6));
      final major = controller.points[ellipse.majorPointId]!;
      expect(major.x, closeTo(10, 1e-6), reason: 'major axis must be untouched by a minor-axis drag');
      expect(major.y, closeTo(0, 1e-6));
    });

    test('once the minor-axis negative Point is gone (no longer intact), dragging the centre '
        'falls back to the ordinary drag path instead of the closed-form one', () async {
      controller.selectDrawTool(SketchTool.ellipse);
      // Off the origin (unlike every other test in this group) - a
      // grounded centre with real (non-provisional) AtMidpointConstraints
      // still attached to it is a pre-existing rigidity-analysis quirk
      // (unrelated to this change: the *general* path already can't drag
      // such a centre even while the Ellipse is otherwise untouched) that
      // would trip this test's own general-path fallback assertion below
      // for a reason that has nothing to do with what this test verifies.
      await controller.handleCanvasTap(20, 20);
      await controller.handleCanvasTap(30, 20);
      await controller.handleCanvasTap(25, 24);
      controller.exitToSelectMode();
      final ellipse = controller.ellipses.values.single;
      // Direct local removal rather than deleteSelected(): a real delete
      // cascades the minor axis Line (and, in the fake backend, leaves its
      // now-dangling AtMidpoint/Perpendicular constraints behind) - an
      // unrelated fixture quirk that trips the *general* solver path's own
      // over-constrained gating before this test's actual target
      // ([_intactEllipseForPoint]'s live points-map check) ever gets
      // exercised. Removing the Point directly from the local cache is
      // exactly what that check reads, with no other side effects.
      controller.points.remove(ellipse.minorPointNegId);
      final majorBefore = controller.points[ellipse.majorPointId]!;

      final center0 = controller.points[ellipse.centerPointId]!;
      controller.cursorX = center0.x;
      controller.cursorY = center0.y;
      expect(controller.beginPointDrag(ellipse.centerPointId), isTrue);
      await controller.updatePointDrag(30, 30);

      // The closed-form path (which would have translated it instantly, per
      // the test above) didn't run - the major Point never moved.
      final majorAfter = controller.points[ellipse.majorPointId]!;
      expect(majorAfter.x, closeTo(majorBefore.x, 1e-9));
      expect(majorAfter.y, closeTo(majorBefore.y, 1e-9));
    });
  });

  // --- Phase 6.2.5: Spline tool ---------------------------------------------

  test('activeDrawGhost previews nothing while no through-point has been placed yet', () async {
    controller.selectDrawTool(SketchTool.spline);

    expect(controller.splineInProgress, isFalse);
    expect(controller.activeDrawGhost, isNull);
  });

  test('activeDrawGhost previews the straight-segment polyline through every placed through-point '
      'plus the cursor, while the spline is in progress', () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    controller.cursorX = 10;
    controller.cursorY = 0;

    expect(controller.splineInProgress, isTrue);
    final ghost = controller.activeDrawGhost;
    expect(ghost, isA<SplineGhost>());
    final spline = ghost as SplineGhost;
    expect(spline.throughPoints, [(0.0, 0.0), (5.0, 5.0)]);
    expect(spline.cursor, (10.0, 0.0));
  });

  test('the spline tool accumulates through-points across taps with no entity created until Finish, '
      'then commits exactly one Spline spanning every placed through-point', () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(5, 5);
    expect(controller.splines, isEmpty);

    await controller.handleCanvasTap(10, 0);
    await controller.finishSpline();

    expect(controller.splineInProgress, isFalse);
    expect(controller.splines.length, 1);
    final spline = controller.splines.values.single;
    expect(spline.throughPointIds.length, 3);
    expect(controller.points[spline.throughPointIds[0]]!.x, closeTo(0, 1e-9));
    expect(controller.points[spline.throughPointIds[1]]!.x, closeTo(5, 1e-9));
    expect(controller.points[spline.throughPointIds[2]]!.x, closeTo(10, 1e-9));
    // 2 segments (3 through-points) * 2 control points each.
    expect(spline.controlPointIds.length, 4);
  });

  test('finishSpline with fewer than 2 through-points clears the in-progress state without creating '
      'a Spline', () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);

    await controller.finishSpline();

    expect(controller.splines, isEmpty);
    expect(controller.splineInProgress, isFalse);
  });

  test('tapping a Spline in select mode, away from its through-points, recognizes SelectionKind.spline',
      () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.finishSpline();
    controller.exitToSelectMode();

    // Midway along the (degenerate, colinear-control-point) 2-through-point
    // spline - away from both through-points.
    await controller.handleCanvasTap(5, 0);

    expect(controller.selectionSet.length, 1);
    expect(controller.selectionSet.first.kind, SelectionKind.spline);
  });

  test('computeDeleteCascade for a directly-selected Spline reports just the Spline', () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.finishSpline();
    final splineId = controller.splines.keys.single;

    final cascade =
        controller.computeDeleteCascade([SketchSelection(kind: SelectionKind.spline, id: splineId)]);

    expect(cascade.splines, {splineId});
    expect(cascade.points, isEmpty);
  });

  test('computeDeleteCascade cascades a deleted through-point to the Spline that references it',
      () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.finishSpline();
    final spline = controller.splines.values.single;

    // .last, not .first: the first tap at (0, 0) snaps onto the sketch
    // origin, which computeDeleteCascade deliberately never cascades from
    // (the origin can't be deleted - see its own `pointIds.add` guard) -
    // .last is the second tap's own real, non-origin Point.
    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.point, id: spline.throughPointIds.last)],
    );

    expect(cascade.splines, {spline.id});
  });

  test('deleteSelected removes a Spline entirely from local state', () async {
    controller.selectDrawTool(SketchTool.spline);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.finishSpline();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(5, 0);
    expect(controller.selection?.kind, SelectionKind.spline);

    await controller.deleteSelected();

    expect(controller.splines, isEmpty);
  });

  // --- Phase 6.2.6: Text tool -------------------------------------------

  test('activeDrawGhost is always null for the text tool, a single self-terminating tap like the '
      'point tool', () {
    controller.selectDrawTool(SketchTool.text);

    expect(controller.activeDrawGhost, isNull);
  });

  test('the text tool places one Text entity per tap, with default content at the backend\'s '
      'default font/size/rotation', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);

    expect(controller.texts.length, 1);
    final text = controller.texts.values.single;
    expect(text.content, 'Text');
    expect(text.font, 'Open Sans');
    expect(text.size, 10.0);
    expect(text.rotationDegrees, 0.0);
    expect(text.construction, isFalse);
    expect(controller.points[text.anchorPointId]!.x, closeTo(5, 1e-9));
    expect(controller.points[text.anchorPointId]!.y, closeTo(5, 1e-9));
  });

  test('creating a Text entity fetches and caches its preview outline', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final text = controller.texts.values.single;

    final contours = controller.textAbsoluteContours(text);

    expect(contours, isNotNull);
    expect(contours!.length, 1);
    expect(contours.first.outer.length, 4);
    // Default content 'Text' (4 chars) * size 10 * 0.6 = 24 width (see the
    // fake backend's own textPreviewContours).
    expect(contours.first.outer[1].$1 - contours.first.outer[0].$1, closeTo(24, 1e-6));
  });

  test('moving a Text entity\'s anchor Point repositions its cached preview contours with no '
      're-fetch - see SketchTextContourOffsets\'s own doc comment for why', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final text = controller.texts.values.single;
    final before = controller.textAbsoluteContours(text)!.first.outer[0];
    final requestCountBefore = backend.requestLog.length;

    controller.points[text.anchorPointId] = SketchPointView(id: text.anchorPointId, x: 25, y: 25);

    final after = controller.textAbsoluteContours(controller.texts[text.id]!)!.first.outer[0];
    expect(after.$1 - before.$1, closeTo(20, 1e-9));
    expect(after.$2 - before.$2, closeTo(20, 1e-9));
    expect(backend.requestLog.length, requestCountBefore);
  });

  test('tapping inside a Text entity\'s filled shape, in select mode, recognizes '
      'SelectionKind.text', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(0, 0); // anchor snaps to the origin
    controller.exitToSelectMode();

    // Default 'Text' content -> a 24x10 rectangle from (0, 0) to (24, 10)
    // (see the fake backend's own textPreviewContours) - well inside it.
    await controller.handleCanvasTap(12, 5);

    expect(controller.selectionSet.length, 1);
    expect(controller.selectionSet.first.kind, SelectionKind.text);
  });

  test('computeDeleteCascade for a directly-selected Text reports just the Text', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final textId = controller.texts.keys.single;

    final cascade =
        controller.computeDeleteCascade([SketchSelection(kind: SelectionKind.text, id: textId)]);

    expect(cascade.texts, {textId});
    expect(cascade.points, isEmpty);
  });

  test('computeDeleteCascade cascades a deleted anchor Point to the Text that references it',
      () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final text = controller.texts.values.single;

    final cascade = controller.computeDeleteCascade(
      [SketchSelection(kind: SelectionKind.point, id: text.anchorPointId)],
    );

    expect(cascade.texts, {text.id});
  });

  test('deleteSelected removes a Text entirely from local state', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(0, 0);
    controller.exitToSelectMode();
    await controller.handleCanvasTap(12, 5);
    expect(controller.selection?.kind, SelectionKind.text);

    await controller.deleteSelected();

    expect(controller.texts, isEmpty);
  });

  test('toggleSelectedConstruction flips a Text entity\'s construction flag', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(0, 0);
    controller.exitToSelectMode();
    await controller.handleCanvasTap(12, 5);
    expect(controller.selectedIsConstruction, isFalse);

    await controller.toggleSelectedConstruction();

    expect(controller.texts.values.single.construction, isTrue);
  });

  group('multi-selection Make Construction/Make Solid (on-device feedback)', () {
    Future<void> placeTwoLines() async {
      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(5, 5);
      await controller.handleCanvasTap(15, 5);
      controller.finishChain();
      await controller.handleCanvasTap(5, 50);
      await controller.handleCanvasTap(15, 50);
      controller.finishChain();
      controller.exitToSelectMode();
    }

    test('offers only Make Const. when every selected Line is solid', () async {
      await placeTwoLines();
      controller.selectInRect(const Rect.fromLTRB(0, 0, 20, 60));
      expect(controller.selectionSet.length, greaterThanOrEqualTo(2));

      final toggles = controller.availableConstructionToggles;

      expect(toggles.showMakeConstruction, isTrue);
      expect(toggles.showMakeSolid, isFalse);
    });

    test('setSelectedConstruction(true) marks every selected Line construction at once', () async {
      await placeTwoLines();
      controller.selectInRect(const Rect.fromLTRB(0, 0, 20, 60));

      await controller.setSelectedConstruction(true);

      expect(controller.lines.values.every((line) => line.construction), isTrue);
    });

    test('offers both Make Const. and Make Solid once the selection mixes construction and solid '
        'entities', () async {
      await placeTwoLines();
      final firstLineId = controller.lines.keys.first;
      controller.selectInRect(const Rect.fromLTRB(4, 4, 16, 6)); // just the first Line + endpoints
      expect(controller.selectionSet.any((s) => s.kind == SelectionKind.line && s.id == firstLineId),
          isTrue);
      await controller.setSelectedConstruction(true);
      expect(controller.lines[firstLineId]!.construction, isTrue);

      controller.selectInRect(const Rect.fromLTRB(0, 0, 20, 60)); // both Lines now
      final toggles = controller.availableConstructionToggles;

      expect(toggles.showMakeConstruction, isTrue); // the still-solid second Line
      expect(toggles.showMakeSolid, isTrue); // the now-construction first Line
    });

    test('setSelectedConstruction(false) only touches entities that need to change', () async {
      await placeTwoLines();
      final firstLineId = controller.lines.keys.first;
      controller.selectInRect(const Rect.fromLTRB(4, 4, 16, 6));
      await controller.setSelectedConstruction(true); // first Line -> construction
      controller.selectInRect(const Rect.fromLTRB(0, 0, 20, 60)); // both Lines, mixed state
      backend.requestLog.clear();

      await controller.setSelectedConstruction(false); // Make Solid

      expect(controller.lines.values.every((line) => !line.construction), isTrue);
      // Only the one Line that actually needed to change was PATCHed - the
      // already-solid second Line was skipped, not redundantly re-sent.
      expect(backend.requestLog.where((r) => r.contains('/lines/$firstLineId')), hasLength(1));
    });
  });

  test('setTextProperties PATCHes content/size/rotation and refreshes the cached preview',
      () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final textId = controller.texts.keys.single;

    await controller.setTextProperties(textId, content: 'Hi', size: 20.0, rotationDegrees: 90.0);

    final updated = controller.texts[textId]!;
    expect(updated.content, 'Hi');
    expect(updated.size, 20.0);
    expect(updated.rotationDegrees, 90.0);
    // 'Hi' (2 chars) * 20 * 0.6 = 24 width, confirming the preview was
    // re-fetched against the *new* content/size, not stale - checked via
    // the Euclidean distance between the first two corners (rotation-
    // invariant), since a 90-degree rotation puts that 24-unit edge along
    // y, not x (cos(90 deg) approx 0), not along x the way it would be
    // at the default rotation=0 every other test above uses.
    final contours = controller.textAbsoluteContours(updated);
    expect(contours!.first.outer.length, 4);
    final corner0 = contours.first.outer[0];
    final corner1 = contours.first.outer[1];
    final edgeLength = math.sqrt(
      math.pow(corner1.$1 - corner0.$1, 2) + math.pow(corner1.$2 - corner0.$2, 2),
    );
    expect(edgeLength, closeTo(24, 1e-6));
  });

  test('setTextProperties PATCHes font and undoing restores the previous font (feedback round: font '
      'is now user-editable, not fixed at the backend default)', () async {
    controller.selectDrawTool(SketchTool.text);
    await controller.handleCanvasTap(5, 5);
    final textId = controller.texts.keys.single;
    expect(controller.texts[textId]!.font, 'Open Sans');

    await controller.setTextProperties(textId, font: 'IBM Plex Mono');

    expect(controller.texts[textId]!.font, 'IBM Plex Mono');

    await controller.undo();

    expect(controller.texts[textId]!.font, 'Open Sans');
  });

  test('textFontOptions offers a small, fixed set of fonts, defaulting to Open Sans', () {
    expect(textFontOptions, contains('Open Sans'));
    expect(textFontOptions.length, greaterThan(1));
    expect(textFontOptions.toSet().length, textFontOptions.length);
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

    // On the circle's edge (radius 5, centered on the origin) but off every
    // cardinal axis - every Circle gets all four North/East/South/West
    // Points (see Sketch._add_cardinal_points), so a diagonal spot is the
    // only genuinely empty-space point on the boundary.
    controller.cursorX = 5 * math.cos(math.pi / 4);
    controller.cursorY = 5 * math.sin(math.pi / 4);

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

  test(
      'selectedPointDeleteBlockedReason no longer flags a point referenced by a line - '
      'deleting it now cascades to the line instead of being disallowed', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(10, 10);
    final startId = controller.chainFirstPointId;
    await controller.handleCanvasTap(15, 10);
    controller.finishChain();
    controller.exitToSelectMode();
    final lineId = controller.lines.keys.first;

    await controller.handleCanvasTap(10, 10);

    expect(controller.selection!.id, startId);
    expect(controller.selectedPointDeleteBlockedReason, isNull);

    await controller.deleteSelected();

    expect(controller.points.containsKey(startId), isFalse);
    expect(controller.lines.containsKey(lineId), isFalse);
    expect(controller.errorMessage, isNull);
  });

  test(
      'selectedPointDeleteBlockedReason no longer flags a point referenced by a circle - '
      'deleting it now cascades to the circle instead of being disallowed', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(10, 10);
    final centerId = controller.circleCenterPointId;
    await controller.handleCanvasTap(15, 10);
    controller.exitToSelectMode();
    final circleId = controller.circles.keys.first;

    await controller.handleCanvasTap(10, 10);

    expect(controller.selection!.id, centerId);
    expect(controller.selectedPointDeleteBlockedReason, isNull);

    await controller.deleteSelected();

    expect(controller.points.containsKey(centerId), isFalse);
    expect(controller.circles.containsKey(circleId), isFalse);
    expect(controller.errorMessage, isNull);
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

  group('pickReferenceGhostVertex (Sketcher-roadmap Phase 4.3 v1)', () {
    Future<(SketchController, _FakeBackend)> adoptedController() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99', partId: 'part-1', sketchFeatureId: 'sketch-feat-1');
      return (freshController, freshBackend);
    }

    test('materializes a real Point and adds it to the dimension pick', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();

      await freshController.pickReferenceGhostVertex('body-1', 3);

      expect(freshBackend.externalReferenceRequestCount, 1);
      expect(freshController.dimensionSelection, hasLength(1));
      expect(freshController.dimensionSelection.single.kind, SelectionKind.point);
      final pointId = freshController.dimensionSelection.single.id;
      expect(freshController.points.containsKey(pointId), isTrue);
      expect(freshController.errorMessage, isNull);
    });

    test('re-picking the same body vertex reuses the already-materialized Point', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();
      await freshController.pickReferenceGhostVertex('body-1', 3);
      final firstPointId = freshController.dimensionSelection.single.id;
      // Toggling the same pick off (mirrors _applyDimensionHit's own
      // "tapping an already-picked entity again removes it" rule).
      await freshController.pickReferenceGhostVertex('body-1', 3);
      expect(freshController.dimensionSelection, isEmpty);

      await freshController.pickReferenceGhostVertex('body-1', 3);

      expect(freshBackend.externalReferenceRequestCount, 1); // still just the one network call
      expect(freshController.dimensionSelection.single.id, firstPointId);
    });

    test('picking two different body vertices materializes two distinct Points, showing dimension ghosts',
        () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();

      await freshController.pickReferenceGhostVertex('body-1', 0);
      await freshController.pickReferenceGhostVertex('body-1', 1);

      expect(freshBackend.externalReferenceRequestCount, 2);
      expect(freshController.dimensionSelection, hasLength(2));
      expect(freshController.ghosts.map((g) => g.key).toSet(), {'v', 'h', 'linear'});
    });

    test('is a no-op without a documentPartId/sketchFeatureId (e.g. a bare, non-Part sketch)', () async {
      // The shared `controller` from setUp() called ensureSketch(), which
      // never sets these - the same as any Sketch reached outside PartScreen.
      controller.enterDimensionMode();

      await controller.pickReferenceGhostVertex('body-1', 0);

      expect(controller.dimensionSelection, isEmpty);
    });
  });

  group('pickReferenceGhostEdge (Sketcher-roadmap Phase 4.3 v2)', () {
    Future<(SketchController, _FakeBackend)> adoptedController() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99', partId: 'part-1', sketchFeatureId: 'sketch-feat-1');
      return (freshController, freshBackend);
    }

    test('materializes a real Line (and its two endpoint Points) and adds it to the dimension pick',
        () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();

      await freshController.pickReferenceGhostEdge('body-1', 0);

      expect(freshBackend.externalEdgeReferenceRequestCount, 1);
      expect(freshController.dimensionSelection, hasLength(1));
      expect(freshController.dimensionSelection.single.kind, SelectionKind.line);
      final lineId = freshController.dimensionSelection.single.id;
      final line = freshController.lines[lineId];
      expect(line, isNotNull);
      expect(freshController.points.containsKey(line!.startPointId), isTrue);
      expect(freshController.points.containsKey(line.endPointId), isTrue);
      expect(freshController.ghosts.map((g) => g.key).toSet(), {'length'});
      expect(freshController.errorMessage, isNull);
      // On-device feedback (bug fix): a materialized Body edge is a
      // reference to dimension against, not new solid geometry the user
      // drew - it must come back construction (see create_external_edge_
      // reference's own construction=True).
      expect(line.construction, isTrue);
    });

    test('re-picking the same body edge reuses the already-materialized Line', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();
      await freshController.pickReferenceGhostEdge('body-1', 0);
      final firstLineId = freshController.dimensionSelection.single.id;
      // Toggling the same pick off (mirrors _applyDimensionHit's own
      // "tapping an already-picked entity again removes it" rule).
      await freshController.pickReferenceGhostEdge('body-1', 0);
      expect(freshController.dimensionSelection, isEmpty);

      await freshController.pickReferenceGhostEdge('body-1', 0);

      expect(freshBackend.externalEdgeReferenceRequestCount, 1); // still just the one network call
      expect(freshController.dimensionSelection.single.id, firstLineId);
    });

    test('picking two different (parallel) body edges shows a lineDistance ghost', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterDimensionMode();

      await freshController.pickReferenceGhostEdge('body-1', 0);
      await freshController.pickReferenceGhostEdge('body-1', 1);

      expect(freshBackend.externalEdgeReferenceRequestCount, 2);
      expect(freshController.dimensionSelection, hasLength(2));
      expect(freshController.ghosts.map((g) => g.key).toSet(), {'lineDistance'});
    });

    test('is a no-op without a documentPartId/sketchFeatureId (e.g. a bare, non-Part sketch)', () async {
      controller.enterDimensionMode();

      await controller.pickReferenceGhostEdge('body-1', 0);

      expect(controller.dimensionSelection, isEmpty);
    });
  });

  group('pickConvertEntityVertex (P48, Sketcher-roadmap Phase 9 v1: Convert Entities)', () {
    Future<(SketchController, _FakeBackend)> adoptedController() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99', partId: 'part-1', sketchFeatureId: 'sketch-feat-1');
      return (freshController, freshBackend);
    }

    test('materializes a real, non-construction Point (not a dimension pick)', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterConvertEntitiesMode();

      await freshController.pickConvertEntityVertex('body-1', 3);

      expect(freshBackend.convertVertexRequestCount, 1);
      // Unlike pickReferenceGhostVertex, this never touches dimensionSelection
      // - Convert Entities just drops real geometry into the sketch.
      expect(freshController.dimensionSelection, isEmpty);
      expect(freshController.points, hasLength(2)); // origin + the converted point
      expect(freshController.errorMessage, isNull);
    });

    test('undo deletes the Point this call created', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterConvertEntitiesMode();
      await freshController.pickConvertEntityVertex('body-1', 3);
      final pointId = freshController.points.keys.firstWhere((id) => id != 'origin-99');
      expect(freshController.canUndo, isTrue);

      await freshController.undo();

      expect(freshController.points.containsKey(pointId), isFalse);
      expect(freshBackend.points.containsKey(pointId), isFalse);
    });

    test('re-picking the same body vertex (backend reuses the existing Point) pushes no extra undo entry',
        () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterConvertEntitiesMode();
      await freshController.pickConvertEntityVertex('body-1', 3);

      await freshController.pickConvertEntityVertex('body-1', 3);

      expect(freshBackend.convertVertexRequestCount, 2); // still hits the network each tap...
      expect(freshController.points, hasLength(2)); // ...but the backend reused the same Point id
      // One undo should remove the Point entirely, proving the second pick
      // never pushed its own delete entry on top of the first's.
      await freshController.undo();
      expect(freshController.points, hasLength(1));
      expect(freshController.canUndo, isFalse);
    });

    test('is a no-op without a documentPartId/sketchFeatureId (e.g. a bare, non-Part sketch)', () async {
      controller.enterConvertEntitiesMode();
      final pointCountBefore = controller.points.length;

      await controller.pickConvertEntityVertex('body-1', 0);

      expect(controller.points, hasLength(pointCountBefore));
    });
  });

  group('pickConvertEntityEdge (P48, Sketcher-roadmap Phase 9 v1: Convert Entities)', () {
    Future<(SketchController, _FakeBackend)> adoptedController() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99', partId: 'part-1', sketchFeatureId: 'sketch-feat-1');
      return (freshController, freshBackend);
    }

    test('materializes a real, non-construction Line and its two endpoint Points', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterConvertEntitiesMode();

      await freshController.pickConvertEntityEdge('body-1', 0);

      expect(freshBackend.convertEdgeRequestCount, 1);
      expect(freshController.dimensionSelection, isEmpty);
      expect(freshController.lines, hasLength(1));
      final line = freshController.lines.values.single;
      expect(line.construction, isFalse);
      expect(freshController.points.containsKey(line.startPointId), isTrue);
      expect(freshController.points.containsKey(line.endPointId), isTrue);
      expect(freshController.errorMessage, isNull);
    });

    test('undo deletes the Line and both Points this call created, lines before points', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterConvertEntitiesMode();
      await freshController.pickConvertEntityEdge('body-1', 0);
      final line = freshController.lines.values.single;
      final lineId = line.id;
      final startId = line.startPointId;
      final endId = line.endPointId;

      await freshController.undo();

      expect(freshController.lines.containsKey(lineId), isFalse);
      expect(freshController.points.containsKey(startId), isFalse);
      expect(freshController.points.containsKey(endId), isFalse);
      expect(freshBackend.lines.containsKey(lineId), isFalse);
    });

    test('is a no-op without a documentPartId/sketchFeatureId (e.g. a bare, non-Part sketch)', () async {
      controller.enterConvertEntitiesMode();
      final lineCountBefore = controller.lines.length;

      await controller.pickConvertEntityEdge('body-1', 0);

      expect(controller.lines, hasLength(lineCountBefore));
    });
  });

  group('pickBodyEdgeForOffset (on-device feedback: "in the offset tool, I should be able to select '
      'edges from other bodies to create sketch geometry offset from the body edges")', () {
    Future<(SketchController, _FakeBackend)> adoptedController() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99', partId: 'part-1', sketchFeatureId: 'sketch-feat-1');
      return (freshController, freshBackend);
    }

    test(
        'converts the Body edge, then accumulates it into the pick set (bug fix: "when I select the '
        'first edge, it sends me to the text box... then I can\'t add more lines or curves")', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterOffsetMode();

      await freshController.pickBodyEdgeForOffset('body-1', 0);

      expect(freshBackend.convertEdgeRequestCount, 1);
      expect(freshController.lines, hasLength(1));
      final line = freshController.lines.values.single;
      expect(line.construction, isFalse);
      // Not yet in offsetPreviewTargets - only Finish opens the value bar,
      // same as a Sketch-entity Line/Arc pick.
      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshController.selectionSet, hasLength(1));
      expect(freshController.selectionSet.single.kind, SelectionKind.line);
      expect(freshController.selectionSet.single.id, line.id);

      // A second Body-edge tap keeps accumulating rather than jumping
      // straight to the value bar.
      await freshController.pickBodyEdgeForOffset('body-1', 1);
      expect(freshController.selectionSet, hasLength(2));

      freshController.finishOffsetChain();
      expect(freshController.offsetPreviewTargets, hasLength(2));
    });

    test('is a no-op without a documentPartId/sketchFeatureId (e.g. a bare, non-Part sketch)', () async {
      controller.enterOffsetMode();
      final lineCountBefore = controller.lines.length;

      await controller.pickBodyEdgeForOffset('body-1', 0);

      expect(controller.lines, hasLength(lineCountBefore));
      expect(controller.offsetPreviewTargets, isNull);
    });

    test(
        'bug fix ("when I offset a curved edge it creates a straight line"): a curved Body edge '
        'converts as a real Arc, with its own center Point, and accumulates as an Arc pick', () async {
      final (freshController, freshBackend) = await adoptedController();
      freshController.enterOffsetMode();

      await freshController.pickBodyEdgeForOffset('body-1', 99); // 99 = this fake's "curved edge" sentinel

      expect(freshController.lines, isEmpty);
      expect(freshController.arcs, hasLength(1));
      final arc = freshController.arcs.values.single;
      expect(arc.construction, isFalse);
      expect(freshController.points.containsKey(arc.centerPointId), isTrue);
      expect(freshController.selectionSet, hasLength(1));
      expect(freshController.selectionSet.single.kind, SelectionKind.arc);
      expect(freshController.selectionSet.single.id, arc.id);

      final centerId = arc.centerPointId;
      final startId = arc.startPointId;
      final endId = arc.endPointId;

      await freshController.undo();

      expect(freshController.arcs.containsKey(arc.id), isFalse);
      expect(freshController.points.containsKey(centerId), isFalse);
      expect(freshController.points.containsKey(startId), isFalse);
      expect(freshController.points.containsKey(endId), isFalse);
      expect(freshBackend.requestLog.any((r) => r.contains('DELETE') && r.contains('/arcs/')), isTrue);
    });
  });

  group('offsetLine/offsetCircle/offsetArc (P49, Sketcher-roadmap Phase 9 v1: Offset Entities)', () {
    Future<(SketchController, _FakeBackend)> adoptedControllerWithLine() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99');
      return (freshController, freshBackend);
    }

    test('offsetLine materializes a new, real, non-construction Line', () async {
      final (freshController, _) = await adoptedControllerWithLine();

      await freshController.offsetLine('line-a', 2.0);

      expect(freshController.lines, hasLength(2));
      final offsetLine = freshController.lines.values.firstWhere((l) => l.id != 'line-a');
      expect(offsetLine.construction, isFalse);
    });

    test('undo after offsetLine deletes the new Line and its new Points', () async {
      final (freshController, freshBackend) = await adoptedControllerWithLine();
      await freshController.offsetLine('line-a', 2.0);
      final offsetLine = freshController.lines.values.firstWhere((l) => l.id != 'line-a');
      final newLineId = offsetLine.id;
      final newStartId = offsetLine.startPointId;
      final newEndId = offsetLine.endPointId;

      await freshController.undo();

      expect(freshController.lines.containsKey(newLineId), isFalse);
      expect(freshController.points.containsKey(newStartId), isFalse);
      expect(freshController.points.containsKey(newEndId), isFalse);
      expect(freshBackend.lines.containsKey(newLineId), isFalse);
    });

    test('offsetting by a distance whose Points already exist reuses them, with no extra undo entry',
        () async {
      final (freshController, _) = await adoptedControllerWithLine();
      // First offset creates the shared 'offset-start-3.0'/'offset-end-3.0'
      // points (see the fake backend's own offset-line route above).
      await freshController.offsetLine('line-a', 3.0);
      final pointCountAfterFirst = freshController.points.length;

      // A second, independent offsetLine call landing on the exact same
      // derived points (the fake keys them by distance) - mirrors the real
      // backend's `add_or_reuse_point` reuse case.
      await freshController.offsetLine('line-a', 3.0);

      expect(freshController.points, hasLength(pointCountAfterFirst)); // no new Points
      expect(freshController.lines, hasLength(3)); // line-a + two offset Lines sharing Points
      // Undoing the second call should remove only its own Line - the
      // shared Points must survive, since the first call's Line still
      // references them.
      await freshController.undo();
      expect(freshController.points, hasLength(pointCountAfterFirst));
      expect(freshController.lines, hasLength(2));
    });

    test('offsetCircle materializes a new Circle sharing the original center Point', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 5.0, 'y': 0.0};
      freshBackend.circles['circle-a'] = {
        'id': 'circle-a',
        'center_point_id': 'point-a',
        'radius_point_id': 'point-b',
        'radius': 5.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99');

      await freshController.offsetCircle('circle-a', 2.0);

      expect(freshController.circles, hasLength(2));
      final offsetCircle = freshController.circles.values.firstWhere((c) => c.id != 'circle-a');
      expect(offsetCircle.centerPointId, 'point-a'); // same center - concentric
      expect(offsetCircle.construction, isFalse);
    });

    test('undo after offsetCircle deletes the new Circle and its new radius Point, keeping the shared center',
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 5.0, 'y': 0.0};
      freshBackend.circles['circle-a'] = {
        'id': 'circle-a',
        'center_point_id': 'point-a',
        'radius_point_id': 'point-b',
        'radius': 5.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99');
      await freshController.offsetCircle('circle-a', 2.0);
      final offsetCircle = freshController.circles.values.firstWhere((c) => c.id != 'circle-a');
      final newCircleId = offsetCircle.id;
      final newRadiusPointId = offsetCircle.radiusPointId;

      await freshController.undo();

      expect(freshController.circles.containsKey(newCircleId), isFalse);
      expect(freshController.points.containsKey(newRadiusPointId), isFalse);
      expect(freshController.points.containsKey('point-a'), isTrue); // shared center survives
    });

    test('offsetArc materializes a new Arc sharing the original center Point', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 5.0, 'y': 0.0};
      freshBackend.points['point-c'] = {'id': 'point-c', 'x': 0.0, 'y': 5.0};
      freshBackend.arcs['arc-a'] = {
        'id': 'arc-a',
        'center_point_id': 'point-a',
        'start_point_id': 'point-b',
        'end_point_id': 'point-c',
        'radius': 5.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99');

      await freshController.offsetArc('arc-a', 2.0);

      expect(freshController.arcs, hasLength(2));
      final offsetArc = freshController.arcs.values.firstWhere((a) => a.id != 'arc-a');
      expect(offsetArc.centerPointId, 'point-a');
      expect(offsetArc.construction, isFalse);
    });

    test('undo after offsetArc deletes the new Arc and both its new start/end Points', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-99', 'origin-99');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 5.0, 'y': 0.0};
      freshBackend.points['point-c'] = {'id': 'point-c', 'x': 0.0, 'y': 5.0};
      freshBackend.arcs['arc-a'] = {
        'id': 'arc-a',
        'center_point_id': 'point-a',
        'start_point_id': 'point-b',
        'end_point_id': 'point-c',
        'radius': 5.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-99');
      await freshController.offsetArc('arc-a', 2.0);
      final offsetArc = freshController.arcs.values.firstWhere((a) => a.id != 'arc-a');
      final newArcId = offsetArc.id;
      final newStartId = offsetArc.startPointId;
      final newEndId = offsetArc.endPointId;

      await freshController.undo();

      expect(freshController.arcs.containsKey(newArcId), isFalse);
      expect(freshController.points.containsKey(newStartId), isFalse);
      expect(freshController.points.containsKey(newEndId), isFalse);
    });

    test('offsetLine is a no-op while busy or without an adopted Sketch', () async {
      final freshController = SketchController(api: SketchApiClient(httpClient: MockClient((_) async => http.Response('', 404))));

      await freshController.offsetLine('line-a', 2.0);

      expect(freshController.lines, isEmpty);
    });
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

  test(
      'feedback round: isCardinalAxisConstraint identifies a circle\'s cardinal-point '
      'axis constraint and excludes its own radius constraint', () async {
    final freshBackend = _FakeBackend();
    freshBackend.seedSketch('sketch-101', 'origin-101');
    freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
    freshBackend.points['point-b'] = {'id': 'point-b', 'x': 5.0, 'y': 0.0};
    freshBackend.points['point-north'] = {'id': 'point-north', 'x': 0.0, 'y': 5.0};
    freshBackend.circles['circle-a'] = {
      'id': 'circle-a',
      'center_point_id': 'point-a',
      'radius_point_id': 'point-b',
      'radius': 5.0,
      'construction': false,
      'cardinal_point_ids': ['point-north', 'point-east', 'point-south', 'point-west'],
    };
    freshBackend.constraints['radius-constraint'] = {
      'id': 'radius-constraint',
      'point_a_id': 'point-a',
      'point_b_id': 'point-b',
      'distance': 5.0,
    };
    freshBackend.constraints['cardinal-constraint'] = {
      'id': 'cardinal-constraint',
      'point_a_id': 'point-a',
      'point_b_id': 'point-north',
      'distance': 0.0,
    };
    final mockClient = MockClient((request) async => freshBackend.handle(request));
    final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));

    await freshController.adoptSketch('sketch-101');

    final radiusConstraint =
        freshController.constraints['radius-constraint']! as DistanceConstraintDto;
    final cardinalConstraint =
        freshController.constraints['cardinal-constraint']! as DistanceConstraintDto;
    expect(freshController.isCardinalAxisConstraint(radiusConstraint), isFalse);
    expect(freshController.isCardinalAxisConstraint(cardinalConstraint), isTrue);
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

  // --- Phase 6.1: auto-constrain on placement when snapped -------------------

  test('placing a near-horizontal line auto-adds a HorizontalConstraint on tap', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0.3); // within the snap threshold

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<HorizontalConstraintDto>(), isNotEmpty);
  });

  test('placing a near-vertical line auto-adds a VerticalConstraint on tap', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0.3, 10); // within the snap threshold

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<VerticalConstraintDto>(), isNotEmpty);
  });

  test('placing a line well off-axis does not auto-add a Horizontal/Vertical constraint', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(4, 5);

    expect(controller.errorMessage, isNull);
    expect(controller.constraints.values.whereType<HorizontalConstraintDto>(), isEmpty);
    expect(controller.constraints.values.whereType<VerticalConstraintDto>(), isEmpty);
  });

  test('closing a chain loop back onto its start never auto-snaps, even if the closing edge is '
      'exactly axis-aligned', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // chain start: the origin
    await controller.handleCanvasTap(5, 3); // edge1: ~31 degrees, no snap
    await controller.handleCanvasTap(8, 0); // edge2: 45 degrees, no snap
    // Close the loop: the closing edge runs from (8, 0) straight back to the
    // origin (0, 0) - exactly horizontal - but must never auto-snap, since
    // its geometry is dictated by the loop closure, not freely aimed.
    controller.cursorX = 0;
    controller.cursorY = 0;
    await controller.handleCanvasTap(0, 0);

    expect(controller.errorMessage, isNull);
    expect(controller.chainInProgress, isFalse);
    expect(controller.constraints.values.whereType<HorizontalConstraintDto>(), isEmpty);
    expect(controller.constraints.values.whereType<VerticalConstraintDto>(), isEmpty);
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
      'on-device feedback: adding a horizontal dimension between two points that already have a '
      'vertical one leaves the vertical one in place instead of deleting it - vertical and '
      'horizontal are complementary, not conflicting, unlike linear-vs-specific', () async {
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('v', 4.0);
    final verticalId = controller.constraints.values.whereType<DistanceConstraintDto>().single.id;

    // Re-pick the same two points and confirm the complementary orientation.
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(3, 4);
    await controller.confirmGhostValue('h', 3.0);

    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>();
    expect(distanceConstraints.length, 2); // both coexist - not over-writing each other
    final vertical = distanceConstraints.firstWhere((c) => c.id == verticalId);
    expect(vertical.orientation, 'vertical');
    expect(vertical.distance, 4.0);
    final horizontal = distanceConstraints.firstWhere((c) => c.id != verticalId);
    expect(horizontal.orientation, 'horizontal');
    expect(horizontal.distance, 3.0);
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

    // On the boundary but off every cardinal axis - every Circle gets all
    // four North/East/South/West Points (see Sketch._add_cardinal_points),
    // so a diagonal spot is the only genuinely empty-space point on it.
    await controller.handleCanvasTap(10 * math.cos(math.pi / 4), 10 * math.sin(math.pi / 4));

    expect(controller.ghosts.map((g) => g.key).toSet(), {'radius', 'diameter'});

    await controller.confirmGhostValue('diameter', 40.0);

    expect(controller.errorMessage, isNull);
    final distanceConstraints = controller.constraints.values.whereType<DistanceConstraintDto>();
    expect(distanceConstraints.single.distance, 20.0); // halved from the 40.0 diameter entered
  });

  test(
      'on-device feedback: confirming a diameter ghost marks the resulting dimension to display as '
      'a diameter; confirming a radius ghost marks it to display as a radius', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // center
    await controller.handleCanvasTap(10, 0); // radius point -> radius 10
    controller.enterDimensionMode();
    // Off every cardinal axis - see Sketch._add_cardinal_points.
    await controller.handleCanvasTap(10 * math.cos(math.pi / 4), 10 * math.sin(math.pi / 4));

    await controller.confirmGhostValue('diameter', 40.0);

    final constraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(controller.showsDiameterFor(constraint.id), isTrue);

    // Re-picking the same circle and confirming the radius ghost this time
    // must flip the same (now-existing) constraint's display mode back.
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10 * math.cos(math.pi / 4), 10 * math.sin(math.pi / 4));
    await controller.confirmGhostValue('radius', 20.0);

    expect(controller.showsDiameterFor(constraint.id), isFalse);
  });

  test(
      'on-device feedback: circleForDistanceConstraint identifies a circle radius/diameter dimension '
      'and returns null for an ordinary two-point dimension', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10, 0);
    await controller.confirmGhostValue('radius', 10.0);
    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;

    expect(controller.circleForDistanceConstraint(radiusConstraint), isNotNull);

    // A DistanceConstraintDto whose point pair doesn't match any Circle's
    // own (centerPointId, radiusPointId) order - even reusing the same two
    // point ids, just swapped - must not be treated as a radius/diameter
    // dimension.
    final notACircleConstraint = DistanceConstraintDto(
      id: 'fake-constraint',
      pointAId: radiusConstraint.pointBId,
      pointBId: radiusConstraint.pointAId,
      distance: 5.0,
    );
    expect(controller.circleForDistanceConstraint(notACircleConstraint), isNull);
  });

  test(
      'task #94 follow-up: polygonForDistanceConstraint identifies a confirmed Polygon circumradius '
      'as a radial dimension, not a generic two-point one (bug fix: it used to fall through to an '
      'internal center-to-vertex linear dimension, easy to miss as "the shape\'s size is now locked")',
      () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(6);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.exitToSelectMode();

    final radiusConstraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    // Still provisional - not yet a radial dimension either, same as an
    // unconfirmed Circle/Arc radius (isRadiusDistanceConstraint doesn't
    // itself gate on provisional, but nothing renders a provisional
    // DistanceConstraint at all - see _paintDimensionOverlays' own
    // `if (c.provisional) break;`).
    expect(controller.polygonForDistanceConstraint(radiusConstraint), isNotNull);
    expect(controller.isRadiusDistanceConstraint(radiusConstraint), isTrue);

    controller.selectConstraint(radiusConstraint.id);
    await controller.updateSelectedConstraintValue(10);
    final confirmed = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(controller.isRadiusDistanceConstraint(confirmed), isTrue);
  });

  test(
      'on-device feedback: a regular Polygon\'s own auto-created angle/equal-length ties between '
      'consecutive edges are implicit structure, hidden while the shape is whole - only a genuinely '
      'unrelated Angle/EqualLength constraint between two ordinary Lines counts as a real dimension',
      () async {
    controller.selectDrawTool(SketchTool.polygon);
    controller.setPolygonSides(5);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.exitToSelectMode();

    final polygonAngle = controller.constraints.values.whereType<AngleConstraintDto>().first;
    final polygonEqualLength = controller.constraints.values.whereType<EqualLengthConstraintDto>().first;
    expect(controller.isImplicitPolygonEdgeTie(polygonAngle.line1Id, polygonAngle.line2Id), isTrue);
    expect(
      controller.isImplicitPolygonEdgeTie(polygonEqualLength.line1Id, polygonEqualLength.line2Id),
      isTrue,
    );

    // Two ordinary Lines, nothing to do with the Polygon - an Angle/
    // EqualLength constraint between them is a real, user-facing dimension.
    final linesBefore = controller.lines.keys.toSet();
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(50, 50);
    await controller.handleCanvasTap(60, 55);
    controller.finishChain();
    await controller.handleCanvasTap(50, 60);
    await controller.handleCanvasTap(60, 65);
    controller.finishChain();
    final unrelatedLineIds =
        controller.lines.keys.where((id) => !linesBefore.contains(id)).toList();
    expect(unrelatedLineIds, hasLength(2));
    expect(
      controller.isImplicitPolygonEdgeTie(unrelatedLineIds[0], unrelatedLineIds[1]),
      isFalse,
    );
  });

  test(
      'on-device feedback ("the perpendicular constraint on the major and minor axes in an ellipse '
      'is implicit of the form of an ellipse so it shouldn\'t be visible"): an Ellipse\'s own '
      'auto-created PerpendicularConstraint between its major/minor axis Lines is hidden from '
      'constraintOverlayItems, but a genuinely unrelated Perpendicular constraint between two '
      'ordinary Lines still shows', () async {
    controller.selectDrawTool(SketchTool.ellipse);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    await controller.handleCanvasTap(5, 4);

    final ellipsePerp = controller.constraints.values.whereType<PerpendicularConstraintDto>().single;
    expect(controller.isImplicitEllipseAxisPerpendicular(ellipsePerp.line1Id, ellipsePerp.line2Id), isTrue);
    expect(
      controller.constraintOverlayItems().whereType<ConstraintLabelItem>().where((i) => i.text == '⟂'),
      isEmpty,
    );

    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(50, 50);
    await controller.handleCanvasTap(60, 50);
    controller.finishChain();
    await controller.handleCanvasTap(50, 60);
    await controller.handleCanvasTap(50, 70);
    controller.finishChain();
    controller.exitToSelectMode();
    await controller.handleCanvasTap(58, 50.1); // first unrelated Line, away from its own midpoint (55, 50)
    await controller.handleCanvasTap(50.1, 68); // second unrelated Line, away from its own midpoint (50, 65)
    await controller.addPerpendicularConstraint();
    final realPerp = controller.constraints.values.whereType<PerpendicularConstraintDto>().last;
    expect(controller.isImplicitEllipseAxisPerpendicular(realPerp.line1Id, realPerp.line2Id), isFalse);
    expect(
      controller.constraintOverlayItems().whereType<ConstraintLabelItem>().where((i) => i.text == '⟂'),
      isNotEmpty,
    );
  });

  test('on-device feedback: toggleRadiusDiameterDisplay flips the display mode and notifies listeners', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10, 0);
    await controller.confirmGhostValue('radius', 10.0);
    final constraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(controller.showsDiameterFor(constraint.id), isFalse);

    var notified = false;
    controller.addListener(() => notified = true);
    controller.toggleRadiusDiameterDisplay(constraint.id);

    expect(controller.showsDiameterFor(constraint.id), isTrue);
    expect(notified, isTrue);

    controller.toggleRadiusDiameterDisplay(constraint.id);
    expect(controller.showsDiameterFor(constraint.id), isFalse);
  });

  test(
      'dimensionLabelAt finds a radius dimension label at its radial base anchor - rim point plus '
      '24px along the centre-to-rim direction, not the generic two-point diagonal midpoint', () async {
    controller.selectDrawTool(SketchTool.circle);
    await controller.handleCanvasTap(0, 0); // centre
    // The second tap only ever measures a distance (radius 10) - the radius
    // point it creates is always the north cardinal point, i.e. rim
    // direction is always +Y, regardless of where this tap lands.
    await controller.handleCanvasTap(10, 0);
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10, 0); // on the boundary, not on a real Point
    await controller.confirmGhostValue('radius', 10.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is DistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // centre (0,0) -> screen (400,300); rim (0,10) -> screen (400,100);
    // direction = -Y on screen (+Y in sketch space), so the base anchor is
    // 24px further along it: (400, 300 - (200 + 24)) = (400, 76).
    const radialAnchor = Offset(400, 76);

    expect(dimensionLabelAt(controller, transform, radialAnchor, 5), constraintId);
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
    // Phase 6.1: off-axis (not (10, 0)) so placement doesn't auto-add a
    // HorizontalConstraint, which would make `constraints.keys.single`
    // below see two Constraints instead of just the confirmed length one.
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 2.4); // on the line, away from its midpoint
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

  test(
      'bug fix (on-device feedback: "before this work any dimension could be edited... this has '
      'been lost on certain dimension types"): selectedConstraintValue exposes an Angle '
      'constraint\'s value, and updateSelectedConstraintValue PATCHes it', () async {
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
    controller.exitToSelectMode();
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is AngleConstraintDto).key;
    controller.selectConstraint(constraintId);

    expect(controller.selectedConstraintValue, 90.0);
    expect(controller.selectedConstraintHasValue, isTrue);
    expect(controller.selectedConstraintIsAngle, isTrue);

    await controller.updateSelectedConstraintValue(60.0);

    expect(controller.errorMessage, isNull);
    expect((controller.constraints[constraintId] as AngleConstraintDto).angleDegrees, 60.0);
    expect(controller.selectionSet, isEmpty);
  });

  test(
      'bug fix (on-device feedback: "this has been lost on certain dimension types"): '
      'selectedConstraintValue exposes a LineDistance constraint\'s value (this getter never '
      'covered it, a pre-existing gap now closed)', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 0, y: 3);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 5, y: 3);
    controller.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'p2', endPointId: 'p3');
    controller.constraints['c0'] =
        const LineDistanceConstraintDto(id: 'c0', line1Id: 'l0', line2Id: 'l1', distance: 3.0);
    controller.selectConstraint('c0');

    expect(controller.selectedConstraintValue, 3.0);
    expect(controller.selectedConstraintHasValue, isTrue);
    expect(controller.selectedConstraintIsAngle, isFalse);
  });

  test(
      'bug fix (on-device feedback: "this has been lost on certain dimension types"): '
      'selectedConstraintValue exposes a PointLineDistance constraint\'s value (this getter never '
      'covered it, and the backend 422d any attempt to PATCH it - both gaps now closed)', () {
    controller.points['pt'] = const SketchPointView(id: 'pt', x: 2, y: 3);
    controller.constraints['c0'] =
        const PointLineDistanceConstraintDto(id: 'c0', pointId: 'pt', lineId: 'l0', distance: 3.0);
    controller.selectConstraint('c0');

    expect(controller.selectedConstraintValue, 3.0);
    expect(controller.selectedConstraintHasValue, isTrue);
    expect(controller.selectedConstraintIsAngle, isFalse);
  });

  test(
      'updateSelectedConstraintValue re-solves and refreshes isUnderConstrained (bug fix: this '
      'used to leave dof stale until some later, unrelated mutation forced a fresh solve)',
      () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 2.4);
    await controller.confirmGhostValue('length', 25.0);
    controller.exitToSelectMode();
    final constraintId = controller.constraints.keys.single;
    controller.selectConstraint(constraintId);

    backend.dof = 3; // would surface in isUnderConstrained only if a fresh solve ran
    await controller.updateSelectedConstraintValue(50.0);

    expect(controller.errorMessage, isNull);
    expect(controller.isUnderConstrained, isTrue);
  });

  test(
      'setLineLength re-solves when patching an already-confirmed length, not just on first '
      'confirm (bug fix: the existing-constraint branch used to skip the solve entirely)',
      () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    controller.exitToSelectMode();
    final line = controller.lines.values.single;

    await controller.setLineLength(line.id, 25.0); // first confirm - creates the constraint
    expect(controller.errorMessage, isNull);

    backend.dof = 4; // would surface in isUnderConstrained only if a fresh solve ran
    await controller.setLineLength(line.id, 30.0); // second confirm - existing-constraint branch

    expect(controller.errorMessage, isNull);
    expect(controller.isUnderConstrained, isTrue);
  });

  test(
      'confirmGhostValue re-solves when re-confirming an existing point-based dimension, not '
      'just on first confirm (bug fix: the existing-constraint branch used to skip the solve, '
      'unlike the angle/lineDistance branches which already solved unconditionally)', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(8, 2.4);
    await controller.confirmGhostValue('length', 25.0); // first confirm - creates it

    await controller.handleCanvasTap(8, 2.4); // re-pick the same Line
    backend.dof = 5; // would surface in isUnderConstrained only if a fresh solve ran
    await controller.confirmGhostValue('length', 30.0); // re-confirm - existing-constraint branch

    expect(controller.errorMessage, isNull);
    expect(controller.isUnderConstrained, isTrue);
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
      'dimensioning a Slot\'s two parallel straight sides shows a lineDistance ghost, not a '
      'mismatched point-to-point one (on-device feedback: "I experienced an issue adding a '
      'dimension between the two parallel lines in a slot. it offered dimensions between the '
      'midpoint of one line and the end point of another" - _resolveSelectableAt resolves each '
      'tap independently: a tap near a Line\'s middle materializes its midpoint into a real '
      'Point, a tap nearer a Line\'s own end (here, shared with the adjacent Arc) resolves to '
      'that endpoint Point directly - both come back as SelectionKind.point, so the dispatch '
      'used to fall through to an ordinary point distance instead of the correct parallel-Line '
      'one)', () async {
    controller.selectDrawTool(SketchTool.slot);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(20, 0);
    await controller.handleCanvasTap(10, 5); // radius 5
    controller.exitToSelectMode();
    // line1 runs b=(0,-5) -> c=(20,-5); line2 runs d=(20,5) -> a=(0,5) - see
    // _slotCorners' own doc comment for this exact pairing.
    final line1 = controller.lines.values.firstWhere(
      (line) => !line.construction && controller.points[line.startPointId]!.y < 0,
    );
    final line2 = controller.lines.values.firstWhere(
      (line) => !line.construction && controller.points[line.startPointId]!.y > 0,
    );
    controller.enterDimensionMode();

    await controller.handleCanvasTap(10, -5); // line1's exact midpoint - materializes a Point
    // line2's own start Point (shared with an Arc) - a real endpoint, not a midpoint.
    final line2Start = controller.points[line2.startPointId]!;
    await controller.handleCanvasTap(line2Start.x, line2Start.y);

    expect(controller.ghosts.map((g) => g.key).toSet(), {'lineDistance'});
    final ghost = controller.ghosts.single;
    expect(ghost.kind, GhostKind.lineDistance);
    expect({ghost.lineAId, ghost.lineBId}, {line1.id, line2.id});
    expect(controller.currentGhostValue(ghost), closeTo(10.0, 1e-9));
  });

  group('Slot construction points (arc apex + centreline midpoint), hover/select-only visible '
      '(on-device feedback: "some points need to be available and visible for the user to use to '
      'constrain: mid point of slot, midpoints of slot radii... These should respect hover '
      'highlight and be visible when selected but should remain unseen otherwise")', () {
    test('hoveredLineMidpoint reveals an intact Slot\'s Arc apex when the cursor is near it, and '
        'stays null when it is not', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();

      // arc1's apex is directly opposite the two straight sides, on the
      // extended centreline: centre1 - radius along the c1->c2 direction.
      controller.cursorX = -5;
      controller.cursorY = 0;
      expect(controller.hoveredLineMidpoint, isNotNull);
      expect(controller.hoveredLineMidpoint!.$1, closeTo(-5, 1e-9));
      expect(controller.hoveredLineMidpoint!.$2, closeTo(0, 1e-9));

      controller.cursorX = 100;
      controller.cursorY = 100;
      expect(controller.hoveredLineMidpoint, isNull);
    });

    test('tapping near an intact Slot\'s Arc apex in dimension mode materializes a real Point '
        'there, usable like any other dimension pick', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();
      final pointCountBefore = controller.points.length;
      controller.enterDimensionMode();

      await controller.handleCanvasTap(-5, 0); // arc1's apex
      await controller.handleCanvasTap(25, 0); // arc2's apex

      expect(controller.points.length, pointCountBefore + 2);
      expect(controller.ghosts.map((g) => g.key).toSet(), {'v', 'h', 'linear'});
      final linearGhost = controller.ghosts.firstWhere((g) => g.key == 'linear');
      expect(controller.currentGhostValue(linearGhost), closeTo(30.0, 1e-6));
    });

    test('deleting one of a Slot\'s own straight Lines collapses just the Slot bookkeeping record '
        '(see computeDeleteCascade\'s own Slot block) - it no longer cascades the rest of the Slot\'s '
        'own geometry away with it, only leaving no Arc-apex snap target behind since the Slot is no '
        'longer intact', () async {
      controller.selectDrawTool(SketchTool.slot);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(20, 0);
      await controller.handleCanvasTap(10, 5); // radius 5
      controller.exitToSelectMode();
      final slot = controller.slots.values.single;
      final arc1 = controller.arcs.values.first;
      final line1 = controller.lines.values.firstWhere(
        (line) => !line.construction && (line.startPointId == arc1.endPointId || line.endPointId == arc1.endPointId),
      );
      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: line1.id));
      await controller.deleteSelected();

      expect(controller.slots, isEmpty);
      expect(controller.errorMessage, isNull);
      expect(controller.lines.containsKey(line1.id), isFalse);
      // The rest of the Slot's own geometry survives - only the wrapper
      // record and the one directly-deleted Line are gone.
      expect(controller.arcs.containsKey(slot.arc1Id), isTrue);
      expect(controller.arcs.containsKey(slot.arc2Id), isTrue);
      expect(controller.lines.containsKey(slot.centerlineId), isTrue);
      final survivingSideId = slot.line1Id == line1.id ? slot.line2Id : slot.line1Id;
      expect(controller.lines.containsKey(survivingSideId), isTrue);
      controller.cursorX = -5;
      controller.cursorY = 0;
      expect(controller.hoveredLineMidpoint, isNull);
    });
  });

  group('Circle/Polygon centre hover-reveal with a 3-second delayed hide (on-device feedback: '
      '"when I hover over any part of a polygon or circle the midpoint should show as a centre '
      'mark and it should hide 3 seconds after the cursor is no longer hovering over part of that '
      'shape. This allows the user to see it, select it without it being otherwise distracting")', () {
    test('hovering a Circle\'s curve reveals its centre Point', () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(5, 0);
      controller.exitToSelectMode();
      final circle = controller.circles.values.single;
      expect(controller.revealedShapeCenterPointId, isNull);

      // On the circle's own curve, off every cardinal axis (see
      // Sketch._add_cardinal_points) - a cardinal Point itself would hover
      // as a Point, not the circle's edge.
      controller.moveCursorToSketchPoint(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4));

      expect(controller.revealedShapeCenterPointId, circle.centerPointId);
    });

    test('hovering a Polygon\'s own edge reveals its centre Point', () async {
      controller.selectDrawTool(SketchTool.polygon);
      controller.setPolygonSides(6);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.exitToSelectMode();
      final polygon = controller.polygons.values.single;
      final line = controller.lines[polygon.lineIds.first]!;
      final start = controller.points[line.startPointId]!;
      final end = controller.points[line.endPointId]!;

      controller.moveCursorToSketchPoint((start.x + end.x) / 2, (start.y + end.y) / 2);

      expect(controller.revealedShapeCenterPointId, polygon.centerPointId);
    });

    test('hovering something unrelated never reveals a centre', () async {
      controller.selectDrawTool(SketchTool.circle);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(5, 0);
      controller.exitToSelectMode();

      controller.moveCursorToSketchPoint(100, 100);

      expect(controller.revealedShapeCenterPointId, isNull);
    });

    test('moving off the shape does not hide the centre immediately, hides it only after 3 '
        'seconds, and a re-hover before then cancels the pending hide', () {
      fakeAsync((async) {
        controller
          ..selectDrawTool(SketchTool.circle)
          ..handleCanvasTap(0, 0);
        async.flushMicrotasks();
        controller.handleCanvasTap(5, 0);
        async.flushMicrotasks();
        controller.exitToSelectMode();
        final circle = controller.circles.values.single;

        // Off every cardinal axis (see Sketch._add_cardinal_points) - a
        // cardinal Point itself would hover as a Point, not the curve.
        controller.moveCursorToSketchPoint(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4));
        expect(controller.revealedShapeCenterPointId, circle.centerPointId);

        controller.moveCursorToSketchPoint(100, 100); // off the shape
        expect(controller.revealedShapeCenterPointId, circle.centerPointId,
            reason: 'must not hide the instant the cursor leaves');

        async.elapse(const Duration(seconds: 2));
        expect(controller.revealedShapeCenterPointId, circle.centerPointId, reason: 'not 3 seconds yet');

        controller.moveCursorToSketchPoint(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4)); // back on the circle before the hide fires
        async.elapse(const Duration(seconds: 2)); // 4s total since first leaving, but re-hovered at 2s
        expect(controller.revealedShapeCenterPointId, circle.centerPointId,
            reason: 'a re-hover before the hide fires must cancel it, not just delay it');

        controller.moveCursorToSketchPoint(100, 100);
        async.elapse(const Duration(seconds: 3, milliseconds: 1));
        expect(controller.revealedShapeCenterPointId, isNull);
      });
    });
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

  test(
      'Bug fix: a LineDistanceConstraint between mismatched-length parallel Lines anchors '
      "perpendicular to Line 1, not at Line 2's own (differently-positioned) midpoint - the old "
      'midpoint-to-midpoint layout drew a visibly diagonal dimension whenever the two Lines\' '
      'lengths differed, even though the labeled value was always the correct perpendicular '
      'distance', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(0, 10);
    controller.finishChain();
    await controller.handleCanvasTap(5, 0);
    await controller.handleCanvasTap(5, 4);
    controller.finishChain();
    controller.enterDimensionMode();
    await controller.handleCanvasTap(0.1, 8); // Line 1, away from its own midpoint (0, 5)
    await controller.handleCanvasTap(5.1, 2.7); // Line 2, away from its own midpoint (5, 2)
    await controller.confirmGhostValue('lineDistance', 5.0);
    final constraintId =
        controller.constraints.entries.firstWhere((e) => e.value is LineDistanceConstraintDto).key;

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // The perpendicular foot from Line 1's own midpoint (0, 5) onto Line
    // 2's infinite line (x = 5) lands at world (5, 5) - not Line 2's own
    // midpoint (5, 2), which the pre-fix code anchored on instead (that
    // would have produced a diagonal dimension segment, not a horizontal
    // one perpendicular to both vertical Lines). The label offset (18px,
    // parallel to both Lines - i.e. vertically, screen -y) then centers on
    // (450, 182): x is the mean of midA.dx=400 and midB.dx=500; y is
    // (200 - 18) for both, since the offset is purely vertical here.
    const expectedAnchor = Offset(450, 182);

    expect(dimensionLabelAt(controller, transform, expectedAnchor, 5), constraintId);
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
    await controller.handleCanvasTap(0, 0); // chain start, snaps to the origin
    await controller.handleCanvasTap(10, 0); // backend.dof defaults to 0
    controller.finishChain();
    controller.exitToSelectMode();
    // Phase 3 bug-fix round: backend.dof == 0 alone isn't "fully
    // constrained" any more - a bare Line with no Constraint tying its far
    // endpoint back to the origin can still be dragged freely, so it must
    // not read as fully constrained even though the fake backend already
    // reports dof == 0 by default. Ground it with a Vertical Constraint
    // (unions the Line's two endpoints - one of which is the origin
    // itself - into one cluster) so this test's premise actually holds.
    await controller.handleCanvasTap(8, 0.1); // the line, away from its midpoint (5, 0)
    await controller.addVerticalConstraint();

    expect(controller.isUnderConstrained, isFalse);
    expect(controller.dragTargetPointIdAt(0, 0, 1), isNull);
  });

  test('dragTargetPointIdAt returns a directly-hit Point once the sketch is under-constrained',
      () async {
    controller.selectDrawTool(SketchTool.line);
    // Away from the origin (0, 0) - that's covered by its own dedicated
    // "never offers the origin" test below, since the origin is never a
    // valid drag target regardless of how directly it's hit.
    await controller.handleCanvasTap(20, 20);
    backend.dof = 1;
    await controller.handleCanvasTap(30, 20);
    controller.finishChain();
    controller.exitToSelectMode();
    final line = controller.lines.values.last;

    expect(controller.isUnderConstrained, isTrue);
    expect(controller.dragTargetPointIdAt(20, 20, 1), line.startPointId);
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
    // Away from the origin (0, 0) - see the identical reasoning in the test
    // above.
    await controller.handleCanvasTap(20, 20);
    backend.dof = 1;
    await controller.handleCanvasTap(30, 20);
    controller.finishChain();
    controller.exitToSelectMode();
    final line = controller.lines.values.last;

    expect(controller.dragTargetPointIdAt(28, 20, 1), line.endPointId);
    expect(controller.dragTargetPointIdAt(22, 20, 1), line.startPointId);
  });

  test('beginPointDrag sets draggingPointId for a known Point and rejects an unknown id', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    // The line's start Point snapped onto the origin ((0, 0) is always
    // within snap radius of it) - use the *end* Point instead, since the
    // origin itself can never be dragged (see beginPointDrag's own origin
    // guard, added on-device feedback: "cannot move the sketch origin
    // point" appearing after dragging something that was never the
    // origin - the backend's own update_point 400s on it unconditionally).
    final pointId = controller.lines.values.last.endPointId;

    expect(controller.beginPointDrag('does-not-exist'), isFalse);
    expect(controller.draggingPointId, isNull);

    expect(controller.beginPointDrag(pointId), isTrue);
    expect(controller.draggingPointId, pointId);
  });

  test('beginPointDrag refuses to grab the sketch origin Point directly - the backend\'s own '
      'update_point 400s on it unconditionally', () async {
    expect(controller.beginPointDrag(controller.originPointId!), isFalse);
    expect(controller.draggingPointId, isNull);
  });

  test('beginPointDrag only records local drag state - no HTTP call, no Point movement', () async {
    // Stage 16 item 5 regression test: a double-tap's second pointer-down
    // typically lands within the hit-radius of the Point rather than
    // pixel-exact on it, so beginPointDrag must record that offset (via
    // _dragOriginCursorX/Y vs _dragOriginPointX/Y) rather than ever PATCHing
    // the touch-down position - otherwise the Point visibly jumps to the
    // touch position before any drag motion happens.
    // Away from (0, 0) on purpose - a tap there snaps onto the Sketch's own
    // origin Point, which can never be dragged (see beginPointDrag's own
    // origin guard).
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(5, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(15, 0);
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
    // Away from (0, 0) on purpose - see the test above's own doc comment.
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(5, 0);
    backend.dof = 1;
    await controller.handleCanvasTap(15, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    final pointId = controller.lines.values.last.startPointId;
    // The chain's last tap left the controller's persistent cursor at
    // (15, 0); this Point (the line's start) sits at (5, 0). beginPointDrag
    // records that 10-unit offset, so updatePointDrag must apply moves
    // relative to it rather than snapping the Point to the raw touch
    // position - see beginPointDrag's doc comment.
    controller.beginPointDrag(pointId);

    backend.dof = 7; // would surface in isUnderConstrained if a solve ran
    await controller.updatePointDrag(17, 34);

    expect(controller.points[pointId]!.x, 7); // 5 + (17 - 15)
    expect(controller.points[pointId]!.y, 34); // 0 + (34 - 0)
    expect(controller.isUnderConstrained, isTrue); // unchanged: still the dof=1 from the line's solve
    expect(controller.errorMessage, isNull);
  });

  test(
      'updatePointDrag solves locally (no /solve round trip) when a native library is injected, '
      'reflowing the other Point to satisfy a live DistanceConstraint', () async {
    final libraryPath = _findHostSlvsLibrary();
    if (libraryPath == null) {
      markTestSkipped('host didsa_slvs_ffi library not built - see client/native/slvs/CMakeLists.txt');
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));
    final localBackend = _FakeBackend();
    final localClient = MockClient((request) async => localBackend.handle(request));
    final localController =
        SketchController(api: SketchApiClient(httpClient: localClient), localSolverBindings: bindings);
    await localController.ensureSketch();

    localController.selectDrawTool(SketchTool.line);
    // Away from (0, 0) on purpose - a tap there snaps onto the Sketch's
    // own origin Point (_pointIdAtCursor's documented behaviour), which
    // would make this test drag the origin instead of a free Point.
    await localController.handleCanvasTap(5, 5);
    // Nonzero dof - same reason as the "PATCHes the dragged Point" test
    // above: beginPointDrag refuses to grab a Point isFullyConstrained
    // already thinks is fully pinned, and the fake backend's dof defaults
    // to 0 (would otherwise look fully constrained the instant the line
    // finishes below).
    localBackend.dof = 1;
    await localController.handleCanvasTap(15, 5);
    localController.finishChain();
    localController.exitToSelectMode();
    final line = localController.lines.values.last;
    final draggedId = line.startPointId;
    final otherId = line.endPointId;
    // Injected directly into the controller's live state, not via the fake
    // backend - the in-process solver reads Points/Constraints/lines from
    // the controller itself, so this is enough to exercise it without
    // teaching the fake backend to model constraint solving too.
    localController.constraints['dc1'] =
        DistanceConstraintDto(id: 'dc1', pointAId: draggedId, pointBId: otherId, distance: 50.0);

    final grabbed = localController.beginPointDrag(draggedId);
    expect(grabbed, isTrue);
    localBackend.requestLog.clear();
    // The exact destination doesn't matter - only that dragging moves
    // draggedId somewhere new and the *other* Point reflows to keep the
    // 50.0 DistanceConstraint satisfied, without any server round trip.
    await localController.updatePointDrag(30, 40);

    // The dragged Point's own PATCH still happens (that part is unchanged -
    // only the *other* Points' reflow is local now), but no /solve or
    // /solve-and-refresh round trip should have fired.
    expect(localBackend.requestLog.any((r) => r.contains('/solve')), isFalse);

    final draggedPoint = localController.points[draggedId]!;
    final otherPoint = localController.points[otherId]!;
    final distance = math.sqrt(
      math.pow(otherPoint.x - draggedPoint.x, 2) + math.pow(otherPoint.y - draggedPoint.y, 2),
    );
    expect(distance, closeTo(50.0, 1e-6));
  });

  test(
      'updateLineDrag also solves locally (no /solve round trip) when a native library is injected, '
      'reflowing a third Point to satisfy a live DistanceConstraint on the dragged Line\'s own endpoint '
      '(on-device feedback: line drag never got the same in-process-solver treatment point drag did)',
      () async {
    final libraryPath = _findHostSlvsLibrary();
    if (libraryPath == null) {
      markTestSkipped('host didsa_slvs_ffi library not built - see client/native/slvs/CMakeLists.txt');
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));
    final localBackend = _FakeBackend();
    final localClient = MockClient((request) async => localBackend.handle(request));
    final localController =
        SketchController(api: SketchApiClient(httpClient: localClient), localSolverBindings: bindings);
    await localController.ensureSketch();

    // Third Point created *before* the Line, not after - beginLineDrag
    // records its drag-start offset from the controller's own persistent
    // cursor position (see beginLineDrag's doc comment), so an unrelated
    // tap between finishing the Line and starting the drag would corrupt
    // that baseline. Placing this first keeps the Line's own last tap as
    // the drag's actual starting cursor position, same as every other
    // drag test in this file.
    localController.selectDrawTool(SketchTool.point);
    await localController.handleCanvasTap(100, 100);
    localController.exitToSelectMode();
    final thirdPointId = localController.points.keys.firstWhere(
      (id) => id != localController.originPointId,
    );

    localController.selectDrawTool(SketchTool.line);
    // Away from (0, 0) on purpose - same origin-snap reasoning as the
    // point-drag test above. Deliberately off-axis (not near-horizontal/
    // vertical), unlike the regression test below - see that test's own
    // doc comment for why an axis-aligned Line is a separate case.
    await localController.handleCanvasTap(5, 5);
    localBackend.dof = 1;
    await localController.handleCanvasTap(19, 12);
    localController.finishChain();
    localController.exitToSelectMode();
    final line = localController.lines.values.last;
    final lineStartId = line.startPointId;
    // Injected directly, same reasoning as the point-drag test above - the
    // in-process solver reads live controller state, not the fake backend.
    localController.constraints['dc1'] =
        DistanceConstraintDto(id: 'dc1', pointAId: lineStartId, pointBId: thirdPointId, distance: 25.0);

    final grabbed = localController.beginLineDrag(line.id);
    expect(grabbed, isTrue);
    localBackend.requestLog.clear();
    await localController.updateLineDrag(20, 20);

    expect(localBackend.requestLog.any((r) => r.contains('/solve')), isFalse);

    final draggedStart = localController.points[lineStartId]!;
    final third = localController.points[thirdPointId]!;
    final distance = math.sqrt(
      math.pow(third.x - draggedStart.x, 2) + math.pow(third.y - draggedStart.y, 2),
    );
    expect(distance, closeTo(25.0, 1e-6));
  });

  test(
      'updateLineDrag falls back to the server round trip (never applies a partial/inconsistent '
      'local result) when dragging an axis-aligned Line whose own Horizontal Constraint, combined '
      'with a separate Constraint reaching out to a third free Point, confuses the native solver\'s '
      'anchor pinning - on-device-investigation bug fix: found via the test above, generalized - a '
      'Horizontal/Vertical Constraint between two simultaneously-anchored Points is fine on its own, '
      'but combined with any other Constraint reaching from one of them to a free Point, the native '
      'solver was found to sometimes move an "anchored" Point anyway, which would otherwise silently '
      'teleport the dragged Line somewhere else - not yet root-caused at the FFI/SLVS level, so this '
      'checks anchor points landed where they were pinned before trusting the rest of a local solve\'s '
      'result at all, falling back to the safe network path if not',
      () async {
    final libraryPath = _findHostSlvsLibrary();
    if (libraryPath == null) {
      markTestSkipped('host didsa_slvs_ffi library not built - see client/native/slvs/CMakeLists.txt');
      return;
    }
    final bindings = SlvsNativeBindings(ffi.DynamicLibrary.open(libraryPath));
    final localBackend = _FakeBackend();
    final localClient = MockClient((request) async => localBackend.handle(request));
    final localController =
        SketchController(api: SketchApiClient(httpClient: localClient), localSolverBindings: bindings);
    await localController.ensureSketch();

    // Third Point first, same drag-start-cursor reasoning as the passing
    // test above.
    localController.selectDrawTool(SketchTool.point);
    await localController.handleCanvasTap(100, 100);
    localController.exitToSelectMode();
    final thirdPointId = localController.points.keys.firstWhere(
      (id) => id != localController.originPointId,
    );

    localController.selectDrawTool(SketchTool.line);
    // Away from (0, 0) on purpose, same reasoning as every other test in
    // this group - and exactly horizontal, so placing it auto-adds a
    // HorizontalConstraint between the Line's own two Points (see
    // "placing a near-horizontal line auto-adds a HorizontalConstraint on
    // tap" elsewhere in this file) - both of which this drag anchors
    // simultaneously.
    await localController.handleCanvasTap(5, 5);
    localBackend.dof = 1;
    await localController.handleCanvasTap(15, 5);
    localController.finishChain();
    localController.exitToSelectMode();
    final line = localController.lines.values.last;
    expect(
      localController.constraints.values.whereType<HorizontalConstraintDto>(),
      isNotEmpty,
      reason: 'sanity check: this scenario only reproduces the bug if the auto-Horizontal-Constraint '
          'actually landed',
    );
    localController.constraints['dc1'] = DistanceConstraintDto(
      id: 'dc1',
      pointAId: line.startPointId,
      pointBId: thirdPointId,
      distance: 25.0,
    );

    final grabbed = localController.beginLineDrag(line.id);
    expect(grabbed, isTrue);
    localBackend.requestLog.clear();
    await localController.updateLineDrag(20, 20);
    // The network fallback's own solve fires via `unawaited(...)` (see
    // _maybeSolveDuringDrag) - a real pointer-move handler can't block on
    // it either, so updateLineDrag itself doesn't await it - one microtask
    // turn lets it actually reach the (fake) backend before asserting on
    // requestLog below.
    await Future<void>.delayed(Duration.zero);

    // The local solve's anchor-drift safety check must have rejected its
    // own result (see _trySolveDuringDragLocally's own doc comment),
    // falling back to the throttled server round trip instead - not left
    // silently un-reflowed, and *definitely* not left with the dragged
    // Line's endpoints moved somewhere other than where the drag put them.
    expect(localBackend.requestLog.any((r) => r.contains('/solve')), isTrue);
    expect(localController.points[line.startPointId]!.x, 10); // 5 + (20 - 15)
    expect(localController.points[line.startPointId]!.y, 20); // 5 + (20 - 5)
    expect(localController.points[line.endPointId]!.x, 20); // 15 + (20 - 15)
    expect(localController.points[line.endPointId]!.y, 20); // 5 + (20 - 5)
  });

  test('endPointDrag clears draggingPointId and re-solves from the dropped position', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // snaps onto the origin
    backend.dof = 1;
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    controller.exitToSelectMode();
    // Dragging the *end* Point, not the start - the start snapped onto the
    // origin, which can never be dragged (see beginPointDrag's own origin
    // guard), and the grounding check below needs the origin to stay part
    // of this Line.
    final pointId = controller.lines.values.last.endPointId;
    controller.beginPointDrag(pointId);
    await controller.updatePointDrag(12, 34); // lands at (12, 34): 10 + (12 - 10), 0 + (34 - 0)

    backend.dof = 0; // simulates the drop settling the sketch fully
    await controller.endPointDrag();

    expect(controller.draggingPointId, isNull);
    expect(controller.points[pointId]!.x, 12);
    expect(controller.points[pointId]!.y, 34);
    expect(controller.errorMessage, isNull);

    // Phase 3 bug-fix round: backend.dof == 0 alone isn't "fully
    // constrained" any more - ground the Line (a Vertical Constraint
    // unions its two endpoints, one of which is the origin, into one
    // cluster) to actually exercise the "fully constrained" case, rather
    // than asserting it against a still-ungrounded Line. Computed (not
    // hand-picked) tap point, since the drag above moved the Line's start.
    final line = controller.lines.values.last;
    final start = controller.points[line.startPointId]!;
    final end = controller.points[line.endPointId]!;
    await controller.handleCanvasTap(
      start.x + (end.x - start.x) * 0.25,
      start.y + (end.y - start.y) * 0.25,
    );
    await controller.addVerticalConstraint();
    expect(controller.isUnderConstrained, isFalse);
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

    // Off every cardinal axis of each circle - every Circle gets all four
    // North/East/South/West Points (see Sketch._add_cardinal_points), so a
    // diagonal spot is the only genuinely empty-space point on the edge.
    await controller.handleCanvasTap(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4)); // first circle's edge
    await controller.handleCanvasTap(20 + 3 * math.cos(math.pi / 4), 3 * math.sin(math.pi / 4)); // second circle's edge

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

    // Off every cardinal axis - every Circle gets all four North/East/
    // South/West Points (see Sketch._add_cardinal_points).
    await controller.handleCanvasTap(5 * math.cos(math.pi / 4), 5 * math.sin(math.pi / 4)); // the circle's edge
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

  test(
      'bug fix (on-device feedback: "when I drop a point on the origin/another point a coincident '
      'constraint is created... the problem is I can\'t see the constraint label - as it\'s a '
      'grounding constraint the user may want to delete it, so it should be visible"): '
      'dimensionLabelAt finds a CoincidentConstraint\'s own label nudged away from the shared '
      'Point, not sitting exactly on top of it', () {
    controller.points['p2'] = const SketchPointView(id: 'p2', x: 3, y: 4);
    controller.points['p3'] = const SketchPointView(id: 'p3', x: 3, y: 4); // exactly coincident with p2
    controller.constraints['c0'] = const CoincidentConstraintDto(id: 'c0', pointAId: 'p2', pointBId: 'p3');

    const transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(400, 300));
    // p2/p3 both project to screen (460, 220) - the fixed (14, -14) nudge
    // moves the badge to (474, 206), off the Point marker itself.
    expect(dimensionLabelAt(controller, transform, const Offset(460, 220), 5), isNull);
    expect(dimensionLabelAt(controller, transform, const Offset(474, 206), 5), 'c0');
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
    // Second line, away from both its midpoint (0, 6.5) and its own
    // endpoints (0, 5)/(0, 8) - (0.1, 7.5) used to land within
    // pointHitRadiusMultiplier's widened radius of the (0, 8) endpoint,
    // selecting that Point instead of the Line.
    await controller.handleCanvasTap(0.15, 7.1);

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
    // Second line, away from its midpoint (5, 3) - (5, 3.1) used to land
    // within snapRadius of that midpoint, materializing a new Point there
    // (see _resolveSelectableAt/_nearestLineMidpointId) instead of
    // selecting the Line itself.
    await controller.handleCanvasTap(6.5, 3.1);

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
    // Away from the second line's midpoint (5, 3) - see the identical fix
    // in addCollinearConstraint's own test above.
    await controller.handleCanvasTap(6.5, 3.1);

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

  test('degenerateConstraintPointIds flags a Line carrying both a Vertical and a Horizontal '
      'Constraint', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 5);
    controller.finishChain();
    final line = controller.lines.values.single;
    controller.exitToSelectMode();

    await controller.handleCanvasTap(2, 1); // the line, away from its midpoint (5, 2.5)
    await controller.addVerticalConstraint();
    await controller.handleCanvasTap(2, 1);
    await controller.addHorizontalConstraint();

    expect(controller.degenerateConstraintPointIds, {line.startPointId, line.endPointId});
    expect(controller.isPointForcedOverConstrained(line.startPointId), isTrue);
    expect(controller.isPointForcedOverConstrained(line.endPointId), isTrue);
    expect(controller.beginPointDrag(line.startPointId), isFalse);
  });

  test('degenerateConstraintPointIds flags a Line pair carrying both a Parallel and a '
      'Perpendicular Constraint between them', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 0);
    controller.finishChain();
    await controller.handleCanvasTap(0, 5);
    await controller.handleCanvasTap(10, 6);
    controller.finishChain();
    final lines = controller.lines.values.toList();
    final expectedIds = {
      for (final line in lines) ...[line.startPointId, line.endPointId],
    };
    controller.exitToSelectMode();

    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(8, 5.8);
    await controller.addParallelConstraint();
    await controller.handleCanvasTap(8, 0.1);
    await controller.handleCanvasTap(8, 5.8);
    await controller.addPerpendicularConstraint();

    expect(controller.degenerateConstraintPointIds, expectedIds);
  });

  test('degenerateConstraintPointIds is empty for a Line with only a Vertical Constraint',
      () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    await controller.handleCanvasTap(10, 5);
    controller.finishChain();
    controller.exitToSelectMode();

    await controller.handleCanvasTap(2, 1);
    await controller.addVerticalConstraint();

    expect(controller.degenerateConstraintPointIds, isEmpty);
  });

  test('backendFlaggedOverConstrainedPointIds reflects py-slvs\'s own failed-constraint report '
      'when the last solve did not converge', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0);
    // Phase 6.1: off-axis (not (10, 0)) so placement doesn't auto-add a
    // HorizontalConstraint ahead of the explicit VerticalConstraint below,
    // which would leave this Line with two (conflicting) Constraints
    // instead of just the one this test means to add.
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    final line = controller.lines.values.single;
    controller.exitToSelectMode();

    // A single Vertical Constraint only removes 1 of the far endpoint's 2
    // degrees of freedom - dof = 1, not the fake backend's default 0, so
    // isFullyConstrained correctly stays false and the drag below (needed
    // to trigger a fresh solve) isn't refused by the newer "a fully
    // constrained and grounded Point can't be dragged" check.
    backend.dof = 1;
    await controller.handleCanvasTap(8, 2.4); // the line, away from its midpoint
    await controller.addVerticalConstraint();
    final constraintId = controller.constraints.values.whereType<VerticalConstraintDto>().single.id;

    backend.converged = false;
    backend.solverReportedFailedConstraintIds = [constraintId];
    // Any further mutation re-solves and refreshes the tracked result - a
    // no-op drag of the line's end Point (itself unrelated to the fake
    // failure - and not the start, which snapped onto the origin and can
    // never be dragged, see beginPointDrag's own origin guard) is a
    // convenient way to trigger one without adding new geometry.
    final endBefore = controller.points[line.endPointId]!;
    controller.cursorX = endBefore.x;
    controller.cursorY = endBefore.y;
    controller.beginPointDrag(line.endPointId);
    await controller.updatePointDrag(endBefore.x, endBefore.y);
    await controller.endPointDrag();

    expect(controller.isUnderConstrained, isTrue);
    expect(
      controller.backendFlaggedOverConstrainedPointIds,
      {line.startPointId, line.endPointId},
    );
    expect(controller.isPointForcedOverConstrained(line.startPointId), isTrue);
  });

  test('isFullyConstrained requires both a backend-confirmed dof<=0 solve AND every entity '
      'being topologically grounded to the origin', () async {
    expect(controller.isFullyConstrained, isFalse); // no geometry yet.

    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(0, 0); // chain start, snaps to the origin
    // Phase 6.1: off-axis (not (10, 0)) so placement doesn't auto-add a
    // Constraint of its own - this test's whole premise is that a bare
    // Line creates none until the explicit VerticalConstraint below.
    await controller.handleCanvasTap(10, 3);
    controller.finishChain();
    controller.exitToSelectMode();

    // Backend confirms dof<=0, but no Constraint ties the Line's far
    // endpoint back to the origin - a Line by itself creates no
    // Constraint (see dof_analysis.dart), so even though its *other*
    // endpoint happens to literally be the origin Point, the far one is
    // not grounded, and this must not read as fully constrained.
    backend.dof = 0;
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(20, 20); // any mutation re-solves; unrelated standalone Point.
    expect(controller.isUnderConstrained, isTrue);
    expect(controller.isFullyConstrained, isFalse);

    // Ground it: a Vertical Constraint on the Line unions its two
    // endpoints - one of which is the origin itself - into one cluster.
    controller.exitToSelectMode();
    await controller.handleCanvasTap(8, 2.4); // the line, away from its midpoint
    await controller.addVerticalConstraint();

    expect(controller.isUnderConstrained, isFalse);
    expect(controller.isFullyConstrained, isTrue);
  });

  test('a fully constrained and grounded Point refuses to be dragged even while an unrelated '
      'Point elsewhere in the same Sketch is still free', () async {
    controller.selectDrawTool(SketchTool.line);
    await controller.handleCanvasTap(20, 20); // away from the origin, deliberately not snapped to it
    // Phase 6.1: off-axis (not (30, 20)) so placement doesn't auto-add a
    // HorizontalConstraint, which would change this Line's own DOF/rigidity
    // clustering beyond just the CoincidentConstraint this test adds below.
    await controller.handleCanvasTap(30, 23);
    controller.finishChain();
    final line = controller.lines.values.single;
    final pointAId = line.startPointId; // about to be grounded
    final pointDId = line.endPointId; // stays free throughout

    controller.exitToSelectMode();
    await controller.handleCanvasTap(0, 0); // the origin
    expect(controller.selection!.id, controller.originPointId);
    await controller.handleCanvasTap(20, 20); // adds A to the selection
    await controller.addCoincidentConstraint();

    // The fake backend's dof is independent of this file's own structural
    // analysis - set it to simulate "the rest of the Sketch (here, D's own
    // freedom) isn't backend-confirmed done yet", so isFullyConstrained
    // (whole-Sketch) reads false, while rigidity's *local* verdict for A's
    // own now-grounded-and-pinned cluster is unaffected by that.
    backend.dof = 1;
    controller.selectDrawTool(SketchTool.point);
    await controller.handleCanvasTap(25, 30); // any mutation re-solves; unrelated standalone Point.

    expect(controller.isFullyConstrained, isFalse);
    expect(controller.rigidity.isPointFullyConstrained(pointAId), isTrue);
    expect(controller.isPointFullyPinned(pointAId), isTrue);
    expect(controller.beginPointDrag(pointAId), isFalse);

    // Control: D is still genuinely free, and must remain draggable - the
    // refusal above is per-Point, not an accidental whole-Sketch block.
    expect(controller.isPointFullyPinned(pointDId), isFalse);
    expect(controller.beginPointDrag(pointDId), isTrue);
  });

  group('trim/extend tool (Phase 11)', () {
    test('enterTrimMode switches to SketchMode.trim with a "Trim/Extend" label', () {
      controller.enterTrimMode();
      expect(controller.mode, SketchMode.trim);
      expect(controller.modeLabel, 'Trim/Extend');
    });

    test("tapping near a Line's nearer endpoint extends it to the configured target, in place",
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-trim-1', 'origin-trim-1');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.trimTargetPoint = (15.0, 0.0);
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-trim-1');
      freshController.enterTrimMode();

      // Closer to point-b (x=10) than point-a (x=0) - point-b is the one
      // that moves.
      await freshController.handleCanvasTap(9, 0);

      expect(freshController.errorMessage, isNull);
      expect(freshController.points['point-b']!.x, closeTo(15.0, 1e-9));
      expect(freshController.points['point-b']!.y, closeTo(0.0, 1e-9));
      expect(freshController.lines['line-a']!.startPointId, 'point-a');
      expect(freshController.lines['line-a']!.endPointId, 'point-b');
      // Stays "hot" for another pick, unlike draw/dimension tools.
      expect(freshController.mode, SketchMode.trim);
    });

    test('trimming an endpoint shared with another Line creates a fresh Point instead of '
        'moving it', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-trim-2', 'origin-trim-2');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.points['point-c'] = {'id': 'point-c', 'x': 10.0, 'y': 10.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.lines['line-b'] = {
        'id': 'line-b',
        'start_point_id': 'point-b',
        'end_point_id': 'point-c',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.trimTargetPoint = (15.0, 0.0);
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-trim-2');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(9, 0);

      expect(freshController.errorMessage, isNull);
      // point-b itself is untouched, and the *other* Line sharing it
      // (line-b) still points at it.
      expect(freshController.points['point-b']!.x, closeTo(10.0, 1e-9));
      expect(freshController.lines['line-b']!.startPointId, 'point-b');
      // line-a's own end was repointed to a brand-new Point at the target.
      final newEndId = freshController.lines['line-a']!.endPointId;
      expect(newEndId, isNot('point-b'));
      expect(freshController.points[newEndId]!.x, closeTo(15.0, 1e-9));
    });

    test('no configured intersection surfaces the 422 as errorMessage and leaves the Line '
        'untouched', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-trim-3', 'origin-trim-3');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      // trimTargetPoint left null - "nothing found", mirroring the real
      // backend's NoIntersectionFoundError (422).
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-trim-3');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(9, 0);

      expect(freshController.errorMessage, isNotNull);
      expect(freshController.points['point-b']!.x, closeTo(10.0, 1e-9));
      expect(freshController.mode, SketchMode.trim);
    });

    test('tapping empty canvas in trim mode is a silent no-op - no network request', () async {
      controller.selectDrawTool(SketchTool.line);
      await controller.handleCanvasTap(0, 0);
      await controller.handleCanvasTap(10, 0);
      controller.finishChain();
      controller.exitToSelectMode();
      final requestCountBeforeTrim = backend.requestLog.length;

      controller.enterTrimMode();
      await controller.handleCanvasTap(500, 500); // nowhere near the Line

      expect(backend.requestLog.length, requestCountBeforeTrim);
      expect(controller.errorMessage, isNull);
    });

    test("undo after an in-place trim/extend reverts the moved Point's position", () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-trim-4', 'origin-trim-4');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.trimTargetPoint = (15.0, 0.0);
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-trim-4');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(9, 0);
      expect(freshController.points['point-b']!.x, closeTo(15.0, 1e-9));
      expect(freshController.canUndo, isTrue);

      await freshController.undo();

      expect(freshController.points['point-b']!.x, closeTo(10.0, 1e-9));
      expect(freshController.points['point-b']!.y, closeTo(0.0, 1e-9));
    });

    test('undo after a shared-endpoint trim/extend deletes the new Point and recreates the '
        'original Line', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-trim-5', 'origin-trim-5');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.points['point-c'] = {'id': 'point-c', 'x': 10.0, 'y': 10.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.lines['line-b'] = {
        'id': 'line-b',
        'start_point_id': 'point-b',
        'end_point_id': 'point-c',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.trimTargetPoint = (15.0, 0.0);
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-trim-5');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(9, 0);
      final newPointId = freshController.lines['line-a']!.endPointId;
      expect(newPointId, isNot('point-b'));

      await freshController.undo();

      expect(freshController.points.containsKey(newPointId), isFalse);
      expect(freshController.points.containsKey('point-a'), isTrue);
      expect(freshController.points.containsKey('point-b'), isTrue);
      // The recreated Line gets a fresh id (same convention as every other
      // undo-of-a-mutation in this class - see [_restoreDeletedEntities]),
      // but a Line between the two original endpoints exists again
      // (moved/kept order, not necessarily the original start/end order).
      final recreated = freshController.lines.values.singleWhere(
        (l) =>
            (l.startPointId == 'point-a' && l.endPointId == 'point-b') ||
            (l.startPointId == 'point-b' && l.endPointId == 'point-a'),
      );
      expect(recreated.id, isNot('line-a'));
    });

    // --- On-device feedback follow-up: split-trim (P37), Circle/Arc trim (P36) ---

    test('P37: a click bracketed by two interior crossings splits the Line into two, discarding '
        'the clicked segment, instead of moving either original endpoint', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-split-1', 'origin-split-1');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': -10.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 20.0,
        'construction': false,
      };
      freshBackend.splitTrimTargets = ((-3.0, 0.0), (3.0, 0.0));
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-split-1');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(0, 0); // the middle, between the two configured crossings

      expect(freshController.errorMessage, isNull);
      expect(freshController.lines.containsKey('line-a'), isFalse);
      expect(freshController.lines, hasLength(2));
      final byStartX = freshController.lines.values.toList()
        ..sort((a, b) => freshController.points[a.startPointId]!.x.compareTo(freshController.points[b.startPointId]!.x));
      expect(freshController.points[byStartX[0].startPointId]!.x, closeTo(-10.0, 1e-9));
      expect(freshController.points[byStartX[0].endPointId]!.x, closeTo(-3.0, 1e-9));
      expect(freshController.points[byStartX[1].startPointId]!.x, closeTo(3.0, 1e-9));
      expect(freshController.points[byStartX[1].endPointId]!.x, closeTo(10.0, 1e-9));
      expect(freshController.mode, SketchMode.trim);
    });

    test('P37: undo after a split-trim deletes both new Lines and recreates the original',
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-split-2', 'origin-split-2');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': -10.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 20.0,
        'construction': false,
      };
      freshBackend.splitTrimTargets = ((-3.0, 0.0), (3.0, 0.0));
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-split-2');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(0, 0);
      expect(freshController.lines, hasLength(2));
      expect(freshController.canUndo, isTrue);

      await freshController.undo();

      expect(freshController.lines, hasLength(1));
      final recreated = freshController.lines.values.single;
      expect(freshController.points[recreated.startPointId]!.x, closeTo(-10.0, 1e-9));
      expect(freshController.points[recreated.endPointId]!.x, closeTo(10.0, 1e-9));
    });

    test('P37: a click NOT bracketed by two interior crossings falls back to the original '
        'single-endpoint trim/extend', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-split-3', 'origin-split-3');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      // splitTrimTargets left null (422) - only a single-endpoint target is
      // configured, exactly like the original Phase 11 tests above.
      freshBackend.trimTargetPoint = (15.0, 0.0);
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-split-3');
      freshController.enterTrimMode();

      await freshController.handleCanvasTap(9, 0);

      expect(freshController.errorMessage, isNull);
      expect(freshController.lines, hasLength(1));
      expect(freshController.points['point-b']!.x, closeTo(15.0, 1e-9));
    });

    test('P36: trimming a Circle converts it into an Arc', () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-curve-1', 'origin-curve-1');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-curve-1');
      freshController.selectDrawTool(SketchTool.circle);
      await freshController.handleCanvasTap(0, 0);
      await freshController.handleCanvasTap(5, 0);
      final circleId = freshController.circles.keys.single;

      freshBackend.curveTrimTargetPoint = (0.0, 5.0);
      freshController.enterTrimMode();
      // The Circle tool places its own radius Point at a canonical angle
      // (north, i.e. (0, 5) here), not necessarily the second tap's own
      // position - clicking there would hit that Point first (a Point
      // always outranks a Circle in `_entityAt`'s own priority order), not
      // the circle's own curve. 45deg around the circle (~3.54, 3.54) is
      // clearly on the boundary but far from every one of the Circle's own
      // defining Points.
      await freshController.handleCanvasTap(5 * 0.70710678, 5 * 0.70710678);

      expect(freshController.errorMessage, isNull);
      expect(freshController.circles.containsKey(circleId), isFalse);
      expect(freshController.arcs, hasLength(1));
      expect(freshController.mode, SketchMode.trim);
    });

    test('P36: undo after trimming a Circle deletes the new Arc and recreates a plain Circle',
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-curve-2', 'origin-curve-2');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-curve-2');
      freshController.selectDrawTool(SketchTool.circle);
      await freshController.handleCanvasTap(0, 0);
      await freshController.handleCanvasTap(5, 0);

      freshBackend.curveTrimTargetPoint = (0.0, 5.0);
      freshController.enterTrimMode();
      await freshController.handleCanvasTap(5 * 0.70710678, 5 * 0.70710678);
      expect(freshController.canUndo, isTrue);

      await freshController.undo();

      expect(freshController.arcs, isEmpty);
      expect(freshController.circles, hasLength(1));
    });

    test('P36: trimming an Arc extends its end Point to the configured target, in place',
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-curve-3', 'origin-curve-3');
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-curve-3');
      freshController.selectDrawTool(SketchTool.arc);
      await freshController.handleCanvasTap(0, 0); // center
      await freshController.handleCanvasTap(5, 0); // start (0deg)
      await freshController.handleCanvasTap(0, 5); // end (90deg)
      final arcId = freshController.arcs.keys.single;
      final arc = freshController.arcs[arcId]!;
      final startPointId = arc.startPointId;

      freshBackend.curveTrimTargetPoint = (0.0, -5.0);
      freshController.enterTrimMode();
      // 20deg around the arc - clearly on its own sweep and far from every
      // one of its own defining Points (a Point always outranks an Arc in
      // `_entityAt`'s own priority order - see the Circle test above for
      // why this matters), and clearly nearer the start (0deg) than the
      // end (90deg), so start is the Point that moves.
      await freshController.handleCanvasTap(5 * 0.93969262, 5 * 0.34202014);

      expect(freshController.errorMessage, isNull);
      expect(freshController.points[startPointId]!.x, closeTo(0.0, 1e-9));
      expect(freshController.points[startPointId]!.y, closeTo(-5.0, 1e-9));
      expect(freshController.arcs[arcId]!.startPointId, startPointId);
    });
  });

  group('offset tool (on-device feedback: "when I start the offset tool, the cursor should be '
      'available so I can select the entities to offset")', () {
    test('enterOffsetMode switches to SketchMode.offset with an "Offset" label', () {
      controller.enterOffsetMode();
      expect(controller.mode, SketchMode.offset);
      expect(controller.modeLabel, 'Offset');
    });

    Future<(SketchController, _FakeBackend)> adoptedControllerWithLine() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-offset-1', 'origin-offset-1');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 0.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-offset-1');
      return (freshController, freshBackend);
    }

    test('tapping a Line adds it to selectionSet without calling the offset API yet (P54)', () async {
      final (freshController, freshBackend) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();

      await freshController.handleCanvasTap(3, 0); // off the exact midpoint, on the Line itself

      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshController.selectionSet, hasLength(1));
      expect(freshController.selectionSet.single.kind, SelectionKind.line);
      expect(freshController.selectionSet.single.id, 'line-a');
      expect(freshBackend.requestLog.any((r) => r.contains('/offset')), isFalse);
    });

    test('tapping the same Line again removes it from selectionSet (P54)', () async {
      final (freshController, _) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(3, 0);
      expect(freshController.selectionSet, isNotEmpty);

      await freshController.handleCanvasTap(3, 0);

      expect(freshController.selectionSet, isEmpty);
    });

    test('tapping empty canvas leaves offsetPreviewTargets null and selectionSet empty', () async {
      final (freshController, _) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();

      await freshController.handleCanvasTap(500, 500);

      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshController.selectionSet, isEmpty);
    });

    test('tapping a Point (not a valid offset target) leaves offsetPreviewTargets null and selectionSet empty',
        () async {
      final (freshController, _) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();

      await freshController.handleCanvasTap(0, 0); // point-a

      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshController.selectionSet, isEmpty);
    });

    test('a Circle tap still goes straight to offsetPreviewTargets (P54: no chain endpoint for a lone Circle)',
        () async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-offset-circle', 'origin-offset-circle');
      freshBackend.points['center'] = {'id': 'center', 'x': 0.0, 'y': 0.0};
      freshBackend.points['rim'] = {'id': 'rim', 'x': 5.0, 'y': 0.0};
      freshBackend.circles['circle-a'] = {
        'id': 'circle-a',
        'center_point_id': 'center',
        'radius_point_id': 'rim',
        'radius': 5.0,
        'construction': false,
        'cardinal_point_ids': ['n', 'e', 's', 'w'],
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-offset-circle');
      freshController.enterOffsetMode();

      // 45deg around the boundary - away from the rim Point at (5, 0),
      // which would otherwise win hit-test priority over the Circle itself.
      await freshController.handleCanvasTap(5 * 0.70710678, 5 * 0.70710678);

      expect(freshController.offsetPreviewTargets, hasLength(1));
      expect(freshController.offsetPreviewTargets!.single.kind, SelectionKind.circle);
      expect(freshController.offsetPreviewTargets!.single.id, 'circle-a');
      expect(freshController.selectionSet, isEmpty);
    });

    test('cancelOffsetPreview clears offsetPreviewTargets and notifies listeners', () async {
      final (freshController, _) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(3, 0);
      freshController.finishOffsetChain(); // exactly one pick -> opens the value bar
      expect(freshController.offsetPreviewTargets, isNotNull);
      var notified = false;
      freshController.addListener(() => notified = true);

      freshController.cancelOffsetPreview();

      expect(freshController.offsetPreviewTargets, isNull);
      expect(notified, isTrue);
    });

    test('entering offset mode clears any stale offsetPreviewTargets from a previous session', () async {
      final (freshController, _) = await adoptedControllerWithLine();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(3, 0);
      freshController.finishOffsetChain();
      expect(freshController.offsetPreviewTargets, isNotNull);

      freshController.enterOffsetMode();

      expect(freshController.offsetPreviewTargets, isNull);
    });
  });

  group('offset chain (P54: multi-entity, corner-joining Offset)', () {
    // Deliberately non-`<prefix>-<n>`-shaped seed ids (`line-a`/`line-b`,
    // matching `offsetLine/offsetCircle/offsetArc`'s own
    // `adoptedControllerWithLine` convention above) - `_FakeBackend._newId`
    // mints its own ids as `line-1`, `line-2`, ... from a fresh per-instance
    // counter, so a seed id shaped like `line-1` would silently collide
    // with (and get overwritten by) the fake's own first auto-generated id.
    Future<(SketchController, _FakeBackend)> adoptedControllerWithTwoConnectedLines() async {
      final freshBackend = _FakeBackend();
      freshBackend.seedSketch('sketch-offset-chain-1', 'origin-offset-chain-1');
      freshBackend.points['point-a'] = {'id': 'point-a', 'x': 0.0, 'y': 0.0};
      freshBackend.points['point-corner'] = {'id': 'point-corner', 'x': 10.0, 'y': 0.0};
      freshBackend.points['point-b'] = {'id': 'point-b', 'x': 10.0, 'y': 10.0};
      freshBackend.lines['line-a'] = {
        'id': 'line-a',
        'start_point_id': 'point-a',
        'end_point_id': 'point-corner',
        'length': 10.0,
        'construction': false,
      };
      freshBackend.lines['line-b'] = {
        'id': 'line-b',
        'start_point_id': 'point-corner',
        'end_point_id': 'point-b',
        'length': 10.0,
        'construction': false,
      };
      final mockClient = MockClient((request) async => freshBackend.handle(request));
      final freshController = SketchController(api: SketchApiClient(httpClient: mockClient));
      await freshController.adoptSketch('sketch-offset-chain-1');
      return (freshController, freshBackend);
    }

    test('finishing with nothing picked exits to select mode', () async {
      final (freshController, _) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();

      freshController.finishOffsetChain();

      expect(freshController.mode, SketchMode.select);
      expect(freshController.offsetPreviewTargets, isNull);
    });

    test('picking two connected Lines then finishing hands off offsetPreviewTargets, clearing selectionSet',
        () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0); // line-a
      await freshController.handleCanvasTap(10, 5); // line-b

      freshController.finishOffsetChain();

      final targets = freshController.offsetPreviewTargets;
      expect(targets, isNotNull);
      expect(targets!.length, 2);
      expect(targets.any((s) => s.kind == SelectionKind.line && s.id == 'line-a'), isTrue);
      expect(targets.any((s) => s.kind == SelectionKind.line && s.id == 'line-b'), isTrue);
      expect(freshController.selectionSet, isEmpty);
      expect(freshBackend.requestLog.any((r) => r.contains('/offset')), isFalse);
    });

    test('cancelOffsetPreview clears offsetPreviewTargets and notifies listeners', () async {
      final (freshController, _) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0);
      await freshController.handleCanvasTap(10, 5);
      freshController.finishOffsetChain();
      expect(freshController.offsetPreviewTargets, isNotNull);
      var notified = false;
      freshController.addListener(() => notified = true);

      freshController.cancelOffsetPreview();

      expect(freshController.offsetPreviewTargets, isNull);
      expect(notified, isTrue);
    });

    test(
        'updateOffsetPreviewDistance sets offsetPreviewDistance and offsetPreviewGhosts previews a raw '
        'offset per target, live', () async {
      final (freshController, _) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0);
      await freshController.handleCanvasTap(10, 5);
      freshController.finishOffsetChain();
      expect(freshController.offsetPreviewGhosts, isEmpty); // no distance typed yet

      freshController.updateOffsetPreviewDistance(1.0);

      expect(freshController.offsetPreviewDistance, 1.0);
      final ghosts = freshController.offsetPreviewGhosts;
      expect(ghosts, hasLength(2));
      expect(ghosts, everyElement(isA<LineGhost>()));
      // line-a: (0,0)->(10,0), offset by +1 -> perpendicular (0,1) shift.
      final lineAGhost =
          ghosts.cast<LineGhost>().firstWhere((g) => g.startX == 0.0 && g.startY == 1.0);
      expect(lineAGhost.endX, 10.0);
      expect(lineAGhost.endY, 1.0);

      // Flipping the sign should flip which side the ghost lands on.
      freshController.updateOffsetPreviewDistance(-1.0);
      final flipped = freshController.offsetPreviewGhosts.cast<LineGhost>();
      expect(flipped.any((g) => g.startY == -1.0), isTrue);
    });

    test('confirmOffsetPreview with a single target calls the single-entity offset endpoint, not offsetChain',
        () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0); // line-a only
      freshController.finishOffsetChain();
      freshController.updateOffsetPreviewDistance(1.0);

      await freshController.confirmOffsetPreview();

      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshController.offsetPreviewDistance, isNull);
      expect(freshBackend.requestLog.any((r) => r.contains('/offset-chain')), isFalse);
      expect(freshBackend.requestLog.any((r) => r.contains('/lines/line-a/offset')), isTrue);
    });

    test('confirmOffsetPreview with multiple targets calls offsetChain', () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0);
      await freshController.handleCanvasTap(10, 5);
      freshController.finishOffsetChain();
      freshController.updateOffsetPreviewDistance(1.0);

      await freshController.confirmOffsetPreview();

      expect(freshController.offsetPreviewTargets, isNull);
      expect(freshBackend.requestLog.any((r) => r.contains('/offset-chain')), isTrue);
    });

    test('confirmOffsetPreview with no distance typed is a no-op', () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();
      await freshController.handleCanvasTap(5, 0);
      freshController.finishOffsetChain();

      await freshController.confirmOffsetPreview();

      expect(freshController.offsetPreviewTargets, isNull); // still cleared, just no API call
      expect(freshBackend.requestLog.any((r) => r.contains('/offset')), isFalse);
    });

    test('offsetChain applies the joined corner to local state with undo support', () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();

      await freshController.offsetChain(['line-a', 'line-b'], 1.0);

      expect(freshController.errorMessage, isNull);
      expect(freshController.lines.length, 4); // the 2 originals + 2 new offsets
      final newLines = freshController.lines.values.where((l) => l.id != 'line-a' && l.id != 'line-b').toList();
      expect(newLines, hasLength(2));
      // The fake backend derives each new Point's id from the *original*
      // shared corner id (see the fake's own offsetChainMatch route) - the
      // two new Lines sharing that same derived id is exactly the "stayed
      // connected" signal the real corner-join produces.
      final line1Offset = newLines.firstWhere((l) => l.startPointId == 'offset-chain-point-a');
      final line2Offset = newLines.firstWhere((l) => l.startPointId != 'offset-chain-point-a');
      expect(line1Offset.endPointId, 'offset-chain-point-corner');
      expect(line2Offset.startPointId, 'offset-chain-point-corner');
      expect(line2Offset.endPointId, 'offset-chain-point-b');

      await freshController.undo();

      expect(freshController.lines.keys.toSet(), {'line-a', 'line-b'});
      expect(freshBackend.requestLog.where((r) => r.contains('DELETE') && r.contains('/lines/')), hasLength(2));
    });

    test('offsetChain is a no-op with an empty entity list', () async {
      final (freshController, freshBackend) = await adoptedControllerWithTwoConnectedLines();
      freshController.enterOffsetMode();

      await freshController.offsetChain([], 1.0);

      expect(freshBackend.requestLog.any((r) => r.contains('/offset-chain')), isFalse);
    });
  });
}
