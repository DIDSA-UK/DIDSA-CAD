import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

/// On-device feedback: a shaded-body backdrop's ghost outline (the body's
/// real edges, projected onto the Sketch's plane via [SketchPlaneBasis] -
/// unrelated to any camera) didn't match the same backdrop's own 3D
/// rendering, on both the XY and XZ planes - "the X axis looks flipped".
/// [OrbitCamera]'s local camera frame (right=+X, up=+Y, camera sits along
/// +Z looking back towards target - see its own class doc comment) is
/// mirrored into world space by [orientationFacingPlane]'s quaternion for
/// each plane; every other 3D-sketch-geometry consumer (rendered points/
/// lines, hit-testing, this same backdrop's own ghost outline) instead
/// places things via [SketchPlaneBasis.fixed]'s `xAxis`/`yAxis`/`normal`.
/// For the backdrop (and Orbit View, which shares this same orientation
/// function) to render anything at all in the same place its flat 2D/ghost
/// counterpart does, the camera's local right/up/viewing-direction MUST
/// equal that same plane's xAxis/yAxis/normal exactly - this test checks
/// that directly, via real `vm.Quaternion` arithmetic (not hand-derived
/// math), for all three fixed planes.
void main() {
  group('orientationFacingPlane matches SketchPlaneBasis exactly', () {
    // Mirrors OrbitCamera's own private local-frame convention exactly (see
    // its class doc comment): right=+X, up=+Y, camera sits along +Z locally
    // (a unit vector from target towards the camera, not the viewing
    // direction into the scene).
    final localRight = vm.Vector3(1, 0, 0);
    final localUp = vm.Vector3(0, 1, 0);
    final localBack = vm.Vector3(0, 0, 1);

    for (final plane in ReferencePlaneKind.values) {
      test('${plane.name}: camera right/up equal the plane basis, and the camera '
          'views from the +normal side', () {
        final orientation = orientationFacingPlane(plane);
        final basis = SketchPlaneBasis.fixed(plane);

        final right = orientation.rotated(localRight);
        final up = orientation.rotated(localUp);
        // Unit vector from target towards the camera - the camera sits on
        // this side of the plane, looking back across it towards target.
        final towardsCamera = orientation.rotated(localBack);

        // TEMP diagnostic - remove once the mismatch is understood.
        // ignore: avoid_print
        print(
          'DIAG ${plane.name}: orientation=$orientation right=$right up=$up '
          'towardsCamera=$towardsCamera basis.xAxis=${basis.xAxis} '
          'basis.yAxis=${basis.yAxis} basis.normal=${basis.normal}',
        );

        expect(right.x, closeTo(basis.xAxis.x, 1e-6));
        expect(right.y, closeTo(basis.xAxis.y, 1e-6));
        expect(right.z, closeTo(basis.xAxis.z, 1e-6));

        expect(up.x, closeTo(basis.yAxis.x, 1e-6));
        expect(up.y, closeTo(basis.yAxis.y, 1e-6));
        expect(up.z, closeTo(basis.yAxis.z, 1e-6));

        expect(towardsCamera.x, closeTo(basis.normal.x, 1e-6));
        expect(towardsCamera.y, closeTo(basis.normal.y, 1e-6));
        expect(towardsCamera.z, closeTo(basis.normal.z, 1e-6));
      });
    }
  });
}
