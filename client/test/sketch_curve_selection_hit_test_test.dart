import 'package:didsa_cad_client/viewport3d/selection_filter.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  const viewportSize = Size(800, 600);

  // A ray straight down -Z, aimed at (x, y, 0) from well in front of the
  // sketch plane - the same "aim straight at the plane" convention every
  // test case below reuses.
  vm.Ray rayAt(double x, double y) => vm.Ray.originDirection(
        vm.Vector3(x, y, 10),
        vm.Vector3(0, 0, -1),
      );

  test('hitTestSketchArcs finds a hit on an open polyline (was missing entirely before P33)', () {
    final polyline = [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(2, 0, 0)];
    final hit = hitTestSketchArcs(rayAt(1, 0), viewportSize, 'feature-1', [polyline], ['arc-1']);

    expect(hit, isNotNull);
    expect(hit!.entity.kind, SelectionEntityKind.sketchArc);
    expect(hit.entity.sketchEntityId, 'arc-1');
  });

  test('hitTestSketchEllipses finds a hit on a closed polygon (was missing entirely before P33)', () {
    final polygon = [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(1, 1, 0), vm.Vector3(0, 0, 0)];
    final hit = hitTestSketchEllipses(rayAt(0.5, 0), viewportSize, 'feature-1', [polygon], ['ellipse-1']);

    expect(hit, isNotNull);
    expect(hit!.entity.kind, SelectionEntityKind.sketchEllipse);
    expect(hit.entity.sketchEntityId, 'ellipse-1');
  });

  test('hitTestSketchSplines finds a hit on an open polyline (was missing entirely before P33)', () {
    final polyline = [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0)];
    final hit = hitTestSketchSplines(rayAt(0.5, 0), viewportSize, 'feature-1', [polyline], ['spline-1']);

    expect(hit, isNotNull);
    expect(hit!.entity.kind, SelectionEntityKind.sketchSpline);
    expect(hit.entity.sketchEntityId, 'spline-1');
  });

  test('a miss (ray far from any geometry) returns null for every curve kind', () {
    final polyline = [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0)];
    expect(hitTestSketchArcs(rayAt(50, 50), viewportSize, 'f', [polyline], ['a']), isNull);
    expect(hitTestSketchEllipses(rayAt(50, 50), viewportSize, 'f', [polyline], ['e']), isNull);
    expect(hitTestSketchSplines(rayAt(50, 50), viewportSize, 'f', [polyline], ['s']), isNull);
  });

  test('hitTestBodies picks up Arc/Ellipse/Spline hits when their filter flags are on', () {
    final geometry = SketchGeometry3D(
      lineSegments: const [],
      lineIds: const [],
      points: const [],
      pointIds: const [],
      circlePolygons: const [],
      circleIds: const [],
      arcPolylines: [
        [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0)]
      ],
      arcIds: ['arc-1'],
      ellipsePolygons: const [],
      ellipseIds: const [],
      splinePolylines: const [],
      splineIds: const [],
    );

    final hit = hitTestBodies(
      ray: rayAt(0.5, 0),
      viewportSize: viewportSize,
      bodies: const [],
      sketchGeometries: {'feature-1': geometry},
      filter: SelectionFilterState.defaults,
    );

    expect(hit, isNotNull);
    expect(hit!.entity.kind, SelectionEntityKind.sketchArc);
  });

  test('hitTestBodies skips Arc hits when sketchArc filter is off', () {
    final geometry = SketchGeometry3D(
      lineSegments: const [],
      lineIds: const [],
      points: const [],
      pointIds: const [],
      circlePolygons: const [],
      circleIds: const [],
      arcPolylines: [
        [vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0)]
      ],
      arcIds: ['arc-1'],
      ellipsePolygons: const [],
      ellipseIds: const [],
      splinePolylines: const [],
      splineIds: const [],
    );

    final hit = hitTestBodies(
      ray: rayAt(0.5, 0),
      viewportSize: viewportSize,
      bodies: const [],
      sketchGeometries: {'feature-1': geometry},
      filter: SelectionFilterState.defaults.copyWith(sketchArc: false),
    );

    expect(hit, isNull);
  });
}
