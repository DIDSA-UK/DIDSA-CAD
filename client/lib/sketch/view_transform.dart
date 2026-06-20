import 'package:flutter/widgets.dart';

/// A point in sketch-space units (the backend's coordinate system - y-up,
/// origin at the sketch's plane origin), as distinct from a screen [Offset]
/// (pixels, y-down) so the two spaces are never confused.
class SketchCoord {
  final double x;
  final double y;

  const SketchCoord(this.x, this.y);
}

/// Maps between sketch-space units and on-screen pixels, so the rest of the
/// app only has to think in one coordinate space at a time.
class ViewTransform {
  final double pixelsPerUnit;
  final Offset originScreen;

  const ViewTransform({required this.pixelsPerUnit, required this.originScreen});

  Offset sketchToScreen(double x, double y) =>
      Offset(originScreen.dx + x * pixelsPerUnit, originScreen.dy - y * pixelsPerUnit);

  SketchCoord screenToSketch(double screenX, double screenY) => SketchCoord(
        (screenX - originScreen.dx) / pixelsPerUnit,
        -(screenY - originScreen.dy) / pixelsPerUnit,
      );
}
