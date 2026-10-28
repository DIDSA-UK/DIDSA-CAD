import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/mesh_geometry.dart' show boundsOfPoints;
import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

void main() {
  final xyBasis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );

  test('spans [-extent, extent] at the given spacing, both directions', () {
    final segments = sketchGridLinesFrom(xyBasis, spacing: 1, extent: 2);

    // 5 offsets (-2, -1, 0, 1, 2) each producing one "horizontal" and one
    // "vertical" line.
    expect(segments.length, 10);

    // The centre horizontal line (y = 0) spans the full extent in x.
    final centreHorizontal = segments.firstWhere((s) => s.$1.y == 0 && s.$1.x == -2);
    expect(centreHorizontal.$1, vm.Vector3(-2, 0, 0));
    expect(centreHorizontal.$2, vm.Vector3(2, 0, 0));

    // The centre vertical line (x = 0) spans the full extent in y.
    final centreVertical = segments.firstWhere((s) => s.$1.x == 0 && s.$1.y == -2);
    expect(centreVertical.$1, vm.Vector3(0, -2, 0));
    expect(centreVertical.$2, vm.Vector3(0, 2, 0));

    // Every point stays exactly on the basis's own plane (z = 0) - the
    // small render-only offset used for on-screen z-fighting avoidance
    // lives in the GPU-facing builder's own Node transform now, not here
    // (see sketch_geometry_3d.dart's own doc comment on why).
    for (final segment in segments) {
      expect(segment.$1.z, 0);
      expect(segment.$2.z, 0);
    }
  });

  test('an arbitrary tilted/offset custom plane places every segment endpoint exactly on the basis', () {
    final normal = vm.Vector3(1, 1, 1).normalized();
    final xAxis = (vm.Vector3(1, -1, 0)).normalized();
    final yAxis = normal.cross(xAxis).normalized();
    final basis = SketchPlaneBasis(origin: vm.Vector3(5, 5, 5), xAxis: xAxis, yAxis: yAxis, normal: normal);

    final segments = sketchGridLinesFrom(basis, spacing: 2, extent: 4);

    expect(segments, isNotEmpty);
    for (final segment in segments) {
      final (localX1, localY1) = worldPointToSketch(basis, segment.$1);
      final (localX2, localY2) = worldPointToSketch(basis, segment.$2);
      // Every endpoint's own local coordinates should be within [-extent,
      // extent] - i.e. the segment genuinely lies within the grid's bounds
      // once mapped back through the same basis.
      expect(localX1.abs(), lessThanOrEqualTo(4.0001));
      expect(localY1.abs(), lessThanOrEqualTo(4.0001));
      expect(localX2.abs(), lessThanOrEqualTo(4.0001));
      expect(localY2.abs(), lessThanOrEqualTo(4.0001));
    }
  });

  // Desktop sketcher feedback 2026-10-28, items 3 and 4: a fixed grid at the
  // sketch origin instead of one that followed the view.
  group('fixed grid', () {
    test('is a 100 mm square until the sketch outgrows it, then grows in 100 mm steps', () {
      expect(sketchGridHalfExtentFor(xyBasis, const []), 50);
      expect(sketchGridHalfExtentFor(xyBasis, [vm.Vector3(30, -40, 0)]), 50);
      expect(sketchGridHalfExtentFor(xyBasis, [vm.Vector3(50, 0, 0)]), 50);
      expect(sketchGridHalfExtentFor(xyBasis, [vm.Vector3(130, 0, 0)]), 150);
      expect(sketchGridHalfExtentFor(xyBasis, [vm.Vector3(0, -201, 0)]), 250);
    });

    test('measures the sketch along the plane axes, not the world ones', () {
      final basis = SketchPlaneBasis(
        origin: vm.Vector3(0, 0, 500),
        xAxis: vm.Vector3(0, 1, 0),
        yAxis: vm.Vector3(0, 0, 1),
        normal: vm.Vector3(1, 0, 0),
      );
      // 500 mm away in world z, but only 20 mm from the sketch origin.
      expect(sketchGridHalfExtentFor(basis, [vm.Vector3(0, 0, 520)]), 50);
    });

    test('major lines every 10 mm, minor lines between them', () {
      final major = sketchGridLineOffsets(sketchGridMajorSpacing, 50);
      expect(major, [-50, -40, -30, -20, -10, 0, 10, 20, 30, 40, 50]);
      final minor = sketchGridLineOffsets(sketchGridMinorSpacing, 50, skipMultiplesOf: sketchGridMajorSpacing);
      expect(minor.length, 101 - 11);
      expect(minor.any((o) => o % 10 == 0), isFalse);
    });

    test('minor lines show only when 1 mm is at least 8 px, on a grid no wider than 500 mm', () {
      expect(sketchGridShowsMinorLines(1 / 8, 50), isTrue);
      expect(sketchGridShowsMinorLines(1 / 7.9, 50), isFalse);
      expect(sketchGridShowsMinorLines(1 / 20, 250), isTrue);
      expect(sketchGridShowsMinorLines(1 / 20, 300), isFalse);
      expect(sketchGridShowsMinorLines(double.nan, 50), isFalse);
      expect(sketchGridShowsMinorLines(0, 50), isFalse);
    });

    test('batches every line into one polyline joined by zero-width connectors, faded at the edge', () {
      final polyline = sketchGridPolyline(xyBasis, const [-10, 0, 10], extent: 50, alpha: 0.5)!;
      expect(polyline.points.length, polyline.widths.length);
      expect(polyline.points.length, polyline.colors.length);
      // Every drawn point lies in the square, on the plane.
      for (final p in polyline.points) {
        expect(p.x.abs(), lessThanOrEqualTo(50 + 1e-9));
        expect(p.y.abs(), lessThanOrEqualTo(50 + 1e-9));
        expect(p.z, 0);
      }
      // Six lines (three offsets, both directions), each bracketed by a
      // zero-width point at either end.
      var runs = 0;
      for (var i = 1; i < polyline.widths.length; i++) {
        if (polyline.widths[i - 1] == 0 && polyline.widths[i] > 0) runs++;
      }
      expect(runs, 6);
      // Solid in the middle, gone at the edge.
      for (var i = 0; i < polyline.points.length; i++) {
        final p = polyline.points[i];
        if (polyline.widths[i] == 0) continue;
        final r = p.x.abs() > p.y.abs() ? p.x.abs() : p.y.abs();
        if (r <= 40) expect(polyline.colors[i].w, closeTo(0.5, 1e-9));
        if (r >= 50) expect(polyline.colors[i].w, closeTo(0, 1e-9));
      }
    });

    test('sameSketchPlaneBasis compares by value', () {
      SketchPlaneBasis copy() => SketchPlaneBasis(
            origin: vm.Vector3.zero(),
            xAxis: vm.Vector3(1, 0, 0),
            yAxis: vm.Vector3(0, 1, 0),
            normal: vm.Vector3(0, 0, 1),
          );
      expect(sameSketchPlaneBasis(copy(), copy()), isTrue);
      expect(sameSketchPlaneBasis(null, null), isTrue);
      expect(sameSketchPlaneBasis(copy(), null), isFalse);
      final moved = SketchPlaneBasis(
        origin: vm.Vector3(0, 0, 5),
        xAxis: vm.Vector3(1, 0, 0),
        yAxis: vm.Vector3(0, 1, 0),
        normal: vm.Vector3(0, 0, 1),
      );
      expect(sameSketchPlaneBasis(copy(), moved), isFalse);
    });

    test('leaves out the fully faded outer lines', () {
      expect(sketchGridPolyline(xyBasis, const [-50, 50], extent: 50, alpha: 0.5), isNull);
    });
  });

  // Item 4: the grid's corners go into the scene bounds (PartViewport.
  // _syncZoomBounds), so the orthographic depth range always spans it, even
  // edge-on and with no bodies.
  test('an edge-on orthographic view of an empty sketch keeps the whole grid in the depth range', () {
    final corners = [
      for (final (x, y) in const [(-50.0, -50.0), (50.0, -50.0), (50.0, 50.0), (-50.0, 50.0)])
        sketchPointToWorld(xyBasis, x, y),
    ];
    final bounds = boundsOfPoints(corners)!;
    final orbit = OrbitCamera()
      ..target = vm.Vector3.zero()
      ..distance = 20
      ..setZoomBoundsForRadius(bounds.boundingSphereRadius, center: bounds.center)
      ..keepOrbitOutsideScene();
    // Look along the plane: the camera's forward lies in z = 0.
    orbit.orientation = OrbitCamera.orientationLookingFrom(vm.Vector3(0, -1, 0), vm.Vector3.zero(), vm.Vector3(0, 0, 1));
    final camera = orthographicCameraFor(orbit, const Size(800, 600));
    final forward = (orbit.target - orbit.position).normalized();
    for (final corner in corners) {
      final depth = (corner - orbit.position).dot(forward);
      expect(depth, greaterThan(camera.near));
      expect(depth, lessThan(camera.far));
    }
  });
}
