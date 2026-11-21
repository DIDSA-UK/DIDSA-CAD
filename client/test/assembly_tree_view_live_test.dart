import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_tree_model.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/assembly_tree_view.dart';
import 'package:didsa_cad_client/viewport3d/view_preferences.dart';

// P1: the live part (the build tree) in the one tree widget: docs/assembly-tree/spec.md section 13.

AssemblyTreeResponseDto _tree() => AssemblyTreeResponseDto.fromJson({
      'part_id': 'root',
      'part_name': 'Bracket',
      'kind': 'part',
      'feature_count': 5,
      'status_included': true,
      'children': <Map<String, dynamic>>[],
    });

AssemblyLivePart _live() => AssemblyLivePart(
      '',
      features: const [
        AssemblyLiveFeature(id: 's1', label: 'Sketch 1', type: 'sketch'),
        AssemblyLiveFeature(id: 'e1', label: 'Extrude 1', type: 'extrude', lostReference: 'The sketch was deleted'),
        AssemblyLiveFeature(id: 'p1', label: 'Plane 1', type: 'create_plane'),
        AssemblyLiveFeature(id: 'g1', label: 'Gear 1', type: 'gear', rolledBack: true),
        AssemblyLiveFeature(id: 's2', label: 'Sketch 2', type: 'sketch', hidden: true),
      ],
      bodies: const [AssemblyLiveItem('b1', 'Body 1'), AssemblyLiveItem('b2', 'Tab', hidden: true)],
      curves: const [AssemblyLiveItem('c1', 'Curve 1')],
    );

Widget _host(Widget view, {LayoutPreference layout = LayoutPreference.phone}) => MaterialApp(
      home: LayoutModeScope(
        controller: LayoutModeController(preference: layout, windowSize: const Size(1200, 800), mouseActive: layout == LayoutPreference.desktop),
        child: Scaffold(body: view),
      ),
    );

Finder _row(String key) => find.byKey(ValueKey('tree-row:$key'));
Finder _rows() => find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('tree-row:'));

