import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/fillet_panel.dart';

/// Prompt D: unit-level coverage for [FilletPanel]'s Confirm-enablement rule
/// - requires a valid, positive numeric radius, mirroring
/// `create_plane_panel_test.dart`'s own coverage of
/// [CreatePlaneMode.offsetFace]'s numeric-field rule exactly. No
/// `flutter_scene` dependency anywhere in `fillet_panel.dart`'s import
/// chain, so this is a real, runnable widget test in this sandbox.
void main() {
  Future<bool> confirmEnabled(WidgetTester tester, {double initialRadius = 1.0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FilletPanel(
            initialRadius: initialRadius,
            onRadiusChanged: (_) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('FilletPanel Confirm enablement', () {
    testWidgets('a valid initial radius is enabled', (tester) async {
      expect(await confirmEnabled(tester, initialRadius: 2.0), isTrue);
    });

    testWidgets('a zero initial radius is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialRadius: 0.0), isFalse);
    });

    testWidgets('shows a numeric radius field', (tester) async {
      await confirmEnabled(tester);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('clearing the radius field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(
              initialRadius: 1.0,
              onRadiusChanged: (_) {},
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

      await tester.enterText(find.byType(TextField), 'not-a-number');
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('clearing the radius field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(
              initialRadius: 1.0,
              onRadiusChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('entering a valid radius re-enables Confirm and fires onRadiusChanged', (tester) async {
      double? lastRadius;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(
              initialRadius: 0.0,
              onRadiusChanged: (value) => lastRadius = value,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '3.5');
      await tester.pump();

      expect(lastRadius, 3.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('FilletPanel title', () {
    testWidgets('defaults to "Fillet"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(initialRadius: 1.0, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Fillet'), findsOneWidget);
      expect(find.text('Edit Fillet'), findsNothing);
    });

    testWidgets('shows "Edit Fillet" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(
              title: 'Edit Fillet',
              initialRadius: 1.0,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Fillet'), findsOneWidget);
    });
  });

  group('FilletPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilletPanel(
              initialRadius: 1.0,
              onConfirm: () {},
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
