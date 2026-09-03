import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/move_face_panel.dart';

/// Direct Editing family, fifth/last entry: unit-level coverage for
/// [MoveFacePanel]'s three mutually-exclusive modes - Offset's Confirm-
/// enablement rule (requires a valid, non-zero numeric offset, mirroring
/// `scale_body_panel_test.dart`'s own coverage of [ScaleBodyPanel]'s
/// factor rule, except negative values are valid too), Delta's (all three
/// fields must parse, zero is valid on each axis, mirrors
/// `move_body_panel_test.dart`'s own delta coverage), and Direction's
/// (a reference must be picked *and* a non-zero distance entered), plus
/// mode switching and the Flip button. No `flutter_scene` dependency
/// anywhere in `move_face_panel.dart`'s import chain, so this is a real,
/// runnable widget test in this sandbox.
void main() {
  Widget buildPanel({
    MoveFaceMode mode = MoveFaceMode.offset,
    void Function(MoveFaceMode)? onModeChanged,
    int faceCount = 1,
    double initialOffset = 1.0,
    void Function(double)? onOffsetChanged,
    double initialDeltaX = 0.0,
    double initialDeltaY = 0.0,
    double initialDeltaZ = 0.0,
    void Function(double, double, double)? onDeltaChanged,
    bool hasDirection = false,
    String? directionSummary,
    void Function(String)? onSetDirectionFixedAxis,
    double initialDirectionDistance = 1.0,
    void Function(double)? onDirectionDistanceChanged,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: MoveFacePanel(
          mode: mode,
          onModeChanged: onModeChanged ?? (_) {},
          faceCount: faceCount,
          initialOffset: initialOffset,
          onOffsetChanged: onOffsetChanged,
          initialDeltaX: initialDeltaX,
          initialDeltaY: initialDeltaY,
          initialDeltaZ: initialDeltaZ,
          onDeltaChanged: onDeltaChanged,
          hasDirection: hasDirection,
          directionSummary: directionSummary,
          onSetDirectionFixedAxis: onSetDirectionFixedAxis ?? (_) {},
          initialDirectionDistance: initialDirectionDistance,
          onDirectionDistanceChanged: onDirectionDistanceChanged,
          onConfirm: () {},
          onCancel: () {},
        ),
      ),
    );
  }

  group('MoveFacePanel mode switching', () {
    testWidgets('defaults to Offset mode, showing exactly one field', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Offset'), findsOneWidget);
    });

    testWidgets('tapping Delta XYZ fires onModeChanged and shows three fields', (tester) async {
      MoveFaceMode? lastMode;
      await tester.pumpWidget(buildPanel(onModeChanged: (m) => lastMode = m));

      await tester.tap(find.text('Delta XYZ'));
      await tester.pump();
      expect(lastMode, MoveFaceMode.delta);

      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.delta));
      expect(find.byType(TextField), findsNWidgets(3));
    });

    testWidgets('Direction mode shows the pick prompt, axis buttons, and a distance field',
        (tester) async {
      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.direction));
      expect(
        find.text('Tap an edge or Sketch Line, or pick a fixed axis'),
        findsOneWidget,
      );
      expect(find.text('X'), findsOneWidget);
      expect(find.text('Y'), findsOneWidget);
      expect(find.text('Z'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  group('MoveFacePanel Offset mode Confirm enablement', () {
    testWidgets('a valid positive initial offset is enabled', (tester) async {
      await tester.pumpWidget(buildPanel(initialOffset: 3.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a valid negative initial offset is enabled', (tester) async {
      await tester.pumpWidget(buildPanel(initialOffset: -3.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a zero initial offset is disabled', (tester) async {
      await tester.pumpWidget(buildPanel(initialOffset: 0.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('clearing the offset field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(buildPanel(initialOffset: 1.0));

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
        buildPanel(initialOffset: 0.0, onOffsetChanged: (value) => lastOffset = value),
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

  group('MoveFacePanel Delta mode Confirm enablement', () {
    testWidgets('the default zero delta is enabled (0 is a valid delta component)', (tester) async {
      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.delta));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('clearing a delta field to an invalid value disables Confirm live', (tester) async {
      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.delta));

      await tester.enterText(find.byType(TextField).first, 'not-a-number');
      await tester.pump();

      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('entering a valid delta fires onDeltaChanged with all three values', (tester) async {
      double? lastX, lastY, lastZ;
      await tester.pumpWidget(buildPanel(
        mode: MoveFaceMode.delta,
        onDeltaChanged: (x, y, z) {
          lastX = x;
          lastY = y;
          lastZ = z;
        },
      ));

      await tester.enterText(find.byType(TextField).at(0), '5');
      await tester.pump();

      expect(lastX, 5.0);
      expect(lastY, 0.0);
      expect(lastZ, 0.0);
    });
  });

  group('MoveFacePanel Direction mode Confirm enablement', () {
    testWidgets('no reference picked disables Confirm even with a valid distance', (tester) async {
      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.direction));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a picked reference with a zero distance disables Confirm', (tester) async {
      await tester.pumpWidget(buildPanel(mode: MoveFaceMode.direction, hasDirection: true));
      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a picked reference with a non-zero distance enables Confirm', (tester) async {
      await tester.pumpWidget(
        buildPanel(mode: MoveFaceMode.direction, hasDirection: true, directionSummary: 'Edge selected'),
      );
      expect(find.text('Edge selected'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping an axis button fires onSetDirectionFixedAxis', (tester) async {
      String? lastAxis;
      await tester.pumpWidget(
        buildPanel(mode: MoveFaceMode.direction, onSetDirectionFixedAxis: (axis) => lastAxis = axis),
      );
      await tester.tap(find.text('X'));
      expect(lastAxis, 'x');
    });

    testWidgets('the Flip button negates the distance in place and fires onDirectionDistanceChanged',
        (tester) async {
      double? lastDistance;
      await tester.pumpWidget(buildPanel(
        mode: MoveFaceMode.direction,
        hasDirection: true,
        initialDirectionDistance: 2.0,
        onDirectionDistanceChanged: (d) => lastDistance = d,
      ));

      await tester.tap(find.widgetWithIcon(IconButton, Icons.swap_vert));
      await tester.pump();

      expect(lastDistance, -2.0);
      expect(find.text('-2'), findsOneWidget);
    });
  });

  group('MoveFacePanel V2 multi-face gating', () {
    testWidgets('zero faces disables Confirm even in Offset mode with a valid offset', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 0, initialOffset: 3.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('two faces disables Confirm in Delta mode even with a valid delta', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 2, mode: MoveFaceMode.delta));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('two faces disables Confirm in Direction mode even with a picked reference',
        (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 2, mode: MoveFaceMode.direction, hasDirection: true));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('two faces keeps Confirm enabled in Offset mode', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 2, initialOffset: 3.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('the Delta XYZ segment is disabled once two faces are picked', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 2));
      final segmentedButton =
          tester.widget<SegmentedButton<MoveFaceMode>>(find.byType(SegmentedButton<MoveFaceMode>));
      final deltaSegment =
          segmentedButton.segments.firstWhere((s) => s.value == MoveFaceMode.delta);
      expect(deltaSegment.enabled, isFalse);
      final offsetSegment =
          segmentedButton.segments.firstWhere((s) => s.value == MoveFaceMode.offset);
      expect(offsetSegment.enabled, isTrue);
    });

    testWidgets('shows a live face-count summary', (tester) async {
      await tester.pumpWidget(buildPanel(faceCount: 3));
      expect(find.text('Moving 3 faces'), findsOneWidget);
      await tester.pumpWidget(buildPanel(faceCount: 1));
      expect(find.text('Moving 1 face'), findsOneWidget);
      await tester.pumpWidget(buildPanel(faceCount: 0));
      expect(find.text('Tap one or more faces of the same body to move'), findsOneWidget);
    });
  });

  group('MoveFacePanel title', () {
    testWidgets('defaults to "Move Face"', (tester) async {
      await tester.pumpWidget(buildPanel());
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
              mode: MoveFaceMode.offset,
              onModeChanged: (_) {},
              faceCount: 1,
              initialOffset: 1.0,
              onSetDirectionFixedAxis: (_) {},
              onConfirm: () {},
              onCancel: () => cancelled = true,
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Cancel'));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