AssemblyTreeModel _model({bool openFolders = false}) {
  final m = AssemblyTreeModel(tree: _tree())..setLivePart(_live());
  if (openFolders) m.openAll(['#bodies', '#planes']);
  return m;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a part opened alone draws its folders, then its features in build order, with one state slot each', (tester) async {
    final model = _model();
    await tester.pumpWidget(_host(AssemblyTreeView(model: model)));
    final keys = [for (final e in _rows().evaluate()) ((e.widget.key as ValueKey).value as String).substring('tree-row:'.length)];
    expect(keys, ['', '#bodies', '#planes', '#curves', '#feature:s1', '#feature:e1', '#feature:p1', '#feature:g1', '#feature:s2']);
    expect(find.text('Bodies'), findsOneWidget);
    expect(find.text('Surfaces'), findsNothing); // empty folders are not shown
    expect(find.byKey(const ValueKey('tree-state:#feature:e1:lost_reference')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-state:#feature:g1:rolled_back')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-eye-off:#feature:s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-state:#feature:s1:none')), findsNothing);
    // Opening a folder lists its items.
    await tester.tap(find.byKey(const ValueKey('tree-chevron:#planes')));
    await tester.pump();
    expect(_row('#plane:xy'), findsOneWidget);
    expect(_row('#plane:feature:p1'), findsOneWidget);
  });

  testWidgets('a tap selects a feature and does not edit; a double-tap edits', (tester) async {
    final model = _model();
    final calls = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      onRowTap: (r) => calls.add('tap:${r.key}'),
      onRowEdit: (r) => calls.add('edit:${r.key}'),
    )));
    await tester.tap(_row('#feature:s1'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(calls, ['tap:#feature:s1']);
    expect(model.selectedKey, '#feature:s1');
    calls.clear();
    await tester.tap(_row('#feature:s1'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_row('#feature:s1'));
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect(calls, ['edit:#feature:s1']);
  });

  testWidgets('a double-click edits on desktop', (tester) async {
    final model = _model();
    final calls = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true, onRowEdit: (r) => calls.add(r.key)), layout: LayoutPreference.desktop));
    await tester.tap(_row('#feature:e1'), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(_row('#feature:e1'), kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout);
    expect(calls, ['#feature:e1']);
  });

  testWidgets('the feature bar: Edit, Roll back to here, Hide, More; a lost reference shows red with its reason', (tester) async {
    final model = _model();
    final calls = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      onEditSelected: (r) => calls.add('edit:${r.key}'),
      onRollbackSelected: (r) => calls.add('rollback:${r.key}'),
      onHideSelected: (r) => calls.add('hide:${r.key}'),
      onZoomSelected: (r) => calls.add('zoom:${r.key}'),
      onMoreSelected: (r) => calls.add('more:${r.key}'),
    )));
    await tester.tap(_row('#feature:e1'));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-bar-reason')), findsOneWidget);
    expect(find.text('Lost reference: The sketch was deleted'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-bar-zoom')), findsNothing);
    for (final k in ['edit', 'rollback', 'hide', 'more']) {
      await tester.tap(find.byKey(ValueKey('tree-bar-$k')));
    }
    expect(calls, ['edit:#feature:e1', 'rollback:#feature:e1', 'hide:#feature:e1', 'more:#feature:e1']);

    // A hidden feature offers Show.
    await tester.tap(_row('#feature:s2'));
    await tester.pump();
    expect(find.text('Show'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-bar-reason')), findsNothing);
  });

  testWidgets('the body and plane bars; a folder has none', (tester) async {
    final model = _model(openFolders: true);
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      onHideSelected: (_) {},
      onZoomSelected: (_) {},
      onMoreSelected: (_) {},
      onEditSelected: (_) {},
    )));
    await tester.tap(_row('#body:b1'));
    await tester.pump();
    expect([for (final k in ['edit', 'rollback', 'hide', 'zoom', 'more']) find.byKey(ValueKey('tree-bar-$k')).evaluate().length], [0, 0, 1, 1, 1]);
    await tester.tap(_row('#plane:xz'));
    await tester.pump();
    expect([for (final k in ['hide', 'zoom', 'more']) find.byKey(ValueKey('tree-bar-$k')).evaluate().length], [1, 0, 0]);
    await tester.tap(_row('#curves'));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsNothing);
  });

  testWidgets('sketch picker: ineligible rows are locked with their reason in the banner, a pickable row reports its pick', (tester) async {
    final model = _model()..setPicker(AssemblyPicker.sketch(eligibleSketchIds: ['s1']));
    final picked = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      onRowPick: (r) => picked.add(r.key),
      onHideSelected: (_) {},
    )));
    expect(find.text('Select a sketch to extrude'), findsOneWidget);
    await tester.tap(_row('#feature:s2'));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-picker-reason')), findsOneWidget);
    expect(find.text('Pick a sketch with a closed profile'), findsOneWidget);
    expect(picked, isEmpty);
    expect(model.selectedKey, isNull);
    await tester.tap(_row('#feature:s1'));
    await tester.pump();
    expect(picked, ['#feature:s1']);
    expect(find.byKey(const ValueKey('tree-selection-bar')), findsNothing, reason: 'the banner replaces the bar');
    expect(find.byKey(const ValueKey('tree-picker-reason')), findsNothing);
  });

  testWidgets('the source multi-picker ticks rows and counts them in the banner', (tester) async {
    final model = _model()..setPicker(AssemblyPicker.sources(pickableFeatureIds: ['s1', 'e1'], pickedFeatureIds: ['e1']));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onRowPick: (_) {})));
    expect(find.text('Select the source features - 1 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-picked:#feature:e1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-picked:#feature:s1')), findsNothing);
    model.setPicker(AssemblyPicker.sources(pickableFeatureIds: ['s1', 'e1'], pickedFeatureIds: ['e1', 's1']));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onRowPick: (_) {})));
    expect(find.text('Select the source features - 2 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-picked:#feature:s1')), findsOneWidget);
  });

  testWidgets('the sketcher lock says why on a tap, and a convert pick lets earlier sketches through', (tester) async {
    final model = _model()..setPicker(AssemblyPicker.locked('Exit the sketch first'));
    final picked = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onRowPick: (r) => picked.add(r.key))));
    expect(find.byKey(const ValueKey('tree-picker-banner')), findsNothing);
    await tester.tap(_row('#feature:e1'));
    await tester.pump();
    expect(find.text('Exit the sketch first'), findsOneWidget);
    expect(picked, isEmpty);

    model.setPicker(AssemblyPicker.convert(pickableSketchIds: ['s1'], laterSketchIds: ['s2']));
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, onRowPick: (r) => picked.add(r.key))));
    await tester.tap(_row('#feature:s2'));
    await tester.pump();
    expect(find.text('This sketch comes after the one being edited'), findsOneWidget);
    await tester.tap(_row('#feature:s1'));
    await tester.pump();
    expect(picked, ['#feature:s1']);
  });

  testWidgets('long-press multi-select ticks live rows by key, and a plane feature ticks in both places', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final model = _model(openFolders: true);
    final toggled = <String>[];
    await tester.pumpWidget(_host(AssemblyTreeView(
      model: model,
      isMultiSelectMode: true,
      selectedKeys: const {'#feature:p1'},
      onMultiSelectToggle: (r) => toggled.add(r.key),
    )));
    await tester.tap(_row('#feature:s1'));
    await tester.longPress(_row('#body:b1'));
    await tester.tap(_row('#plane:xy')); // a default plane cannot be selected
    await tester.tap(_row('#planes')); // nor a folder
    expect(toggled, ['#feature:s1', '#body:b1']);
    expect(model.selectedKey, isNull);
    // The selection holds the build-order key; the twin in the Planes folder is ticked too.
    expect(find.descendant(of: _row('#plane:feature:p1'), matching: find.byIcon(Icons.check_circle)), findsOneWidget);
    expect(find.descendant(of: _row('#feature:p1'), matching: find.byIcon(Icons.check_circle)), findsOneWidget);
    expect(find.descendant(of: _row('#feature:s1'), matching: find.byIcon(Icons.check_circle)), findsNothing);
  });

  testWidgets('the desktop pin column is off by default, an icon turns it on (and saves it), and a pin reports its row', (tester) async {
    final model = _model();
    final pinned = <String>[];
    await tester.pumpWidget(_host(
      AssemblyTreeView(
        model: model,
        docked: true,
        coarseEligibleFeatureIds: const {'g1'},
        pinnedCoarseFeatureIds: const {},
        onToggleCoarsePin: (r) => pinned.add(r.key),
      ),
      layout: LayoutPreference.desktop,
    ));
    expect(find.byKey(const ValueKey('tree-pin:#feature:g1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tree-pin-column-toggle')));
    await tester.pump();
    expect(ViewPreferences.assemblyTreePinColumn, isTrue);
    expect(find.byKey(const ValueKey('tree-pin:#feature:g1')), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-pin:#feature:s1')), findsNothing); // not eligible
    await tester.tap(find.byKey(const ValueKey('tree-pin:#feature:g1')));
    expect(pinned, ['#feature:g1']);
    await tester.tap(find.byKey(const ValueKey('tree-pin-column-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tree-pin:#feature:g1')), findsNothing);
    await ViewPreferences.setAssemblyTreePinColumn(false);
  });

  testWidgets('a phone has no pin column and no toggle', (tester) async {
    await tester.pumpWidget(_host(AssemblyTreeView(model: _model(), coarseEligibleFeatureIds: const {'g1'}, onToggleCoarsePin: (_) {})));
    expect(find.byKey(const ValueKey('tree-pin-column-toggle')), findsNothing);
    expect(find.byKey(const ValueKey('tree-pin:#feature:g1')), findsNothing);
  });

  testWidgets('the filter finds a lost reference inside a collapsed live part and marks it', (tester) async {
    final model = _model();
    model.closeAll();
    await tester.pumpWidget(_host(AssemblyTreeView(model: model, docked: true), layout: LayoutPreference.desktop));
    await tester.enterText(find.byKey(const ValueKey('tree-filter-field')), ':errors');
    await tester.pump();
    expect(_row('#feature:e1'), findsOneWidget);
    expect(find.byKey(const ValueKey('tree-match:#feature:e1')), findsOneWidget);
    expect(_row('#feature:s1'), findsNothing);
  });
}
