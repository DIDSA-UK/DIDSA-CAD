import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_helpers.dart';
import 'package:didsa_cad_client/viewport3d/sketch_feature_tree.dart';

// P3 of docs/assembly-tree-overhaul-scope.md: the sketcher's tree is the one tree, read-mostly. Replaces what the old panel's locked mode
// was tested for (`feature_tree_panel_test.dart` "locked (inside the sketcher)", the tree group of `sketch_convert_picks_test.dart`).

AssemblyTreeResponseDto _partAlone() => AssemblyTreeResponseDto.fromJson({
      'part_id': 'root',
      'part_name': 'Bracket',
      'kind': 'part',
      'feature_count': 4,
      'status_included': true,
      'children': <Map<String, dynamic>>[],
    });

/// A part on its own, as the sketcher seeds it for a focused Part.
AssemblyTreeResponseDto _seed(String partId) => AssemblyTreeResponseDto.fromJson({
      'part_id': partId,
      'part_name': 'Plate',
      'kind': 'part',
      'feature_count': 4,
      'status_included': true,
      'children': <Map<String, dynamic>>[],
    });

Map<String, dynamic> _node(String id, List<String> path,
        {String kind = 'part', List<Map<String, dynamic>> children = const [], int featureCount = 0}) =>
    {
      'occurrence_id': id,
      'path': path,
      'resolved_part_id': 'part-$id',
      'part_name': 'Item $id',
      'kind': kind,
      'hidden': false,
      'feature_count': featureCount,
      'children': children,
    };

/// The edited part three levels down: root > a > b > c.
AssemblyTreeResponseDto _assembly() => AssemblyTreeResponseDto.fromJson({
      'part_id': 'root',
      'part_name': 'Machine',
      'kind': 'assembly',
      'feature_count': 0,
      'status_included': true,
      'mates': {'count': 1},
      'children': [
        _node('a', ['a'], kind: 'assembly', children: [
          _node('b', ['a', 'b'], kind: 'assembly', children: [
            _node('c', ['a', 'b', 'c']),
          ]),
        ]),
        _node('z', ['z'], featureCount: 1),
      ],
    });

/// Sketch 1 (earlier), Sketch 2 (being edited), Sketch 3 (later), an Extrude and its body.
AssemblyLivePart _live({String key = '', bool extrudeHidden = false}) => AssemblyLivePart(
      key,
      features: [
        const AssemblyLiveFeature(id: 'early', label: 'Sketch 1', type: 'sketch'),
        const AssemblyLiveFeature(id: 'current', label: 'Sketch 2', type: 'sketch'),
        const AssemblyLiveFeature(id: 'later', label: 'Sketch 3', type: 'sketch'),
        AssemblyLiveFeature(id: 'ext', label: 'Extrude 1', type: 'extrude', hidden: extrudeHidden),
      ],
      bodies: const [AssemblyLiveItem('ext', 'Body 1')],
    );

Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));

Widget _host(Widget child, {bool desktop = false, TreeConvertPick? convert}) => MaterialApp(
      home: LayoutModeScope(
        controller: LayoutModeController(
          preference: desktop ? LayoutPreference.desktop : LayoutPreference.phone,
          windowSize: const Size(1200, 800),
          mouseActive: desktop,
        ),
        child: Scaffold(body: TreeConvertPickScope(pick: convert, child: child)),
      ),
    );

