import 'dart:math' as math;

import 'package:didsa_cad_client/sketch/sketch_controller.dart';
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

  test(
      'radialDimensionAngleDegrees resolves the sketch-local angle whose projection matches the '
      'desired screen direction - 0deg for rim\'s own direction, 90deg for perp\'s', () {
    const centerScreen = Offset(100, 100);
    const rimScreen = Offset(140, 100); // axisU: (40, 0) -> "rim" is angle 0.
    const perpScreen = Offset(100, 60); // axisV: (0, -40) -> "perp" is angle 90.

    final rimAngle = radialDimensionAngleDegrees(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: perpScreen,
      desiredDirection: const Offset(1, 0), // same direction as axisU itself.
    );
    final perpAngle = radialDimensionAngleDegrees(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: perpScreen,
      desiredDirection: const Offset(0, -1), // same direction as axisV itself.
    );

    expect(rimAngle, closeTo(0.0, 1e-6));
    expect(perpAngle, closeTo(90.0, 1e-6));
  });

  test(
      'radialDimensionAngleDegrees round-trips with radialDimensionTouchPoint: the angle it resolves, '
      'fed back through _rotateSketchPointAroundCenter equivalent math, reproduces the same touch point',
      () {
    const center = (2.0, 1.0);
    const radius = 4.0;
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
    Offset projectPoint((double, double) sketchXY) =>
        worldToScreen(camera, viewportSize, sketchPointToWorld(basis, sketchXY.$1, sketchXY.$2))!;

    final centerScreen = projectPoint(center);
    final rimScreen = projectPoint((center.$1 + radius, center.$2));
    final perpScreen = projectPoint((center.$1, center.$2 + radius));

    const testAngleDegrees = 163.0;
    final testAngleRadians = testAngleDegrees * math.pi / 180.0;
    final trueScreenPoint = projectPoint((
      center.$1 + radius * math.cos(testAngleRadians),
      center.$2 + radius * math.sin(testAngleRadians),
    ));
    final desiredDelta = trueScreenPoint - centerScreen;
    final desiredDirection = desiredDelta / desiredDelta.distance;

    final resolvedAngle = radialDimensionAngleDegrees(
      centerScreen: centerScreen,
      rimScreen: rimScreen,
      perpScreen: perpScreen,
      desiredDirection: desiredDirection,
    );

    expect(resolvedAngle, isNotNull);
    expect(resolvedAngle, closeTo(testAngleDegrees, 1e-2));
  });

  test('radialDimensionAngleDegrees returns null when perpScreen is missing or the vectors are degenerate', () {
    expect(
      radialDimensionAngleDegrees(
        centerScreen: const Offset(100, 100),
        rimScreen: const Offset(140, 100),
        perpScreen: null,
        desiredDirection: const Offset(0, 1),
      ),
      isNull,
    );
    expect(
      radialDimensionAngleDegrees(
        centerScreen: const Offset(100, 100),
        rimScreen: const Offset(140, 100),
        perpScreen: const Offset(160, 100), // collinear - degenerate.
        desiredDirection: const Offset(0, 1),
      ),
      isNull,
    );
  });

  test(
      'bug fix follow-up (on-device feedback: dimension lines "should remain connected to the same '
      'part of the circle while orbiting - currently they slide round"): a ghost\'s default (never '
      'dragged) direction stays anchored to the same fixed point on the circle across two different '
      'camera orientations, instead of drifting because defaultAngleOffsetDegrees used to be applied '
      'as a screen-space rotation', () {
    final basis = SketchPlaneBasis(
      origin: vm.Vector3.zero(),
      xAxis: vm.Vector3(1, 0, 0),
      yAxis: vm.Vector3(0, 1, 0),
      normal: vm.Vector3(0, 0, 1),
    );
    const viewportSize = Size(800, 600);
    // Two genuinely different oblique orientations - not just two points on
    // the same orbit path, to make sure this isn't accidentally passing by
    // coincidence of a shared axis.
    final cameraA = OrthographicCamera(
      position: vm.Vector3(6, 4, 10),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
      halfHeight: 8,
    );
    final cameraB = OrthographicCamera(
      position: vm.Vector3(-3, 9, 5),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
      halfHeight: 8,
    );

    const center = (2.0, 1.0);
    const rim = (6.0, 1.0); // radius 4, rim at sketch-local angle 0.
    const diameterGhost = ConstraintRadialDimensionItem(
      constraintId: 'diameter',
      selected: false,
      center: center,
      rim: rim,
      radius: 4.0,
      isDiameter: true,
      text: '⌀?',
      labelOffset: Offset.zero,
      defaultAngleOffsetDegrees: 50.0, // matches dimensionGhostOverlayItems' own diameter default.
    );

    // The fixed sketch-local point the ghost's default direction should
    // always resolve toward, regardless of camera: rim rotated 50 degrees
    // around center, in sketch-local space.
    const expectedAngle = 50.0 * math.pi / 180.0;
    final expectedSketchPoint = (
      center.$1 + 4.0 * math.cos(expectedAngle),
      center.$2 + 4.0 * math.sin(expectedAngle),
    );

    for (final camera in [cameraA, cameraB]) {
      final centerScreen =
          worldToScreen(camera, viewportSize, sketchPointToWorld(basis, center.$1, center.$2))!;
      final expectedScreen = worldToScreen(
        camera,
        viewportSize,
        sketchPointToWorld(basis, expectedSketchPoint.$1, expectedSketchPoint.$2),
      )!;
      final expectedDelta = expectedScreen - centerScreen;
      final expectedDirection = expectedDelta / expectedDelta.distance;

      final labelCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, diameterGhost)!;
      final actualDelta = labelCenter - centerScreen;
      final actualDirection = actualDelta / actualDelta.distance;

      expect(actualDirection.dx, closeTo(expectedDirection.dx, 1e-3));
      expect(actualDirection.dy, closeTo(expectedDirection.dy, 1e-3));
    }
  });
}
