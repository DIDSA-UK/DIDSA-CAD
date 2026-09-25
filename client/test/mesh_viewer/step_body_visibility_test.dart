// Pure-Dart tests for the STEP multi-body model - no FFI, no
// flutter_scene/flutter_gpu (this repo has no real GPU context available
// under `flutter test`) - see mesh_viewer_render.dart's own top-of-file doc
// comment for why that split matters, and step_loader.dart's for why most
// of *that* file (unlike mesh_data.dart) genuinely needs dart:ffi. Covers
// MeshBody/MultiBodyMesh invert/reset, per-body decimation stride
// invariants (computeBodyDecimationStrides), and the body-aware
// batch-boundary helper (computeBodyAwareBatchRanges), extracted
// specifically so it's testable without a GPU context.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/mesh_viewer/mesh_data.dart';
import 'package:didsa_cad_client/mesh_viewer/mesh_viewer_render.dart';
import 'package:didsa_cad_client/mesh_viewer/step_loader.dart';

MeshBody _body(int id, {bool visible = true}) => MeshBody(
      id: id,
      name: 'Body ${id + 1}',
      startTriangle: id * 10,
      triangleCount: 10,
      bbox: (min: vm.Vector3.zero(), max: vm.Vector3.all(1)),
      visible: visible,
    );

void main() {
  group('MultiBodyMesh visibility', () {
    test('invertVisibility flips every body', () {
      final bodies = [_body(0), _body(1, visible: false), _body(2)];
      final multi = MultiBodyMesh(mesh: _emptyMesh(), bodies: bodies);

      multi.invertVisibility();

      expect(bodies[0].visible, isFalse);
      expect(bodies[1].visible, isTrue);
      expect(bodies[2].visible, isFalse);
    });

    test('invertVisibility twice is a no-op', () {
      final bodies = [_body(0), _body(1, visible: false)];
      final multi = MultiBodyMesh(mesh: _emptyMesh(), bodies: bodies);

      multi.invertVisibility();
      multi.invertVisibility();

      expect(bodies[0].visible, isTrue);
      expect(bodies[1].visible, isFalse);
    });

    test('resetVisibility sets every body visible regardless of starting state', () {
      final bodies = [_body(0, visible: false), _body(1, visible: false), _body(2)];
      final multi = MultiBodyMesh(mesh: _emptyMesh(), bodies: bodies);

      multi.resetVisibility();

      expect(bodies.every((b) => b.visible), isTrue);
    });
  });

  group('computeBodyDecimationStrides', () {
    test('returns all-1 strides when under budget', () {
      final strides = computeBodyDecimationStrides([100, 200, 50], 1000);
      expect(strides, [1, 1, 1]);
    });

    test('returns all-1 strides when maxTriangles is null', () {
      final strides = computeBodyDecimationStrides([100, 200, 50], null);
      expect(strides, [1, 1, 1]);
    });

    test('decimates proportionally to each body\'s own share when over budget', () {
      // Body 0 has 90% of the total triangles, body 1 has 10% - the budget
      // should be split the same way, not evenly per-body.
      final counts = [9000, 1000];
      final strides = computeBodyDecimationStrides(counts, 1000);

      final kept0 = (counts[0] / strides[0]).ceil();
      final kept1 = (counts[1] / strides[1]).ceil();
      final totalKept = kept0 + kept1;

      expect(totalKept, lessThanOrEqualTo(1000 + counts.length)); // rounding slack, still bounded
      // Body 0's kept share should be roughly 9x body 1's (matching its 9x
      // larger source count), not equal.
      expect(kept0, greaterThan(kept1 * 5));
    });

    test('never produces a stride that could merge or skip an entire body', () {
      final strides = computeBodyDecimationStrides([1, 5000], 100);
      // A body with only 1 triangle must always keep stride 1 (a stride
      // that could ever cause "0 triangles kept" would effectively delete
      // that body's own contiguous range from the mesh).
      expect(strides[0], 1);
      expect(strides[1], greaterThan(1));
    });

    test('ignores zero-triangle (failed-tessellation) bodies without dividing by zero', () {
      final strides = computeBodyDecimationStrides([0, 5000, 0], 100);
      expect(strides[0], 1);
      expect(strides[2], 1);
      expect(strides[1], greaterThan(1));
    });

    test('empty input returns empty output', () {
      expect(computeBodyDecimationStrides([], 100), isEmpty);
    });
  });

  group('computeBodyAwareBatchRanges', () {
    test('keeps a small body as a single range', () {
      final ranges = computeBodyAwareBatchRanges(
        [(bodyId: 0, startTriangle: 0, triangleCount: 10)],
        maxTrianglesPerBatch: 100,
      );
      expect(ranges, hasLength(1));
      expect(ranges.single.bodyId, 0);
      expect(ranges.single.startTriangle, 0);
      expect(ranges.single.triangleCount, 10);
    });

    test('splits a body larger than maxTrianglesPerBatch into multiple ranges, all sharing its bodyId', () {
      final ranges = computeBodyAwareBatchRanges(
        [(bodyId: 5, startTriangle: 100, triangleCount: 25)],
        maxTrianglesPerBatch: 10,
      );
      expect(ranges, hasLength(3)); // 10 + 10 + 5
      expect(ranges.every((r) => r.bodyId == 5), isTrue);
      expect(ranges[0].startTriangle, 100);
      expect(ranges[0].triangleCount, 10);
      expect(ranges[1].startTriangle, 110);
      expect(ranges[1].triangleCount, 10);
      expect(ranges[2].startTriangle, 120);
      expect(ranges[2].triangleCount, 5);
    });

    test('never merges two different bodies into one range even when both are small', () {
      final ranges = computeBodyAwareBatchRanges(
        [
          (bodyId: 0, startTriangle: 0, triangleCount: 5),
          (bodyId: 1, startTriangle: 5, triangleCount: 5),
        ],
        maxTrianglesPerBatch: 100,
      );
      expect(ranges, hasLength(2));
      expect(ranges[0].bodyId, 0);
      expect(ranges[1].bodyId, 1);
    });

    test('a zero-triangle body contributes no ranges', () {
      final ranges = computeBodyAwareBatchRanges(
        [(bodyId: 0, startTriangle: 0, triangleCount: 0)],
        maxTrianglesPerBatch: 100,
      );
      expect(ranges, isEmpty);
    });
  });

  group('StepLoadAccumulator', () {
    test('assigns startTriangle/triangleCount as bodies stream in', () {
      final accumulator = StepLoadAccumulator();
      accumulator.addBodies([_body(0), _body(1)]);

      final positionsA = _positions(2); // 2 triangles
      final normalsA = _positions(2);
      accumulator.addBodyMesh(0, positionsA, normalsA);

      final positionsB = _positions(3); // 3 triangles
      final normalsB = _positions(3);
      accumulator.addBodyMesh(1, positionsB, normalsB);

      final multi = accumulator.toMultiBodyMesh();
      expect(multi.bodies[0].startTriangle, 0);
      expect(multi.bodies[0].triangleCount, 2);
      expect(multi.bodies[1].startTriangle, 2);
      expect(multi.bodies[1].triangleCount, 3);
      expect(multi.mesh.triangleCount, 5);
    });
  });
}

DecodedMesh _emptyMesh() => DecodedMesh(
      positions: Float32List(0),
      normals: Float32List(0),
      uvs: Float32List(0),
    );

Float32List _positions(int triangleCount) => Float32List(triangleCount * 9);
