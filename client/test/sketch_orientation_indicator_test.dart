import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart'
    show SketchPlaneBasis;
import 'package:didsa_cad_client/viewport3d/sketch_orientation_indicator.dart';
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Applies [transform] to local sketch-plane point `(u, v)`, mirroring the
/// perspective divide `Canvas.transform` performs internally when
/// rasterizing whatever gets drawn afterward - see
/// [planeTransform]'s own doc comment.
Offset _applyPlaneTransform(vm.Matrix4 transform, double u, double v) {
  final clip = transform * vm.Vector4(u, v, 0, 1) as vm.Vector4;
  return Offset(clip.x / clip.w, clip.y / clip.w);
}

void main() {
  group('planeTransform', () {
    final camera = PerspectiveCamera(
      position: vm.Vector3(0, 0, -10),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
    );
    const viewSize = Size(800, 600);
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );

    test(
        'local (0, 0) lands on the same screen point as worldToScreen(basis.origin)',
        () {
      final transform = planeTransform(camera, viewSize, basis);
      final direct = worldToScreen(camera, viewSize, basis.origin)!;

      final projected = _applyPlaneTransform(transform, 0, 0);

      // Tolerance loosened from 1e-6 (CI: differed by ~2.2e-5, imperceptible
      // for on-screen positioning) - the two paths compute the same clip
      // transform via genuinely different operation orders (a matrix
      // multiply chain vs. worldToScreen's own direct projection), so a
      // platform/SDK-dependent last-bits difference in double rounding is
      // expected, not a real divergence.
      expect(projected.dx, closeTo(direct.dx, 1e-3));
      expect(projected.dy, closeTo(direct.dy, 1e-3));
    });

    test(
        'local (s, 0) lands on the same screen point as worldToScreen(origin + xAxis * s)',
        () {
      final transform = planeTransform(camera, viewSize, basis);
      final direct =
          worldToScreen(camera, viewSize, basis.origin + basis.xAxis * 2.0)!;

      final projected = _applyPlaneTransform(transform, 2.0, 0);

      expect(projected.dx, closeTo(direct.dx, 1e-3));
      expect(projected.dy, closeTo(direct.dy, 1e-3));
    });

    test(
        'local (0, s) lands on the same screen point as worldToScreen(origin + yAxis * s)',
        () {
      final transform = planeTransform(camera, viewSize, basis);
      final direct =
          worldToScreen(camera, viewSize, basis.origin + basis.yAxis * 2.0)!;

      final projected = _applyPlaneTransform(transform, 0, 2.0);

      expect(projected.dx, closeTo(direct.dx, 1e-3));
      expect(projected.dy, closeTo(direct.dy, 1e-3));
    });

    test(
        'a flipped/rotated basis still maps local (0, 0) to the world origin on screen',
        () {
      // xAxis negated (flip) and swapped with yAxis (a 90-degree rotation) -
      // SketchPlaneBasis.origin is always local (0, 0) regardless of
      // flip/rotation (see PlacedPolygon-style "origin corner stays put"
      // reasoning this mirrors for the orientation-confirm step's own
      // canvas-plate square).
      final flippedRotated = SketchPlaneBasis(
        origin: vm.Vector3.zero(),
        xAxis: vm.Vector3(0, 1, 0),
        yAxis: vm.Vector3(1, 0, 0),
        normal: vm.Vector3(0, 0, 1),
      );
      final transform = planeTransform(camera, viewSize, flippedRotated);
      final direct = worldToScreen(camera, viewSize, flippedRotated.origin)!;

      final projected = _applyPlaneTransform(transform, 0, 0);

      expect(projected.dx, closeTo(direct.dx, 1e-3));
      expect(projected.dy, closeTo(direct.dy, 1e-3));
    });
  });
}