SketchFeatureTree _tree({
  AssemblyTreeResponseDto? tree,
  AssemblyLivePart? live,
  Iterable<String> openKeys = const [],
  List<String>? toggled,
  bool docked = false,
  VoidCallback? onClose,
}) =>
    SketchFeatureTree(
      tree: tree ?? _partAlone(),
      livePart: live ?? _live(),
      openKeys: openKeys,
      sketchFeatureId: 'current',
      docked: docked,
      onClose: onClose ?? () {},
      onToggleVisibility: toggled == null ? null : (row) => toggled.add(row.key),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('the sketch being edited is selected; every row is locked and a tap says why', (tester) async {
    await tester.pumpWidget(_host(_tree(toggled: [])));
    await tester.pump();
    expect(find.byType(AssemblyTreeView), findsOneWidget);
    final view = tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView));
    expect(view.model.selectedKey, '#feature:current');
    expect(view.model.picker?.otherReason, 'Exit the sketch first');
    for (final key in ['#feature:early', '#feature:ext', '#feature:current']) {
      expect(view.model.visibleRows().firstWhere((r) => r.key == key).pick, AssemblyPickState.locked, reason: key);
    }
    // No bar (it is a lock); a tap on a row says why and selects nothing else.
    expect(find.byKey(const ValueKey('tree-picker-banner')), findsNothing);
    await tester.tap(find.text('Extrude 1'));
    await tester.pump();
    expect(find.text('Exit the sketch first'), findsOneWidget);
    expect(view.model.selectedKey, '#feature:current');
  });

  testWidgets('a mouse hover on a locked row shows the reason', (tester) async {
    await tester.pumpWidget(_host(_tree(), desktop: true));
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Extrude 1')));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Exit the sketch first'), findsOneWidget);
  });

  for (final desktop in [false, true]) {
    testWidgets('${desktop ? 'desktop' : 'phone'}: every live row has an eye that hides or shows it, except the sketch being edited',
        (tester) async {
      final toggled = <String>[];
      await tester.pumpWidget(_host(_tree(toggled: toggled, openKeys: ['#bodies', '#planes']), desktop: desktop));
      await tester.pump();
      // No hover needed, on either platform: a lock has no bar.
      for (final key in ['#feature:early', '#feature:later', '#feature:ext', '#body:ext', '#plane:xy']) {
        expect(find.byKey(ValueKey('tree-eye:$key')), findsOneWidget, reason: key);
      }
      expect(find.byKey(const ValueKey('tree-eye:#feature:current')), findsNothing);
      expect(find.byKey(const ValueKey('tree-eye:#bodies')), findsNothing, reason: 'a folder has none');
      await tester.tap(find.byKey(const ValueKey('tree-eye:#feature:ext')));
      await tester.tap(find.byKey(const ValueKey('tree-eye:#body:ext')));
      await tester.tap(find.byKey(const ValueKey('tree-eye:#plane:xy')));
      expect(toggled, ['#feature:ext', '#body:ext', '#plane:xy']);
    });
  }

  testWidgets('a hidden row shows the eye-off, which shows it again; new inputs reach the open tree', (tester) async {
    final toggled = <String>[];
    var hidden = false;
    late StateSetter rebuild;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return _tree(toggled: toggled, live: _live(extrudeHidden: hidden));
    })));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-eye:#feature:ext')), findsOneWidget);
    rebuild(() => hidden = true);
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-eye-off:#feature:ext')), findsOneWidget);
    expect(find.byTooltip('Show'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tree-eye-off:#feature:ext')));
    expect(toggled, ['#feature:ext']);
  });

  group('Convert Entities', () {
    TreeConvertPick convert(List<String> staged, {Set<String> picked = const {}}) => TreeConvertPick(
          pickable: const {'early'},
          picked: picked,
          later: const {'later'},
          laterReason: SketchController.convertSourceAfterSketchMessage,
          onPick: staged.add,
        );

    testWidgets('an earlier sketch is pickable and ticks when staged; a later one is locked with its own reason', (tester) async {
      final staged = <String>[];
      await tester.pumpWidget(_host(_tree(), convert: convert(staged)));
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-picker-banner')), findsOneWidget);
      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      expect(staged, ['early']);

      await tester.tap(find.text('Sketch 3'));
      await tester.pump();
      expect(find.text(SketchController.convertSourceAfterSketchMessage), findsOneWidget);
      await tester.tap(find.text('Sketch 2'));
      await tester.tap(find.text('Extrude 1'));
      await tester.pump();
      expect(find.text('Exit the sketch first'), findsOneWidget);
      expect(staged, ['early'], reason: 'a later sketch, the one being edited and an extrude are refused');

      // Staged, it is ticked (and a tap takes it back, through the same pick).
      await tester.pumpWidget(_host(_tree(), convert: convert(staged, picked: {'early'})));
      await tester.pump();
      expect(find.byKey(const ValueKey('tree-picked:#feature:early')), findsOneWidget);
      await tester.tap(find.text('Sketch 1'));
      expect(staged, ['early', 'early']);
    });

    testWidgets('in the sketcher: an earlier sketch stages, ticks and un-stages; leaving Convert locks it again', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = MockClient((request) async {
        if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
          return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
        }
        return http.Response('not found', 404);
      });
      final controller = SketchController(api: SketchApiClient(httpClient: client));
      await controller.ensureSketch();
      final source = SketchReferenceSource(earlierSketchFeatureIds: {'early'}, laterSketchFeatureIds: {'later'});
      addTearDown(source.dispose);
      await tester.pumpWidget(MaterialApp(
        home: SketchScreen(
          controller: controller,
          referenceSource: source,
          featureTreeBuilder: (context, onClose) => _tree(onClose: onClose),
        ),
      ));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Outside Convert mode the earlier sketch is locked too.
      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      expect(controller.pendingConvertSketches, isEmpty);

      controller.enterConvertEntitiesMode();
      await tester.pump();
      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      expect(controller.pendingConvertSketches, ['early']);
      expect(find.byKey(const ValueKey('tree-picked:#feature:early')), findsOneWidget);
      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      expect(controller.pendingConvertSketches, isEmpty);
      expect(find.byKey(const ValueKey('tree-picked:#feature:early')), findsNothing);

      await tester.tap(find.text('Sketch 3'));
      await tester.pump();
      expect(controller.pendingConvertSketches, isEmpty);

      controller.exitToSelectMode();
      await tester.pump();
      await tester.tap(find.text('Sketch 1'));
      await tester.pump();
      expect(controller.pendingConvertSketches, isEmpty);
      expect(find.text('Exit the sketch first'), findsOneWidget);

      // Its own close puts it away.
      await tester.tap(find.descendant(of: find.byType(SketchFeatureTree), matching: find.byTooltip('Close')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(SketchFeatureTree), findsNothing);
    });
  });

  testWidgets('in an assembly the whole tree is listed, opened down to the live part three levels down, with the sketch selected', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_tree(tree: _assembly(), live: _live(key: 'a/b/c')), desktop: true));
    await tester.pump();
    await tester.pump();
    for (final key in ['a', 'a/b', 'a/b/c', 'z', 'a/b/c#feature:current']) {
      expect(_row(key), findsOneWidget, reason: key);
    }
    final view = tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView));
    expect(view.model.selectedKey, 'a/b/c#feature:current');
    // The other parts' rows are not the live part's: no eye.
    expect(find.byKey(const ValueKey('tree-eye:z')), findsNothing);
  });

  testWidgets("what the Part screen fetched reads the same here: another part's features, the Mates rows, a row hidden for this session",
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final main = AssemblyTreeModel(tree: _assembly())
      ..setFeatures(const ['z'], const [AssemblyFeature('zf', 'Sketch 9')])
      ..setFolderItems('#mates', const [AssemblyFolderItem.spec(id: 'm1', label: 'Coincident 1')])
      ..setSessionHiddenKeys({'z'});
    await tester.pumpWidget(_host(SketchFeatureTree(
      tree: _assembly(),
      livePart: _live(key: 'a/b/c'),
      openKeys: const ['z', '#mates'],
      fetchedFrom: main,
      sketchFeatureId: 'current',
      onClose: () {},
    ), desktop: true));
    await tester.pump();
    expect(_row('z#feature:zf'), findsOneWidget);
    expect(_row('#mates#item:m1'), findsOneWidget);
    final view = tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView));
    expect(view.model.visibleRows().firstWhere((r) => r.key == 'z').hidden, isTrue);
  });

  testWidgets("a seed rooted at the focused Part takes nothing from the Part screen's tree when that tree has another root", (tester) async {
    // The Part screen's tree is the document's (root 'root'): its root row has features, a session-hidden row and open rows.
    final main = AssemblyTreeModel(tree: _assembly())
      ..setFeatures(const [], const [AssemblyFeature('root-f', 'Root Sketch')])
      ..setSessionHiddenKeys({''})
      ..openAll(const ['z']);
    final seed = AssemblyTreeResponseDto.fromJson({
      'part_id': 'plate-part',
      'part_name': 'Plate',
      'kind': 'part',
      'feature_count': 1,
      'status_included': true,
      'children': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(_host(SketchFeatureTree(
      tree: seed,
      livePart: null, // the plate's own features are on their way
      openKeys: main.openKeys,
      fetchedFrom: main,
      sketchFeatureId: 'current',
      onClose: () {},
    )));
    await tester.pump();
    final model = tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView)).model;
    expect(find.text('Root Sketch'), findsNothing, reason: "the document root's features are not the plate's");
    expect(model.visibleRows().any((r) => r.key.contains('root-f')), isFalse);
    expect(model.visibleRows().firstWhere((r) => r.key == '').hidden, isFalse, reason: "the root's session-hidden mark is not the plate's");
    expect(model.openKeys, isEmpty, reason: "the document tree's open rows are not the seed's");

    // The same model rooted where the seed is: copied as before.
    final plateMain = AssemblyTreeModel(tree: seed)..setFeatures(const [], const [AssemblyFeature('pf', 'Plate Sketch')]);
    await tester.pumpWidget(_host(SketchFeatureTree(
      key: const ValueKey('again'),
      tree: seed,
      livePart: null,
      fetchedFrom: plateMain,
      sketchFeatureId: 'current',
      onClose: () {},
    )));
    await tester.pump();
    expect(find.text('Plate Sketch'), findsOneWidget);
  });

  testWidgets('when the Part screen\'s tree changes root (the part alone, then the document), the way to the sketch is opened again',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var assembly = false;
    late StateSetter rebuild;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return _tree(tree: assembly ? _assembly() : _partAlone(), live: _live(key: assembly ? 'a/b/c' : ''));
    }), desktop: true));
    await tester.pump();
    expect(_row('#feature:current'), findsOneWidget);
    rebuild(() => assembly = true);
    await tester.pump();
    await tester.pump();
    expect(_row('a/b/c#feature:current'), findsOneWidget, reason: 'a, a/b and a/b/c opened down to the sketch');
    expect(tester.widget<AssemblyTreeView>(find.byType(AssemblyTreeView)).model.selectedKey, 'a/b/c#feature:current');
  });

  // B4 (P3's review): the rows opened in the sketcher were lost when its tree changed root.
  testWidgets("the rows opened in the sketcher's tree are carried to the live part's new place when the tree changes root", (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var assembly = false;
    late StateSetter rebuild;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      // The seed is the focused Part on its own (part-c), then the document's tree with that Part three levels down.
      return _tree(tree: assembly ? _assembly() : _seed('part-c'), live: _live(key: assembly ? 'a/b/c' : ''));
    }), desktop: true));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tree-chevron:#bodies')));
    await tester.pump();
    expect(_row('#body:ext'), findsOneWidget);
    rebuild(() => assembly = true);
    await tester.pump();
    await tester.pump();
    expect(_row('a/b/c#body:ext'), findsOneWidget, reason: 'the Bodies folder opened on the seed is open under the live row');
  });

  // B4 (P3's review): a seed whose source had another root never got the source's open rows, even once the source had the seed's root.
  testWidgets("the Part screen's open rows apply once its tree gets the seed's root", (tester) async {
    final seed = _seed('plate-part');
    var main = AssemblyTreeModel(tree: _assembly())..openAll(const ['z']);
    late StateSetter rebuild;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return SketchFeatureTree(
        tree: seed,
        livePart: _live(),
        openKeys: main.openKeys,
        fetchedFrom: main,
        sketchFeatureId: 'current',
        onClose: () {},
      );
    })));
    await tester.pump();
    expect(_row('#body:ext'), findsNothing);
    // The Part screen's tree is now the part's own, with its Bodies folder open.
    rebuild(() => main = AssemblyTreeModel(tree: seed)..openAll(const ['#bodies']));
    await tester.pump();
    expect(_row('#body:ext'), findsOneWidget);
  });

  // B5 (B4's review, item 3): the same, when the tree object changed with the root's arrival (a new tree of the same root: the merge branch).
  testWidgets("the Part screen's open rows apply once its tree gets the seed's root, also when the seed's tree was replaced with it", (tester) async {
    var seed = _seed('plate-part');
    var main = AssemblyTreeModel(tree: _assembly())..openAll(const ['z']);
    late StateSetter rebuild;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return SketchFeatureTree(
        tree: seed,
        livePart: _live(),
        openKeys: main.openKeys,
        fetchedFrom: main,
        sketchFeatureId: 'current',
        onClose: () {},
      );
    })));
    await tester.pump();
    expect(_row('#body:ext'), findsNothing);
    rebuild(() {
      seed = _seed('plate-part'); // a new object, the same root
      main = AssemblyTreeModel(tree: seed)..openAll(const ['#bodies']);
    });
    await tester.pump();
    expect(_row('#body:ext'), findsOneWidget);
  });

  testWidgets("the sketcher's open rows start as the Part screen's and its changes stay its own", (tester) async {
    final openKeys = <String>['#bodies'];
    await tester.pumpWidget(_host(_tree(openKeys: openKeys)));
    await tester.pump();
    expect(_row('#body:ext'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tree-chevron:#bodies')));
    await tester.pump();
    expect(_row('#body:ext'), findsNothing);
    expect(openKeys, ['#bodies']);
  });

  testWidgets('the floating tree has a resize handle; docked it has none', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(_tree()));
    await tester.pump();
    final before = tester.getSize(find.byType(AssemblyTreeView)).width;
    await tester.drag(find.byKey(const ValueKey('sketch-tree-resize-handle')), const Offset(150, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(AssemblyTreeView)).width, greaterThan(before + 100));

    await tester.pumpWidget(_host(SizedBox(width: 320, child: _tree(docked: true)), desktop: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('sketch-tree-resize-handle')), findsNothing);
  });

  // B3 (P3's review): the sketcher's tree passed no `onFeaturesRequested`, so a component row never opened in the Part screen opened empty.
  group('a component row opened in the sketcher', () {
    Widget treeOver(AssemblyTreeModel main, Future<bool> Function(List<String>) request) => _host(
          SketchFeatureTree(
            tree: _assembly(),
            livePart: _live(key: 'a/b/c'),
            openKeys: const [],
            fetchedFrom: main,
            sketchFeatureId: 'current',
            onFeaturesRequested: request,
            onClose: () {},
          ),
          desktop: true,
        );

    testWidgets("asks the Part screen for the row's features, and shows them once the Part screen's model has them", (tester) async {
      final main = AssemblyTreeModel(tree: _assembly());
      final asked = <List<String>>[];
      late StateSetter rebuild;
      await tester.pumpWidget(StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return treeOver(main, (path) async {
          asked.add(path);
          return true;
        });
      }));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tree-chevron:z')));
      await tester.pump();
      await tester.pump();
      expect(asked, [
        ['z']
      ]);
      expect(_row('z#feature:zf'), findsNothing, reason: 'not read yet');
      // The Part screen reads them into its own model and rebuilds, as `_loadTreeFeatures` does.
      main.setFeatures(const ['z'], const [AssemblyFeature('zf', 'Sketch 9')]);
      rebuild(() {});
      await tester.pump();
      expect(_row('z#feature:zf'), findsOneWidget);
    });

    testWidgets('a request that failed is forgotten: opening the row again asks again', (tester) async {
      final main = AssemblyTreeModel(tree: _assembly());
      final asked = <List<String>>[];
      await tester.pumpWidget(treeOver(main, (path) async {
        asked.add(path);
        return false;
      }));
      await tester.pump();
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const ValueKey('tree-chevron:z')));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('tree-chevron:z'))); // close it
        await tester.pump();
      }
      expect(asked.where((p) => p.join('/') == 'z'), hasLength(2));
    });

    testWidgets('a tree whose source has another root asks for nothing (its paths name other rows)', (tester) async {
      final other = AssemblyTreeModel(
        tree: AssemblyTreeResponseDto.fromJson({
          'part_id': 'elsewhere',
          'part_name': 'Elsewhere',
          'kind': 'assembly',
          'feature_count': 0,
          'status_included': true,
          'children': [_node('z', ['z'], featureCount: 1)],
        }),
      );
      final asked = <List<String>>[];
      await tester.pumpWidget(treeOver(other, (path) async {
        asked.add(path);
        return true;
      }));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('tree-chevron:z')));
      await tester.pump();
      await tester.pump();
      expect(asked, isEmpty);
    });
  });

  // B3 (P3's review): `copyFetchedFrom` took the features, the folder items and the hidden rows, but not the unsaved Parts, so the sketcher's
  // tree showed no unsaved dot where the Part screen's tree did.
  test('copyFetchedFrom copies the unsaved Parts, and drops them again when the other model has none', () {
    final main = AssemblyTreeModel(tree: _assembly(), unsavedPartIds: const {'part-z'});
    final copy = AssemblyTreeModel(tree: _assembly());
    AssemblyRowState stateOf(AssemblyTreeModel m, String key) => m.visibleRows().firstWhere((r) => r.key == key).state;
    expect(stateOf(copy, 'z'), AssemblyRowState.none);
    copy.copyFetchedFrom(main);
    expect(copy.unsavedPartIds, {'part-z'});
    expect(stateOf(copy, 'z'), AssemblyRowState.unsaved);
    main.setUnsavedPartIds(const []);
    copy.copyFetchedFrom(main);
    expect(copy.unsavedPartIds, isEmpty);
    expect(stateOf(copy, 'z'), AssemblyRowState.none);
  });

  testWidgets('an unsaved Part shows its dot in the sketcher\'s tree', (tester) async {
    final main = AssemblyTreeModel(tree: _assembly(), unsavedPartIds: const {'part-z'});
    await tester.pumpWidget(_host(SketchFeatureTree(
      tree: _assembly(),
      livePart: _live(key: 'a/b/c'),
      fetchedFrom: main,
      sketchFeatureId: 'current',
      onClose: () {},
    ), desktop: true));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-state:z:unsaved')), findsOneWidget);
  });
}
