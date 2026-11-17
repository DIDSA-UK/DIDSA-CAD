import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
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
            body: MirrorPanel(
              hasPlanePicked: false,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
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

    testWidgets('a plane picked enables Confirm', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
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
    });

    testWidgets('tapping Confirm fires onConfirm once a plane is picked', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
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
            body: MirrorPanel(
              hasPlanePicked: false,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Select a face, reference plane, or plane to mirror about'), findsOneWidget);
    });

    testWidgets('shows confirmation text once a plane is picked', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
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
            body: MirrorPanel(
              hasPlanePicked: false,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
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
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('Edit Mirror'), findsOneWidget);
    });
  });

  group('MirrorPanel merge toggle', () {
    testWidgets('shows Keep Separate as selected by default', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      final segmentedButton = tester.widget<SegmentedButton<MergeMode>>(find.byType(SegmentedButton<MergeMode>));
      expect(segmentedButton.selected, {MergeMode.keepSeparate});
    });

    testWidgets('reflects fuseIntoOne as selected', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.fuseIntoOne,
              onMergeChanged: (_) {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      final segmentedButton = tester.widget<SegmentedButton<MergeMode>>(find.byType(SegmentedButton<MergeMode>));
      expect(segmentedButton.selected, {MergeMode.fuseIntoOne});
    });

    testWidgets('tapping "Merge into One Body" fires onMergeChanged with fuseIntoOne', (tester) async {
      MergeMode? changedTo;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (m) => changedTo = m,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Merge into One Body'));
      expect(changedTo, MergeMode.fuseIntoOne);
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
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
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
  // Bug report 2026-11-17 item M.3: the tabs + Scope field on top, then the Mirror plane field, which takes the picks once tapped.
  group('MirrorPanel scope and plane field', () {
    Widget panel({bool scopeValid = true, bool planeActive = true, VoidCallback? onActivatePlane, String? toolFeatureSummary}) => MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              scopeSection: const Text('SCOPE'),
              scopeValid: scopeValid,
              planeActive: planeActive,
              onActivatePlane: onActivatePlane,
              toolFeatureSummary: toolFeatureSummary,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        );

    testWidgets('the scope sits above the Mirror plane field, and an invalid scope disables Confirm', (tester) async {
      await tester.pumpWidget(panel(scopeValid: false));
      expect(tester.getTopLeft(find.text('SCOPE')).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('mirror-plane-field'))).dy));
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
      await tester.pumpWidget(panel());
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNotNull);
    });

    testWidgets('tapping the Mirror plane field makes it the active slot', (tester) async {
      var activated = false;
      await tester.pumpWidget(panel(planeActive: false, onActivatePlane: () => activated = true));
      await tester.tap(find.byKey(const ValueKey('mirror-plane-field')));
      expect(activated, isTrue);
    });

    testWidgets('tool features: "always merges" replaces the merge choice', (tester) async {
      await tester.pumpWidget(panel(toolFeatureSummary: 'Extrude 2'));
      expect(find.textContaining('Mirroring Extrude 2 into its own target'), findsOneWidget);
      expect(find.byType(SegmentedButton<MergeMode>), findsNothing);
    });
  });
}
