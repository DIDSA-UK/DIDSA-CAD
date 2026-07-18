import 'dart:math' as math;

import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/sketch_constraint_overlay.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  // Bug fix (on-device feedback: "when I orbit, the radius and diameter
  // dimension lines look disconnected from the circle") - a circle's own
  // screen projection is an ellipse under any non-straight-on view, not a
  // scaled circle. An oblique camera (not looking straight down the
  // sketch plane's own normal) is exactly the case that used to visibly
  // drift: an orthographic camera at this angle still genuinely
  // foreshortens the XY sketch plane on screen.
  final basis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );
  const viewportSize = Size(800, 600);
  final camera = OrthographicCamera(
    position: vm.Vector3(6, 4, 10),
    target: vm.Vector3.zero(),
    up: vm.Vector3(0, 1, 0),
    halfHeight: 8,
  );

  Offset project((double, double) sketchXY) =>
      worldToScreen(camera, viewportSize, sketchPointToWorld(basis, sketchXY.$1, sketchXY.$2))!;

  test(
      'radialDimensionTouchPoint lands exactly on the true projected ellipse at an arbitrary angle, '
      'under an oblique (foreshortening) orthographic camera', () {
    const center = (2.0, 1.0);
    const radius = 4.0;
    final centerScreen = project(center);
    final rimScreen = project((center.$1 + radius, center.$2));
    final perpScreen = project((center.$1, center.$2 + radius));

    // An angle nowhere near the rim (0deg) or perp (90deg) samples - proves
    // the touch point isn't just reproducing one of the two input samples,
    // but genuinely solving for an arbitrary in-between direction.
    for (final testAngleDegrees in [37.0, 128.0, 200.0, 311.0]) {
      final testAngle = testAngleDegrees * math.pi / 180.0;
      final trueScreenPoint = project((
        center.$1 + radius * math.cos(testAngle),
        center.$2 + radius * math.sin(testAngle),
      ));
      final desiredDelta = trueScreenPoint - centerScreen;
      final desiredDirection = desiredDelta / desiredDelta.distance;

      final (touchScreen, direction) = radialDimensionTouchPoint(
        centerScreen: centerScreen,
        rimScreen: rimScreen,
        perpScreen: perpScreen,
        desiredDirection: desiredDirection,
        fallbackRadiusPixels: (rimScreen - centerScreen).distance,
      );

      // Loose-ish tolerance (not 1e-9): the camera/projection pipeline
      // itself round-trips through single-precision (Float32List) matrices
      // internally, not full double precision - this is still tight enough
      // to prove the touch point lands essentially exactly on the true
      // projected circle, nothing like the old approximation's drift.
      expect(touchScreen.dx, closeTo(trueScreenPoint.dx, 1e-2),
          reason: 'angle $testAngleDegrees deg: touch point x should land exactly on the true projected circle');
      expect(touchScreen.dy, closeTo(trueScreenPoint.dy, 1e-2),
          reason: 'angle $testAngleDegrees deg: touch point y should land exactly on the true projected circle');
      expect(direction.dx, closeTo(desiredDirection.dx, 1e-4));
      expect(direction.dy, closeTo(desiredDirection.dy, 1e-4));
    }
  });

  test('radialDimensionTouchPoint falls back to the scalar-circle approximation when perpScreen is null', () {
    const centerScreen = Offset(100, 100);
    const rimScreen = Offset(140, 100);
    const desiredDirection = Offset(0, -1);

    final (touchScreen, direction) = radialDimensionTouchPoint(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: null,
      desiredDirection: desiredDirection,
      fallbackRadiusPixels: 40.0,
    );

    expect(touchScreen, const Offset(100, 60));
    expect(direction, desiredDirection);
  });

  test('radialDimensionTouchPoint falls back when the two conjugate radius vectors are degenerate (edge-on)', () {
    const centerScreen = Offset(100, 100);
    const rimScreen = Offset(140, 100);
    // Collinear with centerScreen->rimScreen - a genuinely edge-on/
    // degenerate projection has no well-defined ellipse to solve against.
    const perpScreen = Offset(160, 100);
    const desiredDirection = Offset(0, 1);

    final (touchScreen, direction) = radialDimensionTouchPoint(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: perpScreen,
      desiredDirection: desiredDirection,
      fallbackRadiusPixels: 40.0,
    );

    expect(touchScreen, const Offset(100, 140));
    expect(direction, desiredDirection);
  });
}
