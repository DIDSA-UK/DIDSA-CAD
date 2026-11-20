// The rigidity analysis's cases (docs/sketch-rigidity-spec.md): every input of test/dof_analysis_test.dart, with the
// assertions that test makes on it, plus a few whole-entity scenes (what the flat app's canvas colours per line / circle /
// arc). Exported to docs/sketch-rigidity-vectors.json by test/sketch_rigidity_vectors_test.dart
// (tools/sketch_vectors/export_rigidity.sh [--check]).
import 'package:didsa_cad_client/api/sketch_api_client.dart';

/// One query the original test asserts: `fully` / `over` / `grounded` / `pinned` (one point), `segment_fully` /
/// `segment_over` (two points), `any_grounded` (none).
typedef RigidityCheck = ({String query, List<String> args, bool want});

class RigidityCase {
  final String id;
  final String description;
  final List<String> pointIds;
  final Set<String> fixed;
  final Map<String, (String, String)> lines;
  final List<ConstraintDto> constraints;
  final bool trustConvergedSolve;
  final List<RigidityCheck> checks;

  /// Entities to colour (scenes only): kind -> id -> defining points (line: start, end; circle: centre, radius point;
  /// arc: centre, start, end).
  final Map<String, Map<String, List<String>>> entities;
  const RigidityCase(
    this.id,
    this.description, {
    required this.pointIds,
    this.fixed = const {'origin'},
    this.lines = const {},
    required this.constraints,
    this.trustConvergedSolve = false,
    this.checks = const [],
    this.entities = const {},
  });
}

RigidityCheck _c(String query, List<String> args, bool want) => (query: query, args: args, want: want);

