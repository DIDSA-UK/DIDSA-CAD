import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';

void main() {
  const size = Size(400, 300);

  test('cameraFor places the camera at distance from target along the default direction', () {
    final camera = OrbitCamera();
    final perspective = camera.cameraFor(size);

    expect(perspective.target, vm.Vector3.zero());
    expect((perspective.position - perspective.target).length, closeTo(camera.distance, 1e-4));
  });

  test('orbitByScreenDelta moves the camera position when dragging right', () {
    final camera = OrbitCamera();
    final initialPosition = camera.cameraFor(size).position.clone();

    camera.orbitByScreenDelta(50, 0);

    expect(camera.cameraFor(size).position, isNot(initialPosition));
  });

  test('orbitByScreenDelta is an exact sign-flip: an equal and opposite drag exactly undoes it', () {
    // Whether "dragging right swings the camera right" (vs. left) is the
    // real-device "does this feel natural" judgment the project brief
    // calls out as needing hands-on confirmation, not something a unit
    // test can settle - but it can confirm the fix is a clean negation
    // (same magnitude, opposite direction) and nothing else. Tested as two
    // separate single-axis drags (rather than one combined horizontal +
    // vertical drag) because pitch is applied about the camera's *current*
    // right axis, which a yaw also rotates - so only a pure horizontal or
    // pure vertical drag, on its own, is guaranteed to exactly invert.
    // vector_math's Quaternion/Vector3 are backed by Float32List (32-bit
    // floats, ~7 significant decimal digits) - on coordinates around 18-30
    // in magnitude that's an absolute rounding noise floor around 1e-6,
    // so the tolerance here is 1e-4 (comfortably above that noise, but far
    // tighter than any real cancellation bug would produce).
    final horizontalOnly = OrbitCamera();
    final initialPosition = horizontalOnly.cameraFor(size).position.clone();
    horizontalOnly.orbitByScreenDelta(50, 0);
    horizontalOnly.orbitByScreenDelta(-50, 0);
    expect(horizontalOnly.cameraFor(size).position.x, closeTo(initialPosition.x, 1e-4));
    expect(horizontalOnly.cameraFor(size).position.y, closeTo(initialPosition.y, 1e-4));
    expect(horizontalOnly.cameraFor(size).position.z, closeTo(initialPosition.z, 1e-4));

    final verticalOnly = OrbitCamera();
    verticalOnly.orbitByScreenDelta(0, -30);
    verticalOnly.orbitByScreenDelta(0, 30);
    expect(verticalOnly.cameraFor(size).position.x, closeTo(initialPosition.x, 1e-4));
    expect(verticalOnly.cameraFor(size).position.y, closeTo(initialPosition.y, 1e-4));
    expect(verticalOnly.cameraFor(size).position.z, closeTo(initialPosition.z, 1e-4));
  });

  test('horizontal orbit always swings about the camera\'s own current up axis, leaving it unchanged', () {
    // Real-device bug: a horizontal drag yawed about the *fixed* world-up
    // axis, which only swings the view the way the drag visually suggests
    // while the camera is still close to right-side-up - once orbited past
    // vertical (the model reads as upside-down), the same drag swings the
    // opposite way on-screen. Yawing about the camera's own *current* up
    // axis instead fixes this structurally rather than via a special-cased
    // sign flip: rotating about a vector can never move that vector, so a
    // pure horizontal drag (dyPixels = 0) must leave [up] exactly fixed,
    // at any orientation - right-side-up or upside-down alike - which is
    // exactly the "still feels horizontal from here" guarantee needed.
    final rightSideUp = OrbitCamera();
    final upBeforeRightSideUp = rightSideUp.cameraFor(size).up.clone();
    rightSideUp.orbitByScreenDelta(50, 0);
    final upAfterRightSideUp = rightSideUp.cameraFor(size).up;
    expect(upAfterRightSideUp.x, closeTo(upBeforeRightSideUp.x, 1e-4));
    expect(upAfterRightSideUp.y, closeTo(upBeforeRightSideUp.y, 1e-4));
    expect(upAfterRightSideUp.z, closeTo(upBeforeRightSideUp.z, 1e-4));

    final upsideDown = OrbitCamera();
    while (upsideDown.cameraFor(size).up.dot(vm.Vector3(0, 1, 0)) >= 0) {
      upsideDown.orbitByScreenDelta(0, -50); // pure vertical drag, tips it past the pole
    }
    expect(upsideDown.cameraFor(size).up.dot(vm.Vector3(0, 1, 0)), lessThan(0));

    final upBeforeUpsideDown = upsideDown.cameraFor(size).up.clone();
    upsideDown.orbitByScreenDelta(50, 0);
    final upAfterUpsideDown = upsideDown.cameraFor(size).up;
    expect(upAfterUpsideDown.x, closeTo(upBeforeUpsideDown.x, 1e-4));
    expect(upAfterUpsideDown.y, closeTo(upBeforeUpsideDown.y, 1e-4));
    expect(upAfterUpsideDown.z, closeTo(upBeforeUpsideDown.z, 1e-4));
  });

  test('orbiting continuously past where the old azimuth/elevation camera used to clamp keeps rotating smoothly', () {
    // A previous azimuth/elevation implementation clamped elevation just
    // shy of the poles and froze there - this is exactly the "gets stuck"
    // bug being fixed. Drive enough cumulative pitch to go well past a
    // single pole (more than pi radians) and confirm the camera keeps
    // producing valid, normally-oriented views the whole way, rather than
    // freezing once some fixed elevation is reached.
    final camera = OrbitCamera();
    var sawDistinctPositions = 0;
    vm.Vector3? lastPosition;
    for (var i = 0; i < 400; i++) {
      camera.orbitByScreenDelta(0, -50); // keep dragging up, tilting further overhead each step
      final position = camera.cameraFor(size).position;

      expect(position.x.isNaN, isFalse);
      expect(position.y.isNaN, isFalse);
      expect(position.z.isNaN, isFalse);
      expect((position - camera.target).length, closeTo(camera.distance, 1e-3));

      final camera2 = camera.cameraFor(size);
      // up must stay a unit vector orthogonal to the view direction at
      // every step - this is exactly what breaks down at a pole for a
      // fixed-world-up, look-at-style camera.
      final direction = (camera2.position - camera2.target).normalized();
      expect(camera2.up.length, closeTo(1, 1e-3));
      expect(camera2.up.dot(direction), closeTo(0, 1e-3));

      if (lastPosition == null || (position - lastPosition).length > 1e-6) {
        sawDistinctPositions++;
      }
      lastPosition = position;
    }
    // 400 steps * 0.5 rad/step (50px * 0.01 sensitivity) is over 200
    // radians of cumulative pitch - if the camera ever got stuck (the old
    // clamp behavior), positions would stop changing partway through.
    expect(sawDistinctPositions, 400);
  });

  test('panByScreenDelta moves the target without changing distance', () {
    final camera = OrbitCamera();
    final initialDistance = camera.distance;

    camera.panByScreenDelta(10, 5);

    expect(camera.target, isNot(vm.Vector3.zero()));
    expect(camera.distance, initialDistance);
  });

  test('panByScreenDelta moves the target in opposite directions for opposite horizontal drags', () {
    // Regression test for the real-device bug where left/right pan was
    // inverted - confirm a leftward and a rightward drag move the target
    // along the camera's right axis in opposite directions.
    final leftDrag = OrbitCamera();
    leftDrag.panByScreenDelta(-10, 0);
    final rightDrag = OrbitCamera();
    rightDrag.panByScreenDelta(10, 0);

    expect(leftDrag.target, isNot(rightDrag.target));
    expect(leftDrag.target.x.sign, isNot(rightDrag.target.x.sign));
  });

  test('zoomByFactor scales distance and is clamped to the min/max range', () {
    final camera = OrbitCamera();

    camera.zoomByFactor(2.0);
    expect(camera.distance, 60);

    camera.zoomByFactor(1000);
    expect(camera.distance, camera.maxDistance);

    camera.zoomByFactor(0.00001);
    expect(camera.distance, camera.minDistance);
  });

  test('setZoomBoundsForRadius scales far/near clip and min/max distance to the body, re-clamping distance', () {
    final camera = OrbitCamera();

    camera.setZoomBoundsForRadius(10);
    // farClip = max(1000, radius * 4) = max(1000, 40) = 1000 for a small body.
    expect(camera.farClip, 1000);
    expect(camera.nearClip, closeTo(0.1, 1e-9)); // farClip / 10000
    expect(camera.minDistance, closeTo(0.2, 1e-9)); // nearClip * 2
    expect(camera.maxDistance, 200); // radius * _maxDistanceRadiusFactor (20)

    // Shrinking the bounds below the camera's current distance (30) must
    // pull it back in immediately, not leave it violating the new max.
    expect(camera.distance, 30);
    camera.setZoomBoundsForRadius(1);
    expect(camera.maxDistance, 20);
    expect(camera.distance, 20);
  });

  test('setZoomBoundsForRadius scales farClip past its floor for a large body', () {
    final camera = OrbitCamera();

    camera.setZoomBoundsForRadius(1000);
    expect(camera.farClip, 4000); // radius * 4, above the 1000 floor
    expect(camera.nearClip, closeTo(0.4, 1e-9)); // farClip / 10000
    expect(camera.minDistance, closeTo(0.8, 1e-9)); // nearClip * 2
  });

  test('setZoomBoundsForRadius falls back to the fixed defaults for a non-positive radius', () {
    final camera = OrbitCamera();

    camera.setZoomBoundsForRadius(10);
    camera.setZoomBoundsForRadius(0);

    expect(camera.minDistance, OrbitCamera.defaultMinDistance);
    expect(camera.maxDistance, OrbitCamera.defaultMaxDistance);
    expect(camera.nearClip, OrbitCamera.defaultNearClip);
    expect(camera.farClip, OrbitCamera.defaultFarClip);
  });

  test('reset returns to the default orbit state', () {
    final camera = OrbitCamera();
    final defaultPosition = camera.cameraFor(size).position.clone();

    camera.orbitByScreenDelta(50, 30);
    camera.panByScreenDelta(10, 10);
    camera.zoomByFactor(2.0);

    camera.reset();

    expect(camera.cameraFor(size).position, defaultPosition);
    expect(camera.distance, 30);
    expect(camera.target, vm.Vector3.zero());
  });

  test('setTarget re-centers the camera and becomes what reset returns to', () {
    // The placeholder box's bounding-box centre isn't the world origin (see
    // boundsOfMesh), so once it's known, "Reset view" must snap back to it
    // rather than to (0,0,0).
    final camera = OrbitCamera();
    final centroid = vm.Vector3(5, 5, 5);

    camera.setTarget(centroid);
    expect(camera.target, centroid);

    camera.orbitByScreenDelta(50, 30);
    camera.panByScreenDelta(10, 10);
    camera.zoomByFactor(2.0);
    camera.reset();

    expect(camera.target, centroid);
  });

  test('reset clamps the default distance into a body-scaled zoom range smaller than it', () {
    // A small body's setZoomBoundsForRadius-derived maxDistance can sit
    // below the fixed default distance (30) reset would otherwise assign -
    // reset must respect the current bounds rather than escape them.
    final camera = OrbitCamera();
    camera.setZoomBoundsForRadius(1); // maxDistance = 20, below the default distance of 30.
    camera.zoomByFactor(0.5);

    camera.reset();

    expect(camera.distance, camera.maxDistance);
  });
}
