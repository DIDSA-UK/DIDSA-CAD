import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s live 2D preview -
/// draws the tooth-outline polyline straight from a [GearPreviewDto]
/// (already computed server-side by `/gear/preview`, no client-side gear
/// math at all - `00-conventions.md`'s "don't duplicate the math
/// client-side" point), plus the reference-circle/line overlay
/// (`showReferenceOverlay`, toggleable, on by default) drawn from the same
/// response.
class GearPreviewCanvas extends StatefulWidget {
  final GearPreviewDto? preview;
  final bool showReferenceOverlay;

  const GearPreviewCanvas({super.key, required this.preview, required this.showReferenceOverlay});

  @override
  State<GearPreviewCanvas> createState() => _GearPreviewCanvasState();
}

class _GearPreviewCanvasState extends State<GearPreviewCanvas> {
  // On-device feedback: promoted from a local variable to a field so the
  // painter can read its current scale on every paint (see
  // `_GearPreviewPainter.zoomScale`) - the fix for line thickness ballooning as
  // the user zooms in (`InteractiveViewer` visually scales its whole child,
  // stroke widths included, since a `CustomPaint`'s own painter has no idea
  // it's being displayed inside one).
  final TransformationController _transformController = TransformationController();

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  /// The one headline metric worth showing directly on the preview rather
  /// than buried in the form: pitch diameter for a gear (external/
  /// internal), overall length for a rack (a rack has no pitch circle at
  /// all - `preview.rackLength` is its own closest equivalent "how big is
  /// this" number). Null while there's nothing valid to report yet.
  String? _metricLabel() {
    final preview = widget.preview;
    if (preview == null) return null;
    if (preview.gearKind == 'rack') {
      final length = preview.rackLength;
      return length == null ? null : 'Length: ${_formatMm(length)} mm';
    }
    final pitchRadius = preview.pitchRadius;
    return pitchRadius == null ? null : 'Pitch diameter: ${_formatMm(pitchRadius * 2)} mm';
  }

