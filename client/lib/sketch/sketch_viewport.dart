import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'view_transform.dart';

/// Mutable pan/zoom state for the sketch canvas - kept separate from
/// [SketchController] because it is purely a view concern, not sketch
/// domain state. Produces a [ViewTransform] for a given canvas size; all
/// panning and zooming only ever adjusts this viewport, never the
/// controller's cursor, which always stays in sketch-space coordinates.
class SketchViewport {
  static const double basePixelsPerUnit = 20;
  static const double maxZoom = 10;

  /// Stage 23b: the maximum zoom-out level must always leave at least this
  /// many mm visible on both axes, regardless of screen size or sketch
  /// content - so the minimum zoom is derived from the canvas size (see
  /// [minZoomFor]) rather than a fixed constant, which only guaranteed a
  /// screen-size-dependent (and on a small canvas, much smaller) extent.
  static const double minVisibleExtentMm = 1000;

  double zoom = 1;
  Offset panOffset = Offset.zero;

  /// The most you're allowed to zoom out for a canvas of [size]: whichever
  /// axis is shorter still shows at least [minVisibleExtentMm].
  double minZoomFor(Size size) {
    final shorterSide = math.min(size.width, size.height);
    return shorterSide / (basePixelsPerUnit * minVisibleExtentMm);
  }

  ViewTransform transformFor(Size size) => ViewTransform(
        pixelsPerUnit: basePixelsPerUnit * zoom,
        originScreen: Offset(size.width / 2, size.height / 2) + panOffset,
      );

  void panByScreenDelta(Offset delta) {
    panOffset += delta;
  }

  /// The single building block both scroll-wheel zoom and pinch-zoom are
  /// built from: scales by [scaleFactor] (clamped to [minZoomFor]/[maxZoom])
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

    zoom = (zoom * scaleFactor).clamp(minZoomFor(size), maxZoom);

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

  /// Stage 23b: fits [boundingBox] (sketch-space geometry extents, see
  /// [SketchController.geometryBoundingBox]) into a canvas of [size] with a
  /// [padding] margin (a fraction of the bounding box's own size added on
  /// each side - the default 0.125 is ~12.5% per side). Falls back to
  /// [reset] when there's no geometry (a null or zero-area box) to fit.
  void zoomToFit(Rect? boundingBox, Size size, {double padding = 0.125}) {
    if (boundingBox == null || (boundingBox.width == 0 && boundingBox.height == 0)) {
      reset();
      return;
    }

    final paddedWidth = boundingBox.width * (1 + 2 * padding);
    final paddedHeight = boundingBox.height * (1 + 2 * padding);

    final scaleCandidates = <double>[
      if (paddedWidth > 0) size.width / paddedWidth,
      if (paddedHeight > 0) size.height / paddedHeight,
    ];
    final fitPixelsPerUnit = scaleCandidates.reduce(math.min);

    zoom = (fitPixelsPerUnit / basePixelsPerUnit).clamp(minZoomFor(size), maxZoom);

    final newPixelsPerUnit = basePixelsPerUnit * zoom;
    final center = boundingBox.center;
    final centerScreen = Offset(size.width / 2, size.height / 2);
    final originScreen = Offset(
      centerScreen.dx - center.dx * newPixelsPerUnit,
      centerScreen.dy + center.dy * newPixelsPerUnit,
    );
    panOffset = originScreen - centerScreen;
  }

  void reset() {
    zoom = 1;
    panOffset = Offset.zero;
  }
}
