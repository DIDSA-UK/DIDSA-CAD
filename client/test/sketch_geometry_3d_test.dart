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

    test(
        'a Circle whose centre Point id is in hiddenPointIds still resolves fully - hiding a '
        'marker must never starve the entity that Point defines (on-device feedback: a Circle\'s '
        'own outline vanishing entirely, fill still showing, the moment its centre was hidden by '
        'the hover-reveal feature - caused by the old version of this omitting hidden Points from '
        'the list entirely, instead of passing the full set through hiddenPointIds)', () {
      final circle = CircleDto(id: 'c1', centerPointId: 'p1', radiusPointId: 'p2', radius: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: [circle],
        hiddenPointIds: {'p1'},
      );

      expect(geometry.circlePolygons, hasLength(1), reason: 'the Circle must still resolve');
      expect(geometry.circleIds, ['c1']);
      // The hidden Point is still fully present in points/pointIds (only
      // buildSketchGeometryNode, which skips marker primitives for
      // hiddenPointIds, treats it differently) - not omitted.
      expect(geometry.points, hasLength(points.length));
      expect(geometry.pointIds, contains('p1'));
      expect(geometry.hiddenPointIds, {'p1'});
    });

    // Bug fix: Arc/Ellipse/Spline had no 3D representation at all before -
    // see sketchGeometry3DFrom's own doc comment.
    test('resolves an Arc into a world-space polyline sweeping CCW from start to end, with a parallel id', () {
      final arcPoints = [
        ...points,
        PointDto(id: 'p4', x: 0, y: 10),
      ];
      final arc = ArcDto(id: 'a1', centerPointId: 'p1', startPointId: 'p2', endPointId: 'p4', radius: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: arcPoints,
        lines: const [],
        circles: const [],
        arcs: [arc],
      );

      expect(geometry.arcPolylines, hasLength(1));
      expect(geometry.arcIds, ['a1']);
      final polyline = geometry.arcPolylines.single;
      // Starts exactly at the start Point (0 degrees) and sweeps CCW to the
      // end Point (90 degrees) - matches sketch_canvas.dart's own
      // _arcScreenAngles/angleWithinArcSweep convention.
      expect(polyline.first.x, closeTo(10, 1e-6));
      expect(polyline.first.y, closeTo(0, 1e-6));
      expect(polyline.last.x, closeTo(0, 1e-6));
      expect(polyline.last.y, closeTo(10, 1e-6));
      for (final p in polyline) {
        expect(p.length, closeTo(10, 1e-6));
      }
    });

    test('an Arc referencing a missing point is skipped, not thrown', () {
      final arc = ArcDto(id: 'a1', centerPointId: 'p1', startPointId: 'missing', endPointId: 'p2', radius: 10);
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: const [],
        arcs: [arc],
      );

      expect(geometry.arcPolylines, isEmpty);
      expect(geometry.arcIds, isEmpty);
    });

    test('resolves an Ellipse into a closed polygon using its own majorRadius/minorRadius/rotation', () {
      final ellipse = EllipseDto(
        id: 'e1',
        centerPointId: 'p1',
        majorPointId: 'p2',
        majorPointNegId: 'unused-1',
        minorPointId: 'unused-2',
        minorPointNegId: 'unused-3',
        majorAxisLineId: 'unused-4',
        minorAxisLineId: 'unused-5',
        majorRadius: 10,
        minorRadius: 5,
        rotation: 0,
      );
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: const [],
        ellipses: [ellipse],
      );

      expect(geometry.ellipsePolygons, hasLength(1));
      expect(geometry.ellipseIds, ['e1']);
      final polygon = geometry.ellipsePolygons.single;
      // Closed loop, first point on the major axis (10, 0), a quarter turn
      // later on the minor axis (0, 5) - unrotated (rotation: 0).
      expect(polygon.first.x, closeTo(10, 1e-6));
      expect(polygon.first.y, closeTo(0, 1e-6));
      expect(polygon.last.x, closeTo(polygon.first.x, 1e-6));
      expect(polygon.last.y, closeTo(polygon.first.y, 1e-6));
      final quarterIndex = circleSegments3D ~/ 4;
      expect(polygon[quarterIndex].x, closeTo(0, 1e-6));
      expect(polygon[quarterIndex].y, closeTo(5, 1e-6));
    });

    test('resolves a Spline into a world-space polyline through its cubic Bezier segments', () {
      final splinePoints = [
        ...points,
        PointDto(id: 'p4', x: 3, y: 0),
        PointDto(id: 'p5', x: 7, y: 0),
      ];
      final spline = SplineDto(
        id: 's1',
        throughPointIds: const ['p1', 'p2'],
        controlPointIds: const ['p4', 'p5'],
      );
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: splinePoints,
        lines: const [],
        circles: const [],
        splines: [spline],
      );

      expect(geometry.splinePolylines, hasLength(1));
      expect(geometry.splineIds, ['s1']);
      final polyline = geometry.splinePolylines.single;
      // Collinear through/control points (all on y=0) reduce the cubic to a
      // straight line from (0,0) to (10,0), regardless of parametrization.
      expect(polyline.first.x, closeTo(0, 1e-6));
      expect(polyline.last.x, closeTo(10, 1e-6));
      for (final p in polyline) {
        expect(p.y, closeTo(0, 1e-6));
      }
    });

    test('a Spline referencing a missing point is skipped, not thrown', () {
      final spline = SplineDto(
        id: 's1',
        throughPointIds: const ['p1', 'missing'],
        controlPointIds: const ['p1', 'p2'],
      );
      final geometry = sketchGeometry3DFrom(
        basis: SketchPlaneBasis.fixed(ReferencePlaneKind.xy),
        points: points,
        lines: const [],
        circles: const [],
        splines: [spline],
      );

      expect(geometry.splinePolylines, isEmpty);
      expect(geometry.splineIds, isEmpty);
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
