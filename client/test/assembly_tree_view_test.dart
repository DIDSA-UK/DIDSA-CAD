import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:didsa_cad_client/ai/ai_theme.dart' show AiPalette;
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/assembly_context_strip.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';

Map<String, dynamic> _node(
  String id,
  List<String> path, {
  String kind = 'part',
  String? name,
  bool hidden = false,
  Map<String, dynamic>? problems,
  Map<String, dynamic>? constraint,
  bool statusFailed = false,
  int? featureCount,
  List<Map<String, dynamic>> children = const [],
}) =>
    {
      'occurrence_id': id,
      'path': path,
      'resolved_part_id': 'part-$id',
      'part_name': name ?? 'Item $id',
      'kind': kind,
      'hidden': hidden,
      if (problems != null) 'problems': problems,
      if (constraint != null) 'constraint': constraint,
      if (statusFailed) 'status_failed': true,
      if (featureCount != null) 'feature_count': featureCount,
      'children': children,
    };

AssemblyTreeResponseDto _tree(List<Map<String, dynamic>> children, {int featureCount = 0}) =>
    AssemblyTreeResponseDto.fromJson({
      'part_id': 'root',
      'part_name': 'Root',
      'kind': 'assembly',
      'feature_count': featureCount,
      'status_included': true,
      'children': children,
    });

Widget _host(
  Widget view, {
  LayoutPreference layout = LayoutPreference.phone,
}) =>
    MaterialApp(
      home: LayoutModeScope(
        controller: LayoutModeController(preference: layout, windowSize: const Size(1200, 800), mouseActive: layout == LayoutPreference.desktop),
        child: Scaffold(body: view),
      ),
    );

Finder _rows() => find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('tree-row:'));
Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));

