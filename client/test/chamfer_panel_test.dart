import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/chamfer_panel.dart';

/// Prompt E: unit-level coverage for [ChamferPanel]'s Confirm-enablement
/// rule - mirrors `fillet_panel_test.dart`'s own coverage of [FilletPanel]
/// exactly, substituting distance for radius. No `flutter_scene` dependency
/// anywhere in `chamfer_panel.dart`'s import chain, so this is a real,
/// runnable widget test in this sandbox.
void main() {
  Future<bool> confirmEnabled(WidgetTester tester, {double initialDistance = 1.0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChamferPanel(
            initialDistance: initialDistance,
            onDistanceChanged: (_) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('ChamferPanel Confirm enablement', () {
    testWidgets('a valid initial distance is enabled', (tester) async {
      expect(await confirmEnabled(tester, initialDistance: 2.0), isTrue);
    });

    testWidgets('a zero initial distance is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialDistance: 0.0), isFalse);
    });

    testWidgets('shows a numeric distance field', (tester) async {
      await confirmEnabled(tester);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('clearing the distance field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(
              initialDistance: 1.0,
              onDistanceChanged: (_) {},
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

    testWidgets('clearing the distance field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(
              initialDistance: 1.0,
              onDistanceChanged: (_) {},
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

    testWidgets('entering a valid distance re-enables Confirm and fires onDistanceChanged', (tester) async {
      double? lastDistance;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(
              initialDistance: 0.0,
              onDistanceChanged: (value) => lastDistance = value,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '3.5');
      await tester.pump();

      expect(lastDistance, 3.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('ChamferPanel title', () {
    testWidgets('defaults to "Chamfer"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(initialDistance: 1.0, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Chamfer'), findsOneWidget);
      expect(find.text('Edit Chamfer'), findsNothing);
    });

    testWidgets('shows "Edit Chamfer" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(
              title: 'Edit Chamfer',
              initialDistance: 1.0,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Chamfer'), findsOneWidget);
    });
  });

  group('ChamferPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChamferPanel(
              initialDistance: 1.0,
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
