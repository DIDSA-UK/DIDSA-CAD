import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

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
}
