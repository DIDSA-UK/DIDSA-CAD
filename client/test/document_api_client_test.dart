import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart' show ApiException;

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
      expect(dto.hidden, isFalse);
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

    test('on-device follow-up: parses hidden: true instead of the entry being omitted', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'boss-1',
        'source': 'computed',
        'hidden': true,
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

      expect(dto.hidden, isTrue);
    });

    test('defaults hidden to false when the key is absent (older fixtures)', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'boss-1',
        'source': 'computed',
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

      expect(dto.hidden, isFalse);
    });

    test('on-device feedback: parses face_edge_ids (one list per face)', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'boss-1',
        'source': 'computed',
        'mesh': {
          'vertices': [
            [0.0, 0.0, 0.0],
          ],
          'normals': [
            [0.0, 0.0, 1.0],
          ],
          'triangle_indices': <List<int>>[],
          'face_edge_ids': [
            [0, 1, 2, 3],
            [3, 4, 5, 6],
          ],
        },
      });

      expect(dto.mesh.faceEdgeIds, [
        [0, 1, 2, 3],
        [3, 4, 5, 6],
      ]);
    });

    test('defaults face_edge_ids to [] when the key is absent (older fixtures)', () {
      final dto = BodyMeshDto.fromJson({
        'body_id': 'boss-1',
        'source': 'computed',
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

      expect(dto.mesh.faceEdgeIds, isEmpty);
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

    test('C5: PlaneRefDto toJson/fromJson round-trips a faceRef entry', () {
      const ref = PlaneRefDto(
        faceRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 2),
      );
      final roundTripped = PlaneRefDto.fromJson(ref.toJson());
      expect(roundTripped.faceRef?.bodyId, 'body-1');
      expect(roundTripped.faceRef?.index, 2);
      expect(roundTripped.fixedPlane, isNull);
      expect(roundTripped.planeFeatureId, isNull);
      expect(ref.toJson().containsKey('fixed_plane'), isFalse);
      expect(ref.toJson().containsKey('plane_feature_id'), isFalse);
    });

    test('C5: PlaneRefDto toJson/fromJson round-trips a fixedPlane entry', () {
      const ref = PlaneRefDto(fixedPlane: 'XY');
      final roundTripped = PlaneRefDto.fromJson(ref.toJson());
      expect(roundTripped.fixedPlane, 'XY');
      expect(roundTripped.faceRef, isNull);
      expect(roundTripped.planeFeatureId, isNull);
      expect(ref.toJson().containsKey('face_ref'), isFalse);
      expect(ref.toJson().containsKey('plane_feature_id'), isFalse);
    });

    test('C5: PlaneRefDto toJson/fromJson round-trips a planeFeatureId entry', () {
      const ref = PlaneRefDto(planeFeatureId: 'plane-1');
      final roundTripped = PlaneRefDto.fromJson(ref.toJson());
      expect(roundTripped.planeFeatureId, 'plane-1');
      expect(roundTripped.faceRef, isNull);
      expect(roundTripped.fixedPlane, isNull);
      expect(ref.toJson().containsKey('face_ref'), isFalse);
      expect(ref.toJson().containsKey('fixed_plane'), isFalse);
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
        'face_refs': [
          {
            'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 2},
          },
        ],
        'offset': 5.0,
        'origin': [1.0, 2.0, 3.0],
        'normal': [0.0, 0.0, 1.0],
        'x_axis': [1.0, 0.0, 0.0],
        'y_axis': [0.0, 1.0, 0.0],
      });

      expect(dto.type, 'create_plane');
      expect(dto.planeType, 'offset_face');
      expect(dto.faceRefs.single.faceRef?.bodyId, 'body-1');
      expect(dto.faceRefs.single.faceRef?.index, 2);
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
          {
            'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
          },
          {
            'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
          },
        ],
        'origin': [0.0, 0.0, 5.0],
        'normal': [0.0, 0.0, 1.0],
      });

      expect(dto.planeType, 'midplane');
      expect(dto.faceRefs, hasLength(2));
      expect(dto.faceRefs[0].faceRef?.index, 0);
      expect(dto.faceRefs[1].faceRef?.index, 3);
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
        'face_refs': [
          {
            'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 2},
          },
        ],
        'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 1},
        'origin': [1.0, 1.0, 1.0],
        'normal': [0.0, 0.0, 1.0],
      });

      expect(dto.planeType, 'parallel_to_face_through_vertex');
      expect(dto.faceRefs.single.faceRef?.index, 2);
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

  group('Prompt D: FeatureDto.fromJson for a fillet Feature', () {
    test('parses edge_refs and radius', () {
      final dto = FeatureDto.fromJson({
        'type': 'fillet',
        'id': 'fillet-1',
        'locked': false,
        'produces': 'body',
        'edge_refs': [
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 3},
        ],
        'radius': 2.0,
      });

      expect(dto.type, 'fillet');
      expect(dto.edgeRefs, hasLength(2));
      expect(dto.edgeRefs[0].bodyId, 'body-1');
      expect(dto.edgeRefs[0].index, 0);
      expect(dto.edgeRefs[1].index, 3);
      expect(dto.radius, 2.0);
      expect(dto.produces, 'body');
    });

    test('defaults edgeRefs to empty and radius to null when omitted', () {
      final dto = FeatureDto.fromJson({
        'type': 'extrude',
        'id': 'ef-1',
        'locked': false,
        'produces': 'body',
        'sketch_feature_id': 'sf-1',
        'extrude_type': 'boss',
        'start_distance': 0.0,
        'end_distance': 10.0,
      });

      expect(dto.edgeRefs, isEmpty);
      expect(dto.radius, isNull);
    });
  });

  group('Prompt D: DocumentApiClient createFilletFeature/updateFilletFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createFilletFeature sends edge_refs and radius', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'fillet',
            'id': 'fillet-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
            ],
            'radius': 1.5,
          });
        }),
      );

      final feature = await client.createFilletFeature(
        'part-1',
        edgeRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'edge', index: 0)],
        radius: 1.5,
      );

      expect(capturedBody['edge_refs'], [
        {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
      ]);
      expect(capturedBody['radius'], 1.5);
      expect(feature.radius, 1.5);
      expect(feature.edgeRefs.single.bodyId, 'body-1');
    });

    test('updateFilletFeature only sends the fields supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'fillet',
            'id': 'fillet-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
            ],
            'radius': 3.0,
          }, status: 200);
        }),
      );

      await client.updateFilletFeature('part-1', 'fillet-1', radius: 3.0);

      expect(capturedBody, {'radius': 3.0});
    });

    test('updateFilletFeature sends edge_refs when supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'fillet',
            'id': 'fillet-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 1},
            ],
            'radius': 1.0,
          }, status: 200);
        }),
      );

      await client.updateFilletFeature(
        'part-1',
        'fillet-1',
        edgeRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'edge', index: 1)],
      );

      expect(capturedBody, {
        'edge_refs': [
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 1},
        ],
      });
    });
  });

  group('Prompt E: FeatureDto.fromJson for a chamfer Feature', () {
    test('parses edge_refs and distance', () {
      final dto = FeatureDto.fromJson({
        'type': 'chamfer',
        'id': 'chamfer-1',
        'locked': false,
        'produces': 'body',
        'edge_refs': [
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 3},
        ],
        'distance': 2.0,
      });

      expect(dto.type, 'chamfer');
      expect(dto.edgeRefs, hasLength(2));
      expect(dto.edgeRefs[0].bodyId, 'body-1');
      expect(dto.edgeRefs[0].index, 0);
      expect(dto.edgeRefs[1].index, 3);
      expect(dto.distance, 2.0);
      expect(dto.produces, 'body');
    });

    test('defaults edgeRefs to empty and distance to null when omitted', () {
      final dto = FeatureDto.fromJson({
        'type': 'extrude',
        'id': 'ef-1',
        'locked': false,
        'produces': 'body',
        'sketch_feature_id': 'sf-1',
        'extrude_type': 'boss',
        'start_distance': 0.0,
        'end_distance': 10.0,
      });

      expect(dto.edgeRefs, isEmpty);
      expect(dto.distance, isNull);
    });
  });

  group('Prompt E: DocumentApiClient createChamferFeature/updateChamferFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createChamferFeature sends edge_refs and distance', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'chamfer',
            'id': 'chamfer-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
            ],
            'distance': 1.5,
          });
        }),
      );

      final feature = await client.createChamferFeature(
        'part-1',
        edgeRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'edge', index: 0)],
        distance: 1.5,
      );

      expect(capturedBody['edge_refs'], [
        {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
      ]);
      expect(capturedBody['distance'], 1.5);
      expect(feature.distance, 1.5);
      expect(feature.edgeRefs.single.bodyId, 'body-1');
    });

    test('updateChamferFeature only sends the fields supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'chamfer',
            'id': 'chamfer-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 0},
            ],
            'distance': 3.0,
          }, status: 200);
        }),
      );

      await client.updateChamferFeature('part-1', 'chamfer-1', distance: 3.0);

      expect(capturedBody, {'distance': 3.0});
    });

    test('updateChamferFeature sends edge_refs when supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'chamfer',
            'id': 'chamfer-1',
            'locked': false,
            'produces': 'body',
            'edge_refs': [
              {'body_id': 'body-1', 'shape_type': 'edge', 'index': 1},
            ],
            'distance': 1.0,
          }, status: 200);
        }),
      );

      await client.updateChamferFeature(
        'part-1',
        'chamfer-1',
        edgeRefs: const [SubShapeRefDto(bodyId: 'body-1', shapeType: 'edge', index: 1)],
      );

      expect(capturedBody, {
        'edge_refs': [
          {'body_id': 'body-1', 'shape_type': 'edge', 'index': 1},
        ],
      });
    });
  });

  group('Pattern/Mirror scoping Phase 1: FeatureDto.fromJson for a mirror Feature', () {
    test('parses source_body_ids and mirror_plane', () {
      final dto = FeatureDto.fromJson({
        'type': 'mirror',
        'id': 'mirror-1',
        'locked': false,
        'produces': 'body',
        'source_body_ids': ['body-1'],
        'mirror_plane': {'face_ref': null, 'fixed_plane': 'YZ', 'plane_feature_id': null},
      });

      expect(dto.type, 'mirror');
      expect(dto.sourceBodyIds, ['body-1']);
      expect(dto.mirrorPlane?.fixedPlane, 'YZ');
      expect(dto.produces, 'body');
    });

    test('defaults sourceBodyIds to empty and mirrorPlane to null when omitted', () {
      final dto = FeatureDto.fromJson({
        'type': 'extrude',
        'id': 'ef-1',
        'locked': false,
        'produces': 'body',
        'sketch_feature_id': 'sf-1',
        'extrude_type': 'boss',
        'start_distance': 0.0,
        'end_distance': 10.0,
      });

      expect(dto.sourceBodyIds, isEmpty);
      expect(dto.mirrorPlane, isNull);
    });
  });

  group('Pattern/Mirror scoping Phase 1: DocumentApiClient createMirrorFeature/updateMirrorFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createMirrorFeature sends source_body_ids and mirror_plane', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'mirror',
            'id': 'mirror-1',
            'locked': false,
            'produces': 'body',
            'source_body_ids': ['body-1'],
            'mirror_plane': {'face_ref': null, 'fixed_plane': 'YZ', 'plane_feature_id': null},
          });
        }),
      );

      final feature = await client.createMirrorFeature(
        'part-1',
        sourceBodyIds: const ['body-1'],
        mirrorPlane: const PlaneRefDto(fixedPlane: 'YZ'),
      );

      expect(capturedBody['source_body_ids'], ['body-1']);
      expect(capturedBody['mirror_plane'], {'fixed_plane': 'YZ'});
      expect(feature.sourceBodyIds, ['body-1']);
      expect(feature.mirrorPlane?.fixedPlane, 'YZ');
    });

    test('updateMirrorFeature only sends the fields supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'mirror',
            'id': 'mirror-1',
            'locked': false,
            'produces': 'body',
            'source_body_ids': ['body-1'],
            'mirror_plane': {'face_ref': null, 'fixed_plane': 'XZ', 'plane_feature_id': null},
          }, status: 200);
        }),
      );

      await client.updateMirrorFeature(
        'part-1',
        'mirror-1',
        mirrorPlane: const PlaneRefDto(fixedPlane: 'XZ'),
      );

      expect(capturedBody, {
        'mirror_plane': {'fixed_plane': 'XZ'},
      });
    });

    test('updateMirrorFeature sends source_body_ids when supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'mirror',
            'id': 'mirror-1',
            'locked': false,
            'produces': 'body',
            'source_body_ids': ['body-2'],
            'mirror_plane': {'face_ref': null, 'fixed_plane': 'YZ', 'plane_feature_id': null},
          }, status: 200);
        }),
      );

      await client.updateMirrorFeature('part-1', 'mirror-1', sourceBodyIds: const ['body-2']);

      expect(capturedBody, {
        'source_body_ids': ['body-2'],
      });
    });
  });

  group('Boolean family, first entry: FeatureDto.fromJson for a merge Feature', () {
    test('parses body_ids', () {
      final dto = FeatureDto.fromJson({
        'type': 'merge',
        'id': 'merge-1',
        'locked': false,
        'produces': 'body',
        'body_ids': ['body-1', 'body-2'],
      });

      expect(dto.type, 'merge');
      expect(dto.bodyIds, ['body-1', 'body-2']);
      expect(dto.produces, 'body');
    });

    test('defaults bodyIds to empty when omitted', () {
      final dto = FeatureDto.fromJson({
        'type': 'extrude',
        'id': 'ef-1',
        'locked': false,
        'produces': 'body',
        'sketch_feature_id': 'sf-1',
        'extrude_type': 'boss',
        'start_distance': 0.0,
        'end_distance': 10.0,
      });

      expect(dto.bodyIds, isEmpty);
    });
  });

  group('Boolean family, first entry: DocumentApiClient createMergeFeature/updateMergeFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createMergeFeature sends body_ids', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'merge',
            'id': 'merge-1',
            'locked': false,
            'produces': 'body',
            'body_ids': ['body-1', 'body-2'],
          });
        }),
      );

      final feature = await client.createMergeFeature('part-1', bodyIds: const ['body-1', 'body-2']);

      expect(capturedBody, {
        'body_ids': ['body-1', 'body-2'],
      });
      expect(feature.bodyIds, ['body-1', 'body-2']);
    });

    test('updateMergeFeature only sends body_ids when supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'merge',
            'id': 'merge-1',
            'locked': false,
            'produces': 'body',
            'body_ids': ['body-1', 'body-3'],
          }, status: 200);
        }),
      );

      await client.updateMergeFeature('part-1', 'merge-1', bodyIds: const ['body-1', 'body-3']);

      expect(capturedBody, {
        'body_ids': ['body-1', 'body-3'],
      });
    });

    test('updateMergeFeature sends an empty body when nothing supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'merge',
            'id': 'merge-1',
            'locked': false,
            'produces': 'body',
            'body_ids': ['body-1', 'body-2'],
          }, status: 200);
        }),
      );

      await client.updateMergeFeature('part-1', 'merge-1');

      expect(capturedBody, <String, dynamic>{});
    });
  });

  group('Boolean family, Subtract/Common: FeatureDto.fromJson for a boolean Feature', () {
    test('parses operation/target_body_ids/tool_body_ids/consume_tool_bodies', () {
      final dto = FeatureDto.fromJson({
        'type': 'boolean',
        'id': 'bool-1',
        'locked': false,
        'produces': 'body',
        'operation': 'subtract',
        'target_body_ids': ['body-1'],
        'tool_body_ids': ['body-2'],
        'consume_tool_bodies': false,
      });

      expect(dto.type, 'boolean');
      expect(dto.operation, 'subtract');
      expect(dto.targetBodyIds, ['body-1']);
      expect(dto.toolBodyIds, ['body-2']);
      expect(dto.consumeToolBodies, false);
    });

    test('defaults consumeToolBodies to true and toolBodyIds to empty when omitted', () {
      final dto = FeatureDto.fromJson({
        'type': 'extrude',
        'id': 'ef-1',
        'locked': false,
        'produces': 'body',
        'sketch_feature_id': 'sf-1',
        'extrude_type': 'boss',
        'start_distance': 0.0,
        'end_distance': 10.0,
      });

      expect(dto.operation, isNull);
      expect(dto.toolBodyIds, isEmpty);
      expect(dto.consumeToolBodies, true);
    });
  });

  group('Boolean family, Subtract/Common: DocumentApiClient createBooleanFeature/updateBooleanFeature',
      () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createBooleanFeature sends operation/target_body_ids/tool_body_ids/consume_tool_bodies', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'boolean',
            'id': 'bool-1',
            'locked': false,
            'produces': 'body',
            'operation': 'common',
            'target_body_ids': ['body-1'],
            'tool_body_ids': ['body-2'],
            'consume_tool_bodies': true,
          });
        }),
      );

      final feature = await client.createBooleanFeature(
        'part-1',
        operation: BooleanOperation.common,
        targetBodyIds: const ['body-1'],
        toolBodyIds: const ['body-2'],
      );

      expect(capturedBody, {
        'operation': 'common',
        'target_body_ids': ['body-1'],
        'tool_body_ids': ['body-2'],
        'consume_tool_bodies': true,
      });
      expect(feature.operation, 'common');
      expect(feature.targetBodyIds, ['body-1']);
      expect(feature.toolBodyIds, ['body-2']);
    });

    test('updateBooleanFeature only sends supplied fields', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'boolean',
            'id': 'bool-1',
            'locked': false,
            'produces': 'body',
            'operation': 'subtract',
            'target_body_ids': ['body-1'],
            'tool_body_ids': ['body-3'],
            'consume_tool_bodies': false,
          }, status: 200);
        }),
      );

      await client.updateBooleanFeature('part-1', 'bool-1', toolBodyIds: const ['body-3']);

      expect(capturedBody, {
        'tool_body_ids': ['body-3'],
      });
    });

    test('updateBooleanFeature sends an empty body when nothing supplied', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'boolean',
            'id': 'bool-1',
            'locked': false,
            'produces': 'body',
            'operation': 'subtract',
            'target_body_ids': ['body-1'],
            'tool_body_ids': ['body-2'],
            'consume_tool_bodies': true,
          }, status: 200);
        }),
      );

      await client.updateBooleanFeature('part-1', 'bool-1');

      expect(capturedBody, <String, dynamic>{});
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
        faceRefs: const [
          PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 0)),
        ],
        offset: 5.0,
      );

      expect(capturedBody['plane_type'], 'offset_face');
      expect(capturedBody['face_refs'], [
        {
          'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
        },
      ]);
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
            'face_refs': [
              {
                'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
              },
            ],
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
              {
                'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
              },
              {
                'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
              },
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
          PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 0)),
          PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 3)),
        ],
      );

      expect(capturedBody['plane_type'], 'midplane');
      expect(capturedBody['face_refs'], [
        {
          'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 0},
        },
        {
          'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 3},
        },
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
            'face_refs': [
              {
                'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 2},
              },
            ],
            'vertex_ref': {'body_id': 'body-1', 'shape_type': 'vertex', 'index': 1},
            'origin': [1.0, 1.0, 1.0],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'parallel_to_face_through_vertex',
        faceRefs: const [
          PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'body-1', shapeType: 'face', index: 2)),
        ],
        vertexRef: const SubShapeRefDto(bodyId: 'body-1', shapeType: 'vertex', index: 1),
      );

      expect(capturedBody['plane_type'], 'parallel_to_face_through_vertex');
      expect(capturedBody['face_refs'], [
        {
          'face_ref': {'body_id': 'body-1', 'shape_type': 'face', 'index': 2},
        },
      ]);
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

    test('C5: createCreatePlaneFeature sends a midplane mixing a fixedPlane and a planeFeatureId', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'create_plane',
            'id': 'plane-9',
            'locked': false,
            'produces': 'plane',
            'plane_type': 'midplane',
            'face_refs': [
              {'fixed_plane': 'XY'},
              {'plane_feature_id': 'plane-1'},
            ],
            'origin': [0.0, 0.0, 2.5],
            'normal': [0.0, 0.0, 1.0],
          });
        }),
      );

      final feature = await client.createCreatePlaneFeature(
        'part-1',
        planeType: 'midplane',
        faceRefs: const [PlaneRefDto(fixedPlane: 'XY'), PlaneRefDto(planeFeatureId: 'plane-1')],
      );

      expect(capturedBody['plane_type'], 'midplane');
      expect(capturedBody['face_refs'], [
        {'fixed_plane': 'XY'},
        {'plane_feature_id': 'plane-1'},
      ]);
      expect(feature.faceRefs[0].fixedPlane, 'XY');
      expect(feature.faceRefs[1].planeFeatureId, 'plane-1');
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

  group('Gear Design Workstream 8: GearPreviewDto.fromJson', () {
    test('parses a gear-kind response with reference circles', () {
      final dto = GearPreviewDto.fromJson({
        'gear_kind': 'external',
        'outline_points': [
          [1.0, 2.0],
          [3.0, 4.0],
        ],
        'pitch_radius': 20.0,
        'base_radius': 18.79,
        'addendum_radius': 22.0,
        'dedendum_radius': 17.5,
        'outer_radius': null,
        'pitch_line_y': null,
        'addendum_line_y': null,
        'dedendum_line_y': null,
        'rack_length': null,
        'warnings': ['Tooth count is low'],
      });

      expect(dto.gearKind, 'external');
      expect(dto.outlinePoints, [
        [1.0, 2.0],
        [3.0, 4.0],
      ]);
      expect(dto.pitchRadius, 20.0);
      expect(dto.addendumRadius, 22.0);
      expect(dto.pitchLineY, isNull);
      expect(dto.warnings, ['Tooth count is low']);
    });

    test('parses a rack response with reference lines instead of circles', () {
      final dto = GearPreviewDto.fromJson({
        'gear_kind': 'rack',
        'outline_points': [
          [-5.0, -2.5],
          [5.0, -2.5],
        ],
        'pitch_line_y': 0.0,
        'addendum_line_y': 2.0,
        'dedendum_line_y': -2.5,
        'rack_length': 62.8,
        'warnings': [],
      });

      expect(dto.gearKind, 'rack');
      expect(dto.pitchRadius, isNull);
      expect(dto.pitchLineY, 0.0);
      expect(dto.rackLength, 62.8);
      expect(dto.warnings, isEmpty);
    });
  });

  group('Gear Design Workstream 8: DocumentApiClient previewGear', () {
    http.Response jsonResponse(Object body, {int status = 200}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('sends gear_kind/module/tooth_count and parses the response', () async {
      Map<String, dynamic> capturedBody = {};
      Uri? capturedUri;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'gear_kind': 'external',
            'outline_points': [
              [1.0, 0.0],
            ],
            'pitch_radius': 20.0,
            'base_radius': 18.0,
            'addendum_radius': 22.0,
            'dedendum_radius': 17.5,
            'warnings': [],
          });
        }),
      );

      final preview = await client.previewGear(gearKind: 'external', module: 2.0, toothCount: 20);

      expect(capturedUri?.path, '/document/gear/preview');
      expect(capturedBody['gear_kind'], 'external');
      expect(capturedBody['module'], 2.0);
      expect(capturedBody['tooth_count'], 20);
      expect(capturedBody.containsKey('outer_diameter'), isFalse);
      expect(capturedBody.containsKey('backing_height'), isFalse);
      expect(preview.pitchRadius, 20.0);
    });

    test('sends outer_diameter for an internal gear', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'gear_kind': 'internal',
            'outline_points': [
              [1.0, 0.0],
            ],
            'outer_radius': 50.0,
            'warnings': [],
          });
        }),
      );

      await client.previewGear(gearKind: 'internal', module: 2.0, toothCount: 40, outerDiameter: 100.0);

      expect(capturedBody['outer_diameter'], 100.0);
    });

    test('surfaces a structured 422 detail as the ApiException message', () async {
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'detail': {'type': 'invalid_gear_preview_parameters', 'detail': 'tooth_count must be >= 4'},
            }),
            422,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        client.previewGear(gearKind: 'external', module: 2.0, toothCount: 3),
        throwsA(
          isA<ApiException>().having((e) => e.message, 'message', contains('tooth_count must be >= 4')),
        ),
      );
    });
  });

  group('Gear Design Workstream 8: DocumentApiClient createGearFeature/createRackFeature', () {
    http.Response jsonResponse(Object body, {int status = 201}) =>
        http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

    test('createGearFeature sends every gear field plus plane_ref', () async {
      Map<String, dynamic> capturedBody = {};
      Uri? capturedUri;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'gear',
            'id': 'gear-1',
            'locked': false,
            'produces': 'body',
            'plane_ref': {'fixed_plane': 'XY'},
            'gear_type': 'boss',
            'is_internal': false,
            'module': 2.0,
            'tooth_count': 20,
            'face_width': 5.0,
            'pressure_angle_degrees': 20.0,
            'profile_shift': 0.0,
            'backlash': 0.0,
            'root_fillet_radius': 0.0,
          });
        }),
      );

      final feature = await client.createGearFeature(
        'part-1',
        gearType: 'boss',
        isInternal: false,
        module: 2.0,
        toothCount: 20,
        faceWidth: 5.0,
        planeRef: const PlaneRefDto(fixedPlane: 'XY'),
      );

      expect(capturedUri?.path, '/document/parts/part-1/gear-features');
      expect(capturedBody['plane_ref'], {'fixed_plane': 'XY'});
      expect(capturedBody['is_internal'], false);
      expect(capturedBody['module'], 2.0);
      expect(capturedBody['tooth_count'], 20);
      // Workstream 4a: defaults reproduce a plain spur gear byte-identically.
      expect(capturedBody['helix_angle_degrees'], 0.0);
      expect(capturedBody['herringbone'], false);
      expect(feature.type, 'gear');
    });

    test('createGearFeature sends helix_angle_degrees/herringbone when set', () async {
      Map<String, dynamic> capturedBody = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'gear',
            'id': 'gear-1',
            'locked': false,
            'produces': 'body',
            'plane_ref': {'fixed_plane': 'XY'},
            'gear_type': 'boss',
            'is_internal': false,
            'module': 2.0,
            'tooth_count': 20,
            'face_width': 5.0,
            'pressure_angle_degrees': 20.0,
            'profile_shift': 0.0,
            'backlash': 0.0,
            'root_fillet_radius': 0.0,
            'helix_angle_degrees': 20.0,
            'herringbone': true,
          });
        }),
      );

      await client.createGearFeature(
        'part-1',
        gearType: 'boss',
        isInternal: false,
        module: 2.0,
        toothCount: 20,
        faceWidth: 5.0,
        helixAngleDegrees: 20.0,
        herringbone: true,
      );

      expect(capturedBody['helix_angle_degrees'], 20.0);
      expect(capturedBody['herringbone'], true);
    });

    test('createRackFeature sends every rack field plus plane_ref', () async {
      Map<String, dynamic> capturedBody = {};
      Uri? capturedUri;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          capturedUri = request.url;
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'rack',
            'id': 'rack-1',
            'locked': false,
            'produces': 'body',
            'plane_ref': {'fixed_plane': 'XZ'},
            'rack_type': 'boss',
            'module': 2.0,
            'tooth_count': 10,
            'face_width': 5.0,
            'pressure_angle_degrees': 20.0,
            'backlash': 0.0,
          });
        }),
      );

      final feature = await client.createRackFeature(
        'part-1',
        rackType: 'boss',
        module: 2.0,
        toothCount: 10,
        faceWidth: 5.0,
        planeRef: const PlaneRefDto(fixedPlane: 'XZ'),
      );

      expect(capturedUri?.path, '/document/parts/part-1/rack-features');
      expect(capturedBody['rack_type'], 'boss');
      expect(capturedBody['tooth_count'], 10);
      expect(capturedBody.containsKey('backing_height'), isFalse);
      expect(feature.type, 'rack');
    });
  });
}
