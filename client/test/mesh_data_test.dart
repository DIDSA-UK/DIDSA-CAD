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