void main() {
  testWidgets('a nested row opens and closes from its chevron', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'], kind: 'assembly', name: 'Arm', children: [_node('b', ['a', 'b'], name: 'Pin')]),
    ]));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model)));

    expect(_row('a'), findsOneWidget);
    expect(_row('a/b'), findsNothing);
    // The root row is listed, always open, and has no chevron.
    expect(_row(''), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-chevron:')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
    await tester.pump();
    expect(_row('a/b'), findsOneWidget);
    expect(find.text('Pin'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
    await tester.pump();
    expect(_row('a/b'), findsNothing);
  });

  testWidgets('reveal scrolls to a row 4 deep among 2,000 and builds only what is on screen', (tester) async {
    // 40 assemblies x (b > c > 50 parts) = 2,000 parts, every Part distinct (so nothing groups), all collapsed.
    final tops = [
      for (var i = 0; i < 40; i++)
        _node('a$i', ['a$i'], kind: 'assembly', children: [
          _node('b', ['a$i', 'b'], kind: 'assembly', children: [
            _node('c', ['a$i', 'b', 'c'], kind: 'assembly', children: [
              for (var j = 0; j < 50; j++) _node('p$i-$j', ['a$i', 'b', 'c', 'p$i-$j']),
            ]),
          ]),
        ]),
    ];
    final model = AssemblyTreeModel(tree: _tree(tops));
    // Open every assembly, so 2,000+ rows are listed; the reveal then has to scroll, not just open.
    model.openAll([for (var i = 0; i < 40; i++) ...['a$i', 'a$i/b', 'a$i/b/c']]);
    expect(model.visibleRows().length, greaterThan(2000));
    final controller = AssemblyTreeController();
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, controller: controller)));

    final target = ['a30', 'b', 'c', 'p30-45'];
    expect(_row(target.join('/')), findsNothing); // far below the first screen
    controller.reveal(target, select: true);
    await tester.pump();
    await tester.pump();

    // The ancestors are open, the row is selected and on the screen.
    expect(model.isOpen('a30'), isTrue);
    expect(model.isOpen('a30/b'), isTrue);
    expect(model.isOpen('a30/b/c'), isTrue);
    expect(model.selectedKey, target.join('/'));
    final rowFinder = _row(target.join('/'));
    expect(rowFinder, findsOneWidget);
    final list = tester.getRect(find.byKey(const ValueKey('assembly-tree-list')));
    final rect = tester.getRect(rowFinder);
    expect(rect.top, greaterThanOrEqualTo(list.top - 0.5));
    expect(rect.bottom, lessThanOrEqualTo(list.bottom + 0.5));

    // The list holds 2,000+ rows but builds a screenful of them.
    expect(model.visibleRows().length, greaterThan(2000));
    expect(_rows().evaluate().length, lessThan(30));

    // Revealing back up scrolls up again.
    controller.reveal(['a0'], select: true);
    await tester.pump();
    await tester.pump();
    expect(_row('a0'), findsOneWidget);
    expect(_row(target.join('/')), findsNothing);
  });

  testWidgets('a problem count shows on a collapsed parent and goes when it opens', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'],
          kind: 'assembly',
          problems: {'missing': 2, 'cycles': 0, 'broken': 0, 'over_constrained': 0, 'near': 0},
          children: [_node('m', ['a', 'm'], kind: 'missing', name: 'Gone')]),
    ]));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model)));

    final bubble = find.byKey(const ValueKey('tree-bubble:a'));
    expect(bubble, findsOneWidget);
    expect(find.descendant(of: bubble, matching: find.text('2')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
    await tester.pump();
    expect(bubble, findsNothing);
    // The missing child carries the red state itself.
    expect(find.byKey(const ValueKey('tree-state:a/m:missing')), findsOneWidget);
  });

  testWidgets('a phone row has no buttons and a hidden row shows the eye-off', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'], name: 'Shown'),
      _node('h', ['h'], name: 'Tucked away', hidden: true),
    ]));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onVisibilityToggle: (_) {}, onHideSelected: (_) {})));

    final list = find.byKey(const ValueKey('assembly-tree-list'));
    for (final type in <Type>[IconButton, TextButton, ElevatedButton, OutlinedButton, FilledButton, PopupMenuButton, Switch]) {
      expect(find.descendant(of: list, matching: find.byType(type)), findsNothing, reason: '$type in a phone row');
    }
    expect(find.byKey(const ValueKey('tree-eye-off:h')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-eye-off:a')), findsNothing);
    expect(tester.getSize(_row('a')).height, kAssemblyTreeRowHeightPhone);
  });

  testWidgets('the selection bar reports each action with the selected row', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'], name: 'Bolt'),
      _node('b', ['b'], name: 'Nut'),
    ]));
    final calls = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      onHideSelected: (r) => calls.add('hide:${r.key}'),
      onIsolateSelected: (r) => calls.add('isolate:${r.key}'),
      onZoomSelected: (r) => calls.add('zoom:${r.key}'),
      onFocusSelected: (r) => calls.add('focus:${r.key}'),
      onAloneSelected: (r) => calls.add('alone:${r.key}'),
      onMoreSelected: (r) => calls.add('more:${r.key}'),
      onRowTap: (r) => calls.add('tap:${r.key}'),
    )));

    expect(find.byKey(const ValueKey('tree-selection-bar')), findsNothing);
    await tester.tap(_row('b'));
    await tester.pump();
    expect(model.selectedKey, 'b');
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);

    for (final k in ['hide', 'isolate', 'zoom', 'focus', 'alone', 'more']) {
      await tester.tap(find.byKey(ValueKey('tree-bar-$k')));
    }
    expect(calls, ['tap:b', 'hide:b', 'isolate:b', 'zoom:b', 'focus:b', 'alone:b', 'more:b']);
  });

  testWidgets('the grouping icon button reports its change and the rows follow (no Switch)', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      for (var i = 0; i < 4; i++)
        {
          ..._node('bolt$i', ['bolt$i'], name: 'Bolt M4'),
          'resolved_part_id': 'same-part',
        },
    ]));
    bool? reported;
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onGroupingChanged: (v) => reported = v)));

    expect(model.grouping, isTrue);
    expect(find.text('Bolt M4 x4'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree-grouping-toggle')));
    await tester.pump();
    expect(reported, isFalse);
    expect(model.grouping, isFalse);
    expect(find.text('Bolt M4 x4'), findsNothing);
    expect(find.text('Bolt M4 <1>'), findsOneWidget);
  });

  testWidgets('the desktop hover eye appears on hover and reports its tap', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([_node('a', ['a'], name: 'Bolt'), _node('b', ['b'], name: 'Nut')]));
    final toggled = <String>[];
    await tester.pumpWidget(_host(
      AssemblyTreeView(model: model, onVisibilityToggle: (r) => toggled.add(r.key)),
      layout: LayoutPreference.desktop,
    ));
    expect(tester.getSize(_row('a')).height, kAssemblyTreeRowHeightDesktop);
    expect(find.byKey(const ValueKey('tree-eye:a')), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(_row('a')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-eye:a')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-eye:b')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tree-eye:a')));
    expect(toggled, ['a']);

    await mouse.moveTo(tester.getCenter(_row('b')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-eye:a')), findsNothing);
    expect(find.byKey(const ValueKey('tree-eye:b')), findsOneWidget);
  });

  testWidgets('opening a part asks for its features once, and the root asks at start', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([_node('a', ['a'], name: 'Bolt', featureCount: 3)], featureCount: 2));
    final asked = <List<String>>[];
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onFeaturesRequested: asked.add)));
    await tester.pump();
    expect(asked, [<String>[]]);

    await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
    await tester.pump();
    expect(asked, [<String>[], ['a']]);

    model.setFeatures(['a'], const [AssemblyFeature('f1', 'Extrude 1')]);
    model.setFeatures(const [], const [AssemblyFeature('f0', 'Sketch 1')]);
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onFeaturesRequested: asked.add)));
    expect(find.text('Extrude 1'), findsOneWidget);
    expect(find.text('Sketch 1'), findsOneWidget);
  });

  testWidgets('states: each has its own icon; a failed level shows a hint, not a constraint state', (tester) async {
    Map<String, dynamic> c(String s, {int broken = 0, int near = 0, int dof = 0}) =>
        {'status': s, 'dof': dof, 'broken_mates': broken, 'near_mates': near};
    final model = AssemblyTreeModel(tree: _tree([
      _node('u', ['u'], constraint: c('under_constrained', dof: 3)),
      _node('o', ['o'], constraint: c('over_constrained')),
      _node('n', ['n'], constraint: c('over_constrained', near: 1)),
      _node('k', ['k'], constraint: c('fully_constrained')),
      _node('x', ['x'], constraint: c('under_constrained', broken: 1)),
      _node('f', ['f'], statusFailed: true, constraint: c('under_constrained')),
    ]));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model)));

    IconData icon(String key, String state) =>
        tester.widget<Icon>(find.byKey(ValueKey('tree-state:$key:$state'))).icon!;
    final icons = {
      icon('u', 'under_constrained'),
      icon('o', 'over_constrained'),
      icon('n', 'near'),
      icon('k', 'fully_constrained'),
      icon('x', 'broken'),
    };
    // over-constrained and near share a shape and differ by colour; the others are all distinct.
    expect(icons.length, 4);
    expect(tester.widget<Icon>(find.byKey(const ValueKey('tree-state:o:over_constrained'))).color,
        isNot(tester.widget<Icon>(find.byKey(const ValueKey('tree-state:n:near'))).color));
    expect(find.byKey(const ValueKey('tree-state:f:status_failed')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-state:f:under_constrained')), findsNothing);
  });

  testWidgets('multi-select toggles instead of selecting, and a rigid set draws its bracket', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'], constraint: {'status': 'fully_constrained', 'dof': 0, 'rigid_set': 'a'}),
      _node('b', ['b'], constraint: {'status': 'fully_constrained', 'dof': 0, 'rigid_set': 'a'}),
      _node('c', ['c']),
    ]));
    final toggled = <String>[];
    var tapped = 0;
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      isMultiSelectMode: true,
      selectedKeys: const {'a'},
      onMultiSelectToggle: (r) => toggled.add(r.key),
      onRowTap: (_) => tapped++,
    )));
    expect(find.byKey(const ValueKey('tree-bracket:a')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-bracket:b')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-bracket:c')), findsNothing);

    await tester.tap(_row('b'));
    await tester.longPress(_row('c'));
    expect(toggled, ['b', 'c']);
    expect(tapped, 0);
    expect(model.selectedKey, isNull);
  });

  testWidgets('collapse all closes everything but the root', (tester) async {
    final model = AssemblyTreeModel(tree: _tree([
      _node('a', ['a'], kind: 'assembly', children: [_node('b', ['a', 'b'])]),
    ]));
    model.setOpen('a', true);
    await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
    expect(_row('a/b'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tree-collapse-all')));
    await tester.pump();
    expect(_row('a/b'), findsNothing);
    expect(_row(''), findsOneWidget);
    expect(_row('a'), findsOneWidget);
  });

  group('review fixes', () {
    testWidgets('root features are asked for when the tree arrives after the view', (tester) async {
      final model = AssemblyTreeModel();
      final controller = AssemblyTreeController();
      final asked = <List<String>>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, controller: controller, onFeaturesRequested: asked.add)));
      await tester.pump();
      expect(asked, isEmpty);

      model.merge(_tree([_node('a', ['a'])], featureCount: 2));
      controller.refresh();
      await tester.pump();
      expect(asked, [<String>[]]);

      // Once: another refresh while the fetch is out does not ask again.
      controller.refresh();
      await tester.pump();
      expect(asked.length, 1);
    });

    testWidgets('a reveal made before the tree loads is applied when it arrives', (tester) async {
      final model = AssemblyTreeModel();
      final controller = AssemblyTreeController();
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, controller: controller)));
      controller.reveal(['z', 'zc'], select: true);
      await tester.pump();

      model.merge(_tree([
        for (var i = 0; i < 100; i++) _node('p$i', ['p$i']),
        _node('z', ['z'], kind: 'assembly', children: [_node('zc', ['z', 'zc'])]),
      ]));
      controller.refresh();
      await tester.pump();
      await tester.pump();
      expect(model.isOpen('z'), isTrue);
      expect(model.selectedKey, 'z/zc');
      final list = tester.getRect(find.byKey(const ValueKey('assembly-tree-list')));
      expect(_row('z/zc'), findsOneWidget);
      expect(tester.getRect(_row('z/zc')).bottom, lessThanOrEqualTo(list.bottom + 0.5));
    });

    testWidgets('a reveal while the docked tree is not shown scrolls when it is', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([
        for (var i = 0; i < 100; i++) _node('p$i', ['p$i']),
        _node('z', ['z'], kind: 'assembly', children: [_node('zc', ['z', 'zc'])]),
      ]));
      final controller = AssemblyTreeController();
      Widget view(bool visible) => _host(AssemblyTreeView(model: model, controller: controller, docked: true, visible: visible));
      await tester.pumpWidget(view(false));
      controller.reveal(['z', 'zc']);
      await tester.pump();
      await tester.pump();
      expect(model.isOpen('z'), isTrue);

      await tester.pumpWidget(view(true));
      await tester.pump();
      await tester.pump();
      final list = tester.getRect(find.byKey(const ValueKey('assembly-tree-list')));
      expect(_row('z/zc'), findsOneWidget);
      expect(tester.getRect(_row('z/zc')).bottom, lessThanOrEqualTo(list.bottom + 0.5));
    });

    testWidgets('the eye-off does nothing in multi-select on desktop', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([_node('h', ['h'], hidden: true)]));
      final toggled = <String>[];
      await tester.pumpWidget(_host(
        AssemblyTreeView(model: model, isMultiSelectMode: true, onVisibilityToggle: (r) => toggled.add(r.key)),
        layout: LayoutPreference.desktop,
      ));
      await tester.tap(find.byKey(const ValueKey('tree-eye-off:h')));
      expect(toggled, isEmpty);
    });

    testWidgets('on a phone the eye-off of a hidden row toggles it (and no other row has one)', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([_node('a', ['a']), _node('h', ['h'], hidden: true)]));
      final toggled = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onVisibilityToggle: (r) => toggled.add(r.key))));
      await tester.tap(find.byKey(const ValueKey('tree-eye-off:h')));
      expect(toggled, ['h']);
      expect(find.byKey(const ValueKey('tree-eye:a')), findsNothing);
    });

    testWidgets('features are asked for once while the fetch is out; forgetting it allows another ask', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([
        _node('a', ['a'], kind: 'assembly', featureCount: 1, children: [_node('b', ['a', 'b'], featureCount: 1)]),
      ]));
      final controller = AssemblyTreeController();
      final asked = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, controller: controller, onFeaturesRequested: (p) => asked.add(p.join('/')))));

      Future<void> toggleA() async {
        await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
        await tester.pump();
        await tester.pump();
      }

      await toggleA(); // open
      await toggleA(); // close
      await toggleA(); // reopen: still waiting for the first answer
      expect(asked, ['a']);

      controller.reveal(['a', 'b']); // through the open ancestor 'a': 'a' is not asked again
      await tester.pump();
      await tester.pump();
      expect(asked, ['a']);

      controller.forgetFeaturesRequest(['a']);
      await toggleA(); // close
      await toggleA(); // open
      expect(asked, ['a', 'a']);

      // An answer clears it: nothing more to ask.
      model.setFeatures(['a'], const [AssemblyFeature('f', 'Sketch 1')]);
      controller.refresh();
      await toggleA();
      await toggleA();
      expect(asked, ['a', 'a']);
    });

    // C3 (#13): a read-only feature row (a part that is not live) offers Edit in context where the host allows it.
    testWidgets('a read-only feature row: the bar has Edit in context, only where the host allows it', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([_node('a', ['a'], featureCount: 2)]));
      model.setOpen('a', true);
      model.setFeatures(['a'], const [AssemblyFeature('f1', 'Extrude 1'), AssemblyFeature('f2', 'Import 1')]);
      model.selectedKey = 'a#feature:f1';
      final edited = <String>[];
      Widget view() => _host(AssemblyTreeView(
            model: model,
            onHideSelected: (_) {},
            onRowEditInContext: (row) => edited.add(row.key),
            canEditInContext: (row) => row.featureId == 'f1',
          ));
      await tester.pumpWidget(view());
      expect(find.byKey(const ValueKey('tree-bar-edit-in-context')), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-bar-edit')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tree-bar-edit-in-context')));
      await tester.pump();
      expect(edited, ['a#feature:f1']);

      // A feature the host refuses (no edit panel): no bar.
      model.selectedKey = 'a#feature:f2';
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-bar-edit-in-context')), findsNothing);
    });

    testWidgets('a double-tap on a read-only feature row is Edit in context; none without the callback', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([_node('a', ['a'], featureCount: 2)]));
      model.setOpen('a', true);
      model.setFeatures(['a'], const [AssemblyFeature('f1', 'Extrude 1'), AssemblyFeature('f2', 'Import 1')]);
      final edited = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(
        model: model,
        onRowEditInContext: (row) => edited.add(row.key),
        canEditInContext: (row) => row.featureId == 'f1',
      )));
      for (final label in ['Extrude 1', 'Import 1']) {
        await tester.tap(find.text(label));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tap(find.text(label));
        await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 20));
      }
      expect(edited, ['a#feature:f1'], reason: 'the import has no edit panel: its double-tap does nothing');
      expect(model.selectedKey, 'a#feature:f2', reason: 'a tap still selects');
    });

    testWidgets('collapse all keeps the selected row listed, so the phone bar stays', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([
        _node('a', ['a'], kind: 'assembly', children: [_node('b', ['a', 'b'])]),
      ]));
      model.setOpen('a', true);
      model.selectedKey = 'a/b';
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onHideSelected: (_) {})));
      expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tree-collapse-all')));
      await tester.pump();
      await tester.pump();
      expect(model.selectedKey, 'a/b');
      expect(_row('a/b'), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);
    });

    testWidgets('a group row of hidden members shows no eye-off', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([
        for (var i = 0; i < 4; i++) {..._node('bolt$i', ['bolt$i'], name: 'Bolt M4', hidden: true), 'resolved_part_id': 'same'},
      ]));
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onVisibilityToggle: (_) {})));
      expect(find.text('Bolt M4 x4'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key.toString().contains('tree-eye-off:')), findsNothing);
    });

    testWidgets('more than six rigid sets still get different colours', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([
        for (var i = 0; i < 9; i++)
          _node('n$i', ['n$i'], constraint: {'status': 'fully_constrained', 'dof': 0, 'rigid_set': 's$i'}),
      ]));
      await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
      final colours = {
        for (var i = 0; i < 9; i++) tester.widget<ColoredBox>(find.byKey(ValueKey('tree-bracket:n$i'))).color,
      };
      expect(colours.length, 9);
    });
  });

  // A4: what the host adds on top of A3 - the Mates and Patterns folders listing the host's own rows, the flash of mates a pattern edit broke,
  // a status line, and the floating tree's Edit Alone row only while it is open.
  group('A4 additions', () {
    AssemblyTreeModel withFolders() {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'root',
          'part_name': 'Root',
          'kind': 'assembly',
          'status_included': true,
          'mates': {'count': 2, 'broken': 1},
          'patterns': {'count': 1},
          'children': [_node('a', ['a'], name: 'Arm')],
        }),
      );
      model.setFolderItems('#mates', const [
        AssemblyFolderItem.spec(id: 'm1', label: 'Coincident 1', status: 'broken', note: "Broken - can't be satisfied"),
        AssemblyFolderItem.spec(id: 'm2', label: 'Distance 1', note: '5 mm', suppressed: true),
      ]);
      model.setFolderItems('#patterns', const [AssemblyFolderItem.spec(id: 'p1', label: 'Linear 1', note: '×3')]);
      return model;
    }

    testWidgets('the folders open on a tap and list the host\'s rows; a tap and a long-press on a row report it', (tester) async {
      final model = withFolders();
      final taps = <String>[];
      final presses = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(
        model: model,
        onRowTap: (r) => taps.add('${r.kind.wire}:${r.itemId}'),
        onRowLongPress: (r) => presses.add('${r.kind.wire}:${r.itemId}'),
      )));
      expect(_row('#mates#item:m1'), findsNothing, reason: 'the folders start closed');

      await tester.tap(_row('#mates'));
      await tester.pump();
      expect(model.isOpen('#mates'), isTrue);
      expect(_row('#mates#item:m1'), findsOneWidget);
      expect(find.text('Coincident 1'), findsOneWidget);
      expect(find.text("Broken - can't be satisfied"), findsOneWidget, reason: 'a phone row has the note on a second line');

      await tester.tap(_row('#mates#item:m1'));
      await tester.longPress(_row('#mates#item:m1'));
      await tester.pump();
      expect(taps, ['mates_folder:null', 'mate:m1']);
      expect(presses, ['mate:m1'], reason: 'a note does not take the long-press away (no tooltip on touch)');

      await tester.tap(find.byKey(const ValueKey('tree-chevron:#patterns')));
      await tester.pump();
      expect(find.text('Linear 1'), findsOneWidget);
      expect(model.selectedKey, '#mates#item:m1', reason: 'the chevron does not select');
    });

    testWidgets('a broken mate is red with a warning icon, a suppressed one is dimmed, a plain one keeps the link icon', (tester) async {
      final model = withFolders()..setOpen('#mates', true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      Icon icon(String id) => tester.widget<Icon>(find.descendant(of: _row('#mates#item:$id'), matching: find.byType(Icon)).first);
      expect(icon('m1').icon, Icons.warning_amber_rounded);
      expect(icon('m1').color, error);
      expect(tester.widget<Text>(find.descendant(of: _row('#mates#item:m1'), matching: find.text('Coincident 1'))).style?.color, error);
      expect(icon('m2').icon, Icons.link);
      expect(tester.widget<Opacity>(find.descendant(of: _row('#mates#item:m2'), matching: find.byType(Opacity)).first).opacity, lessThan(1));
    });

    testWidgets('C2: an item row is coloured by its state: lost and broken red, held and near amber, a followed reference an info icon',
        (tester) async {
      final model = withFolders();
      model.setFolderItems('#mates', const [
        AssemblyFolderItem.spec(id: 'l', label: 'Coincident 1', status: 'broken', lost: true),
        AssemblyFolderItem.spec(id: 'h', label: 'Coincident 2', status: 'broken', held: true),
        AssemblyFolderItem.spec(id: 'n', label: 'Coincident 3', status: 'near'),
        AssemblyFolderItem.spec(id: 'f', label: 'Coincident 4', followed: true, note: 'Followed'),
      ]);
      model.setOpen('#mates', true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
      final scheme = Theme.of(tester.element(find.text('Mates'))).colorScheme;
      final amber = AiPalette.of(tester.element(find.text('Mates'))).warning;
      Icon icon(String id) => tester.widget<Icon>(find.descendant(of: _row('#mates#item:$id'), matching: find.byType(Icon)).first);
      expect(icon('l').color, scheme.error);
      expect(icon('h').color, amber, reason: 'a held mate reads amber though its listing says broken');
      expect(icon('n').color, amber);
      expect(icon('f').icon, Icons.info_outline);
      expect(icon('f').color, scheme.primary);
    });

    testWidgets('C2: an open folder without items asks for them once (opened, or open already); a filter notes the folders not read',
        (tester) async {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'root',
          'part_name': 'Root',
          'kind': 'assembly',
          'mates': {'count': 1},
          'children': [
            {
              ..._node('a', ['a'], name: 'Arm'),
              'kind': 'assembly',
              'mates': {'count': 2},
              'children': [_node('x', ['a', 'x'], name: 'X')],
            },
          ],
        }),
      )..openAll(['#mates'], remember: false);
      final asked = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onFolderItemsRequested: asked.add)));
      await tester.pump();
      expect(asked, ['#mates'], reason: 'the root folder was open already (restored)');
      await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tree-chevron:a#mates')));
      await tester.pump();
      await tester.pump();
      expect(asked, ['#mates', 'a#mates']);
      // Asked once while it stays open (rebuilds ask nothing more); closing and opening again asks again (the host's retry).
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onFolderItemsRequested: asked.add)));
      await tester.pump();
      expect(asked, ['#mates', 'a#mates']);
      await tester.tap(find.byKey(const ValueKey('tree-chevron:a#mates')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tree-chevron:a#mates')));
      await tester.pump();
      await tester.pump();
      expect(asked, ['#mates', 'a#mates', 'a#mates']);

      // C1-1: a filter while some folders are not read says so (and :mates is not an unknown token).
      await tester.tap(find.byTooltip('Filter'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':mates');
      await tester.pump();
      final notes = tester.widget<Text>(find.byKey(const ValueKey('tree-filter-notes'))).data!;
      expect(notes, contains('Mates and patterns are searched only in folders you have opened'));
      expect(notes, isNot(contains('Unknown filter')));
      model.setFolderItems('#mates', const [AssemblyFolderItem.spec(id: 'r', label: 'Coincident 1')]);
      model.setFolderItems('a#mates', const [AssemblyFolderItem.spec(id: 'm', label: 'Coincident 1')]);
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':mates ');
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-filter-notes')), findsNothing, reason: 'every folder is read now');
    });

    testWidgets('C2 review: a folder open already under a collapsed row asks for its items when the row is opened', (tester) async {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'root',
          'part_name': 'Root',
          'kind': 'assembly',
          'children': [
            {
              ..._node('a', ['a'], name: 'Arm'),
              'kind': 'assembly',
              'mates': {'count': 2},
              'children': [_node('x', ['a', 'x'], name: 'X')],
            },
          ],
        }),
      )..openAll(['a#mates'], remember: false); // restored, under the collapsed Arm
      final asked = <String>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onFolderItemsRequested: asked.add)));
      await tester.pump();
      expect(asked, isEmpty, reason: 'not listed yet');
      await tester.tap(find.byKey(const ValueKey('tree-chevron:a')));
      await tester.pump();
      await tester.pump();
      expect(asked, ['a#mates']);
      // Medium review: a tap on the folder's own row (not its chevron) closes and opens it too, and asks again when it opens.
      await tester.tap(_row('a#mates'));
      await tester.pump();
      expect(model.isOpen('a#mates'), isFalse);
      await tester.tap(_row('a#mates'));
      await tester.pump(kDoubleTapTimeout);
      await tester.pump();
      expect(model.isOpen('a#mates'), isTrue);
      expect(asked, ['a#mates', 'a#mates']);
    });

    testWidgets("C2: a selected item of another level shows the strip with Focus here to edit; the host's own level shows none",
        (tester) async {
      final model = withFolders()..setOpen('#mates', true);
      final focused = <String>[];
      String? level = 'Root';
      Widget view() => _host(AssemblyTreeView(
            model: model,
            itemOtherLevel: (r) => r.itemId == null ? null : level,
            onItemFocusToEdit: (r) => focused.add(r.key),
          ));
      await tester.pumpWidget(view());
      await tester.tap(_row('#mates#item:m1'));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const ValueKey('tree-focus-to-edit-note'))).data, 'Coincident 1 is in Root');
      await tester.tap(find.byKey(const ValueKey('tree-focus-to-edit')));
      expect(focused, ['#mates#item:m1']);
      level = null;
      await tester.pumpWidget(view());
      expect(find.byKey(const ValueKey('tree-focus-to-edit')), findsNothing);
    });

    testWidgets('C2-5: on a narrow pane the strip puts its button under the note, which is not cut short', (tester) async {
      final model = withFolders()..setOpen('#mates', true);
      Widget view(double width) => _host(
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: AssemblyTreeView(
                model: model,
                docked: true,
                itemOtherLevel: (r) => r.itemId == null ? null : 'Sub-assembly',
                onItemFocusToEdit: (_) {},
              ),
            ),
          ),
          layout: LayoutPreference.desktop);
      await tester.pumpWidget(view(300));
      await tester.tap(_row('#mates#item:m1'));
      await tester.pump();
      final note = find.byKey(const ValueKey('tree-focus-to-edit-note'));
      expect(tester.renderObject<RenderParagraph>(note).didExceedMaxLines, isFalse, reason: 'the whole note shows');
      expect(tester.getTopLeft(find.byKey(const ValueKey('tree-focus-to-edit'))).dy, greaterThan(tester.getTopLeft(note).dy),
          reason: 'the button is under the note');
      // A wide pane keeps one line, the button beside it.
      await tester.pumpWidget(view(800));
      await tester.pump();
      expect(tester.getCenter(find.byKey(const ValueKey('tree-focus-to-edit'))).dy, closeTo(tester.getCenter(note).dy, 4));
      expect(tester.renderObject<RenderParagraph>(note).didExceedMaxLines, isFalse);
    });

    testWidgets('a desktop row has the note after the label, on one line', (tester) async {
      final model = withFolders()..setOpen('#mates', true);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model), layout: LayoutPreference.desktop));
      expect(find.byKey(const ValueKey('tree-note:#mates#item:m1')), findsNothing, reason: 'no second line');
      expect(find.textContaining("Broken - can't be satisfied", findRichText: true), findsOneWidget);
      expect(tester.getSize(_row('#mates#item:m1')).height, kAssemblyTreeRowHeightDesktop);
    });

    testWidgets('a new flash token pulses the named mate rows and opens the Mates folder', (tester) async {
      final model = withFolders();
      Widget view(int token, Set<String> ids) => _host(AssemblyTreeView(model: model, flashItemIds: ids, flashToken: token));
      await tester.pumpWidget(view(0, const {}));
      expect(_row('#mates#item:m1'), findsNothing);

      await tester.pumpWidget(view(1, const {'m1'}));
      await tester.pump(); // the post-frame work
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.isOpen('#mates'), isTrue);
      final error = Theme.of(tester.element(find.text('Mates'))).colorScheme.error;
      Color? fill() => tester.widget<Material>(find.descendant(of: _row('#mates#item:m1'), matching: find.byType(Material)).first).color;
      // Somewhere in the two seconds the row's background is tinted with the error colour, and at the end it is plain again.
      var tinted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final c = fill();
        if (c != null && c.a > 0 && c.r == error.r && c.g == error.g && c.b == error.b) tinted = true;
      }
      expect(tinted, isTrue);
      expect(fill(), Colors.transparent);
      // The other mate never pulses.
      expect(tester.widget<Material>(find.descendant(of: _row('#mates#item:m2'), matching: find.byType(Material)).first).color, Colors.transparent);
    });

    testWidgets("C2-1: a flash in a nested level's Mates folder opens that folder and the rows down to it; only its rows pulse", (tester) async {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'root',
          'part_name': 'Root',
          'kind': 'assembly',
          'mates': {'count': 1, 'broken': 1},
          'children': [
            {
              ..._node('a', ['a'], name: 'Arm'),
              'kind': 'assembly',
              'mates': {'count': 1, 'broken': 1},
              'children': [_node('x', ['a', 'x'], name: 'X')],
            },
          ],
        }),
      );
      // The same mate id at the root and in Arm (ids are a level's own): only Arm's pulses.
      model.setFolderItems('#mates', const [AssemblyFolderItem.spec(id: 'm1', label: 'Coincident 1', status: 'broken')]);
      model.setFolderItems('a#mates', const [AssemblyFolderItem.spec(id: 'm1', label: 'Coincident 1', status: 'broken')]);
      model.setOpen('#mates', true);
      Widget view(int token) =>
          _host(AssemblyTreeView(model: model, flashItemIds: const {'m1'}, flashToken: token, flashFolderKey: 'a#mates'));
      await tester.pumpWidget(view(0));
      expect(model.isOpen('a'), isFalse);
      await tester.pumpWidget(view(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(model.isOpen('a'), isTrue, reason: 'the level above the folder opens');
      expect(model.isOpen('a#mates'), isTrue, reason: "the level's own folder opens, not the root's");
      expect(_row('a#mates#item:m1'), findsOneWidget);
      Color? fill(String key) => tester.widget<Material>(find.descendant(of: _row(key), matching: find.byType(Material)).first).color;
      var nestedTinted = false;
      var rootTinted = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if ((fill('a#mates#item:m1')?.a ?? 0) > 0) nestedTinted = true;
        if ((fill('#mates#item:m1')?.a ?? 0) > 0) rootTinted = true;
      }
      expect(nestedTinted, isTrue);
      expect(rootTinted, isFalse, reason: "the root's mate of the same id is not the one the edit broke");
    });

    testWidgets('a status line shows under the header, and nothing when empty', (tester) async {
      final model = withFolders();
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, statusLine: 'Group: 5 DOF')));
      expect(find.byKey(const ValueKey('assembly-motion-summary')), findsOneWidget);
      expect(find.text('Group: 5 DOF'), findsOneWidget);
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, statusLine: '')));
      expect(find.byKey(const ValueKey('assembly-motion-summary')), findsNothing);
    });

    testWidgets('the Edit Alone row is in the floating tree only while it is open (the pill is the way out when it is closed)', (tester) async {
      final model = withFolders();
      Widget view(bool visible) => _host(AssemblyTreeView(model: model, visible: visible, editAlone: const AssemblyEditAloneInfo(label: 'Arm'), onEditAloneDone: () {}));
      await tester.pumpWidget(view(true));
      expect(find.byKey(const ValueKey('edit-alone-done')), findsOneWidget);
      await tester.pumpWidget(view(false));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('edit-alone-done')), findsNothing);
      // Docked, it is always there.
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, visible: false, editAlone: const AssemblyEditAloneInfo(label: 'Arm'), onEditAloneDone: () {}), layout: LayoutPreference.desktop));
      expect(find.byKey(const ValueKey('edit-alone-done')), findsNothing, reason: 'a docked tree that is not shown draws nothing; the host shows it');
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, editAlone: const AssemblyEditAloneInfo(label: 'Arm'), onEditAloneDone: () {}), layout: LayoutPreference.desktop));
      expect(find.byKey(const ValueKey('edit-alone-done')), findsOneWidget);
    });

    testWidgets('a row hidden for this session shows the eye-off like one hidden on the backend', (tester) async {
      final model = AssemblyTreeModel(tree: _tree([_node('a', ['a'], name: 'Arm'), _node('b', ['b'], name: 'Bar')]))..setSessionHiddenKeys({'b'});
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, onVisibilityToggle: (_) {})));
      expect(find.byKey(const ValueKey('tree-eye-off:b')), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-eye-off:a')), findsNothing);
    });
  });

  group('B2: filter and expand to selection', () {
    // Root > Arm (assembly) > Mid (assembly) > Pin, plus Plate and Pin-2 at the top.
    AssemblyTreeModel deep() => AssemblyTreeModel(tree: _tree([
          _node('a', ['a'], kind: 'assembly', name: 'Arm', children: [
            _node('b', ['a', 'b'], kind: 'assembly', name: 'Mid', children: [_node('c', ['a', 'b', 'c'], name: 'Pin')]),
          ]),
          _node('z', ['z'], name: 'Plate'),
          _node('y', ['y'], name: 'Spare', hidden: true),
        ]));

    Widget desktopView(AssemblyTreeModel model, {AssemblyTreeController? controller}) =>
        _host(AssemblyTreeView(model: model, controller: controller, docked: true), layout: LayoutPreference.desktop);

    List<String> keysShown() => [
          for (final e in _rows().evaluate()) ((e.widget.key as ValueKey).value as String).substring('tree-row:'.length),
        ];

    testWidgets('desktop: a deep match is listed with its ancestors (only the match marked), and clearing the filter gives the rows back', (tester) async {
      final model = deep();
      await tester.pumpWidget(desktopView(model));
      expect(keysShown(), ['', 'a', 'z', 'y']);

      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'pin');
      await tester.pump();
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c']);
      expect(find.byKey(const ValueKey('tree-match:a/b/c')), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-match:a')), findsNothing, reason: 'an ancestor is plain');
      expect(find.byKey(const ValueKey('tree-match:a/b')), findsNothing);
      expect(model.openKeys, isEmpty, reason: 'the filter does not change what is open');

      // The chevrons are inert while a filter is on (a row that cannot be toggled has none), and a tap on a row only selects it.
      expect(find.byKey(const ValueKey('tree-chevron:a')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tree-row:a')));
      await tester.pump();
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c']);
      expect(model.isOpen('a'), isFalse);
      expect(model.selectedKey, 'a');

      await tester.tap(find.byKey(const ValueKey('tree-filter-clear')));
      await tester.pump();
      expect(keysShown(), ['', 'a', 'z', 'y']);
      expect(model.openKeys, isEmpty);
    });

    testWidgets('a token filters by state, and an unknown token says so', (tester) async {
      final model = deep();
      await tester.pumpWidget(desktopView(model));
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':hidden');
      await tester.pump();
      expect(keysShown(), ['', 'y']);

      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':Foo pin');
      await tester.pump();
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c']);
      expect(find.textContaining('Unknown filter :foo'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'zzz');
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-filter-empty')), findsOneWidget);
    });

    testWidgets('a status token before the status has arrived says it is still loading', (tester) async {
      final model = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'root',
          'part_name': 'Root',
          'kind': 'assembly',
          'status_included': false,
          'children': [_node('a', ['a'], name: 'Arm')],
        }),
      );
      await tester.pumpWidget(desktopView(model));
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':errors');
      await tester.pump();
      expect(find.textContaining('Status is still loading'), findsOneWidget);
    });

    testWidgets('desktop: Esc clears the filter, and clearing it reveals the selected row', (tester) async {
      final model = deep()..selectedKey = 'a/b/c';
      await tester.pumpWidget(desktopView(model));
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'plate');
      await tester.pump();
      expect(keysShown(), ['', 'z']);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('tree-filter-field'))).controller!.text, isEmpty);
      // Section 11: the selected row is revealed when the filter goes, so it is where the person left it.
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c', 'z', 'y']);
      expect(model.selectedKey, 'a/b/c');
    });

    testWidgets('expand and collapse are off while a filter is on, and expand is off with no selection', (tester) async {
      final model = deep();
      await tester.pumpWidget(desktopView(model));
      bool enabled(String key) => tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed != null;
      expect(enabled('tree-expand-to-selection'), isFalse);
      expect(enabled('tree-collapse-all'), isTrue);
      model.selectedKey = 'a/b/c';
      await tester.pumpWidget(desktopView(model));
      expect(enabled('tree-expand-to-selection'), isTrue);
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'pin');
      await tester.pump();
      expect(enabled('tree-expand-to-selection'), isFalse);
      expect(enabled('tree-collapse-all'), isFalse);
    });

    testWidgets('expand to selection opens a 4-deep path among 2,000 rows and scrolls to the row', (tester) async {
      final tops = [
        for (var i = 0; i < 40; i++)
          _node('a$i', ['a$i'], kind: 'assembly', children: [
            _node('b', ['a$i', 'b'], kind: 'assembly', children: [
              _node('c', ['a$i', 'b', 'c'], kind: 'assembly', children: [
                for (var j = 0; j < 50; j++) _node('p$i-$j', ['a$i', 'b', 'c', 'p$i-$j']),
              ]),
            ]),
          ]),
      ];
      final model = AssemblyTreeModel(tree: _tree(tops));
      model.openAll([for (var i = 0; i < 40; i++) 'a$i']); // every top-level assembly shows its 'b': more than a screenful, the path below is closed
      const target = 'a30/b/c/p30-45';
      model.selectedKey = target;
      await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
      expect(_row(target), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tree-expand-to-selection')));
      await tester.pump();
      await tester.pump();

      expect(model.isOpen('a30/b'), isTrue);
      expect(model.isOpen('a30/b/c'), isTrue);
      expect(model.selectedKey, target);
      final rowFinder = _row(target);
      expect(rowFinder, findsOneWidget);
      final list = tester.getRect(find.byKey(const ValueKey('assembly-tree-list')));
      final rect = tester.getRect(rowFinder);
      expect(rect.top, greaterThanOrEqualTo(list.top - 0.5));
      expect(rect.bottom, lessThanOrEqualTo(list.bottom + 0.5));
    });

    testWidgets('a status token says "unavailable" when the status failed, and nothing once it is here', (tester) async {
      AssemblyTreeModel noStatus() => AssemblyTreeModel(
            tree: AssemblyTreeResponseDto.fromJson({
              'part_id': 'root',
              'part_name': 'Root',
              'kind': 'assembly',
              'status_included': false,
              'children': [_node('a', ['a'], name: 'Arm')],
            }),
          );
      Widget view(AssemblyTreeModel m, {bool unavailable = false}) =>
          _host(AssemblyTreeView(model: m, docked: true, statusUnavailable: unavailable), layout: LayoutPreference.desktop);
      await tester.pumpWidget(view(noStatus(), unavailable: true));
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':warnings');
      await tester.pump();
      expect(find.textContaining('Status unavailable'), findsOneWidget);
      expect(find.textContaining('still loading'), findsNothing);

      await tester.pumpWidget(view(deep()));
      await tester.pump();
      expect(find.textContaining('Status'), findsNothing, reason: 'the tree has its status');
    });

    testWidgets('multi-select ends the filter: its field is gone, so the rows must not stay narrowed', (tester) async {
      final model = deep();
      // The header is what hides the field, so that is what ends the filter (the mode flag is not set in this test).
      Widget view({required bool multi}) => _host(
            AssemblyTreeView(model: model, docked: true, multiSelectHeader: multi ? const Text('2 selected') : null),
            layout: LayoutPreference.desktop,
          );
      await tester.pumpWidget(view(multi: false));
      await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'pin');
      await tester.pump();
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c']);

      await tester.pumpWidget(view(multi: true));
      await tester.pump();
      expect(keysShown(), ['', 'a', 'z', 'y'], reason: 'the filter ended with the multi-select');

      await tester.pumpWidget(view(multi: false));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('tree-filter-field'))).controller!.text, isEmpty);
      expect(keysShown(), ['', 'a', 'z', 'y']);
    });

    testWidgets('an expand to selection asked for while the view is not built does nothing: the host shows the tree first and asks after the frame', (tester) async {
      final model = deep()..selectedKey = 'a/b/c';
      final controller = AssemblyTreeController()..expandToSelection();
      await tester.pumpWidget(desktopView(model, controller: controller));
      await tester.pump();
      await tester.pump();
      expect(model.openKeys, isEmpty, reason: 'nothing was kept');
      expect(keysShown(), ['', 'a', 'z', 'y']);
      controller.expandToSelection(); // attached now
      await tester.pump();
      expect(keysShown(), ['', 'a', 'a/b', 'a/b/c', 'z', 'y']);
    });

    group('phone header', () {
      Future<void> phoneSize(WidgetTester tester, Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      for (final width in [360.0, 320.0]) {
        testWidgets('is one line at $width dp: the title and five small icons, nothing oversized, and no overflow', (tester) async {
          await phoneSize(tester, Size(width, 780));
          final model = deep()..selectedKey = 'a';
          await tester.pumpWidget(_host(AssemblyTreeView(model: model, width: width, onClose: () {})));
          expect(tester.takeException(), isNull);
          final keys = ['tree-filter-toggle', 'tree-grouping-toggle', 'tree-expand-to-selection', 'tree-collapse-all', 'tree-close'];
          final title = tester.getRect(find.text('Assembly'));
          final rects = [for (final k in keys) tester.getRect(find.byKey(ValueKey(k)))];
          for (final r in rects) {
            expect(r.height, lessThanOrEqualTo(40), reason: 'no oversized control (A4.1)');
            expect(r.width, lessThanOrEqualTo(40));
            expect((r.center.dy - title.center.dy).abs(), lessThan(1), reason: 'one line');
            expect(r.right, lessThanOrEqualTo(width));
          }
          expect(title.right, lessThanOrEqualTo(rects.first.left), reason: 'the title keeps its own room');
          expect(title.width, greaterThan(40), reason: 'and is not squeezed away');
        });
      }

      testWidgets('the filter icon turns the header into the field (still one line); close or Esc gives the title back and clears the filter', (tester) async {
        await phoneSize(tester, const Size(360, 780));
        final model = deep();
        await tester.pumpWidget(_host(AssemblyTreeView(model: model, width: 360)));
        expect(find.byKey(const ValueKey('tree-filter-field')), findsNothing);

        await tester.tap(find.byKey(const ValueKey('tree-filter-toggle')));
        await tester.pump();
        await tester.pump();
        expect(find.byKey(const ValueKey('tree-filter-field')), findsOneWidget);
        expect(find.text('Assembly'), findsNothing);
        expect(tester.getSize(find.byKey(const ValueKey('tree-filter-header'))).height, 48, reason: 'the header is the same height');
        expect(tester.takeException(), isNull);

        await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'pin');
        await tester.pump();
        expect(keysShown(), ['', 'a', 'a/b', 'a/b/c']);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(find.byKey(const ValueKey('tree-filter-field')), findsNothing);
        expect(find.text('Assembly'), findsOneWidget);
        expect(keysShown(), ['', 'a', 'z', 'y']);

        await tester.tap(find.byKey(const ValueKey('tree-filter-toggle')));
        await tester.pump();
        await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'plate');
        await tester.pump();
        expect(keysShown(), ['', 'z']);
        await tester.tap(find.byKey(const ValueKey('tree-filter-close')));
        await tester.pump();
        expect(keysShown(), ['', 'a', 'z', 'y']);
        expect(find.text('Assembly'), findsOneWidget);
      });
    });
  });

  // B3 (`docs/assembly-tree-overhaul-scope.md` 10.6): the whole tree stays while a level is focused; the strip above it names the levels.
  group('B3: focus and Edit Alone context', () {
    /// root > a > b > c, root > z, and a second branch root > a2 > x.
    AssemblyTreeModel nested() => AssemblyTreeModel(
          tree: _tree([
            _node('a', ['a'], kind: 'assembly', name: 'Mast', children: [
              _node('b', ['a', 'b'], kind: 'assembly', name: 'Arm', children: [
                _node('c', ['a', 'b', 'c'], name: 'Bolt'),
              ]),
            ]),
            _node('z', ['z'], name: 'Plate'),
            _node('a2', ['a2'], kind: 'assembly', name: 'Mast copy', children: [_node('x', ['a2', 'x'], name: 'Pin')]),
          ]),
        )..openAll(const ['a', 'a/b', 'a2']);

    testWidgets('the focus roles: the focused row, the rows below it, the way down (and the root) as context, the rest outside', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      AssemblyFocusRole role(String key) => model.focusRoleOf(model.visibleRows().firstWhere((r) => r.key == key));
      expect(role('a/b'), AssemblyFocusRole.focused);
      expect(role('a/b/c'), AssemblyFocusRole.inside);
      expect(role(''), AssemblyFocusRole.ancestor);
      expect(role('a'), AssemblyFocusRole.ancestor);
      for (final key in ['z', 'a2', 'a2/x']) {
        expect(role(key), AssemblyFocusRole.outside, reason: key);
      }
      model.focusPath = const [];
      expect(role('z'), AssemblyFocusRole.none, reason: 'nothing focused: no row is outside');
    });

    testWidgets('a group on the way down is context; another group is outside', (tester) async {
      // Four identical siblings group (spec section 3): the focus is the second of them.
      final model = AssemblyTreeModel(
        tree: _tree([
          for (var i = 1; i <= 4; i++) {..._node('s$i', ['s$i'], name: 'Screw'), 'resolved_part_id': 'part-screw'},
          _node('z', ['z'], name: 'Plate'),
        ]),
      )..openAll(const ['#group:s1'])..focusPath = const ['s2'];
      final rows = model.visibleRows();
      final group = rows.firstWhere((r) => r.kind == AssemblyRowKind.group);
      expect(model.focusRoleOf(group), AssemblyFocusRole.ancestor, reason: 'the focused screw sits in this group');
      expect(model.focusRoleOf(rows.firstWhere((r) => r.key == 's2')), AssemblyFocusRole.focused);
      expect(model.focusRoleOf(rows.firstWhere((r) => r.key == 's3')), AssemblyFocusRole.outside);
      expect(model.focusRoleOf(rows.firstWhere((r) => r.key == 'z')), AssemblyFocusRole.outside);
    });

    testWidgets('outside rows are dimmed and the focused branch has the rail; the strip stands for the root row', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, focusCrumbs: const ['Root', 'Mast', 'Arm'], onFocusCrumb: (_) {})));
      for (final key in ['z', 'a2', 'a2/x']) {
        expect(find.byKey(ValueKey('tree-dimmed:$key')), findsOneWidget, reason: key);
      }
      for (final key in ['a', 'a/b', 'a/b/c']) {
        expect(find.byKey(ValueKey('tree-dimmed:$key')), findsNothing, reason: key);
      }
      expect(find.byKey(const ValueKey('tree-focus-rail:a/b')), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-focus-rail:a/b/c')), findsOneWidget);
      expect(find.byKey(const ValueKey('tree-focus-rail:a')), findsNothing);
      expect(find.byKey(const ValueKey('tree-focus-rail:z')), findsNothing);
      expect(find.byKey(const ValueKey('focus-strip')), findsOneWidget);
      expect(_row(''), findsNothing, reason: 'rule 5: the root crumb is the root row');
      expect(_row('a'), findsOneWidget);
    });

    testWidgets('a crumb above the last reports its depth; the last does nothing; one crumb is no strip', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      final taps = <int>[];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, focusCrumbs: const ['Root', 'Mast', 'Arm'], onFocusCrumb: taps.add)));
      await tester.tap(find.byKey(const ValueKey('focus-crumb:0')));
      await tester.tap(find.byKey(const ValueKey('focus-crumb:1')));
      await tester.tap(find.byKey(const ValueKey('focus-crumb:2')));
      expect(taps, [0, 1]);
      await tester.pumpWidget(_host(AssemblyTreeView(model: nested(), focusCrumbs: const ['Root'], onFocusCrumb: taps.add)));
      expect(find.byKey(const ValueKey('focus-strip')), findsNothing);
      expect(_row(''), findsOneWidget, reason: 'nothing focused: the root row is drawn');
    });

    testWidgets('with the root row in the strip the list still scrolls to and marks the right rows', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      final controller = AssemblyTreeController();
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, controller: controller, focusCrumbs: const ['Root', 'Mast', 'Arm'])));
      controller.reveal(const ['a2', 'x'], select: true);
      await tester.pump();
      await tester.pump();
      expect(model.selectedKey, 'a2/x');
      expect(_row('a2/x'), findsOneWidget);
      // No row went missing under the strip's list offset: the first row is the first below the root.
      final first = tester.getTopLeft(_row('a')).dy;
      expect(first, lessThan(tester.getTopLeft(_row('a/b')).dy));
    });

    testWidgets('a selected row outside the focus offers "Focus here"; inside or on the way, nothing is offered', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      final here = <String>[];
      Widget view() => _host(AssemblyTreeView(model: model, focusCrumbs: const ['Root', 'Mast', 'Arm'], onFocusHere: (row) => here.add(row.key)));
      await tester.pumpWidget(view());
      expect(find.byKey(const ValueKey('tree-focus-here')), findsNothing);
      model.selectedKey = 'a/b/c';
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-focus-here')), findsNothing, reason: 'inside the focus');
      model.selectedKey = 'a';
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-focus-here')), findsNothing, reason: 'on the way down');
      await tester.tap(_row('a2/x'));
      await tester.pump();
      expect(model.selectedKey, 'a2/x');
      expect(find.byKey(const ValueKey('tree-focus-here-note')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('tree-focus-here')));
      expect(here, ['a2/x']);
    });

    testWidgets('the Edit Alone strip: Editing, Done, "in ..." crumbs and "used N x" from 2; the root row is not drawn', (tester) async {
      final crumbs = <int>[];
      var done = 0;
      Widget view(int? used) => _host(AssemblyTreeView(
            model: nested(),
            editAlone: AssemblyEditAloneInfo(label: 'Arm', inLabels: const ['Rover', 'Mast'], usedCount: used),
            onEditAloneDone: () => done++,
            onEditAloneCrumb: crumbs.add,
          ));
      await tester.pumpWidget(view(2));
      expect(find.textContaining('Editing', findRichText: true), findsOneWidget);
      expect(find.text('used 2 \u00D7'), findsOneWidget);
      expect(_row(''), findsNothing);
      await tester.tap(find.byKey(const ValueKey('edit-alone-crumb:1')));
      await tester.tap(find.byKey(const ValueKey('edit-alone-crumb:0')));
      expect(crumbs, [1, 0]);
      await tester.tap(find.byKey(const ValueKey('edit-alone-done')));
      expect(done, 1);
      await tester.pumpWidget(view(1));
      expect(find.byKey(const ValueKey('edit-alone-used')), findsNothing, reason: 'placed once: nothing to say');
      await tester.pumpWidget(view(null));
      expect(find.byKey(const ValueKey('edit-alone-used')), findsNothing, reason: 'not known: nothing is claimed');
    });

    testWidgets('a filter with the root in the strip lists the matches, and says when nothing matches', (tester) async {
      final model = nested()..focusPath = const ['a', 'b'];
      await tester.pumpWidget(_host(AssemblyTreeView(model: model, focusCrumbs: const ['Root', 'Mast', 'Arm']), layout: LayoutPreference.desktop));
      await tester.enterText(find.byType(TextField), 'pin');
      await tester.pump();
      expect(_row('a2/x'), findsOneWidget);
      expect(_row('a2'), findsOneWidget, reason: 'the way to the match');
      expect(_row(''), findsNothing);
      await tester.enterText(find.byType(TextField), 'nothing like this');
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-filter-empty')), findsOneWidget);
    });
  });
}
