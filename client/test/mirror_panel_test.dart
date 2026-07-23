import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/mirror_panel.dart';

/// Pattern/Mirror scoping's Phase 1 (`docs/pattern-mirror-scope.md`
/// §2.1/§4): unit-level coverage for [MirrorPanel]'s Confirm-enablement
/// rule - requires [MirrorPanel.hasPlanePicked], mirroring
/// `fillet_panel_test.dart`'s own coverage of [FilletPanel]'s numeric-field
/// rule, just driven by a bool instead of a text field (Phase 1 has no
/// numeric parameter at all - the only thing to pick is the mirror plane
/// itself, live in the viewport). No `flutter_scene` dependency anywhere in
/// `mirror_panel.dart`'s import chain, so this is a real, runnable widget
/// test in this sandbox.
void main() {
  group('MirrorPanel Confirm enablement', () {
    testWidgets('no plane picked yet disables Confirm', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(hasPlanePicked: false, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('a plane picked enables Confirm', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(hasPlanePicked: true, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping Confirm fires onConfirm once a plane is picked', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              onConfirm: () => confirmed = true,
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      expect(confirmed, isTrue);
    });

    testWidgets('shows hint text while no plane is picked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(hasPlanePicked: false, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Select a face, reference plane, or plane to mirror about'), findsOneWidget);
    });

    testWidgets('shows confirmation text once a plane is picked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(hasPlanePicked: true, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Mirror plane selected'), findsOneWidget);
    });
  });

  group('MirrorPanel title', () {
    testWidgets('defaults to "Mirror"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(hasPlanePicked: false, onConfirm: () {}, onCancel: () {}),
          ),
        ),
      );
      expect(find.text('Mirror'), findsOneWidget);
      expect(find.text('Edit Mirror'), findsNothing);
    });

    testWidgets('shows "Edit Mirror" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              title: 'Edit Mirror',
              hasPlanePicked: true,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Mirror'), findsOneWidget);
    });
  });

  group('MirrorPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: false,
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
