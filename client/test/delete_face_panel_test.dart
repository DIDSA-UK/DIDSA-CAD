import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/delete_face_panel.dart';

/// Direct Editing family, fourth entry, V2: unit-level coverage for
/// [DeleteFacePanel]'s Confirm-enablement rule - requires [faceCount] > 0,
/// mirroring `fillet_panel_test.dart`'s own coverage shape, plus the live
/// face-count summary text. No `flutter_scene` dependency anywhere in
/// `delete_face_panel.dart`'s import chain, so this is a real, runnable
/// widget test in this sandbox.
void main() {
  Widget buildPanel({
    int faceCount = 1,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: DeleteFacePanel(
          faceCount: faceCount,
          onConfirm: onConfirm ?? () {},
          onCancel: onCancel ?? () {},
        ),
      ),
    );
  }

  group('DeleteFacePanel Confirm enablement', () {
    testWidgets('one face picked enables Confirm', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 1));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed,
        isNotNull,
      );
    });

    testWidgets('two faces picked enables Confirm', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 2));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed,
        isNotNull,
      );
    });

    testWidgets('zero faces picked disables Confirm', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed,
        isNull,
      );
    });
  });

  group('DeleteFacePanel face-count summary', () {
    testWidgets('shows singular text for one face', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 1));
      expect(find.text('Deleting 1 face'), findsOneWidget);
    });

    testWidgets('shows plural text for multiple faces', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 3));
      expect(find.text('Deleting 3 faces'), findsOneWidget);
    });

    testWidgets('shows a prompt when nothing is picked yet', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 0));
      expect(find.text('Tap one or more faces of the same body to delete'), findsOneWidget);
    });
  });

  group('DeleteFacePanel title', () {
    testWidgets('defaults to "Delete Face"', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.text('Delete Face'), findsOneWidget);
      expect(find.text('Edit Delete Face'), findsNothing);
    });

    testWidgets('shows "Edit Delete Face" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DeleteFacePanel(
              title: 'Edit Delete Face',
              faceCount: 1,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Delete Face'), findsOneWidget);
    });
  });

  group('DeleteFacePanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(buildPanel(faceCount: 0, onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
