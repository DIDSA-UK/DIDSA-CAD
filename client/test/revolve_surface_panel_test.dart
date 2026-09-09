import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/revolve_surface_panel.dart';

/// Phase 1 surfacing package: unit-level coverage for [RevolveSurfacePanel]'s
/// Confirm-enablement rule - mirrors [RevolvePanel]'s own would-be test
/// shape (`extrude_panel_test.dart`'s structure, since neither
/// `revolve_panel_test.dart` nor `sweep_panel_test.dart` exist yet in this
/// repo), minus the Boss/Cut/target-body concerns this panel has no
/// equivalent of at all - Confirm here only ever depends on the angle field
/// and whether an axis has been picked. No `flutter_scene` dependency
/// anywhere in `revolve_surface_panel.dart`'s import chain, so this is a
/// real, runnable widget test in this sandbox, not just `flutter analyze`.
void main() {
  Future<bool> confirmEnabled(
    WidgetTester tester, {
    double initialAngle = 180.0,
    required bool hasAxis,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RevolveSurfacePanel(
            initialAngle: initialAngle,
            hasAxis: hasAxis,
            onChanged: (_) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('RevolveSurfacePanel Confirm enablement', () {
    testWidgets('a valid angle with an axis picked is enabled', (tester) async {
      expect(await confirmEnabled(tester, hasAxis: true), isTrue);
    });

    testWidgets('a valid angle with no axis picked is disabled', (tester) async {
      expect(await confirmEnabled(tester, hasAxis: false), isFalse);
    });

    testWidgets('an angle of 0 with an axis picked is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialAngle: 0, hasAxis: true), isFalse);
    });

    testWidgets('an angle over 360 with an axis picked is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialAngle: 400, hasAxis: true), isFalse);
    });

    testWidgets('editing the angle field to an invalid value disables Confirm live',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RevolveSurfacePanel(
              initialAngle: 180,
              hasAxis: true,
              onChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });
  });

  group('RevolveSurfacePanel axis status line', () {
    testWidgets('shows "Select an axis line" while none is picked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RevolveSurfacePanel(
              hasAxis: false,
              onChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Select an axis line in the viewport'), findsOneWidget);
    });

    testWidgets('shows "Axis: selected" once one is picked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RevolveSurfacePanel(
              hasAxis: true,
              onChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Axis: selected'), findsOneWidget);
    });
  });

  group('RevolveSurfacePanel title (B4)', () {
    testWidgets('defaults to "Revolve Surface"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RevolveSurfacePanel(
              hasAxis: false,
              onChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Revolve Surface'), findsOneWidget);
      expect(find.text('Edit Revolve Surface'), findsNothing);
    });

    testWidgets('shows "Edit Revolve Surface" when editing an existing Feature',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RevolveSurfacePanel(
              title: 'Edit Revolve Surface',
              hasAxis: true,
              onChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Revolve Surface'), findsOneWidget);
    });
  });
}
