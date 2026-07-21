// Promoted from the Spike B (Track 2) B2 prototype
// (b1_tap_test_screen.dart, left in the repo unwired as a reference) into
// real production code for the sketcher restructure's Phase 2. Confirmed
// on-device that this needs zero changes to work: `screenPointToRay`/
// `getViewTransform`/`getFrustum` are all inherited unchanged from the base
// `Camera` class, so ray-based picking (tap-to-place, entity snapping)
// works under orthographic exactly as it does under perspective.
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'orbit_camera.dart';

/// A standard orthographic projection - same `[0,1]` depth-range convention
/// flutter_scene's own `PerspectiveProjection`/`_matrix4Perspective` uses
/// (confirmed by reading that private function), just without the
/// perspective divide (w stays 1). Implements flutter_scene 0.18.1's own
/// documented extension point (`CameraProjection` - see that package's
/// camera.dart: "applications can implement CameraProjection for
/// orthographic or other projections") - no patch or fork needed.
class OrthographicProjection extends CameraProjection {
  OrthographicProjection({required this.halfHeight, this.near = 0.1, this.far = 1000.0});

  /// Half the world-space height of the view volume - the orthographic
  /// equivalent of [PerspectiveProjection.fovRadiansY].
  double halfHeight;
  double near;
  double far;

  @override
  vm.Matrix4 getProjectionMatrix(double aspectRatio) {
    final halfWidth = halfHeight * aspectRatio;
    return vm.Matrix4(
      1.0 / halfWidth, 0.0, 0.0, 0.0, //
      0.0, 1.0 / halfHeight, 0.0, 0.0, //
      0.0, 0.0, 1.0 / (far - near), 0.0, //
      0.0, 0.0, -near / (far - near), 1.0, //
    );
  }
}

/// On-device confirmed (2026-07-22): a Body imported from a labeled
/// SolidWorks STEP file, *and* a fresh Body built entirely inside
/// DIDSA-CAD (Sketch -> Boss), both render as genuine mirror images of
/// reality - confirmed by orbiting a full turn around each; no camera
/// angle ever shows either one correctly. Both stayed self-consistent
/// with hit-testing throughout (tapping the visible, wrong-side geometry
/// always resolved back to itself), which rules out any *data*-level
/// mismatch between what's rendered and what's hit-tested - the two
/// always agree with each other. That combination (self-consistent, yet
/// an un-rotatable mirror against any real external reference) can only
/// come from the view-matrix construction itself, not from world data,
/// not from the backend (`plane_geometry.py`'s sketch-plane basis table
/// is independently hand-verified right-handed - `x_axis cross y_axis ==
/// normal` for all three fixed planes, using the literal standard
/// `(1,0,0)`/`(0,1,0)`/`(0,0,1)` world axes - and `import_geometry.py`/
/// `step_export.py` are both unmodified, vanilla OCCT STEP I/O with no
/// coordinate transform of any kind).
///
/// Read directly against `flutter_scene` 0.18.1's own source
/// (`package:flutter_scene/src/camera.dart`'s private `_matrix4LookAt`,
/// used by its `PerspectiveCamera.getViewMatrix()`) confirms it: that
/// function computes `right = up.cross(forward)` - the wrong
/// cross-product order for a standard right-handed view space (e.g.
/// OpenGL's own `gluLookAt`, `s = cross(f, up)`, uses `forward.cross(up)`
/// instead). `up.cross(forward) = -(forward.cross(up))` is a general
/// vector-algebra identity, true for *any* up/forward, not just a
/// particular case - so this is an exact negation of the standard right
/// vector for every camera orientation, not a one-off sign slip.
/// Concretely verified (forward=(0,0,1), up=(0,1,0)): flutter_scene's own
/// formula gives right=(1,0,0); the standard formula gives right=(-1,0,0)
/// for the identical inputs. This is baked into the view-matrix
/// *construction* itself - no choice of camera position/target/up can
/// compensate for it (negating the `up` input flips both the computed
/// right *and* up together, which is a 180-degree in-plane rotation, not
/// an un-mirror) - exactly matching the reported symptom: a real,
/// un-fixable-by-orbiting mirror.
///
/// This explains the whole history in one shot: `triad.dart`'s own
/// `triadAxes` independently reimplements this *same* (buggy)
/// `up.cross(forward)` formula specifically because it has to match
/// whatever actually renders - and `orientationFacingBasis`
/// (`orbit_camera.dart`) explicitly negates its own target-right vector
/// "because" of this exact bug (see that function's own doc comment,
/// written before this was traced to its root). Every one of those was a
/// correct, working *compensation* for a bug nobody had yet traced back
/// to `flutter_scene` itself - which is also why nothing looked "wrong"
/// from *inside* DIDSA-CAD (every self-authored view was calibrated by
/// eye against this same, consistently-mirrored rendering) until
/// compared against an external, standards-compliant reference (a
/// labeled STEP file's known coordinates, or SolidWorks directly).
///
/// [right] uses the standard `forward.cross(up)` order instead;
/// [correctedUp] is re-derived from *this* [right] the same way
/// flutter_scene's own function re-derives its own `up` - just with the
/// matching corrected order (`right.cross(forward)` instead of
/// `forward.cross(right)`) so it stays orthogonal to both.
///
/// Used for *both* [OrthographicCamera] (below - this file's own
/// `_lookAt` deliberately reimplemented flutter_scene's buggy formula to
/// stay consistent with [PerspectiveCamera] before this was traced; now
/// both share this corrected one instead) and [FixedPerspectiveCamera], a
/// drop-in replacement for flutter_scene's own `PerspectiveCamera` (whose
/// `getViewMatrix()` can't be overridden without subclassing, since it's
/// a `flutter_scene`-internal, unexported function) - see that class
/// below.
vm.Matrix4 correctedLookAt(vm.Vector3 eye, vm.Vector3 target, vm.Vector3 up) {
  final forward = (target - eye).normalized();
  final right = forward.cross(up).normalized();
  final correctedUp = right.cross(forward).normalized();
  return vm.Matrix4(
    right.x, correctedUp.x, forward.x, 0.0, //
    right.y, correctedUp.y, forward.y, 0.0, //
    right.z, correctedUp.z, forward.z, 0.0, //
    -right.dot(eye), -correctedUp.dot(eye), -forward.dot(eye), 1.0, //
  );
}

