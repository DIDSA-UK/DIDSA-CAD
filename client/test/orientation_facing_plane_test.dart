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

  /// Bug fix (on-device feedback - camera calibration, "8 possible
  /// orientations for each plane"): [SketchPlaneBasis.withOrientation]'s
  /// `flip` makes `xAxis`/`yAxis` a *left-handed* pair relative to
  /// `basis.normal` (confirmed: `xAxis.cross(yAxis) == -basis.normal`
  /// whenever flip is applied, for every plane, every rotation) -
  /// `Quaternion.fromRotation` can't represent that (it can only represent a
  /// proper rotation, determinant +1), so `orientationFacingBasis` used to
  /// silently produce an incorrect camera whenever `flip` was true. Fixed to
  /// derive its own viewing direction from the basis's own actual
  /// handedness (`xAxis.cross(yAxis)`) instead of trusting `basis.normal`
  /// blindly - this covers every `flip`/`rotationQuarterTurns` combination,
  /// not just the three combinations independently confirmed on-device
  /// (`orbit_camera_test.dart`'s own default-orientation tests), by
  /// checking the same "does flutter_scene's actual lookAt render
  /// right=xAxis, up=yAxis, forward=the basis's own *actual* handedness"
  /// property this file's own group above already established as ground
  /// truth - generalized here to hold for every oriented basis, not just
  /// the three unflipped/unrotated ones.
  group('orientationFacingPlane renders correctly for every flip/rotation combination', () {
    final localUp = vm.Vector3(0, 1, 0);
    final localBack = vm.Vector3(0, 0, 1);

    for (final plane in ReferencePlaneKind.values) {
      for (final flip in [false, true]) {
        for (var rotation = 0; rotation < 4; rotation++) {
          test('${plane.name} flip=$flip rotation=$rotation', () {
            final basis = SketchPlaneBasis.oriented(plane, flip: flip, rotationQuarterTurns: rotation);
            final orientation = orientationFacingPlane(plane, flip: flip, rotationQuarterTurns: rotation);

            final direction = orientation.rotated(localBack);
            final up = orientation.rotated(localUp);
            final forward = -direction;
            final renderRight = up.cross(forward).normalized();
            final renderUp = forward.cross(renderRight).normalized();

            expect((renderRight - basis.xAxis).length, closeTo(0, 1e-6));
            expect((renderUp - basis.yAxis).length, closeTo(0, 1e-6));

            // The camera's own actual viewing direction must match the
            // basis's *real* handedness, not its raw (always-fixed,
            // flip-independent) normal - that's exactly the bug this test
            // group exists to catch a regression of.
            final effectiveNormal = basis.xAxis.cross(basis.yAxis);
            expect((forward - effectiveNormal).length, closeTo(0, 1e-6));
          });
        }
      }
    }
  });

  /// The three per-plane defaults `PartScreen._defaultPendingOrientationFor`
  /// actually uses, checked against the exact on-screen-triad-convention
  /// readouts independently captured on-device for each - a direct
  /// regression guard for `part_screen.dart`'s own defaults, not just for
  /// `orientationFacingBasis` in the abstract.
  group('the three per-plane defaults match their own independently-captured on-device targets', () {
    void expectTriadReadout(
      vm.Quaternion orientation, {
      required vm.Vector3 expectedXReading,
      required vm.Vector3 expectedYReading,
      required vm.Vector3 expectedZReading,
    }) {
      final camera = OrbitCamera()..orientation = orientation;
      final towardCamera = (camera.position - camera.target).normalized();
      final forward = -towardCamera;
      final right = camera.up.cross(forward).normalized();
      final up = forward.cross(right).normalized();

      void expectAxis(vm.Vector3 axis, vm.Vector3 expected) {
        expect(axis.dot(right), closeTo(expected.x, 0.01));
        expect(axis.dot(up), closeTo(expected.y, 0.01));
        expect(axis.dot(towardCamera), closeTo(expected.z, 0.01));
      }

      expectAxis(vm.Vector3(1, 0, 0), expectedXReading);
      expectAxis(vm.Vector3(0, 1, 0), expectedYReading);
      expectAxis(vm.Vector3(0, 0, 1), expectedZReading);
    }

    test('XY: flip=true, rotation=1', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.xy, flip: true, rotationQuarterTurns: 1),
        expectedXReading: vm.Vector3(0, 1, 0),
        expectedYReading: vm.Vector3(1, 0, 0),
        expectedZReading: vm.Vector3(0, 0, 1),
      );
    });

    test('XZ: flip=true, rotation=0', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.xz, flip: true, rotationQuarterTurns: 0),
        expectedXReading: vm.Vector3(1, 0, 0),
        expectedYReading: vm.Vector3(0, 0, 1),
        expectedZReading: vm.Vector3(0, 1, 0),
      );
    });

    test('YZ: flip=false, rotation=0 (unchanged - already an exact match)', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.yz, flip: false, rotationQuarterTurns: 0),
        expectedXReading: vm.Vector3(0, 0, -1),
        expectedYReading: vm.Vector3(1, 0, 0),
        expectedZReading: vm.Vector3(0, 1, 0),
      );
    });
  });
}