List<RigidityCase> rigidityCases() {
  const lostPair = [
    HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'a', pointBId: 'b'),
    DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b', distance: 10.0),
  ];
  const tripleOnA = [
    DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
    HorizontalConstraintDto(id: 'c2', lineId: 'l1', pointAId: 'origin', pointBId: 'a'),
    VerticalConstraintDto(id: 'c3', lineId: 'l2', pointAId: 'origin', pointBId: 'a'),
  ];
  const oneDistance = [DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0)];
  final hexLines = <String, (String, String)>{
    for (var i = 0; i < 6; i++) ...{'edge$i': ('v$i', 'v${(i + 1) % 6}'), 'radial$i': ('center', 'v$i')},
  };
  const hexPoints = ['origin', 'center', 'v0', 'v1', 'v2', 'v3', 'v4', 'v5'];
  final hexBase = <ConstraintDto>[
    const CoincidentConstraintDto(id: 'coincident', pointAId: 'origin', pointBId: 'center'),
    const DistanceConstraintDto(id: 'radius', pointAId: 'center', pointBId: 'v0', distance: 10.0),
    for (var i = 1; i < 6; i++)
      EqualRadiusConstraintDto(
          id: 'equal_radius_$i',
          center1PointId: 'center',
          radius1PointId: 'v0',
          center2PointId: 'center',
          radius2PointId: 'v$i'),
    for (var i = 0; i < 5; i++)
      AngleConstraintDto(id: 'angle_$i', line1Id: 'radial$i', line2Id: 'radial${i + 1}', angleDegrees: 60.0),
  ];
  const hexHorizontal = HorizontalConstraintDto(id: 'horizontal', lineId: 'edge0', pointAId: 'v0', pointBId: 'v1');
  const hexAcrossFlats =
      LineDistanceConstraintDto(id: 'across_flats', line1Id: 'edge0', line2Id: 'edge3', distance: 17.32);
  final hexNoneOver = [
    for (final id in hexPoints.skip(1)) _c('over', [id], false)
  ];

  // A rectangle a-b-c-d (lines l0..l3) with H/V sides and its corner a on the origin: the scenes' common part.
  const rectLines = {'l0': ('a', 'b'), 'l1': ('b', 'c'), 'l2': ('c', 'd'), 'l3': ('d', 'a')};
  const rect = [
    CoincidentConstraintDto(id: 'on_origin', pointAId: 'origin', pointBId: 'a'),
    HorizontalConstraintDto(id: 'h0', lineId: 'l0', pointAId: 'a', pointBId: 'b'),
    VerticalConstraintDto(id: 'v1', lineId: 'l1', pointAId: 'b', pointBId: 'c'),
    HorizontalConstraintDto(id: 'h2', lineId: 'l2', pointAId: 'c', pointBId: 'd'),
    VerticalConstraintDto(id: 'v3', lineId: 'l3', pointAId: 'd', pointBId: 'a'),
    DistanceConstraintDto(id: 'width', pointAId: 'a', pointBId: 'b', distance: 40, orientation: 'horizontal'),
  ];
  const height =
      DistanceConstraintDto(id: 'height', pointAId: 'b', pointBId: 'c', distance: 20, orientation: 'vertical');
  final rectEntities = {
    'line': {
      for (final e in rectLines.entries) e.key: [e.value.$1, e.value.$2]
    },
  };

  return [
    // ---- dof_analysis_test.dart, in its order (group / test names shortened into the ids)
    RigidityCase('standalone-point', 'a Point with no Constraint at all is neither fully nor over constrained',
        pointIds: [
          'origin',
          'a'
        ],
        constraints: const [],
        checks: [
          _c('fully', ['a'], false),
          _c('over', ['a'], false)
        ]),
    RigidityCase('floating-rigid-pair', 'a rigid pair not tied to the origin is not fully constrained',
        pointIds: ['origin', 'a', 'b'],
        constraints: lostPair,
        checks: [
          _c('fully', ['a'], false),
          _c('fully', ['b'], false)
        ]),
    RigidityCase('grounded-rigid-pair', 'the same pair IS fully constrained once tied to the origin', pointIds: [
      'origin',
      'a',
      'b'
    ], constraints: const [
      HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'origin', pointBId: 'a'),
      DistanceConstraintDto(id: 'c2', pointAId: 'origin', pointBId: 'a', distance: 5.0),
      HorizontalConstraintDto(id: 'c3', lineId: 'l2', pointAId: 'a', pointBId: 'b'),
      DistanceConstraintDto(id: 'c4', pointAId: 'a', pointBId: 'b', distance: 10.0),
    ], checks: [
      _c('fully', ['a'], true),
      _c('fully', ['b'], true),
      _c('segment_fully', ['a', 'b'], true)
    ]),
    RigidityCase('one-dof-to-origin', 'a single 1-DOF constraint to the origin leaves one degree of freedom',
        pointIds: ['origin', 'a'],
        constraints: oneDistance,
        checks: [
          _c('fully', ['a'], false),
          _c('over', ['a'], false)
        ]),
    RigidityCase('coincident-with-origin', 'a Point Coincident with the origin is fully constrained by itself',
        pointIds: [
          'origin',
          'a'
        ],
        constraints: const [
          CoincidentConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a')
        ],
        checks: [
          _c('fully', ['a'], true)
        ]),
    RigidityCase(
        'redundant-third', 'a third redundant constraint on a fully constrained Point reports over-constrained',
        pointIds: ['origin', 'a'],
        constraints: tripleOnA,
        checks: [
          _c('over', ['a'], true),
          _c('fully', ['a'], false)
        ]),
    RigidityCase('segment-over-either-end', 'isSegmentOverConstrained is true if either endpoint is implicated',
        pointIds: ['origin', 'a', 'b'],
        constraints: tripleOnA,
        checks: [
          _c('over', ['b'], false),
          _c('segment_over', ['a', 'b'], true),
          _c('segment_over', ['a', 'origin'], true)
        ]),
    RigidityCase(
        'trust-converged', 'trustConvergedSolve suppresses a redundant-but-consistent over-constrained verdict',
        pointIds: ['origin', 'a'],
        constraints: tripleOnA,
        trustConvergedSolve: true,
        checks: [
          _c('over', ['a'], false),
          _c('fully', ['a'], false)
        ]),
    RigidityCase(
        'hexagon-horizontal-and-across-flats',
        'a polygon\'s redundant chain plus a horizontal edge AND an across-flats '
            'dimension reads as over-constrained by counting alone',
        pointIds: hexPoints,
        lines: hexLines,
        constraints: [
          ...hexBase,
          hexHorizontal,
          hexAcrossFlats
        ],
        checks: [
          _c('over', ['v0'], true)
        ]),
    RigidityCase(
        'hexagon-horizontal-and-across-flats-trusted', 'the same, once told the backend converged: nothing is over',
        pointIds: hexPoints,
        lines: hexLines,
        constraints: [...hexBase, hexHorizontal, hexAcrossFlats],
        trustConvergedSolve: true,
        checks: hexNoneOver),
    RigidityCase('hexagon-horizontal-only', 'the polygon chain with only the horizontal edge is not over-constrained',
        pointIds: hexPoints,
        lines: hexLines,
        constraints: [
          ...hexBase,
          hexHorizontal
        ],
        checks: [
          _c('over', ['v0'], false)
        ]),
    RigidityCase(
        'hexagon-across-flats-only', 'the polygon chain with only the across-flats dimension is not over-constrained',
        pointIds: hexPoints,
        lines: hexLines,
        constraints: [
          ...hexBase,
          hexAcrossFlats
        ],
        checks: [
          _c('over', ['v0'], false)
        ]),
    RigidityCase('parallel-unions-four', 'Parallel between two Lines unions all four endpoints into one cluster',
        pointIds: [
          'origin',
          'a',
          'b',
          'c',
          'd'
        ],
        lines: const {
          'l1': ('a', 'b'),
          'l2': ('c', 'd')
        },
        constraints: const [
          ParallelConstraintDto(id: 'c1', line1Id: 'l1', line2Id: 'l2')
        ],
        checks: [
          for (final id in ['a', 'b', 'c', 'd']) ...[
            _c('fully', [id], false),
            _c('over', [id], false)
          ],
        ]),
    RigidityCase('at-midpoint', 'AtMidpoint removes both degrees of freedom of the midpoint Point', pointIds: [
      'origin',
      'a',
      'b',
      'm'
    ], lines: const {
      'l1': ('a', 'b')
    }, constraints: const [
      DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
      HorizontalConstraintDto(id: 'c2', lineId: 'l0', pointAId: 'origin', pointBId: 'a'),
      DistanceConstraintDto(id: 'c3', pointAId: 'a', pointBId: 'b', distance: 10.0),
      HorizontalConstraintDto(id: 'c4', lineId: 'l0b', pointAId: 'a', pointBId: 'b'),
      AtMidpointConstraintDto(id: 'c5', pointId: 'm', lineId: 'l1'),
    ], checks: [
      _c('fully', ['a'], true),
      _c('fully', ['b'], true),
      _c('fully', ['m'], true)
    ]),
    RigidityCase(
        'pinned-centre', 'a Point Coincident with the origin is pinned even though its cluster still has freedom',
        pointIds: [
          'origin',
          'centre',
          'start'
        ],
        constraints: const [
          CoincidentConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'centre'),
          DistanceConstraintDto(id: 'c2', pointAId: 'centre', pointBId: 'start', distance: 5.0),
        ],
        checks: [
          _c('fully', ['centre'], false),
          _c('pinned', ['centre'], true),
          _c('pinned', ['start'], false)
        ]),
    RigidityCase('not-pinned-by-distance', 'a Point reached only through a 1-DOF constraint type is not pinned',
        pointIds: ['origin', 'a'],
        constraints: oneDistance,
        checks: [
          _c('pinned', ['a'], false)
        ]),
    RigidityCase('concentric-pins', 'Concentric pins the same way Coincident does', pointIds: [
      'origin',
      'centre'
    ], constraints: const [
      ConcentricConstraintDto(
          id: 'c1', entity1Id: 'e1', entity2Id: 'e2', center1PointId: 'origin', center2PointId: 'centre'),
    ], checks: [
      _c('pinned', ['centre'], true)
    ]),
    RigidityCase('pinned-chain', 'pinning is transitive through a chain of Coincident Points', pointIds: [
      'origin',
      'a',
      'b'
    ], constraints: const [
      CoincidentConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a'),
      CoincidentConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b'),
    ], checks: [
      _c('pinned', ['b'], true)
    ]),
    RigidityCase('floating-pair-not-grounded', 'a rigid pair not connected to the origin is not grounded',
        pointIds: ['origin', 'a', 'b'],
        constraints: lostPair,
        checks: [
          _c('grounded', ['a'], false),
          _c('grounded', ['b'], false)
        ]),
    RigidityCase('one-constraint-grounds', 'a single Constraint touching the origin grounds the whole cluster',
        pointIds: ['origin', 'a'],
        constraints: oneDistance,
        checks: [
          _c('fully', ['a'], false),
          _c('grounded', ['a'], true)
        ]),
    RigidityCase('grounding-transitive', 'grounding is transitive through an intermediate Point', pointIds: [
      'origin',
      'a',
      'b'
    ], constraints: const [
      DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
      DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b', distance: 3.0),
    ], checks: [
      _c('grounded', ['b'], true)
    ]),
    RigidityCase('untouched-not-grounded', 'a Point untouched by any Constraint is not grounded', pointIds: [
      'origin',
      'a'
    ], constraints: const [], checks: [
      _c('grounded', ['a'], false)
    ]),
    RigidityCase('nothing-grounded', 'isAnyPointGrounded is false when nothing is grounded',
        pointIds: ['origin', 'a', 'b'],
        constraints: const [HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'a', pointBId: 'b')],
        checks: [_c('any_grounded', [], false)]),
    RigidityCase('any-grounded', 'isAnyPointGrounded is true as soon as any single Point is grounded', pointIds: [
      'origin',
      'a',
      'b',
      'c'
    ], constraints: const [
      HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'b', pointBId: 'c'),
      DistanceConstraintDto(id: 'c2', pointAId: 'origin', pointBId: 'a', distance: 5.0),
    ], checks: [
      _c('grounded', ['b'], false),
      _c('any_grounded', [], true)
    ]),
    RigidityCase('fixed-anchor-grounds', 'any fixed Point grounds, not only the origin', pointIds: [
      'origin',
      'anchor',
      'a'
    ], fixed: const {
      'origin',
      'anchor'
    }, constraints: const [
      DistanceConstraintDto(id: 'c1', pointAId: 'anchor', pointBId: 'a', distance: 5.0)
    ], checks: [
      _c('grounded', ['a'], true),
      _c('any_grounded', [], true)
    ]),
    RigidityCase('no-fixed-grounds-nothing', 'an empty fixed set grounds nothing at all',
        pointIds: ['a', 'b'],
        fixed: const {},
        constraints: const [DistanceConstraintDto(id: 'c1', pointAId: 'a', pointBId: 'b', distance: 5.0)],
        checks: [_c('any_grounded', [], false)]),
    // ---- whole-entity scenes (F6): what the per-entity colours read
    RigidityCase(
        'scene-rectangle-missing-height',
        'a rectangle on the origin with its width but no height: one cluster with '
            'one degree of freedom left, so no side is fully constrained',
        pointIds: ['origin', 'a', 'b', 'c', 'd'],
        lines: rectLines,
        constraints: rect,
        entities: rectEntities),
    RigidityCase('scene-rectangle-dimensioned', 'the same rectangle with its height: every side fully constrained',
        pointIds: ['origin', 'a', 'b', 'c', 'd'],
        lines: rectLines,
        constraints: [...rect, height],
        entities: rectEntities),
    RigidityCase(
        'scene-rectangle-and-free-line',
        'the dimensioned rectangle plus a horizontal line on its own: the rectangle\'s '
            'sides are fully constrained, the free line is not (per-entity, not whole-sketch)',
        pointIds: [
          'origin',
          'a',
          'b',
          'c',
          'd',
          'p',
          'q'
        ],
        lines: {
          ...rectLines,
          'free': ('p', 'q')
        },
        constraints: [
          ...rect,
          height,
          const HorizontalConstraintDto(id: 'hf', lineId: 'free', pointAId: 'p', pointBId: 'q')
        ],
        entities: {
          'line': {
            ...rectEntities['line']!,
            'free': ['p', 'q']
          },
        }),
    RigidityCase(
        'scene-rectangle-over-dimensioned',
        'the dimensioned rectangle with a second height on the other side: every '
            'side over-constrained by counting (the backend would converge: with trustConvergedSolve nothing is red)',
        pointIds: ['origin', 'a', 'b', 'c', 'd'],
        lines: rectLines,
        constraints: [
          ...rect,
          height,
          const DistanceConstraintDto(
              id: 'height2', pointAId: 'a', pointBId: 'd', distance: 20, orientation: 'vertical'),
        ],
        entities: rectEntities),
    RigidityCase(
        'scene-circle-provisional-radius',
        'a circle on the origin whose radius is still provisional: the provisional '
            'distance is skipped, so the radius point keeps both degrees of freedom',
        pointIds: [
          'origin',
          'centre',
          'r'
        ],
        constraints: const [
          CoincidentConstraintDto(id: 'on_origin', pointAId: 'origin', pointBId: 'centre'),
          DistanceConstraintDto(id: 'radius', pointAId: 'centre', pointBId: 'r', distance: 10, provisional: true),
        ],
        entities: const {
          'circle': {
            'k': ['centre', 'r'],
          },
        }),
    RigidityCase(
        'scene-circle-confirmed',
        'the same circle with the radius confirmed and the radius point held horizontal: '
            'fully constrained',
        pointIds: [
          'origin',
          'centre',
          'r'
        ],
        constraints: const [
          CoincidentConstraintDto(id: 'on_origin', pointAId: 'origin', pointBId: 'centre'),
          DistanceConstraintDto(id: 'radius', pointAId: 'centre', pointBId: 'r', distance: 10),
          HorizontalConstraintDto(id: 'hr', lineId: 'none', pointAId: 'centre', pointBId: 'r'),
        ],
        entities: const {
          'circle': {
            'k': ['centre', 'r'],
          },
        }),
    RigidityCase(
        'scene-arc-one-end-free',
        'an arc on the origin with its start fixed by a radius and a horizontal, its end only '
            'on the circle (equal radius): the end keeps one degree of freedom, so the arc is not fully constrained (both radii must be)',
        pointIds: [
          'origin',
          'centre',
          's',
          'e'
        ],
        constraints: const [
          CoincidentConstraintDto(id: 'on_origin', pointAId: 'origin', pointBId: 'centre'),
          DistanceConstraintDto(id: 'radius', pointAId: 'centre', pointBId: 's', distance: 10),
          HorizontalConstraintDto(id: 'hs', lineId: 'none', pointAId: 'centre', pointBId: 's'),
          EqualRadiusConstraintDto(
              id: 'eq', center1PointId: 'centre', radius1PointId: 's', center2PointId: 'centre', radius2PointId: 'e'),
        ],
        entities: const {
          'arc': {
            'k': ['centre', 's', 'e'],
          },
        }),
    RigidityCase(
        'scene-part-d-and-fix',
        'part D types count one each; a Fix constraint counts nothing (the caller passes its '
            'point as fixed instead); a spline tangency counts one over seven points',
        pointIds: [
          'origin',
          'a',
          'b',
          'c',
          'r',
          'f',
          's0',
          's1',
          's2',
          's3',
          's4',
          's5',
          's6',
          's7'
        ],
        fixed: const {
          'origin',
          'f'
        },
        constraints: const [
          CoincidentConstraintDto(id: 'on_origin', pointAId: 'origin', pointBId: 'c'),
          PointCircleDistanceConstraintDto(
              id: 'pcd',
              pointId: 'a',
              circleOrArcId: 'k',
              centerPointId: 'c',
              radiusPointId: 'r',
              distance: 5,
              side: 'min'),
          PointAngleConstraintDto(id: 'pa', vertexPointId: 'c', point1Id: 'a', point2Id: 'b', angleDegrees: 30),
          FixedConstraintDto(id: 'fix', pointIds: ['f']),
          SplineTangentConstraintDto(
            id: 'st',
            splineId: 'sp',
            segmentAP0: 's0',
            segmentAP1: 's1',
            segmentAP2: 's2',
            segmentAP3: 's3',
            segmentBP0: 's3',
            segmentBP1: 's5',
            segmentBP2: 's6',
            segmentBP3: 's7',
          ),
        ]),
  ];
}
