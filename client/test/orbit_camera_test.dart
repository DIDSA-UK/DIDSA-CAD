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

    expect(camera.target, vm.Vector3.zero());
    expect((perspective.position - camera.target).length, closeTo(camera.distance, 1e-4));
  });

  test('isometricOrientation is now the same view as the default cold-start orientation', () {
    final defaultCamera = OrbitCamera();
    final isometricCamera = OrbitCamera()..orientation = OrbitCamera.isometricOrientation();
    expect(
      (defaultCamera.orientation.rotated(vm.Vector3(1, 2, 3)) -
              isometricCamera.orientation.rotated(vm.Vector3(1, 2, 3)))
          .length,
      closeTo(0, 1e-6),
    );
  });

  /// On-device feedback + a numeric calibration round: the default/isometric
  /// orientation must match what actually renders as screen-right/up (the
  /// on-screen triad, `triad.dart`'s `triadAxes`) - not just be internally
  /// self-consistent with [OrbitCamera.right]/[OrbitCamera.up] themselves,
  /// which are the camera's own *local-frame* vectors and (confirmed by
  /// deriving `triadAxes`' formula algebraically) read a *different* sign
  /// for "right" from what the triad actually displays. A previous round's
  /// camera rewrite passed its own self-consistency tests but still looked
  /// mirrored on-device for exactly this reason - this test reproduces
  /// `triadAxes`' own formula directly instead, so a regression here would
  /// have been caught the same way the on-device confidence test caught it.
  ///
  /// **2026-07-22**: `triadRight`'s own formula changed from
  /// `camera.up.cross(forward)` to `forward.cross(camera.up)` - see
  /// `orthographic_camera.dart`'s `correctedLookAt` doc comment for the full
  /// story (flutter_scene's own `PerspectiveCamera` had a confirmed,
  /// genuine left-right mirror baked into its view-matrix construction;
  /// `triad.dart`'s `triadAxes`, which this test reproduces, now uses the
  /// corrected formula to match the corrected renderer). `expectAxis`'s
  /// right-column values are the exact negation of what this test asserted
  /// before that fix (up unchanged - the fix only flips the horizontal
  /// axis) - re-derived from the same identity `up.cross(forward) =
  /// -(forward.cross(up))`, not re-captured on-device, since the *camera
  /// orientation itself* (still the pre-fix isometric quaternion) hasn't
  /// changed, only which screen-direction it now correctly renders as.
  test('the default/isometric orientation matches the on-screen triad exactly', () {
    final camera = OrbitCamera();
    final towardCamera = (camera.position - camera.target).normalized();
    final forward = -towardCamera;
    final triadRight = forward.cross(camera.up).normalized();
    final triadUp = triadRight.cross(forward).normalized();

    void expectAxis(vm.Vector3 axis, double expectedRight, double expectedUp) {
      expect(axis.dot(triadRight), closeTo(expectedRight, 0.01));
      expect(axis.dot(triadUp), closeTo(expectedUp, 0.01));
    }

    expectAxis(vm.Vector3(1, 0, 0), -0.71, 0.41);
    expectAxis(vm.Vector3(0, 1, 0), -0.71, -0.41);
    expectAxis(vm.Vector3(0, 0, 1), 0.0, 0.82);
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
      final direction = (camera2.position - camera.target).normalized();
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
    expect(camera.distance, 160);

    camera.zoomByFactor(1000);
    expect(camera.distance, camera.maxDistance);

    camera.zoomByFactor(0.00001);
    expect(camera.distance, camera.minDistance);
  });

  test('setZoomBoundsForRadius scales far/near clip and min/max distance to the body, re-clamping distance', () {
    final camera = OrbitCamera();

    camera.setZoomBoundsForRadius(10);
    // farClip = max(3000, radius * 4) = max(3000, 40) = 3000 for a small body.
    expect(camera.farClip, 3000);
    expect(camera.nearClip, closeTo(0.3, 1e-9)); // farClip / 10000
    expect(camera.minDistance, closeTo(0.6, 1e-9)); // nearClip * 2
    expect(camera.maxDistance, 200); // radius * _maxDistanceRadiusFactor (20)

    // Shrinking the bounds below the camera's current distance (80) must
    // pull it back in immediately, not leave it violating the new max.
    expect(camera.distance, 80);
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
    expect(camera.distance, 80);
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
    // below the fixed default distance (80) reset would otherwise assign -
    // reset must respect the current bounds rather than escape them.
    final camera = OrbitCamera();
    camera.setZoomBoundsForRadius(1); // maxDistance = 20, below the default distance of 80.
    camera.zoomByFactor(0.5);

    camera.reset();

    expect(camera.distance, camera.maxDistance);
  });

  group('frameRadius (on-device feedback: Reset View too close for a large imported body)', () {
    test('a larger radius requires a larger distance to stay framed', () {
      final camera = OrbitCamera()..setZoomBoundsForRadius(1000);
      camera.frameRadius(10, size);
      final smallDistance = camera.distance;
      camera.frameRadius(100, size);
      final largeDistance = camera.distance;

      expect(largeDistance, greaterThan(smallDistance));
    });

    test('a landscape viewport is height-limited: matches the vertical-FOV-only formula', () {
      final camera = OrbitCamera()..setZoomBoundsForRadius(1000);
      const landscape = Size(400, 100); // aspectRatio 4, comfortably >= 1.
      camera.frameRadius(50, landscape);

      const halfFovY = 45 * 3.141592653589793 / 180 / 2;
      final expected = 50 * 1.2 / (0.4142135623730951 /* tan(halfFovY) */);
      expect(camera.distance, closeTo(expected, 1e-6));
      // Sanity-check the hand-computed tan constant above against dart:math.
      expect(0.4142135623730951, closeTo(math.tan(halfFovY), 1e-9));
    });

    test('a portrait viewport is width-limited: needs more distance than landscape for the same radius', () {
      final camera = OrbitCamera()..setZoomBoundsForRadius(1000);
      const portrait = Size(100, 400); // aspectRatio 0.25.
      const landscape = Size(400, 100);

      camera.frameRadius(50, portrait);
      final portraitDistance = camera.distance;
      camera.frameRadius(50, landscape);
      final landscapeDistance = camera.distance;

      expect(portraitDistance, greaterThan(landscapeDistance));
    });

    test('clamps into the current min/max zoom bounds rather than escaping them', () {
      final camera = OrbitCamera()..setZoomBoundsForRadius(1); // maxDistance = 20.
      camera.frameRadius(1000, size); // Would otherwise demand a huge distance.
      expect(camera.distance, camera.maxDistance);
    });

    test('non-positive radius or empty viewport size is a no-op', () {
      final camera = OrbitCamera();
      final original = camera.distance;
      camera.frameRadius(0, size);
      expect(camera.distance, original);
      camera.frameRadius(-5, size);
      expect(camera.distance, original);
      camera.frameRadius(50, Size.zero);
      expect(camera.distance, original);
    });
  });
}
