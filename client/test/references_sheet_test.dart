// Finding moved files (`docs/moved-files-scope.md`, F3): the Review sheet and the banner's summary text.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/assembly/folder_match_dialog.dart';
import 'package:didsa_cad_client/assembly/folder_match_session_choice.dart';
import 'package:didsa_cad_client/assembly/references_sheet.dart';

ReferenceReport _report(
  String occurrenceId,
  ReferenceOutcome outcome, {
  String requested = 'Frame_A.didsa',
  String? foundPath,
  List<String> candidates = const [],
  bool pathMismatch = false,
  bool staleCopy = false,
}) =>
    ReferenceReport(
      parentPartId: 'root',
      parentPath: 'root.didsa',
      occurrenceId: occurrenceId,
      requestedPath: requested,
      storedPartId: 'frame',
      outcome: outcome,
      foundPath: foundPath,
      candidates: candidates,
      pathMismatch: pathMismatch,
      staleCopy: staleCopy,
    );

void main() {
  test('the summary says how many moved and how many need the user', () {
    expect(referenceSummary(const []), isNull);
    expect(referenceSummary([_report('a', ReferenceOutcome.movedById)]), '1 file was found in new places');
    expect(
      referenceSummary([
        _report('a', ReferenceOutcome.movedById),
        _report('b', ReferenceOutcome.movedById),
        _report('c', ReferenceOutcome.ask),
      ]),
      '2 files were found in new places, 1 needs you',
    );
    expect(
      referenceSummary([_report('a', ReferenceOutcome.missing), _report('b', ReferenceOutcome.suggest)]),
      '2 need you',
    );
  });

  group('ReferencesSheet', () {
    late ValueNotifier<List<ReferenceReport>> reports;
    final used = <(String, String)>[];
    final located = <String>[];
    final left = <String>[];

    Future<void> pumpSheet(WidgetTester tester, List<ReferenceReport> list) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      used.clear();
      located.clear();
      left.clear();
      reports = ValueNotifier(list);
      addTearDown(reports.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReferencesSheet(
              reports: reports,
              onUse: (report, path) async => used.add((report.occurrenceId, path)),
              onLocate: (report) async => located.add(report.occurrenceId),
              onLeaveMissing: (report) => left.add(report.occurrenceId),
            ),
          ),
        ),
      );
    }

    testWidgets('lists each kind of reference with why, the ones needing the user first', (tester) async {
      await pumpSheet(tester, [
        _report('moved', ReferenceOutcome.movedById, foundPath: 'parts/frames/Frame_A.didsa'),
        _report('ask', ReferenceOutcome.ask, requested: 'Leg.didsa', candidates: ['left/Leg.didsa', 'right/Leg.didsa']),
        _report(
          'suggest',
          ReferenceOutcome.suggest,
          requested: 'Plate.didsa',
          candidates: ['Plate.didsa'],
          pathMismatch: true,
        ),
        _report('gone', ReferenceOutcome.missing, requested: 'Gone.didsa'),
        _report('stale', ReferenceOutcome.missing, requested: 'Old.didsa', staleCopy: true),
      ]);

      expect(find.text('1 file was found in new places, 4 need you'), findsOneWidget);
      expect(find.text('Found by its part id in parts/frames/Frame_A.didsa. The path is corrected; save to keep it.'),
          findsOneWidget);
      expect(find.textContaining('2 files have this part'), findsOneWidget);
      expect(find.textContaining('The file at Plate.didsa is a different part'), findsOneWidget);
      expect(find.text('Not found in the project folder.'), findsNWidgets(2));
      expect(find.textContaining('last saved copy is shown'), findsOneWidget);
      // The moved reference needs nothing; every other one can be located or left.
      expect(find.byKey(const Key('locate-moved')), findsNothing);
      expect(find.byKey(const Key('leave-gone')), findsOneWidget);
      // Needs-you rows come before the one that was fixed.
      final askTop = tester.getTopLeft(find.byKey(const Key('reference-ask'))).dy;
      final movedTop = tester.getTopLeft(find.byKey(const Key('reference-moved'))).dy;
      expect(askTop, lessThan(movedTop));
    });

    testWidgets('Use on a copy that carries the placed part\'s id goes straight through', (tester) async {
      await pumpSheet(tester, [
        _report('ask', ReferenceOutcome.ask, requested: 'Leg.didsa', candidates: ['left/Leg.didsa', 'right/Leg.didsa']),
      ]);

      await tester.tap(find.byKey(const Key('use-ask-right/Leg.didsa')));
      await tester.pump();

      expect(used, [('ask', 'right/Leg.didsa')]);
      expect(find.text('Not the placed file'), findsNothing);
    });

    testWidgets('Use on a suggestion needs a confirmation: Cancel uses nothing, Use anyway does', (tester) async {
      await pumpSheet(tester, [
        _report('s', ReferenceOutcome.suggest, requested: 'Washer.didsa', candidates: ['old/Washer.didsa']),
      ]);

      await tester.tap(find.byKey(const Key('use-s-old/Washer.didsa')));
      await tester.pumpAndSettle();
      expect(find.text('old/Washer.didsa is not the file that was placed here. Use it anyway?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(used, isEmpty);

      await tester.tap(find.byKey(const Key('use-s-old/Washer.didsa')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use anyway'));
      await tester.pumpAndSettle();
      expect(used, [('s', 'old/Washer.didsa')]);
    });

    testWidgets('Locate... and Leave missing report the row; a dealt-with row leaves the list', (tester) async {
      await pumpSheet(tester, [
        _report('a', ReferenceOutcome.missing, requested: 'A.didsa'),
        _report('b', ReferenceOutcome.missing, requested: 'B.didsa'),
      ]);

      await tester.tap(find.byKey(const Key('locate-a')));
      await tester.tap(find.byKey(const Key('leave-b')));
      await tester.pump();
      expect(located, ['a']);
      expect(left, ['b']);

      reports.value = [reports.value.first];
      await tester.pump();
      expect(find.byKey(const Key('reference-b')), findsNothing);
      expect(find.byKey(const Key('reference-a')), findsOneWidget);
    });
  });

  test('withParentPartId rewrites only the parent id (nested reports of a re-minted file)', () {
    final original = _report('o', ReferenceOutcome.suggest, candidates: ['x/Frame_A.didsa']);
    final moved = original.withParentPartId('minted-1');
    expect(moved.parentPartId, 'minted-1');
    expect(moved.parentPath, original.parentPath);
    expect(moved.occurrenceId, original.occurrenceId);
    expect(moved.outcome, original.outcome);
    expect(moved.candidates, original.candidates);
  });

  group('item 1: the folder-match additions', () {
    Future<void> pump(
      WidgetTester tester,
      List<ReferenceReport> list, {
      ValueNotifier<String?>? notice,
      ValueNotifier<int>? offer,
      Future<void> Function()? apply,
      Future<void> Function(List<ReferenceReport>)? useAll,
      FolderMatchSessionChoice? choice,
    }) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReferencesSheet(
            reports: ValueNotifier(list),
            onUse: (r, p) async {},
            onLocate: (r) async {},
            onLeaveMissing: (r) {},
            notice: notice,
            folderChangeOffer: offer,
            onApplyFolderChange: apply,
            onUseAllSingle: useAll,
            sessionChoice: choice,
          ),
        ),
      ));
    }

    ReferenceReport nested(String id, ReferenceOutcome outcome, {List<String> candidates = const [], String parent = 'proj/parts/Sub.didsa'}) =>
        ReferenceReport(
          parentPartId: 'sub',
          parentPath: parent,
          occurrenceId: id,
          requestedPath: 'parts/$id.didsa',
          storedPartId: null,
          outcome: outcome,
          foundPath: candidates.isEmpty ? null : candidates.first,
          candidates: candidates,
        );

    testWidgets('each row says which file it is in, and a likely row offers its one candidate with Use', (tester) async {
      await pump(tester, [nested('leaf', ReferenceOutcome.likely, candidates: ['proj/parts/leaf.didsa'])]);
      expect(find.text('in Sub.didsa'), findsOneWidget);
      expect(find.byKey(const Key('level-leaf')), findsOneWidget);
      expect(find.byKey(const Key('use-leaf-proj/parts/leaf.didsa')), findsOneWidget);
      expect(find.textContaining('Probably moved with the project folder'), findsOneWidget);
    });

    testWidgets('the notice line shows why the list grew', (tester) async {
      final notice = ValueNotifier<String?>('Found 3 more references inside Sub.didsa');
      addTearDown(notice.dispose);
      await pump(tester, [nested('leaf', ReferenceOutcome.missing)], notice: notice);
      expect(find.text('Found 3 more references inside Sub.didsa'), findsOneWidget);
    });

    testWidgets('Apply the same folder change shows its count and runs once', (tester) async {
      final offer = ValueNotifier<int>(0);
      addTearDown(offer.dispose);
      var applied = 0;
      await pump(tester, [nested('a', ReferenceOutcome.suggest, candidates: ['x/a.didsa'])], offer: offer, apply: () async => applied++);
      expect(find.byKey(const Key('apply-folder-change')), findsNothing);
      offer.value = 6;
      await tester.pump();
      expect(find.text('Apply the same folder change to 6 other references'), findsOneWidget);
      await tester.tap(find.byKey(const Key('apply-folder-change')));
      await tester.pump();
      expect(applied, 1);
    });

    testWidgets('Use all single suggestions covers only rows with exactly one candidate', (tester) async {
      List<ReferenceReport>? got;
      await pump(
        tester,
        [
          nested('one', ReferenceOutcome.suggest, candidates: ['x/one.didsa']),
          nested('likely', ReferenceOutcome.likely, candidates: ['x/likely.didsa']),
          nested('two', ReferenceOutcome.suggest, candidates: ['x/two.didsa', 'y/two.didsa']),
          nested('gone', ReferenceOutcome.missing),
        ],
        useAll: (reports) async => got = reports,
      );
      expect(find.text('Use all single suggestions (2)'), findsOneWidget);
      await tester.tap(find.byKey(const Key('use-all-single')));
      await tester.pump();
      expect(got!.map((r) => r.occurrenceId), unorderedEquals(['one', 'likely']));
    });

    testWidgets('the stored folder-match answer is shown with Ask again, which clears it', (tester) async {
      final choice = FolderMatchSessionChoice.instance..clear();
      addTearDown(choice.clear);
      await pump(tester, [nested('a', ReferenceOutcome.missing)], choice: choice);
      expect(find.byKey(const Key('folder-match-session-line')), findsNothing);
      choice.remember(true);
      await tester.pump();
      expect(find.text('Folder matches: used automatically this session'), findsOneWidget);
      await tester.tap(find.byKey(const Key('folder-match-ask-again')));
      await tester.pump();
      expect(choice.answer, isNull);
      expect(find.byKey(const Key('folder-match-session-line')), findsNothing);
    });
  });

  group('showFolderMatchDialog', () {
    testWidgets('lists examples and returns Use them with the checkbox state', (tester) async {
      FolderMatchAnswer? answer;
      final reports = [
        for (var i = 0; i < 5; i++)
          ReferenceReport(
            parentPartId: 'r',
            parentPath: 'root.didsa',
            occurrenceId: 'o$i',
            requestedPath: 'parts/x$i.didsa',
            storedPartId: null,
            outcome: ReferenceOutcome.likely,
            foundPath: 'proj/parts/x$i.didsa',
            candidates: ['proj/parts/x$i.didsa'],
          ),
      ];
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => answer = await showFolderMatchDialog(context, reports),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('5 files look like they moved with the project folder'), findsOneWidget);
      expect(find.textContaining('parts/x0.didsa  →  proj/parts/x0.didsa'), findsOneWidget);
      expect(find.text('…and 2 more'), findsOneWidget);
      await tester.tap(find.byKey(const Key('folder-match-dont-ask')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('folder-match-use')));
      await tester.pumpAndSettle();
      expect(answer!.useThem, isTrue);
      expect(answer!.dontAskAgain, isTrue);
    });
  });
}
