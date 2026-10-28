import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

// Desktop sketcher feedback 2026-10-28, item 2: orbiting about the point
// under the mouse sent the model off screen. The pivot was read with
// `ray.at(hit.rayT)`, but a camera's picking ray is not a unit vector while
// rayT is a distance.
void main() {
  const size = Size(800, 600);
  const cursor = Offset(520, 230);

  // A 400 mm square face in the z = 0 plane, as two triangles.
  final face = [
    (vm.Vector3(-200, -200, 0), vm.Vector3(200, -200, 0), vm.Vector3(200, 200, 0)),
    (vm.Vector3(-200, -200, 0), vm.Vector3(200, 200, 0), vm.Vector3(-200, 200, 0)),
  ];

  for (final perspective in [false, true]) {
    group(perspective ? 'perspective' : 'orthographic', () {
      OrbitCamera makeCamera() => OrbitCamera()
        ..isPerspective = perspective
        ..setZoomBoundsForRadius(150, center: vm.Vector3.zero());

      test('the picking ray is not a unit vector, so ray.at(rayT) misses the hit', () {
        final ray = makeCamera().cameraFor(size).screenPointToRay(cursor, size);
        final hit = hitTestFaces(ray, face, const [1, 1])!;
        expect(ray.direction.length, isNot(closeTo(1, 1e-3)));
        expect(ray.at(hit.rayT).z.abs(), greaterThan(1));
      });

      test('pointAtRayDistance lands on the face, under the cursor', () {
        final camera = makeCamera().cameraFor(size);
        final ray = camera.screenPointToRay(cursor, size);
        final pivot = pointAtRayDistance(ray, hitTestFaces(ray, face, const [1, 1])!.rayT);
        expect(pivot.z, closeTo(0, 1e-2));
        final onScreen = worldToScreen(camera, size, pivot)!;
        expect((onScreen - cursor).distance, lessThan(0.5));
      });

      test('orbiting about that pivot keeps it under the cursor', () {
        final orbit = makeCamera();
        final ray = orbit.cameraFor(size).screenPointToRay(cursor, size);
        final pivot = pointAtRayDistance(ray, hitTestFaces(ray, face, const [1, 1])!.rayT);

        orbit.orbitAboutPointByScreenDelta(60, -40, pivot);

        final onScreen = worldToScreen(orbit.cameraFor(size), size, pivot)!;
        expect((onScreen - cursor).distance, lessThan(0.5));
      });
    });
  }
}
