import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/extrude_panel.dart';

/// Prompt A4: unit-level coverage for [ExtrudePanel]'s Confirm-enablement
/// rule - Boss allows confirming with zero target bodies picked (starts a
/// brand-new Body), Cut requires at least one. No `flutter_scene` dependency
/// anywhere in `extrude_panel.dart`'s import chain, so unlike most of
/// `part_screen.dart`'s own UI this is a real, runnable widget test in this
/// sandbox, not just `flutter analyze`.
void main() {
  Future<bool> confirmEnabled(
    WidgetTester tester, {
    required ExtrudeType type,
    required int targetBodyCount,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ExtrudePanel(
            initialType: type,
            targetBodyCount: targetBodyCount,
            onChanged: (_, __, ___) {},
            onConfirm: () {},
            onCancel: () {},
          ),
        ),
      ),
    );
    final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
    return button.onPressed != null;
  }

  group('ExtrudePanel Confirm enablement', () {
    testWidgets('Boss with zero target bodies stays enabled', (tester) async {
      expect(
        await confirmEnabled(tester, type: ExtrudeType.boss, targetBodyCount: 0),
        isTrue,
      );
    });

    testWidgets('Boss with target bodies picked stays enabled', (tester) async {
      expect(
        await confirmEnabled(tester, type: ExtrudeType.boss, targetBodyCount: 3),
        isTrue,
      );
    });

    testWidgets('Cut with zero target bodies is disabled', (tester) async {
      expect(
        await confirmEnabled(tester, type: ExtrudeType.cut, targetBodyCount: 0),
        isFalse,
      );
    });

    testWidgets('Cut with at least one target body is enabled', (tester) async {
      expect(
        await confirmEnabled(tester, type: ExtrudeType.cut, targetBodyCount: 1),
        isTrue,
      );
    });

    testWidgets('switching Boss to Cut with nothing picked disables Confirm live',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              initialType: ExtrudeType.boss,
              targetBodyCount: 0,
              onChanged: (_, __, ___) {},
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

      // ButtonSegment itself isn't a Widget (SegmentedButton just reads it
      // as data), so the tap target is the label Text it renders.
      await tester.tap(find.text('Cut'));
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('an invalid depth disables Confirm regardless of target bodies',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              initialType: ExtrudeType.boss,
              initialStartDistance: 10,
              initialEndDistance: 0, // end <= start: invalid depth.
              targetBodyCount: 5,
              onChanged: (_, __, ___) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });
  });

  group('ExtrudePanel title (B4)', () {
    testWidgets('defaults to "Extrude"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              targetBodyCount: 0,
              onChanged: (_, __, ___) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Extrude'), findsOneWidget);
      expect(find.text('Edit Extrude'), findsNothing);
    });

    testWidgets('shows "Edit Extrude" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              title: 'Edit Extrude',
              initialType: ExtrudeType.boss,
              initialStartDistance: 0,
              initialEndDistance: 10,
              targetBodyCount: 0,
              onChanged: (_, __, ___) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Extrude'), findsOneWidget);
    });
  });
}
