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
/// `flutter_scene`'s `PerspectiveCamera` never reads those getters - it
/// independently re-derives the *actual* rendered right/up from
/// `position`/`target`/`up`. This test replicates that exact formula and
/// checks the result against `SketchPlaneBasis.fixed(plane)` instead - the
/// only ground truth every other 3D-sketch-geometry consumer (rendered
/// points/lines, hit-testing, the ghost outline) already agrees on.
///
/// **2026-07-22 update**: the render formula this test reproduces changed
/// from `right = up.cross(forward)` (flutter_scene's own `PerspectiveCamera`
/// convention, confirmed - by reading that package's actual source - to be a
/// genuine, un-rotatable-away mirror bug) to `right = forward.cross(up)`
/// (`[OrbitCamera.cameraFor]` now returns `FixedPerspectiveCamera`, which
/// fixes this at its root - see `orthographic_camera.dart`'s
/// `correctedLookAt`). `orientationFacingBasis` was updated to match (its
/// own compensating negations, which existed solely to counteract the old
/// bug, were removed) - so `renderRight`/`renderUp` below still land on
/// `basis.xAxis`/`basis.yAxis` exactly as before, only `forward`'s sign (and
/// so which physical side of the plane the camera sits on) changed.
void main() {
  group('orientationFacingPlane renders the true right/up flutter_scene will show', () {
    final localUp = vm.Vector3(0, 1, 0);
    // "Unit vector from target towards the camera" - matches OrbitCamera's
    // own `_direction` getter and `position = target + direction * distance`.
    final localBack = vm.Vector3(0, 0, 1);

    for (final plane in ReferencePlaneKind.values) {
      test('${plane.name}: the camera actually renders right=xAxis, up=yAxis, '
          'viewed through the plane towards -normal', () {
        final orientation = orientationFacingPlane(plane);
        final basis = SketchPlaneBasis.fixed(plane);

        final direction = orientation.rotated(localBack);
        final up = orientation.rotated(localUp);
        // Exactly FixedPerspectiveCamera's own correctedLookAt: forward =
        // target - position (unit), right = forward x up, up
        // re-orthogonalized as right x forward - not `OrbitCamera.up`/
        // `.right` directly.
        final forward = -direction;
        final renderRight = forward.cross(up).normalized();
        final renderUp = renderRight.cross(forward).normalized();

        expect(renderRight.x, closeTo(basis.xAxis.x, 1e-6));
        expect(renderRight.y, closeTo(basis.xAxis.y, 1e-6));
        expect(renderRight.z, closeTo(basis.xAxis.z, 1e-6));

        expect(renderUp.x, closeTo(basis.yAxis.x, 1e-6));
        expect(renderUp.y, closeTo(basis.yAxis.y, 1e-6));
        expect(renderUp.z, closeTo(basis.yAxis.z, 1e-6));

        // The camera now views *from* the +normal side, back through
        // -normal at the plane's front face - the intuitive side, unlike
        // the pre-fix version's own "+normal, viewed from behind". See
        // `orientationFacingBasis`'s own doc comment for the full derivation.
        expect(forward.x, closeTo(-basis.normal.x, 1e-6));
        expect(forward.y, closeTo(-basis.normal.y, 1e-6));
        expect(forward.z, closeTo(-basis.normal.z, 1e-6));
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
            final renderRight = forward.cross(up).normalized();
            final renderUp = renderRight.cross(forward).normalized();

            expect((renderRight - basis.xAxis).length, closeTo(0, 1e-6));
            expect((renderUp - basis.yAxis).length, closeTo(0, 1e-6));

            // The camera's own actual viewing direction must match the
            // basis's *real* handedness, not its raw (always-fixed,
            // flip-independent) normal - that's exactly the bug this test
            // group exists to catch a regression of. Negated (2026-07-22):
            // the camera now views *from* the effectiveNormal side, back
            // through -effectiveNormal - see orientationFacingBasis's own
            // doc comment.
            final effectiveNormal = basis.xAxis.cross(basis.yAxis);
            expect((forward + effectiveNormal).length, closeTo(0, 1e-6));
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
  ///
  /// **2026-07-22**: `right`'s own formula updated to match the corrected
  /// renderer (see this file's own top-of-file doc comment) - the expected
  /// readouts below are deliberately *unchanged*, since `orientationFacingBasis`
  /// was specifically re-derived to keep producing the identical
  /// `renderRight`/`renderUp` result for the same basis (see its own doc
  /// comment) - only its internal target-back/right values, not its
  /// external on-screen contract, changed.
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
      final right = forward.cross(camera.up).normalized();
      final up = right.cross(forward).normalized();

      void expectAxis(vm.Vector3 axis, vm.Vector3 expected) {
        expect(axis.dot(right), closeTo(expected.x, 0.01));
        expect(axis.dot(up), closeTo(expected.y, 0.01));
        expect(axis.dot(towardCamera), closeTo(expected.z, 0.01));
      }

      expectAxis(vm.Vector3(1, 0, 0), expectedXReading);
      expectAxis(vm.Vector3(0, 1, 0), expectedYReading);
      expectAxis(vm.Vector3(0, 0, 1), expectedZReading);
    }

    // The right/up (x/y) components of each reading below are unchanged
    // from before 2026-07-22's camera fix (orientationFacingBasis was
    // specifically re-derived to keep producing the same renderRight/
    // renderUp) - only each reading's `out`/towards-camera (z) component
    // flips sign, since the camera now genuinely sits on the opposite
    // physical side of the plane (see orientationFacingBasis's own doc
    // comment).
    test('XY: flip=true, rotation=1', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.xy, flip: true, rotationQuarterTurns: 1),
        expectedXReading: vm.Vector3(0, 1, 0),
        expectedYReading: vm.Vector3(1, 0, 0),
        expectedZReading: vm.Vector3(0, 0, -1),
      );
    });

    test('XZ: flip=true, rotation=0', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.xz, flip: true, rotationQuarterTurns: 0),
        expectedXReading: vm.Vector3(1, 0, 0),
        expectedYReading: vm.Vector3(0, 0, -1),
        expectedZReading: vm.Vector3(0, 1, 0),
      );
    });

    test('YZ: flip=false, rotation=0 (unchanged - already an exact match)', () {
      expectTriadReadout(
        orientationFacingPlane(ReferencePlaneKind.yz, flip: false, rotationQuarterTurns: 0),
        expectedXReading: vm.Vector3(0, 0, 1),
        expectedYReading: vm.Vector3(1, 0, 0),
        expectedZReading: vm.Vector3(0, 1, 0),
      );
    });
  });
}
