import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/gear/gear_preview_canvas.dart';

/// Follow-up on-device feedback: [GearPreviewCanvas] should show pitch
/// diameter (gear) / length (rack) directly on the preview, and support
/// pinch-zoom/two-finger-pan (`InteractiveViewer`) - both check out here at
/// the widget level; the pinch-zoom gesture itself needs a real multi-touch
/// input to fully exercise (confirmed separately on-device via a
/// click-drag pan, since `InteractiveViewer` handles both gestures through
/// the same recognizer).
void main() {
  testWidgets('shows pitch diameter for a gear preview', (tester) async {
    final preview = GearPreviewDto.fromJson({
      'gear_kind': 'external',
      'outline_points': [
        [1.0, 0.0],
      ],
      'pitch_radius': 20.0,
      'warnings': [],
    });

    await tester.pumpWidget(
      MaterialApp(home: GearPreviewCanvas(preview: preview, showReferenceOverlay: true)),
    );

    expect(find.text('Pitch diameter: 40 mm'), findsOneWidget);
  });

  testWidgets('shows length, not pitch diameter, for a rack preview', (tester) async {
    final preview = GearPreviewDto.fromJson({
      'gear_kind': 'rack',
      'outline_points': [
        [1.0, 0.0],
      ],
      'rack_length': 62.83,
      'warnings': [],
    });

    await tester.pumpWidget(
      MaterialApp(home: GearPreviewCanvas(preview: preview, showReferenceOverlay: true)),
    );

    expect(find.text('Length: 62.83 mm'), findsOneWidget);
    expect(find.textContaining('Pitch diameter'), findsNothing);
  });

  testWidgets('shows no metric label while there is no preview yet', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: GearPreviewCanvas(preview: null, showReferenceOverlay: true)),
    );

    expect(find.textContaining('Pitch diameter'), findsNothing);
    expect(find.textContaining('Length'), findsNothing);
  });

  testWidgets('supports pinch-zoom/pan via InteractiveViewer', (tester) async {
    final preview = GearPreviewDto.fromJson({
      'gear_kind': 'external',
      'outline_points': [
        [1.0, 0.0],
      ],
      'pitch_radius': 20.0,
      'warnings': [],
    });

    await tester.pumpWidget(
      MaterialApp(home: GearPreviewCanvas(preview: preview, showReferenceOverlay: true)),
    );

    expect(find.byType(InteractiveViewer), findsOneWidget);
  });

  testWidgets('outline stroke width stays visually constant as zoom scale changes', (tester) async {
    // A plain axis-aligned square (not a real gear outline), deliberately
    // smaller than the painter's own `maxExtent` floor of `1.0` - the
    // auto-fit scale is then driven by that floor, not by this shape's own
    // size, so its edges sit close to the canvas centre rather than at the
    // usual 85%-of-half-viewport auto-fit margin. That keeps both edges
    // inside the visible viewport even after a 3x zoom centred on that same
    // point - a full-size auto-fit outline's edges would zoom straight off
    // the edge of the view, which is correct panning/zooming behaviour but
    // useless for this test (there'd be nothing left in the scanned column
    // to measure). The top edge is perfectly horizontal, so a vertical
    // pixel scan straight through it measures the outline stroke's true
    // perpendicular thickness directly - the same technique used to
    // confirm this fix's effect via real on-device screenshots (see
    // docs/status.md's dated entry).
    final preview = GearPreviewDto.fromJson({
      'gear_kind': 'external',
      'outline_points': [
        [0.3, 0.3],
        [-0.3, 0.3],
        [-0.3, -0.3],
        [0.3, -0.3],
      ],
      'warnings': [],
    });

    const boxSize = 400.0;
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: boxSize,
            height: boxSize,
            child: RepaintBoundary(
              key: boundaryKey,
              child: GearPreviewCanvas(preview: preview, showReferenceOverlay: false),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // `toImage`/`toByteData` do real (non-fake-clock) async engine work, so
    // must run inside `tester.runAsync` - awaiting them directly under the
    // normal fake-async test zone never completes.
    Future<double> topAndBottomEdgeCoverageMass() async {
      return (await tester.runAsync(() async {
        final boundary = boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        return _verticalWhiteCoverageMass(byteData!, image.width, image.height, image.width ~/ 2);
      }))!;
    }

    final baselineMass = await topAndBottomEdgeCoverageMass();
    expect(baselineMass, greaterThan(0));

    final controller = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;
    // Scales 3x about the viewport's own centre (not the origin) - the
    // shape stays roughly centred, just magnified, matching what a real
    // pinch-zoom gesture does when the user's fingers are centred on the
    // content rather than its top-left corner.
    const center = boxSize / 2;
    controller.value = Matrix4.identity()
      ..translateByDouble(center, center, 0, 1)
      ..scaleByDouble(3.0, 3.0, 3.0, 1)
      ..translateByDouble(-center, -center, 0, 1);
    await tester.pumpAndSettle();

    final zoomedMass = await topAndBottomEdgeCoverageMass();

    // Without the fix, `zoomedMass` would be roughly 3x `baselineMass` (the
    // InteractiveViewer visually scaling an unchanged-in-local-space
    // stroke) - the fix keeps it within 25% of the unzoomed mass.
    expect(zoomedMass, closeTo(baselineMass, baselineMass * 0.25));
  });
}

/// Scans column [x] of an RGBA [byteData] top-to-bottom and sums each
/// pixel's brightness *above the dark background*, normalised to [0, 1] per
/// pixel - a sub-pixel-accurate, anti-aliasing-tolerant stand-in for "how
/// many pixels of white stroke cross this column", robust to a fractional
/// (e.g. 1.1px) stroke width that doesn't land on a whole pixel boundary
/// and so never renders as a single run of pure-white pixels.
double _verticalWhiteCoverageMass(ByteData byteData, int width, int height, int x) {
  const backgroundBrightness = 18 + 18 + 28; // gear_preview_canvas's Color(0xFF12121C)
  const whiteBrightness = 255 * 3;
  var mass = 0.0;
  for (var y = 0; y < height; y++) {
    final offset = (y * width + x) * 4;
    final r = byteData.getUint8(offset);
    final g = byteData.getUint8(offset + 1);
    final b = byteData.getUint8(offset + 2);
    final brightness = r + g + b;
    final coverage = (brightness - backgroundBrightness) / (whiteBrightness - backgroundBrightness);
    if (coverage > 0) mass += coverage;
  }
  return mass;
}
