import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
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

  group('mateTypeLabel', () {
    test('capitalizes every known type', () {
      expect(mateTypeLabel('coincident'), 'Coincident');
      expect(mateTypeLabel('concentric'), 'Concentric');
      expect(mateTypeLabel('parallel'), 'Parallel');
      expect(mateTypeLabel('distance'), 'Distance');
      expect(mateTypeLabel('angle'), 'Angle');
    });
  });

  group('mateBranchNotice (Phase 2b)', () {
    MateDto mate(String id, String type) => MateDto(id: id, type: type, references: const []);
    BranchChangeDto change(String id) => BranchChangeDto(mateId: id, field: 'secondary_flip', from: false, to: true);

    test('nothing to say without changes, blockers or conflicts', () {
      expect(mateBranchNotice(const [], const []), isNull);
    });

    test('one earlier mate moving is named by its type and Confirm applies it', () {
      final text = mateBranchNotice([change('m1')], [mate('m1', 'distance')])!;
      expect(text, contains('Distance mate'));
      expect(text, contains('Confirm applies it'));
    });

    test('several mates are counted once each, even with two fields changed on one mate', () {
      final text = mateBranchNotice(
        [change('m1'), BranchChangeDto(mateId: 'm1', field: 'alignment', from: 'aligned', to: 'anti_aligned'), change('m2')],
        [mate('m1', 'distance'), mate('m2', 'angle')],
      )!;
      expect(text, contains('2 earlier mates'));
      expect(text, contains('Distance mate, Angle mate'));
    });

    test('a user-set mate in the way and a genuine conflict each get their own sentence', () {
      expect(mateBranchNotice(const [], [mate('m1', 'concentric')], blockedBy: ['m1']), contains('you set'));
      expect(mateBranchNotice(const [], [mate('m1', 'concentric')], conflicting: ['m1']), contains('conflicts'));
    });

    test('an unknown mate id falls back to "a mate"', () {
      expect(mateBranchNotice([change('gone')], const []), contains('a mate'));
    });
  });

  group('Phase 3 helpers', () {
    MateSolveAlternativeDto alt(String? alignment, bool? flip) =>
        MateSolveAlternativeDto(alignment: alignment, secondaryFlip: flip);

    test('the flip label says what the flag means for the type', () {
      expect(mateSecondaryFlipLabel('distance'), 'Flip side');
      expect(mateSecondaryFlipLabel('concentric'), 'Flip spin');
      expect(mateSecondaryFlipLabel('angle'), 'Supplement');
    });

    test('a negative distance is not a value, an angle may be', () {
      expect(parseMateValue('distance', '-3'), isNull);
      expect(parseMateValue('distance', '0'), 0);
      expect(parseMateValue('distance', '12.5'), 12.5);
      expect(parseMateValue('angle', '-30'), -30);
      expect(parseMateValue('distance', 'abc'), isNull);
      expect(mateValueError('distance', '-3'), isNotNull);
      expect(mateValueError('distance', '3'), isNull);
      expect(mateValueError('angle', '-3'), isNull);
    });

    test('the current placement is found among the alternatives', () {
      final list = [alt('anti_aligned', true), alt('anti_aligned', false), alt('aligned', true), alt('aligned', false)];
      expect(mateAlternativeIndex(list, 'aligned', true), 2);
      expect(mateAlternativeIndex(list, 'aligned', null), isNull);
      expect(mateAlternativeIndex(const [], 'aligned', true), isNull);
    });

    test('Next solution steps through the alternatives, wraps, and starts at the nearest when nothing matches', () {
      final list = [alt('anti_aligned', true), alt('anti_aligned', false), alt('aligned', true)];
      expect(mateNextAlternative(list, 'anti_aligned', true), same(list[1]));
      expect(mateNextAlternative(list, 'aligned', true), same(list[0]));
      expect(mateNextAlternative(list, null, null), same(list[0]));
    });

    test('there is nothing to step to with fewer than two alternatives', () {
      expect(mateNextAlternative(const [], null, null), isNull);
      expect(mateNextAlternative([alt('aligned', null)], 'aligned', null), isNull);
    });
  });

  group('MateBranchControls', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    MateBranchControls controls({
      String type = 'distance',
      List<String> shown = const ['alignment', 'secondary_flip'],
      String? alignment,
      String? resolvedAlignment = 'anti_aligned',
      bool? secondaryFlip,
      bool? resolvedSecondaryFlip = true,
      int count = 4,
      int? index = 0,
      ValueChanged<String>? onAlignment,
      ValueChanged<bool>? onFlip,
      VoidCallback? onNext,
    }) =>
        MateBranchControls(
          mateType: type,
          controls: shown,
          alignment: alignment,
          resolvedAlignment: resolvedAlignment,
          secondaryFlip: secondaryFlip,
          resolvedSecondaryFlip: resolvedSecondaryFlip,
          alternativeCount: count,
          alternativeIndex: index,
          onAlignmentChanged: onAlignment ?? (_) {},
          onSecondaryFlipChanged: onFlip ?? (_) {},
          onNextSolution: onNext ?? () {},
        );

    testWidgets('shows exactly the controls the preview names', (tester) async {
      await tester.pumpWidget(wrap(controls()));
      expect(find.byKey(const ValueKey('mate-alignment')), findsOneWidget);
      expect(find.text('Flip side'), findsOneWidget);

      await tester.pumpWidget(wrap(controls(shown: const ['alignment'], count: 0)));
      expect(find.byKey(const ValueKey('mate-alignment')), findsOneWidget);
      expect(find.byKey(const ValueKey('mate-secondary-flip')), findsNothing);

      await tester.pumpWidget(wrap(controls(type: 'angle', shown: const ['secondary_flip'], count: 0)));
      expect(find.byKey(const ValueKey('mate-alignment')), findsNothing);
      expect(find.text('Supplement'), findsOneWidget);

      await tester.pumpWidget(wrap(controls(shown: const [], count: 0)));
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('an ANGLE about a hinge names its alignment as the swing direction', (tester) async {
      await tester.pumpWidget(wrap(controls(type: 'angle')));
      expect(find.text('Swing direction'), findsOneWidget);
      expect(find.text('Positive'), findsOneWidget);
      expect(find.text('Negative'), findsOneWidget);
      expect(find.text('Aligned'), findsNothing);
      expect(mateAlignmentTitle('distance'), 'Orientation');
      expect(mateAlignmentLabel('anti_aligned'), 'Anti-aligned');
    });

    testWidgets('Closest is marked auto and shows the resolved value; a choice drops the marker', (tester) async {
      await tester.pumpWidget(wrap(controls()));
      expect(find.byKey(const ValueKey('mate-alignment-auto')), findsOneWidget);
      var segmented = tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('mate-alignment')));
      expect(segmented.selected, {'anti_aligned'});
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('mate-secondary-flip'))).value, isTrue);

      await tester.pumpWidget(wrap(controls(alignment: 'aligned', secondaryFlip: false)));
      expect(find.byKey(const ValueKey('mate-alignment-auto')), findsNothing);
      segmented = tester.widget<SegmentedButton<String>>(find.byKey(const ValueKey('mate-alignment')));
      expect(segmented.selected, {'aligned'});
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('mate-secondary-flip'))).value, isFalse);
    });

    testWidgets('picking an orientation and toggling the flip report the choice', (tester) async {
      String? picked;
      bool? flip;
      await tester.pumpWidget(wrap(controls(onAlignment: (a) => picked = a, onFlip: (f) => flip = f)));
      await tester.tap(find.text('Aligned'));
      await tester.pump();
      expect(picked, 'aligned');
      await tester.tap(find.byKey(const ValueKey('mate-secondary-flip')));
      await tester.pump();
      expect(flip, isFalse); // it was on (resolved true): the tap turns it off
    });

    testWidgets('Next solution says where it is, and only shows with two or more alternatives', (tester) async {
      var taps = 0;
      await tester.pumpWidget(wrap(controls(index: 1, onNext: () => taps++)));
      expect(find.text('Next solution (2 of 4)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mate-next-solution')));
      expect(taps, 1);

      await tester.pumpWidget(wrap(controls(index: null)));
      expect(find.text('Next solution (4 available)'), findsOneWidget);

      await tester.pumpWidget(wrap(controls(count: 1)));
      expect(find.byKey(const ValueKey('mate-next-solution')), findsNothing);
    });
  });

  group('MatePanel branch controls', () {
    testWidgets('are placed in the panel when given, and the distance field refuses a negative value', (tester) async {
      double? sent = 1;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MatePanel(
            selectedEntities: const {},
            bodyNames: const {},
            mateType: 'distance',
            value: 5,
            branchControls: MateBranchControls(
              mateType: 'distance',
              controls: const ['alignment', 'secondary_flip'],
              alignment: null,
              resolvedAlignment: 'aligned',
              secondaryFlip: null,
              resolvedSecondaryFlip: false,
              alternativeCount: 4,
              alternativeIndex: 0,
              onAlignmentChanged: (_) {},
              onSecondaryFlipChanged: (_) {},
              onNextSolution: () {},
            ),
            allowRotation: true,
            onMateTypeChanged: (_) {},
            onValueChanged: (v) => sent = v,
            onAllowRotationChanged: (_) {},
            saving: false,
            error: null,
            onConfirm: null,
            onCancel: () {},
          ),
        ),
      ));
      expect(find.text('Flip side'), findsOneWidget);
      expect(find.text('Next solution (1 of 4)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('mate-value-distance')), '-4');
      await tester.pump();
      expect(sent, isNull);
      expect(find.textContaining('cannot be negative'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('mate-value-distance')), '0');
      await tester.pump();
      expect(sent, 0);
    });
  });

  group('kMateTypes', () {
    test('has exactly the backend-supported types (the five placing mates and the three couplers)', () {
      expect(kMateTypes, ['coincident', 'concentric', 'parallel', 'distance', 'angle', 'gear', 'rack_pinion', 'screw']);
    });
  });

  group('MatePanel', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('shows the branch notice only when given (Phase 2b)', (tester) async {
      Widget panel({String? notice}) => wrap(MatePanel(
            selectedEntities: const {},
            bodyNames: const {},
            mateType: 'distance',
            value: 5,
            onMateTypeChanged: (_) {},
            onValueChanged: (_) {},
            allowRotation: false,
            onAllowRotationChanged: (_) {},
            saving: false,
            error: null,
            notice: notice,
            onConfirm: null,
            onCancel: () {},
          ));
      await tester.pumpWidget(panel());
      expect(find.byKey(const ValueKey('mate-branch-notice')), findsNothing);
      await tester.pumpWidget(panel(notice: 'To fit, an earlier mate moves.'));
      expect(find.text('To fit, an earlier mate moves.'), findsOneWidget);
    });

    testWidgets('shows a dropdown listing every Mate type', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.text('Angle (degrees)'), findsOneWidget);
    });

    testWidgets('shows Allow rotation for concentric, and no checkbox for parallel', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'concentric',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      // The Aligned / Flip controls come from the preview (`branchControls`), not from the type: none here.
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(find.text('Allow rotation'), findsOneWidget);

      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'parallel',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.byType(CheckboxListTile), findsNothing);
    });

    testWidgets('shows an Allow rotation checkbox only for concentric', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: true,
        onAllowRotationChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      expect(find.text('Allow rotation'), findsNothing);
    });

    testWidgets('unchecking Allow rotation calls onAllowRotationChanged(false)', (tester) async {
      bool? changedTo;
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'concentric',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: true,
        onAllowRotationChanged: (checked) => changedTo = checked,
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));
      await tester.tap(find.text('Allow rotation'));
      expect(changedTo, isFalse);
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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

    testWidgets('names a pick on a placed component by the component, so two picks on two parts differ', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: {
          const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 4, occurrenceId: 'occ-plate'),
          const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b2', id: 4, occurrenceId: 'occ-gear'),
        },
        // the part screen's names map also carries each occurrence's display name, keyed by occurrence id
        bodyNames: const {'b1': 'Body 1', 'b2': 'Body 1', 'occ-plate': 'Plate', 'occ-gear': 'Gear (40 teeth)'},
        mateType: 'gear',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
        saving: false,
        error: null,
        onConfirm: null,
        onCancel: () {},
      )));

      expect(find.text('Plate - Face #4'), findsOneWidget);
      expect(find.text('Gear (40 teeth) - Face #4'), findsOneWidget);
    });

    testWidgets('shows the error text when given one', (tester) async {
      await tester.pumpWidget(wrap(MatePanel(
        selectedEntities: const {},
        bodyNames: const {},
        mateType: 'coincident',
        value: null,
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (_) {},
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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
        onMateTypeChanged: (type) => changedTo = type,
        onValueChanged: (_) {},
        allowRotation: false,
        onAllowRotationChanged: (_) {},
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

    // Bug report 2026-10-14, item 8.
    group('clearing the selection', () {
      MatePanel panel(
        Set<SelectionEntityRef> selected, {
        VoidCallback? onClear,
        ValueChanged<SelectionEntityRef>? onRemove,
        VoidCallback? onConfirm,
      }) =>
          MatePanel(
            selectedEntities: selected,
            bodyNames: const {},
            mateType: 'coincident',
            value: null,
            onMateTypeChanged: (_) {},
            onValueChanged: (_) {},
            allowRotation: false,
            onAllowRotationChanged: (_) {},
            saving: false,
            error: null,
            onConfirm: onConfirm,
            onCancel: () {},
            onClearSelection: onClear,
            onRemoveEntity: onRemove,
          );

      const faceA = SelectionEntityRef(kind: SelectionEntityKind.face, id: 1, bodyId: 'b');
      const faceB = SelectionEntityRef(kind: SelectionEntityKind.face, id: 2, bodyId: 'b');

      testWidgets('no Clear selection button while nothing is selected', (tester) async {
        await tester.pumpWidget(wrap(panel(const {}, onClear: () {})));
        expect(find.text('Clear selection'), findsNothing);
      });

      testWidgets('with two references, Clear selection empties the list and Confirm disables', (tester) async {
        var selected = <SelectionEntityRef>{faceA, faceB};
        await tester.pumpWidget(
          wrap(
            StatefulBuilder(
              builder: (context, setState) => panel(
                selected,
                onClear: () => setState(() => selected = {}),
                onConfirm: selected.length == 2 ? () {} : null,
              ),
            ),
          ),
        );
        expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNotNull);
        expect(find.text('Clear selection'), findsOneWidget);

        await tester.tap(find.text('Clear selection'));
        await tester.pump();

        expect(selected, isEmpty);
        expect(find.text('Clear selection'), findsNothing);
        expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm')).onPressed, isNull);
      });

      testWidgets('the per-row X removes just that reference', (tester) async {
        var selected = <SelectionEntityRef>{faceA, faceB};
        await tester.pumpWidget(
          wrap(
            StatefulBuilder(
              builder: (context, setState) => panel(
                selected,
                onClear: () => setState(() => selected = {}),
                onRemove: (e) => setState(() => selected = {...selected}..remove(e)),
              ),
            ),
          ),
        );
        expect(find.byTooltip('Remove from selection'), findsNWidgets(2));

        await tester.tap(find.byTooltip('Remove from selection').first);
        await tester.pump();

        expect(selected, hasLength(1));
        expect(find.byTooltip('Remove from selection'), findsOneWidget);
      });
    });
  });
}