/// A drop-in replacement for flutter_scene's own `PerspectiveCamera` -
/// identical shape/API - whose only difference is [getViewMatrix] using
/// [correctedLookAt] instead of that package's own mirrored
/// `_matrix4LookAt`. See [correctedLookAt]'s own doc comment for why this
/// exists. [projection] reuses flutter_scene's own [PerspectiveProjection]
/// unchanged - the projection matrix is diagonal/scale-only (confirmed by
/// reading `_matrix4Perspective`) and doesn't affect handedness, only the
/// view matrix does.
class FixedPerspectiveCamera extends Camera {
  FixedPerspectiveCamera({
    this.fovRadiansY = 45 * math.pi / 180,
    required this.position,
    required this.target,
    required this.up,
    this.fovNear = 0.1,
    this.fovFar = 1000.0,
  });

  double fovRadiansY;

  @override
  vm.Vector3 position;
  vm.Vector3 target;
  @override
  vm.Vector3 up;
  double fovNear;
  double fovFar;

  @override
  CameraProjection get projection =>
      PerspectiveProjection(fovRadiansY: fovRadiansY, near: fovNear, far: fovFar);

  @override
  vm.Vector3 get forward => (target - position).normalized();

  @override
  vm.Matrix4 getViewMatrix() => correctedLookAt(position, target, up);
}

/// The orthographic counterpart to `PerspectiveCamera` - same eye/target/up
/// shape, paired with [OrthographicProjection] instead.
class OrthographicCamera extends Camera {
  OrthographicCamera({
    required this.position,
    required this.target,
    required this.up,
    required this.halfHeight,
    this.near = 0.1,
    this.far = 1000.0,
  });

  @override
  vm.Vector3 position;
  vm.Vector3 target;
  @override
  vm.Vector3 up;
  double halfHeight;
  double near;
  double far;

  @override
  vm.Vector3 get forward => (target - position).normalized();

  @override
  CameraProjection get projection => OrthographicProjection(halfHeight: halfHeight, near: near, far: far);

  @override
  vm.Matrix4 getViewMatrix() => correctedLookAt(position, target, up);
}

/// Builds an [OrthographicCamera] matching [orbit]'s current
/// position/target/up - the orthographic counterpart to
/// [OrbitCamera.cameraFor], for call sites (the embedded sketch view) that
/// default to orthographic rather than perspective. Matches perspective's
/// apparent scale at the current orbit distance (half-height = distance *
/// tan(halfFovY), using [OrbitCamera.cameraFor]'s default 45deg vertical
/// FOV) so switching between the two doesn't jarringly resize the view.
OrthographicCamera orthographicCameraFor(OrbitCamera orbit, Size size) {
  final halfHeight = orbit.distance * math.tan(45 * math.pi / 180 / 2);
  return OrthographicCamera(
    position: orbit.position,
    target: orbit.target,
    up: orbit.up,
    halfHeight: halfHeight,
    near: orbit.nearClip,
    far: orbit.farClip,
  );
}
