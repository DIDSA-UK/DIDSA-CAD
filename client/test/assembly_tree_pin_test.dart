import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/assembly_context_strip.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_pin.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';

// B5 (`docs/assembly-tree-overhaul-scope.md` 10.6): the phone sheet's deep trees. Ancestors pin to the top of the list while it scrolls, a tap on
// one collapses back to it, the indent stops at 4 levels of 12 dp, and under Focus the rows outside the focused branch are not shown. Also B4's
// carried items 1 and 2 (the strips under the header).

Map<String, dynamic> _node(String id, List<String> path, {List<Map<String, dynamic>> children = const [], int? leaves}) => {
      'occurrence_id': id,
      'path': path,
      'resolved_part_id': 'part-$id',
      'part_name': 'Item $id',
      'kind': children.isEmpty && leaves == null ? 'part' : 'assembly',
      'hidden': false,
      'children': [
        ...children,
        for (var i = 0; i < (leaves ?? 0); i++) _node('${id}_$i', [...path, '${id}_$i']),
      ],
    };

/// A chain `n1 > n2 > ... > nDepth`, the deepest holding [leaves] leaves.
Map<String, dynamic> _chain(int depth, {int leaves = 0, List<String> prefix = const []}) {
  Map<String, dynamic> go(int level, List<String> parent) {
    final id = 'n$level';
    final path = [...parent, id];
    return _node(id, path, children: level < depth ? [go(level + 1, path)] : const [], leaves: level == depth && leaves > 0 ? leaves : null);
  }

  return go(1, prefix);
}

AssemblyTreeModel _modelOf(List<Map<String, dynamic>> children) => AssemblyTreeModel(
      tree: AssemblyTreeResponseDto.fromJson({
        'part_id': 'root',
        'part_name': 'Rover',
        'kind': 'assembly',
        'feature_count': 0,
        'status_included': true,
        'children': children,
      }),
    );

class _Host extends StatefulWidget {
  const _Host({super.key, required this.model, this.controller, this.initial = AssemblyTreeSheetHeight.full});
  final AssemblyTreeModel model;
  final AssemblyTreeController? controller;
  final AssemblyTreeSheetHeight initial;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late AssemblyTreeSheetHeight height = widget.initial;
  final List<String> taps = [];
  final List<String> focusHere = [];

  @override
  Widget build(BuildContext context) => AssemblyTreeView(
        model: widget.model,
        controller: widget.controller,
        sheetHeight: height,
        onSheetHeightChanged: (h) => setState(() => height = h),
        onRowTap: (row) => taps.add(row.key),
        onFocusHere: (row) => focusHere.add(row.key),
        onHideSelected: (_) {},
        onMoreSelected: (_) {},
        onClose: () {},
      );
}

Future<void> _pump(WidgetTester tester, Widget child, {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: LayoutModeScope(
      controller: LayoutModeController(preference: LayoutPreference.phone, windowSize: size, mouseActive: false),
      child: Scaffold(body: child),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));
Finder _chainFinder() => find.byKey(const ValueKey('tree-pinned-chain'));
Finder _pinned(String key) => find.byKey(ValueKey('tree-pinned:$key'));
ScrollController _scroll(WidgetTester tester) => tester.widget<ListView>(find.byKey(const ValueKey('assembly-tree-list'))).controller!;
/// Where a row's label starts: its indent shows in it.
double _labelX(WidgetTester tester, String key, String label) =>
    tester.getTopLeft(find.descendant(of: _row(key), matching: find.text(label))).dx;

/// The keys of the pinned rows, outermost first.
List<String> _pinnedKeys(WidgetTester tester) => [
      for (final e in find.descendant(of: _chainFinder(), matching: find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('tree-pinned:'))).evaluate())
        ((e.widget.key as ValueKey<String>).value).substring('tree-pinned:'.length)
    ];

