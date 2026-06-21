import 'dart:math' as math;
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

  test('orbitByScreenDelta increases azimuth when dragging right', () {
    final camera = OrbitCamera();
    final initialAzimuth = camera.azimuth;

    camera.orbitByScreenDelta(50, 0);

    expect(camera.azimuth, greaterThan(initialAzimuth));
  });

  test('orbitByScreenDelta clamps elevation just shy of the poles', () {
    final lookingUp = OrbitCamera();
    lookingUp.orbitByScreenDelta(0, -100000);
    expect(lookingUp.elevation, lessThan(math.pi / 2));
    expect(lookingUp.elevation, greaterThan(math.pi / 2 - 0.1));

    final lookingDown = OrbitCamera();
    lookingDown.orbitByScreenDelta(0, 100000);
    expect(lookingDown.elevation, greaterThan(-math.pi / 2));
    expect(lookingDown.elevation, lessThan(-math.pi / 2 + 0.1));
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
    camera.orbitByScreenDelta(50, 30);
    camera.panByScreenDelta(10, 10);
    camera.zoomByFactor(2.0);

    camera.reset();

    expect(camera.azimuth, math.pi / 4);
    expect(camera.elevation, math.pi / 6);
    expect(camera.distance, 30);
    expect(camera.target, vm.Vector3.zero());
  });
}
