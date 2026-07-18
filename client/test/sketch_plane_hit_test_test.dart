import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:didsa_cad_client/viewport3d/sketch_plane_hit_test.dart';

void main() {
  test('ray straight down hits the XY plane at the expected point', () {
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );
    final ray = vm.Ray.originDirection(vm.Vector3(2, 3, 10), vm.Vector3(0, 0, -1));

    final hit = hitTestSketchPlane(ray, basis);

    expect(hit, isNotNull);
    final (point, rayT) = hit!;
    expect(point.x, closeTo(2, 1e-9));
    expect(point.y, closeTo(3, 1e-9));
    expect(point.z, closeTo(0, 1e-9));
    expect(rayT, closeTo(10, 1e-9));
  });

  test('ray parallel to the plane never hits', () {
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );
    // Direction lies entirely within the plane (z component zero).
    final ray = vm.Ray.originDirection(vm.Vector3(0, 0, 5), vm.Vector3(1, 0, 0));

    expect(hitTestSketchPlane(ray, basis), isNull);
  });

  test('ray pointing away from the plane (intersection behind the origin) never hits', () {
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );
    // Above the plane, pointing further away from it, not towards it.
    final ray = vm.Ray.originDirection(vm.Vector3(0, 0, 5), vm.Vector3(0, 0, 1));

    expect(hitTestSketchPlane(ray, basis), isNull);
  });

  test('works against an arbitrary (non-axis-aligned, offset) custom plane, matching worldPointToSketch', () {
    // A plane offset from the origin, tilted (not axis-aligned) - the
    // general case a custom (CreatePlaneFeature-anchored) Sketch needs,
    // unlike the three fixed reference planes.
    final normal = vm.Vector3(1, 1, 1).normalized();
    // Any vector not parallel to normal, projected to be in-plane and
    // normalized, gives a valid xAxis; yAxis completes a right-handed basis.
    final xAxis = (vm.Vector3(1, -1, 0)).normalized();
    final yAxis = normal.cross(xAxis).normalized();
    final basis = SketchPlaneBasis(origin: vm.Vector3(5, 5, 5), xAxis: xAxis, yAxis: yAxis, normal: normal);

    // A ray from somewhere off-plane, aimed generally back towards the
    // plane's origin.
    final ray = vm.Ray.originDirection(basis.origin + normal * 20, -normal);

    final hit = hitTestSketchPlane(ray, basis);
    expect(hit, isNotNull);
    final (point, _) = hit!;

    // The hit point should be exactly basis.origin (ray travels straight
    // down the normal from directly above it).
    expect((point - basis.origin).length, closeTo(0, 1e-9));

    // And converting it back to local sketch coordinates via the existing
    // worldPointToSketch should give (0, 0) - the basis's own origin.
    final (localX, localY) = worldPointToSketch(basis, point);
    expect(localX, closeTo(0, 1e-9));
    expect(localY, closeTo(0, 1e-9));
  });
}
