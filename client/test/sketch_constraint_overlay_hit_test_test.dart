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

  test(
      'constraintOverlayItemLabelCenter resolves a ConstraintLabelItem with two genuinely distinct '
      'anchors to their own midpoint+offset, with no nudge applied', () {
    const pairItem = ConstraintLabelItem(
      constraintId: 'pair',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (2.0, 0.0),
      text: 'V',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    const midpointItem = ConstraintLabelItem(
      constraintId: 'midpoint',
      selected: false,
      anchorA: (1.0, 0.0),
      anchorB: (1.0, 0.0),
      // anchorA == anchorB deliberately - see the dedicated coincident-nudge
      // test below for why this is NOT expected to land at the same place.
      text: 'unused',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    // Orthographic projection is affine (no perspective foreshortening) -
    // the midpoint of two DISTINCT projected anchors must equal the
    // projection of their own sketch-local midpoint, regardless of this
    // camera's own exact scale/orientation convention (deliberately not
    // hardcoded here) - contrasted against [midpointItem] purely to prove
    // that value, not to assert equality (see below).
    final pairCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, pairItem);
    final midpointCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, midpointItem);
    expect(pairCenter, isNotNull);
    expect(midpointCenter, isNotNull);
    // Bug fix (on-device feedback: "when I drop a point on the origin/
    // another point a coincident constraint is created... I can't see the
    // constraint label"): unlike before this fix, a zero-distance anchor
    // pair (e.g. Coincident) no longer lands exactly on the same spot a
    // real, separated pair with the same midpoint would - see the
    // dedicated nudge test below.
    expect(midpointCenter!.dx, isNot(closeTo(pairCenter!.dx, 1e-6)));
  });

  test(
      'bug fix (on-device feedback: "when I drop a point on the origin/another point a coincident '
      'constraint is created... I can\'t see the constraint label - as it\'s a grounding constraint '
      'the user may want to delete it, so it should be visible"): constraintOverlayItemLabelCenter '
      'nudges a ConstraintLabelItem whose two anchors are exactly coincident away from the shared '
      'Point, but leaves a genuinely separated pair (even one with the same numeric midpoint) alone',
      () {
    const coincidentItem = ConstraintLabelItem(
      constraintId: 'coincident',
      selected: false,
      anchorA: (1.0, 0.0),
      anchorB: (1.0, 0.0),
      text: 'Coinc.',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    const separatedItem = ConstraintLabelItem(
      constraintId: 'separated',
      selected: false,
      anchorA: (0.0, 0.0),
      anchorB: (2.0, 0.0),
      text: 'V',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    final coincidentCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, coincidentItem);
    final separatedCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, separatedItem);
    expect(coincidentCenter, isNotNull);
    expect(separatedCenter, isNotNull);
    // Both anchor pairs project to the same numeric sketch-local midpoint
    // (1.0, 0.0), so any remaining difference is exactly the nudge.
    final nudge = coincidentCenter! - separatedCenter!;
    expect(nudge.distance, greaterThan(5.0)); // clearly off the Point marker, not a rounding wobble
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
    // test 1 above does, to avoid a second import just for this. A tiny
    // (1e-4 sketch unit) anchor separation keeps the midpoint at the origin
    // while staying well clear of [_pairGlyphMidpoint]'s own coincident-
    // nudge threshold (1e-6 *screen* pixels) - an exactly-coincident pair
    // would otherwise pick up that nudge here too, throwing off this test's
    // own zoom-ratio math (unrelated to what this test is actually about).
    const targetItem = ConstraintLabelItem(
      constraintId: 'origin',
      selected: false,
      anchorA: (-0.0001, 0.0),
      anchorB: (0.0001, 0.0),
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

  test(
      'constraintOverlayItemLabelCenter resolves a vertical-oriented ConstraintLinearDimensionItem '
      'the same way regardless of which constrained Point is stored as A vs B - on-device feedback '
      '("vertical dimension can\'t be dragged left/right, up/down is inverted")', () {
    const forward = ConstraintLinearDimensionItem(
      constraintId: 'forward',
      selected: false,
      pointA: (0.0, 0.0),
      pointB: (0.0, 10.0),
      orientation: 'vertical',
      text: '10.00',
      labelOffset: Offset.zero,
      sketchLocalOffsetDistance: 2.0,
    );
    const backward = ConstraintLinearDimensionItem(
      constraintId: 'backward',
      selected: false,
      pointA: (0.0, 10.0),
      pointB: (0.0, 0.0),
      orientation: 'vertical',
      text: '10.00',
      labelOffset: Offset.zero,
      sketchLocalOffsetDistance: 2.0,
    );
    final forwardCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, forward)!;
    final backwardCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, backward)!;
    expect(forwardCenter.dx, closeTo(backwardCenter.dx, 1e-6));
    expect(forwardCenter.dy, closeTo(backwardCenter.dy, 1e-6));
  });

  test(
      'a vertical-oriented ConstraintLinearDimensionItem\'s dimension line sits at a larger '
      'sketch-local X the larger sketchLocalOffsetDistance is (bug fix: it used to be pinned at a '
      'fixed screen-space X regardless of the stored distance)', () {
    const near = ConstraintLinearDimensionItem(
      constraintId: 'near',
      selected: false,
      pointA: (0.0, 0.0),
      pointB: (0.0, 10.0),
      orientation: 'vertical',
      text: '10.00',
      labelOffset: Offset.zero,
      sketchLocalOffsetDistance: 1.0,
    );
    const far = ConstraintLinearDimensionItem(
      constraintId: 'far',
      selected: false,
      pointA: (0.0, 0.0),
      pointB: (0.0, 10.0),
      orientation: 'vertical',
      text: '10.00',
      labelOffset: Offset.zero,
      sketchLocalOffsetDistance: 5.0,
    );
    final nearCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, near)!;
    final farCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, far)!;
    expect(farCenter.dx, greaterThan(nearCenter.dx));
    expect(farCenter.dy, closeTo(nearCenter.dy, 1e-6));
  });

  test(
      'angleDimensionVertexAndRays solves the two Lines\' own infinite-extension intersection even '
      'when they don\'t share an endpoint', () {
    const item = ConstraintAngleDimensionItem(
      constraintId: 'a',
      selected: false,
      line1Start: (0.0, 0.0),
      line1End: (10.0, 0.0),
      line2Start: (5.0, 5.0),
      line2End: (5.0, -5.0),
      text: '90.0°',
      labelOffset: Offset.zero,
    );
    final result = angleDimensionVertexAndRays(item)!;
    expect(result.$1.$1, closeTo(5.0, 1e-9));
    expect(result.$1.$2, closeTo(0.0, 1e-9));
  });

  test('angleDimensionVertexAndRays solves a shared-endpoint vertex directly', () {
    const item = ConstraintAngleDimensionItem(
      constraintId: 'a',
      selected: false,
      line1Start: (0.0, 0.0),
      line1End: (10.0, 0.0),
      line2Start: (0.0, 0.0),
      line2End: (0.0, 10.0),
      text: '90.0°',
      labelOffset: Offset.zero,
    );
    final result = angleDimensionVertexAndRays(item)!;
    expect(result.$1.$1, closeTo(0.0, 1e-9));
    expect(result.$1.$2, closeTo(0.0, 1e-9));
  });

  test('angleDimensionVertexAndRays returns null for (near-)parallel Lines - a degenerate case with '
      'no single well-defined vertex', () {
    const item = ConstraintAngleDimensionItem(
      constraintId: 'a',
      selected: false,
      line1Start: (0.0, 0.0),
      line1End: (10.0, 0.0),
      line2Start: (0.0, 5.0),
      line2End: (10.0, 5.0),
      text: '0.0°',
      labelOffset: Offset.zero,
    );
    expect(angleDimensionVertexAndRays(item), isNull);
  });

  test(
      'constraintOverlayItemLabelCenter resolves a ConstraintAngleDimensionItem near the arc '
      'between its two Lines\' rays, and falls back to the old plain-chip midpoint for the '
      'degenerate (near-parallel) case', () {
    const item = ConstraintAngleDimensionItem(
      constraintId: 'a',
      selected: false,
      line1Start: (0.0, 0.0),
      line1End: (10.0, 0.0),
      line2Start: (0.0, 0.0),
      line2End: (0.0, 10.0),
      text: '90.0°',
      labelOffset: Offset.zero,
    );
    expect(constraintOverlayItemLabelCenter(camera, viewportSize, basis, item), isNotNull);

    const parallelItem = ConstraintAngleDimensionItem(
      constraintId: 'p',
      selected: false,
      line1Start: (0.0, 0.0),
      line1End: (10.0, 0.0),
      line2Start: (0.0, 5.0),
      line2End: (10.0, 5.0),
      text: '0.0°',
      labelOffset: Offset.zero,
    );
    // No vertex to arc around - falls back to the two Lines' own midpoint
    // average, same as the pre-fix plain-chip behavior.
    final fallbackCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, parallelItem)!;
    const midpointItem = ConstraintLabelItem(
      constraintId: 'mid',
      selected: false,
      anchorA: (5.0, 0.0),
      anchorB: (5.0, 5.0),
      text: '',
      labelOffset: Offset.zero,
      plainBlackText: false,
    );
    final expectedCenter = constraintOverlayItemLabelCenter(camera, viewportSize, basis, midpointItem)!;
    expect(fallbackCenter.dx, closeTo(expectedCenter.dx, 1e-6));
    expect(fallbackCenter.dy, closeTo(expectedCenter.dy, 1e-6));
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
