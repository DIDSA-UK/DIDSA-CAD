import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/mesh_geometry.dart';

void main() {
  test('meshBuffersFromMesh packs position/normal/uv/color into 12 floats per vertex', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh);

    expect(buffers.vertexCount, 3);
    expect(buffers.vertexData.length, 3 * 12);

    final vertex1 = buffers.vertexData.sublist(12, 24);
    expect(vertex1, [
      1, 0, 0, // position
      0, 0, 1, // normal
      0, 0, // uv
      1, 1, 1, 1, // color
    ]);
  });

  test('meshBuffersFromMesh writes a flat 16-bit index buffer from triangleIndices', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
        [1, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
        [2, 1, 3],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh);
    final indices = Uint16List.sublistView(buffers.indexData);

    expect(indices, [0, 1, 2, 2, 1, 3]);
  });

  test(
      'meshBuffersFromMesh doubleSidedWinding: false (the default) is byte-for-byte unchanged - '
      'a regression guard for the face-culling fix below', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final defaulted = meshBuffersFromMesh(mesh);
    final explicit = meshBuffersFromMesh(mesh, doubleSidedWinding: false);

    expect(defaulted.vertexCount, explicit.vertexCount);
    expect(defaulted.vertexData, explicit.vertexData);
    expect(
      Uint16List.sublistView(defaulted.indexData),
      Uint16List.sublistView(explicit.indexData),
    );
  });

  test(
      'meshBuffersFromMesh doubleSidedWinding: true emits a second, reverse-wound, '
      'normal-flipped copy of every triangle - the face-culling bug fix (see '
      'geometryFromMesh\'s doc comment: flutter_scene back-face-culls any translucent '
      'material regardless of Material.doubleSided, so the geometry itself must supply '
      'a back-facing copy)', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh, doubleSidedWinding: true);

    expect(buffers.vertexCount, 6);

    // First 3 vertices: original positions/normals, unchanged.
    final firstCopyNormalZ = buffers.vertexData[5];
    expect(firstCopyNormalZ, 1);

    // Second 3 vertices: same positions, negated normals.
    final secondCopyPosition = buffers.vertexData.sublist(36, 39);
    expect(secondCopyPosition, [0, 0, 0]); // same position as vertex 0
    final secondCopyNormalZ = buffers.vertexData[41];
    expect(secondCopyNormalZ, -1);

    final indices = Uint16List.sublistView(buffers.indexData);
    expect(indices.length, 6);
    // Front-facing triangle, unchanged.
    expect(indices.sublist(0, 3), [0, 1, 2]);
    // Back-facing triangle: reversed winding, offset into the second vertex copy.
    expect(indices.sublist(3, 6), [3, 5, 4]);
  });

  test('boundsOfMesh returns the bounding box centre, not the vertex average', () {
    // Mirrors the real placeholder mesh's actual bounds - a
    // BRepPrimAPI_MakeBox(10, 10, 10) spans (0,0,0) to (10,10,10), so its
    // genuine bounding-box centre is (5, 5, 5) - lopsided vertex placement
    // (here, three vertices share z=0 and only one sits at z=10) must not
    // pull the centre away from the box's true geometric middle the way a
    // plain vertex-position average would (that would land at z=2.5).
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [10, 0, 0],
        [0, 10, 0],
        [10, 10, 10],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
        [2, 1, 3],
      ],
    );

    final bounds = boundsOfMesh(mesh)!;

    expect(bounds.center.x, closeTo(5, 1e-9));
    expect(bounds.center.y, closeTo(5, 1e-9));
    expect(bounds.center.z, closeTo(5, 1e-9));
    // Bounding box is 10x10x10 - its space diagonal is 10*sqrt(3), so the
    // bounding-sphere radius (half that diagonal) is 5*sqrt(3).
    expect(bounds.boundingSphereRadius, closeTo(5 * 1.7320508, 1e-4));
  });

  test('boundsOfMesh returns null for an empty mesh', () {
    final mesh = MeshDto(vertices: [], normals: [], triangleIndices: []);

    expect(boundsOfMesh(mesh), isNull);
  });

  test('edgeSegmentsFromMesh groups the flat edges array into 6-float segment pairs', () {
    final mesh = MeshDto(
      vertices: [],
      normals: [],
      triangleIndices: [],
      edges: [0, 0, 0, 10, 0, 0, 10, 0, 0, 10, 10, 0],
    );

    final segments = edgeSegmentsFromMesh(mesh);

    expect(segments, hasLength(2));
    expect(segments[0].$1, vm.Vector3(0, 0, 0));
    expect(segments[0].$2, vm.Vector3(10, 0, 0));
    expect(segments[1].$1, vm.Vector3(10, 0, 0));
    expect(segments[1].$2, vm.Vector3(10, 10, 0));
  });

  test('edgeSegmentsFromMesh returns no segments for an empty edges array', () {
    final mesh = MeshDto(vertices: [], normals: [], triangleIndices: [], edges: []);

    expect(edgeSegmentsFromMesh(mesh), isEmpty);
  });

  test('biasSegmentsTowardCamera pushes each point towards the camera by amount', () {
    final segments = [(vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0))];

    final biased = biasSegmentsTowardCamera(segments, vm.Vector3(-5, 0, 0), 1.0);

    // Camera is at x=-5. Both points move 1 unit along -x, towards it.
    expect(biased[0].$1, vm.Vector3(-1, 0, 0));
    expect(biased[0].$2, vm.Vector3(9, 0, 0));
  });

  test('biasSegmentsTowardCamera leaves a point exactly at the camera unchanged', () {
    final segments = [(vm.Vector3(5, 5, 5), vm.Vector3(10, 0, 0))];

    final biased = biasSegmentsTowardCamera(segments, vm.Vector3(5, 5, 5), 1.0);

    expect(biased[0].$1, vm.Vector3(5, 5, 5));
  });

  test('biasTrianglesTowardCamera pushes each vertex towards the camera by amount (on-device feedback: '
      'face highlight lost to the Body\'s own translucent surface)', () {
    final triangles = [(vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0), vm.Vector3(0, 10, 0))];

    final biased = biasTrianglesTowardCamera(triangles, vm.Vector3(-5, 0, 0), 1.0);

    expect(biased[0].$1, vm.Vector3(-1, 0, 0));
    expect(biased[0].$2, vm.Vector3(9, 0, 0));
    // (0,10,0) pulled 1 unit toward (-5,0,0): direction (-5,-10,0), length
    // sqrt(125) ≈ 11.1803, normalized ≈ (-0.4472, -0.8944, 0).
    expect(biased[0].$3.x, closeTo(-0.4472, 1e-3));
    expect(biased[0].$3.y, closeTo(9.1056, 1e-3));
    expect(biased[0].$3.z, closeTo(0.0, 1e-9));
  });

  test('biasTrianglesTowardCamera leaves a vertex exactly at the camera unchanged', () {
    final triangles = [(vm.Vector3(5, 5, 5), vm.Vector3(10, 0, 0), vm.Vector3(0, 10, 0))];

    final biased = biasTrianglesTowardCamera(triangles, vm.Vector3(5, 5, 5), 1.0);

    expect(biased[0].$1, vm.Vector3(5, 5, 5));
  });

  group('vertexMarkerSegments', () {
    test('turns each position into a near-zero-length segment starting at that position', () {
      final segments = vertexMarkerSegments([vm.Vector3(1, 2, 3), vm.Vector3(4, 5, 6)]);

      expect(segments, hasLength(2));
      expect(segments[0].$1, vm.Vector3(1, 2, 3));
      expect((segments[0].$2 - segments[0].$1).length, lessThan(1e-3));
      expect(segments[1].$1, vm.Vector3(4, 5, 6));
      expect((segments[1].$2 - segments[1].$1).length, lessThan(1e-3));
    });

    test('returns no segments for an empty position list', () {
      expect(vertexMarkerSegments([]), isEmpty);
    });
  });

  group('triangleHighlightBuffers', () {
    test('emits front + back face: 6 vertices per input triangle', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
      ]);

      // One input triangle → 2 output triangles (front + back) → 6 vertices.
      expect(buffers.vertexCount, 6);
      // Front-face vertex 0 is unchanged: position (0,0,0), normal +Z.
      final vertex0 = buffers.vertexData.sublist(0, 12);
      expect(vertex0, [
        0, 0, 0, // position
        0, 0, 1, // normal (cross of the two edges, +Z for this winding)
        0, 0, // uv
        1, 1, 1, 1, // color
      ]);
    });

    test('writes a flat 16-bit index buffer of 0..vertexCount-1', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
        (vm.Vector3(0, 0, 0), vm.Vector3(0, 1, 0), vm.Vector3(0, 0, 1)),
      ]);

      // 2 input triangles → 4 output triangles → 12 vertices → 12 indices.
      final indices = Uint16List.sublistView(buffers.indexData);
      expect(indices, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
    });

    test('a degenerate (zero-area) triangle gets the zero normal rather than NaN', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 0)),
      ]);

      expect(buffers.vertexData.sublist(3, 6), [0, 0, 0]);
    });
  });

  group('highContrastColorFrom (on-device feedback: selected face colour too similar to body colour)', () {
    final palette = [
      vm.Vector4(1, 0, 0, 1), // red
      vm.Vector4(0, 1, 0, 1), // green
      vm.Vector4(0, 0, 1, 1), // blue
    ];

    test('picks the palette entry furthest from the reference color', () {
      // Closest to blue and green; red is furthest away.
      final reference = vm.Vector4(0.1, 0.4, 0.5, 1);
      expect(highContrastColorFrom(palette, reference), vm.Vector4(1, 0, 0, 1));
    });

    test('a reference color near one palette entry avoids it in favor of a further one', () {
      final reference = vm.Vector4(0.95, 0.05, 0.05, 1); // near-red
      final result = highContrastColorFrom(palette, reference);
      expect(result, isNot(vm.Vector4(1, 0, 0, 1)));
    });

    test('a single-entry palette always returns that entry', () {
      final onlyOption = [vm.Vector4(0.5, 0.5, 0.5, 1)];
      expect(highContrastColorFrom(onlyOption, vm.Vector4(0.5, 0.5, 0.5, 1)), onlyOption.single);
    });
  });
}
