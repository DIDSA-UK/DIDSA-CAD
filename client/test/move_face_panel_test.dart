import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/move_face_panel.dart';

/// Direct Editing family, fifth/last entry: unit-level coverage for
/// [MoveFacePanel]'s Confirm-enablement rule - requires a valid, non-zero
/// numeric offset, mirroring `scale_body_panel_test.dart`'s own coverage
/// of [ScaleBodyPanel]'s factor rule, except negative values are valid
/// too (an offset can push either direction along the face's own normal).
/// No `flutter_scene` dependency anywhere in `move_face_panel.dart`'s
/// import chain, so this is a real, runnable widget test in this sandbox.
void main() {
  Future<bool> confirmEnabled(WidgetTester tester, {double initialOffset = 1.0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MoveFacePanel(
            initialOffset: initialOffset,
            onOffsetChanged: (_) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('MoveFacePanel Confirm enablement', () {
    testWidgets('a valid positive initial offset is enabled', (tester) async {
      expect(await confirmEnabled(tester, initialOffset: 3.0), isTrue);
    });

    testWidgets('a valid negative initial offset is enabled', (tester) async {
      expect(await confirmEnabled(tester, initialOffset: -3.0), isTrue);
    });

    testWidgets('a zero initial offset is disabled', (tester) async {
      expect(await confirmEnabled(tester, initialOffset: 0.0), isFalse);
    });

    testWidgets('shows a numeric offset field', (tester) async {
      await confirmEnabled(tester);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('clearing the offset field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveFacePanel(
              initialOffset: 1.0,
              onOffsetChanged: (_) {},
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

    testWidgets('entering a valid negative offset re-enables Confirm and fires onOffsetChanged',
        (tester) async {
      double? lastOffset;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveFacePanel(
              initialOffset: 0.0,
              onOffsetChanged: (value) => lastOffset = value,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '-2.5');
      await tester.pump();

      expect(lastOffset, -2.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('MoveFacePanel title', () {
    testWidgets('defaults to "Move Face"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveFacePanel(initialOffset: 1.0, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Move Face'), findsOneWidget);
      expect(find.text('Edit Move Face'), findsNothing);
    });
  });

  group('MoveFacePanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MoveFacePanel(
              initialOffset: 1.0,
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
