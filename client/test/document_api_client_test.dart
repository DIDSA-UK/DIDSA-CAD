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
      expect(capturedUri!.queryParametersAll.containsKey('rollback_excluded_feature_ids'), isFalse);
    });

    test(
      'bug fix: sends rollback_excluded_feature_ids as its own separate repeated query '
      'parameter, never merged with hidden_feature_ids',
      () async {
        Uri? capturedUri;
        final client = DocumentApiClient(
          httpClient: MockClient((request) async {
            capturedUri = request.url;
            return jsonResponse(const []);
          }),
        );

        await client.getPartMesh(
          'part-1',
          hiddenFeatureIds: ['hidden-1'],
          rollbackExcludedFeatureIds: ['rollback-1', 'rollback-2'],
        );

        expect(capturedUri!.queryParametersAll['hidden_feature_ids'], ['hidden-1']);
        expect(
          capturedUri!.queryParametersAll['rollback_excluded_feature_ids'],
          ['rollback-1', 'rollback-2'],
        );
      },
    );

    test('sends no query string at all when both id lists are empty', () async {
      Uri? capturedUri;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          return jsonResponse(const []);
        }),
      );

      await client.getPartMesh('part-1');

      expect(capturedUri!.query, isEmpty);
    });
  });

  // Prompt A4: target_body_ids on the create/update calls, and FeatureDto
  // round-tripping it back - the client-side half of A1's Boss/Cut body
  // targeting, now actually wired up from the 3D-viewport picker.
  group('DocumentApiClient createExtrudeFeature/updateExtrudeFeature target_body_ids', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    Map<String, dynamic> capturedBody = {};

    test('createExtrudeFeature sends target_body_ids, defaulting to []', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'extrude',
            'id': 'extrude-1',
            'sketch_feature_id': 'sketch-1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'locked': false,
            'target_body_ids': <String>[],
          });
        }),
      );

      await client.createExtrudeFeature(
        'part-1',
        sketchFeatureId: 'sketch-1',
        extrudeType: 'boss',
        startDistance: 0.0,
        endDistance: 10.0,
      );

      expect(capturedBody['target_body_ids'], <String>[]);
    });

    test('createExtrudeFeature sends explicitly picked target_body_ids', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'extrude',
            'id': 'extrude-1',
            'sketch_feature_id': 'sketch-1',
            'extrude_type': 'cut',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'locked': false,
            'target_body_ids': ['boss-1', 'boss-2#0'],
          });
        }),
      );

      final feature = await client.createExtrudeFeature(
        'part-1',
        sketchFeatureId: 'sketch-1',
        extrudeType: 'cut',
        startDistance: 0.0,
        endDistance: 10.0,
        targetBodyIds: ['boss-1', 'boss-2#0'],
      );

      expect(capturedBody['target_body_ids'], ['boss-1', 'boss-2#0']);
      expect(feature.targetBodyIds, ['boss-1', 'boss-2#0']);
    });

    test('updateExtrudeFeature omits target_body_ids when not supplied', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'extrude',
            'id': 'extrude-1',
            'sketch_feature_id': 'sketch-1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 20.0,
            'locked': false,
            'target_body_ids': <String>[],
          }, status: 200);
        }),
      );

      await client.updateExtrudeFeature('part-1', 'extrude-1', endDistance: 20.0);

      expect(capturedBody.containsKey('target_body_ids'), isFalse);
    });

    test('updateExtrudeFeature sends an explicit empty list distinctly from omitting it',
        () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'extrude',
            'id': 'extrude-1',
            'sketch_feature_id': 'sketch-1',
            'extrude_type': 'boss',
            'start_distance': 0.0,
            'end_distance': 10.0,
            'locked': false,
            'target_body_ids': <String>[],
          }, status: 200);
        }),
      );

      await client.updateExtrudeFeature('part-1', 'extrude-1', targetBodyIds: const []);

      expect(capturedBody.containsKey('target_body_ids'), isTrue);
      expect(capturedBody['target_body_ids'], <String>[]);
    });
  });

  group('SubShapeRefDto / SketchEntityRefDto round-trip', () {
    test('SubShapeRefDto toJson/fromJson round-trips exactly', () {
      const ref = SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 3);
      final roundTripped = SubShapeRefDto.fromJson(ref.toJson());
      expect(roundTripped.bodyId, ref.bodyId);
      expect(roundTripped.shapeType, ref.shapeType);
      expect(roundTripped.index, ref.index);
    });

    test('SketchEntityRefDto toJson/fromJson round-trips exactly', () {
      const ref = SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'line', entityId: 'line-1');
      final roundTripped = SketchEntityRefDto.fromJson(ref.toJson());
      expect(roundTripped.sketchId, ref.sketchId);
      expect(roundTripped.entityType, ref.entityType);
      expect(roundTripped.entityId, ref.entityId);
    });

    test('C4: PointRefDto toJson/fromJson round-trips a vertexRef entry', () {
      const ref = PointRefDto(
        vertexRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'vertex', index: 2),
      );
      final roundTripped = PointRefDto.fromJson(ref.toJson());
      expect(roundTripped.vertexRef?.bodyId, 'body-1');
      expect(roundTripped.vertexRef?.index, 2);
      expect(roundTripped.sketchPointRef, isNull);
      expect(ref.toJson().containsKey('sketch_point_ref'), isFalse);
    });

    test('C4: PointRefDto toJson/fromJson round-trips a sketchPointRef entry', () {
      const ref = PointRefDto(
        sketchPointRef: SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'point', entityId: 'point-1'),
      );
      final roundTripped = PointRefDto.fromJson(ref.toJson());
      expect(roundTripped.sketchPointRef?.entityId, 'point-1');
      expect(roundTripped.vertexRef, isNull);
      expect(ref.toJson().containsKey('vertex_ref'), isFalse);
    });
  });

  group('FeatureDto.fromJson for a create_plane Feature', () {
    test('parses an offset_face Feature with resolved origin/normal', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-1',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'offset_face',
        'face_refs': [{'body_id': 'body-1', 'shape_type': 'face', 'index': 2}],
        'offset': 5.0,
        'origin': [1.0, 2.0, 3.0],
        'normal': [0.0, 0.0, 1.0],
        'x_axis': [1.0, 0.0, 0.0],
        'y_axis': [0.0, 1.0, 0.0],
      });

      expect(dto.type, 'create_plane');
      expect(dto.planeType, 'offset_face');
      expect(dto.faceRefs.single.bodyId, 'body-1');
      expect(dto.faceRefs.single.index, 2);
      expect(dto.offset, 5.0);
      expect(dto.lineRef, isNull);
      expect(dto.pointRef, isNull);
      expect(dto.origin, [1.0, 2.0, 3.0]);
      expect(dto.normal, [0.0, 0.0, 1.0]);
      expect(dto.xAxis, [1.0, 0.0, 0.0]);
      expect(dto.yAxis, [0.0, 1.0, 0.0]);
    });

    test('parses a midplane Feature with two face_refs entries', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-4',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'midplane',
        'face_refs': [
          {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
          {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
        ],
        'origin': [0.0, 0.0, 5.0],
        'normal': [0.0, 0.0, 1.0],
      });

      expect(dto.planeType, 'midplane');
      expect(dto.faceRefs, hasLength(2));
      expect(dto.faceRefs[0].index, 0);
      expect(dto.faceRefs[1].index, 3);
      expect(dto.offset, isNull);
    });

    test('parses a normal_to_line_at_point Feature', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-2',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'normal_to_line_at_point',
        'line_ref': {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'line-1'},
        'point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-1'},
        'origin': [0.0, 0.0, 0.0],
        'normal': [1.0, 0.0, 0.0],
      });

      expect(dto.planeType, 'normal_to_line_at_point');
      expect(dto.faceRefs, isEmpty);
      expect(dto.offset, isNull);
      expect(dto.lineRef?.entityId, 'line-1');
      expect(dto.pointRef?.entityId, 'point-1');
    });

    test('C4: parses a normal_to_edge_through_vertex Feature', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-6',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'normal_to_edge_through_vertex',
        'edge_ref': {'body_id': 'body-1', 'shape_type': 'edge', 'index': 4},
        'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 0},
        'origin': [0.0, 0.0, 0.0],
        'normal': [1.0, 0.0, 0.0],
      });

      expect(dto.planeType, 'normal_to_edge_through_vertex');
      expect(dto.edgeRef?.index, 4);
      expect(dto.vertexRef?.index, 0);
      expect(dto.pointRefs, isEmpty);
    });

    test('C4: parses a parallel_to_face_through_vertex Feature', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-7',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'parallel_to_face_through_vertex',
        'face_refs': [{'body_id': 'body-1', 'shape_type': 'face', 'index': 2}],
        'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 1},
        'origin': [1.0, 1.0, 1.0],
        'normal': [0.0, 0.0, 1.0],
      });

      expect(dto.planeType, 'parallel_to_face_through_vertex');
      expect(dto.faceRefs.single.index, 2);
      expect(dto.vertexRef?.index, 1);
    });

    test('C4: parses a three_points Feature mixing a vertexRef and sketchPointRefs', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-8',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'three_points',
        'point_refs': [
          {
            'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 0},
          },
          {
            'sketch_point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-1'},
          },
          {
            'sketch_point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-2'},
          },
        ],
        'origin': [0.0, 0.0, 0.0],
        'normal': [0.0, 0.0, 1.0],
      });

      expect(dto.planeType, 'three_points');
      expect(dto.pointRefs, hasLength(3));
      expect(dto.pointRefs[0].vertexRef?.index, 0);
      expect(dto.pointRefs[1].sketchPointRef?.entityId, 'point-1');
      expect(dto.pointRefs[2].sketchPointRef?.entityId, 'point-2');
    });

    test('a Feature whose Plane could not be resolved has null origin/normal', () {
      final dto = FeatureDto.fromJson({
        'type': 'create_plane',
        'id': 'plane-3',
        'locked': false,
        'produces': 'plane',
        'plane_type': 'offset_face',
        'face_refs': [{'body_id': 'gone', 'shape_type': 'face', 'index': 0}],
        'offset': 1.0,
        'origin': null,
        'normal': null,
      });

      expect(dto.origin, isNull);
      expect(dto.normal, isNull);
    });
  });

  group('DocumentApiClient createCreatePlaneFeature/updateCreatePlaneFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createCreatePlaneFeature sends only the offset_face fields', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-1',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'offset_face',
            'face_refs': [{'body_id': 'body-1', 'shape_type': 'face', 'index': 0}],
            'offset': 5.0,
            'origin': [0.0, 0.0, 5.0],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      final feature = await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'offset_face',
        faceRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 0)],
        offset: 5.0,
      );

      expect(capturedBody['plane_type'], 'offset_face');
      expect(capturedBody['face_refs'], [{'body_id': 'body-1', 'shape_type': 'face', 'index': 0}]);
      expect(capturedBody['offset'], 5.0);
      expect(capturedBody.containsKey('line_ref'), isFalse);
      expect(capturedBody.containsKey('point_ref'), isFalse);
      expect(feature.origin, [0.0, 0.0, 5.0]);
    });

    test('createCreatePlaneFeature sends only the normal_to_line_at_point fields', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-2',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'normal_to_line_at_point',
            'line_ref': {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'line-1'},
            'point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-1'},
            'origin': [0.0, 0.0, 0.0],
            'normal': [1.0, 0.0, 0.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'normal_to_line_at_point',
        lineRef: const SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'line', entityId: 'line-1'),
        pointRef: const SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'point', entityId: 'point-1'),
      );

      expect(capturedBody['plane_type'], 'normal_to_line_at_point');
      expect(capturedBody.containsKey('face_refs'), isFalse);
      expect(capturedBody.containsKey('offset'), isFalse);
      expect(capturedBody['line_ref'], {'sketch_id': 'sketch-1', 'entity_type': 'line', 'entity_id': 'line-1'});
    });

    test('updateCreatePlaneFeature only sends the fields supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-1',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'offset_face',
            'face_refs': [{'body_id': 'body-1', 'shape_type': 'face', 'index': 0}],
            'offset': 20.0,
            'origin': [0.0, 0.0, 20.0],
            'normal': [0.0, 0.0, 1.0],
          }, status: 200);
        }),
      );

      await client.updateCreatePlaneFeature('part-1', 'plane-1', offset: 20.0);

      expect(capturedBody, {'offset': 20.0});
    });

    test('createCreatePlaneFeature sends both face_refs entries for midplane', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-5',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'midplane',
            'face_refs': [
              {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
              {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
            ],
            'origin': [0.0, 0.0, 5.0],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'midplane',
        faceRefs: const [
          SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 0),
          SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 3),
        ],
      );

      expect(capturedBody['plane_type'], 'midplane');
      expect(capturedBody['face_refs'], [
        {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
        {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
      ]);
      expect(capturedBody.containsKey('offset'), isFalse);
    });

    test('C4: createCreatePlaneFeature sends only the normal_to_edge_through_vertex fields', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-6',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'normal_to_edge_through_vertex',
            'edge_ref': {'body_id': 'body-1', 'shape_type': 'edge', 'index': 4},
            'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 0},
            'origin': [0.0, 0.0, 0.0],
            'normal': [1.0, 0.0, 0.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'normal_to_edge_through_vertex',
        edgeRef: const SubShapeRefDto(bodyId: 'body-1', shapeType: 'edge', index: 4),
        vertexRef: const SubShapeRefDto(bodyId: 'body-1', shapeType: 'vertex', index: 0),
      );

      expect(capturedBody['plane_type'], 'normal_to_edge_through_vertex');
      expect(capturedBody['edge_ref'], {'body_id': 'body-1', 'shape_type': 'edge', 'index': 4});
      expect(capturedBody['vertex_ref'], {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 0});
      expect(capturedBody.containsKey('face_refs'), isFalse);
    });

    test('C4: createCreatePlaneFeature sends only the parallel_to_face_through_vertex fields', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-7',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'parallel_to_face_through_vertex',
            'face_refs': [{'body_id': 'body-1', 'shape_type': 'face', 'index': 2}],
            'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 1},
            'origin': [1.0, 1.0, 1.0],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'parallel_to_face_through_vertex',
        faceRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 2)],
        vertexRef: const SubShapeRefDto(bodyId: 'body-1', shapeType: 'vertex', index: 1),
      );

      expect(capturedBody['plane_type'], 'parallel_to_face_through_vertex');
      expect(capturedBody['face_refs'], [{'body_id': 'body-1', 'shape_type': 'face', 'index': 2}]);
      expect(capturedBody['vertex_ref'], {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 1});
      expect(capturedBody.containsKey('edge_ref'), isFalse);
    });

    test('C4: createCreatePlaneFeature sends point_refs mixing vertexRef and sketchPointRef', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-8',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'three_points',
            'point_refs': [],
            'origin': [0.0, 0.0, 0.0],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'three_points',
        pointRefs: const [
          PointRefDto(vertexRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'vertex', index: 0)),
          PointRefDto(
            sketchPointRef: SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'point', entityId: 'point-1'),
          ),
          PointRefDto(
            sketchPointRef: SketchEntityRefDto(sketchId: 'sketch-1', entityType: 'point', entityId: 'point-2'),
          ),
        ],
      );

      expect(capturedBody['plane_type'], 'three_points');
      expect(capturedBody['point_refs'], [
        {
          'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 0},
        },
        {
          'sketch_point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-1'},
        },
        {
          'sketch_point_ref': {'sketch_id': 'sketch-1', 'entity_type': 'point', 'entity_id': 'point-2'},
        },
      ]);
      expect(capturedBody.containsKey('face_refs'), isFalse);
    });
  });

  group('DocumentApiClient createSketchFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('defaults to plane: XY when neither plane nor planeFeatureId is given', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'sketch',
            'id': 'sf-1',
            'sketch_id': 'sketch-1',
            'locked': false,
            'produces': 'sketch',
          });
        }),
      );

      await client.createSketchFeature('part-1');

      expect(capturedBody, {'plane': 'XY'});
    });

    test('sends plane_feature_id instead of plane when supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'sketch',
            'id': 'sf-2',
            'sketch_id': 'sketch-2',
            'locked': false,
            'produces': 'sketch',
            'plane_feature_id': 'plane-1',
          });
        }),
      );

      final feature =
          await client.createSketchFeature('part-1', plane: null, planeFeatureId: 'plane-1');

      expect(capturedBody, {'plane_feature_id': 'plane-1'});
      expect(feature.planeFeatureId, 'plane-1');
    });
  });
}
