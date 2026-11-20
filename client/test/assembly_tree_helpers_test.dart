import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/pattern_context_menu.dart';

// The pure helpers the Assembly tree's callers share (moved here from `assembly_tree_panel_test.dart` in A4, when the old panel was
// removed: the panel's widget tests are replaced by `assembly_tree_view_test.dart` and the "Assembly tree" group of
// `part_screen_test.dart`).

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

OccurrenceDto _occurrence(
  String id, {
  String? externalRef,
  String? resolvedPartId,
  String? nameOverride,
  bool hidden = false,
  bool suppressed = false,
  bool fixed = false,
  String? color,
}) =>
    OccurrenceDto(
      id: id,
      externalRef: externalRef,
      resolvedPartId: resolvedPartId,
      nameOverride: nameOverride,
      transform: _identity(),
      hidden: hidden,
      suppressed: suppressed,
      fixed: fixed,
      color: color,
    );

ComponentPatternDto _pattern(
  String id, {
  String patternType = 'linear',
  int count = 3,
  double angleTotal = 360.0,
  int countAngular = 1,
  bool suppressed = false,
}) =>
    ComponentPatternDto(
      id: id,
      sourceOccurrenceIds: const ['o1'],
      patternType: patternType,
      direction: const [1.0, 0.0, 0.0],
      count: count,
      angleTotal: angleTotal,
      countAngular: countAngular,
      suppressed: suppressed,
    );

MateDto _mate(String id, {String type = 'coincident', bool suppressed = false}) => MateDto(
      id: id,
      type: type,
      references: const [],
      suppressed: suppressed,
    );

