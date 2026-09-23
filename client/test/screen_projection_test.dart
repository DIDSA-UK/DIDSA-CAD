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

  group('worldToScreenFocused', () {
    final camera = PerspectiveCamera(
      position: vm.Vector3(0, 0, -10),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
    );
    const viewSize = Size(800, 600);

    test('a null focusTransform matches worldToScreen exactly (unfocused/root case)', () {
      final direct = worldToScreen(camera, viewSize, vm.Vector3(-1, 1, 0));
      final focused = worldToScreenFocused(camera, viewSize, null, vm.Vector3(-1, 1, 0));

      expect(focused, isNotNull);
      expect(focused!.dx, closeTo(direct!.dx, 1e-9));
      expect(focused.dy, closeTo(direct.dy, 1e-9));
    });

    test('an identity focusTransform matches worldToScreen exactly', () {
      final direct = worldToScreen(camera, viewSize, vm.Vector3(-1, 1, 0));
      final focused =
          worldToScreenFocused(camera, viewSize, vm.Matrix4.identity(), vm.Vector3(-1, 1, 0));

      expect(focused, isNotNull);
      expect(focused!.dx, closeTo(direct!.dx, 1e-9));
      expect(focused.dy, closeTo(direct.dy, 1e-9));
    });

    test('a pure-translation focusTransform composes onto the local point before projecting', () {
      // A local-frame origin, translated 2 units along world +X by
      // focusTransform, should project to the exact same screen point as
      // directly projecting world-space (2, 0, 0) - this is the whole
      // point of the fix: a Sketch's local-frame geometry on a focused
      // sub-Part must land at its real, composed world position.
      final focusTransform = vm.Matrix4.identity()..setTranslation(vm.Vector3(2, 0, 0));
      final direct = worldToScreen(camera, viewSize, vm.Vector3(2, 0, 0));
      final focused = worldToScreenFocused(camera, viewSize, focusTransform, vm.Vector3.zero());

      expect(focused, isNotNull);
      expect(focused!.dx, closeTo(direct!.dx, 1e-6));
      expect(focused.dy, closeTo(direct.dy, 1e-6));
    });

    test('a rotation focusTransform composes correctly, not just translation', () {
      final focusTransform = vm.Matrix4.rotationZ(vm.radians(90));
      // (1, 0, 0) local, rotated 90 degrees about Z, lands at world (0, 1, 0).
      final direct = worldToScreen(camera, viewSize, vm.Vector3(0, 1, 0));
      final focused = worldToScreenFocused(camera, viewSize, focusTransform, vm.Vector3(1, 0, 0));

      expect(focused, isNotNull);
      expect(focused!.dx, closeTo(direct!.dx, 1e-6));
      expect(focused.dy, closeTo(direct.dy, 1e-6));
    });
  });
}
