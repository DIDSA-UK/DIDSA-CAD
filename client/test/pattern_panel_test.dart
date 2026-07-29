import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/pattern_panel.dart';

/// Pattern/Mirror scoping's Phase 2 (`docs/pattern-mirror-scope.md`
/// §2.2/§4): unit-level coverage for [PatternPanel]'s Confirm-enablement
/// rule and its X/Y/Z/reverse/second-direction controls - mirrors
/// `mirror_panel_test.dart`'s own coverage shape. No `flutter_scene`
/// dependency anywhere in `pattern_panel.dart`'s import chain, so this is a
/// real, runnable widget test in this sandbox.
void main() {
  Widget harness({
    PatternMode mode = PatternMode.rectangular,
    bool canChangeMode = true,
    void Function(PatternMode mode)? onModeChanged,
    bool hasDirection1 = false,
    String? direction1Summary,
    int initialCount1 = 2,
    double initialSpacing1 = 10.0,
    bool reverse1 = false,
    void Function(String axis)? onSetDirection1FixedAxis,
    void Function(int count)? onCount1Changed,
    void Function(double spacing)? onSpacing1Changed,
    void Function(bool reverse)? onReverse1Changed,
    bool hasSecondDirection = false,
    void Function(bool enabled)? onSecondDirectionToggled,
    bool hasDirection2 = false,
    String? direction2Summary,
    int initialCount2 = 1,
    double initialSpacing2 = 0.0,
    bool reverse2 = false,
    int activeDirectionSlot = 1,
    void Function(int slot)? onActiveDirectionSlotChanged,
    bool hasAxis = false,
    String? axisSummary,
    int initialCountAngular = 2,
    double initialAngleTotal = 360.0,
    bool reverseAngular = false,
    void Function(int count)? onCountAngularChanged,
    void Function(double angle)? onAngleTotalChanged,
    void Function(bool reverse)? onReverseAngularChanged,
    MergeMode merge = MergeMode.keepSeparate,
    void Function(MergeMode merge)? onMergeChanged,
    String title = 'Pattern',
    VoidCallback? onConfirm,
    VoidCallback? onCancel,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PatternPanel(
          title: title,
          mode: mode,
          canChangeMode: canChangeMode,
          onModeChanged: onModeChanged ?? (_) {},
          hasDirection1: hasDirection1,
          direction1Summary: direction1Summary,
          onSetDirection1FixedAxis: onSetDirection1FixedAxis ?? (_) {},
          initialCount1: initialCount1,
          initialSpacing1: initialSpacing1,
          reverse1: reverse1,
          onCount1Changed: onCount1Changed,
          onSpacing1Changed: onSpacing1Changed,
          onReverse1Changed: onReverse1Changed,
          hasSecondDirection: hasSecondDirection,
          onSecondDirectionToggled: onSecondDirectionToggled ?? (_) {},
          hasDirection2: hasDirection2,
          direction2Summary: direction2Summary,
          onSetDirection2FixedAxis: (_) {},
          initialCount2: initialCount2,
          initialSpacing2: initialSpacing2,
          reverse2: reverse2,
          activeDirectionSlot: activeDirectionSlot,
          onActiveDirectionSlotChanged: onActiveDirectionSlotChanged ?? (_) {},
          hasAxis: hasAxis,
          axisSummary: axisSummary,
          initialCountAngular: initialCountAngular,
          initialAngleTotal: initialAngleTotal,
          reverseAngular: reverseAngular,
          onCountAngularChanged: onCountAngularChanged,
          onAngleTotalChanged: onAngleTotalChanged,
          onReverseAngularChanged: onReverseAngularChanged,
          merge: merge,
          onMergeChanged: onMergeChanged ?? (_) {},
          onConfirm: onConfirm ?? () {},
          onCancel: onCancel ?? () {},
        ),
      ),
    );
  }

  group('PatternPanel Confirm enablement', () {
    testWidgets('no Direction 1 picked yet disables Confirm', (tester) async {
      await tester.pumpWidget(harness(hasDirection1: false));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('Direction 1 picked with a valid count/spacing enables Confirm', (tester) async {
      await tester.pumpWidget(harness(hasDirection1: true));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('count_1 of 1 with no second direction disables Confirm (no-op pattern)', (tester) async {
      await tester.pumpWidget(harness(hasDirection1: true, initialCount1: 1));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('second direction enabled but not yet picked disables Confirm', (tester) async {
      await tester.pumpWidget(
        harness(hasDirection1: true, hasSecondDirection: true, hasDirection2: false),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('both directions picked with valid counts enables Confirm', (tester) async {
      await tester.pumpWidget(
        harness(
          hasDirection1: true,
          hasSecondDirection: true,
          hasDirection2: true,
          initialCount2: 2,
          initialSpacing2: 10.0,
        ),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('tapping Confirm fires onConfirm once valid', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(harness(hasDirection1: true, onConfirm: () => confirmed = true));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      expect(confirmed, isTrue);
    });
  });

  group('PatternPanel Direction 1 controls', () {
    testWidgets('tapping X/Y/Z fires onSetDirection1FixedAxis', (tester) async {
      String? picked;
      await tester.pumpWidget(harness(onSetDirection1FixedAxis: (axis) => picked = axis));
      await tester.tap(find.widgetWithText(OutlinedButton, 'Y'));
      expect(picked, 'y');
    });

    testWidgets('shows the hint text while nothing is picked yet', (tester) async {
      await tester.pumpWidget(harness(hasDirection1: false));
      expect(find.text('Tap an edge or Sketch Line, or pick a fixed axis'), findsOneWidget);
    });

    testWidgets('shows the direction summary once something is picked', (tester) async {
      await tester.pumpWidget(harness(hasDirection1: true, direction1Summary: 'X axis'));
      expect(find.text('X axis'), findsOneWidget);
    });

    testWidgets('tapping the reverse icon fires onReverse1Changed with the flipped value', (tester) async {
      bool? reversed;
      await tester.pumpWidget(harness(reverse1: false, onReverse1Changed: (r) => reversed = r));
      await tester.tap(find.byIcon(Icons.flip));
      expect(reversed, isTrue);
    });
  });

  group('PatternPanel second direction toggle', () {
    testWidgets('Direction 2 controls are hidden until enabled', (tester) async {
      await tester.pumpWidget(harness(hasSecondDirection: false));
      expect(find.text('Direction 2'), findsNothing);
      expect(find.text('Add second direction'), findsOneWidget);
    });

    testWidgets('Direction 2 controls appear once enabled', (tester) async {
      await tester.pumpWidget(harness(hasSecondDirection: true));
      // Two: the segmented-toggle chip label and the section's own heading.
      expect(find.text('Direction 2'), findsNWidgets(2));
      expect(find.text('Remove second direction'), findsOneWidget);
    });

    testWidgets('tapping "Add second direction" fires onSecondDirectionToggled(true)', (tester) async {
      bool? enabled;
      await tester.pumpWidget(
        harness(hasSecondDirection: false, onSecondDirectionToggled: (e) => enabled = e),
      );
      await tester.tap(find.text('Add second direction'));
      expect(enabled, isTrue);
    });

    testWidgets('tapping "Remove second direction" fires onSecondDirectionToggled(false)', (tester) async {
      bool? enabled;
      await tester.pumpWidget(
        harness(hasSecondDirection: true, onSecondDirectionToggled: (e) => enabled = e),
      );
      await tester.tap(find.text('Remove second direction'));
      expect(enabled, isFalse);
    });

    testWidgets('the active-direction-slot toggle only appears once a second direction exists',
        (tester) async {
      await tester.pumpWidget(harness(hasSecondDirection: false));
      // Only the section's own heading - no segmented-toggle chip yet.
      expect(find.text('Direction 1'), findsOneWidget);
      await tester.pumpWidget(harness(hasSecondDirection: true));
      // Now both the segmented-toggle chip and the section's own heading.
      expect(find.text('Direction 1'), findsNWidgets(2));
      expect(find.text('Direction 2'), findsNWidgets(2));
    });
  });

  group('PatternPanel title', () {
    testWidgets('defaults to "Pattern"', (tester) async {
      await tester.pumpWidget(harness());
      expect(find.text('Pattern'), findsOneWidget);
      expect(find.text('Edit Pattern'), findsNothing);
    });

    testWidgets('shows "Edit Pattern" when editing an existing Feature', (tester) async {
      await tester.pumpWidget(harness(title: 'Edit Pattern', hasDirection1: true));
      expect(find.text('Edit Pattern'), findsOneWidget);
    });
  });

  group('PatternPanel Cancel', () {
    testWidgets('Cancel is always enabled and fires onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(harness(onCancel: () => cancelled = true));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });
  });

  group('PatternPanel mode toggle', () {
    testWidgets('shown when canChangeMode is true', (tester) async {
      await tester.pumpWidget(harness(canChangeMode: true));
      expect(find.text('Rectangular'), findsOneWidget);
      expect(find.text('Circular'), findsOneWidget);
    });

    testWidgets('hidden when canChangeMode is false (editing an existing Feature)', (tester) async {
      await tester.pumpWidget(harness(canChangeMode: false));
      expect(find.text('Rectangular'), findsNothing);
      expect(find.text('Circular'), findsNothing);
    });

    testWidgets('tapping Circular fires onModeChanged', (tester) async {
      PatternMode? picked;
      await tester.pumpWidget(harness(onModeChanged: (mode) => picked = mode));
      await tester.tap(find.text('Circular'));
      expect(picked, PatternMode.circular);
    });

    testWidgets('Rectangular mode shows direction fields, not the axis field', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.rectangular));
      expect(find.text('Direction 1'), findsOneWidget);
      expect(find.text('Axis'), findsNothing);
    });

    testWidgets('Circular mode shows the axis field, not direction fields', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular));
      expect(find.text('Axis'), findsOneWidget);
      expect(find.text('Direction 1'), findsNothing);
    });
  });

  group('PatternPanel Circular Confirm enablement', () {
    testWidgets('no axis picked yet disables Confirm', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: false));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('axis picked with a valid count/angle enables Confirm', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: true));
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNotNull,
      );
    });

    testWidgets('count_angular of 1 disables Confirm (no-op pattern)', (tester) async {
      await tester.pumpWidget(
        harness(mode: PatternMode.circular, hasAxis: true, initialCountAngular: 1),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });

    testWidgets('an invalid angle_total disables Confirm', (tester) async {
      await tester.pumpWidget(
        harness(mode: PatternMode.circular, hasAxis: true, initialAngleTotal: 0),
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed,
        isNull,
      );
    });
  });

  group('PatternPanel Circular axis controls', () {
    testWidgets('shows the hint text while nothing is picked yet', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: false));
      expect(find.text('Tap an edge, a cylindrical face, or a Sketch Line for the axis'), findsOneWidget);
    });

    testWidgets('shows the axis summary once something is picked', (tester) async {
      await tester.pumpWidget(
        harness(mode: PatternMode.circular, hasAxis: true, axisSummary: 'Circular edge selected'),
      );
      expect(find.text('Circular edge selected'), findsOneWidget);
    });

    testWidgets('editing count_angular fires onCountAngularChanged', (tester) async {
      int? count;
      await tester.pumpWidget(
        harness(mode: PatternMode.circular, hasAxis: true, onCountAngularChanged: (c) => count = c),
      );
      await tester.enterText(find.widgetWithText(TextField, 'Count'), '6');
      expect(count, 6);
    });

    testWidgets('editing angle_total fires onAngleTotalChanged', (tester) async {
      double? angle;
      await tester.pumpWidget(
        harness(mode: PatternMode.circular, hasAxis: true, onAngleTotalChanged: (a) => angle = a),
      );
      await tester.enterText(find.widgetWithText(TextField, 'Angle (degrees)'), '180');
      expect(angle, 180.0);
    });

    testWidgets('tapping the reverse icon fires onReverseAngularChanged with the flipped value',
        (tester) async {
      bool? reversed;
      await tester.pumpWidget(
        harness(
          mode: PatternMode.circular,
          hasAxis: true,
          reverseAngular: false,
          onReverseAngularChanged: (r) => reversed = r,
        ),
      );
      await tester.tap(find.byIcon(Icons.flip));
      expect(reversed, isTrue);
    });

    testWidgets('there is no fixed-axis button in Circular mode', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: true));
      expect(find.widgetWithText(OutlinedButton, 'X'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Y'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Z'), findsNothing);
    });
  });

  group('PatternPanel skip-instances hint', () {
    const hintText = 'Tap an instance in the viewport to skip or keep it';

    testWidgets('hidden in Rectangular mode when count_1 * count_2 is 1', (tester) async {
      await tester.pumpWidget(harness(initialCount1: 1, initialCount2: 1));
      expect(find.text(hintText), findsNothing);
    });

    testWidgets('shown in Rectangular mode once count_1 * count_2 is more than 1', (tester) async {
      await tester.pumpWidget(harness(initialCount1: 3, initialCount2: 1));
      expect(find.text(hintText), findsOneWidget);
    });

    testWidgets('hidden in Circular mode when count_angular is 1', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: true, initialCountAngular: 1));
      expect(find.text(hintText), findsNothing);
    });

    testWidgets('shown in Circular mode once count_angular is more than 1', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: true, initialCountAngular: 5));
      expect(find.text(hintText), findsOneWidget);
    });
  });

  group('PatternPanel merge toggle', () {
    testWidgets('shows Keep Separate as selected by default in Rectangular mode', (tester) async {
      await tester.pumpWidget(harness());
      final segmentedButton = tester.widget<SegmentedButton<MergeMode>>(find.byType(SegmentedButton<MergeMode>));
      expect(segmentedButton.selected, {MergeMode.keepSeparate});
    });

    testWidgets('reflects fuseIntoOne as selected', (tester) async {
      await tester.pumpWidget(harness(merge: MergeMode.fuseIntoOne));
      final segmentedButton = tester.widget<SegmentedButton<MergeMode>>(find.byType(SegmentedButton<MergeMode>));
      expect(segmentedButton.selected, {MergeMode.fuseIntoOne});
    });

    testWidgets('tapping "Merge into One Body" fires onMergeChanged with fuseIntoOne', (tester) async {
      MergeMode? changedTo;
      await tester.pumpWidget(harness(onMergeChanged: (m) => changedTo = m));
      await tester.tap(find.text('Merge into One Body'));
      expect(changedTo, MergeMode.fuseIntoOne);
    });

    testWidgets('is shown in Circular mode too', (tester) async {
      await tester.pumpWidget(harness(mode: PatternMode.circular, hasAxis: true));
      expect(find.byType(SegmentedButton<MergeMode>), findsOneWidget);
    });
  });
}
