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

    test('the second face of a pair must be under the same top-level part', () {
      final (pick, why) = picked([face('frame/barA', 7)]).toggle(face('plate', 0));
      expect(why, contains('same part'));
      expect(pick.picks.length, 1);
      // two bars of one frame are the same part
      expect(picked([face('frame/barA', 7)]).toggle(face('frame/barB', 7)).$2, isNull);
    });

    test('the part to centre must differ from the gap', () {
      final base = picked([face('frame/barA', 7), face('frame/barB', 7)]);
      final (pick, why) = base.toggle(face('frame/barC', 3));
      expect(why, contains('different part'));
      expect(pick.picks.length, 2);
    });

    test('the third and fourth face must pair with each other', () {
      final base = picked([face('frame/barA', 7), face('frame/barB', 7), face('plate', 0)]);
      expect(base.toggle(face('other', 1)).$2, contains('same part'));
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
