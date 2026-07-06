import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/create_plane_geometry_3d.dart';

/// C2/C3: pure-math coverage for [createPlaneTransform] - the orientation
/// logic behind [buildCreatePlaneNode]'s arbitrary (not axis-aligned) quad
/// placement. Like `reference_planes_test.dart`'s own coverage of
/// `doubleSidedQuadBuffers`/`ReferencePlaneKindX.localTransform`, this file
/// transitively imports `flutter_scene` (via `create_plane_geometry_3d.dart`'s
/// own `buildCreatePlaneNode`), so it's blocked from executing by the same
/// pre-existing `flutter_scene`/`flutter_gpu` stable-channel mismatch as
/// every GPU-touching test file in this project - `flutter analyze`-clean
/// and correct by inspection, confirmed via real CI once available.
void main() {
  group('createPlaneTransform', () {
    test('translates the local origin to the given world origin', () {
      final origin = vm.Vector3(3, 4, 5);
      final transform = createPlaneTransform(
        origin,
        vm.Vector3(1, 0, 0),
        vm.Vector3(0, 0, 1),
        vm.Vector3(0, 1, 0),
      );
      final transformedOrigin = transform.transformed3(vm.Vector3.zero());
      expect(transformedOrigin.x, closeTo(origin.x, 1e-6));
      expect(transformedOrigin.y, closeTo(origin.y, 1e-6));
      expect(transformedOrigin.z, closeTo(origin.z, 1e-6));
    });

    test('maps local +X onto the given xAxis', () {
      final transform = createPlaneTransform(
        vm.Vector3.zero(),
        vm.Vector3(0, 1, 0),
        vm.Vector3(0, 0, 1),
        vm.Vector3(1, 0, 0),
      );
      final transformed = transform.transformed3(vm.Vector3(1, 0, 0));
      expect(transformed.x, closeTo(0, 1e-6));
      expect(transformed.y, closeTo(1, 1e-6));
      expect(transformed.z, closeTo(0, 1e-6));
    });

    test('maps local +Z onto the given yAxis', () {
      final transform = createPlaneTransform(
        vm.Vector3.zero(),
        vm.Vector3(1, 0, 0),
        vm.Vector3(0, 0, -1),
        vm.Vector3(0, 1, 0),
      );
      final transformed = transform.transformed3(vm.Vector3(0, 0, 1));
      expect(transformed.x, closeTo(0, 1e-6));
      expect(transformed.y, closeTo(0, 1e-6));
      expect(transformed.z, closeTo(-1, 1e-6));
    });

    test("maps local +Y (the quad's own normal) onto the given world normal", () {
      for (final normal in [
        vm.Vector3(1, 0, 0),
        vm.Vector3(0, 0, 1),
        vm.Vector3(-1, 0, 0),
        vm.Vector3(0, -1, 0), // anti-parallel to local +Y - no special-cased degenerate branch needed.
        vm.Vector3(1, 1, 1).normalized(),
      ]) {
        // xAxis/yAxis don't need to be geometrically consistent with `normal`
        // for this particular assertion - only the local +Y -> normal column
        // is under test here.
        final transform = createPlaneTransform(
          vm.Vector3.zero(),
          vm.Vector3(1, 0, 0),
          vm.Vector3(0, 0, 1),
          normal,
        );
        final transformedUp = transform.transformed3(vm.Vector3(0, 1, 0));
        expect(transformedUp.x, closeTo(normal.x, 1e-6), reason: 'normal=$normal');
        expect(transformedUp.y, closeTo(normal.y, 1e-6), reason: 'normal=$normal');
        expect(transformedUp.z, closeTo(normal.z, 1e-6), reason: 'normal=$normal');
      }
    });

    test('combines origin + in-plane axes for an arbitrary local point', () {
      final origin = vm.Vector3(10, 0, 0);
      final xAxis = vm.Vector3(0, 1, 0);
      final yAxis = vm.Vector3(0, 0, 1);
      final normal = vm.Vector3(1, 0, 0);
      final transform = createPlaneTransform(origin, xAxis, yAxis, normal);

      // Local (2, 0, 3) -> origin + 2*xAxis + 3*yAxis (local Y, the quad's
      // own normal direction, is 0 here so it doesn't contribute).
      final transformed = transform.transformed3(vm.Vector3(2, 0, 3));
      expect(transformed.x, closeTo(10, 1e-6));
      expect(transformed.y, closeTo(2, 1e-6));
      expect(transformed.z, closeTo(3, 1e-6));
    });
  });
}
