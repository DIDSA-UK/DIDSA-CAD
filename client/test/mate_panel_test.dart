import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/mate_panel.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

/// Phase 6 (`docs/assembly-scope.md` §3): unit-level coverage for
/// [MatePanel] and its pure `mateType*` helpers - mirrors `fillet_panel_
/// test.dart`'s own "no `flutter_scene` dependency, real runnable widget
/// test" shape exactly (`selection_hit_test.dart`'s own import chain is
/// likewise `flutter_scene`-free).
void main() {
  group('mateTypeNeedsValue', () {
    test('distance and angle need a value', () {
      expect(mateTypeNeedsValue('distance'), isTrue);
      expect(mateTypeNeedsValue('angle'), isTrue);
    });

    test('coincident, concentric, and parallel do not', () {
      expect(mateTypeNeedsValue('coincident'), isFalse);
      expect(mateTypeNeedsValue('concentric'), isFalse);
      expect(mateTypeNeedsValue('parallel'), isFalse);
    });
  });

  group('mateTypeHasFlip', () {
    test('coincident, concentric, and angle have a flip option', () {
      expect(mateTypeHasFlip('coincident'), isTrue);
      expect(mateTypeHasFlip('concentric'), isTrue);
      expect(mateTypeHasFlip('angle'), isTrue);
    });

    test('parallel and distance do not', () {
      expect(mateTypeHasFlip('parallel'), isFalse);
      expect(mateTypeHasFlip('distance'), isFalse);
    });
  });

  group('mateTypeLabel', () {
    test('capitalizes every known type', () {
      expect(mateTypeLabel('coincident'), 'Coincident');
      expect(mateTypeLabel('concentric'), 'Concentric');
      expect(mateTypeLabel('parallel'), 'Parallel');
      expect(mateTypeLabel('distance'), 'Distance');
      expect(mateTypeLabel('angle'), 'Angle');
    });
  });

  group('kMateTypes', () {
    test('has exactly the five backend-supported types', () {
      expect(kMateTypes, ['coincident', 'concentric', 'parallel', 'distance', 'angle']);
    });
  });

  group('MatePanel', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('shows a dropdown listing every Mate type', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
      expect(find.text('Coincident'), findsOneWidget);
    });

    testWidgets('shows a value field for distance, not for coincident', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.byType(TextFormField), findsNothing);

      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'distance',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('Distance (mm)'), findsOneWidget);
    });

    testWidgets('shows "Angle (degrees)" as the value field label for an angle mate', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'angle',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.text('Angle (degrees)'), findsOneWidget);
    });

    testWidgets('shows a Flipped checkbox for concentric, not for parallel', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'concentric',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Flipped'), findsOneWidget);

      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'parallel',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('lists selected entities by body name and kind', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: {
          const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 2),
          const SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: 'b2', id: 0, occurrenceId: 'occ-1'),
        },
        bodyNames: const {'b1': 'Base Body', 'b2': 'Bracket Body'},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      expect(find.text('Base Body - Face #2'), findsOneWidget);
      // An entity with a non-empty occurrenceId is labelled as belonging to
      // a component, distinguishing it from an identically-named root Body.
      expect(find.text('Bracket Body (component) - Vertex #0'), findsOneWidget);
    });

    testWidgets('shows the error text when given one', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: 'Mate could not be solved',
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.text('Mate could not be solved'), findsOneWidget);
    });

    testWidgets('shows a progress indicator while saving, and disables Cancel/Confirm', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: true,
        error: null,
        onConfirm: () {},
        onCancel: () {},
      )));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel')).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
    });

    testWidgets('Cancel fires onCancel when not saving', (tester) async {
      var cancelled = false;
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () => cancelled = true,
      )));
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      expect(cancelled, isTrue);
    });

    testWidgets('selecting a Mate type calls onMateTypeChanged', (tester) async {
      String? changedTo;
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        flipped: false,
        onMateTypeChanged: (type) => changedTo = type,
        onValueChanged: (_) {},
        onFlippedChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Concentric').last);
      await tester.pumpAndSettle();

      expect(changedTo, 'concentric');
    });
  });
}
