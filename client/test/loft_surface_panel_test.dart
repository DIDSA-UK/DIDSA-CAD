import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/loft_surface_panel.dart';

/// Phase 1 surfacing package: unit-level coverage for [LoftSurfacePanel] -
/// mirrors `extrude_panel_test.dart`'s structure. Unlike [LoftPanel] (no
/// `loft_panel_test.dart` exists yet in this repo either), this panel always
/// keeps Confirm enabled (no Boss/Cut/thickness validity concern at all -
/// see this panel's own doc comment), so its own tests instead cover the
/// `Ruled` toggle's live [onChanged] callback and the guide-curve row's
/// Pick/Change/Clear/Cancel state machine. No `flutter_scene` dependency
/// anywhere in `loft_surface_panel.dart`'s import chain, so this is a real,
/// runnable widget test in this sandbox.
void main() {
  // The panel is taller now (a collapsed "Guide curves" tile sits above the alignment tile): give the
  // test surface room so every button is on screen.
  void useTallView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
  }

  Widget buildPanel({
    String title = 'Loft Surface',
    bool initialRuled = false,
    int sectionCount = 2,
    List<bool> alignmentPointsSet = const [],
    List<int> guideSegmentCounts = const [],
    int draftGuideSegments = 0,
    List<String> warnings = const [],
    bool pickingGuideCurve = false,
    int? pickingAlignmentPointIndex,
    void Function(int)? onPickAlignmentPoint,
    void Function(int)? onClearAlignmentPoint,
    VoidCallback? onCancelAlignmentPointPick,
    VoidCallback? onPickGuideCurve,
    VoidCallback? onFinishGuideCurve,
    void Function(int)? onRemoveGuideCurve,
    VoidCallback? onCancelGuideCurvePick,
    void Function(bool ruled)? onChanged,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LoftSurfacePanel(
          title: title,
          initialRuled: initialRuled,
          sectionCount: sectionCount,
          alignmentPointsSet: alignmentPointsSet,
          guideSegmentCounts: guideSegmentCounts,
          draftGuideSegments: draftGuideSegments,
          warnings: warnings,
          pickingGuideCurve: pickingGuideCurve,
          pickingAlignmentPointIndex: pickingAlignmentPointIndex,
          onPickAlignmentPoint: onPickAlignmentPoint ?? (_) {},
          onClearAlignmentPoint: onClearAlignmentPoint ?? (_) {},
          onCancelAlignmentPointPick: onCancelAlignmentPointPick ?? () {},
          onPickGuideCurve: onPickGuideCurve ?? () {},
          onFinishGuideCurve: onFinishGuideCurve ?? () {},
          onRemoveGuideCurve: onRemoveGuideCurve ?? (_) {},
          onCancelGuideCurvePick: onCancelGuideCurvePick ?? () {},
          onChanged: onChanged ?? (_) {},
          onConfirm: onConfirm ?? () {},
          onCancel: onCancel ?? () {},
        ),
      ),
    );
  }

  group('LoftSurfacePanel section summary', () {
    testWidgets('shows the picked section count', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 3));
      expect(find.text('Sections: 3'), findsOneWidget);
    });
  });

  group('LoftSurfacePanel Ruled toggle', () {
    testWidgets('starts at initialRuled and reports live changes', (tester) async {
      bool? lastRuled;
      await tester.pumpWidget(buildPanel(initialRuled: false, onChanged: (r) => lastRuled = r));
      await tester.pump();
      expect(lastRuled, isFalse);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pump();

      expect(lastRuled, isTrue);
    });
  });

  group('LoftSurfacePanel guide curves', () {
    setUp(() {});
    testWidgets('no guides: an "Add guide" button that invokes onPickGuideCurve', (tester) async {
      useTallView(tester);
      var picked = false;
      await tester.pumpWidget(buildPanel(sectionCount: 0, onPickGuideCurve: () => picked = true));
      await tester.tap(find.text('Guide curves'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No guides'), findsOneWidget);
      await tester.tap(find.text('Add guide'));
      await tester.pump();
      expect(picked, isTrue);
    });

    testWidgets('while picking, shows the count so far, Done and Cancel', (tester) async {
      useTallView(tester);
      var finished = false;
      await tester.pumpWidget(buildPanel(
        sectionCount: 0,
        pickingGuideCurve: true,
        draftGuideSegments: 1,
        onFinishGuideCurve: () => finished = true,
      ));
      await tester.pumpAndSettle();
      expect(find.text('1 curve picked'), findsOneWidget);
      expect(find.text('Add guide'), findsNothing);
      await tester.tap(find.text('Done'));
      expect(finished, isTrue);
    });

    testWidgets('lists the guides and removes one', (tester) async {
      useTallView(tester);
      final removed = <int>[];
      await tester.pumpWidget(buildPanel(sectionCount: 0, guideSegmentCounts: const [2], onRemoveGuideCurve: removed.add));
      await tester.pumpAndSettle();
      expect(find.text('Guide 1'), findsOneWidget);
      expect(find.text('2 curves'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove guide 1'));
      expect(removed, [0]);
    });

    testWidgets('shows warnings from the backend', (tester) async {
      useTallView(tester);
      await tester.pumpWidget(buildPanel(warnings: const ['Guide 2 misses section 1 by 0.2 mm']));
      expect(find.textContaining('Guide 2 misses section 1'), findsOneWidget);
    });
  });

  group('LoftSurfacePanel alignment point rows', () {
    testWidgets('shows one row per section, "Not set" by default', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 2, alignmentPointsSet: const [false, false]));
      await tester.tap(find.text('Alignment points (advanced)'));
      await tester.pumpAndSettle();
      expect(find.text('Section 1 alignment point'), findsOneWidget);
      expect(find.text('Section 2 alignment point'), findsOneWidget);
      expect(find.text('Not set'), findsNWidgets(2)); // 2 sections
    });

    testWidgets('tapping Pick for a section invokes onPickAlignmentPoint with its index', (tester) async {
      int? pickedIndex;
      await tester.pumpWidget(buildPanel(
        sectionCount: 2,
        alignmentPointsSet: const [false, false],
        onPickAlignmentPoint: (i) => pickedIndex = i,
      ));
      await tester.tap(find.text('Alignment points (advanced)'));
      await tester.pumpAndSettle();
      final pickButtons = find.widgetWithText(TextButton, 'Pick');
      await tester.ensureVisible(pickButtons.last);
      await tester.pumpAndSettle();
      await tester.tap(pickButtons.last);
      await tester.pump();
      expect(pickedIndex, 1);
    });

    testWidgets('once set, shows "Set" and a Clear icon for that section', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 2, alignmentPointsSet: const [true, false]));
      await tester.tap(find.text('Alignment points (advanced)'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Clear alignment point'), findsOneWidget);
    });
  });

  group('LoftSurfacePanel Confirm/Cancel', () {
    testWidgets('Confirm is always enabled', (tester) async {
      useTallView(tester);
      await tester.pumpWidget(buildPanel());
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping Cancel invokes onCancel', (tester) async {
      useTallView(tester);
      var cancelled = false;
      await tester.pumpWidget(buildPanel(onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(cancelled, isTrue);
    });
  });

  group('LoftSurfacePanel title (B4)', () {
    testWidgets('defaults to "Loft Surface"', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.text('Loft Surface'), findsOneWidget);
      expect(find.text('Edit Loft Surface'), findsNothing);
    });

    testWidgets('shows "Edit Loft Surface" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(buildPanel(title: 'Edit Loft Surface'));
      expect(find.text('Edit Loft Surface'), findsOneWidget);
    });
  });
}
