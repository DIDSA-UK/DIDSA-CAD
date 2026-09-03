import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/scale_body_panel.dart';

/// Direct Editing family, second entry: unit-level coverage for
/// [ScaleBodyPanel]'s Confirm-enablement rule - requires a valid, positive
/// numeric factor, mirroring `fillet_panel_test.dart`'s own coverage of
/// [FilletPanel]'s identical radius rule. No `flutter_scene` dependency
/// anywhere in `scale_body_panel.dart`'s import chain, so this is a real,
/// runnable widget test in this sandbox.
void main() {
  Future<bool> confirmEnabled(WidgetTester tester, {double initialFactor = 1.0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScaleBodyPanel(
            initialFactor: initialFactor,
            onFactorChanged: (_) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('ScaleBodyPanel Confirm enablement', () {
    testWidgets('a valid initial factor is enabled', (tester) async {
      expect(await confirmEnabled(tester, initialFactor: 2.0), isTrue);
    });

    testWidgets('a zero initial factor is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialFactor: 0.0), isFalse);
    });

    testWidgets('a negative initial factor is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialFactor: -1.0), isFalse);
    });

    testWidgets('shows a numeric factor field', (tester) async {
      await confirmEnabled(tester);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('clearing the factor field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(
              initialFactor: 1.0,
              onFactorChanged: (_) {},
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

    testWidgets('clearing the factor field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(
              initialFactor: 1.0,
              onFactorChanged: (_) {},
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

    testWidgets('entering a valid factor re-enables Confirm and fires onFactorChanged', (tester) async {
      double? lastFactor;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(
              initialFactor: 0.0,
              onFactorChanged: (value) => lastFactor = value,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '3.5');
      await tester.pump();

      expect(lastFactor, 3.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('ScaleBodyPanel title', () {
    testWidgets('defaults to "Scale"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(initialFactor: 1.0, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Scale'), findsOneWidget);
      expect(find.text('Edit Scale'), findsNothing);
    });

    testWidgets('shows "Edit Scale" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(
              title: 'Edit Scale',
              initialFactor: 1.0,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Scale'), findsOneWidget);
    });
  });

  group('ScaleBodyPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScaleBodyPanel(
              initialFactor: 1.0,
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
