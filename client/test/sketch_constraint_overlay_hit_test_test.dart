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

  test(
      'constraintOverlayItemLabelCenter uses a canonical (order-independent) perpendicular '
      'normal for a diagonal ConstraintLinearDimensionItem - on-device feedback ("swiping '
      'up/down moves the dimension in the wrong direction")', () {
    const forward = ConstraintLinearDimensionItem(
      constraintId: 'forward',
      selected: false,
      pointA: (0.0, 0.0),
      pointB: (4.0, 3.0),
      orientation: null,
      text: '5.00',
      labelOffset: Offset.zero,
    );
    const backward = ConstraintLinearDimensionItem(
      constraintId: 'backward',
      selected: false,
      pointA: (4.0, 3.0),
      pointB: (0.0, 0.0),
      orientation: null,
      text: '5.00',
      labelOffset: Offset.zero,
    );
    // Both dimensions measure the same physical pair of Points, just with
    // A/B swapped (the same "which point got created first" ambiguity a
    // real Sketch has no control over) - before the fix, the offset
    // normal's sign flipped with them, so the label rendered on opposite
    // sides depending on arbitrary creation order.
    final forwardCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, forward)!;
    final backwardCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, backward)!;
    expect(forwardCenter.dx, closeTo(backwardCenter.dx, 1e-6));
    expect(forwardCenter.dy, closeTo(backwardCenter.dy, 1e-6));
  });

  test(
      'constraintOverlayItemLabelCenter with a stored sketchLocalOffsetDistance scales with '
      'camera zoom, matching the painter\'s own camera-independent-offset math - on-device-'
      'investigation bug fix: this hit-test used to read the offset through a stale, purely '
      'camera-*dependent* fallback even after the painter itself was fixed to use '
      'sketchLocalOffsetDistance, so regrabbing a dragged dimension broke the instant the '
      'camera moved since the drag', () {
    const item = ConstraintLinearDimensionItem(
      constraintId: 'h',
      selected: false,
      pointA: (0.0, 0.0),
      pointB: (4.0, 0.0),
      orientation: 'horizontal',
      text: '4.00',
      labelOffset: Offset.zero,
      sketchLocalOffsetDistance: 2.0,
    );
    // pointA sits at the camera target, so its own screen position is the
    // same viewport-centre point under any zoom - resolved the same way
    // test 1 above does, to avoid a second import just for this.
    const targetItem = ConstraintLabelItem(
      constraintId: 'origin',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (0.0, 0.0),
      text: '',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    final zoomedIn = OrthographicCamera(
      position: vm.Vector3(0, 0, 10),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
      halfHeight: 5,
    );
    final zoomedOut = OrthographicCamera(
      position: vm.Vector3(0, 0, 10),
      target: vm.Vector3.zero(),
      up: vm.Vector3(0, 1, 0),
      halfHeight: 10, // half the pixels-per-unit of zoomedIn
    );
    final targetScreen = constraintOverlayItemLabelCenter(zoomedIn, viewportSize, basis, targetItem)!;

    final centerIn = constraintOverlayItemLabelCenter(zoomedIn, viewportSize, basis, item)!;
    final centerOut = constraintOverlayItemLabelCenter(zoomedOut, viewportSize, basis, item)!;
    final offsetIn = (centerIn.dy - targetScreen.dy).abs();
    final offsetOut = (centerOut.dy - targetScreen.dy).abs();
    // A stale, camera-*dependent* fallback (ignoring sketchLocalOffsetDistance
    // entirely) would return the exact same fixed-pixel offset regardless of
    // zoom; the correct, camera-independent-distance-scaled offset must
    // halve when pixels-per-unit halves.
    expect(offsetIn, closeTo(offsetOut * 2, 0.5));
    expect(offsetIn, greaterThan(1.0)); // sanity: not degenerately zero either way
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
