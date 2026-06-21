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
}
