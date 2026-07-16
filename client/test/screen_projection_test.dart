import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('worldToScreen', () {
    test('projects the camera target to the exact centre of the viewport', () {
      final camera = PerspectiveCamera(
        position: vm.Vector3(0, 0, -10),
        target: vm.Vector3.zero(),
        up: vm.Vector3(0, 1, 0),
      );
      const viewSize = Size(800, 600);

      final screen = worldToScreen(camera, viewSize, vm.Vector3.zero());

      expect(screen, isNotNull);
      expect(screen!.dx, closeTo(400, 1e-6));
      expect(screen.dy, closeTo(300, 1e-6));
    });

    test(
        'is the exact inverse of screenPointToRay at the near plane, for a point directly in view',
        () {
      final camera = PerspectiveCamera(
        position: vm.Vector3(0, 0, -10),
        target: vm.Vector3.zero(),
        up: vm.Vector3(0, 1, 0),
      );
      const viewSize = Size(800, 600);
      const originalScreenPoint = Offset(500, 200);

      final ray = camera.screenPointToRay(originalScreenPoint, viewSize);
      // A point along the ray, well within the frustum - round-tripping it
      // back through worldToScreen should land on the same screen position
      // worldToScreen started from, confirming the two are exact inverses
      // of each other (same view-projection transform, same NDC<->screen
      // mapping, just run in opposite directions).
      final worldPoint = ray.origin + ray.direction.normalized() * 5;

      final roundTripped = worldToScreen(camera, viewSize, worldPoint);

      expect(roundTripped, isNotNull);
      expect(roundTripped!.dx, closeTo(originalScreenPoint.dx, 0.5));
      expect(roundTripped.dy, closeTo(originalScreenPoint.dy, 0.5));
    });

    test(
        'a world point up and to the left of the target projects up-left of screen centre',
        () {
      final camera = PerspectiveCamera(
        position: vm.Vector3(0, 0, -10),
        target: vm.Vector3.zero(),
        up: vm.Vector3(0, 1, 0),
      );
      const viewSize = Size(800, 600);

      final screen = worldToScreen(camera, viewSize, vm.Vector3(-1, 1, 0));

      expect(screen, isNotNull);
      expect(screen!.dx, lessThan(400));
      expect(screen.dy, lessThan(300));
    });

    test('returns null for a world point behind the camera', () {
      final camera = PerspectiveCamera(
        position: vm.Vector3(0, 0, -10),
        target: vm.Vector3.zero(),
        up: vm.Vector3(0, 1, 0),
      );
      const viewSize = Size(800, 600);

      // Far behind the camera's eye position, along its own backward
      // direction.
      final screen = worldToScreen(camera, viewSize, vm.Vector3(0, 0, -50));

      expect(screen, isNull);
    });
  });
}
