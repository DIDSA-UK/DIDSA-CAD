import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/offset_surface_panel.dart';

/// Phase 2 surfacing package, fourth/last entry: unit-level coverage for
/// [OffsetSurfacePanel]'s Confirm-enablement rule (needs both a resolved
/// source *and* a valid, non-zero distance) and its From Face/From Surface
/// [OffsetSurfaceSourceKind] toggle - mirrors `move_face_panel_test.dart`'s
/// own coverage of [MoveFacePanel]'s analogous mode toggle/field rules. No
/// `flutter_scene` dependency anywhere in `offset_surface_panel.dart`'s
/// import chain, so this is a real, runnable widget test in this sandbox.
void main() {
  Widget buildPanel({
    OffsetSurfaceSourceKind kind = OffsetSurfaceSourceKind.face,
    void Function(OffsetSurfaceSourceKind)? onKindChanged,
    String? sourceSummary,
    bool hasSource = false,
    VoidCallback? onPickSurface,
    double initialDistance = 1.0,
    void Function(double)? onDistanceChanged,
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: OffsetSurfacePanel(
            kind: kind,
            onKindChanged: onKindChanged ?? (_) {},
            sourceSummary: sourceSummary,
            hasSource: hasSource,
            onPickSurface: onPickSurface ?? () {},
            initialDistance: initialDistance,
            onDistanceChanged: onDistanceChanged,
            onConfirm: onConfirm ?? () {},
            onCancel: onCancel ?? () {},
          ),
        ),
      );

  group('OffsetSurfacePanel Confirm enablement', () {
    testWidgets('no source and a valid distance stays disabled', (tester) async {
      await tester.pumpWidget(buildPanel(hasSource: false, initialDistance: 1.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a source and a zero distance stays disabled', (tester) async {
      await tester.pumpWidget(buildPanel(hasSource: true, initialDistance: 0.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a source and a valid non-zero distance enables Confirm', (tester) async {
      await tester.pumpWidget(buildPanel(hasSource: true, initialDistance: 2.0));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('clearing the distance field to zero disables Confirm live', (tester) async {
      await tester.pumpWidget(buildPanel(hasSource: true, initialDistance: 2.0));
      await tester.enterText(find.byType(TextField), '0');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('entering a valid distance fires onDistanceChanged', (tester) async {
      double? lastDistance;
      await tester.pumpWidget(buildPanel(
        hasSource: true,
        initialDistance: 0.0,
        onDistanceChanged: (value) => lastDistance = value,
      ));
      await tester.enterText(find.byType(TextField), '3.5');
      await tester.pump();
      expect(lastDistance, 3.5);
    });
  });

  group('OffsetSurfacePanel source kind toggle', () {
    testWidgets('shows both From Face and From Surface segments', (tester) async {
      await tester.pumpWidget(buildPanel());
      expect(find.text('From Face'), findsOneWidget);
      expect(find.text('From Surface'), findsOneWidget);
    });

    testWidgets('tapping From Surface fires onKindChanged', (tester) async {
      OffsetSurfaceSourceKind? changedTo;
      await tester.pumpWidget(buildPanel(onKindChanged: (kind) => changedTo = kind));
      await tester.tap(find.text('From Surface'));
      await tester.pump();
      expect(changedTo, OffsetSurfaceSourceKind.surface);
    });

    testWidgets('the Pick/Change button only shows in From Surface mode', (tester) async {
      await tester.pumpWidget(buildPanel(kind: OffsetSurfaceSourceKind.face));
      expect(find.widgetWithText(TextButton, 'Pick'), findsNothing);

      await tester.pumpWidget(buildPanel(kind: OffsetSurfaceSourceKind.surface, hasSource: false));
      expect(find.widgetWithText(TextButton, 'Pick'), findsOneWidget);

      await tester.pumpWidget(buildPanel(kind: OffsetSurfaceSourceKind.surface, hasSource: true));
      expect(find.widgetWithText(TextButton, 'Change'), findsOneWidget);
    });
  });

  group('OffsetSurfacePanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(buildPanel(onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });
}