void main() {
  group('AssemblyTreePinIndex', () {
    // 0 a            level 0
    // 1   b          level 1
    // 2     c0..c4   level 2 (rows 2-6)
    // 7   d          level 1
    // 8 e            level 0
    final depths = [0, 1, 2, 2, 2, 2, 2, 1, 0];

    test('levels, parents and where a subtree ends', () {
      final pin = AssemblyTreePinIndex(depths);
      expect([for (var i = 0; i < depths.length; i++) pin.levelOf(i)], [0, 1, 2, 2, 2, 2, 2, 1, 0]);
      expect([for (var i = 0; i < depths.length; i++) pin.parentOf(i)], [-1, 0, 1, 1, 1, 1, 1, 0, -1]);
      expect(pin.endOf(0), 8);
      expect(pin.endOf(1), 7);
      expect(pin.endOf(8), 9);
      expect(pin.hasChildren(0), isTrue);
      expect(pin.hasChildren(2), isFalse);
    });

    test('nothing is pinned at the top; ancestors pin as their rows scroll off and leave when the branch is past', () {
      const h = 48.0;
      final pin = AssemblyTreePinIndex(depths);
      expect(pin.pinnedAt(0, h), isEmpty, reason: 'every row is where it belongs');
      // A row that has scrolled up to its slot sticks there: a at 0, and b (which would have been at 48) at 48, as the rows slide under them.
      expect(pin.pinnedAt(10, h), [0, 1]);
      expect(pin.pinnedAt(3 * h, h), [0, 1], reason: 'rows 0 to 2 are above, the children of b are under them');
      expect(pin.pinnedAt(4.5 * h, h), [0, 1]);
      // Once b's last child (row 6) is under the chain b has nothing left below it and goes; a stays for d.
      expect(pin.pinnedAt(5.5 * h, h), [0]);
      expect(pin.pinnedAt(6.5 * h, h), [0]);
      // d and e are leaves: they never pin, and a goes when d is the last row of its branch.
      expect(pin.pinnedAt(7 * h, h), isEmpty);
      expect(pin.pinnedAt(8 * h, h), isEmpty);
    });

    test('the deepest ancestors are kept when the chain is longer than the room', () {
      const h = 48.0;
      // A branch 7 deep: rows 0..6 each the parent of the next, then 10 leaves at level 7.
      final pin = AssemblyTreePinIndex([for (var i = 0; i < 7; i++) i, for (var i = 0; i < 10; i++) 7]);
      expect(pin.pinnedAt(8 * h, h), [0, 1, 2, 3, 4, 5, 6]);
      expect(pin.pinnedAt(8 * h, h, maxPinned: 3), [4, 5, 6]);
    });

    test('an empty list and a list of leaves pin nothing', () {
      expect(AssemblyTreePinIndex(const []).pinnedAt(100, 48), isEmpty);
      expect(AssemblyTreePinIndex(const [0, 0, 0]).pinnedAt(60, 48), isEmpty);
    });
  });

  testWidgets('indent: a row 7 deep has the indent of the 4th level (12 dp a level, then it stops)', (tester) async {
    final model = _modelOf([_chain(7)]);
    model.openAll(['n1', 'n1/n2', 'n1/n2/n3', 'n1/n2/n3/n4', 'n1/n2/n3/n4/n5', 'n1/n2/n3/n4/n5/n6']);
    await _pump(tester, _Host(model: model));
    const keys = ['n1', 'n1/n2', 'n1/n2/n3', 'n1/n2/n3/n4', 'n1/n2/n3/n4/n5', 'n1/n2/n3/n4/n5/n6', 'n1/n2/n3/n4/n5/n6/n7'];
    final x = [for (var i = 0; i < keys.length; i++) _labelX(tester, keys[i], 'Item n${i + 1}')];
    // Below the title the first level is not indented; each of the next four is 12 dp further in.
    for (var i = 1; i <= 4; i++) {
      expect(x[i] - x[i - 1], 12, reason: 'level $i');
    }
    expect(x[5], x[4], reason: 'the fifth level stops moving right');
    expect(x[6], x[4], reason: 'a row 7 deep stands where level 4 does');
  });

  testWidgets('scrolling a long branch pins its ancestors, and a tap on one collapses back to it', (tester) async {
    final model = _modelOf([
      _chain(2, leaves: 40),
      for (var i = 0; i < 5; i++) _node('t$i', ['t$i']),
    ]);
    model.openAll(['n1', 'n1/n2']);
    await _pump(tester, _Host(model: model));
    expect(_chainFinder(), findsNothing, reason: 'at the top every ancestor is on screen');

    _scroll(tester).jumpTo(10 * 48);
    await tester.pump();
    expect(_pinnedKeys(tester), ['n1', 'n1/n2'], reason: 'the chain says where you are');
    final listTop = tester.getTopLeft(find.byKey(const ValueKey('assembly-tree-list'))).dy;
    expect(tester.getTopLeft(_pinned('n1')).dy, listTop);
    expect(tester.getTopLeft(_pinned('n1/n2')).dy, listTop + 48);
    // Scrolling on keeps them while the branch lasts.
    _scroll(tester).jumpTo(30 * 48);
    await tester.pump();
    expect(_pinnedKeys(tester), ['n1', 'n1/n2']);

    // A tap on the outer one: it closes and the list goes to it.
    await tester.tap(_pinned('n1'));
    await tester.pumpAndSettle();
    expect(model.isOpen('n1'), isFalse);
    expect(_chainFinder(), findsNothing, reason: 'nothing of the branch is listed any more');
    expect(_row('n1'), findsOneWidget);
    expect(tester.getTopLeft(_row('n1')).dy, listTop, reason: 'at the top: its own place');
    expect(model.isOpen('n1/n2'), isTrue, reason: 'what was open inside stays open, as a chevron close leaves it');
  });

  testWidgets('a tap on a pinned inner ancestor puts it just under the ones above it; a selection it hid moves to it', (tester) async {
    final model = _modelOf([_chain(2, leaves: 40)]);
    model.openAll(['n1', 'n1/n2']);
    await _pump(tester, _Host(model: model));
    model.selectedKey = 'n1/n2/n2_30';
    _scroll(tester).jumpTo(25 * 48);
    await tester.pump();
    expect(_pinnedKeys(tester), ['n1', 'n1/n2']);
    final taps = (tester.state(find.byType(_Host)) as _HostState).taps;
    await tester.tap(_pinned('n1/n2'));
    await tester.pumpAndSettle();
    expect(model.isOpen('n1/n2'), isFalse);
    expect(model.selectedKey, 'n1/n2', reason: 'the selected leaf was hidden by the collapse');
    expect(taps, ['n1/n2'], reason: 'the host hears it');
    final listTop = tester.getTopLeft(find.byKey(const ValueKey('assembly-tree-list'))).dy;
    // n1 is the row above: the list is as it was at the top, n1/n2 right under n1 (no chain is needed for a short list).
    expect(tester.getTopLeft(_row('n1/n2')).dy, listTop + 48);
  });

  testWidgets('a tap on a pinned row does not collapse while a filter is on', (tester) async {
    final model = _modelOf([_chain(2, leaves: 40)]);
    model.openAll(['n1', 'n1/n2']);
    await _pump(tester, _Host(model: model));
    await tester.tap(find.byKey(const ValueKey('tree-filter-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'Item n2_');
    await tester.pumpAndSettle();
    _scroll(tester).jumpTo(20 * 48);
    await tester.pump();
    expect(_pinnedKeys(tester), contains('n1'));
    await tester.tap(_pinned('n1'));
    await tester.pumpAndSettle();
    expect(model.isOpen('n1'), isTrue, reason: 'what is open is not changed from a list of matches');
  });

  testWidgets('reveal scrolls to the right row with pinned headers in the way: it ends under the chain, not behind it', (tester) async {
    final model = _modelOf([
      _chain(3, leaves: 60, prefix: const []),
      for (var i = 0; i < 4; i++) _node('t$i', ['t$i']),
    ]);
    model.openAll(['n1', 'n1/n2']);
    final controller = AssemblyTreeController();
    await _pump(tester, _Host(model: model, controller: controller));
    // A row of the deepest branch, far down: opening n1/n2/n3 lists its leaves.
    model.openAll(['n1/n2/n3']);
    controller.refresh();
    await tester.pump();
    controller.reveal(['n1', 'n2', 'n3', 'n3_45'], select: true);
    await tester.pumpAndSettle();
    expect(_pinnedKeys(tester), ['n1', 'n1/n2', 'n1/n2/n3']);
    final target = tester.getRect(_row('n1/n2/n3/n3_45'));
    final chain = tester.getRect(_chainFinder());
    expect(target.top, greaterThanOrEqualTo(chain.bottom - 0.5), reason: 'the row is below the pinned chain');
    expect(target.bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('assembly-tree-list'))).bottom + 0.5));

    // Another row, higher up, goes the other way: the list scrolls back to it.
    controller.reveal(['n1', 'n2', 'n3', 'n3_3'], select: true);
    await tester.pumpAndSettle();
    final up = tester.getRect(_row('n1/n2/n3/n3_3'));
    expect(up.top, greaterThanOrEqualTo(tester.getRect(_chainFinder()).bottom - 0.5));
  });

  testWidgets('under Focus the rows outside the focused branch are not shown: the chain to it and the focused branch are', (tester) async {
    final model = _modelOf([
      _node('x', ['x'], leaves: 6),
      _node('y', ['y'], children: [
        _node('z', ['y', 'z'], leaves: 4),
        _node('w', ['y', 'w']),
      ]),
      _node('u', ['u']),
    ]);
    model.openAll(['x', 'y', 'y/z']);
    model.focusPath = const ['y', 'z'];
    await _pump(tester, _Host(model: model));
    expect(_row('y'), findsOneWidget, reason: 'the way down to the focus');
    expect(_row('y/z'), findsOneWidget, reason: 'the focused row');
    expect(_row('y/z/z_0'), findsOneWidget, reason: 'inside it');
    for (final gone in ['x', 'x/x_0', 'y/w', 'u']) {
      expect(_row(gone), findsNothing, reason: '$gone is outside the focus');
    }
    expect(find.byKey(const ValueKey('tree-dimmed:x')), findsNothing, reason: 'not dimmed: absent');
    // No focus: they all come back (the side panel and tablets dim them; this is the portrait sheet's rule only).
    model.focusPath = const [];
    await _pump(tester, _Host(model: model, key: const ValueKey('again')));
    await tester.pumpAndSettle();
    expect(_row('x'), findsOneWidget);
    expect(_row('u'), findsOneWidget);
  });

  testWidgets('under Focus the chain to the focused row stays pinned while its branch scrolls', (tester) async {
    final model = _modelOf([
      _node('x', ['x'], leaves: 6),
      _chain(3, leaves: 40),
    ]);
    model.openAll(['x', 'n1', 'n1/n2', 'n1/n2/n3']);
    model.focusPath = const ['n1', 'n2', 'n3'];
    await _pump(tester, _Host(model: model));
    expect(_row('x'), findsNothing);
    _scroll(tester).jumpTo(12 * 48);
    await tester.pump();
    expect(_pinnedKeys(tester), ['n1', 'n1/n2', 'n1/n2/n3']);
    // The way to the focus is not collapsed by a tap (that would hide the focused branch): the row is selected as any tap does.
    await tester.tap(_pinned('n1'));
    await tester.pumpAndSettle();
    expect(model.isOpen('n1'), isTrue);
    expect(model.selectedKey, 'n1');
  });

  testWidgets('a selected row outside the focus is not listed, but keeps its bar and "Focus here"', (tester) async {
    final model = _modelOf([
      _node('x', ['x'], leaves: 2),
      _node('y', ['y'], leaves: 2),
    ]);
    model.openAll(['x', 'y']);
    model.focusPath = const ['y'];
    model.selectedKey = 'x';
    await _pump(tester, _Host(model: model));
    expect(_row('x'), findsNothing);
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-focus-here')), findsOneWidget);
    // At peek too (B4 left it out): the selected row, the offer and the bar.
    await _pump(tester, _Host(model: model, key: const ValueKey('peek'), initial: AssemblyTreeSheetHeight.peek));
    expect(find.byKey(const ValueKey('tree-sheet-peek')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-focus-here')), findsOneWidget);
    expect(_row('x'), findsOneWidget, reason: 'the selected row, as at peek always');
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);
  });

  // B4's carried item 2: the root's name is said once.
  testWidgets('the title keeps its own words while a strip names the root, and is the root at peek where no strip is drawn', (tester) async {
    final model = _modelOf([_node('a', ['a'], leaves: 2)]);
    Widget view(AssemblyTreeSheetHeight h, {bool strip = true}) => _Host(model: model, initial: h);
    await _pump(
      tester,
      AssemblyTreeView(
        model: model,
        sheetHeight: AssemblyTreeSheetHeight.half,
        onSheetHeightChanged: (_) {},
        focusCrumbs: const ['Rover', 'Mast'],
        onFocusCrumb: (_) {},
      ),
    );
    expect(find.byKey(const ValueKey('focus-strip')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('tree-title'))).data, 'Assembly', reason: 'the strip says Rover');
    await _pump(
      tester,
      AssemblyTreeView(
        model: model,
        sheetHeight: AssemblyTreeSheetHeight.half,
        onSheetHeightChanged: (_) {},
        editAlone: const AssemblyEditAloneInfo(label: 'Rover'),
        onEditAloneDone: () {},
      ),
    );
    expect(tester.widget<Text>(find.byKey(const ValueKey('tree-title'))).data, 'Assembly');
    await _pump(
      tester,
      AssemblyTreeView(
        model: model,
        sheetHeight: AssemblyTreeSheetHeight.peek,
        onSheetHeightChanged: (_) {},
        focusCrumbs: const ['Rover', 'Mast'],
        onFocusCrumb: (_) {},
      ),
    );
    expect(find.byKey(const ValueKey('focus-strip')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('tree-title'))).data, 'Rover', reason: 'no strip at peek: the title is the root');
    // And with no strip at all the title is the root, as in B4.
    await _pump(tester, view(AssemblyTreeSheetHeight.half, strip: false));
    expect(tester.widget<Text>(find.byKey(const ValueKey('tree-title'))).data, 'Rover');
  });

  // B4's carried item 1: a drag that begins at peek with a strip on made the column taller than the sheet.
  testWidgets('a drag from peek with Edit Alone\'s strip on does not overflow the sheet', (tester) async {
    final model = _modelOf([_node('a', ['a'], leaves: 3)])..selectedKey = 'a';
    await _pump(
      tester,
      _SheetWithStrip(model: model),
    );
    final handle = find.byKey(const ValueKey('tree-sheet-handle'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(0, -6));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'after ${(i + 1) * 6} dp');
    }
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(EditAloneStrip), findsOneWidget, reason: 'the strips show once there is room');
    await gesture.up();
    await tester.pumpAndSettle();
  });
}

class _SheetWithStrip extends StatefulWidget {
  const _SheetWithStrip({required this.model});
  final AssemblyTreeModel model;
  @override
  State<_SheetWithStrip> createState() => _SheetWithStripState();
}

class _SheetWithStripState extends State<_SheetWithStrip> {
  AssemblyTreeSheetHeight height = AssemblyTreeSheetHeight.peek;
  @override
  Widget build(BuildContext context) => AssemblyTreeView(
        model: widget.model,
        sheetHeight: height,
        onSheetHeightChanged: (h) => setState(() => height = h),
        editAlone: AssemblyEditAloneInfo(label: 'Rover', inLabels: const ['Fleet', 'Site A', 'Hangar 2'], usedCount: 3),
        onEditAloneDone: () {},
        focusCrumbs: const ['Rover', 'Mast', 'Arm'],
        onFocusCrumb: (_) {},
        statusLine: 'Solved in 0.2 s',
        onHideSelected: (_) {},
        onMoreSelected: (_) {},
        onClose: () {},
      );
}
