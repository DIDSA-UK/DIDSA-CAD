import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/sketch_constraint_overlay.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';
import 'package:flutter/material.dart' show Offset, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  // A flat, axis-aligned XY sketch plane at the world origin, viewed
  // straight-on from +Z - keeps the sketch-local -> screen projection
  // trivial to reason about (an orthographic camera looking down -Z maps
  // sketch (x, y) directly to a predictable screen position).
  final basis = SketchPlaneBasis(
    origin: vm.Vector3.zero(),
    xAxis: vm.Vector3(1, 0, 0),
    yAxis: vm.Vector3(0, 1, 0),
    normal: vm.Vector3(0, 0, 1),
  );
  const viewportSize = Size(800, 600);
  final camera = OrthographicCamera(
    position: vm.Vector3(0, 0, 10),
    target: vm.Vector3.zero(),
    up: vm.Vector3(0, 1, 0),
    halfHeight: 5,
  );

  test('constraintOverlayItemLabelCenter resolves a ConstraintLabelItem to its own midpoint+offset', () {
    const pointItem = ConstraintLabelItem(
      constraintId: 'point',
      selected: false,
      anchorA: (1.0, 0.0),
      anchorB: (1.0, 0.0),
      text: 'V',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    const pairItem = ConstraintLabelItem(
      constraintId: 'pair',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (2.0, 0.0),
      text: 'V',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    // Orthographic projection is affine (no perspective foreshortening) -
    // the midpoint of two projected anchors must equal the projection of
    // their own sketch-local midpoint, regardless of this camera's own
    // exact scale/orientation convention (deliberately not hardcoded here).
    final pointCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, pointItem);
    final pairCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, pairItem);
    expect(pointCenter, isNotNull);
    expect(pairCenter, isNotNull);
    expect(pairCenter!.dx, closeTo(pointCenter!.dx, 1e-6));
    expect(pairCenter.dy, closeTo(pointCenter.dy, 1e-6));
  });

  test('constraintOverlayItemAt finds the item whose label centre is within radius', () {
    const item = ConstraintLabelItem(
      constraintId: 'c0',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (0.0, 0.0),
      text: 'V',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    final center = constraintOverlayItemLabelCenter(camera, viewportSize, basis, item)!;

    expect(constraintOverlayItemAt(camera, viewportSize, basis, [item], center), 'c0');
    expect(
      constraintOverlayItemAt(camera, viewportSize, basis, [item], center + const Offset(5, 5)),
      'c0',
      reason: 'within the default hit radius',
    );
    expect(
      constraintOverlayItemAt(camera, viewportSize, basis, [item], center + const Offset(500, 500)),
      isNull,
      reason: 'far outside the hit radius',
    );
  });

  test('constraintOverlayItemAt returns null for an empty item list', () {
    expect(constraintOverlayItemAt(camera, viewportSize, basis, const [], Offset.zero), isNull);
  });

  test('constraintOverlayItemAt picks the nearer of two overlapping-ish items (reverse/topmost order)', () {
    const near = ConstraintLabelItem(
      constraintId: 'near',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (0.0, 0.0),
      text: 'A',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    const far = ConstraintLabelItem(
      constraintId: 'far',
      selected: false,
      anchorA: (5.0, 5.0),
      anchorB: (5.0, 5.0),
      text: 'B',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    final nearCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, near)!;

    expect(constraintOverlayItemAt(camera, viewportSize, basis, [far, near], nearCenter), 'near');
  });
}
