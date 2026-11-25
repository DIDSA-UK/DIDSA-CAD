import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';

// B4 (`docs/assembly-tree-overhaul-scope.md` 10.6): the phone portrait sheet. The view draws it when given a height; the Part screen's own
// wiring (a viewport pick, a tool panel, the drawer) is tested in `part_screen_test.dart` ("Phone portrait sheet (B4)").

Map<String, dynamic> _node(String id, List<String> path, {String kind = 'part', List<Map<String, dynamic>> children = const []}) => {
      'occurrence_id': id,
      'path': path,
      'resolved_part_id': 'part-$id',
      'part_name': 'Item $id',
      'kind': kind,
      'hidden': false,
      'children': children,
    };

AssemblyTreeModel _model() => AssemblyTreeModel(
      tree: AssemblyTreeResponseDto.fromJson({
        'part_id': 'root',
        'part_name': 'Rover',
        'kind': 'assembly',
        'feature_count': 0,
        'status_included': true,
        'children': [
          _node('a', ['a'], kind: 'assembly', children: [_node('b', ['a', 'b'])]),
          for (var i = 0; i < 30; i++) _node('p$i', ['p$i']),
        ],
      }),
    );

/// A phone held upright (390 x 844), the sheet's height kept by the host as the person changes it.
class _SheetHost extends StatefulWidget {
  const _SheetHost({required this.model, this.initial = AssemblyTreeSheetHeight.half});
  final AssemblyTreeModel model;
  final AssemblyTreeSheetHeight initial;
  @override
  State<_SheetHost> createState() => _SheetHostState();
}

class _SheetHostState extends State<_SheetHost> {
  late AssemblyTreeSheetHeight height = widget.initial;
  final List<String> hidden = [];

  void setHeight(AssemblyTreeSheetHeight value) => setState(() => height = value);

  @override
  Widget build(BuildContext context) => AssemblyTreeView(
        model: widget.model,
        sheetHeight: height,
        onSheetHeightChanged: (h) => setState(() => height = h),
        onHideSelected: (row) => hidden.add(row.key),
        onIsolateSelected: (_) {},
        onFocusSelected: (_) {},
        onZoomSelected: (_) {},
        onAloneSelected: (_) {},
        onMoreSelected: (_) {},
        onClose: () {},
      );
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: LayoutModeScope(
      controller: LayoutModeController(preference: LayoutPreference.phone, windowSize: const Size(390, 844), mouseActive: false),
      child: Scaffold(body: child),
    ),
  ));
  await tester.pumpAndSettle();
}

_SheetHostState _host(WidgetTester tester) => tester.state<_SheetHostState>(find.byType(_SheetHost));
double _sheetHeight(WidgetTester tester) => tester.getSize(find.byKey(const ValueKey('tree-sheet'))).height;
Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));

