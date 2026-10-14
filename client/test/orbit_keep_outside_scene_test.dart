import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';

/// The orbit distance is only ever set by Reset view (80 mm until then), so the camera used to orbit INSIDE any part
/// longer than that. `keepOrbitOutsideScene` raises the distance and narrows the lens by the same ratio.
void main() {
  OrbitCamera cameraAround({required double radius, required vm.Vector3 centre, vm.Vector3? target}) {
    final camera = OrbitCamera()..isPerspective = true;
    camera.setTarget(target ?? centre);
    camera.setZoomBoundsForRadius(radius, center: centre);
    return camera;
  }

  double visibleHalfHeightAtTarget(OrbitCamera camera) => camera.distance * math.tan(camera.fovRadiansY / 2);

  vm.Quaternion randomOrientation(math.Random random) => vm.Quaternion.axisAngle(
        vm.Vector3(random.nextDouble() - 0.5, random.nextDouble() - 0.5, random.nextDouble() - 0.5).normalized(),
        random.nextDouble() * 2 * math.pi,
      );

  test('a 1500 mm part: before, the camera can be inside its bounding sphere; after, never, from any orientation', () {
    final centre = vm.Vector3(0, 0, 750);
    final camera = cameraAround(radius: 751, centre: centre);
    expect(camera.distance, 80);
    expect((camera.position - centre).length, lessThan(751)); // the bug: parked inside the part's sphere

    expect(camera.keepOrbitOutsideScene(), isTrue);

    final random = math.Random(3);
    for (var i = 0; i < 400; i++) {
      camera.orientation = randomOrientation(random);
      expect((camera.position - centre).length, greaterThanOrEqualTo(751), reason: 'camera inside the scene sphere');
    }
  });

  test('the world-space window visible at the target (what you are looking at) is unchanged', () {
    final camera = cameraAround(radius: 751, centre: vm.Vector3(0, 0, 750));
    final before = visibleHalfHeightAtTarget(camera);
    camera.keepOrbitOutsideScene();
    expect(visibleHalfHeightAtTarget(camera), closeTo(before, 1e-9));
    expect(camera.fovRadiansY, lessThan(math.pi / 4)); // dollied back, lens narrowed to compensate
    expect(camera.fovRadiansY, greaterThan(0));
  });

  test('pan/zoom sensitivity is unchanged (it is derived from the visible window, not the distance)', () {
    final camera = cameraAround(radius: 751, centre: vm.Vector3(0, 0, 750));
    final before = visibleHalfHeightAtTarget(camera);
    final distanceBefore = camera.distance;
    camera.keepOrbitOutsideScene();
    // _effectiveDistanceForPanSensitivity == distance * tan(fov/2) / tan(default fov/2) in perspective
    expect(visibleHalfHeightAtTarget(camera) / math.tan(math.pi / 8), closeTo(before / math.tan(math.pi / 8), 1e-9));
    expect(camera.distance, greaterThan(distanceBefore));
  });

  test('a small part the camera already clears is left exactly as it was', () {
    final camera = cameraAround(radius: 42, centre: vm.Vector3.zero()); // a 60 mm cube
    final distance = camera.distance;
    final fov = camera.fovRadiansY;
    expect(camera.keepOrbitOutsideScene(), isFalse);
    expect(camera.distance, distance);
    expect(camera.fovRadiansY, fov);
  });

  test('idempotent: a second call changes nothing', () {
    final camera = cameraAround(radius: 751, centre: vm.Vector3(0, 0, 750));
    camera.keepOrbitOutsideScene();
    final distance = camera.distance;
    final fov = camera.fovRadiansY;
    expect(camera.keepOrbitOutsideScene(), isFalse);
    expect(camera.distance, distance);
    expect(camera.fovRadiansY, fov);
  });

  test('a panned target (away from the scene centre) is allowed for: the swing sphere still clears the scene', () {
    final centre = vm.Vector3(0, 0, 750);
    final camera = cameraAround(radius: 751, centre: centre, target: vm.Vector3(300, 0, 750));
    camera.keepOrbitOutsideScene();
    final random = math.Random(5);
    for (var i = 0; i < 400; i++) {
      camera.orientation = randomOrientation(random);
      expect((camera.position - centre).length, greaterThanOrEqualTo(751));
    }
  });

  test('never moves the camera past maxDistance, however far the target has been panned', () {
    final camera = cameraAround(radius: 100, centre: vm.Vector3.zero(), target: vm.Vector3(1e6, 0, 0));
    camera.keepOrbitOutsideScene();
    expect(camera.distance, lessThanOrEqualTo(camera.maxDistance));
    expect(camera.fovRadiansY, greaterThan(0));
    expect(camera.fovRadiansY, lessThanOrEqualTo(camera.maxFovRadiansY));
  });

  test('with no scene yet it does nothing', () {
    final camera = OrbitCamera();
    expect(camera.keepOrbitOutsideScene(), isFalse);
    expect(camera.distance, 80);
  });

  test('stress: 1.5 m up to 1 km parts - clears the scene, window preserved, lens stays valid', () {
    for (final length in [1500.0, 3000, 6000, 12000, 24000, 50000, 100000, 1000000]) {
      final radius = math.sqrt(30 * 30 * 2 + length * length) / 2;
      final centre = vm.Vector3(0, 0, length / 2);
      final camera = cameraAround(radius: radius, centre: centre);
      final window = visibleHalfHeightAtTarget(camera);
      camera.keepOrbitOutsideScene();
      expect(visibleHalfHeightAtTarget(camera), closeTo(window, window * 1e-9), reason: 'length $length');
      expect(camera.fovRadiansY, greaterThan(0), reason: 'length $length');
      for (var i = 0; i < 50; i++) {
        camera.orientation = randomOrientation(math.Random(i));
        expect((camera.position - centre).length, greaterThanOrEqualTo(radius), reason: 'length $length');
      }
    }
  });
}
