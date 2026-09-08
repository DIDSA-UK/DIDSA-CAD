import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/sketch_viewport.dart';

void main() {
  const size = Size(400, 300);

  test('transformFor uses the base scale and a centered origin at default zoom/pan', () {
    final viewport = SketchViewport();
    final transform = viewport.transformFor(size);

    expect(transform.pixelsPerUnit, SketchViewport.basePixelsPerUnit);
    expect(transform.originScreen, const Offset(200, 150));
  });

  test('panByScreenDelta shifts the origin without touching zoom', () {
    final viewport = SketchViewport();
    viewport.panByScreenDelta(const Offset(10, -5));

    final transform = viewport.transformFor(size);
    expect(transform.originScreen, const Offset(210, 145));
    expect(viewport.zoom, 1);
  });

  test('zoomAtScreenPoint keeps the sketch point under the focal point fixed on screen', () {
    final viewport = SketchViewport();
    const focal = Offset(120, 80);

    final before = viewport.transformFor(size);
    final sketchUnderFocal = before.screenToSketch(focal.dx, focal.dy);

    viewport.zoomAtScreenPoint(focal, 2.0, size);

    final after = viewport.transformFor(size);
    final screenOfSamePoint = after.sketchToScreen(sketchUnderFocal.x, sketchUnderFocal.y);

    expect(screenOfSamePoint.dx, closeTo(focal.dx, 1e-9));
    expect(screenOfSamePoint.dy, closeTo(focal.dy, 1e-9));
    expect(viewport.zoom, 2.0);
  });

  test('zoom is clamped to the min/max range', () {
    final viewport = SketchViewport();

    viewport.zoomAtScreenPoint(Offset.zero, 1000, size);
    expect(viewport.zoom, SketchViewport.maxZoom);

    viewport.zoomAtScreenPoint(Offset.zero, 0.0001, size);
    expect(viewport.zoom, viewport.minZoomFor(size));
  });

  test('minZoomFor always leaves at least 1000mm visible on the shorter axis', () {
    final viewport = SketchViewport();

    for (final testSize in [size, const Size(1200, 800), const Size(100, 2000)]) {
      final minZoom = viewport.minZoomFor(testSize);
      final shorterSide = testSize.width < testSize.height ? testSize.width : testSize.height;
      final visibleExtent = shorterSide / (SketchViewport.basePixelsPerUnit * minZoom);
      expect(visibleExtent, closeTo(SketchViewport.minVisibleExtentMm, 1e-9));
    }
  });

  test('zoomToFit centers the bounding box and fits it within the viewport with padding', () {
    final viewport = SketchViewport();
    const box = Rect.fromLTRB(0, 0, 100, 50);

    viewport.zoomToFit(box, size);

    final transform = viewport.transformFor(size);
    final center = transform.sketchToScreen(50, 25);
    expect(center.dx, closeTo(200, 1e-9));
    expect(center.dy, closeTo(150, 1e-9));

    // The padded box (12.5% margin per side) must fit entirely on screen.
    final topLeft = transform.sketchToScreen(0, 50);
    final bottomRight = transform.sketchToScreen(100, 0);
    expect(topLeft.dx, greaterThanOrEqualTo(0));
    expect(topLeft.dy, greaterThanOrEqualTo(0));
    expect(bottomRight.dx, lessThanOrEqualTo(size.width));
    expect(bottomRight.dy, lessThanOrEqualTo(size.height));
  });

  test('zoomToFit falls back to reset when there is no geometry', () {
    final viewport = SketchViewport();
    viewport.zoomAtScreenPoint(const Offset(50, 50), 3, size);
    viewport.panByScreenDelta(const Offset(20, 20));

    viewport.zoomToFit(null, size);

    expect(viewport.zoom, 1);
    expect(viewport.panOffset, Offset.zero);
  });

  test('applyAnchoredZoomPan moves the anchor sketch point to the target screen position', () {
    final viewport = SketchViewport();
    const anchor = Offset(150, 100);
    const target = Offset(180, 130);

    final before = viewport.transformFor(size);
    final anchorSketch = before.screenToSketch(anchor.dx, anchor.dy);

    viewport.applyAnchoredZoomPan(anchorScreen: anchor, targetScreen: target, scaleFactor: 1.5, size: size);

    final after = viewport.transformFor(size);
    final screenOfAnchorPoint = after.sketchToScreen(anchorSketch.x, anchorSketch.y);

    expect(screenOfAnchorPoint.dx, closeTo(target.dx, 1e-9));
    expect(screenOfAnchorPoint.dy, closeTo(target.dy, 1e-9));
    expect(viewport.zoom, 1.5);
  });

  // Bug fix (on-device feedback: "zoom is clamped so the user cannot see
  // the whole sketch - auto fit works but as soon as the user tries to
  // change the zoom level, it goes to the clamped value"): a sketch large
  // enough that zoomToFit must go below minZoomFor to show it all used to
  // snap straight back up to minZoomFor on the very next manual zoom -
  // see effectiveMinZoomFor's own doc comment.
  test('a manual zoom after zoomToFit never clamps tighter than the fit needed, on a large sketch', () {
    final viewport = SketchViewport();
    // Large enough (relative to a 400x300 canvas) that its own fit zoom is
    // well below minZoomFor(size).
    const box = Rect.fromLTRB(0, 0, 5000, 3750);

    viewport.zoomToFit(box, size);
    final fitZoom = viewport.zoom;
    expect(fitZoom, lessThan(viewport.minZoomFor(size)));

    // A small manual zoom-in, with the sketch's own bounding box supplied
    // (as the real canvas now always does) must not jump back up to the
    // flat minZoomFor floor - it should still land near the fit zoom.
    viewport.applyAnchoredZoomPan(
      anchorScreen: const Offset(200, 150),
      targetScreen: const Offset(200, 150),
      scaleFactor: 1.01,
      size: size,
      contentBoundingBox: box,
    );

    expect(viewport.zoom, closeTo(fitZoom * 1.01, 1e-9));
    expect(viewport.zoom, lessThan(viewport.minZoomFor(size)));
  });

  test('effectiveMinZoomFor never raises the floor above minZoomFor for a small sketch', () {
    final viewport = SketchViewport();
    const smallBox = Rect.fromLTRB(0, 0, 10, 10);

    expect(viewport.effectiveMinZoomFor(size, smallBox), viewport.minZoomFor(size));
    expect(viewport.effectiveMinZoomFor(size, null), viewport.minZoomFor(size));
  });

  test('reset returns to default zoom and pan', () {
    final viewport = SketchViewport();
    viewport.zoomAtScreenPoint(const Offset(50, 50), 3, size);
    viewport.panByScreenDelta(const Offset(20, 20));

    viewport.reset();

    expect(viewport.zoom, 1);
    expect(viewport.panOffset, Offset.zero);
  });
}
