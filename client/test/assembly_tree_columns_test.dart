// C4 (#12, #15; `docs/assembly-tree-overhaul-scope.md` 12.6): the tree's optional columns (Eye, Colour, DOF, and P1's pin moved into the
// Columns menu), and the row <-> viewport hover. The host's side of the hover is in part_screen_test.dart ("Hover linking (C4)").
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/assembly_hover_link.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';

Map<String, dynamic> _node(
  String id,
  List<String> path, {
  String kind = 'part',
  String? name,
  String? partId,
  bool hidden = false,
  String? color,
  Map<String, dynamic>? constraint,
  List<Map<String, dynamic>> children = const [],
}) =>
    {
      'occurrence_id': id,
      'path': path,
      'resolved_part_id': partId ?? 'part-$id',
      'part_name': name ?? 'Item $id',
      'kind': kind,
      'hidden': hidden,
      if (color != null) 'color': color,
      if (constraint != null) 'constraint': constraint,
      'children': children,
    };

AssemblyTreeResponseDto _tree(List<Map<String, dynamic>> children) => AssemblyTreeResponseDto.fromJson({
      'part_id': 'root',
      'part_name': 'Root',
      'kind': 'assembly',
      'feature_count': 0,
      'status_included': true,
      'children': children,
    });

Widget _host(Widget view, {LayoutPreference layout = LayoutPreference.desktop}) => MaterialApp(
      home: LayoutModeScope(
        controller: LayoutModeController(preference: layout, windowSize: const Size(1200, 800), mouseActive: layout == LayoutPreference.desktop),
        child: Scaffold(body: view),
      ),
    );

Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));
Finder _key(String key) => find.byKey(ValueKey(key));

AssemblyTreeModel _model() => AssemblyTreeModel(
      tree: _tree([
        _node('a', ['a'], name: 'Bolt', color: '#FF0000', constraint: {'status': 'under_constrained', 'dof': 3}),
        _node('b', ['b'], name: 'Nut', hidden: true),
        _node('s', ['s'], kind: 'assembly', name: 'Sub', constraint: {'status': 'fully_constrained', 'dof': 0}, children: [
          _node('c', ['s', 'c'], name: 'Pin'),
        ]),
      ]),
    );

