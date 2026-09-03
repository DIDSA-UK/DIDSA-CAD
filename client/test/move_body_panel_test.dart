import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/move_body_panel.dart';

/// Direct Editing family, third entry: unit-level coverage for
/// [MoveBodyPanel]'s Confirm-enablement rule - all three delta fields must
/// parse as numbers (0 is valid, unlike Fillet's `> 0` radius rule), plus
/// the Move/Copy toggle. No `flutter_scene` dependency anywhere in
/// `move_body_panel.dart`'s import chain, so this is a real, runnable
/// widget test in this sandbox.
void main() {
  Widget buildPanel({
    double initialDeltaX = 0.0,
    double initialDeltaY = 0.0,
    double initialDeltaZ = 0.0,
    bool copy = false,
    void Function(double, double, double)? onDeltaChanged,
    void Function(bool)? onCopyChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MoveBodyPanel(
          initialDeltaX: initialDeltaX,
          initialDeltaY: initialDeltaY,
          initialDeltaZ: initialDeltaZ,
          onDeltaChanged: onDeltaChanged,
          copy: copy,
          onCopyChanged: onCopyChanged ?? (_) {},
          onConfirm: () {},
          onCancel: () {},
        ),
      ),
    );
  }

  group('MoveBodyPanel Confirm enablement', () {
    testWidgets('the default zero delta is enabled (0 is a valid delta component)', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('shows three numeric delta fields', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.byType(TextField), findsNWidgets(3));
    });

    testWidgets('clearing a delta field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(buildPanel());

      await tester.enterText(find.byType(TextField).first, 'not-a-number');
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('entering a valid delta fires onDeltaChanged with all three values', (tester) async {
      double? lastX, lastY, lastZ;
      await tester.pumpWidget(buildPanel(onDeltaChanged: (x, y, z) {
        lastX = x;
        lastY = y;
        lastZ = z;
      }));

      await tester.enterText(find.byType(TextField).at(0), '5');
      await tester.pump();

      expect(lastX, 5.0);
      expect(lastY, 0.0);
      expect(lastZ, 0.0);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('MoveBodyPanel Move/Copy toggle', () {
    testWidgets('defaults to Move, tapping Copy fires onCopyChanged(true)', (tester) async {
      bool? lastCopy;
      await tester.pumpWidget(buildPanel(onCopyChanged: (value) => lastCopy = value));

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(lastCopy, isTrue);
    });
  });

  group('MoveBodyPanel title', () {
    testWidgets('defaults to "Move Body"', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.text('Move Body'), findsOneWidget);
      expect(find.text('Edit Move Body'), findsNothing);
    });
  });

  group('MoveBodyPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveBodyPanel(
              copy: false,
              onCopyChanged: (_) {},
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
