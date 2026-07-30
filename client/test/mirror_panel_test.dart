import 'package:flutter/material.dart';
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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
              onPickSourceFeatures: () {},
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

  group('Pattern/Mirror scoping Phase 6: MirrorPanel source Features from tree', () {
    testWidgets('shows "No Features added" when sourceFeatureIds is empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onPickSourceFeatures: () {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('No Features added from the Build Tree'), findsOneWidget);
    });

    testWidgets('shows the count once sourceFeatureIds is non-empty', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              sourceFeatureIds: const ['f1', 'f2'],
              onPickSourceFeatures: () {},
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      expect(find.text('2 Features added from the Build Tree'), findsOneWidget);
    });

    testWidgets('tapping "Add from Tree" fires onPickSourceFeatures', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MirrorPanel(
              hasPlanePicked: true,
              merge: MergeMode.keepSeparate,
              onMergeChanged: (_) {},
              onPickSourceFeatures: () => tapped = true,
              onConfirm: () {},
              onCancel: () {},
            ),
          ),
        ),
      );
      await tester.tap(find.text('Add from Tree'));
      expect(tapped, isTrue);
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
              onPickSourceFeatures: () {},
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
