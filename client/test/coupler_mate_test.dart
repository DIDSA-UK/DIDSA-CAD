import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';
import 'package:didsa_cad_client/viewport3d/mate_panel.dart';

/// `docs/gears-and-motion-plan.md` M4: the coupler ("motion") mates in the flat app - gear, rack and pinion, screw. Types and labels, the value
/// field (ratio / travel per turn / lead, empty = Auto for gear and rack), the Reverse / Left-hand control relative to the backend's default
/// sense, the mate row's summary, and the DTOs (a mate round trip, the preview's `coupler_value`, the create / update payloads).
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('types, labels and values', () {
    test('the three couplers are listed and labelled', () {
      expect(kCouplerMateTypes, ['gear', 'rack_pinion', 'screw']);
      expect(kMateTypes.sublist(kMateTypes.length - 5, kMateTypes.length - 2), kCouplerMateTypes, reason: 'the couplers come after the placing mates and before the two limits');
      expect(mateTypeLabel('gear'), 'Gear');
      expect(mateTypeLabel('rack_pinion'), 'Rack and pinion');
      expect(mateTypeLabel('screw'), 'Screw');
      expect(isCouplerMateType('screw'), isTrue);
      expect(isCouplerMateType('distance'), isFalse);
    });

    test('only the screw needs a value; gear and rack and pinion may leave it for Auto', () {
      expect(mateTypeNeedsValue('screw'), isTrue);
      expect(mateTypeNeedsValue('gear'), isFalse);
      expect(mateTypeNeedsValue('rack_pinion'), isFalse);
      for (final type in kCouplerMateTypes) {
        expect(mateTypeHasValueField(type), isTrue);
      }
      expect(mateTypeHasValueField('coincident'), isFalse);
    });

    test('value labels and the Auto hint', () {
      expect(mateValueLabel('gear'), 'Ratio (B turns per A turn)');
      expect(mateValueLabel('rack_pinion'), 'Travel per turn (mm)');
      expect(mateValueLabel('screw'), 'Lead (mm per turn)');
      expect(mateValueHelper('gear'), contains('empty'));
      expect(mateValueHelper('gear', autoValue: 0.5), 'Auto: 0.5 (from the teeth)');
      expect(mateValueHelper('rack_pinion', autoValue: 125.664), 'Auto: 125.664 mm per turn (from the teeth)');
      expect(mateValueHelper('screw'), isNull);
    });

    test('a coupler value must be above zero; empty is fine for gear and rack, an error for nothing else to type', () {
      expect(parseMateValue('gear', '0.5'), 0.5);
      expect(parseMateValue('gear', '0'), isNull);
      expect(parseMateValue('screw', '-2'), isNull);
      expect(parseMateValue('gear', ''), isNull);
      expect(mateValueError('gear', ''), isNull);
      expect(mateValueError('gear', '0'), contains('above zero'));
      expect(mateValueError('screw', 'abc'), 'Enter a number above zero');
      expect(mateValueError('rack_pinion', '12'), isNull);
    });

    test('the sense control is called Reverse, or Left-hand for a screw', () {
      expect(mateSecondaryFlipLabel('gear'), 'Reverse');
      expect(mateSecondaryFlipLabel('rack_pinion'), 'Reverse');
      expect(mateSecondaryFlipLabel('screw'), 'Left-hand');
    });
  });

  group('the mate row', () {
    MateDto mate(String type, double? value) => MateDto(id: 'm', type: type, references: const [], value: value);

    test('names and summaries', () {
      expect(mateDisplayName([mate('gear', 0.5), mate('gear', 2.0), mate('screw', 2.0)], 1), 'Gear 2');
      expect(mateDisplayName([mate('rack_pinion', 100)], 0), 'Rack and pinion 1');
      expect(mateValueSummary(mate('gear', 0.5)), '1 : 2');
      expect(mateValueSummary(mate('gear', 2.0)), '1 : 0.5');
      expect(mateValueSummary(mate('rack_pinion', 62.832)), '62.832 mm per turn');
      expect(mateValueSummary(mate('screw', 2)), 'lead 2 mm');
      expect(mateValueSummary(mate('distance', 5)), isNull);
    });

    testWidgets('the tree shows the summary under a coupler row and nothing under others', (tester) async {
      await tester.pumpWidget(wrap(AssemblyTreePanel(visible: true, occurrences: const [], selectedOccurrenceId: null, onOccurrenceTap: (_) {}, onOccurrenceLongPress: (_) {}, onClose: () {}, mates: [mate('gear', 0.5), mate('distance', 5)])));
      expect(find.text('Gear 1'), findsOneWidget);
      expect(find.text('1 : 2'), findsOneWidget);
    });
  });

  group('the sense control', () {
    Widget controls({bool? chosen, bool? base = false, bool? resolved, void Function(bool)? onFlip, String type = 'gear'}) => wrap(MateBranchControls(
          mateType: type,
          controls: const ['secondary_flip'],
          alignment: null,
          resolvedAlignment: null,
          secondaryFlip: chosen,
          resolvedSecondaryFlip: resolved ?? base,
          senseBase: base,
          alternativeCount: 0,
          alternativeIndex: null,
          onAlignmentChanged: (_) {},
          onSecondaryFlipChanged: onFlip ?? (_) {},
          onNextSolution: null,
        ));

    testWidgets('reads Reverse, unchecked until the sense differs from the default, and sends the opposite of the default when checked', (tester) async {
      final sent = <bool>[];
      await tester.pumpWidget(controls(onFlip: sent.add));
      expect(find.text('Reverse'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('mate-secondary-flip'))).value, isFalse);
      await tester.tap(find.byKey(const ValueKey('mate-secondary-flip')));
      expect(sent, [true]); // the default was False (k = -1): Reverse sends True

      await tester.pumpWidget(controls(chosen: true, onFlip: sent.add));
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('mate-secondary-flip'))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('mate-secondary-flip')));
      expect(sent.last, false); // un-reversing goes back to the default
    });

    testWidgets('works from a default of True too (an internal gear pair), and a screw reads Left-hand', (tester) async {
      final sent = <bool>[];
      await tester.pumpWidget(controls(base: true, onFlip: sent.add, type: 'screw'));
      expect(find.text('Left-hand'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('mate-secondary-flip'))).value, isFalse);
      await tester.tap(find.byKey(const ValueKey('mate-secondary-flip')));
      expect(sent, [false]);
    });
  });

  group('the panel', () {
    Widget panel({required String type, double? value, double? autoValue, void Function(double?)? onValue}) => wrap(MatePanel(
          selectedEntities: const {},
          bodyNames: const {},
          mateType: type,
          value: value,
          autoValue: autoValue,
          allowRotation: true,
          onMateTypeChanged: (_) {},
          onValueChanged: onValue ?? (_) {},
          onAllowRotationChanged: (_) {},
          saving: false,
          error: null,
          onConfirm: null,
          onCancel: () {},
        ));

    testWidgets('a gear mate has a ratio field with the Auto hint and the backend ratio', (tester) async {
      double? sent = 1;
      await tester.pumpWidget(panel(type: 'gear', autoValue: 0.5, onValue: (v) => sent = v));
      expect(find.text('Ratio (B turns per A turn)'), findsOneWidget);
      expect(find.text('Auto: 0.5 (from the teeth)'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('mate-value-gear')), '2');
      expect(sent, 2.0);
      await tester.enterText(find.byKey(const ValueKey('mate-value-gear')), '');
      expect(sent, isNull); // empty: Auto
    });

    testWidgets('screw and rack and pinion have their own labels; other types have no value field but distance and angle', (tester) async {
      await tester.pumpWidget(panel(type: 'screw'));
      expect(find.text('Lead (mm per turn)'), findsOneWidget);
      await tester.pumpWidget(panel(type: 'rack_pinion'));
      expect(find.text('Travel per turn (mm)'), findsOneWidget);
      await tester.pumpWidget(panel(type: 'concentric'));
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets('the type list offers the couplers', (tester) async {
      await tester.pumpWidget(panel(type: 'gear'));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('Rack and pinion'), findsOneWidget);
      expect(find.text('Screw'), findsOneWidget);
    });
  });

  group('the API', () {
    test('a coupler MateDto round trips its value and sense', () {
      final dto = MateDto.fromJson({
        'id': 'g',
        'type': 'gear',
        'references': const [],
        'value': 0.5,
        'secondary_flip': false,
        'branch_source': 'auto',
      });
      expect(dto.type, 'gear');
      expect(dto.value, 0.5);
      expect(dto.secondaryFlip, isFalse);
      expect(dto.alignment, isNull);
    });

    test("the preview's coupler_value is read, and absent for other mates", () {
      final dto = MateSolvePreviewDto.fromJson({'converged': true, 'coupler_value': 0.5, 'controls': ['secondary_flip']});
      expect(dto.couplerValue, 0.5);
      expect(dto.controls, ['secondary_flip']);
      expect(MateSolvePreviewDto.fromJson({'converged': true}).couplerValue, isNull);
    });

    test('create sends the type, an empty value as no value, and the chosen sense', () async {
      final bodies = <Map<String, dynamic>>[];
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return jsonResponse({'id': 'g', 'type': 'gear', 'references': const [], 'value': 0.5, 'secondary_flip': true}, status: 201);
        }),
      );
      final mate = await client.createMate('P', type: 'gear', references: const [], secondaryFlip: true);
      expect(bodies.single['type'], 'gear');
      expect(bodies.single.containsKey('value'), isFalse);
      expect(bodies.single['secondary_flip'], true);
      expect(mate.value, 0.5);
    });
  });
}
