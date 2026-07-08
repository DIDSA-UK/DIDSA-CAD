import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/mesh_viewer/mesh_data.dart';

/// Builds a minimal binary STL: two triangles sharing the XY plane, mirroring
/// `backend/tests/test_mesh_import.py`'s `_two_triangle_mesh` fixture.
Uint8List _binaryStl(List<(List<double>, List<double>, List<double>)> triangles) {
  final builder = BytesBuilder();
  builder.add(List.filled(80, 0));
  final countBytes = ByteData(4)..setUint32(0, triangles.length, Endian.little);
  builder.add(countBytes.buffer.asUint8List());
  for (final (a, b, c) in triangles) {
    final data = ByteData(50);
    var offset = 0;
    for (final component in [0.0, 0.0, 1.0, ...a, ...b, ...c]) {
      data.setFloat32(offset, component, Endian.little);
      offset += 4;
    }
    builder.add(data.buffer.asUint8List());
  }
  return builder.toBytes();
}

void main() {
  group('decodeStl', () {
    test('decodes a binary STL with two triangles', () {
      final bytes = _binaryStl([
        ([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]),
        ([1.0, 0.0, 0.0], [1.0, 1.0, 0.0], [0.0, 1.0, 0.0]),
      ]);
      final mesh = decodeStl(bytes);
      expect(mesh.triangleCount, 2);
      expect(mesh.positions.sublist(0, 3), [0.0, 0.0, 0.0]);
      expect(mesh.normals.sublist(0, 3), [0.0, 0.0, 1.0]);
    });

    test('rejects a non-STL file by falling back to ASCII and failing', () {
      expect(() => decodeStl(Uint8List.fromList(utf8.encode('not an stl file at all'))),
          throwsA(isA<MeshImportError>()));
    });

    test('maxTriangles decimates a binary STL during decode and reports sourceTriangleCount', () {
      final bytes = _binaryStl([
        for (var i = 0; i < 10; i++)
          ([0.0, 0.0, 0.0], [1.0, 0.0, 0.0], [0.0, i.toDouble(), 0.0]),
      ]);
      final mesh = decodeStl(bytes, maxTriangles: 3);
      expect(mesh.sourceTriangleCount, 10);
      expect(mesh.triangleCount, lessThanOrEqualTo(3));
      expect(mesh.triangleCount, greaterThan(0));
    });

    test('maxTriangles decimates an ASCII STL during decode and reports sourceTriangleCount', () {
      final buffer = StringBuffer('solid test\n');
      for (var i = 0; i < 10; i++) {
        buffer.write(
          'facet normal 0 0 1\nouter loop\n'
          'vertex 0 0 0\nvertex 1 0 0\nvertex 0 $i 0\n'
          'endloop\nendfacet\n',
        );
      }
      buffer.write('endsolid test\n');
      final mesh = decodeStl(Uint8List.fromList(utf8.encode(buffer.toString())), maxTriangles: 3);
      expect(mesh.sourceTriangleCount, 10);
      expect(mesh.triangleCount, lessThanOrEqualTo(3));
      expect(mesh.triangleCount, greaterThan(0));
    });

    test('decodes an ASCII STL', () {
      const text = 'solid test\n'
          'facet normal 0 0 1\n'
          'outer loop\n'
          'vertex 0 0 0\n'
          'vertex 1 0 0\n'
          'vertex 0 1 0\n'
          'endloop\n'
          'endfacet\n'
          'endsolid test\n';
      final mesh = decodeStl(Uint8List.fromList(utf8.encode(text)));
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 9), [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
      expect(mesh.normals.sublist(0, 3), [0.0, 0.0, 1.0]);
    });

    test('computes a normal when an ASCII facet normal is all zero', () {
      const text = 'solid test\n'
          'facet normal 0 0 0\n'
          'outer loop\n'
          'vertex 0 0 0\n'
          'vertex 1 0 0\n'
          'vertex 0 1 0\n'
          'endloop\n'
          'endfacet\n'
          'endsolid test\n';
      final mesh = decodeStl(Uint8List.fromList(utf8.encode(text)));
      expect(mesh.normals[0], closeTo(0, 1e-9));
      expect(mesh.normals[1], closeTo(0, 1e-9));
      expect(mesh.normals[2], closeTo(1, 1e-9));
    });
  });

  group('decodeObj', () {
    test('decodes a triangle and computes a normal when none is given', () {
      final mesh = decodeObj('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n');
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 9), [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
      expect(mesh.normals[2], closeTo(1, 1e-9));
    });

    test('fan-triangulates a quad face', () {
      final mesh = decodeObj('v 0 0 0\nv 1 0 0\nv 1 1 0\nv 0 1 0\nf 1 2 3 4\n');
      expect(mesh.triangleCount, 2);
    });

    test('rejects a face referencing an unknown vertex', () {
      expect(() => decodeObj('v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 5\n'), throwsA(isA<MeshImportError>()));
    });

    test('rejects a file with no vertices', () {
      expect(() => decodeObj('# just a comment\n'), throwsA(isA<MeshImportError>()));
    });

    test('maxTriangles decimates during decode and reports sourceTriangleCount', () {
      final buffer = StringBuffer();
      for (var i = 0; i < 10; i++) {
        buffer.write('v 0 0 0\nv 1 0 0\nv 0 $i 0\n');
      }
      for (var i = 0; i < 10; i++) {
        final base = i * 3 + 1;
        buffer.write('f $base ${base + 1} ${base + 2}\n');
      }
      final mesh = decodeObj(buffer.toString(), maxTriangles: 3);
      expect(mesh.sourceTriangleCount, 10);
      expect(mesh.triangleCount, lessThanOrEqualTo(3));
      expect(mesh.triangleCount, greaterThan(0));
    });
  });

  group('decodeGltf', () {
    test('rejects bad magic bytes as neither GLB nor parseable JSON', () {
      final bytes = Uint8List.fromList([...utf8.encode('not a glb file'), ...List.filled(20, 0)]);
      expect(() => decodeGltf(bytes), throwsA(isA<MeshImportError>()));
    });

    test('rejects a JSON .gltf referencing an external buffer file', () {
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {'byteLength': 12, 'uri': 'geometry.bin'},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 12},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 1, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      expect(
        () => decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf)))),
        throwsA(isA<MeshImportError>()),
      );
    });

    test('decodes a binary GLB container', () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final binChunkData = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {'byteLength': binChunkData.length},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': binChunkData.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final jsonChunkData = Uint8List.fromList(utf8.encode(jsonEncode(gltf)));
      final jsonPadding = (4 - jsonChunkData.length % 4) % 4;
      final paddedJson = Uint8List.fromList([...jsonChunkData, ...List.filled(jsonPadding, 0x20)]);
      final binPadding = (4 - binChunkData.length % 4) % 4;
      final paddedBin = Uint8List.fromList([...binChunkData, ...List.filled(binPadding, 0)]);

      final builder = BytesBuilder();
      void writeUint32(int value) {
        final data = ByteData(4)..setUint32(0, value, Endian.little);
        builder.add(data.buffer.asUint8List());
      }

      final totalLength = 12 + 8 + paddedJson.length + 8 + paddedBin.length;
      builder.add(utf8.encode('glTF'));
      writeUint32(2); // version
      writeUint32(totalLength);
      writeUint32(paddedJson.length);
      writeUint32(0x4e4f534a); // 'JSON'
      builder.add(paddedJson);
      writeUint32(paddedBin.length);
      writeUint32(0x004e4942); // 'BIN\0'
      builder.add(paddedBin);

      final mesh = decodeGltf(builder.toBytes());
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 9), [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
    });

    test('decodes a JSON .gltf with an embedded data: URI buffer', () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 9), [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0]);
    });

    test('a vertex accessor with no bufferView decodes as all-zero data instead of crashing', () {
      // Real ODM/OpenDroneMap .glb export hit this on-device: bufferView is
      // legally optional per spec (all-zero data), but was force-cast
      // straight to int, crashing with a raw "type 'Null' is not a subtype
      // of type 'int'" instead of handling the spec-legal case.
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': <Map<String, dynamic>>[],
        'bufferViews': <Map<String, dynamic>>[],
        'accessors': [
          {'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(mesh.triangleCount, 1);
      expect(mesh.positions, everyElement(0.0));
    });

    test('an index accessor with no bufferView is rejected with a clear error', () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
          {'componentType': 5123, 'count': 3, 'type': 'SCALAR'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
                'indices': 1,
              },
            ],
          },
        ],
      };
      expect(
        () => decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf)))),
        throwsA(isA<MeshImportError>()),
      );
    });

    test('a Draco-compressed glTF is rejected with a clear, specific error', () {
      // Real ODM/OpenDroneMap .glb export hit this on-device: its
      // extensionsUsed declares KHR_draco_mesh_compression, and its
      // accessors have no bufferView at all (the real data is compressed
      // inside a KHR_draco_mesh_compression extension block this decoder
      // doesn't implement) - this must fail fast with a specific message,
      // not the generic "no bufferView" error, and specifically before any
      // attempt to zero-fill a vertex accessor's (potentially huge) declared
      // count as if it were legitimately all-zero data.
      final gltf = {
        'asset': {'version': '2.0'},
        'extensionsUsed': ['KHR_draco_mesh_compression'],
        'buffers': <Map<String, dynamic>>[],
        'bufferViews': <Map<String, dynamic>>[],
        'accessors': [
          {'componentType': 5126, 'count': 1000000, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
                'extensions': {
                  'KHR_draco_mesh_compression': {'bufferView': 0, 'attributes': {'POSITION': 0}},
                },
              },
            ],
          },
        ],
      };
      expect(
        () => decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf)))),
        throwsA(
          isA<MeshImportError>().having((e) => e.message, 'message', contains('KHR_draco_mesh_compression')),
        ),
      );
    });

    test('maxTriangles decimates during decode and reports sourceTriangleCount', () {
      final positions = Float32List.fromList([
        for (var i = 0; i < 10; i++) ...[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, i.toDouble(), 0.0],
      ]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 30, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))), maxTriangles: 3);
      expect(mesh.sourceTriangleCount, 10);
      expect(mesh.triangleCount, lessThanOrEqualTo(3));
      expect(mesh.triangleCount, greaterThan(0));
    });
  });

  group('decodeGltf node transforms', () {
    // A single triangle: (0,0,0), (1,0,0), (0,1,0), with a matching per-vertex
    // normal (0,0,1) so rotation's effect on normals can be checked too.
    Map<String, dynamic> gltfWithRootNode(Map<String, dynamic> node) {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final normals = Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]);
      final posBytes = positions.buffer.asUint8List();
      final normalBytes = normals.buffer.asUint8List();
      final combined = Uint8List.fromList([...posBytes, ...normalBytes]);
      return {
        'asset': {'version': '2.0'},
        'scene': 0,
        'scenes': [
          {'nodes': [0]},
        ],
        'nodes': [node],
        'buffers': [
          {
            'byteLength': combined.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(combined)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': posBytes.length},
          {'buffer': 0, 'byteOffset': posBytes.length, 'byteLength': normalBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
          {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0, 'NORMAL': 1},
              },
            ],
          },
        ],
      };
    }

    test('applies a root node translation to vertex positions', () {
      final gltf = gltfWithRootNode({'mesh': 0, 'translation': [10.0, 20.0, 30.0]});
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(
        mesh.positions.sublist(0, 9),
        [10.0, 20.0, 30.0, 11.0, 20.0, 30.0, 10.0, 21.0, 30.0],
      );
      // Translation must not affect normals.
      expect(mesh.normals.sublist(0, 3), [0.0, 0.0, 1.0]);
    });

    test('applies a root node scale to vertex positions', () {
      final gltf = gltfWithRootNode({'mesh': 0, 'scale': [2.0, 3.0, 4.0]});
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(
        mesh.positions.sublist(0, 9),
        [0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 3.0, 0.0],
      );
    });

    test('applies a root node rotation to both positions and normals', () {
      // 90-degree rotation about the X axis: (x, y, z) -> (x, -z, y).
      const half = 0.70710678;
      final gltf = gltfWithRootNode({
        'mesh': 0,
        'rotation': [half, 0.0, 0.0, half],
      });
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      final positions = mesh.positions.sublist(0, 9);
      expect(positions[0], closeTo(0.0, 1e-6));
      expect(positions[1], closeTo(0.0, 1e-6));
      expect(positions[2], closeTo(0.0, 1e-6));
      expect(positions[3], closeTo(1.0, 1e-6));
      expect(positions[4], closeTo(0.0, 1e-6));
      expect(positions[5], closeTo(0.0, 1e-6));
      expect(positions[6], closeTo(0.0, 1e-6));
      expect(positions[7], closeTo(0.0, 1e-6));
      expect(positions[8], closeTo(1.0, 1e-6));
      final normal = mesh.normals.sublist(0, 3);
      expect(normal[0], closeTo(0.0, 1e-6));
      expect(normal[1], closeTo(-1.0, 1e-6));
      expect(normal[2], closeTo(0.0, 1e-6));
    });

    test('rejects a root node that uses a raw matrix transform', () {
      final gltf = gltfWithRootNode({
        'mesh': 0,
        'matrix': [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0],
      });
      expect(
        () => decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf)))),
        throwsA(isA<MeshImportError>()),
      );
    });

    test('a node with no mesh reference is skipped rather than erroring', () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'scene': 0,
        'scenes': [
          {'nodes': [0, 1]},
        ],
        'nodes': [
          {'name': 'empty group'},
          {'mesh': 0, 'translation': [5.0, 0.0, 0.0]},
        ],
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 3), [5.0, 0.0, 0.0]);
    });

    test('composes an ancestor transform with a nested mesh node (not just root nodes)', () {
      // Mirrors a real Blender export shape: the mesh-bearing node itself
      // carries no transform at all - the axis-correction/object transform
      // lives entirely on a parent "Empty"/collection node instead. A
      // root-nodes-only (non-recursive) walk would miss this transform
      // completely, since the root node here has no `mesh` field of its own.
      const half = 0.70710678;
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'scene': 0,
        'scenes': [
          {'nodes': [0]},
        ],
        'nodes': [
          {
            'name': 'axis-correction root (no mesh)',
            'rotation': [half, 0.0, 0.0, half], // 90 deg about X: (x,y,z) -> (x,-z,y)
            'children': [1],
          },
          {'name': 'mesh object', 'mesh': 0},
        ],
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      final p = mesh.positions.sublist(0, 9);
      expect(p[0], closeTo(0.0, 1e-6));
      expect(p[1], closeTo(0.0, 1e-6));
      expect(p[2], closeTo(0.0, 1e-6));
      expect(p[3], closeTo(1.0, 1e-6));
      expect(p[4], closeTo(0.0, 1e-6));
      expect(p[5], closeTo(0.0, 1e-6));
      expect(p[6], closeTo(0.0, 1e-6));
      expect(p[7], closeTo(0.0, 1e-6));
      expect(p[8], closeTo(1.0, 1e-6));
    });
  });

  group('decodeGltf multi-material primitives', () {
    // A real photogrammetry export routinely has one primitive/material per
    // texture-atlas chunk (a real ODM/Blender export this was built against
    // has 39) - each primitive's own vertex data and texture must stay
    // associated with its own contiguous triangle range, not get collapsed
    // onto material 0's texture for the whole mesh.
    Map<String, dynamic> gltfWithTwoMaterialPrimitives({int? primitive0Material, int? primitive1Material}) {
      final positionsA = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final positionsB = Float32List.fromList([2, 0, 0, 3, 0, 0, 2, 1, 0]);
      final bytesA = positionsA.buffer.asUint8List();
      final bytesB = positionsB.buffer.asUint8List();
      final combined = Uint8List.fromList([...bytesA, ...bytesB]);
      final textureA = base64.encode(utf8.encode('texture-a-bytes'));
      final textureB = base64.encode(utf8.encode('texture-b-bytes'));
      return {
        'asset': {'version': '2.0'},
        'buffers': [
          {
            'byteLength': combined.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(combined)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bytesA.length},
          {'buffer': 0, 'byteOffset': bytesA.length, 'byteLength': bytesB.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
          {'bufferView': 1, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'materials': [
          {
            'pbrMetallicRoughness': {
              'baseColorTexture': {'index': 0},
            },
          },
          {
            'pbrMetallicRoughness': {
              'baseColorTexture': {'index': 1},
            },
          },
        ],
        'textures': [
          {'source': 0},
          {'source': 1},
        ],
        'images': [
          {'uri': 'data:image/png;base64,$textureA'},
          {'uri': 'data:image/png;base64,$textureB'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
                if (primitive0Material != null) 'material': primitive0Material,
              },
              {
                'attributes': {'POSITION': 1},
                if (primitive1Material != null) 'material': primitive1Material,
              },
            ],
          },
        ],
      };
    }

    test('each primitive gets its own MeshMaterialGroup with its own texture and triangle range', () {
      final gltf = gltfWithTwoMaterialPrimitives(primitive0Material: 0, primitive1Material: 1);
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      expect(mesh.triangleCount, 2);
      final groups = mesh.materialGroups!;
      expect(groups.length, 2);
      expect(groups[0].startTriangle, 0);
      expect(groups[0].triangleCount, 1);
      expect(utf8.decode(groups[0].textureBytes!), 'texture-a-bytes');
      expect(groups[1].startTriangle, 1);
      expect(groups[1].triangleCount, 1);
      expect(utf8.decode(groups[1].textureBytes!), 'texture-b-bytes');
    });

    test('a primitive with no material field defaults to material index 0', () {
      final gltf = gltfWithTwoMaterialPrimitives(primitive0Material: null, primitive1Material: 1);
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      final groups = mesh.materialGroups!;
      expect(utf8.decode(groups[0].textureBytes!), 'texture-a-bytes');
      expect(utf8.decode(groups[1].textureBytes!), 'texture-b-bytes');
    });

    test('a single-primitive glTF still populates a single-entry materialGroups', () {
      final positions = Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]);
      final bufferBytes = positions.buffer.asUint8List();
      final gltf = {
        'asset': {'version': '2.0'},
        'buffers': [
          {
            'byteLength': bufferBytes.length,
            'uri': 'data:application/octet-stream;base64,${base64.encode(bufferBytes)}',
          },
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': bufferBytes.length},
        ],
        'accessors': [
          {'bufferView': 0, 'componentType': 5126, 'count': 3, 'type': 'VEC3'},
        ],
        'meshes': [
          {
            'primitives': [
              {
                'attributes': {'POSITION': 0},
              },
            ],
          },
        ],
      };
      final mesh = decodeGltf(Uint8List.fromList(utf8.encode(jsonEncode(gltf))));
      final groups = mesh.materialGroups!;
      expect(groups.length, 1);
      expect(groups.single.startTriangle, 0);
      expect(groups.single.triangleCount, 1);
      expect(groups.single.textureBytes, isNull);
    });
  });

  group('decimateToTriangleBudget', () {
    DecodedMesh meshWithTriangles(int count) => DecodedMesh(
          positions: Float32List(count * 9),
          normals: Float32List(count * 9),
          uvs: Float32List(count * 6),
        );

    test('returns the same instance when already within budget', () {
      final mesh = meshWithTriangles(10);
      expect(identical(decimateToTriangleBudget(mesh, 20), mesh), isTrue);
    });

    test('drops triangles at a stride to reach the budget', () {
      final mesh = meshWithTriangles(100);
      final decimated = decimateToTriangleBudget(mesh, 10);
      expect(decimated.triangleCount, lessThanOrEqualTo(10));
      expect(decimated.triangleCount, greaterThan(0));
    });
  });
}
