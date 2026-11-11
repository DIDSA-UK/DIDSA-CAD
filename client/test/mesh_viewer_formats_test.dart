import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/mesh_viewer/brep_convert.dart';
import 'package:didsa_cad_client/mesh_viewer/mesh_data.dart';

// F-5: the mesh viewer's new formats: PLY on the device, STEP / IGES through the server's /convert/mesh.
Uint8List _asciiPly({bool normals = false, bool quad = false, bool colour = false}) {
  final props = [
    'property float x', 'property float y', 'property float z',
    if (normals) ...['property float nx', 'property float ny', 'property float nz'],
    if (colour) ...['property uchar red', 'property uchar green', 'property uchar blue'],
  ];
  final verts = quad ? 4 : 3;
  final lines = [
    'ply', 'format ascii 1.0', 'comment made by a test', 'element vertex $verts', ...props, 'element face 1',
    'property list uchar int vertex_indices', 'end_header',
    for (final v in [
      [0, 0, 0], [10, 0, 0], [10, 10, 0], if (quad) [0, 10, 0]
    ])
      [...v.map((e) => '$e'), if (normals) ...['0', '0', '1'], if (colour) ...['255', '0', '0']].join(' '),
    quad ? '4 0 1 2 3' : '3 0 1 2',
  ];
  return Uint8List.fromList(utf8.encode('${lines.join('\n')}\n'));
}

Uint8List _binaryPly(Endian endian) {
  final header = 'ply\nformat ${endian == Endian.little ? 'binary_little_endian' : 'binary_big_endian'} 1.0\nelement vertex 3\n'
      'property float x\nproperty float y\nproperty float z\nproperty uchar alpha\nelement face 1\nproperty list uchar uint vertex_indices\nend_header\n';
  final body = BytesBuilder();
  final data = ByteData(13 * 3 + 1 + 12);
  var at = 0;
  for (final v in [[0.0, 0.0, 0.0], [5.0, 0.0, 0.0], [0.0, 5.0, 0.0]]) {
    for (final c in v) {
      data.setFloat32(at, c, endian);
      at += 4;
    }
    data.setUint8(at++, 255);
  }
  data.setUint8(at++, 3);
  for (final i in [0, 1, 2]) {
    data.setUint32(at, i, endian);
    at += 4;
  }
  body.add(utf8.encode(header));
  body.add(data.buffer.asUint8List(0, at));
  return body.toBytes();
}

