import 'dart:convert';
import 'dart:math' as math;

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
  final Map<String, Map<String, dynamic>> arcs = {};
  final Map<String, Map<String, dynamic>> ellipses = {};
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
      return http.Response('', 204);
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
      return http.Response('', 204);
    }

    final arcDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/arcs/(.+)$').firstMatch(path);
    if (arcDeleteMatch != null && request.method == 'DELETE') {
      return http.Response('', 204);
    }

    final ellipseDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/ellipses/(.+)$').firstMatch(path);
    if (ellipseDeleteMatch != null && request.method == 'DELETE') {
      ellipses.remove(ellipseDeleteMatch.group(1));
      return http.Response('', 204);
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

    final splineDeleteMatch = RegExp(r'^/sketch/sketches/[^/]+/splines/(.+)$').firstMatch(path);
    if (splineDeleteMatch != null && request.method == 'DELETE') {
      splines.remove(splineDeleteMatch.group(1));
      return http.Response('', 204);
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
      return http.Response('', 204);
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
        'construction': false,
      };
      lines[lineId] = line;
      return _json({'line': line, 'start_point': startPoint, 'end_point': endPoint}, 201);
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
      var radiusPointId = body['radius_point_id'] as String?;
      final requestedRadius = (body['radius'] as num?)?.toDouble() ?? 1.0;
      final cardinalPointIds = <String>[];
      if (radiusPointId == null) {
        // Centre-point circle tool's own mode (bare radius, no
        // radius_point_id/angle) - mirrors the real backend's
        // Sketch.add_circle: the new Point becomes the circle's own north
        // cardinal point directly.
        final center = points[body['center_point_id'] as String]!;
        radiusPointId = _newId('point');
        points[radiusPointId] = {
          'id': radiusPointId,
          'x': (center['x'] as num).toDouble(),
          'y': (center['y'] as num).toDouble() + requestedRadius,
        };
        cardinalPointIds.add(radiusPointId);
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

    expect(controller.points.length, 2);
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
    // On the boundary but not on the north cardinal point itself (see
    // SketchController._clickCircleTool's own doc comment).
    await controller.handleCanvasTap(5, 0);
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

  test('togglePolygonGuideCircles flips showPolygonGuideCircles, reflected in the next ghost preview',
      () async {
    expect(controller.showPolygonGuideCircles, isTrue);
    controller.selectDrawTool(SketchTool.polygon);
    await controller.handleCanvasTap(0, 0);
    controller.cursorX = 5;
    controller.cursorY = 0;
    expect((controller.activeDrawGhost as PolygonGhost).showGuideCircles, isTrue);

    controller.togglePolygonGuideCircles();

    expect(controller.showPolygonGuideCircles, isFalse);
    expect((controller.activeDrawGhost as PolygonGhost).showGuideCircles, isFalse);
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

    // On the circle's edge (radius 5, centered on the origin) but not near
    // either of its two real Points - the centre, or the north cardinal
    // point the radius tap now creates (see SketchController._clickCircleTool's
    // own doc comment: the second tap only ever measures a distance, so
    // (5, 0) itself - east - is empty space, unlike north at (0, 5).
    controller.cursorX = 5;
    controller.cursorY = 0;

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

    // On the boundary but not on the north cardinal point the radius tap
    // now creates (see SketchController._clickCircleTool's own doc comment
    // - the second tap only ever measures a distance, so east (10, 0) is
    // empty space, unlike north at (0, 10)).
    await controller.handleCanvasTap(10, 0);

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
    await controller.handleCanvasTap(10, 0); // on the circle's edge

    await controller.confirmGhostValue('diameter', 40.0);

    final constraint = controller.constraints.values.whereType<DistanceConstraintDto>().single;
    expect(controller.showsDiameterFor(constraint.id), isTrue);

    // Re-picking the same circle and confirming the radius ghost this time
    // must flip the same (now-existing) constraint's display mode back.
    controller.enterDimensionMode();
    await controller.handleCanvasTap(10, 0);
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
    expect(controller.points[pointId]!.x, 2);
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

    // East of each circle, not the north cardinal point the radius tap
    // creates (see SketchController._clickCircleTool's own doc comment).
    await controller.handleCanvasTap(5, 0); // first circle's edge
    await controller.handleCanvasTap(23, 0); // second circle's edge

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

    await controller.handleCanvasTap(5, 0); // the circle's edge, not its north cardinal point
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
    // Any further mutation re-solves and refreshes the tracked result -
    // dragging the line's start Point (itself unrelated to the fake
    // failure) is a convenient way to trigger one without adding new
    // geometry.
    controller.beginPointDrag(line.startPointId);
    await controller.updatePointDrag(0, 0);
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
}
