import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart' show MeshDto;
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

void main() {
  group('sketchPointToWorld', () {
    test('XY keeps (x, y) and zeroes Z', () {
      expect(sketchPointToWorld(SketchPlaneBasis.fixed(ReferencePlaneKind.xy), 3, 4), vm.Vector3(3, 4, 0));
    });

    test('XZ maps local y onto world Z, negates local x onto world X, and zeroes Y', () {
      // The x-negation is a real fix (see SketchPlaneBasis.fixed's own doc
      // comment) - XZ's basis used to be left-handed, the only one of the
      // three fixed planes that was, which built every XZ-plane Sketch with
      // inverted chirality.
      expect(sketchPointToWorld(SketchPlaneBasis.fixed(ReferencePlaneKind.xz), 3, 4), vm.Vector3(-3, 0, 4));
    });

    test('YZ maps local x onto world Y and zeroes X', () {
      expect(sketchPointToWorld(SketchPlaneBasis.fixed(ReferencePlaneKind.yz), 3, 4), vm.Vector3(0, 3, 4));
    });
  });

  group('projectMeshVerticesOntoPlane', () {
    test('projects each topology vertex through the basis, threading bodyId/vertexIndex unchanged', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: [
          [3.0, 4.0, 0.0],
          [-3.0, 0.0, 4.0],
        ],
        topologyVertexIds: [7, 12],
      );

      final result = projectMeshVerticesOntoPlane(
        SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        'body-1',
        mesh,
      );

      expect(result, [('body-1', 7, 3.0, 4.0), ('body-1', 12, -3.0, 0.0)]);
    });

    test('is the exact inverse of sketchPointToWorld for a non-trivial plane', () {
      final basis = SketchPlaneBasis.fixed(ReferencePlaneKind.xz);
      final world = sketchPointToWorld(basis, 5.0, -2.0);
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: [
          [world.x, world.y, world.z],
        ],
        topologyVertexIds: [0],
      );

      final result = projectMeshVerticesOntoPlane(basis, 'body-1', mesh);

      expect(result.single.$3, closeTo(5.0, 1e-9));
      expect(result.single.$4, closeTo(-2.0, 1e-9));
    });
  });

  group('projectMeshEdgesOntoPlaneWithIds', () {
    test('projects each edge segment through the basis, threading bodyId/edgeId unchanged', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        edges: [
          0.0, 0.0, 0.0, 10.0, 0.0, 0.0, // segment 0: edge id 5
          0.0, 0.0, 0.0, 0.0, 10.0, 0.0, // segment 1: edge id 6
        ],
        edgeIds: [5, 6],
      );

      final result = projectMeshEdgesOntoPlaneWithIds(
        SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        'body-1',
        mesh,
      );

      expect(result, [
        ('body-1', 5, (0.0, 0.0), (10.0, 0.0)),
        ('body-1', 6, (0.0, 0.0), (0.0, 10.0)),
      ]);
    });

    test('a curved edge\'s several consecutive segments all carry that edge\'s same id', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        edges: [
          0.0, 0.0, 0.0, 1.0, 1.0, 0.0,
          1.0, 1.0, 0.0, 2.0, 0.0, 0.0,
        ],
        edgeIds: [3, 3],
      );

      final result = projectMeshEdgesOntoPlaneWithIds(
        SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        'body-1',
        mesh,
      );

      expect(result.map((e) => e.$2).toSet(), {3});
      expect(result, hasLength(2));
    });
  });

  group('sketchGeometry3DFrom', () {
    final points = [
      PointDto(id: 'p1', x: 0, y: 0),
      PointDto(id: 'p2', x: 10, y: 0),
      PointDto(id: 'p3', x: 0, y: 10),
    ];

    test('resolves a Line into one world-space segment on its plane, with a parallel id', () {
      final line = LineDto(id: 'l1', startPointId: 'p1', endPointId: 'p2', length: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xz),
        points: points,
        lines: [line],
        circles: const [],
      );

      expect(geometry.lineSegments, hasLength(1));
      expect(geometry.lineSegments.single.$1, vm.Vector3(0, 0, 0));
      expect(geometry.lineSegments.single.$2, vm.Vector3(-10, 0, 0));
      expect(geometry.lineIds, ['l1']);
      expect(geometry.circlePolygons, isEmpty);
      expect(geometry.isEmpty, isFalse);
    });

    test('a Line referencing a missing point is skipped, not thrown', () {
      final line = LineDto(id: 'l1', startPointId: 'p1', endPointId: 'missing', length: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: [line],
        circles: const [],
      );

      expect(geometry.lineSegments, isEmpty);
      expect(geometry.lineIds, isEmpty);
      // C1: the Sketch's real Points are still rendered/pickable on their
      // own, independent of whether any Line successfully resolved - not
      // "empty" just because this one Line couldn't be drawn.
      expect(geometry.points, hasLength(points.length));
      expect(geometry.isEmpty, isFalse);
    });

    test('resolves a Circle into a closed polygon centered on its center point, on its plane', () {
      final circle = CircleDto(id: 'c1', centerPointId: 'p1', radiusPointId: 'p2', radius: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.yz),
        points: points,
        lines: const [],
        circles: [circle],
      );

      expect(geometry.circlePolygons, hasLength(1));
      final polygon = geometry.circlePolygons.single;
      // Closed loop: last point repeats the first, up to floating-point
      // error from going all the way around via cos/sin(2*pi).
      expect(polygon.last.x, closeTo(polygon.first.x, 1e-6));
      expect(polygon.last.y, closeTo(polygon.first.y, 1e-6));
      expect(polygon.last.z, closeTo(polygon.first.z, 1e-6));
      // Every point stays on the YZ plane (world X == 0) and exactly `radius`
      // away from the center, which itself maps to the world origin.
      for (final p in polygon) {
        expect(p.x, closeTo(0, 1e-6));
        expect(p.length, closeTo(10, 1e-6));
      }
    });

    test('a Circle referencing a missing center point is skipped, not thrown', () {
      final circle = CircleDto(id: 'c1', centerPointId: 'missing', radiusPointId: 'p2', radius: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: [circle],
      );

      expect(geometry.circlePolygons, isEmpty);
      // Same reasoning as the missing-point Line test above.
      expect(geometry.points, hasLength(points.length));
      expect(geometry.isEmpty, isFalse);
    });

    test('every given Point is projected into points/pointIds, regardless of Line/Circle use', () {
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: const [],
      );

      expect(geometry.pointIds, ['p1', 'p2', 'p3']);
      expect(geometry.points, [vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0), vm.Vector3(0, 10, 0)]);
      expect(geometry.isEmpty, isFalse);
    });

    test('no points, lines, or circles at all is genuinely empty', () {
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: const [],
        lines: const [],
        circles: const [],
      );

      expect(geometry.isEmpty, isTrue);
      expect(geometry.points, isEmpty);
      expect(geometry.lineSegments, isEmpty);
      expect(geometry.circlePolygons, isEmpty);
    });
  });
}