void main() {
  group('decodePly', () {
    test('an ASCII triangle: one triangle, flat normal +Z, positions as written', () {
      final mesh = decodePly(_asciiPly());
      expect(mesh.triangleCount, 1);
      expect(mesh.positions.sublist(0, 9), [0, 0, 0, 10, 0, 0, 10, 10, 0]);
      expect(mesh.normals.sublist(0, 3), [0, 0, 1]);
    });

    test('a quad is fanned into two triangles', () => expect(decodePly(_asciiPly(quad: true)).triangleCount, 2));

    test('vertex normals are used when the file has them; colour properties are skipped', () {
      final mesh = decodePly(_asciiPly(normals: true, colour: true));
      expect(mesh.triangleCount, 1);
      expect(mesh.normals.sublist(0, 3), [0, 0, 1]);
    });

    test('binary little endian and big endian read the same triangle (with an extra alpha property in between)', () {
      for (final endian in [Endian.little, Endian.big]) {
        final mesh = decodePly(_binaryPly(endian));
        expect(mesh.triangleCount, 1, reason: '$endian');
        expect(mesh.positions.sublist(0, 9), [0, 0, 0, 5, 0, 0, 0, 5, 0], reason: '$endian');
      }
    });

    test('a file that is not PLY, has no faces or points at a missing vertex is a MeshImportError', () {
      expect(() => decodePly(Uint8List.fromList(utf8.encode('hello'))), throwsA(isA<MeshImportError>()));
      final noFaces = utf8.encode('ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n');
      expect(() => decodePly(Uint8List.fromList(noFaces)), throwsA(isA<MeshImportError>()));
      final bad = utf8.encode('ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nend_header\n0 0 0\n3 0 1 2\n');
      expect(() => decodePly(Uint8List.fromList(bad)), throwsA(isA<MeshImportError>()));
    });

    test('maxTriangles decimates during decode and remembers the source count', () {
      final lines = ['ply', 'format ascii 1.0', 'element vertex 3', 'property float x', 'property float y', 'property float z', 'element face 10', 'property list uchar int vertex_indices', 'end_header', '0 0 0', '1 0 0', '0 1 0', for (var i = 0; i < 10; i++) '3 0 1 2'];
      final mesh = decodePly(Uint8List.fromList(utf8.encode(lines.join('\n'))), maxTriangles: 4);
      expect(mesh.sourceTriangleCount, 10);
      expect(mesh.triangleCount, lessThanOrEqualTo(4));
    });
  });

  group('extension routing', () {
    test('mesh formats stay on the device; STEP and IGES need the server', () {
      for (final e in ['stl', 'obj', 'gltf', 'glb', 'ply']) {
        expect(needsServer(e), isFalse, reason: e);
      }
      for (final e in ['step', 'stp', 'iges', 'igs']) {
        expect(needsServer(e), isTrue, reason: e);
      }
      expect(kViewerExtensions, containsAll(['ply', 'step', 'stp', 'iges', 'igs', 'stl']));
      expect(sourceFormatFor('stp'), 'step');
      expect(sourceFormatFor('igs'), 'iges');
      expect(() => sourceFormatFor('stl'), throwsA(isA<MeshImportError>()));
    });
  });

  group('convertBrepToGlb', () {
    test('with no server saved it says a server is needed (not a crash)', () async {
      await expectLater(
        convertBrepToGlb(bytes: Uint8List(3), extension: 'step', baseUrl: ''),
        throwsA(isA<MeshImportError>().having((e) => e.toString(), 'message', contains('needs a DIDSA-CAD server'))),
      );
    });

    test('posts the file with the key and returns the glb bytes, which decodeGltf reads (the endpoint output fixture: a 10 x 20 x 30 box)', () async {
      final glb = File('test/fixtures/convert_mesh_box.glb').readAsBytesSync();
      http.Request? seen;
      final client = MockClient((request) async {
        seen = request;
        return http.Response.bytes(glb, 200);
      });
      final bytes = await convertBrepToGlb(bytes: Uint8List.fromList([1, 2]), extension: 'stp', client: client, baseUrl: 'http://srv', apiKey: 'k');
      expect(seen!.url.toString(), 'http://srv/document/convert/mesh');
      expect(seen!.headers['X-API-Key'], 'k');
      expect(jsonDecode(seen!.body)['source_format'], 'step');
      final mesh = decodeGltf(bytes);
      expect(mesh.triangleCount, 12);
      var maxX = 0.0, maxY = 0.0, maxZ = 0.0;
      for (var i = 0; i < mesh.positions.length; i += 3) {
        maxX = maxX < mesh.positions[i] ? mesh.positions[i] : maxX;
        maxY = maxY < mesh.positions[i + 1] ? mesh.positions[i + 1] : maxY;
        maxZ = maxZ < mesh.positions[i + 2] ? mesh.positions[i + 2] : maxZ;
      }
      expect([maxX, maxY, maxZ].map((v) => v.round()), [10, 20, 30]);
    });

    test('a refusal carries the server\'s reason; an unreachable server says a server is needed', () async {
      final refused = MockClient((request) async => http.Response(jsonEncode({'detail': {'type': 'import_too_large', 'detail': 'too many triangles'}}), 422));
      await expectLater(
        convertBrepToGlb(bytes: Uint8List(1), extension: 'iges', client: refused, baseUrl: 'http://srv', apiKey: 'k'),
        throwsA(isA<MeshImportError>().having((e) => e.toString(), 'message', contains('too many triangles'))),
      );
      final down = MockClient((request) async => throw http.ClientException('no route'));
      await expectLater(
        convertBrepToGlb(bytes: Uint8List(1), extension: 'iges', client: down, baseUrl: 'http://srv', apiKey: 'k'),
        throwsA(isA<MeshImportError>().having((e) => e.toString(), 'message', contains('needs a DIDSA-CAD server'))),
      );
    });
  });
}
