import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/create_plane_panel.dart';

/// C2: unit-level coverage for [CreatePlanePanel]'s Confirm-enablement rule
/// - [CreatePlaneMode.offsetFace] requires a valid numeric offset,
/// [CreatePlaneMode.normalToLineAtPoint] has no field at all and is always
/// enabled. No `flutter_scene` dependency anywhere in
/// `create_plane_panel.dart`'s import chain, so this is a real, runnable
/// widget test in this sandbox, same as `extrude_panel_test.dart`.
void main() {
  Future<bool> confirmEnabled(WidgetTester tester, CreatePlaneMode mode, {double initialOffset = 0.0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CreatePlanePanel(
            mode: mode,
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

  group('CreatePlanePanel Confirm enablement', () {
    testWidgets('offsetFace with a valid initial offset is enabled', (tester) async {
      expect(await confirmEnabled(tester, CreatePlaneMode.offsetFace, initialOffset: 5.0), isTrue);
    });

    testWidgets('normalToLineAtPoint has no numeric field and is always enabled', (tester) async {
      expect(await confirmEnabled(tester, CreatePlaneMode.normalToLineAtPoint), isTrue);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('offsetFace shows a numeric offset field', (tester) async {
      await confirmEnabled(tester, CreatePlaneMode.offsetFace);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('clearing the offset field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreatePlanePanel(
              mode: CreatePlaneMode.offsetFace,
              initialOffset: 5.0,
              onOffsetChanged: (_) {},
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

    testWidgets('entering a valid offset re-enables Confirm and fires onOffsetChanged', (tester) async {
      double? lastOffset;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreatePlanePanel(
              mode: CreatePlaneMode.offsetFace,
              initialOffset: 0.0,
              onOffsetChanged: (value) => lastOffset = value,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), '12.5');
      await tester.pump();

      expect(lastOffset, 12.5);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });
  });

  group('CreatePlanePanel title', () {
    testWidgets('defaults to "Create Plane"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreatePlanePanel(
              mode: CreatePlaneMode.offsetFace,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Create Plane'), findsOneWidget);
      expect(find.text('Edit Plane'), findsNothing);
    });

    testWidgets('shows "Edit Plane" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreatePlanePanel(
              title: 'Edit Plane',
              mode: CreatePlaneMode.normalToLineAtPoint,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Plane'), findsOneWidget);
    });
  });

  group('CreatePlanePanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CreatePlanePanel(
              mode: CreatePlaneMode.normalToLineAtPoint,
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
