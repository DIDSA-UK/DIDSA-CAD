import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/ai/ai_theme.dart' show AiPalette;
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/mate_context_menu.dart';
import 'package:didsa_cad_client/viewport3d/mate_reference_state.dart';

/// N1d (`docs/mates-storage-sessions-plan-2026-11-12.md`): the flat app shows what the backend says about a mate's references: a followed
/// reference (info, kept until "Got it"), a held mate (amber, with Confirm) and a lost one (the reason). An older backend's mate shows nothing.

Map<String, dynamic> _mateJson({Map<String, dynamic> extra = const {}}) => {
      'id': 'm1',
      'type': 'coincident',
      'references': [
        {
          'occurrence_id': 'o1',
          'subshape_ref': {'body_id': 'b1', 'shape_type': 'face', 'index': 4},
        },
        {
          'occurrence_id': '',
          'subshape_ref': {'body_id': 'b2', 'shape_type': 'face', 'index': 1},
        },
      ],
      ...extra,
    };

MateDto _fromJson(Map<String, dynamic> extra) => MateDto.fromJson(_mateJson(extra: extra));

/// What an N1b backend sends for a mate it has nothing to say about.
final _clean = {
  'lost_references': <String>[],
  'moved_references': <String>[],
  'followed_references': <String>[],
  'reference_reasons': <String, String>{},
  'held': false,
};

MateDto _followed() => _fromJson({
      ..._clean,
      'followed_references': ['references[0].subshape_ref'],
      'reference_reasons': {'references[0].subshape_ref': 'unique_fingerprint'},
    });

MateDto _held({String status = 'ok'}) => _fromJson({
      ..._clean,
      'status': status,
      'held': true,
      'moved_references': ['references[1].subshape_ref'],
      'reference_reasons': {'references[1].subshape_ref': 'unique_fingerprint_far'},
    });

MateDto _lost() => _fromJson({
      ..._clean,
      'status': 'broken',
      'lost_references': ['references[0].subshape_ref'],
      'reference_reasons': {'references[0].subshape_ref': 'no_match'},
    });

/// An older backend: none of the N1b fields.
MateDto _old() => _fromJson({});

/// The Assembly tree with the mates listed under its Mates folder (open), as the Assembly lens shows them.
Widget _panel(List<MateDto> mates) {
  final model = AssemblyTreeModel(
    tree: assemblyTreeFromLists(partId: 'root', partName: 'Root', occurrences: const [], mates: mates, patterns: const []),
  )
    ..setFolderItems('#mates', mateFolderItems(mates))
    ..setOpen('#mates', true);
  return MaterialApp(home: Scaffold(body: AssemblyTreeView(model: model, docked: true)));
}

/// The mate row for [id]: its icon and label colour, and the note under or after the label.
Finder _mateRow(String id) => find.byKey(ValueKey('tree-row:#mates#item:$id'));
Icon _rowIcon(WidgetTester tester, String id) =>
    tester.widget<Icon>(find.descendant(of: _mateRow(id), matching: find.byType(Icon)).first);
Color? _labelColour(WidgetTester tester, String id, String label) =>
    tester.widget<Text>(find.descendant(of: _mateRow(id), matching: find.text(label))).style?.color;

