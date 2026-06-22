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
}
