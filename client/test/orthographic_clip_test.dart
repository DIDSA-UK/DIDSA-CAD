import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';

/// An orthographic view clips by depth from the camera POSITION, and the orbit distance stays at its 80 mm default
/// until Reset view - so a long part used to contain the camera and lose everything behind it. The depth range must
/// always span the whole scene sphere along the actual view direction.
void main() {
  OrbitCamera cameraAround({required double radius, required vm.Vector3 centre, vm.Vector3? target}) {
    final camera = OrbitCamera()..isPerspective = false;
    camera.setTarget(target ?? centre);
    camera.setZoomBoundsForRadius(radius, center: centre);
    return camera;
  }

  void expectSphereInsideDepthRange(OrbitCamera camera, double radius, vm.Vector3 centre) {
    final ortho = orthographicCameraFor(camera, const Size(1080, 2340));
    final projection = ortho.projection as OrthographicProjection;
    final forward = (camera.target - camera.position).normalized();
    final centreDepth = (centre - camera.position).dot(forward);
    expect(projection.near, lessThanOrEqualTo(centreDepth - radius), reason: 'near plane cuts into the scene');
    expect(projection.far, greaterThanOrEqualTo(centreDepth + radius), reason: 'far plane cuts into the scene');
  }

  test('a 1500 mm part (camera parked inside it at the default 80 mm) is never depth-clipped from any orientation', () {
    final centre = vm.Vector3(0, 0, 750);
    final camera = cameraAround(radius: 751, centre: centre);
    expect(camera.distance, 80); // the precondition: the camera really is inside the part
    final random = math.Random(7);
    for (var i = 0; i < 300; i++) {
      camera.orientation = vm.Quaternion.axisAngle(
        vm.Vector3(random.nextDouble() - 0.5, random.nextDouble() - 0.5, random.nextDouble() - 0.5).normalized(),
        random.nextDouble() * 2 * math.pi,
      );
      expectSphereInsideDepthRange(camera, 751, centre);
    }
  });

  test('end-on views (along the part\'s own axis) keep the whole part in range', () {
    final centre = vm.Vector3(0, 0, 750);
    final camera = cameraAround(radius: 751, centre: centre);
    for (final axis in [vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0), vm.Vector3(0, 0, 1)]) {
      for (final angle in [0.0, math.pi / 2, math.pi, 3 * math.pi / 2]) {
        camera.orientation = vm.Quaternion.axisAngle(axis, angle);
        expectSphereInsideDepthRange(camera, 751, centre);
      }
    }
  });

  test('an Occurrence far from the camera target (a small host plate, a long part off to one side) stays in range', () {
    final occurrenceCentre = vm.Vector3(300, 0, 650);
    final camera = cameraAround(radius: 777, centre: occurrenceCentre, target: vm.Vector3(0, 0, 10));
    final random = math.Random(11);
    for (var i = 0; i < 300; i++) {
      camera.orientation = vm.Quaternion.axisAngle(
        vm.Vector3(random.nextDouble() - 0.5, random.nextDouble() - 0.5, random.nextDouble() - 0.5).normalized(),
        random.nextDouble() * 2 * math.pi,
      );
      expectSphereInsideDepthRange(camera, 777, occurrenceCentre);
    }
  });

  test('stress: 1.5 m up to 1 km parts, camera at the default distance, always in range', () {
    for (final length in [1500.0, 3000, 6000, 12000, 24000, 50000, 100000, 1000000]) {
      final radius = math.sqrt(30 * 30 * 2 + length * length) / 2;
      final centre = vm.Vector3(0, 0, length / 2);
      final camera = cameraAround(radius: radius, centre: centre);
      for (final angle in [0.0, 0.7, 1.4, 2.1, 2.8]) {
        camera.orientation = vm.Quaternion.axisAngle(vm.Vector3(1, 1, 0).normalized(), angle);
        expectSphereInsideDepthRange(camera, radius, centre);
      }
    }
  });

  test('the depth range is only ever widened - a camera well outside a small part keeps its tight near plane', () {
    final centre = vm.Vector3.zero();
    final camera = cameraAround(radius: 20, centre: centre);
    camera.distance = 200;
    final ortho = orthographicCameraFor(camera, const Size(800, 600));
    final projection = ortho.projection as OrthographicProjection;
    expect(projection.near, lessThanOrEqualTo(camera.effectiveNearClip));
    expect(projection.far, greaterThanOrEqualTo(camera.effectiveFarClip));
  });
}
