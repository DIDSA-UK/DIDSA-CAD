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
    final horizontalOnly = OrbitCamera();
    final initialPosition = horizontalOnly.cameraFor(size).position.clone();
    horizontalOnly.orbitByScreenDelta(50, 0);
    horizontalOnly.orbitByScreenDelta(-50, 0);
    expect(horizontalOnly.cameraFor(size).position.x, closeTo(initialPosition.x, 1e-9));
    expect(horizontalOnly.cameraFor(size).position.y, closeTo(initialPosition.y, 1e-9));
    expect(horizontalOnly.cameraFor(size).position.z, closeTo(initialPosition.z, 1e-9));

    final verticalOnly = OrbitCamera();
    verticalOnly.orbitByScreenDelta(0, -30);
    verticalOnly.orbitByScreenDelta(0, 30);
    expect(verticalOnly.cameraFor(size).position.x, closeTo(initialPosition.x, 1e-9));
    expect(verticalOnly.cameraFor(size).position.y, closeTo(initialPosition.y, 1e-9));
    expect(verticalOnly.cameraFor(size).position.z, closeTo(initialPosition.z, 1e-9));
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
    expect(camera.distance, OrbitCamera.maxDistance);

    camera.zoomByFactor(0.00001);
    expect(camera.distance, OrbitCamera.minDistance);
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
    // The placeholder box's centroid isn't the world origin (see
    // centroidOfMesh), so once it's known, "Reset view" must snap back to
    // it rather than to (0,0,0).
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
}
