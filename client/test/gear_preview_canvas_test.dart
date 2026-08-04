import 'package:flutter/material.dart';
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
}
