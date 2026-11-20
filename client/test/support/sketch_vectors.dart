// Golden vectors for the sketch drag projector (docs/motion/sketch-projector-spec.md, section 10): built here, written to and
// checked against docs/motion/sketch-vectors.json by `test/sketch_vectors_test.dart` (tools/sketch_vectors/export.sh).
//
// Runs under `flutter test`, not `dart run`: the projector imports `sketch_api_client.dart`, which pulls in Flutter
// (`shared_preferences`).
//
// Deterministic: no randomness; every float is rounded to 10 decimals (and -0.0 -> 0.0) before it is written, and inputs are
// rounded BEFORE the expected values are computed from them (the input is written to JSON, read back, and only then run),
// so a client reading the file reproduces `expected` from exactly the inputs it sees.
import 'dart:convert';
import 'dart:math' as math;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/projector/sketch_projector.dart';

import 'sketch_projector_cases.dart';

/// Path of the committed file, relative to `client/` (where `flutter test` runs).
const String kSketchVectorsPath = '../docs/motion/sketch-vectors.json';

/// Two regenerations may differ by this much (last-digit rounding of a different libm); anything else must be identical.
const double kRegenerateTolerance = 1e-9;

/// A port's answer must be within `kPointsRelative * max(1, diagonal of the case's start points)` of `expected` (each
/// coordinate). The walk stops when a step moves less than kProjectorArrived (1e-5) of the group's size, so a port whose
/// rounding takes one step more or less lands within about that of the Dart answer (the nudge test in
/// sketch_vectors_test.dart measures the margin: 1e-10 on the inputs moves no answer by 1 % of this).
const double kPointsRelative = 1e-5;

// ---- the backend's wire form of a constraint (what VR already parses) ----------------------------------------------