  static String _formatMm(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final metricLabel = _metricLabel();
    return Container(
      color: const Color(0xFF12121C),
      child: Stack(
        children: [
          // Pinch-to-zoom/two-finger-pan: `InteractiveViewer` is the stock
          // Flutter widget for exactly this gesture pair (also picks up
          // trackpad pinch/scroll on desktop) - no custom gesture-tracking
          // needed. `boundaryMargin` is generous rather than tight so
          // panning past the auto-fit view isn't immediately clamped.
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5,
              maxScale: 12,
              boundaryMargin: const EdgeInsets.all(2000),
              // On-device feedback (caught by actually running this screen,
              // not by `flutter analyze`/widget tests alone): a childless
              // `CustomPaint` has no intrinsic size and collapses to zero
              // inside this `Row`'s `Expanded` - `Expanded` only forces
              // tight *width*, not height, so with no child the whole
              // canvas silently vanished the moment a real preview loaded
              // (the "enter valid parameters" placeholder `Text` happened
              // to force a size while `preview == null`, masking the bug
              // until a valid preview actually arrived). `SizedBox.expand`
              // makes this fill its parent unconditionally, child or not.
              child: SizedBox.expand(
                // Repaints on every transform change (pinch/scroll/pan) so
                // the painter's own `zoomScale` argument - and therefore its
                // effective stroke width - always matches the current zoom
                // level, not just whatever it was at the last unrelated
                // rebuild (a new preview arriving, the overlay toggle, ...).
                child: AnimatedBuilder(
                  animation: _transformController,
                  builder: (context, child) => CustomPaint(
                    painter: _GearPreviewPainter(
                      preview: widget.preview,
                      showReferenceOverlay: widget.showReferenceOverlay,
                      zoomScale: _transformController.value.getMaxScaleOnAxis(),
                    ),
                    child: child,
                  ),
                  child: widget.preview == null
                      ? const Center(
                          child: Text(
                            'Enter valid parameters to see a preview',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          if (metricLabel != null)
            Positioned(
              top: 8,
              left: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(metricLabel, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// On-device feedback: these read too thick even at 1x zoom against the
// `InteractiveViewer`'s own scaling, before the zoom-invariance fix below
// even comes into play - halved/tightened from the original 2/1.
const double _outlineStrokeWidth = 1.1;
const double _referenceStrokeWidth = 0.6;

class _GearPreviewPainter extends CustomPainter {
  final GearPreviewDto? preview;
  final bool showReferenceOverlay;

  /// The `InteractiveViewer` ancestor's current zoom factor
  /// (`TransformationController.value.getMaxScaleOnAxis()`) - divided into
  /// every stroke width below so line weight stays visually constant as the
  /// user zooms in/out, rather than the `InteractiveViewer` visually
  /// scaling this painter's own already-fixed-width strokes along with
  /// everything else it draws (the root cause: this painter has no idea
  /// it's being displayed inside one, so a "2px" stroke is 2px in *its own*
  /// coordinate space, not 2 screen px, once that space itself is scaled).
  final double zoomScale;

  _GearPreviewPainter({required this.preview, required this.showReferenceOverlay, required this.zoomScale});

  @override
  void paint(Canvas canvas, Size size) {
    final preview = this.preview;
    if (preview == null || preview.outlinePoints.isEmpty) return;

    // Auto-fit scale/pan: every gear/rack kind is centred on the origin in
    // its own local frame (see the backend's `full_gear_profile_points`/
    // `full_rack_profile_points`), so the extent to fit is just the largest
    // |x|/|y| seen across the outline plus (when shown) the overlay's own
    // reference circles/lines - an internal gear's `outer_radius` in
    // particular reaches further out than its own tooth outline does.
    double maxExtent = 1.0;
    for (final point in preview.outlinePoints) {
      maxExtent = math.max(maxExtent, math.max(point[0].abs(), point[1].abs()));
    }
    if (showReferenceOverlay) {
      for (final radius in [
        preview.pitchRadius,
        preview.baseRadius,
        preview.addendumRadius,
        preview.dedendumRadius,
        preview.outerRadius,
      ]) {
        if (radius != null) maxExtent = math.max(maxExtent, radius);
      }
      if (preview.rackLength != null) maxExtent = math.max(maxExtent, preview.rackLength! / 2);
    }

    final scale = (math.min(size.width, size.height) / 2) * 0.85 / maxExtent;
    final center = Offset(size.width / 2, size.height / 2);
    // Flip y: gear_math's +y is "up", Canvas's +y is "down".
    Offset toCanvas(double x, double y) => center + Offset(x * scale, -y * scale);

    if (showReferenceOverlay) _paintReferenceOverlay(canvas, preview, toCanvas);

    final outlinePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _outlineStrokeWidth / zoomScale
      ..color = Colors.white;
    final path = Path()..moveTo(toCanvas(preview.outlinePoints.first[0], preview.outlinePoints.first[1]).dx,
        toCanvas(preview.outlinePoints.first[0], preview.outlinePoints.first[1]).dy);
    for (final point in preview.outlinePoints.skip(1)) {
      final canvasPoint = toCanvas(point[0], point[1]);
      path.lineTo(canvasPoint.dx, canvasPoint.dy);
    }
    path.close();
    canvas.drawPath(path, outlinePaint);
  }

  void _paintReferenceOverlay(
    Canvas canvas,
    GearPreviewDto preview,
    Offset Function(double, double) toCanvas,
  ) {
    final refPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _referenceStrokeWidth / zoomScale;

    // On-device feedback: `canvas.drawCircle` rendered as a filled bounding
    // square rather than a stroked circle under this project's Impeller/
    // software-GL toolchain (Flutter master channel, required for
    // `flutter_scene` compatibility - see `.github/workflows/client-verify.
    // yml`'s own "volatile channel" caveat) - a sampled `Path` (the same
    // primitive the tooth outline above already uses, and already confirmed
    // correct on-device) sidesteps it entirely rather than depending on a
    // draw call this toolchain doesn't render right.
    void drawCircle(double? radius, Color color) {
      if (radius == null) return;
      const sampleCount = 72;
      final path = Path();
      for (var i = 0; i <= sampleCount; i++) {
        final angle = 2 * math.pi * i / sampleCount;
        final point = toCanvas(radius * math.cos(angle), radius * math.sin(angle));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      canvas.drawPath(path, refPaint..color = color);
    }

    drawCircle(preview.outerRadius, Colors.purpleAccent);
    drawCircle(preview.addendumRadius, Colors.lightGreenAccent);
    drawCircle(preview.pitchRadius, Colors.lightBlueAccent);
    drawCircle(preview.baseRadius, Colors.orangeAccent);
    drawCircle(preview.dedendumRadius, Colors.redAccent);

    final rackLength = preview.rackLength;
    if (rackLength != null) {
      final halfSpan = rackLength / 2 + rackLength * 0.1;

      void drawLine(double? y, Color color) {
        if (y == null) return;
        final path = Path()
          ..moveTo(toCanvas(-halfSpan, y).dx, toCanvas(-halfSpan, y).dy)
          ..lineTo(toCanvas(halfSpan, y).dx, toCanvas(halfSpan, y).dy);
        canvas.drawPath(path, refPaint..color = color);
      }

      drawLine(preview.addendumLineY, Colors.lightGreenAccent);
      drawLine(preview.pitchLineY, Colors.lightBlueAccent);
      drawLine(preview.dedendumLineY, Colors.redAccent);
    }
  }

  @override
  bool shouldRepaint(covariant _GearPreviewPainter oldDelegate) =>
      oldDelegate.preview != preview ||
      oldDelegate.showReferenceOverlay != showReferenceOverlay ||
      oldDelegate.zoomScale != zoomScale;
}