void main() {
  group('MateDto parses the N1b reference fields', () {
    test('a new backend: lists, reasons and held', () {
      final m = _held();
      expect(m.hasReferenceState, isTrue);
      expect(m.held, isTrue);
      expect(m.movedReferences, ['references[1].subshape_ref']);
      expect(m.referenceReasons, {'references[1].subshape_ref': 'unique_fingerprint_far'});
      expect(m.needsConfirm, isTrue);
      expect(m.hasLostReference, isFalse);
      expect(_lost().lostReferences, ['references[0].subshape_ref']);
      expect(_followed().followedReferences, ['references[0].subshape_ref']);
    });

    test('an older backend sends none: everything reads absent / empty', () {
      final m = _old();
      expect(m.hasReferenceState, isFalse);
      expect(m.held, isFalse);
      expect(m.lostReferences, isEmpty);
      expect(m.movedReferences, isEmpty);
      expect(m.followedReferences, isEmpty);
      expect(m.referenceReasons, isEmpty);
      expect(m.needsConfirm, isFalse);
      expect(mateReferenceNote(m).kind, MateReferenceKind.none);
    });

    test('a clean mate from a new backend still counts as new, with nothing to say', () {
      final m = _fromJson(_clean);
      expect(m.hasReferenceState, isTrue);
      expect(mateReferenceNote(m).kind, MateReferenceKind.none);
    });

    test('a lost mate is never held for Confirm, even if `held` were sent', () {
      final m = _fromJson({
        'held': true,
        'lost_references': ['references[0].subshape_ref'],
      });
      expect(m.needsConfirm, isFalse);
      expect(mateReferenceNote(m).kind, MateReferenceKind.lost);
    });

    test('the sub-shape reference stays a plain {body_id, shape_type, index}: no signature to read or send', () {
      expect(_held().references.first.subshapeRef!.index, 4);
      expect(jsonEncode(_held().references.first.subshapeRef!.toJson()), isNot(contains('signature')));
    });
  });

  group('updateMate', () {
    test('Confirm sends {"confirm_references": true} and, when asked, ?solve=', () async {
      final seen = <http.Request>[];
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          seen.add(request);
          return http.Response(jsonEncode(_mateJson(extra: _clean)), 200, headers: {'content-type': 'application/json'});
        }),
      );
      await client.updateMate('p1', 'm1', confirmReferences: true, solve: 'group', solveOccurrenceId: 'o1');
      await client.updateMate('p1', 'm1', value: 3);
      expect(seen[0].method, 'PATCH');
      expect(seen[0].url.path, '/document/parts/p1/mates/m1');
      expect(seen[0].url.queryParameters, {'solve': 'group', 'occurrence_id': 'o1'});
      expect(jsonDecode(seen[0].body), {'confirm_references': true});
      expect(jsonDecode(seen[1].body), {'value': 3}, reason: 'an ordinary edit does not send it');
    });
  });

  group('the row subtitle and icon', () {
    testWidgets('followed: an info icon and line, nothing alarming', (tester) async {
      await tester.pumpWidget(_panel([_followed()]));
      expect(_rowIcon(tester, 'm1').icon, Icons.info_outline);
      expect(find.text(kMateFollowedText), findsOneWidget);
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      expect(_labelColour(tester, 'm1', 'Coincident 1'), isNull);
      expect(_rowIcon(tester, 'm1').color, isNot(error));
    });

    testWidgets('held: the amber warning icon and "Check this mate" with the reason', (tester) async {
      await tester.pumpWidget(_panel([_held()]));
      final amber = AiPalette.of(tester.element(find.text('Mates'))).warning;
      expect(_rowIcon(tester, 'm1').icon, Icons.warning_amber_rounded);
      expect(_rowIcon(tester, 'm1').color, amber);
      expect(_labelColour(tester, 'm1', 'Coincident 1'), amber);
      expect(find.text('$kMateHeldText: the face moved a long way'), findsOneWidget);
    });

    testWidgets('held and broken (the part sits on the old face): still the held text, not the generic broken one', (tester) async {
      await tester.pumpWidget(_panel([_held(status: 'broken')]));
      expect(find.textContaining(kMateHeldText), findsOneWidget);
      expect(find.text(kBrokenMateText), findsNothing);
      // The real backend reports a held mate as `broken` while the part sits on the old face (found driving the Linux app against it):
      // the row must still be amber, not the error red of a lost face.
      final amber = AiPalette.of(tester.element(find.text('Mates'))).warning;
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      expect(_rowIcon(tester, 'm1').color, amber);
      expect(_labelColour(tester, 'm1', 'Coincident 1'), amber);
      expect(_rowIcon(tester, 'm1').color, isNot(error));
    });

    testWidgets('lost: the error colour and the reason', (tester) async {
      await tester.pumpWidget(_panel([_lost()]));
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      expect(_rowIcon(tester, 'm1').icon, Icons.warning_amber_rounded);
      expect(_rowIcon(tester, 'm1').color, error);
      expect(find.text('Lost a face: its face is gone'), findsOneWidget);
      expect(find.text(kBrokenMateText), findsNothing);
    });

    test('an unknown reason code reads as itself, a missing one says nothing more', () {
      final odd = _fromJson({
        'lost_references': ['references[0].subshape_ref'],
        'reference_reasons': {'references[0].subshape_ref': 'something_new'},
      });
      final bare = _fromJson({'lost_references': ['references[0].subshape_ref']});
      expect(mateReferenceNote(odd).text, 'Lost a face: something new');
      expect(mateReferenceNote(bare).text, 'Lost a face');
    });

    testWidgets('an older backend\'s mate shows nothing: the plain link icon, no note', (tester) async {
      await tester.pumpWidget(_panel([_old()]));
      expect(_rowIcon(tester, 'm1').icon, Icons.link);
      expect(find.byKey(const ValueKey('tree-note:#mates#item:m1')), findsNothing);
    });

    testWidgets('a clean mate from a new backend looks the same as an old one', (tester) async {
      await tester.pumpWidget(_panel([_fromJson(_clean)]));
      expect(_rowIcon(tester, 'm1').icon, Icons.link);
      expect(find.byKey(const ValueKey('tree-note:#mates#item:m1')), findsNothing);
    });
  });

  group('the context menu', () {
    Future<void> open(WidgetTester tester, MateDto? mate, List<MateContextMenuAction?> picked) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked.add(await showMateContextMenu(context, mate: mate)),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a held mate offers Confirm (and Edit / Delete); choosing it reports confirmReferences', (tester) async {
      final picked = <MateContextMenuAction?>[];
      await open(tester, _held(), picked);
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Got it'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(picked, [MateContextMenuAction.confirmReferences]);
    });

    testWidgets('a lost mate has nothing to confirm', (tester) async {
      await open(tester, _lost(), []);
      expect(find.text('Confirm'), findsNothing);
      expect(find.text('Got it'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });

    testWidgets('a followed mate offers Got it, not Confirm; choosing it reports gotIt', (tester) async {
      final picked = <MateContextMenuAction?>[];
      await open(tester, _followed(), picked);
      expect(find.text('Got it'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      await tester.tap(find.text('Got it'));
      await tester.pumpAndSettle();
      expect(picked, [MateContextMenuAction.gotIt]);
    });

    testWidgets('an older backend\'s mate (and a call with no mate) gets exactly Edit and Delete', (tester) async {
      await open(tester, _old(), []);
      expect(find.text('Confirm'), findsNothing);
      expect(find.text('Got it'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await open(tester, null, []);
      expect(find.text('Confirm'), findsNothing);
      expect(find.text('Edit'), findsOneWidget);
    });
  });

  group('a followed reference is told once and kept until dismissed', () {
    test('the next, clean listing keeps the note; Got it removes it', () {
      final notes = MateFollowedNotes();
      var shown = notes.merge([_followed()]);
      expect(shown.single.hasFollowedReference, isTrue);

      // The backend says it once: the next listing is clean, the screen still shows it.
      shown = notes.merge([_fromJson(_clean)]);
      expect(shown.single.followedReferences, ['references[0].subshape_ref']);
      expect(shown.single.referenceReasons['references[0].subshape_ref'], 'unique_fingerprint');
      expect(mateReferenceNote(shown.single).kind, MateReferenceKind.followed);

      notes.dismiss('m1');
      shown = notes.merge([_fromJson(_clean)]);
      expect(shown.single.hasFollowedReference, isFalse);
      expect(mateReferenceNote(shown.single).kind, MateReferenceKind.none);
    });

    test('a mate that goes away takes its note with it; an old backend never makes one', () {
      final notes = MateFollowedNotes();
      notes.merge([_followed()]);
      notes.merge(const []);
      expect(notes.isEmpty, isTrue);
      notes.merge([_old()]);
      expect(notes.isEmpty, isTrue);
    });

    test('held and lost still win over a kept followed note', () {
      final notes = MateFollowedNotes();
      notes.merge([_followed()]);
      final shown = notes.merge([_held()]).single;
      expect(mateReferenceNote(shown).kind, MateReferenceKind.held);
      expect(shown.needsConfirm, isTrue);
    });
  });
}
