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

/// flutter_scene's own look-at matrix construction is a private top-level
/// function, not exported - reimplemented here (right = up×forward, realUp
/// = forward×right) rather than depending on package internals.
vm.Matrix4 _lookAt(vm.Vector3 eye, vm.Vector3 target, vm.Vector3 up) {
  final forward = (target - eye).normalized();
  final right = up.cross(forward).normalized();
  final realUp = forward.cross(right).normalized();
  return vm.Matrix4(
    right.x, realUp.x, forward.x, 0.0, //
    right.y, realUp.y, forward.y, 0.0, //
    right.z, realUp.z, forward.z, 0.0, //
    -right.dot(eye), -realUp.dot(eye), -forward.dot(eye), 1.0, //
  );
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
  vm.Matrix4 getViewMatrix() => _lookAt(position, target, up);
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
