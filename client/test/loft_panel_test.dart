import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/loft_panel.dart';

void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    List<double?> seams = const [null, 0.25],
    List<bool> reverse = const [false, true],
    List<bool> profilePicked = const [false, true],
    int? pickingProfile,
    void Function(int, double?)? onSeam,
    void Function(int, bool)? onReverse,
    void Function(int)? onPick,
    void Function(int)? onClear,
    List<int> guideSegmentCounts = const [],
    int draftGuideSegments = 0,
    bool pickingGuide = false,
    List<String> warnings = const [],
    VoidCallback? onAddGuide,
    VoidCallback? onFinishGuide,
    VoidCallback? onCancelGuide,
    void Function(int)? onRemoveGuide,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(900, 1600);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          LoftPanel(
            sectionCount: 2,
            targetBodyCount: 0,
            alignmentPointsSet: const [false, false],
            guideSegmentCounts: guideSegmentCounts,
            draftGuideSegments: draftGuideSegments,
            warnings: warnings,
            pickingAlignmentPointIndex: null,
            pickingGuideCurve: pickingGuide,
            onPickAlignmentPoint: (_) {},
            onClearAlignmentPoint: (_) {},
            onCancelAlignmentPointPick: () {},
            onPickGuideCurve: onAddGuide ?? () {},
            onFinishGuideCurve: onFinishGuide ?? () {},
            onRemoveGuideCurve: onRemoveGuide ?? (_) {},
            onCancelGuideCurvePick: onCancelGuide ?? () {},
            onChanged: (_, __, ___, ____) {},
            onConfirm: () {},
            onCancel: () {},
            seamParams: seams,
            reverseFlags: reverse,
            profilePicked: profilePicked,
            pickingProfileIndex: pickingProfile,
            onSeamChanged: onSeam ?? (_, __) {},
            onReverseChanged: onReverse ?? (_, __) {},
            onPickProfile: onPick ?? (_) {},
            onClearProfile: onClear ?? (_) {},
          ),
        ]),
      ),
    ));
    await tester.tap(find.text('Connection point & direction'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows each section\'s start as auto or a percentage', (tester) async {
    await pumpPanel(tester);
    expect(find.text('Section 1 start: auto'), findsOneWidget);
    expect(find.text('Section 2 start: 25%'), findsOneWidget);
  });

  testWidgets('the reverse switch and Auto button report per-section changes', (tester) async {
    final reversed = <(int, bool)>[];
    final seams = <(int, double?)>[];
    await pumpPanel(tester, onReverse: (i, v) => reversed.add((i, v)), onSeam: (i, v) => seams.add((i, v)));

    await tester.tap(find.byKey(const ValueKey('loft-reverse-switch-0')));
    await tester.pump();
    expect(reversed, [(0, true)]);

    await tester.tap(find.text('Auto')); // only section 2 has an explicit seam
    await tester.pump();
    expect(seams, [(1, null)]);
  });

  testWidgets('the profile row offers Pick when default and Change/clear when picked', (tester) async {
    final picked = <int>[];
    final cleared = <int>[];
    await pumpPanel(tester, onPick: picked.add, onClear: cleared.add);

    expect(find.text('Default (only loop)'), findsOneWidget);
    expect(find.text('Picked'), findsOneWidget);

    await tester.tap(find.text('Pick'));
    await tester.tap(find.text('Change'));
    await tester.tap(find.byTooltip('Use the default profile'));
    expect(picked, [0, 1]);
    expect(cleared, [1]);
  });

  testWidgets('while picking a profile the row asks for a tap in the viewport', (tester) async {
    await pumpPanel(tester, pickingProfile: 0);
    expect(find.text('Tap one of its lines or curves in the viewport…'), findsOneWidget);
  });

  group('guide curves', () {
    testWidgets('start collapsed with no guides and "Add guide" reports a pick', (tester) async {
      var added = 0;
      await pumpPanel(tester, onAddGuide: () => added++);
      await tester.ensureVisible(find.text('Guide curves'));
      await tester.tap(find.text('Guide curves'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No guides'), findsOneWidget);
      await tester.ensureVisible(find.text('Add guide'));
      await tester.tap(find.text('Add guide'));
      expect(added, 1);
    });

    testWidgets('lists each guide and removes the one whose X is tapped', (tester) async {
      final removed = <int>[];
      await pumpPanel(tester, guideSegmentCounts: const [1, 3], onRemoveGuide: removed.add);
      // Guides exist, so the tile starts expanded.
      expect(find.text('Guide curves (2)'), findsOneWidget);
      expect(find.text('Guide 1'), findsOneWidget);
      expect(find.text('1 curve'), findsOneWidget);
      expect(find.text('Guide 2'), findsOneWidget);
      expect(find.text('3 curves'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Remove guide 2'));
      await tester.tap(find.byTooltip('Remove guide 2'));
      expect(removed, [1]);
    });

    testWidgets('while picking, shows the count so far with Done and Cancel', (tester) async {
      var done = 0;
      var cancelled = 0;
      await pumpPanel(
        tester,
        guideSegmentCounts: const [2],
        pickingGuide: true,
        draftGuideSegments: 2,
        onFinishGuide: () => done++,
        onCancelGuide: () => cancelled++,
      );
      expect(find.text('Guide 2'), findsOneWidget);
      expect(find.text('2 curves picked'), findsOneWidget);
      await tester.ensureVisible(find.text('Done'));
      await tester.tap(find.text('Done'));
      await tester.ensureVisible(find.byKey(const ValueKey('loft-guide-draft')));
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('loft-guide-draft')), matching: find.text('Cancel')));
      expect(done, 1);
      expect(cancelled, 1);
      expect(find.text('Add guide'), findsNothing);
    });

    testWidgets('Done is disabled until a curve is picked', (tester) async {
      await pumpPanel(tester, pickingGuide: true, draftGuideSegments: 0);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Done')).onPressed, isNull);
    });

    testWidgets('shows the backend warnings for the built loft', (tester) async {
      await pumpPanel(tester, warnings: const ['Guide 1 misses section 2 by 0.30 mm; the surface was bent to meet both.']);
      expect(find.textContaining('Guide 1 misses section 2'), findsOneWidget);
    });
  });
}
