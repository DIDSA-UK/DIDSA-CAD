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
  Widget buildPanel({
    String title = 'Loft Surface',
    bool initialRuled = false,
    int sectionCount = 2,
    List<bool> alignmentPointsSet = const [],
    bool guideCurveSet = false,
    bool pickingGuideCurve = false,
    int? pickingAlignmentPointIndex,
    void Function(int)? onPickAlignmentPoint,
    void Function(int)? onClearAlignmentPoint,
    VoidCallback? onCancelAlignmentPointPick,
    VoidCallback? onPickGuideCurve,
    VoidCallback? onClearGuideCurve,
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
          guideCurveSet: guideCurveSet,
          pickingGuideCurve: pickingGuideCurve,
          pickingAlignmentPointIndex: pickingAlignmentPointIndex,
          onPickAlignmentPoint: onPickAlignmentPoint ?? (_) {},
          onClearAlignmentPoint: onClearAlignmentPoint ?? (_) {},
          onCancelAlignmentPointPick: onCancelAlignmentPointPick ?? () {},
          onPickGuideCurve: onPickGuideCurve ?? () {},
          onClearGuideCurve: onClearGuideCurve ?? () {},
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

  group('LoftSurfacePanel guide curve row', () {
    // Bug fix ("Guide curve option in loft surface doesn't seem to do
    // anything"): now lives inside the "Guide curve & alignment points
    // (advanced)" ExpansionTile (mirrors LoftPanel exactly), collapsed by
    // default - every test below expands it first.
    Future<void> expandAdvanced(WidgetTester tester) async {
      await tester.tap(find.text('Guide curve & alignment points (advanced)'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows "Not set" and a Pick button by default', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 0, guideCurveSet: false, pickingGuideCurve: false));
      await expandAdvanced(tester);
      expect(find.text('Not set'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Pick'), findsOneWidget);
    });

    testWidgets('tapping Pick invokes onPickGuideCurve', (tester) async {
      var picked = false;
      await tester.pumpWidget(buildPanel(sectionCount: 0, onPickGuideCurve: () => picked = true));
      await expandAdvanced(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Pick'));
      await tester.pump();
      expect(picked, isTrue);
    });

    testWidgets('while picking, shows a prompt and a Cancel button instead', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 0, pickingGuideCurve: true));
      await expandAdvanced(tester);
      expect(find.textContaining('Tap a line, arc, ellipse or spline'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsWidgets);
      expect(find.widgetWithText(TextButton, 'Pick'), findsNothing);
    });

    testWidgets('once set, shows "Set", a Change button, and a Clear icon', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 0, guideCurveSet: true, pickingGuideCurve: false));
      await expandAdvanced(tester);
      expect(find.text('Set'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Change'), findsOneWidget);
      expect(find.byTooltip('Clear guide curve'), findsOneWidget);
    });

    testWidgets('tapping the Clear icon invokes onClearGuideCurve', (tester) async {
      var cleared = false;
      await tester.pumpWidget(
          buildPanel(sectionCount: 0, guideCurveSet: true, onClearGuideCurve: () => cleared = true));
      await expandAdvanced(tester);
      await tester.tap(find.byTooltip('Clear guide curve'));
      await tester.pump();
      expect(cleared, isTrue);
    });
  });

  group('LoftSurfacePanel alignment point rows', () {
    testWidgets('shows one row per section, "Not set" by default', (tester) async {
      await tester.pumpWidget(buildPanel(sectionCount: 2, alignmentPointsSet: const [false, false]));
      await tester.tap(find.text('Guide curve & alignment points (advanced)'));
      await tester.pumpAndSettle();
      expect(find.text('Section 1 alignment point'), findsOneWidget);
      expect(find.text('Section 2 alignment point'), findsOneWidget);
      expect(find.text('Not set'), findsNWidgets(3)); // guide curve + 2 sections
    });

    testWidgets('tapping Pick for a section invokes onPickAlignmentPoint with its index', (tester) async {
      int? pickedIndex;
      await tester.pumpWidget(buildPanel(
        sectionCount: 2,
        alignmentPointsSet: const [false, false],
        onPickAlignmentPoint: (i) => pickedIndex = i,
      ));
      await tester.tap(find.text('Guide curve & alignment points (advanced)'));
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
      await tester.tap(find.text('Guide curve & alignment points (advanced)'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Clear alignment point'), findsOneWidget);
    });
  });

  group('LoftSurfacePanel Confirm/Cancel', () {
    testWidgets('Confirm is always enabled', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping Cancel invokes onCancel', (tester) async {
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
