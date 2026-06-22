import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/reference_planes.dart';

void main() {
  group('referencePlaneKindFromApiValue', () {
    test('parses every plane apiValue back to its ReferencePlaneKind', () {
      for (final plane in ReferencePlaneKind.values) {
        expect(referencePlaneKindFromApiValue(plane.apiValue), plane);
      }
    });

    test('returns null for an unrecognized value rather than throwing', () {
      expect(referencePlaneKindFromApiValue('bogus'), isNull);
    });
  });

  group('ReferencePlaneKindX.localTransform', () {
    // PlaneGeometry is always built flat in the XZ plane (surface facing
    // +Y) - confirms each plane's rotation actually lands a representative
    // local point onto its target plane, per the derivation in
    // reference_planes.dart's doc comment.
    test('xy rotation maps a local XZ point onto the z=0 plane', () {
      final transformed = ReferencePlaneKind.xy.localTransform.transformed3(vm.Vector3(3, 0, 4));
      expect(transformed.z, closeTo(0, 1e-6));
    });

    test('xz rotation is the identity (PlaneGeometry is already XZ)', () {
      final point = vm.Vector3(3, 0, 4);
      final transformed = ReferencePlaneKind.xz.localTransform.transformed3(point);
      expect(transformed.x, closeTo(point.x, 1e-6));
      expect(transformed.y, closeTo(point.y, 1e-6));
      expect(transformed.z, closeTo(point.z, 1e-6));
    });

    test('yz rotation maps a local XZ point onto the x=0 plane', () {
      final transformed = ReferencePlaneKind.yz.localTransform.transformed3(vm.Vector3(3, 0, 4));
      expect(transformed.x, closeTo(0, 1e-6));
    });
  });

  group('hitTestReferencePlanes', () {
    test('a ray straight down the Y axis hits the XZ plane (y=0) at the origin', () {
      // Looking straight down (-Y direction) from above the origin crosses
      // y=0 - the XZ plane - immediately below the camera.
      final ray = vm.Ray.originDirection(vm.Vector3(0, 10, 0), vm.Vector3(0, -1, 0));
      final hit = hitTestReferencePlanes(ray);
      expect(hit?.plane, ReferencePlaneKind.xz);
      expect(hit!.point, vm.Vector3(0, 0, 0));
    });

    test('a ray pointed away from every plane it could hit returns null', () {
      // Travelling straight up from above the origin never crosses y=0
      // again - same for the other two planes, since x and z never change.
      final ray = vm.Ray.originDirection(vm.Vector3(0, 10, 0), vm.Vector3(0, 1, 0));
      expect(hitTestReferencePlanes(ray), isNull);
    });

    test('a ray that crosses the infinite plane outside the rendered rectangle misses', () {
      // Crosses y=0 at x=100, z=100 - far outside the default halfSize=10
      // rendered rectangle.
      final ray = vm.Ray.originDirection(vm.Vector3(100, 10, 100), vm.Vector3(0, -1, 0));
      expect(hitTestReferencePlanes(ray), isNull);
    });

    test('a ray that crosses just inside the rendered rectangle hits', () {
      final ray = vm.Ray.originDirection(vm.Vector3(9, 10, 9), vm.Vector3(0, -1, 0));
      final hit = hitTestReferencePlanes(ray);
      expect(hit?.plane, ReferencePlaneKind.xz);
      expect(hit!.point, vm.Vector3(9, 0, 9));
    });

    test('a ray behind the plane (negative t) does not hit it', () {
      // Already past y=0, moving further away (+Y) - the plane is behind
      // the ray's origin along its direction, not ahead of it.
      final ray = vm.Ray.originDirection(vm.Vector3(0, -10, 0), vm.Vector3(0, -1, 0));
      expect(hitTestReferencePlanes(ray), isNull);
    });

    test('when a ray could hit multiple planes, the closest one to the ray origin wins', () {
      // From (2, 10, 0) heading down and across, this ray crosses x=0 (the
      // YZ plane) after travelling 2*sqrt(2) units, and crosses y=0 (the
      // XZ plane) only later, after 10*sqrt(2) - YZ is unambiguously
      // closer, so it must win even though both rectangles are crossed
      // within bounds. (It runs exactly within the z=0/XY plane the whole
      // way, so that one is correctly skipped as parallel-to-direction
      // rather than reported as a third, even-closer "hit".)
      final ray = vm.Ray.originDirection(vm.Vector3(2, 10, 0), vm.Vector3(-1, -1, 0).normalized());
      final hit = hitTestReferencePlanes(ray);
      expect(hit?.plane, ReferencePlaneKind.yz);
      expect(hit!.point, vm.Vector3(0, 8, 0));
    });

    test('a custom halfSize narrows which rectangle a ray must land within', () {
      final ray = vm.Ray.originDirection(vm.Vector3(4, 10, 4), vm.Vector3(0, -1, 0));
      expect(hitTestReferencePlanes(ray, halfSize: 10)?.plane, ReferencePlaneKind.xz);
      expect(hitTestReferencePlanes(ray, halfSize: 3), isNull);
    });
  });
}
