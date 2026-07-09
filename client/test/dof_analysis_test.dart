import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/dof_analysis.dart';

/// Pure-Dart tests for dof_analysis.dart's union-find DOF-counting
/// algorithm - no Flutter widget dependencies, mirrors
/// clip_distance_test.dart's own pure-logic style. Point ids below are
/// short human-readable strings (not real UUIDs) purely for test
/// readability - the algorithm treats them as opaque.

SketchRigidity _analyze({
  required Iterable<String> pointIds,
  String? originPointId = 'origin',
  Map<String, String> lineStartPointId = const {},
  Map<String, String> lineEndPointId = const {},
  required Iterable<ConstraintDto> constraints,
}) =>
    SketchRigidity.analyze(
      pointIds: pointIds,
      originPointId: originPointId,
      lineStartPointId: lineStartPointId,
      lineEndPointId: lineEndPointId,
      constraints: constraints,
    );

void main() {
  group('SketchRigidity.empty', () {
    test('every query returns false', () {
      const rigidity = SketchRigidity.empty();
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
      expect(rigidity.isPointOverConstrained('a'), isFalse);
      expect(rigidity.isSegmentFullyConstrained('a', 'b'), isFalse);
      expect(rigidity.isSegmentOverConstrained('a', 'b'), isFalse);
    });
  });

  group('a standalone Point with no Constraint at all', () {
    test('is neither fully nor over constrained', () {
      final rigidity = _analyze(pointIds: ['origin', 'a'], constraints: const []);
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
      expect(rigidity.isPointOverConstrained('a'), isFalse);
    });
  });

  group('grounding requires a chain back to the origin', () {
    test('a rigid pair of Points not connected to the origin is not fully constrained', () {
      // Two Points pinned to each other by two independent 1-DOF
      // constraints (Horizontal + Distance) removes both of the second
      // Point's degrees of freedom relative to the first - but neither is
      // tied to the origin, so the pair can still translate/rotate as a
      // whole (a rigid-but-floating shape), and must not read as green.
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b'],
        constraints: const [
          HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'a', pointBId: 'b'),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b', distance: 10.0),
        ],
      );
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
      expect(rigidity.isPointFullyConstrained('b'), isFalse);
    });

    test('the same pair IS fully constrained once tied to the origin', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b'],
        constraints: const [
          HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'origin', pointBId: 'a'),
          DistanceConstraintDto(id: 'c2', pointAId: 'origin', pointBId: 'a', distance: 5.0),
          HorizontalConstraintDto(id: 'c3', lineId: 'l2', pointAId: 'a', pointBId: 'b'),
          DistanceConstraintDto(id: 'c4', pointAId: 'a', pointBId: 'b', distance: 10.0),
        ],
      );
      expect(rigidity.isPointFullyConstrained('a'), isTrue);
      expect(rigidity.isPointFullyConstrained('b'), isTrue);
      expect(rigidity.isSegmentFullyConstrained('a', 'b'), isTrue);
    });
  });

  group('a single 1-DOF constraint to the origin is not enough', () {
    test('leaves one remaining degree of freedom, not fully constrained', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a'],
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
        ],
      );
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
      expect(rigidity.isPointOverConstrained('a'), isFalse);
    });
  });

  group('coincident with the origin removes both degrees of freedom at once', () {
    test('a Point Coincident with the origin is fully constrained by itself', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a'],
        constraints: const [
          CoincidentConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a'),
        ],
      );
      expect(rigidity.isPointFullyConstrained('a'), isTrue);
    });
  });

  group('over-constrained detection', () {
    test('a third redundant constraint on an already-fully-constrained Point reports over-constrained', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a'],
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
          HorizontalConstraintDto(id: 'c2', lineId: 'l1', pointAId: 'origin', pointBId: 'a'),
          // Redundant: a already has 0 remaining DOF after c1+c2.
          VerticalConstraintDto(id: 'c3', lineId: 'l2', pointAId: 'origin', pointBId: 'a'),
        ],
      );
      expect(rigidity.isPointOverConstrained('a'), isTrue);
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
    });

    test('isSegmentOverConstrained is true if either endpoint is implicated, even if the other is untouched', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b'],
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
          HorizontalConstraintDto(id: 'c2', lineId: 'l1', pointAId: 'origin', pointBId: 'a'),
          VerticalConstraintDto(id: 'c3', lineId: 'l2', pointAId: 'origin', pointBId: 'a'),
        ],
      );
      // b is untouched by any Constraint at all (no union ever ran on it),
      // but isSegmentOverConstrained checks each endpoint independently
      // (an OR, not "same cluster") - a alone being over-constrained is
      // enough to flag the pair.
      expect(rigidity.isPointOverConstrained('b'), isFalse);
      expect(rigidity.isSegmentOverConstrained('a', 'b'), isTrue);
      expect(rigidity.isSegmentOverConstrained('a', 'origin'), isTrue);
    });
  });

  group('line-pair constraint types resolve via the Line endpoint maps', () {
    test('Parallel between two Lines unions all four endpoints into one cluster', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b', 'c', 'd'],
        lineStartPointId: const {'l1': 'a', 'l2': 'c'},
        lineEndPointId: const {'l1': 'b', 'l2': 'd'},
        constraints: const [
          ParallelConstraintDto(id: 'c1', line1Id: 'l1', line2Id: 'l2'),
        ],
      );
      // Parallel alone (1 DOF) can't fully constrain anything by itself,
      // but it must not throw or silently ignore the Lines - a weaker
      // smoke check that resolution via the endpoint maps didn't crash
      // and didn't spuriously mark anything fully/over constrained.
      for (final id in ['a', 'b', 'c', 'd']) {
        expect(rigidity.isPointFullyConstrained(id), isFalse);
        expect(rigidity.isPointOverConstrained(id), isFalse);
      }
    });

    test('AtMidpoint removes both degrees of freedom of the midpoint Point', () {
      // origin --- a --- b, with m pinned to a's midpoint and a/b each
      // pinned relative to the origin.
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b', 'm'],
        lineStartPointId: const {'l1': 'a'},
        lineEndPointId: const {'l1': 'b'},
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
          HorizontalConstraintDto(id: 'c2', lineId: 'l0', pointAId: 'origin', pointBId: 'a'),
          DistanceConstraintDto(id: 'c3', pointAId: 'a', pointBId: 'b', distance: 10.0),
          HorizontalConstraintDto(id: 'c4', lineId: 'l0b', pointAId: 'a', pointBId: 'b'),
          AtMidpointConstraintDto(id: 'c5', pointId: 'm', lineId: 'l1'),
        ],
      );
      expect(rigidity.isPointFullyConstrained('a'), isTrue);
      expect(rigidity.isPointFullyConstrained('b'), isTrue);
      expect(rigidity.isPointFullyConstrained('m'), isTrue);
    });
  });

  group('isPointGrounded - exact topological connectivity to the origin, independent of DOF counting', () {
    test('a rigid pair not connected to the origin is not grounded, even though DOF is not what '
        'gates this check', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b'],
        constraints: const [
          HorizontalConstraintDto(id: 'c1', lineId: 'l1', pointAId: 'a', pointBId: 'b'),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b', distance: 10.0),
        ],
      );
      expect(rigidity.isPointGrounded('a'), isFalse);
      expect(rigidity.isPointGrounded('b'), isFalse);
    });

    test('a single Constraint touching the origin grounds the whole cluster, even with 1 '
        'remaining degree of freedom', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a'],
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
        ],
      );
      // Not fully constrained (1 DOF remains - see the earlier group of
      // the same name), but grounded is a strictly weaker, purely
      // topological claim: is there *any* chain back to the origin.
      expect(rigidity.isPointFullyConstrained('a'), isFalse);
      expect(rigidity.isPointGrounded('a'), isTrue);
    });

    test('grounding is transitive through an unrelated intermediate Point', () {
      final rigidity = _analyze(
        pointIds: ['origin', 'a', 'b'],
        constraints: const [
          DistanceConstraintDto(id: 'c1', pointAId: 'origin', pointBId: 'a', distance: 5.0),
          DistanceConstraintDto(id: 'c2', pointAId: 'a', pointBId: 'b', distance: 3.0),
        ],
      );
      expect(rigidity.isPointGrounded('b'), isTrue);
    });

    test('a Point untouched by any Constraint at all is not grounded', () {
      final rigidity = _analyze(pointIds: ['origin', 'a'], constraints: const []);
      expect(rigidity.isPointGrounded('a'), isFalse);
    });
  });

  group('dofCostByConstraintType', () {
    test('matches the documented per-type equation counts', () {
      expect(dofCostByConstraintType['distance'], 1);
      expect(dofCostByConstraintType['vertical'], 1);
      expect(dofCostByConstraintType['horizontal'], 1);
      expect(dofCostByConstraintType['angle'], 1);
      expect(dofCostByConstraintType['coincident'], 2);
      expect(dofCostByConstraintType['parallel'], 1);
      expect(dofCostByConstraintType['perpendicular'], 1);
      expect(dofCostByConstraintType['equal_length'], 1);
      expect(dofCostByConstraintType['line_distance'], 1);
      expect(dofCostByConstraintType['collinear'], 2);
      expect(dofCostByConstraintType['point_line_distance'], 1);
      expect(dofCostByConstraintType['at_midpoint'], 2);
    });
  });
}
