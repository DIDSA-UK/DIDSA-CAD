import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/mate_panel.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/width_pick.dart';

/// Width mate (`docs/width-mate-plan.md`, W2): the four-pick state, its refusals, the wire shape, the panel and the DTO.
SelectionEntityRef face(String occurrence, int index, {String body = 'b'}) =>
    SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: body, id: index, occurrenceId: occurrence);

WidthPick picked(List<SelectionEntityRef> faces) {
  var pick = const WidthPick();
  for (final f in faces) {
    final (next, why) = pick.toggle(f);
    expect(why, isNull);
    pick = next;
  }
  return pick;
}

void main() {
  group('WidthPick', () {
    test('counts 1 of 4 .. 4 of 4 and names the step', () {
      var pick = const WidthPick();
      expect(pick.progress, startsWith('1 of 4'));
      pick = picked([face('frame/barA', 7)]);
      expect(pick.progress, startsWith('2 of 4'));
      pick = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0)]);
      expect(pick.progress, startsWith('4 of 4'));
      expect(pick.isComplete, isFalse);
      pick = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]);
      expect(pick.isComplete, isTrue);
      expect(pick.progress, '4 of 4 - ready');
    });

    test('only faces can be picked', () {
      final (pick, why) = const WidthPick().toggle(const SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: 'b', id: 1));
      expect(why, contains('faces'));
      expect(pick.isEmpty, isTrue);
    });

    test('a pair may be made of two parts (a gap of two loose bars, a tab of two parts), 2, 3 or 4 parts in all', () {
      // 2 parts: both faces of each pair on one part
      expect(picked([face('frame', 7), face('frame', 3), face('plate', 0), face('plate', 2)]).isComplete, isTrue);
      // 3 parts: the gap spans two bars
      expect(picked([face('barL', 7), face('barR', 7), face('plate', 0), face('plate', 2)]).isComplete, isTrue);
      // 4 parts: the gap spans two bars and the tab spans two plates
      final four = picked([face('barL', 7), face('barR', 7), face('plateA', 0), face('plateB', 2)]);
      expect(four.isComplete, isTrue);
      final refs = four.references();
      expect(refs[0].midplane!.bOccurrenceId, 'barR');
      expect(refs[1].occurrenceId, 'plateA');
      expect(refs[1].midplane!.bOccurrenceId, 'plateB');
    });

    test('the part(s) to centre must differ from the part(s) of the gap', () {
      final base = picked([face('barL', 7), face('barR', 7)]);
      for (final clash in ['barL', 'barR', 'barL/inner']) {
        final (pick, why) = base.toggle(face(clash, 3));
        expect(why, contains('different part'), reason: clash);
        expect(pick.picks.length, 2);
      }
      final three = picked([face('barL', 7), face('barR', 7), face('plateA', 0)]);
      expect(three.toggle(face('barR', 1)).$2, contains('different part'));
    });

    test('toggling a pick off removes it and every pick after it; Back removes the last', () {
      final full = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]);
      expect(full.toggle(face('frame/barB', 7)).$1.picks, [face('frame/barA', 7)]);
      expect(full.back().picks.length, 3);
      expect(const WidthPick().back().isEmpty, isTrue);
    });

    test('a fifth face is refused', () {
      final full = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]);
      expect(full.toggle(face('plate', 4)).$2, contains('four faces'));
    });

    test('references: gap first, tab second, each a mid-plane; b names its own occurrence only when it differs', () {
      final refs = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]).references();
      expect(refs.length, 2);
      expect(refs[0].occurrenceId, 'frame/barA');
      expect(refs[0].midplane!.bOccurrenceId, 'frame/barB');
      expect(refs[1].occurrenceId, 'plate');
      expect(refs[1].midplane!.bOccurrenceId, isNull);
      expect(refs[1].midplane!.a.faceRef!.index, 0);
      expect(refs[1].midplane!.b.faceRef!.index, 2);
      expect(refs.every((r) => r.subshapeRef == null && r.planeRef == null && r.pointRef == null), isTrue);
    });

    test('wire type: centred is coincident, an offset is a distance', () {
      expect(WidthPick.wireType(null), 'coincident');
      expect(WidthPick.wireType(0), 'coincident');
      expect(WidthPick.wireType(5), 'distance');
      expect(WidthPick.wireValue(null), isNull);
      expect(WidthPick.wireValue(5), 5);
    });
  });

  group('Symmetric (3 picks)', () {
    WidthPick symPicked(List<SelectionEntityRef> faces) {
      var pick = const WidthPick([], true);
      for (final f in faces) {
        final (next, why) = pick.toggle(f);
        expect(why, isNull, reason: '$f');
        pick = next;
      }
      return pick;
    }

    test('counts 1 of 3 .. 3 of 3 and names the steps', () {
      var pick = const WidthPick([], true);
      expect(pick.total, 3);
      expect(pick.progress, startsWith('1 of 3'));
      pick = symPicked([face('left', 1), face('right', 0)]);
      expect(pick.progress, contains('3 of 3'));
      expect(pick.progress, contains('mirror plane'));
      expect(pick.slotLabel(2), 'Mirror plane');
      pick = symPicked([face('left', 1), face('right', 0), face('centre', 1)]);
      expect(pick.isComplete, isTrue);
      expect(pick.progress, '3 of 3 - ready');
    });

    test('the two mirrored faces must be on different parts and the mirror plane on a third', () {
      final one = symPicked([face('left', 1)]);
      expect(one.toggle(face('left/inner', 2)).$2, contains('different parts'));
      final two = symPicked([face('left', 1), face('right', 0)]);
      expect(two.toggle(face('left', 3)).$2, contains('mirror plane'));
      expect(two.toggle(face('right', 3)).$2, contains('mirror plane'));
      expect(two.toggle(const SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: 'b', id: 1)).$2, contains('Symmetric'));
      expect(symPicked([face('left', 1), face('right', 0), face('centre', 1)]).toggle(face('centre', 2)).$2, contains('three faces'));
    });

    test('the mate is a mid-plane of the two faces and the mirror plane as an ordinary face reference', () {
      final refs = symPicked([face('left', 1), face('right', 0), face('centre', 1)]).references();
      expect(refs.length, 2);
      expect(refs[0].occurrenceId, 'left');
      expect(refs[0].midplane!.bOccurrenceId, 'right');
      expect(refs[1].occurrenceId, 'centre');
      expect(refs[1].midplane, isNull);
      expect(refs[1].subshapeRef!.index, 1);
      expect(refs[1].subshapeRef!.shapeType, 'face');
    });

    test('a stored Symmetric mate is listed and titled as Symmetric, not Width; it involves all three parts', () {
      final refs = symPicked([face('left', 1), face('right', 0), face('centre', 1)]).references();
      final sym = MateDto(id: 's', type: 'coincident', references: refs);
      final width = MateDto(
          id: 'w',
          type: 'coincident',
          references: picked([face('barL', 7), face('barR', 7), face('plate', 0), face('plate', 2)]).references());
      expect(isSymmetricMate(sym), isTrue);
      expect(isWidthMate(sym), isFalse);
      expect(isSymmetricMate(width), isFalse);
      expect(isWidthMate(width), isTrue);
      expect(mateLabel(sym), 'Symmetric');
      expect(mateLabel(width), 'Width');
      expect(mateDisplayName([sym, width, sym], 2), 'Symmetric 2');
      expect(mateDisplayName([sym, width], 1), 'Width 1');
      expect(mateTopLevelOccurrences(sym), {'left', 'right', 'centre'});
      expect(isMultiPickMateType('symmetric'), isTrue);
      expect(isMultiPickMateType('coincident'), isFalse);
    });

    testWidgets('the panel offers Symmetric, shows three slots and no offset field', (tester) async {
      final pick = symPicked([face('left', 1)]);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MatePanel(
            selectedEntities: pick.picks.toSet(),
            bodyNames: const {},
            mateType: kSymmetricMateType,
            value: null,
            onMateTypeChanged: (_) {},
            onValueChanged: (_) {},
            allowRotation: true,
            onAllowRotationChanged: (_) {},
            saving: false,
            error: null,
            onConfirm: null,
            onCancel: () {},
            widthPick: pick,
            onWidthOffsetChanged: (_) {},
            onWidthBack: () {},
          ),
        ),
      ));
      expect(find.textContaining('2 of 3'), findsOneWidget);
      expect(find.textContaining('Mirror plane'), findsOneWidget);
      expect(find.textContaining('Tab face'), findsNothing);
      expect(find.byKey(const ValueKey('width-offset')), findsNothing);
    });
  });

  group('DTO', () {
    test('a mid-plane reference round-trips through JSON; refs without one are unchanged', () {
      final ref = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]).references().first;
      final json = ref.toJson();
      expect(json['midplane'], isNotNull);
      expect(json.containsKey('subshape_ref'), isFalse);
      final back = MateEntityRefDto.fromJson(json);
      expect(back.toJson(), json);
      expect(back.midplane!.bOccurrenceId, 'frame/barB');
      final plain = MateEntityRefDto(occurrenceId: 'o', subshapeRef: const SubShapeRefDto(bodyId: 'b', shapeType: 'face', index: 1));
      expect(plain.toJson().containsKey('midplane'), isFalse);
      expect(MateEntityRefDto.fromJson(plain.toJson()).midplane, isNull);
    });

    test('a stored Width mate is listed and titled as Width', () {
      final refs = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0), face('plate', 2)]).references();
      final width = MateDto(id: 'w', type: 'coincident', references: refs);
      final plain = MateDto(id: 'p', type: 'coincident', references: const []);
      expect(isWidthMate(width), isTrue);
      expect(isWidthMate(plain), isFalse);
      expect(mateLabel(width), 'Width');
      expect(mateLabel(plain), 'Coincident');
      expect(mateDisplayName([plain, width, width], 2), 'Width 2');
      expect(mateDisplayName([plain, width], 0), 'Coincident 1');
    });

    test('a Width mate over 4 parts involves all four top-level occurrences (delete / count / re-solve rely on it)', () {
      final refs = picked([face('barL', 7), face('barR/inner', 7), face('plateA', 0), face('plateB', 2)]).references();
      expect(mateTopLevelOccurrences(MateDto(id: 'w', type: 'coincident', references: refs)), {'barL', 'barR', 'plateA', 'plateB'});
    });
  });

  group('offset', () {
    test('empty is centred; a negative or non-numeric offset is refused', () {
      expect(parseWidthOffset(''), isNull);
      expect(parseWidthOffset('5'), 5);
      expect(parseWidthOffset('-1'), isNull);
      expect(widthOffsetError(''), isNull);
      expect(widthOffsetError('x'), isNotNull);
      expect(widthOffsetError('-1'), contains('Flip side'));
    });
  });

  group('MatePanel in Width mode', () {
    Widget panel(WidthPick pick, {String? error, VoidCallback? onBack, bool withWidth = true}) => MaterialApp(
          home: Scaffold(
            body: MatePanel(
              selectedEntities: pick.picks.toSet(),
              bodyNames: const {},
              mateType: withWidth ? kWidthMateType : 'coincident',
              value: null,
              onMateTypeChanged: (_) {},
              onValueChanged: (_) {},
              allowRotation: true,
              onAllowRotationChanged: (_) {},
              saving: false,
              error: null,
              onConfirm: null,
              onCancel: () {},
              widthPick: withWidth ? pick : null,
              widthError: error,
              onWidthOffsetChanged: (_) {},
              onWidthBack: onBack,
            ),
          ),
        );

    testWidgets('shows N of 4, the four slots and Back', (tester) async {
      var backs = 0;
      await tester.pumpWidget(panel(picked([face('frame/barA', 7), face('frame/barB', 7)]), onBack: () => backs++));
      expect(find.byKey(const ValueKey('width-progress')), findsOneWidget);
      expect(find.textContaining('3 of 4'), findsOneWidget);
      expect(find.textContaining('Gap face 1'), findsOneWidget);
      expect(find.textContaining('Tab face 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('width-offset')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('width-back')));
      expect(backs, 1);
    });

    testWidgets('shows the parallel error', (tester) async {
      await tester.pumpWidget(panel(picked([face('frame/barA', 7), face('frame/barB', 3)]), error: 'These two faces are not parallel'));
      expect(find.byKey(const ValueKey('width-error')), findsOneWidget);
    });

    testWidgets('the type list offers Width only in the new-mate flow, and other types show no Width UI', (tester) async {
      await tester.pumpWidget(panel(const WidthPick(), withWidth: false));
      expect(find.byKey(const ValueKey('width-progress')), findsNothing);
      expect(find.byKey(const ValueKey('width-offset')), findsNothing);
    });
  });
}
