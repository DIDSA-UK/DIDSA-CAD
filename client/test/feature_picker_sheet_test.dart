import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/feature_picker_sheet.dart';

/// No `flutter_scene` dependency anywhere in `feature_picker_sheet.dart`'s
/// import chain, so this is a real, runnable widget test in this sandbox,
/// same as `create_plane_panel_test.dart`.
void main() {
  Future<FeaturePickerAction?>? pendingResult;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pendingResult = showFeaturePickerSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showFeaturePickerSheet', () {
    testWidgets('tapping Extrude resolves FeaturePickerAction.extrude', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Extrude'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.extrude);
    });

    testWidgets('C3: tapping Plane resolves FeaturePickerAction.plane', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Plane'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.plane);
    });

    testWidgets('on-device feedback: tapping Fillet resolves FeaturePickerAction.fillet', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Fillet'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.fillet);
    });

    testWidgets('Prompt E: tapping Chamfer resolves FeaturePickerAction.chamfer', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Chamfer'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.chamfer);
    });

    testWidgets('Revolve resolves FeaturePickerAction.revolve', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Revolve'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.revolve);
    });

    testWidgets('Sweep resolves FeaturePickerAction.sweep', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Sweep'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.sweep);
    });

    testWidgets('Surface resolves FeaturePickerAction.surface', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Surface'));
      await tester.pumpAndSettle();
      expect(await pendingResult, FeaturePickerAction.surface);
    });

    testWidgets('the picker sheet groups entries into collapsible sections', (tester) async {
      await openSheet(tester);
      expect(find.text('Sketch-based'), findsOneWidget);
      expect(find.text('Reference'), findsOneWidget);
      expect(find.text('Modify'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
      expect(find.text('Combine'), findsOneWidget);
      // Reference groups Plane and Surface together.
      expect(find.text('Plane'), findsOneWidget);
      expect(find.text('Surface'), findsOneWidget);
      // Repeat groups Mirror and Pattern together - each entry's own label
      // still resolves unambiguously now that the section itself isn't
      // also named "Pattern".
      expect(find.text('Mirror'), findsOneWidget);
      expect(find.text('Pattern'), findsOneWidget);
    });
  });
}
