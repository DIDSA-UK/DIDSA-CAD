import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

void main() {
  group('sketchPointToWorld', () {
    test('XY keeps (x, y) and zeroes Z', () {
      expect(sketchPointToWorld(ReferencePlaneKind.xy, 3, 4), vm.Vector3(3, 4, 0));
    });

    test('XZ maps local y onto world Z and zeroes Y', () {
      expect(sketchPointToWorld(ReferencePlaneKind.xz, 3, 4), vm.Vector3(3, 0, 4));
    });

    test('YZ maps local x onto world Y and zeroes X', () {
      expect(sketchPointToWorld(ReferencePlaneKind.yz, 3, 4), vm.Vector3(0, 3, 4));
    });
  });

  group('sketchGeometry3DFrom', () {
    final points = [
      PointDto(id: 'p1', x: 0, y: 0),
      PointDto(id: 'p2', x: 10, y: 0),
      PointDto(id: 'p3', x: 0, y: 10),
    ];

    test('resolves a Line into one world-space segment on its plane', () {
      final line = LineDto(id: 'l1', startPointId: 'p1', endPointId: 'p2', length: 10);
      final geometry = sketchGeometry3DFrom(
        plane: ReferencePlaneKind.xz,
        points: points,
        lines: [line],
        circles: const [],
      );

      expect(geometry.lineSegments, hasLength(1));
      expect(geometry.lineSegments.single.$1, vm.Vector3(0, 0, 0));
      expect(geometry.lineSegments.single.$2, vm.Vector3(10, 0, 0));
      expect(geometry.circlePolygons, isEmpty);
      expect(geometry.isEmpty, isFalse);
    });

    test('a Line referencing a missing point is skipped, not thrown', () {
      final line = LineDto(id: 'l1', startPointId: 'p1', endPointId: 'missing', length: 10);
      final geometry = sketchGeometry3DFrom(
        plane: ReferencePlaneKind.xy,
        points: points,
        lines: [line],
        circles: const [],
      );

      expect(geometry.isEmpty, isTrue);
    });

    test('resolves a Circle into a closed polygon centered on its center point, on its plane', () {
      final circle = CircleDto(id: 'c1', centerPointId: 'p1', radiusPointId: 'p2', radius: 10);
      final geometry = sketchGeometry3DFrom(
        plane: ReferencePlaneKind.yz,
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
        plane: ReferencePlaneKind.xy,
        points: points,
        lines: const [],
        circles: [circle],
      );

      expect(geometry.isEmpty, isTrue);
    });
  });
}
