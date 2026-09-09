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
    bool guideCurveSet = false,
    bool pickingGuideCurve = false,
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
          guideCurveSet: guideCurveSet,
          pickingGuideCurve: pickingGuideCurve,
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
    testWidgets('shows "Not set" and a Pick button by default', (tester) async {
      await tester.pumpWidget(buildPanel(guideCurveSet: false, pickingGuideCurve: false));
      expect(find.text('Not set'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Pick'), findsOneWidget);
    });

    testWidgets('tapping Pick invokes onPickGuideCurve', (tester) async {
      var picked = false;
      await tester.pumpWidget(buildPanel(onPickGuideCurve: () => picked = true));
      await tester.tap(find.widgetWithText(TextButton, 'Pick'));
      await tester.pump();
      expect(picked, isTrue);
    });

    testWidgets('while picking, shows a prompt and a Cancel button instead', (tester) async {
      await tester.pumpWidget(buildPanel(pickingGuideCurve: true));
      expect(find.textContaining('Tap a line, arc, ellipse or spline'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsWidgets);
      expect(find.widgetWithText(TextButton, 'Pick'), findsNothing);
    });

    testWidgets('once set, shows "Set", a Change button, and a Clear icon', (tester) async {
      await tester.pumpWidget(buildPanel(guideCurveSet: true, pickingGuideCurve: false));
      expect(find.text('Set'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Change'), findsOneWidget);
      expect(find.byTooltip('Clear guide curve'), findsOneWidget);
    });

    testWidgets('tapping the Clear icon invokes onClearGuideCurve', (tester) async {
      var cleared = false;
      await tester.pumpWidget(
          buildPanel(guideCurveSet: true, onClearGuideCurve: () => cleared = true));
      await tester.tap(find.byTooltip('Clear guide curve'));
      await tester.pump();
      expect(cleared, isTrue);
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