Map<String, dynamic> constraintToWire(ConstraintDto c) {
  Map<String, dynamic> w(String type, Map<String, dynamic> fields) => {'type': type, 'id': c.id, ...fields};
  if (c is DistanceConstraintDto) {
    return w('distance', {
      'point_a_id': c.pointAId,
      'point_b_id': c.pointBId,
      'distance': c.distance,
      'orientation': c.orientation,
      if (c.provisional) 'provisional': true,
    });
  }
  if (c is VerticalConstraintDto) return w('vertical', {'line_id': c.lineId, 'point_a_id': c.pointAId, 'point_b_id': c.pointBId});
  if (c is HorizontalConstraintDto) {
    return w('horizontal', {'line_id': c.lineId, 'point_a_id': c.pointAId, 'point_b_id': c.pointBId});
  }
  if (c is AngleConstraintDto) {
    return w('angle', {'line1_id': c.line1Id, 'line2_id': c.line2Id, 'angle_degrees': c.angleDegrees, 'quadrant': c.quadrant});
  }
  if (c is CoincidentConstraintDto) return w('coincident', {'point_a_id': c.pointAId, 'point_b_id': c.pointBId});
  if (c is ConcentricConstraintDto) {
    return w('concentric', {
      'entity1_id': c.entity1Id,
      'entity2_id': c.entity2Id,
      'center1_point_id': c.center1PointId,
      'center2_point_id': c.center2PointId,
    });
  }
  if (c is ParallelConstraintDto) return w('parallel', {'line1_id': c.line1Id, 'line2_id': c.line2Id});
  if (c is PerpendicularConstraintDto) return w('perpendicular', {'line1_id': c.line1Id, 'line2_id': c.line2Id});
  if (c is EqualLengthConstraintDto) return w('equal_length', {'line1_id': c.line1Id, 'line2_id': c.line2Id});
  if (c is CollinearConstraintDto) return w('collinear', {'line1_id': c.line1Id, 'line2_id': c.line2Id});
  if (c is LineDistanceConstraintDto) {
    return w('line_distance', {'line1_id': c.line1Id, 'line2_id': c.line2Id, 'distance': c.distance});
  }
  if (c is PointLineDistanceConstraintDto) {
    return w('point_line_distance', {'point_id': c.pointId, 'line_id': c.lineId, 'distance': c.distance});
  }
  if (c is AtMidpointConstraintDto) return w('at_midpoint', {'point_id': c.pointId, 'line_id': c.lineId});
  if (c is SplineTangentConstraintDto) {
    return w('spline_tangent', {
      'spline_id': c.splineId,
      'segment_a_p0': c.segmentAP0,
      'segment_a_p1': c.segmentAP1,
      'segment_a_p2': c.segmentAP2,
      'segment_a_p3': c.segmentAP3,
      'segment_b_p0': c.segmentBP0,
      'segment_b_p1': c.segmentBP1,
      'segment_b_p2': c.segmentBP2,
      'segment_b_p3': c.segmentBP3,
    });
  }
  if (c is TangentConstraintDto) {
    return w('tangent', {'center_point_id': c.centerPointId, 'radius_point_id': c.radiusPointId, 'line_id': c.lineId});
  }
  if (c is CurveTangentConstraintDto) {
    return w('curve_tangent', {
      'entity1_id': c.entity1Id,
      'entity2_id': c.entity2Id,
      'center1_point_id': c.center1PointId,
      'center2_point_id': c.center2PointId,
      'shared_point_id': c.sharedPointId,
    });
  }
  if (c is EqualRadiusConstraintDto) {
    return w('equal_radius', {
      'center1_point_id': c.center1PointId,
      'radius1_point_id': c.radius1PointId,
      'center2_point_id': c.center2PointId,
      'radius2_point_id': c.radius2PointId,
    });
  }
  if (c is PointOnLineConstraintDto) return w('point_on_line', {'point_id': c.pointId, 'line_id': c.lineId});
  if (c is PointOnCircleConstraintDto) {
    return w('point_on_circle', {
      'point_id': c.pointId,
      'circle_or_arc_id': c.circleOrArcId,
      'center_point_id': c.centerPointId,
      'radius_point_id': c.radiusPointId,
    });
  }
  if (c is PointOnEllipseConstraintDto) {
    return w('point_on_ellipse', {
      'point_id': c.pointId,
      'ellipse_id': c.ellipseId,
      'center_point_id': c.centerPointId,
      'major_point_id': c.majorPointId,
      'minor_point_id': c.minorPointId,
    });
  }
  if (c is FixedConstraintDto) return w('fixed', {'point_ids': c.pointIds});
  if (c is ArcLengthConstraintDto) {
    return w('arc_length', {
      'arc_id': c.arcId,
      'center_point_id': c.centerPointId,
      'start_point_id': c.startPointId,
      'end_point_id': c.endPointId,
      'length': c.length,
    });
  }
  if (c is HorizontalAngleConstraintDto) {
    return w('horizontal_angle', {
      'line_id': c.lineId,
      'line_start_id': c.lineStartId,
      'line_end_id': c.lineEndId,
      'angle_degrees': c.angleDegrees,
      'quadrant': c.quadrant,
    });
  }
  if (c is PointAngleConstraintDto) {
    return w('point_angle', {
      'vertex_point_id': c.vertexPointId,
      'point1_id': c.point1Id,
      'point2_id': c.point2Id,
      'angle_degrees': c.angleDegrees,
      'quadrant': c.quadrant,
    });
  }
  if (c is PointCircleDistanceConstraintDto) {
    return w('point_circle_distance', {
      'point_id': c.pointId,
      'circle_or_arc_id': c.circleOrArcId,
      'center_point_id': c.centerPointId,
      'radius_point_id': c.radiusPointId,
      'distance': c.distance,
      'side': c.side,
    });
  }
  if (c is CircleCircleDistanceConstraintDto) {
    return w('circle_distance', {
      'entity1_id': c.entity1Id,
      'center1_point_id': c.center1PointId,
      'radius1_point_id': c.radius1PointId,
      'entity2_id': c.entity2Id,
      'center2_point_id': c.center2PointId,
      'radius2_point_id': c.radius2PointId,
      'distance': c.distance,
      'side': c.side,
    });
  }
  if (c is LineCircleDistanceConstraintDto) {
    return w('line_circle_distance', {
      'line_id': c.lineId,
      'line_start_id': c.lineStartId,
      'line_end_id': c.lineEndId,
      'circle_or_arc_id': c.circleOrArcId,
      'center_point_id': c.centerPointId,
      'radius_point_id': c.radiusPointId,
      'distance': c.distance,
      'side': c.side,
    });
  }
  throw ArgumentError('no wire form for ${c.runtimeType}');
}

// ---- rounding and JSON ---------------------------------------------------------------------------------------------

double r10(double v) {
  final r = double.parse(v.toStringAsFixed(10));
  return r == 0 ? 0.0 : r;
}

dynamic _clean(dynamic x) {
  if (x is double) return r10(x);
  if (x is Map) return {for (final e in x.entries) e.key as String: _clean(e.value)};
  if (x is List) return [for (final v in x) _clean(v)];
  return x;
}

Map<String, dynamic> _pointsJson(Map<String, Pt> points) {
  final keys = points.keys.toList()..sort();
  return {for (final k in keys) k: [points[k]!.$1, points[k]!.$2]};
}

Map<String, Pt> _pointsOf(dynamic json) => {
      for (final e in (json as Map<String, dynamic>).entries)
        e.key: ((e.value[0] as num).toDouble(), (e.value[1] as num).toDouble()),
    };

