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
            onChanged: (_, __, ___, ____, _____, ______, _______) {},
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
              onChanged: (_, __, ___, ____, _____, ______, _______) {},
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
              onChanged: (_, __, ___, ____, _____, ______, _______) {},
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

  group('ExtrudePanel flip direction', () {
    testWidgets('tapping flip negates and swaps start/end distance', (tester) async {
      ExtrudeType? lastType;
      double? lastStart;
      double? lastEnd;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              initialType: ExtrudeType.boss,
              initialStartDistance: 0,
              initialEndDistance: 10,
              targetBodyCount: 0,
              onChanged: (type, start, end, _, __, ___, ____) {
                lastType = type;
                lastStart = start;
                lastEnd = end;
              },
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Flip direction'));
      await tester.pump();

      expect(lastType, ExtrudeType.boss);
      expect(lastStart, -10);
      expect(lastEnd, 0);
      expect(find.text('Depth: 10'), findsOneWidget);
    });

    testWidgets('flipping an asymmetric span keeps end greater than start',
        (tester) async {
      double? lastStart;
      double? lastEnd;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              initialType: ExtrudeType.boss,
              initialStartDistance: -2,
              initialEndDistance: 8,
              targetBodyCount: 0,
              onChanged: (_, start, end, __, ___, ____, _____) {
                lastStart = start;
                lastEnd = end;
              },
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Flip direction'));
      await tester.pump();

      expect(lastStart, -8);
      expect(lastEnd, 2);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
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
              onChanged: (_, __, ___, ____, _____, ______, _______) {},
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
              onChanged: (_, __, ___, ____, _____, ______, _______) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Extrude'), findsOneWidget);
    });
  });
  group('ExtrudePanel draft (Feature 5)', () {
    Future<List<(double?, bool)>> pumpPanel(
      WidgetTester tester, {
      double? initialThickness,
      double? initialDraftAngle,
      bool initialDraftOutward = true,
    }) async {
      final emitted = <(double?, bool)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExtrudePanel(
              targetBodyCount: 0,
              initialThickness: initialThickness,
              initialDraftAngle: initialDraftAngle,
              initialDraftOutward: initialDraftOutward,
              onChanged: (_, __, ___, ____, _____, draftAngle, draftOutward) =>
                  emitted.add((draftAngle, draftOutward)),
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      return emitted;
    }

    bool confirmEnabled(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed != null;

    Future<void> tapDraftToggle(WidgetTester tester) async {
      final toggle = find.byKey(const ValueKey('extrude-draft-toggle'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
    }

    testWidgets('off by default - no draft emitted, no angle field', (tester) async {
      final emitted = await pumpPanel(tester);
      expect(emitted.last.$1, isNull);
      expect(find.byKey(const ValueKey('extrude-draft-angle-field')), findsNothing);
    });

    testWidgets('toggling Draft on emits the default angle, outward', (tester) async {
      final emitted = await pumpPanel(tester);
      await tapDraftToggle(tester);
      expect(emitted.last, (5.0, true));
      expect(find.byKey(const ValueKey('extrude-draft-angle-field')), findsOneWidget);
      expect(confirmEnabled(tester), isTrue);
    });

    testWidgets('Inward segment emits draftOutward false', (tester) async {
      final emitted = await pumpPanel(tester, initialDraftAngle: 3);
      final inward = find.text('Inward');
      await tester.ensureVisible(inward);
      await tester.tap(inward);
      await tester.pump();
      expect(emitted.last, (3.0, false));
    });

    for (final invalid in ['0', '90', '120', 'abc']) {
      testWidgets('angle "$invalid" disables Confirm', (tester) async {
        await pumpPanel(tester, initialDraftAngle: 5);
        final field = find.byKey(const ValueKey('extrude-draft-angle-field'));
        await tester.ensureVisible(field);
        await tester.enterText(field, invalid);
        await tester.pump();
        expect(confirmEnabled(tester), isFalse);
        expect(find.text('Enter an angle between 0 and 90'), findsOneWidget);
      });
    }

    testWidgets('Draft toggle is disabled while thin extrude is on', (tester) async {
      await pumpPanel(tester, initialThickness: 1);
      final tile = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('extrude-draft-toggle')));
      expect(tile.onChanged, isNull);
      expect(find.text('Not available with thin extrude'), findsOneWidget);
    });

    testWidgets('Thin extrude toggle is disabled while draft is on', (tester) async {
      await pumpPanel(tester, initialDraftAngle: 5);
      final tile = tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, 'Thin extrude'));
      expect(tile.onChanged, isNull);
      expect(find.text('Not available with draft'), findsOneWidget);
    });
  });
}
