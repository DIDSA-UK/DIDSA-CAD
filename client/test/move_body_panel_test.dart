import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/move_body_panel.dart';

/// Direct Editing family, third entry: unit-level coverage for
/// [MoveBodyPanel]'s Confirm-enablement rule - all three delta fields must
/// parse as numbers (0 is valid, unlike Fillet's `> 0` radius rule), plus
/// the Move/Copy toggle, plus (once a rotation axis is picked) the optional
/// rotation-angle field. No `flutter_scene` dependency anywhere in
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
    bool hasRotationAxis = false,
    String? rotationAxisSummary,
    double initialRotationAngleDegrees = 0.0,
    void Function(double)? onRotationAngleChanged,
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
          hasRotationAxis: hasRotationAxis,
          rotationAxisSummary: rotationAxisSummary,
          initialRotationAngleDegrees: initialRotationAngleDegrees,
          onRotationAngleChanged: onRotationAngleChanged,
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

    testWidgets('shows three delta fields plus one rotation-angle field', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.byType(TextField), findsNWidgets(4));
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

  group('MoveBodyPanel rotation', () {
    testWidgets('rotation angle field is disabled with no axis picked', (tester) async {
      await tester.pumpWidget(buildPanel());
      final field = tester.widget<TextField>(find.byType(TextField).at(3));
      expect(field.enabled, isFalse);
    });

    testWidgets('rotation angle field is enabled once an axis is picked', (tester) async {
      await tester.pumpWidget(buildPanel(hasRotationAxis: true));
      final field = tester.widget<TextField>(find.byType(TextField).at(3));
      expect(field.enabled, isTrue);
    });

    testWidgets('shows the pick prompt with no axis, the summary once picked', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(
        find.text('Tap an edge, cylindrical face, or Sketch Line to pick a rotation axis'),
        findsOneWidget,
      );

      await tester.pumpWidget(buildPanel(hasRotationAxis: true, rotationAxisSummary: 'Edge selected'));
      expect(find.text('Edge selected'), findsOneWidget);
    });

    testWidgets('a non-zero angle survives the axis being cleared afterward, and disables Confirm',
        (tester) async {
      // The angle field is disabled while no axis is picked (confirmed
      // above), so the only realistic way to reach "non-zero angle, no
      // axis" is: pick an axis, type an angle, then the axis gets cleared
      // (e.g. the user taps the picked entity again to deselect it) - the
      // angle field itself is local widget state, independent of
      // widget.hasRotationAxis, so it isn't reset when that happens.
      await tester.pumpWidget(buildPanel(hasRotationAxis: true));
      await tester.enterText(find.byType(TextField).at(3), '45');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );

      await tester.pumpWidget(buildPanel(hasRotationAxis: false));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a non-zero angle with an axis picked keeps Confirm enabled', (tester) async {
      await tester.pumpWidget(buildPanel(hasRotationAxis: true));
      await tester.enterText(find.byType(TextField).at(3), '45');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('entering a valid angle fires onRotationAngleChanged', (tester) async {
      double? lastAngle;
      await tester.pumpWidget(
        buildPanel(hasRotationAxis: true, onRotationAngleChanged: (a) => lastAngle = a),
      );
      await tester.enterText(find.byType(TextField).at(3), '90');
      await tester.pump();
      expect(lastAngle, 90.0);
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
      // The rotation section adds enough content that Cancel/Confirm can
      // sit below ResizableToolPanel's own scrollable viewport at the
      // default height fraction - ensureVisible scrolls it into view first,
      // same fix pattern `pattern_panel_test.dart` already established for
      // its own taller panel.
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Cancel'));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
