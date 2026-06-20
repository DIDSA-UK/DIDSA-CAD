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
    expect(viewport.zoom, SketchViewport.minZoom);
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

  test('reset returns to default zoom and pan', () {
    final viewport = SketchViewport();
    viewport.zoomAtScreenPoint(const Offset(50, 50), 3, size);
    viewport.panByScreenDelta(const Offset(20, 20));

    viewport.reset();

    expect(viewport.zoom, 1);
    expect(viewport.panOffset, Offset.zero);
  });
}
