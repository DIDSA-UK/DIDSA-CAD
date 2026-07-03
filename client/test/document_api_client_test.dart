import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';

/// Prompt A3: tests for the array-of-Bodies `/mesh` response shape Prompt
/// A1 introduced - `BodyMeshDto.fromJson` directly, plus `getPartMesh`'s
/// end-to-end array parsing via a [MockClient] (no real network, no
/// `flutter_scene` dependency - this file, unlike most of `client/test/`,
/// has none in its import chain, so it actually runs in a sandbox with no
/// working `flutter_gpu`/`flutter_scene` SDK).
void main() {
  group('BodyMeshDto.fromJson', () {
    test('parses body_id/source/mesh from a single JSON object', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'boss-1',
        'source': 'computed',
        'mesh': {
          'vertices': [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
          ],
          'normals': [
            [0.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
          ],
          'triangle_indices': [
            [0, 1, 2],
          ],
          'face_ids': [7],
        },
      });

      expect(dto.bodyId, 'boss-1');
      expect(dto.source, 'computed');
      expect(dto.mesh.vertices.length, 3);
      expect(dto.mesh.faceIds, [7]);
    });

    test('placeholder entry parses the same way as a computed one', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'placeholder',
        'source': 'placeholder',
        'mesh': {
          'vertices': [
            [0.0, 0.0, 0.0],
          ],
          'normals': [
            [0.0, 0.0, 1.0],
          ],
          'triangle_indices': <List<int>>[],
        },
      });

      expect(dto.bodyId, 'placeholder');
      expect(dto.source, 'placeholder');
    });
  });

  group('DocumentApiClient.getPartMesh', () {
    http.Response jsonResponse(Object body, {int status = 200}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    Map<String, dynamic> minimalMeshJson() => {
          'vertices': [
            [0.0, 0.0, 0.0],
            [1.0, 0.0, 0.0],
            [0.0, 1.0, 0.0],
          ],
          'normals': [
            [0.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
            [0.0, 0.0, 1.0],
          ],
          'triangle_indices': [
            [0, 1, 2],
          ],
        };

    test('parses a JSON array with a single computed Body', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async => jsonResponse([
              {'body_id': 'boss-1', 'source': 'computed', 'mesh': minimalMeshJson()},
            ])),
      );

      final bodies = await client.getPartMesh('part-1');

      expect(bodies, hasLength(1));
      expect(bodies.single.bodyId, 'boss-1');
      expect(bodies.single.source, 'computed');
    });

    test('parses a JSON array with multiple independent Bodies', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async => jsonResponse([
              {'body_id': 'boss-1', 'source': 'computed', 'mesh': minimalMeshJson()},
              {'body_id': 'boss-2', 'source': 'computed', 'mesh': minimalMeshJson()},
            ])),
      );

      final bodies = await client.getPartMesh('part-1');

      expect(bodies.map((b) => b.bodyId).toList(), ['boss-1', 'boss-2']);
    });

    test('parses the single-entry placeholder array', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async => jsonResponse([
              {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': minimalMeshJson()},
            ])),
      );

      final bodies = await client.getPartMesh('part-1');

      expect(bodies, hasLength(1));
      expect(bodies.single.source, 'placeholder');
    });

    test('parses an empty array (every Body hidden/skipped)', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async => jsonResponse(const [])),
      );

      final bodies = await client.getPartMesh('part-1');

      expect(bodies, isEmpty);
    });

    test('still sends hidden_feature_ids as a repeated query parameter', () async {
      Uri? capturedUri;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          return jsonResponse(const []);
        }),
      );

      await client.getPartMesh('part-1', hiddenFeatureIds: ['f1', 'f2']);

      expect(capturedUri!.queryParametersAll['hidden_feature_ids'], ['f1', 'f2']);
    });
  });
}
