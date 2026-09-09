import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/thicken_panel.dart';

/// Phase 2 surfacing package, first entry: unit-level coverage for
/// [ThickenPanel]'s Confirm-enablement rule - requires a valid, non-zero
/// thickness, mirroring `scale_body_panel_test.dart`'s own coverage of
/// [ScaleBodyPanel]'s identical factor rule. No `flutter_scene` dependency
/// anywhere in `thicken_panel.dart`'s import chain, so this is a real,
/// runnable widget test in this sandbox.
void main() {
  Widget buildPanel({
    double initialThickness = 1.0,
    String sourceSummary = 'Loft Surface 1',
    void Function(double)? onThicknessChanged,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: ThickenPanel(
            sourceSummary: sourceSummary,
            initialThickness: initialThickness,
            onThicknessChanged: onThicknessChanged,
            onConfirm: onConfirm ?? () {},
            onCancel: onCancel ?? () {},
          ),
        ),
      );

  group('ThickenPanel Confirm enablement', () {
    testWidgets('a valid non-zero initial thickness is enabled', (tester) async {
      await tester.pumpWidget(buildPanel(initialThickness: 2.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a zero initial thickness is disabled', (tester) async {
      await tester.pumpWidget(buildPanel(initialThickness: 0.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('clearing the thickness field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(buildPanel(initialThickness: 1.0));
      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('entering a valid thickness re-enables Confirm and fires onThicknessChanged',
        (tester) async {
      double? lastThickness;
      await tester.pumpWidget(buildPanel(
        initialThickness: 0.0,
        onThicknessChanged: (value) => lastThickness = value,
      ));
      await tester.enterText(find.byType(TextField), '4.5');
      await tester.pump();
      expect(lastThickness, 4.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a negative thickness (flip side) is still valid', (tester) async {
      await tester.pumpWidget(buildPanel(initialThickness: -2.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('ThickenPanel source summary', () {
    testWidgets('shows the source Feature name passed in', (tester) async {
      await tester.pumpWidget(buildPanel(sourceSummary: 'Revolve Surface 2'));
      expect(find.textContaining('Revolve Surface 2'), findsOneWidget);
    });
  });

  group('ThickenPanel title', () {
    testWidgets('defaults to "Thicken"', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.text('Thicken'), findsOneWidget);
    });

    testWidgets('shows "Edit Thicken" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThickenPanel(
              title: 'Edit Thicken',
              sourceSummary: 'Loft Surface 1',
              initialThickness: 1.0,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Thicken'), findsOneWidget);
    });
  });

  group('ThickenPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(buildPanel(onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
