// Shape-proposal vectors (docs/motion/sketch-projector-spec.md, section 13): what a drag of a closed-form shape's point
// proposes for every point of the shape, which provisional sizes it switches on, and what the projector then makes of it.
//
// Written by the "shape proposal vectors" group of test/sketch_controller_test.dart (the hybrid-drag tests' fake backend
// builds the shapes; the controller's own drag code computes every frame) and checked from the file alone by
// test/sketch_shape_vectors_test.dart. tools/sketch_vectors/export_shapes.sh [--check] runs both.
import 'dart:convert';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/projector/sketch_projector.dart';

import 'sketch_projector_cases.dart' show Pt;
import 'sketch_vectors.dart' show r10, encodeSketchVectors;

export 'sketch_vectors.dart' show encodeSketchVectors, sketchVectorDifferences, kRegenerateTolerance;

/// Path of the committed file, relative to `client/`.
const String kShapeVectorsPath = '../docs/motion/sketch-shape-vectors.json';

/// Per-coordinate tolerance of a case: this times `max(1, diagonal of the case's input points)`.
const double kShapePointsRelative = 1e-5;

dynamic shapeClean(dynamic x) {
  if (x is double) return r10(x);
  if (x is Map) return {for (final e in x.entries) e.key as String: shapeClean(e.value)};
  if (x is List) return [for (final v in x) shapeClean(v)];
  return x;
}

Map<String, dynamic> shapePointsJson(Map<String, Pt> points) {
  final keys = points.keys.toList()..sort();
  return {
    for (final k in keys) k: [r10(points[k]!.$1), r10(points[k]!.$2)]
  };
}

Map<String, Pt> shapePointsOf(dynamic json) => {
      for (final e in (json as Map<String, dynamic>).entries)
        e.key: ((e.value[0] as num).toDouble(), (e.value[1] as num).toDouble()),
    };

double shapeDiagonal(Iterable<Pt> pts) {
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final (x, y) in pts) {
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return minX.isFinite ? math.sqrt(math.pow(maxX - minX, 2) + math.pow(maxY - minY, 2)) : 0;
}

/// The positions frame [index] starts from: `input.points` with every earlier frame's `expected.result` laid over it.
Map<String, Pt> shapeFrameStart(Map<String, dynamic> testCase, int index) {
  final prev = shapePointsOf(testCase['input']['points']);
  final frames = testCase['frames'] as List;
  for (var k = 0; k < index; k++) {
    prev.addAll(shapePointsOf(frames[k]['expected']['result']));
  }
  return prev;
}

/// The projector call of a hybrid frame (spec 13.4), from the JSON alone: points = the frame's start with the proposal laid
/// over it, reference = the frame's start, anchors = the grabbed point, stiff = the proposal's ids, pinned and provisional
/// sizes from the file. Returns the clamped positions the controller writes back: the projection's points, plus every
/// proposal point outside the group at its proposal (spec 1, last paragraph). Null when the projection is unsupported or
/// not converged.
Map<String, Pt>? replayShapeClamp(Map<String, dynamic> testCase, int index) {
  final input = testCase['input'] as Map<String, dynamic>;
  final expected = ((testCase['frames'] as List)[index] as Map<String, dynamic>)['expected'] as Map<String, dynamic>;
  final reference = shapeFrameStart(testCase, index);
  final proposal = shapePointsOf(expected['proposal']);
  final lines = {
    for (final e in (input['lines'] as Map<String, dynamic>).entries)
      e.key: (e.value[0] as String, e.value[1] as String),
  };
  final projection = projectSketch(
    points: {...reference, ...proposal},
    reference: reference,
    constraints: [for (final c in input['constraints'] as List) ConstraintDto.fromJson(c as Map<String, dynamic>)],
    lineEndpoints: (id) => lines[id] ?? (throw StateError('unknown line $id')),
    anchorPointIds: {input['grabbed'] as String},
    stiffPointIds: proposal.keys.toSet(),
    pinnedPointIds: {for (final id in input['pinned'] as List) id as String},
    provisionalDistances: {
      for (final e in (expected['provisional'] as Map<String, dynamic>).entries) e.key: (e.value as num).toDouble(),
    },
  );
  if (projection.unsupported || !projection.converged) return null;
  return {
    for (final e in proposal.entries)
      if (!projection.points.containsKey(e.key)) e.key: e.value,
    ...projection.points,
  };
}

/// The document's text (the projector vectors' layout: one case per block, one frame per line).
String encodeShapeVectors(Map<String, dynamic> doc) => encodeSketchVectors(doc);

/// Round-trips [doc] through JSON (so the in-memory regeneration compares like the file).
Map<String, dynamic> shapeVectorsViaJson(Map<String, dynamic> doc) =>
    jsonDecode(encodeShapeVectors(doc)) as Map<String, dynamic>;
