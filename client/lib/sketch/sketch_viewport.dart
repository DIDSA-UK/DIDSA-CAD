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

  /// Stage 23b: the maximum *manual* zoom-out level (scroll-wheel/pinch, via
  /// [applyAnchoredZoomPan]) must always leave at least this many mm visible
  /// on both axes, regardless of screen size or sketch content - so the
  /// minimum zoom is derived from the canvas size (see [minZoomFor]) rather
  /// than a fixed constant, which only guaranteed a screen-size-dependent
  /// (and on a small canvas, much smaller) extent. This floor exists so a
  /// sparse/empty sketch can't be scrolled out into meaningless empty space
  /// - it deliberately does NOT apply to [zoomToFit], which must always be
  /// able to show the full extent of whatever geometry actually exists, no
  /// matter how large (a multi-metre floor plan included).
  static const double minVisibleExtentMm = 1000;

  double zoom = 1;
  Offset panOffset = Offset.zero;

  /// The most you're allowed to *manually* zoom out for a canvas of [size]:
  /// whichever axis is shorter still shows at least [minVisibleExtentMm].
  /// Not used by [zoomToFit] - see [minVisibleExtentMm]'s own doc comment.
  double minZoomFor(Size size) {
    final shorterSide = math.min(size.width, size.height);
    return shorterSide / (basePixelsPerUnit * minVisibleExtentMm);
  }

  /// Bug fix (on-device feedback: "zoom is clamped so the user cannot see
  /// the whole sketch - auto fit works but as soon as the user tries to
  /// change the zoom level, it goes to the clamped value"): [minZoomFor]'s
  /// flat, canvas-size-derived floor was never widened for a sketch whose
  /// own content needs to be zoomed out further than that to fit - so
  /// [zoomToFit] (deliberately unclamped by [minZoomFor] - see that
  /// method's own doc comment) could leave [zoom] *below* [minZoomFor],
  /// and the very next manual zoom (even a pinch trying to zoom in a
  /// little) immediately snapped [zoom] back up to [minZoomFor] via
  /// [applyAnchoredZoomPan]'s own `.clamp(minZoomFor(size), maxZoom)` -
  /// discarding the fit and hiding part of the sketch again.
  ///
  /// The real floor for manual zoom is therefore never tighter than
  /// whatever [boundingBox] itself needs to stay fully visible: this
  /// returns `min(minZoomFor(size), the zoom [zoomToFit] would have
  /// chosen for boundingBox)`, so a manual zoom can still never scroll a
  /// sparse/empty sketch into meaningless empty space (this only ever
  /// *lowers* the floor, never raises it above [minZoomFor]), but also
  /// never re-clamps a large sketch tighter than the fit that just made it
  /// fully visible. `boundingBox == null` (no geometry yet) falls back to
  /// the plain [minZoomFor] floor, matching [zoomToFit]'s own behaviour in
  /// that case.
  double effectiveMinZoomFor(Size size, Rect? boundingBox) {
    final flatFloor = minZoomFor(size);
    final fitZoom = _fitZoomFor(boundingBox, size);
    if (fitZoom == null) return flatFloor;
    return math.min(flatFloor, fitZoom);
  }

  /// The zoom level [zoomToFit] would choose for [boundingBox] in a canvas
  /// of [size] - shared by [zoomToFit] itself and [effectiveMinZoomFor]
  /// above, so the two can never drift apart. Returns `null` for the same
  /// "nothing to fit" cases [zoomToFit] falls back to [reset] for.
  double? _fitZoomFor(Rect? boundingBox, Size size, {double padding = 0.125}) {
    if (boundingBox == null || (boundingBox.width == 0 && boundingBox.height == 0)) return null;

    final paddedWidth = boundingBox.width * (1 + 2 * padding);
    final paddedHeight = boundingBox.height * (1 + 2 * padding);

    final scaleCandidates = <double>[
      if (paddedWidth > 0) size.width / paddedWidth,
      if (paddedHeight > 0) size.height / paddedHeight,
    ];
    if (scaleCandidates.isEmpty) return null;
    final fitPixelsPerUnit = scaleCandidates.reduce(math.min);
    return math.min(fitPixelsPerUnit / basePixelsPerUnit, maxZoom);
  }

  ViewTransform transformFor(Size size) => ViewTransform(
        pixelsPerUnit: basePixelsPerUnit * zoom,
        originScreen: Offset(size.width / 2, size.height / 2) + panOffset,
      );

  void panByScreenDelta(Offset delta) {
    panOffset += delta;
  }

  /// The single building block both scroll-wheel zoom and pinch-zoom are
  /// built from: scales by [scaleFactor] (clamped to
  /// [effectiveMinZoomFor]/[maxZoom]) while moving whatever sketch-space
  /// point was under [anchorScreen] before the change to [targetScreen]
  /// after it. A plain zoom-in-place (mouse wheel, single pinch focal
  /// point) is the case where [anchorScreen] and [targetScreen] are the
  /// same point.
  ///
  /// [contentBoundingBox] (the current sketch's own geometry extents, same
  /// value [zoomToFit] is called with) widens the manual-zoom-out floor
  /// past [minZoomFor] whenever the content itself needs it - see
  /// [effectiveMinZoomFor]'s own doc comment for the bug this fixes.
  /// Passing `null` (a caller with no bounding box handy) falls back to
  /// the plain [minZoomFor] floor, the pre-fix behaviour.
  void applyAnchoredZoomPan({
    required Offset anchorScreen,
    required Offset targetScreen,
    required double scaleFactor,
    required Size size,
    Rect? contentBoundingBox,
  }) {
    final anchorSketch = transformFor(size).screenToSketch(anchorScreen.dx, anchorScreen.dy);

    zoom = (zoom * scaleFactor).clamp(effectiveMinZoomFor(size, contentBoundingBox), maxZoom);

    final newPixelsPerUnit = basePixelsPerUnit * zoom;
    final centerScreen = Offset(size.width / 2, size.height / 2);
    final originScreen = Offset(
      targetScreen.dx - anchorSketch.x * newPixelsPerUnit,
      targetScreen.dy + anchorSketch.y * newPixelsPerUnit,
    );
    panOffset = originScreen - centerScreen;
  }

  void zoomAtScreenPoint(Offset focalPointScreen, double scaleFactor, Size size, {Rect? contentBoundingBox}) =>
      applyAnchoredZoomPan(
        anchorScreen: focalPointScreen,
        targetScreen: focalPointScreen,
        scaleFactor: scaleFactor,
        size: size,
        contentBoundingBox: contentBoundingBox,
      );

  /// Stage 23b: fits [boundingBox] (sketch-space geometry extents, see
  /// [SketchController.geometryBoundingBox]) into a canvas of [size] with a
  /// [padding] margin (a fraction of the bounding box's own size added on
  /// each side - the default 0.125 is ~12.5% per side). Falls back to
  /// [reset] when there's no geometry (a null or zero-area box) to fit.
  ///
  /// Only clamped against [maxZoom] (so a tiny sketch doesn't zoom in past
  /// what's useful) - deliberately NOT clamped against [minZoomFor], which
  /// exists solely to bound *manual* zoom-out on sparse content (see
  /// [minVisibleExtentMm]'s doc comment). A fit must always be able to show
  /// the whole of whatever was actually drawn, however large.
  void zoomToFit(Rect? boundingBox, Size size, {double padding = 0.125}) {
    final fitZoom = _fitZoomFor(boundingBox, size, padding: padding);
    if (fitZoom == null || boundingBox == null) {
      reset();
      return;
    }

    zoom = fitZoom;

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