// ---- the replay: one frame from the JSON alone (the procedure of the spec's section 10) -----------------------------

/// The positions frame [index] of [testCase] starts from: `input.start` with every earlier frame's `expected.points` laid
/// over it in turn.
Map<String, Pt> frameStart(Map<String, dynamic> testCase, int index) {
  final prev = _pointsOf(testCase['input']['start']);
  final frames = testCase['frames'] as List;
  for (var k = 0; k < index; k++) {
    prev.addAll(_pointsOf(frames[k]['expected']['points']));
  }
  return prev;
}

/// Runs frame [index] of [testCase] through [projectSketch], reading nothing but the JSON.
SketchProjection replayFrame(Map<String, dynamic> testCase, int index) {
  final input = testCase['input'] as Map<String, dynamic>;
  final frame = (testCase['frames'] as List)[index] as Map<String, dynamic>;
  final reference = frameStart(testCase, index);
  final points = {...reference, ..._pointsOf(frame['wish'])};
  final lines = {
    for (final e in (input['lines'] as Map<String, dynamic>).entries) e.key: (e.value[0] as String, e.value[1] as String),
  };
  return projectSketch(
    points: points,
    reference: reference,
    constraints: [for (final c in input['constraints'] as List) ConstraintDto.fromJson(c as Map<String, dynamic>)],
    lineEndpoints: (id) => lines[id] ?? (throw StateError('unknown line $id')),
    anchorPointIds: {for (final id in input['anchors'] as List) id as String},
    stiffPointIds: {for (final id in input['stiff'] as List) id as String},
    pinnedPointIds: {for (final id in input['pinned'] as List) id as String},
    provisionalDistances: {
      for (final e in (input['provisional'] as Map<String, dynamic>).entries) e.key: (e.value as num).toDouble(),
    },
  );
}

Map<String, dynamic> expectedOf(SketchProjection r) => _clean({
      'unsupported': r.unsupported,
      'converged': r.converged,
      'points': _pointsJson(r.points),
      'variable_points': r.variablePoints,
      'rows': r.rows,
      'residual_inf': r.residualInf.isFinite ? r.residualInf : null,
      'exit': r.exit,
      'walks': r.walks,
      'rejected_steps': r.rejectedSteps,
      'iterations': r.iterations,
    }) as Map<String, dynamic>;

// ---- case building --------------------------------------------------------------------------------------------------

class _Spec {
  final String id;
  final String kind;
  final String description;
  final Map<String, Pt> start;
  final Map<String, (String, String)> lines;
  final List<ConstraintDto> constraints;
  final List<String> anchors;
  final List<String> stiff;
  final List<String> pinned;
  final Map<String, double> provisional;
  final List<Map<String, Pt>> wishes;
  final Pt? nearest;
  _Spec(this.id, this.kind, this.description,
      {required this.start,
      this.lines = const {},
      required this.constraints,
      required this.anchors,
      this.stiff = const [],
      this.pinned = const [],
      this.provisional = const {},
      required this.wishes,
      this.nearest});
}

double _diagonal(Map<String, Pt> pts) {
  var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
  for (final (x, y) in pts.values) {
    minX = math.min(minX, x);
    maxX = math.max(maxX, x);
    minY = math.min(minY, y);
    maxY = math.max(maxY, y);
  }
  return pts.isEmpty ? 0 : math.sqrt(math.pow(maxX - minX, 2) + math.pow(maxY - minY, 2));
}

Map<String, dynamic> _build(_Spec s) {
  final linesJson = {
    for (final id in (s.lines.keys.toList()..sort())) id: [s.lines[id]!.$1, s.lines[id]!.$2],
  };
  final input = _clean({
    'start': _pointsJson(s.start),
    'lines': linesJson,
    'constraints': [for (final c in s.constraints) constraintToWire(c)],
    'anchors': s.anchors,
    'stiff': s.stiff,
    'pinned': s.pinned,
    'provisional': {for (final id in (s.provisional.keys.toList()..sort())) id: s.provisional[id]},
  });
  final testCase = <String, dynamic>{
    'id': s.id,
    'kind': s.kind,
    'description': s.description,
    'tolerance': r10(kPointsRelative * math.max(1.0, _diagonal(s.start))),
    'input': input,
    'frames': <Map<String, dynamic>>[],
  };
  // Compute from exactly what a client will read: the JSON text, parsed back.
  final read = jsonDecode(jsonEncode(testCase)) as Map<String, dynamic>;
  for (var k = 0; k < s.wishes.length; k++) {
    (read['frames'] as List).add({'wish': _clean(_pointsJson(s.wishes[k]))});
    final readBack = jsonDecode(jsonEncode(read)) as Map<String, dynamic>;
    final expected = expectedOf(replayFrame(readBack, k));
    (read['frames'] as List)[k]['expected'] = expected;
  }
  if (s.nearest != null) read['nearest'] = _clean([s.nearest!.$1, s.nearest!.$2]);
  return read;
}

