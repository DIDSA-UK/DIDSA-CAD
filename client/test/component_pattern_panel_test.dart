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
    }) {
      return ComponentPatternPanel(
        mode: mode,
        onModeChanged: (_) {},
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
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
        countAngular: 4,
        onCountAngularChanged: (_) {},
        angleTotal: 360.0,
        onAngleTotalChanged: (_) {},
        reverseAngular: false,
        onReverseAngularChanged: (_) {},
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
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
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
        direction: ComponentPatternAxisPreset.x,
        onDirectionChanged: (_) {},
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
  });
}
