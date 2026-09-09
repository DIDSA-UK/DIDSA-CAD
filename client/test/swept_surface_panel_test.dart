import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/swept_surface_panel.dart';

/// Phase 1 surfacing package: unit-level coverage for [SweptSurfacePanel] -
/// mirrors `extrude_panel_test.dart`'s structure. Unlike [ExtrudePanel]/
/// [RevolveSurfacePanel], this panel has no editable field at all (the path
/// is already fixed by the time it opens) - so its only real behaviour to
/// test is the [ready] gate on Confirm and the path summary line. No
/// `flutter_scene` dependency anywhere in `swept_surface_panel.dart`'s
/// import chain, so this is a real, runnable widget test in this sandbox.
void main() {
  Widget buildPanel({
    String title = 'Swept Surface',
    int pathSegmentCount = 2,
    bool pathIsClosed = false,
    required bool ready,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SweptSurfacePanel(
          title: title,
          pathSegmentCount: pathSegmentCount,
          pathIsClosed: pathIsClosed,
          ready: ready,
          onConfirm: onConfirm ?? () {},
          onCancel: onCancel ?? () {},
        ),
      ),
    );
  }

  group('SweptSurfacePanel Confirm enablement', () {
    testWidgets('disabled while the Feature has not been created yet', (tester) async {
      await tester.pumpWidget(buildPanel(ready: false));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('enabled once the Feature has been created', (tester) async {
      await tester.pumpWidget(buildPanel(ready: true));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping Confirm invokes onConfirm once ready', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(buildPanel(ready: true, onConfirm: () => confirmed = true));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pump();
      expect(confirmed, isTrue);
    });

    testWidgets('tapping Cancel invokes onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(buildPanel(ready: true, onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(cancelled, isTrue);
    });
  });

  group('SweptSurfacePanel path summary', () {
    testWidgets('singular segment count reads "1 segment"', (tester) async {
      await tester.pumpWidget(buildPanel(pathSegmentCount: 1, pathIsClosed: false, ready: true));
      expect(find.text('Path: 1 segment, open'), findsOneWidget);
    });

    testWidgets('plural, closed path reads correctly', (tester) async {
      await tester.pumpWidget(buildPanel(pathSegmentCount: 4, pathIsClosed: true, ready: true));
      expect(find.text('Path: 4 segments, closed'), findsOneWidget);
    });
  });

  group('SweptSurfacePanel title (B4)', () {
    testWidgets('defaults to "Swept Surface"', (tester) async {
      await tester.pumpWidget(buildPanel(ready: false));
      expect(find.text('Swept Surface'), findsOneWidget);
      expect(find.text('Edit Swept Surface'), findsNothing);
    });

    testWidgets('shows "Edit Swept Surface" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(buildPanel(title: 'Edit Swept Surface', ready: true));
      expect(find.text('Edit Swept Surface'), findsOneWidget);
    });
  });
}