String _slug(String name) =>
    name.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// One grabbed point `d`, every other point pinned: the golden cases of `sketch_projector_test.dart`.
List<_Spec> _goldenSpecs() => [
      for (final c in [...projectorGoldenCases, ...projectorPartDCases])
        _Spec('golden-${_slug(c.name)}', 'golden', c.name,
            start: c.points,
            lines: c.lines,
            constraints: c.constraints,
            anchors: ['d'],
            pinned: [for (final id in c.points.keys) if (id != 'd') id],
            wishes: [
              {'d': c.wish},
            ],
            nearest: c.expected),
    ];

/// A drag path per golden case: the same geometry with only the first other point pinned (the rest follow), the hand going
/// from `d` towards the golden wish and twice as far, bowed to one side, in 8 frames.
List<_Spec> _dragSpecs() {
  final out = <_Spec>[];
  for (final c in [...projectorGoldenCases, ...projectorPartDCases]) {
    final s = c.points['d']!;
    final w = c.wish;
    final dx = w.$1 - s.$1, dy = w.$2 - s.$2;
    final l = math.sqrt(dx * dx + dy * dy);
    final nx = -dy / l, ny = dx / l;
    final pinned = [for (final id in c.points.keys) if (id != 'd') id].take(1).toList();
    out.add(_Spec('drag-${_slug(c.name)}', 'drag', '${c.name}: $pinned pinned, the other points follow; 8 frames along a bowed path',
        start: c.points,
        lines: c.lines,
        constraints: c.constraints,
        anchors: ['d'],
        pinned: pinned,
        wishes: [
          for (var k = 1; k <= 8; k++)
            {
              'd': (
                s.$1 + dx * k / 4 + nx * 0.3 * l * math.sin(math.pi * k / 8),
                s.$2 + dy * k / 4 + ny * 0.3 * l * math.sin(math.pi * k / 8),
              ),
            },
        ]));
  }
  return out;
}

List<Map<String, Pt>> _path(String id, List<Pt> pts) => [
      for (final p in pts) {id: p},
    ];

List<Pt> _arc(double radius, List<double> degrees, [Pt center = (0, 0)]) => [
      for (final a in degrees) (center.$1 + radius * math.cos(a * math.pi / 180), center.$2 + radius * math.sin(a * math.pi / 180)),
    ];