void main() {
  test('a phone held upright is narrower than 600 and taller than wide', () {
    expect(isPhonePortrait(const Size(390, 844)), isTrue);
    expect(isPhonePortrait(const Size(844, 390)), isFalse, reason: 'landscape keeps the side panel');
    expect(isPhonePortrait(const Size(800, 1280)), isFalse, reason: 'a tablet keeps the side panel');
  });

  testWidgets('the sheet spans the width at the bottom; the root row is its title and not a row; rows are 48 dp', (tester) async {
    await _pump(tester, _SheetHost(model: _model()));
    final sheet = tester.getRect(find.byKey(const ValueKey('tree-sheet')));
    expect(sheet.width, 390);
    expect(sheet.bottom, 844);
    expect(tester.widget<Text>(find.byKey(const ValueKey('tree-title'))).data, 'Rover');
    expect(_row(''), findsNothing, reason: 'the root row is the title');
    expect(tester.getSize(_row('a')).height, kAssemblyTreeRowHeightPhone);
    // The root is the title, so its children start where the root row would have (section 5: one level of indent saved), and a child of
    // theirs one level in.
    final chevronA = tester.getTopLeft(find.byKey(const ValueKey('tree-chevron:a'))).dx;
    final side = AssemblyTreeView(model: _model(), onClose: () {});
    await tester.pumpWidget(MaterialApp(
      home: LayoutModeScope(
        controller: LayoutModeController(preference: LayoutPreference.phone, windowSize: const Size(390, 844), mouseActive: false),
        child: Scaffold(body: side),
      ),
    ));
    await tester.pumpAndSettle();
    final sideChevronA = tester.getTopLeft(find.byKey(const ValueKey('tree-chevron:a'))).dx;
    expect(chevronA, sideChevronA - 16, reason: 'one 16 dp level less than the side panel');
    await _pump(tester, _SheetHost(model: _model()));
    // Rows carry no buttons (rule 3): nothing in a healthy row is an IconButton.
    expect(find.descendant(of: _row('a'), matching: find.byType(IconButton)), findsNothing);
  });

  testWidgets('three heights: half, full, peek; a drag on the handle moves between them and a slow release snaps to the nearest',
      (tester) async {
    await _pump(tester, _SheetHost(model: _model()));
    expect(_sheetHeight(tester), closeTo(844 * 0.5, 1));

    // Up most of the way: full.
    await tester.drag(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, -330));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.full);
    expect(_sheetHeight(tester), closeTo(844 - kAssemblyTreeSheetTopGap, 1));

    // All the way down: peek, which is the header alone with nothing selected.
    await tester.drag(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.peek);
    expect(find.byKey(const ValueKey('tree-sheet-peek')), findsOneWidget);
    expect(find.byKey(const ValueKey('assembly-tree-list')), findsNothing);
    expect(_sheetHeight(tester), lessThan(100));

    // A little way up from peek: back to peek (the nearest); a long way: half.
    await tester.drag(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.peek);
    await tester.drag(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, -380));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.half);
  });

  testWidgets('a fling goes one height up or down; a tap on the handle opens peek to half and drops the rest to peek', (tester) async {
    await _pump(tester, _SheetHost(model: _model()));
    await tester.fling(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, -100), 2000);
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.full, reason: 'a short fling up from half');
    await tester.fling(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, 100), 2000);
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.half, reason: 'one height down from full');

    await tester.tap(find.byKey(const ValueKey('tree-sheet-handle')));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.peek);
    await tester.tap(find.byKey(const ValueKey('tree-sheet-handle')));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.half);
  });

  testWidgets('peek is the header and the selected row with its bar; going up lists the rows from the selected one', (tester) async {
    final model = _model();
    await _pump(tester, _SheetHost(model: model));
    // p20 is below the half sheet: selected as a viewport pick selects it (the host sets the model's selection).
    model.selectedKey = 'p20';
    _host(tester).setHeight(AssemblyTreeSheetHeight.peek);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree-sheet-peek')), findsOneWidget);
    expect(_row('p20'), findsOneWidget, reason: 'the selected row');
    expect(_row('a'), findsNothing, reason: 'no other row at peek');
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tree-bar-hide')));
    expect(_host(tester).hidden, ['p20'], reason: "the peek's bar acts on the selected row");

    _host(tester).setHeight(AssemblyTreeSheetHeight.half);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('assembly-tree-list')), findsOneWidget);
    expect(_row('p20'), findsOneWidget, reason: 'the list is scrolled to the selected row');
  });

  testWidgets('the filter sits in the header; opening it takes the sheet to full', (tester) async {
    await _pump(tester, _SheetHost(model: _model(), initial: AssemblyTreeSheetHeight.peek));
    expect(find.byKey(const ValueKey('tree-filter-toggle')), findsOneWidget, reason: 'in the header, at peek too');
    await tester.tap(find.byKey(const ValueKey('tree-filter-toggle')));
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.full);
    expect(find.byKey(const ValueKey('tree-filter-field')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'Item b');
    await tester.pumpAndSettle();
    expect(_row('a/b'), findsOneWidget);
    expect(_row('p3'), findsNothing);
  });

  testWidgets('without the selection bar (phone landscape) a selected row shows no bar', (tester) async {
    final model = _model()..selectedKey = 'a';
    await _pump(tester, AssemblyTreeView(model: model, onHideSelected: (_) {}, onMoreSelected: (_) {}, selectionBar: false));
    expect(_row('a'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsNothing);
    await _pump(tester, AssemblyTreeView(model: model, onHideSelected: (_) {}, onMoreSelected: (_) {}));
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsOneWidget, reason: 'the default keeps the bar');
  });

  // Review of B4, finding 7: the sheet sat under the home indicator / gesture area.
  testWidgets('the sheet keeps its rows above the bottom inset', (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    await _pump(tester, _SheetHost(model: _model(), initial: AssemblyTreeSheetHeight.full));
    expect(tester.getRect(find.byKey(const ValueKey('assembly-tree-list'))).bottom, lessThanOrEqualTo(844 - 34));
  });

  testWidgets('a sheet the host holds (no height callback) offers no filter, and a drag does not move it', (tester) async {
    await _pump(tester, AssemblyTreeView(model: _model(), sheetHeight: AssemblyTreeSheetHeight.peek, onClose: () {}));
    expect(find.byKey(const ValueKey('tree-filter-toggle')), findsNothing);
    final before = _sheetHeight(tester);
    await tester.drag(find.byKey(const ValueKey('tree-sheet-handle')), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_sheetHeight(tester), before);
  });

  // Review of B4's fix round: the drag read the frame's height with the inset in it, so the sheet jumped up by the inset as a drag began.
  testWidgets('with a bottom inset a drag that comes back to where it began leaves the sheet where it was', (tester) async {
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    await _pump(tester, _SheetHost(model: _model()));
    final before = _sheetHeight(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('tree-sheet-handle'))));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    expect(_sheetHeight(tester), closeTo(before, 1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_host(tester).height, AssemblyTreeSheetHeight.half);
  });

  // Review of B4's fix round: a filter open when the host began holding the sheet at peek stayed open with no list and no way to close it.
  testWidgets('a filter open when the host starts holding the sheet is closed', (tester) async {
    var locked = false;
    late StateSetter rebuild;
    final model = _model();
    await _pump(
        tester,
        StatefulBuilder(builder: (context, setState) {
          rebuild = setState;
          return AssemblyTreeView(
            model: model,
            sheetHeight: locked ? AssemblyTreeSheetHeight.peek : AssemblyTreeSheetHeight.full,
            onSheetHeightChanged: locked ? null : (_) {},
          );
        }));
    await tester.tap(find.byKey(const ValueKey('tree-filter-toggle')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), 'Item b');
    await tester.pumpAndSettle();
    rebuild(() => locked = true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tree-filter-field')), findsNothing);
    rebuild(() => locked = false);
    await tester.pumpAndSettle();
    expect(_row('p3'), findsOneWidget, reason: 'the filter is off: every row again');
  });
}
