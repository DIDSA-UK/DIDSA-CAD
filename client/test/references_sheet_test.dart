// Finding moved files (`docs/moved-files-scope.md`, F3): the Review sheet and the banner's summary text.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/reference_report.dart';
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
}