/// Paths that cross a branch choice (spec section 5): the answer must stay on the branch the start was on.
List<_Spec> _branchSpecs() => [
      _Spec('branch-vertical-distance-below', 'branch', 'vertical distance 10 with d below a: the hand rises past a, d stays 10 below',
          start: {'a': (0, 0), 'd': (3, -10)},
          constraints: [DistanceConstraintDto(id: 'k', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'vertical')],
          anchors: ['d'],
          pinned: ['a'],
          wishes: _path('d', [(4, -6), (5, -2), (6, 2), (7, 6), (8, 10), (9, 14)])),
      _Spec('branch-horizontal-distance-left', 'branch', 'horizontal distance 10 with d left of a: the hand crosses to the right, d stays 10 left',
          start: {'a': (0, 0), 'd': (-10, 2)},
          constraints: [DistanceConstraintDto(id: 'k', pointAId: 'a', pointBId: 'd', distance: 10, orientation: 'horizontal')],
          anchors: ['d'],
          pinned: ['a'],
          wishes: _path('d', [(-6, 3), (-2, 4), (2, 5), (6, 6), (10, 7), (14, 8)])),
      _Spec('branch-angle-supplement', 'branch',
          'two-line angle 60 held as its supplement (120, as the start has it): the hand sweeps to 60 degrees, d stays on the 120 ray',
          start: {'a': (0, 0), 'b': (10, 0), 'd': _arc(10, [120])[0]},
          lines: {'l1': ('a', 'b'), 'l2': ('a', 'd')},
          constraints: [AngleConstraintDto(id: 'k', line1Id: 'l1', line2Id: 'l2', angleDegrees: 60)],
          anchors: ['d'],
          pinned: ['a', 'b'],
          wishes: _path('d', _arc(10, [112, 104, 96, 88, 76, 64]))),
      _Spec('branch-horizontal-angle-no-quadrant', 'branch',
          'angle to horizontal 30, no quadrant, the line at 150: the hand sweeps to 40 degrees, the line stays at 150',
          start: {'a': (0, 0), 'd': _arc(10, [150])[0]},
          lines: {'l': ('a', 'd')},
          constraints: [HorizontalAngleConstraintDto(id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'd', angleDegrees: 30)],
          anchors: ['d'],
          pinned: ['a'],
          wishes: _path('d', _arc(10, [140, 120, 100, 80, 60, 40]))),
      _Spec('branch-point-angle-no-quadrant', 'branch',
          'three-point angle 40, no quadrant, the start open at 140: the hand sweeps to 40 degrees, the angle stays 140',
          start: {'v': (0, 0), 'a': (10, 0), 'd': _arc(10, [140])[0]},
          constraints: [PointAngleConstraintDto(id: 'k', vertexPointId: 'v', point1Id: 'a', point2Id: 'd', angleDegrees: 40)],
          anchors: ['d'],
          pinned: ['v', 'a'],
          wishes: _path('d', _arc(10, [130, 110, 90, 70, 50, 40]))),
      _Spec('branch-point-circle-minimum-outside', 'branch',
          'minimum distance 3 from a radius-5 circle, the Point outside: the hand passes over the centre, the Point stays 8 out',
          start: {'c': (0, 0), 'r': (0, 5), 'd': (8, 0)},
          constraints: [
            PointCircleDistanceConstraintDto(
                id: 'k', pointId: 'd', circleOrArcId: 'circle', centerPointId: 'c', radiusPointId: 'r', distance: 3, side: 'min'),
          ],
          anchors: ['d'],
          pinned: ['c', 'r'],
          wishes: _path('d', [(6, 1), (4, 1), (2, 1), (0, 1), (-2, 1), (-4, 1)])),
      _Spec('branch-line-circle-tangent-side', 'branch',
          'tangent-side distance 6, circle above the line: its centre is dragged down through the line, the circle stays above',
          start: {'a': (-20, 0), 'b': (20, 0), 'c': (2, 10), 'r': (6, 10)},
          lines: {'l': ('a', 'b')},
          constraints: [
            LineCircleDistanceConstraintDto(
                id: 'k', lineId: 'l', lineStartId: 'a', lineEndId: 'b', circleOrArcId: 'circle', centerPointId: 'c',
                radiusPointId: 'r', distance: 6, side: 'min'),
            DistanceConstraintDto(id: 'rad', pointAId: 'c', pointBId: 'r', distance: 4),
          ],
          anchors: ['c'],
          pinned: ['a', 'b'],
          wishes: _path('c', [(3, 6), (4, 2), (5, -2), (6, -6), (7, -10), (8, -14)])),
    ];

const _noLines = <String, (String, String)>{};

