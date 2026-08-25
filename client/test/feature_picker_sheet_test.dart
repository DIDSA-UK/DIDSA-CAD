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

  /// Bug fix: every section now starts collapsed (previously all but Combine
  /// started expanded) - expands [section] first, then taps [entry] inside
  /// it. Scrolls each into view before tapping: the sheet's two
  /// independently-scrolling columns mean either a section header or its
  /// entries can sit outside the fixed 800x600 test viewport, the same
  /// class of failure earlier CI runs against this sheet already hit twice
  /// (see this file's own git history).
  Future<void> expandAndTap(WidgetTester tester, String section, String entry) async {
    await tester.ensureVisible(find.text(section));
    await tester.tap(find.text(section));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(entry));
    await tester.tap(find.text(entry));
    await tester.pumpAndSettle();
  }

  group('showFeaturePickerSheet', () {
    testWidgets('tapping Extrude resolves FeaturePickerAction.extrude', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Sketch-based', 'Extrude');
      expect(await pendingResult, FeaturePickerAction.extrude);
    });

    testWidgets('C3: tapping Plane resolves FeaturePickerAction.plane', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Reference', 'Plane');
      expect(await pendingResult, FeaturePickerAction.plane);
    });

    testWidgets('on-device feedback: tapping Fillet resolves FeaturePickerAction.fillet', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Modify', 'Fillet');
      expect(await pendingResult, FeaturePickerAction.fillet);
    });

    testWidgets('Prompt E: tapping Chamfer resolves FeaturePickerAction.chamfer', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Modify', 'Chamfer');
      expect(await pendingResult, FeaturePickerAction.chamfer);
    });

    testWidgets('Revolve resolves FeaturePickerAction.revolve', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Sketch-based', 'Revolve');
      expect(await pendingResult, FeaturePickerAction.revolve);
    });

    testWidgets('Sweep resolves FeaturePickerAction.sweep', (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Sketch-based', 'Sweep');
      expect(await pendingResult, FeaturePickerAction.sweep);
    });

    testWidgets(
      'Bug fix: the renamed "Extrude Surface" entry lives in its own Surfacing '
      'section and still resolves FeaturePickerAction.surface',
      (tester) async {
        await openSheet(tester);
        await expandAndTap(tester, 'Surfacing', 'Extrude Surface');
        expect(await pendingResult, FeaturePickerAction.surface);
      },
    );

    testWidgets('Boolean family, first entry: tapping Merge resolves FeaturePickerAction.merge',
        (tester) async {
      await openSheet(tester);
      await expandAndTap(tester, 'Combine', 'Merge');
      expect(await pendingResult, FeaturePickerAction.merge);
    });

    testWidgets('the picker sheet groups entries into collapsible sections, all collapsed by default', (
      tester,
    ) async {
      await openSheet(tester);
      expect(find.text('Sketch-based'), findsOneWidget);
      expect(find.text('Reference'), findsOneWidget);
      expect(find.text('Surfacing'), findsOneWidget);
      expect(find.text('Modify'), findsOneWidget);
      expect(find.text('Repeat'), findsOneWidget);
      expect(find.text('Combine'), findsOneWidget);
      // Bug fix: every section (not just Combine) now starts collapsed -
      // none of their entries are findable until expanded.
      expect(find.text('Extrude'), findsNothing);
      expect(find.text('Plane'), findsNothing);
      expect(find.text('Extrude Surface'), findsNothing);
      expect(find.text('Fillet'), findsNothing);
      expect(find.text('Mirror'), findsNothing);
      expect(find.text('Merge'), findsNothing);
    });

    testWidgets(
      'Bug fix: Reference now holds only Plane - Surface moved into its own '
      'renamed Surfacing section',
      (tester) async {
        await openSheet(tester);
        await tester.ensureVisible(find.text('Reference'));
        await tester.tap(find.text('Reference'));
        await tester.pumpAndSettle();
        expect(find.text('Plane'), findsOneWidget);
        expect(find.text('Surface'), findsNothing);
        expect(find.text('Extrude Surface'), findsNothing);

        await tester.ensureVisible(find.text('Surfacing'));
        await tester.tap(find.text('Surfacing'));
        await tester.pumpAndSettle();
        expect(find.text('Extrude Surface'), findsOneWidget);
      },
    );
  });
}
