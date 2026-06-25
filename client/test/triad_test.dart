import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/triad.dart';

void main() {
  group('triadAxes', () {
    test('labels and colors are X/red, Y/green, Z/blue in that order', () {
      final camera = PerspectiveCamera(position: vm.Vector3(0, 0, -5), target: vm.Vector3.zero());
      final axes = triadAxes(camera);

      expect(axes.map((a) => a.label).toList(), ['X', 'Y', 'Z']);
      expect(axes[0].color, triadColorX);
      expect(axes[1].color, triadColorY);
      expect(axes[2].color, triadColorZ);
    });

    test('looking down -Z with +Y up projects Y up on screen and Z towards the camera', () {
      // The simplest case: camera at the origin looking down -Z, up = +Y.
      // [triadAxes] derives its `right`/`up` basis the same way
      // flutter_scene's own `_matrix4LookAt` does (`right =
      // up.cross(forward)`) precisely so the triad's screen directions
      // always agree with how the real scene actually renders - which
      // means world +X projects to *screen-left* here, not the
      // conventionally "intuitive" screen-right (`up.cross(forward)`, not
      // `forward.cross(up)`, is the swapped-handedness choice
      // flutter_scene's matrix itself makes). Y, unaffected by that swap,
      // projects the intuitive way: screen-up.
      final camera = PerspectiveCamera(
        position: vm.Vector3(0, 0, 0),
        target: vm.Vector3(0, 0, -1),
        up: vm.Vector3(0, 1, 0),
      );
      final axes = triadAxes(camera);

      final x = axes.firstWhere((a) => a.label == 'X').direction;
      final y = axes.firstWhere((a) => a.label == 'Y').direction;
      final z = axes.firstWhere((a) => a.label == 'Z').direction;

      expect(x.dx, closeTo(-1, 1e-6));
      expect(x.dy, closeTo(0, 1e-6));
      expect(y.dx, closeTo(0, 1e-6));
      expect(y.dy, closeTo(-1, 1e-6));
      // Z points straight at the camera (the view direction), so it
      // foreshortens to zero length on screen - exactly the "pointing
      // towards/away from camera" cue the task brief calls out.
      expect(z.distance, closeTo(0, 1e-6));
    });

    test('camera position/target distance does not affect the projected directions', () {
      // The triad is orientation-only - moving the camera far from the
      // origin (zoom/pan) must not change the on-screen axis directions,
      // only the actual orbit/pan/zoom state would (via a changed
      // orientation), confirming [triadAxes] ignores translation.
      final near = PerspectiveCamera(position: vm.Vector3(0, 0, -5), target: vm.Vector3.zero());
      final far = PerspectiveCamera(position: vm.Vector3(0, 0, -500), target: vm.Vector3(0, 0, 100));

      final nearAxes = triadAxes(near);
      final farAxes = triadAxes(far);

      for (var i = 0; i < 3; i++) {
        expect(farAxes[i].direction.dx, closeTo(nearAxes[i].direction.dx, 1e-6));
        expect(farAxes[i].direction.dy, closeTo(nearAxes[i].direction.dy, 1e-6));
      }
    });
  });
}
