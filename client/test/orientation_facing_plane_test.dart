import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

/// On-device feedback (2026-07-10): a shaded-body backdrop's ghost outline
/// (the body's real edges, projected onto the Sketch's plane via
/// [SketchPlaneBasis] - a plain CPU dot-product, no camera involved) didn't
/// match the same backdrop's own 3D-rendered mesh, on a plane-facing view.
///
/// The previous version of this test (and of `orientationFacingPlane` it
/// verified) checked [OrbitCamera]'s own `right`/`up`/`direction` getters
/// (`orientation.rotated(localRight/localUp/localBack)`) against
/// `SketchPlaneBasis.fixed(plane)` directly. That's the wrong ground truth:
/// `flutter_scene`'s `PerspectiveCamera` never reads those getters - its own
/// `_matrix4LookAt` (`packages/flutter_scene/lib/src/camera.dart` in the
/// `bdero/flutter_scene` repo) independently re-derives the *actual* rendered
/// right/up from `position`/`target`/`up` as `right = up.cross(forward)`,
/// `up = forward.cross(right)` (`forward = (target - position).normalized()`).
/// This test now replicates that exact formula (mirroring `triad.dart`'s
/// `triadAxes`, which already uses the same `camera.up.cross(forward)` -
/// correctly bypassing `OrbitCamera.right` for exactly this reason) and
/// checks the result against `SketchPlaneBasis.fixed(plane)` instead - the
/// only ground truth every other 3D-sketch-geometry consumer (rendered
/// points/lines, hit-testing, the ghost outline) already agrees on.
void main() {
  group('orientationFacingPlane renders the true right/up flutter_scene will show', () {
    final localUp = vm.Vector3(0, 1, 0);
    // "Unit vector from target towards the camera" - matches OrbitCamera's
    // own `_direction` getter and `position = target + direction * distance`.
    final localBack = vm.Vector3(0, 0, 1);

    for (final plane in ReferencePlaneKind.values) {
      test('${plane.name}: the camera actually renders right=xAxis, up=yAxis, '
          'viewed through the plane towards +normal', () {
        final orientation = orientationFacingPlane(plane);
        final basis = SketchPlaneBasis.fixed(plane);

        final direction = orientation.rotated(localBack);
        final up = orientation.rotated(localUp);
        // Exactly flutter_scene's own `_matrix4LookAt`: forward = target -
        // position (unit), right = up x forward, up re-orthogonalized as
        // forward x right - not `OrbitCamera.up`/`.right` directly.
        final forward = -direction;
        final renderRight = up.cross(forward).normalized();
        final renderUp = forward.cross(renderRight).normalized();

        expect(renderRight.x, closeTo(basis.xAxis.x, 1e-6));
        expect(renderRight.y, closeTo(basis.xAxis.y, 1e-6));
        expect(renderRight.z, closeTo(basis.xAxis.z, 1e-6));

        expect(renderUp.x, closeTo(basis.yAxis.x, 1e-6));
        expect(renderUp.y, closeTo(basis.yAxis.y, 1e-6));
        expect(renderUp.z, closeTo(basis.yAxis.z, 1e-6));

        // The camera views *through* the plane towards +normal (forward
        // points from the camera into the scene) - so it physically sits on
        // the -normal side. See `orientationFacingPlane`'s own doc comment
        // for why this side (not +normal) is the one that renders correctly,
        // given `flutter_scene`'s left-handed lookAt convention.
        expect(forward.x, closeTo(basis.normal.x, 1e-6));
        expect(forward.y, closeTo(basis.normal.y, 1e-6));
        expect(forward.z, closeTo(basis.normal.z, 1e-6));
      });
    }
  });
}