List<_Spec> _sceneSpecs() {
  final chainStart = <String, Pt>{'p0': (0, 0)};
  final chain = <ConstraintDto>[];
  for (var i = 1; i <= 20; i++) {
    chainStart['p$i'] = (5.0 * i, 0.3 * math.sin(i.toDouble()));
    chain.add(DistanceConstraintDto(id: 'c$i', pointAId: 'p${i - 1}', pointBId: 'p$i', distance: 5));
  }
  final tip = chainStart['p20']!;
  // The same 20 links curled on a radius-60 arc (a feasible start, away from the straight bifurcation): the timing vector.
  final theta = 2 * math.asin(2.5 / 60);
  final curledStart = <String, Pt>{
    for (var i = 0; i <= 20; i++) 'p$i': (60 * math.sin(i * theta), 60 * (1 - math.cos(i * theta))),
  };
  final curledTip = curledStart['p20']!;
  final rect = <String, Pt>{'o': (0, 0), 'a': (10, 0), 'b': (10, 6), 'c': (0, 6)};
  const rectLines = {'l0': ('o', 'a'), 'l1': ('a', 'b'), 'l2': ('b', 'c'), 'l3': ('c', 'o')};
  final rectSides = <ConstraintDto>[
    HorizontalConstraintDto(id: 'h0', lineId: 'l0', pointAId: 'o', pointBId: 'a'),
    VerticalConstraintDto(id: 'v1', lineId: 'l1', pointAId: 'a', pointBId: 'b'),
    HorizontalConstraintDto(id: 'h2', lineId: 'l2', pointAId: 'b', pointBId: 'c'),
    VerticalConstraintDto(id: 'v3', lineId: 'l3', pointAId: 'c', pointBId: 'o'),
    DistanceConstraintDto(id: 'w', pointAId: 'o', pointBId: 'a', distance: 10, orientation: 'horizontal'),
  ];
  return [
    _Spec('scene-free-point', 'scene', 'a point no constraint touches goes exactly where the hand is',
        start: {'p': (8, 0.4), 'q': (1, 1)}, constraints: const [], anchors: ['p'], wishes: _path('p', [(50, 60)])),
    _Spec('scene-horizontal-to-pinned', 'scene', 'horizontal to a pinned point: d slides along y = 0 to the hand\'s x',
        start: {'o': (0, 0), 'd': (10, 0)},
        constraints: [HorizontalConstraintDto(id: 'h', lineId: 'l', pointAId: 'o', pointBId: 'd')],
        anchors: ['d'],
        pinned: ['o'],
        wishes: _path('d', [(30, 40)])),
    _Spec('scene-group-only', 'scene', 'only the dragged point\'s group is solved: x and y are not in the answer',
        start: {'a': (0, 0), 'd': (10, 0), 'x': (50, 50), 'y': (60, 50)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'x', pointBId: 'y', distance: 10),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(10, 3)])),
    _Spec('scene-pinned-does-not-link', 'scene', 'a pinned point does not join two groups: x stays out',
        start: {'a': (0, 0), 'd': (10, 0), 'x': (-10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'x', distance: 10),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(10, 3)])),
    _Spec('scene-arm-followers', 'scene', 'two-link arm: the joint f follows, the tip is pulled toward a point past its reach',
        start: {'a': (0, 0), 'f': (10, 0.5), 'd': (20, 0.5)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'f', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'f', pointBId: 'd', distance: 10),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(25, 0)])),
    _Spec('scene-arm-wall', 'scene', 'two-link arm, the hand far beyond the reach: the tip lands on the wall (20 from a)',
        start: {'a': (0, 0), 'f': (10, 0.2), 'd': (20, 0.2)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'f', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'f', pointBId: 'd', distance: 10),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(60, 0)])),
    _Spec('scene-redundant', 'scene', 'the same distance twice (consistent, redundant): harmless',
        start: {'a': (0, 0), 'd': (10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'd', pointBId: 'a', distance: 10),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(7, 7)])),
    _Spec('scene-conflict', 'scene', 'distance 10 and 12 between the same points: not converged',
        start: {'a': (0, 0), 'd': (10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'd', distance: 12),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: [{}]),
    _Spec('scene-provisional-off', 'scene', 'a provisional distance with no value from the caller takes no part (0 rows)',
        start: {'a': (0, 0), 'd': (7, 7)},
        constraints: [DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10, provisional: true)],
        anchors: ['d'],
        pinned: ['a'],
        wishes: [{}]),
    _Spec('scene-provisional-on', 'scene',
        'the same provisional distance switched on at 5 by the caller: the start is polished onto it (it starts at 9.9)',
        start: {'a': (0, 0), 'd': (7, 7)},
        constraints: [DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10, provisional: true)],
        anchors: ['d'],
        pinned: ['a'],
        provisional: {'c1': 5},
        wishes: [{}]),
    _Spec('scene-spline-unsupported', 'scene', 'a spline tangency in the dragged group: unsupported, nothing computed',
        start: {for (final id in ['a0', 'a1', 'a2', 'a3', 'b0', 'b1', 'b2', 'b3']) id: (0.0, 0.0)},
        constraints: const [
          SplineTangentConstraintDto(
            id: 'k',
            splineId: 's',
            segmentAP0: 'a0',
            segmentAP1: 'a1',
            segmentAP2: 'a2',
            segmentAP3: 'a3',
            segmentBP0: 'b0',
            segmentBP1: 'b1',
            segmentBP2: 'b2',
            segmentBP3: 'b3',
          ),
        ],
        anchors: ['a3'],
        wishes: _path('a3', [(1, 1)])),
    _Spec('scene-spline-elsewhere', 'scene', 'a spline tangency outside the dragged group does not matter',
        start: {
          'a': (0, 0),
          'd': (10, 0),
          for (final id in ['a0', 'a1', 'a2', 'a3', 'b0', 'b1', 'b2', 'b3']) id: (30.0, 30.0),
        },
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          SplineTangentConstraintDto(
            id: 'k',
            splineId: 's',
            segmentAP0: 'a0',
            segmentAP1: 'a1',
            segmentAP2: 'a2',
            segmentAP3: 'a3',
            segmentBP0: 'b0',
            segmentBP1: 'b1',
            segmentBP2: 'b2',
            segmentBP3: 'b3',
          ),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(7, 7)])),
    _Spec('scene-unknown-ids-skipped', 'scene',
        'a constraint naming a Line the caller does not know, and one naming a missing Point, take no part (1 row)',
        start: {'a': (0, 0), 'd': (10, 0)},
        lines: _noLines,
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          PointOnLineConstraintDto(id: 'ghost-line', pointId: 'd', lineId: 'no-such-line'),
          DistanceConstraintDto(id: 'ghost-point', pointAId: 'd', pointBId: 'no-such-point', distance: 3),
        ],
        anchors: ['d'],
        pinned: ['a'],
        wishes: _path('d', [(7, 7)])),
    _Spec('scene-fixed-is-the-callers', 'scene',
        'a Fix constraint is ignored: pinning is the caller\'s pinned set, so a, not in it, follows the drag',
        start: {'a': (0, 0), 'd': (10, 0)},
        constraints: [
          DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'd', distance: 10),
          FixedConstraintDto(id: 'fix', pointIds: ['a']),
        ],
        anchors: ['d'],
        wishes: _path('d', [(15, 5)])),
    _Spec('scene-rectangle-stiff-proposal', 'scene',
        'rectangle on the origin, width dimensioned: b grabbed, c a stiff proposal; b can only rise, c keeps its proposal',
        start: rect,
        lines: rectLines,
        constraints: rectSides,
        anchors: ['b'],
        stiff: ['c'],
        pinned: ['o'],
        wishes: [
          // (not round numbers: a step ratio of exactly 0.5 sits on the Aitken threshold, and a port's rounding would pick a side)
          {'b': (14, 9.3), 'c': (0, 9.3)},
          {'b': (15, 12.4), 'c': (0, 12.4)},
        ]),
    _Spec('scene-circle-cardinals', 'scene',
        'circle as the backend builds it (cardinal points pinned to the centre by distance 0 horizontal / vertical, equal radii), '
        'centre dimensioned 15 from a pinned point: the centre slides on the 15 circle, the shape rides along',
        start: {'o': (0, 0), 'c': (15, 0), 'e': (19, 0), 'n': (15, 4)},
        constraints: [
          DistanceConstraintDto(id: 'pe', pointAId: 'c', pointBId: 'e', distance: 0, orientation: 'vertical'),
          DistanceConstraintDto(id: 'pn', pointAId: 'c', pointBId: 'n', distance: 0, orientation: 'horizontal'),
          EqualRadiusConstraintDto(id: 'eq', center1PointId: 'c', radius1PointId: 'e', center2PointId: 'c', radius2PointId: 'n'),
          DistanceConstraintDto(id: 'dim', pointAId: 'o', pointBId: 'c', distance: 15),
        ],
        anchors: ['c'],
        pinned: ['o'],
        wishes: _path('c', [(14, 6), (10, 12), (2, 20)])),
    _Spec('scene-two-anchors', 'scene', 'a whole line grabbed (both ends anchors): horizontal, length 10; r hangs off q at 5 and follows',
        start: {'p': (0, 0), 'q': (10, 0), 'r': (10, 5)},
        lines: {'l': ('p', 'q')},
        constraints: [
          HorizontalConstraintDto(id: 'h', lineId: 'l', pointAId: 'p', pointBId: 'q'),
          DistanceConstraintDto(id: 'len', pointAId: 'p', pointBId: 'q', distance: 10),
          DistanceConstraintDto(id: 'hang', pointAId: 'q', pointBId: 'r', distance: 5),
        ],
        anchors: ['p', 'q'],
        wishes: [
          {'p': (3, 4), 'q': (13, 5)},
          {'p': (6, 8), 'q': (16, 7)},
        ]),
    _Spec('scene-chain-20-nearly-straight', 'scene',
        '20 distance-5 links from a pinned origin, nearly straight (an infeasible start: polished first), the tip pulled sideways '
        'and out: a singular start (the straight-chain bifurcation); the rescue step (spec 7.3) lets the tip swing round the pinned '
            'origin towards the hand (before F6 the walk stalled and nothing moved)',
        start: chainStart,
        constraints: chain,
        anchors: ['p20'],
        pinned: ['p0'],
        wishes: _path('p20', [(tip.$1, tip.$2 + 2), (tip.$1 + 2, tip.$2 + 8), (tip.$1 + 20, tip.$2 + 10)])),
    _Spec('scene-chain-20-curled', 'scene',
        '20 distance-5 links curled on a radius-60 arc from a pinned origin, the tip dragged about (the timing vector)',
        start: curledStart,
        constraints: chain,
        anchors: ['p20'],
        pinned: ['p0'],
        wishes: _path('p20', [
          (curledTip.$1 - 3, curledTip.$2 + 2),
          (curledTip.$1 - 8, curledTip.$2 + 6),
          (curledTip.$1 - 15, curledTip.$2 + 4),
          (curledTip.$1 + 10, curledTip.$2 + 15),
        ])),
  ];
}