void main() {
  group('occurrenceDisplayName', () {
    test('prefers nameOverride when set', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/bolt.didsa', nameOverride: 'My Bolt')];
      expect(occurrenceDisplayName(occurrences, 0), 'My Bolt');
    });

    test('falls back to the externalRef file basename without extension', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/sub/bracket.didsa')];
      expect(occurrenceDisplayName(occurrences, 0), 'bracket');
    });

    test('a generated file name (UUID / hex id) is not a name: "Component N" instead, counted by position', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/bracket.didsa'),
        _occurrence('o2', externalRef: 'parts/a441a4ab-e3b7-4c63-8784-aec0d5159295.didsa'),
        _occurrence('o3', externalRef: 'parts/part-3f2a9c41d07e5b8a1c2d.didsa'),
        _occurrence('o4', externalRef: 'parts/Bolt M8.didsa'),
      ];
      expect([for (var i = 0; i < 4; i++) occurrenceDisplayName(occurrences, i)], ['bracket', 'Component 2', 'Component 3', 'Bolt M8']);
      expect(occurrenceDisplayNames(occurrences), {'o1': 'bracket', 'o2': 'Component 2', 'o3': 'Component 3', 'o4': 'Bolt M8'});
    });

    test('looksGeneratedName: uuids and long hex ids yes, ordinary names no', () {
      for (final g in ['a441a4ab-e3b7-4c63-8784-aec0d5159295', 'a441a4abe3b74c638784aec0d5159295', 'occ_3f2a9c41d07e5b8a1c2d', '']) {
        expect(looksGeneratedName(g), isTrue, reason: g);
      }
      for (final n in ['bolt', 'Plate 2', 'cafe', 'deadbeef', 'M8x30', 'Bracket-A']) {
        expect(looksGeneratedName(n), isFalse, reason: n);
      }
    });

    test('A4: a part placed more than once is numbered `<base> <n>` as the spec says; overrides are verbatim and not counted; a lone part is plain', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail'),
        _occurrence('o2', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail'),
        _occurrence('o3', externalRef: 'parts/LONG_RAIL_001.didsa', resolvedPartId: 'rail', nameOverride: 'Rail Left'),
        _occurrence('o4', externalRef: 'parts/GUSSET_001.didsa', resolvedPartId: 'gusset'),
      ];
      expect([for (var i = 0; i < 4; i++) occurrenceDisplayName(occurrences, i)],
          ['LONG_RAIL_001 <1>', 'LONG_RAIL_001 <2>', 'Rail Left', 'GUSSET_001']);
    });

    test('B4: pattern copies read "Source [Linear 1 #2]" and nested paths show their last segment', () {
      final occurrences = [_occurrence('o1', externalRef: 'parts/bolt.didsa', nameOverride: 'Short Rail BOT_RIGHT')];
      final patterns = [_pattern('p1')];
      expect(occurrencePathDisplayName('o1#pattern:p1:1', occurrences, patterns: patterns), 'Short Rail BOT_RIGHT [Linear 1 #2]');
      expect(occurrencePathDisplayName('x/o1', occurrences, patterns: patterns), 'Short Rail BOT_RIGHT');
      final names = occurrenceDisplayNames(occurrences, patterns: patterns, extraPaths: const ['o1#pattern:p1:1', 'o1']);
      expect(names['o1#pattern:p1:1'], 'Short Rail BOT_RIGHT [Linear 1 #2]');
      expect(names['o1'], 'Short Rail BOT_RIGHT');
    });

    test('falls back to an ordinal "Component N" when neither is available', () {
      final occurrences = [_occurrence('o1'), _occurrence('o2')];
      expect(occurrenceDisplayName(occurrences, 0), 'Component 1');
      expect(occurrenceDisplayName(occurrences, 1), 'Component 2');
    });
    test('a renamed placement is not counted: the other one is a lone part and keeps the plain name', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/bolt.didsa', resolvedPartId: 'bolt'),
        _occurrence('o2', externalRef: 'parts/bolt.didsa', resolvedPartId: 'bolt', nameOverride: 'Special'),
      ];
      expect([for (var i = 0; i < 2; i++) occurrenceDisplayName(occurrences, i)], ['bolt', 'Special']);
    });

    test('the same Part gets the same name as the tree model gives its row (one rule, `AssemblyTreeNaming`)', () {
      final occurrences = [
        _occurrence('o1', externalRef: 'parts/bolt.didsa', resolvedPartId: 'bolt'),
        _occurrence('o2', externalRef: 'parts/bolt.didsa', resolvedPartId: 'bolt'),
        _occurrence('o3'),
      ];
      final tree = assemblyTreeFromLists(partId: 'root', partName: 'Root', occurrences: occurrences, mates: const [], patterns: const []);
      final model = AssemblyTreeModel(tree: tree);
      for (var i = 0; i < occurrences.length; i++) {
        expect(occurrenceDisplayName(occurrences, i), model.labelAtPath([occurrences[i].id]), reason: occurrences[i].id);
      }
      expect(occurrenceDisplayName(occurrences, 0), 'bolt <1>');
    });
  });

  group('mateDisplayName', () {
    test('labels by type with a per-type ordinal', () {
      final mates = [_mate('m1', type: 'coincident'), _mate('m2', type: 'concentric'), _mate('m3', type: 'coincident')];
      expect(mateDisplayName(mates, 0), 'Coincident 1');
      expect(mateDisplayName(mates, 1), 'Concentric 1');
      expect(mateDisplayName(mates, 2), 'Coincident 2');
    });
  });

  group('componentPatternDisplayName', () {
    test('labels by type with a per-type ordinal', () {
      final patterns = [
        _pattern('p1', patternType: 'linear'),
        _pattern('p2', patternType: 'circular'),
        _pattern('p3', patternType: 'linear'),
      ];
      expect(componentPatternDisplayName(patterns, 0), 'Linear 1');
      expect(componentPatternDisplayName(patterns, 1), 'Circular 1');
      expect(componentPatternDisplayName(patterns, 2), 'Linear 2');
    });
  });

  group('componentPatternSummary', () {
    test('a linear pattern shows its instance count', () {
      expect(componentPatternSummary(_pattern('p1', patternType: 'linear', count: 4)), '×4');
    });

    test('a full-circle circular pattern omits the redundant angle', () {
      expect(
        componentPatternSummary(_pattern('p1', patternType: 'circular', countAngular: 6, angleTotal: 360.0)),
        '×6',
      );
    });

    test('a partial-sweep circular pattern shows its angle', () {
      expect(
        componentPatternSummary(_pattern('p1', patternType: 'circular', countAngular: 3, angleTotal: 270.0)),
        '×3 (270°)',
      );
    });
  });

  group('assemblyTreeDefaultWidthFraction', () {
    test('portrait phone gets 66%', () {
      expect(assemblyTreeDefaultWidthFraction(const Size(400, 800)), 0.66);
    });

    test('landscape phone, tablet and desktop get 40%', () {
      expect(assemblyTreeDefaultWidthFraction(const Size(800, 400)), 0.4);
      expect(assemblyTreeDefaultWidthFraction(const Size(800, 1200)), 0.4);
      expect(assemblyTreeDefaultWidthFraction(const Size(1400, 900)), 0.4);
    });
  });

  group('rigid sets (M5)', () {
    const under = ConstraintState.underConstrained;
    final occs = [
      _occurrence('a', resolvedPartId: 'p', nameOverride: 'Plate'),
      _occurrence('b', resolvedPartId: 'p', nameOverride: 'Bolt'),
      _occurrence('c', resolvedPartId: 'p', nameOverride: 'Cover'),
      _occurrence('d', resolvedPartId: 'p', nameOverride: 'Loose'),
    ];
    const status = {
      'a': ConstraintStatusDto(state: under, dof: 6, rigidSet: 'a'),
      'b': ConstraintStatusDto(state: under, dof: 6, rigidSet: 'a'),
      'c': ConstraintStatusDto(state: under, dof: 6, rigidSet: 'a'),
      'd': ConstraintStatusDto(state: under, dof: 2),
    };

    test('the DTO reads rigid_set, and a backend without it as null', () {
      expect(ConstraintStatusDto.fromJson({'status': 'under_constrained', 'dof': 6, 'rigid_set': 'a'}).rigidSet, 'a');
      expect(ConstraintStatusDto.fromJson({'status': 'under_constrained', 'dof': 6}).rigidSet, isNull);
      expect(ConstraintStatusDto.fromJson({'status': 'fully_constrained', 'dof': 0, 'rigid_set': null}).rigidSet, isNull);
    });

    test('the lead says how many others move with it, the rest name the lead, a loose part says nothing', () {
      expect(rigidSetSubtitle(occs, status, 0), 'Moves with 2 other parts');
      expect(rigidSetSubtitle(occs, status, 1), 'Moves with Plate');
      expect(rigidSetSubtitle(occs, status, 2), 'Moves with Plate');
      expect(rigidSetSubtitle(occs, status, 3), isNull);
      expect(rigidSetSubtitle(occs, const {}, 1), isNull, reason: 'no status (an older backend)');
      expect(rigidSetSubtitle(occs.take(2).toList(), status, 0), 'Moves with 1 other part');
      expect(rigidSetMemberIds(occs, status, 'a'), ['a', 'b', 'c']);
    });

    test('the grab notice names the other members (three, then "and N more"), and is null outside a set', () {
      expect(rigidSetGrabNotice(occs, status, 'b'), 'Moves as one with Plate, Cover: the mates lock them together.');
      expect(rigidSetGrabNotice(occs, status, 'd'), isNull);
      final many = [for (var i = 0; i < 6; i++) _occurrence('m$i', nameOverride: 'P$i')];
      final st = {for (final o in many) o.id: const ConstraintStatusDto(state: under, dof: 6, rigidSet: 'm0')};
      expect(rigidSetGrabNotice(many, st, 'm0'), 'Moves as one with P1, P2, P3 and 2 more: the mates lock them together.');
    });

    test('one bracket colour per set, stable, different between sets', () {
      final two = {...status, 'd': const ConstraintStatusDto(state: under, dof: 2, rigidSet: 'd')};
      expect(rigidSetBracketColour(two, 'a'), rigidSetBracketColour(two, 'a'));
      expect(rigidSetBracketColour(two, 'a'), isNot(rigidSetBracketColour(two, 'd')));
    });
  });

  group('pattern context menu (F2)', () {
    Future<PatternContextMenuAction?> open(WidgetTester tester, {required bool suppressed, required String tap}) async {
      PatternContextMenuAction? result;
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showPatternContextMenu(context, suppressed: suppressed);
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Dissolve'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text(tap));
      await tester.pumpAndSettle();
      return done ? result : null;
    }

    testWidgets('lists Edit, Dissolve and Delete and resolves to the tapped action', (tester) async {
      expect(await open(tester, suppressed: false, tap: 'Dissolve'), PatternContextMenuAction.dissolve);
    });

    testWidgets('Dissolve is disabled for a suppressed pattern: tapping it picks nothing', (tester) async {
      expect(await open(tester, suppressed: true, tap: 'Dissolve'), isNull);
      expect(find.text('Dissolve'), findsOneWidget, reason: 'the sheet stays open');
    });
  });

  group('near mates (B1: within tolerance, amber)', () {
    MateDto nearMate(String id, {double mm = 0.006, double deg = 0.0002, List<String> occurrences = const []}) => MateDto(
          id: id,
          type: 'distance',
          references: [for (final o in occurrences) MateEntityRefDto(occurrenceId: o)],
          status: 'near',
          statusResidualMm: mm,
          statusResidualDeg: deg,
        );

    test('MateDto reads status near and the residuals; an older backend gives ok', () {
      final json = {
        'id': 'm',
        'type': 'distance',
        'references': [
          {'occurrence_id': 'a'},
          {'occurrence_id': 'b'},
        ],
      };
      expect(MateDto.fromJson(json).isNear, isFalse);
      final near = MateDto.fromJson({...json, 'status': 'near', 'status_residual_mm': 0.006, 'status_residual_deg': 0.0002});
      expect(near.isNear, isTrue);
      expect(near.isBroken, isFalse);
      expect(near.statusResidualMm, 0.006);
      expect(near.statusResidualDeg, 0.0002);
    });

    test('the subtitle text is "Within tolerance: 0.006 mm / 0.0002°" with trailing zeros dropped', () {
      expect(nearMateText(nearMate('m')), 'Within tolerance: 0.006 mm / 0.0002°');
      expect(nearMateText(nearMate('m', mm: 0.01, deg: 0.1)), 'Within tolerance: 0.01 mm / 0.1°');
      expect(nearMateText(nearMate('m', mm: 0.00385, deg: 0.000123)), 'Within tolerance: 0.004 mm / 0.0001°');
    });


    test('occurrenceConflictsAreAllNear: needs a near mate, and any broken one on the part makes it a real conflict', () {
      final near = nearMate('n', occurrences: ['a', 'b']);
      final broken = MateDto(id: 'x', type: 'distance', references: [MateEntityRefDto(occurrenceId: 'a/inner')], status: 'broken');
      expect(occurrenceConflictsAreAllNear([near], 'a'), isTrue);
      expect(occurrenceConflictsAreAllNear([near, broken], 'a'), isFalse, reason: 'a/inner is inside the top-level a');
      expect(occurrenceConflictsAreAllNear([near, broken], 'b'), isTrue, reason: 'the broken mate does not touch b');
      expect(occurrenceConflictsAreAllNear([MateDto(id: 'ok', type: 'coincident', references: const [])], 'a'), isFalse);
      expect(occurrenceConflictsAreAllNear([near], 'c'), isFalse);
    });
  });

  group('mate and pattern rows under the tree folders (A4)', () {
    MateDto mateWith(String id, {String status = 'ok', bool suppressed = false, String type = 'coincident'}) =>
        MateDto(id: id, type: type, references: const [], status: status, suppressed: suppressed, statusResidualMm: 0.006, statusResidualDeg: 0.0002);

    test('a broken mate is red and says why; an ok one is plain; a suppressed one is never drawn as broken', () {
      final items = mateFolderItems([mateWith('bad', status: 'broken'), mateWith('good'), mateWith('s', status: 'broken', suppressed: true)]);
      expect(items.map((i) => i.label), ['Coincident 1', 'Coincident 2', 'Coincident 3']);
      expect(items[0].tone, AssemblyItemTone.error);
      expect(items[0].note, startsWith(kBrokenMateText));
      expect(items[1].tone, isNull);
      expect(items[2].tone, isNull);
      expect(items[2].suppressed, isTrue);
      expect(items[2].note ?? '', isNot(contains(kBrokenMateText)));
    });

    test('a near mate is amber and says how far', () {
      final items = mateFolderItems([mateWith('n', status: 'near', type: 'distance')]);
      expect(items.single.tone, AssemblyItemTone.warning);
      expect(items.single.note, contains('Within tolerance: 0.006 mm / 0.0002°'));
    });

    test('patterns are named by type and numbered, with the instance count as the note', () {
      final items = patternFolderItems([_pattern('a'), _pattern('b', patternType: 'circular', countAngular: 4, angleTotal: 270), _pattern('c', suppressed: true)]);
      expect(items.map((i) => i.label), ['Linear 1', 'Circular 1', 'Linear 2']);
      expect(items.map((i) => i.note), ['×3', '×4 (270°)', '×3']);
      expect(items.map((i) => i.suppressed), [false, false, true]);
    });
  });

  group('patching and building tree responses (A4)', () {
    AssemblyTreeNodeDto node(String id, {List<String> parent = const [], List<AssemblyTreeNodeDto> children = const [], bool fixed = false, AssemblyTreeConstraintDto? constraint}) =>
        AssemblyTreeNodeDto(
          occurrenceId: id,
          path: [...parent, id],
          resolvedPartId: 'p-$id',
          kind: children.isEmpty ? 'part' : 'assembly',
          fixed: fixed,
          constraint: constraint,
          children: children,
        );

    test('assemblyTreeWithNode replaces one nested node, shares the rest, and drops the constraint when asked', () {
      final inner = node('b', parent: const ['a'], constraint: const AssemblyTreeConstraintDto(status: ConstraintState.underConstrained, dof: 3));
      final sibling = node('s', parent: const ['a']);
      final tree = AssemblyTreeResponseDto(
        partId: 'root',
        partName: 'Root',
        children: [node('a', children: [inner, sibling]), node('z')],
      );
      final patched = assemblyTreeWithNode(tree, const ['a', 'b'], (n) => copyAssemblyTreeNode(n, fixed: true, clearConstraint: true));
      final b = patched.children.first.children.first;
      expect(b.fixed, isTrue);
      expect(b.constraint, isNull);
      expect(identical(patched.children.first.children.last, sibling), isTrue, reason: 'untouched nodes are shared');
      expect(identical(patched.children.last, tree.children.last), isTrue);
      // The original is not changed.
      expect(tree.children.first.children.first.fixed, isFalse);
      expect(tree.children.first.children.first.constraint, isNotNull);
      expect(identical(assemblyTreeWithNode(tree, const ['a', 'nope'], (n) => n), tree), isTrue);
    });

    test('assemblyTreeFromLists is one level, with the mates and patterns counted and no status', () {
      final tree = assemblyTreeFromLists(
        partId: 'root',
        partName: 'Root',
        occurrences: [_occurrence('o1', externalRef: 'parts/a.didsa', resolvedPartId: 'pa', fixed: true), _occurrence('o2', externalRef: 'parts/gone.didsa')],
        mates: [_mate('m')],
        patterns: const [],
      );
      expect(tree.statusIncluded, isFalse);
      expect(tree.mates?.count, 1);
      expect(tree.patterns, isNull);
      expect(tree.children.map((n) => (n.occurrenceId, n.kind, n.fixed)), [('o1', 'part', true), ('o2', 'missing', false)]);
    });

    test('topLevelConstraintStatus keeps the rigid set and dof, and is empty without status', () {
      final tree = AssemblyTreeResponseDto(partId: 'r', partName: 'R', statusIncluded: true, children: [
        node('a', constraint: const AssemblyTreeConstraintDto(status: ConstraintState.underConstrained, dof: 4, rigidSet: 'a')),
        node('b'),
      ]);
      final status = topLevelConstraintStatus(tree);
      expect(status.keys, ['a']);
      expect(status['a']!.dof, 4);
      expect(status['a']!.rigidSet, 'a');
      expect(topLevelConstraintStatus(AssemblyTreeResponseDto(partId: 'r', partName: 'R', children: [node('a')])), isEmpty);
    });
  });
}
