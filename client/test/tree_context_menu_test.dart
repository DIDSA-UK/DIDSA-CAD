import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): a mouse right
/// click on a tree row asks for that row's menu at the cursor; a touch
/// long-press keeps doing what it did (here: the panel's own long-press
/// callback), and nothing is offered while a multi-select is open.

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
  await gesture.down(tester.getCenter(target));
  await gesture.up();
  await tester.pump();
}

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

void main() {
  group('Build Tree', () {
    // The live part's rows in the one tree (P3: the old build tree panel is gone).
    Widget panel({
      List<(String, Offset)>? opened,
      List<String>? longPresses,
      bool multiSelect = false,
    }) {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto(partId: 'root', partName: 'Bracket', featureCount: 2, statusIncluded: true),
      )
        ..setLivePart(AssemblyLivePart(
          '',
          features: const [
            AssemblyLiveFeature(id: 's1', label: 'Sketch 1', type: 'sketch'),
            AssemblyLiveFeature(id: 'e1', label: 'Extrude 1', type: 'extrude'),
          ],
          bodies: const [AssemblyLiveItem('e1', 'Body 1')],
        ))
        ..openAll(['#bodies']);
      return MaterialApp(
        home: Scaffold(
          body: AssemblyTreeView(
            model: model,
            docked: true,
            isMultiSelectMode: multiSelect,
            onRowLongPress: (r) => longPresses?.add(r.key),
            onRowContextMenu: (r, at) => opened?.add((r.key, at)),
          ),
        ),
      );
    }

    testWidgets('a right click on a feature row reports it and the cursor position', (tester) async {
      final opened = <(String, Offset)>[];
      await tester.pumpWidget(panel(opened: opened));
      await _rightClick(tester, find.text('Sketch 1'));
      expect(opened, [('#feature:s1', tester.getCenter(find.text('Sketch 1')))]);
    });

    testWidgets('a right click on a body row reports the body', (tester) async {
      final opened = <(String, Offset)>[];
      await tester.pumpWidget(panel(opened: opened));
      await _rightClick(tester, find.text('Body 1'));
      expect(opened.map((o) => o.$1), ['#body:e1']);
    });

    testWidgets('a touch long-press still calls its own callback and opens no context menu', (tester) async {
      final opened = <(String, Offset)>[];
      final longPresses = <String>[];
      await tester.pumpWidget(panel(opened: opened, longPresses: longPresses));
      await tester.longPress(find.text('Sketch 1'));
      await tester.pump();
      expect(longPresses, ['#feature:s1']);
      expect(opened, isEmpty);
    });

    testWidgets('nothing is offered while a multi-select is open', (tester) async {
      final opened = <(String, Offset)>[];
      await tester.pumpWidget(panel(opened: opened, multiSelect: true));
      await _rightClick(tester, find.text('Sketch 1'));
      expect(opened, isEmpty);
    });
  });

  group('Assembly Tree', () {
    final occurrence = OccurrenceDto(id: 'o1', externalRef: 'parts/bolt.didsa', nameOverride: 'My Bolt', transform: _identity());
    final mate = MateDto(id: 'm1', type: 'coincident', references: const [], suppressed: false);
    final pattern = ComponentPatternDto(
      id: 'p1',
      sourceOccurrenceIds: const ['o1'],
      patternType: 'linear',
      direction: const [1.0, 0.0, 0.0],
      count: 3,
      angleTotal: 360,
      countAngular: 1,
      suppressed: false,
    );

    Widget panel({required List<String> opened, bool multiSelect = false, List<String>? longPresses}) {
      // The occurrence, the mate and the pattern each have a row (the mate and pattern ones under their folders, opened).
      final model = AssemblyTreeModel(
        tree: assemblyTreeFromLists(partId: 'root', partName: 'Root', occurrences: [occurrence], mates: [mate], patterns: [pattern]),
      )
        ..setFolderItems('#mates', mateFolderItems([mate]))
        ..setFolderItems('#patterns', patternFolderItems([pattern]))
        ..setOpen('#mates', true)
        ..setOpen('#patterns', true);
      String name(AssemblyTreeRow r) => switch (r.kind) {
            AssemblyRowKind.mate => 'mate ${r.itemId}',
            AssemblyRowKind.pattern => 'pattern ${r.itemId}',
            _ => 'occurrence ${r.path?.last}',
          };
      return MaterialApp(
        home: Scaffold(
          body: AssemblyTreeView(
            model: model,
            docked: true,
            isMultiSelectMode: multiSelect,
            onRowLongPress: (r) => longPresses?.add(r.itemId ?? r.path!.last),
            onRowContextMenu: (r, at) => opened.add(name(r)),
          ),
        ),
      );
    }

    testWidgets('a right click on an occurrence, a mate and a pattern row reports each', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(panel(opened: opened));
      for (final key in ['o1', '#mates#item:m1', '#patterns#item:p1']) {
        await _rightClick(tester, find.byKey(ValueKey('tree-row:$key')));
      }
      expect(opened, ['occurrence o1', 'mate m1', 'pattern p1']);
    });

    testWidgets('a touch long-press keeps its own callbacks and opens no context menu', (tester) async {
      final opened = <String>[];
      final longPresses = <String>[];
      await tester.pumpWidget(panel(opened: opened, longPresses: longPresses));
      for (final key in ['o1', '#mates#item:m1', '#patterns#item:p1']) {
        await tester.longPress(find.byKey(ValueKey('tree-row:$key')));
        await tester.pump();
      }
      expect(longPresses, ['o1', 'm1', 'p1']);
      expect(opened, isEmpty);
    });

    testWidgets('nothing is offered while a multi-select is open', (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(panel(opened: opened, multiSelect: true));
      for (final key in ['o1', '#mates#item:m1', '#patterns#item:p1']) {
        await _rightClick(tester, find.byKey(ValueKey('tree-row:$key')));
      }
      expect(opened, isEmpty);
    });
  });
}
