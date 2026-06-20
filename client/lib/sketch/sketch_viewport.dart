import 'package:flutter/widgets.dart';

import 'view_transform.dart';

/// Mutable pan/zoom state for the sketch canvas - kept separate from
/// [SketchController] because it is purely a view concern, not sketch
/// domain state. Produces a [ViewTransform] for a given canvas size; all
/// panning and zooming only ever adjusts this viewport, never the
/// controller's cursor, which always stays in sketch-space coordinates.
class SketchViewport {
  static const double basePixelsPerUnit = 20;
  static const double minZoom = 0.2;
  static const double maxZoom = 10;

  double zoom = 1;
  Offset panOffset = Offset.zero;

  ViewTransform transformFor(Size size) => ViewTransform(
        pixelsPerUnit: basePixelsPerUnit * zoom,
        originScreen: Offset(size.width / 2, size.height / 2) + panOffset,
      );

  void panByScreenDelta(Offset delta) {
    panOffset += delta;
  }

  /// The single building block both scroll-wheel zoom and pinch-zoom are
  /// built from: scales by [scaleFactor] (clamped to [minZoom]/[maxZoom])
  /// while moving whatever sketch-space point was under [anchorScreen]
  /// before the change to [targetScreen] after it. A plain zoom-in-place
  /// (mouse wheel, single pinch focal point) is the case where
  /// [anchorScreen] and [targetScreen] are the same point.
  void applyAnchoredZoomPan({
    required Offset anchorScreen,
    required Offset targetScreen,
    required double scaleFactor,
    required Size size,
  }) {
    final anchorSketch = transformFor(size).screenToSketch(anchorScreen.dx, anchorScreen.dy);

    zoom = (zoom * scaleFactor).clamp(minZoom, maxZoom);

    final newPixelsPerUnit = basePixelsPerUnit * zoom;
    final centerScreen = Offset(size.width / 2, size.height / 2);
    final originScreen = Offset(
      targetScreen.dx - anchorSketch.x * newPixelsPerUnit,
      targetScreen.dy + anchorSketch.y * newPixelsPerUnit,
    );
    panOffset = originScreen - centerScreen;
  }

  void zoomAtScreenPoint(Offset focalPointScreen, double scaleFactor, Size size) => applyAnchoredZoomPan(
        anchorScreen: focalPointScreen,
        targetScreen: focalPointScreen,
        scaleFactor: scaleFactor,
        size: size,
      );

  void reset() {
    zoom = 1;
    panOffset = Offset.zero;
  }
}