/// The whole document, in the order it is written.
Map<String, dynamic> buildSketchVectors() {
  final cases = [
    for (final s in [..._goldenSpecs(), ..._dragSpecs(), ..._branchSpecs(), ..._sceneSpecs()]) _build(s),
  ];
  final ids = <String>{};
  for (final c in cases) {
    if (!ids.add(c['id'] as String)) throw StateError('duplicate case id ${c['id']}');
  }
  return {
    'version': 1,
    'spec': 'docs/motion/sketch-projector-spec.md',
    'generator': 'client/test/sketch_vectors_test.dart (tools/sketch_vectors/export.sh writes; --check verifies)',
    'regenerate_tolerance': kRegenerateTolerance,
    'points_relative_tolerance': kPointsRelative,
    'constants': {
      'follower_stiffness': kProjectorFollowerStiffness,
      'nearest_max': kProjectorNearestMax,
      'arrived': kProjectorArrived,
      'min_omega': kProjectorMinOmega,
      'max_boost': kProjectorMaxBoost,
      'correctors': kProjectorCorrectors,
      'max_polish': kProjectorMaxPolish,
      'tolerance': kProjectorTolerance,
      'trust': kProjectorTrust,
      'trust_diagonal': kProjectorTrustDiagonal,
      // literals in sketch_projector.dart (no named constant there)
      'eps': 1e-12,
      'lambda_relative': 1e-10,
      'lambda_absolute': 1e-14,
      'corrector_halvings': 8,
      'closer_ratio': 1e-9,
      'rho_reverse': -0.3,
      'rho_boost_low': 0.5,
      'rho_boost_high': 0.999,
      'stall_limit': 5,
    },
    'conventions': {
      'point': '[x, y] in sketch units (mm)',
      'constraint': 'the backend wire form (type + fields), as GET .../constraints returns it',
      'frame': 'start = input.start, then every earlier frame\'s expected.points laid over it; '
          'call: points = start + wish (wish replaces those ids), reference = start, anchors / stiff / pinned / provisional from input',
      'expected': 'normative: unsupported, converged, the ids of points, each coordinate within the case\'s tolerance, '
          'variable_points, rows; informational: residual_inf (converged means <= tolerance * max(1, group diagonal)), '
          'exit, walks, rejected_steps, iterations',
      'nearest': 'golden cases only, where known: the exact nearest feasible point (informational; the projector may stop a little short)',
    },
    'cases': cases,
  };
}