Future<void> _toggleColumn(WidgetTester tester, String column) async {
  await tester.tap(_key('tree-columns-menu'));
  await tester.pumpAndSettle();
  await tester.tap(_key('tree-column-$column'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await ViewPreferences.setAssemblyTreeEyeColumn(false);
    await ViewPreferences.setAssemblyTreeColourColumn(false);
    await ViewPreferences.setAssemblyTreeDofColumn(false);
    await ViewPreferences.setAssemblyTreePinColumn(false);
  });

  group('the Columns menu', () {
    testWidgets('every column is off by default, and a phone has no menu', (tester) async {
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onVisibilityToggle: (_) {})));
      expect(_key('tree-columns-menu'), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-dof:a')), findsNothing);
      expect(find.byKey(const ValueKey('tree-colour:a')), findsNothing);
      expect(find.byKey(const ValueKey('tree-eye:a')), findsNothing);
      expect(find.byKey(const ValueKey('tree-eye-off:b')), findsOneWidget, reason: 'a hidden row still shows its eye-off, as before');
      expect(ViewPreferences.assemblyTreeEyeColumn, isFalse);
      expect(ViewPreferences.assemblyTreeColourColumn, isFalse);
      expect(ViewPreferences.assemblyTreeDofColumn, isFalse);

      await tester.pumpWidget(_host(AssemblyTreeView(model: _model()), layout: LayoutPreference.phone));
      expect(_key('tree-columns-menu'), findsNothing);
    });

    testWidgets('each column switches on and off, is saved, and comes back in a new view', (tester) async {
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onVisibilityToggle: (_) {})));
      for (final (column, probe, saved) in <(String, String, bool Function())>[
        ('dof', 'tree-dof:a', () => ViewPreferences.assemblyTreeDofColumn),
        ('colour', 'tree-colour:a', () => ViewPreferences.assemblyTreeColourColumn),
        ('eye', 'tree-eye:a', () => ViewPreferences.assemblyTreeEyeColumn),
      ]) {
        await _toggleColumn(tester, column);
        expect(saved(), isTrue, reason: '$column saved on');
        expect(_key(probe), findsOneWidget, reason: '$column drawn');
        await _toggleColumn(tester, column);
        expect(saved(), isFalse, reason: '$column saved off');
        expect(_key(probe), findsNothing, reason: '$column gone');
      }

      // Restored: a new view reads the saved values.
      await ViewPreferences.setAssemblyTreeDofColumn(true);
      await ViewPreferences.setAssemblyTreeColourColumn(true);
      await tester.pumpWidget(_host(AssemblyTreeView(key: UniqueKey(), model: _model(), docked: true)));
      expect(_key('tree-dof:a'), findsOneWidget);
      expect(_key('tree-colour:a'), findsOneWidget);
      expect(_key('tree-eye:a'), findsNothing);
    });

    testWidgets('the pin column moved into the menu with its saved value and key kept; only a live part offers it', (tester) async {
      // The saved value of P1's toggle is honoured without touching the menu.
      await ViewPreferences.setAssemblyTreePinColumn(true);
      expect(ViewPreferences.assemblyTreePinColumnPrefKey, 'view_assembly_tree_pin_column');
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true)));
      await tester.tap(_key('tree-columns-menu'));
      await tester.pumpAndSettle();
      expect(_key('tree-column-pin'), findsNothing, reason: 'no live part, no pin toggle: the menu has no pin entry');
      expect(_key('tree-column-eye'), findsOneWidget);
    });
  });

  group('the columns', () {
    testWidgets('Eye: an eye on every row that can hide, crossed when hidden, a tap reports the row; nothing on a row with none', (tester) async {
      final toggled = <String>[];
      await ViewPreferences.setAssemblyTreeEyeColumn(true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onVisibilityToggle: (r) => toggled.add(r.key))));
      expect(_key('tree-eye:a'), findsOneWidget);
      expect(_key('tree-eye-off:b'), findsOneWidget);
      expect(_key('tree-eye:'), findsNothing, reason: 'the root has nothing to hide');
      await tester.tap(_key('tree-eye:a'));
      await tester.tap(_key('tree-eye-off:b'));
      expect(toggled, ['a', 'b']);
    });

    testWidgets('the columns line up whether or not a row has a state icon', (tester) async {
      await ViewPreferences.setAssemblyTreeEyeColumn(true);
      await ViewPreferences.setAssemblyTreeColourColumn(true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onVisibilityToggle: (_) {})));
      // a has a state icon (under-constrained), b has none.
      expect(find.byKey(const ValueKey('tree-state:a:under_constrained')), findsOneWidget);
      expect(tester.getRect(_key('tree-eye:a')).right, tester.getRect(_key('tree-eye-off:b')).right);
      expect(tester.getRect(_key('tree-colour:a')).right, tester.getRect(_key('tree-colour:b')).right);
    });

    testWidgets('Colour: a disc in the placement colour (a ring when it has none), a click reports the row; the root has none', (tester) async {
      final tapped = <String>[];
      await ViewPreferences.setAssemblyTreeColourColumn(true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onRowColourTap: (r) => tapped.add(r.key))));
      BoxDecoration deco(String key) => tester.widget<Container>(_key('tree-colour:$key')).decoration! as BoxDecoration;
      expect(deco('a').color, const Color(0xFFFF0000));
      expect(deco('b').color, isNull, reason: 'no colour of its own: an empty ring');
      expect(_key('tree-colour:'), findsNothing);
      await tester.tap(_key('tree-colour:a'));
      expect(tapped, ['a']);
    });

    testWidgets('DOF: the number from the constraint, empty while the status loads', (tester) async {
      await ViewPreferences.setAssemblyTreeDofColumn(true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true)));
      expect(tester.widget<Text>(_key('tree-dof:a')).data, '3');
      expect(tester.widget<Text>(_key('tree-dof:s')).data, '0');
      expect(tester.widget<Text>(_key('tree-dof:b')).data, '', reason: 'no constraint yet: nothing, not 0');
    });
  });

  group('hover', () {
    testWidgets('the mouse over a row reports it once, moving along it again reports nothing, and leaving reports null', (tester) async {
      final reported = <String?>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), docked: true, onRowHover: (r) => reported.add(r?.key))));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      final box = tester.getRect(_row('a'));
      await mouse.moveTo(box.center);
      await tester.pump();
      await mouse.moveTo(box.center + const Offset(10, 0));
      await tester.pump();
      expect(reported, ['a']);
      await mouse.moveTo(tester.getCenter(_row('b')));
      await tester.pump();
      expect(reported, ['a', 'b'], reason: 'one row to the next: the new row, no gap');
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(reported, ['a', 'b', null]);
    });

    testWidgets('a row that leaves the list under the pointer takes its light back', (tester) async {
      final reported = <String?>[];
      final model = _model()..openAll(const ['s']);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, onRowHover: (r) => reported.add(r?.key))));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_row('s/c')));
      await tester.pump();
      expect(reported, ['s/c']);
      model.closeAll();
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, onRowHover: (r) => reported.add(r?.key))));
      await tester.pump();
      expect(reported.last, isNull);
    });

    testWidgets('a phone reports no hover and marks no row', (tester) async {
      final reported = <String?>[];
      final path = ValueNotifier<List<String>?>(const ['a']);
      await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), onRowHover: (r) => reported.add(r?.key), viewportHover: path), layout: LayoutPreference.phone));
      expect(_key('tree-viewport-hover:a'), findsNothing);
      expect(reported, isEmpty);
    });

    testWidgets('the viewport hover marks its row; a collapsed one marks the nearest listed ancestor; it never opens, scrolls or selects', (tester) async {
      final model = _model();
      final path = ValueNotifier<List<String>?>(null);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, viewportHover: path)));
      expect(find.byKey(const ValueKey('tree-viewport-hover:a')), findsNothing);

      path.value = const ['a'];
      await tester.pump();
      expect(_key('tree-viewport-hover:a'), findsOneWidget);

      path.value = const ['s', 'c'];
      await tester.pump();
      expect(_key('tree-viewport-hover:a'), findsNothing);
      expect(_key('tree-viewport-hover:s'), findsOneWidget, reason: 's is closed: its row stands for c');
      expect(_row('s/c'), findsNothing);
      expect(model.isOpen('s'), isFalse);
      expect(model.selectedKey, isNull);

      model.openAll(const ['s']);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, viewportHover: path)));
      await tester.pump();
      expect(_key('tree-viewport-hover:s/c'), findsOneWidget, reason: 'open now: its own row');
      expect(_key('tree-viewport-hover:s'), findsNothing);

      path.value = null;
      await tester.pump();
      expect(_key('tree-viewport-hover:s/c'), findsNothing);
    });
  });

  group('the model', () {
    AssemblyTreeModel grouped() => AssemblyTreeModel(
          tree: _tree([
            for (var i = 0; i < 5; i++) _node('bolt$i', ['bolt$i'], name: 'Bolt', partId: 'bolt'),
            _node('s', ['s'], kind: 'assembly', name: 'Sub', children: [_node('c', ['s', 'c'], name: 'Pin')]),
          ]),
        );

    test('listedRowKeyOfPath: its own row, else its group, else the nearest listed ancestor, else null', () {
      final m = grouped();
      expect(m.listedRowKeyOfPath(const ['s']), 's');
      expect(m.listedRowKeyOfPath(const ['s', 'c']), 's', reason: 'closed: the sub-assembly');
      m.openAll(const ['s']);
      expect(m.listedRowKeyOfPath(const ['s', 'c']), 's/c');
      final group = m.visibleRows().firstWhere((r) => r.kind == AssemblyRowKind.group).key;
      expect(m.listedRowKeyOfPath(const ['bolt2']), group, reason: 'a member of a closed group: the group row');
      m.openAll([group]);
      expect(m.listedRowKeyOfPath(const ['bolt2']), 'bolt2');
      m.grouping = false;
      expect(m.listedRowKeyOfPath(const ['bolt2']), 'bolt2');
      expect(m.listedRowKeyOfPath(const ['nope']), isNull);
      expect(m.listedRowKeyOfPath(const []), isNull);
    });

    test('groupMemberPaths lists the members of a group row and nothing for another key', () {
      final m = grouped();
      final group = m.visibleRows().firstWhere((r) => r.kind == AssemblyRowKind.group).key;
      expect(m.groupMemberPaths(group), [for (var i = 0; i < 5; i++) ['bolt$i']]);
      expect(m.groupMemberPaths('s'), isEmpty);
    });
  });

  group('HoverThrottle and ViewportTreeHover', () {
    testWidgets('the first value goes through at once, the rest wait for the window and only the newest is kept', (tester) async {
      final seen = <int>[];
      final t = HoverThrottle<int>(seen.add, window: const Duration(milliseconds: 50));
      addTearDown(t.dispose);
      t.push(1);
      expect(seen, [1]);
      t.push(2);
      t.push(3);
      t.push(4);
      expect(seen, [1], reason: 'inside the window');
      await tester.pump(const Duration(milliseconds: 60));
      expect(seen, [1, 4], reason: 'the newest only');
      await tester.pump(const Duration(milliseconds: 60));
      t.push(4);
      expect(seen, [1, 4], reason: 'the same value again is dropped');
      t.push(5);
      await tester.pump(const Duration(milliseconds: 60));
      expect(seen, [1, 4, 5]);
      await tester.pump(const Duration(milliseconds: 60));
    });

    testWidgets('a disposed throttle passes nothing on and leaves no timer (a pending one would fail the test)', (tester) async {
      final seen = <int>[];
      final t = HoverThrottle<int>(seen.add, window: const Duration(milliseconds: 20));
      t.dispose();
      t.push(1); // a teardown's late "none" lands here
      expect(seen, isEmpty);
    });

    test('a value that went there and back inside one window is not passed on twice', () async {
      final seen = <String?>[];
      final t = HoverThrottle<String?>(seen.add, window: const Duration(milliseconds: 20));
      t.push('a');
      t.push(null);
      t.push('a');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(seen, ['a']);
      t.dispose();
    });

    test('shownInstanceKeys leaves out the hidden placements, and keeps the rest', () {
      AssemblyOccurrenceInstanceDto at(List<String> path, {bool hidden = false}) => AssemblyOccurrenceInstanceDto(
            occurrencePath: path,
            partId: 'p',
            worldTransform: RigidTransformDto(translation: const [0.0, 0.0, 0.0], rotationAxis: const [0.0, 0.0, 1.0], rotationAngleDegrees: 0.0),
            hidden: hidden,
          );
      final instances = [at(['a']), at(['s', 'c'], hidden: true), at(['s', 'd'])];
      expect(shownInstanceKeys({'a', 's/c', 's/d'}, instances), {'a', 's/d'});
      final same = {'a'};
      expect(identical(shownInstanceKeys(same, [at(['a'])]), same), isTrue, reason: 'nothing hidden: no copy');
    });

    test('ViewportTreeHover compares by what it lights', () {
      final one = ViewportTreeHover(instanceKeys: {'a', 'b'}, entities: {const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'x')});
      final two = ViewportTreeHover(instanceKeys: {'b', 'a'}, entities: {const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'x')});
      expect(one, two);
      expect(one.hashCode, two.hashCode);
      expect(one, isNot(const ViewportTreeHover(instanceKeys: {'a'})));
      expect(const ViewportTreeHover().isEmpty, isTrue);
    });
  });
}
