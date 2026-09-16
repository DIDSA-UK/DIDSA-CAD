import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/component_pattern_panel.dart';

/// Phase 7 (`docs/assembly-scope.md` §3 item 7 / §2j): unit-level coverage
/// for [ComponentPatternPanel] and its pure helpers - mirrors
/// `mate_panel_test.dart`'s own "no `flutter_scene` dependency, real
/// runnable widget test" shape (this panel has no viewport-picking
/// dependency at all - see the widget's own doc comment).
void main() {
  group('componentPatternAxisPresetVector', () {
    test('maps each preset to its own unit vector', () {
      expect(componentPatternAxisPresetVector(ComponentPatternAxisPreset.x), [1.0, 0.0, 0.0]);
      expect(componentPatternAxisPresetVector(ComponentPatternAxisPreset.y), [0.0, 1.0, 0.0]);
      expect(componentPatternAxisPresetVector(ComponentPatternAxisPreset.z), [0.0, 0.0, 1.0]);
    });
  });

  group('resolveComponentPatternVector', () {
    test('returns the world-axis unit vector for x/y/z, ignoring custom', () {
      expect(
        resolveComponentPatternVector(ComponentPatternAxisPreset.x, [9.0, 9.0, 9.0]),
        [1.0, 0.0, 0.0],
      );
      expect(
        resolveComponentPatternVector(ComponentPatternAxisPreset.y, [9.0, 9.0, 9.0]),
        [0.0, 1.0, 0.0],
      );
    });

    test('returns the custom vector verbatim for custom', () {
      expect(
        resolveComponentPatternVector(ComponentPatternAxisPreset.custom, [2.0, 3.0, 4.0]),
        [2.0, 3.0, 4.0],
      );
    });
  });

  group('presetForVector', () {
    test('recognizes each exact world axis', () {
      expect(presetForVector([1.0, 0.0, 0.0]), ComponentPatternAxisPreset.x);
      expect(presetForVector([0.0, 1.0, 0.0]), ComponentPatternAxisPreset.y);
      expect(presetForVector([0.0, 0.0, 1.0]), ComponentPatternAxisPreset.z);
    });

    test('falls back to custom for anything else', () {
      expect(presetForVector([1.0, 1.0, 0.0]), ComponentPatternAxisPreset.custom);
      expect(presetForVector([0.0, 0.0, -1.0]), ComponentPatternAxisPreset.custom);
    });

    test('tolerates float round-trip noise around a world axis', () {
      expect(presetForVector([1.0000000001, 0.0, -0.0000000001]), ComponentPatternAxisPreset.x);
    });
  });

  group('ComponentPatternMode', () {
    test('apiValue/fromApiValue round-trip both values', () {
      expect(ComponentPatternMode.linear.apiValue, 'linear');
      expect(ComponentPatternMode.circular.apiValue, 'circular');
      expect(ComponentPatternMode.fromApiValue('linear'), ComponentPatternMode.linear);
      expect(ComponentPatternMode.fromApiValue('circular'), ComponentPatternMode.circular);
    });

    test('fromApiValue falls back to linear for an unknown value', () {
      expect(ComponentPatternMode.fromApiValue('bogus'), ComponentPatternMode.linear);
    });
  });

  group('ComponentPatternPanel', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    ComponentPatternPanel buildPanel({
      ComponentPatternMode mode = ComponentPatternMode.linear,
      bool saving = false,
      String? error,
      VoidCallback? onConfirm,
      List<String> sourceOccurrenceNames = const ['Bolt'],
      bool pickingMoreSources = false,
      ComponentPatternAxisPreset direction = ComponentPatternAxisPreset.x,
      ComponentPatternAxisPreset axisDirection = ComponentPatternAxisPreset.z,
      String? editingPatternId,
    }) {
      return ComponentPatternPanel(
        mode: mode,
        onModeChanged: (_) {},
        sourceOccurrenceNames: sourceOccurrenceNames,
        onRemoveSource: (_) {},
        pickingMoreSources: pickingMoreSources,
        onPickingMoreSourcesChanged: (_) {},
        direction: direction,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (_) {},
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: axisDirection,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        editingPatternId: editingPatternId,
        saving: saving,
        error: error,
        onConfirm: onConfirm,
        onCancel: () {},
      );
    }

    testWidgets('shows the Linear/Circular mode toggle', (tester) async {
      await tester.pumpWidget(wrap(buildPanel()));
      expect(find.text('Linear'), findsOneWidget);
      expect(find.text('Circular'), findsOneWidget);
    });

    testWidgets('linear mode shows Direction/Count/Spacing/Reverse, not axis fields', (tester) async {
      await tester.pumpWidget(wrap(buildPanel()));
      expect(find.text('Direction'), findsOneWidget);
      expect(find.text('Count'), findsOneWidget);
      expect(find.text('Spacing (mm)'), findsOneWidget);
      expect(find.text('Reverse'), findsOneWidget);
      expect(find.text('Axis origin'), findsNothing);
      expect(find.text('Total angle (degrees)'), findsNothing);
    });

    testWidgets('circular mode shows axis/count-angular/angle fields, not linear ones', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(mode: ComponentPatternMode.circular)));
      expect(find.text('Axis origin'), findsOneWidget);
      expect(find.text('Axis direction'), findsOneWidget);
      expect(find.text('Instance count'), findsOneWidget);
      expect(find.text('Total angle (degrees)'), findsOneWidget);
      expect(find.text('Spacing (mm)'), findsNothing);
      expect(find.text('Count'), findsNothing);
    });

    testWidgets('tapping Circular in the mode toggle calls onModeChanged', (tester) async {
      ComponentPatternMode? changedTo;
      await tester.pumpWidget(wrap(ComponentPatternPanel(
        mode: ComponentPatternMode.linear,
        onModeChanged: (mode) => changedTo = mode,
        sourceOccurrenceNames: const ['Bolt'],
        onRemoveSource: (_) {},
        pickingMoreSources: false,
        onPickingMoreSourcesChanged: (_) {},
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (_) {},
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: ComponentPatternAxisPreset.z,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      await tester.tap(find.text('Circular'));
      await tester.pump();

      expect(changedTo, ComponentPatternMode.circular);
    });

    testWidgets('Confirm is disabled when onConfirm is null', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(onConfirm: null)));
      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'));
      expect(button.onPressed, isNull);
    });

    testWidgets('tapping Confirm invokes onConfirm when enabled', (tester) async {
      var confirmed = false;
      await tester.pumpWidget(wrap(buildPanel(onConfirm: () => confirmed = true)));
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm'));
      await tester.pump();
      expect(confirmed, isTrue);
    });

    testWidgets('shows a progress indicator while saving', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(saving: true)));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('shows the error text when set', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(error: 'ComponentPattern count must be >= 2')));
      expect(find.text('ComponentPattern count must be >= 2'), findsOneWidget);
    });

    testWidgets('tapping Cancel invokes onCancel', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(wrap(ComponentPatternPanel(
        mode: ComponentPatternMode.linear,
        onModeChanged: (_) {},
        sourceOccurrenceNames: const ['Bolt'],
        onRemoveSource: (_) {},
        pickingMoreSources: false,
        onPickingMoreSourcesChanged: (_) {},
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (_) {},
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: ComponentPatternAxisPreset.z,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () => cancelled = true,
      )));
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Cancel'));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(cancelled, isTrue);
    });

    // --- Phase 11 (`docs/assembly-scope.md` §6 `[7]`/`[8]`) -----------------

    testWidgets('shows a Custom segment alongside X/Y/Z for direction/axis direction', (tester) async {
      await tester.pumpWidget(wrap(buildPanel()));
      expect(find.text('Custom'), findsOneWidget);
    });

    testWidgets('the X/Y/Z entry fields are hidden for a preset direction, shown for custom', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(direction: ComponentPatternAxisPreset.x)));
      expect(find.byKey(const ValueKey('component-pattern-field-X')), findsNothing);

      await tester.pumpWidget(wrap(buildPanel(direction: ComponentPatternAxisPreset.custom)));
      expect(find.byKey(const ValueKey('component-pattern-field-X')), findsOneWidget);
      expect(find.byKey(const ValueKey('component-pattern-field-Y')), findsOneWidget);
      expect(find.byKey(const ValueKey('component-pattern-field-Z')), findsOneWidget);
    });

    testWidgets('editing the custom direction X field calls onCustomDirectionChanged', (tester) async {
      List<double>? changedTo;
      await tester.pumpWidget(wrap(ComponentPatternPanel(
        mode: ComponentPatternMode.linear,
        onModeChanged: (_) {},
        sourceOccurrenceNames: const ['Bolt'],
        onRemoveSource: (_) {},
        pickingMoreSources: false,
        onPickingMoreSourcesChanged: (_) {},
        direction: ComponentPatternAxisPreset.custom,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (vector) => changedTo = vector,
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: ComponentPatternAxisPreset.z,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      await tester.enterText(find.byKey(const ValueKey('component-pattern-field-X')), '2.5');
      expect(changedTo, [2.5, 0.0, 0.0]);
    });

    testWidgets('shows one chip per source occurrence name', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(sourceOccurrenceNames: const ['Bolt', 'Washer'])));
      expect(find.widgetWithText(Chip, 'Bolt'), findsOneWidget);
      expect(find.widgetWithText(Chip, 'Washer'), findsOneWidget);
    });

    testWidgets('a lone source chip has no delete affordance', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(sourceOccurrenceNames: const ['Bolt'])));
      final chip = tester.widget<Chip>(find.widgetWithText(Chip, 'Bolt'));
      expect(chip.onDeleted, isNull);
    });

    testWidgets('tapping a chip delete icon invokes onRemoveSource with its index', (tester) async {
      int? removedIndex;
      await tester.pumpWidget(wrap(ComponentPatternPanel(
        mode: ComponentPatternMode.linear,
        onModeChanged: (_) {},
        sourceOccurrenceNames: const ['Bolt', 'Washer'],
        onRemoveSource: (i) => removedIndex = i,
        pickingMoreSources: false,
        onPickingMoreSourcesChanged: (_) {},
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (_) {},
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: ComponentPatternAxisPreset.z,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      final deleteIcon = find.descendant(
        of: find.widgetWithText(Chip, 'Washer'),
        matching: find.byIcon(Icons.cancel),
      );
      await tester.tap(deleteIcon);
      expect(removedIndex, 1);
    });

    testWidgets('the "+ Add source" chip toggles onPickingMoreSourcesChanged', (tester) async {
      bool? picking;
      await tester.pumpWidget(wrap(buildPanel()));
      // Rebuild once with a listener wired, then tap it.
      await tester.pumpWidget(wrap(ComponentPatternPanel(
        mode: ComponentPatternMode.linear,
        onModeChanged: (_) {},
        sourceOccurrenceNames: const ['Bolt'],
        onRemoveSource: (_) {},
        pickingMoreSources: false,
        onPickingMoreSourcesChanged: (value) => picking = value,
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
        customDirection: const [1.0, 0.0, 0.0],
        onCustomDirectionChanged: (_) {},
        count: 3,
        onCountChanged: (_) {},
        spacing: 10.0,
        onSpacingChanged: (_) {},
        reverse: false,
        onReverseChanged: (_) {},
        axisOrigin: const [0.0, 0.0, 0.0],
        onAxisOriginChanged: (_) {},
        axisDirection: ComponentPatternAxisPreset.z,
        onAxisDirectionChanged: (_) {},
        customAxisDirection: const [0.0, 0.0, 1.0],
        onCustomAxisDirectionChanged: (_) {},
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      await tester.tap(find.text('+ Add source'));
      await tester.pump();
      expect(picking, isTrue);
    });

    testWidgets('shows a hint to tap a component in the tree while picking more sources', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(pickingMoreSources: true)));
      expect(find.text('Tap a component in the tree to add it'), findsOneWidget);
    });

    testWidgets('title reads "Pattern Component" when creating, "Edit Pattern" when editing', (tester) async {
      await tester.pumpWidget(wrap(buildPanel()));
      expect(find.text('Pattern Component'), findsOneWidget);

      await tester.pumpWidget(wrap(buildPanel(editingPatternId: 'pat-1')));
      expect(find.text('Edit Pattern'), findsOneWidget);
    });

    testWidgets('confirm button reads "Confirm" when creating, "Save" when editing', (tester) async {
      await tester.pumpWidget(wrap(buildPanel(onConfirm: () {})));
      expect(find.widgetWithText(FilledButton, 'Confirm'), findsOneWidget);

      await tester.pumpWidget(wrap(buildPanel(onConfirm: () {}, editingPatternId: 'pat-1')));
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
    });
  });
}