/// The file's text: one case per block, one frame per line (the file stays reviewable).
String encodeSketchVectors(Map<String, dynamic> doc) {
  final b = StringBuffer('{\n');
  final top = doc.keys.where((k) => k != 'cases').toList();
  for (final k in top) {
    b.writeln(' ${jsonEncode(k)}: ${const JsonEncoder.withIndent('  ').convert(doc[k]).replaceAll('\n', '\n ')},');
  }
  b.writeln(' "cases": [');
  final cases = doc['cases'] as List;
  for (var i = 0; i < cases.length; i++) {
    final c = cases[i] as Map<String, dynamic>;
    b.writeln('  {');
    final keys = c.keys.where((k) => k != 'frames').toList();
    for (final k in keys) {
      b.writeln('   ${jsonEncode(k)}: ${jsonEncode(c[k])},');
    }
    b.writeln('   "frames": [');
    final frames = c['frames'] as List;
    for (var f = 0; f < frames.length; f++) {
      b.writeln('    ${jsonEncode(frames[f])}${f == frames.length - 1 ? '' : ','}');
    }
    b.writeln('   ]');
    b.writeln('  }${i == cases.length - 1 ? '' : ','}');
  }
  b.writeln(' ]');
  b.writeln('}');
  return b.toString();
}

/// Differences between two documents: any structural or non-numeric difference, or a number more than [tolerance] apart.
List<String> sketchVectorDifferences(dynamic a, dynamic b, double tolerance, [String path = '']) {
  if (a is num && b is num) {
    return (a - b).abs() > tolerance ? ['$path: $a vs $b'] : const [];
  }
  if (a is Map && b is Map) {
    final out = <String>[];
    for (final k in {...a.keys, ...b.keys}) {
      if (!a.containsKey(k) || !b.containsKey(k)) {
        out.add('$path.$k: only in ${a.containsKey(k) ? 'the first' : 'the second'}');
      } else {
        out.addAll(sketchVectorDifferences(a[k], b[k], tolerance, '$path.$k'));
      }
    }
    return out;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return ['$path: length ${a.length} vs ${b.length}'];
    return [for (var i = 0; i < a.length; i++) ...sketchVectorDifferences(a[i], b[i], tolerance, '$path[$i]')];
  }
  return a == b ? const [] : ['$path: $a vs $b'];
}
