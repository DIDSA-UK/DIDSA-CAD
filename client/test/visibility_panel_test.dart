import 'package:didsa_cad_client/viewport3d/render_mode.dart';
import 'package:didsa_cad_client/viewport3d/visibility_panel.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Visibility panel on its own: three-state chips from the data, tap rules, the lock badge, the Style row and the View row.
void main() {
  late List<String> taps;
  late ViewportRenderMode mode;

  VisibilityChipData chip(String id, VisibilityChipState state, {bool locked = false, bool enabled = true}) =>
      VisibilityChipData(
        id: id,
        label: id,
        icon: const Icon(Icons.circle),
        state: state,
        locked: locked,
        tooltip: 'tip $id',
        onTap: enabled ? () => taps.add(id) : null,
      );

  Future<void> pumpPanel(WidgetTester tester, List<VisibilityChipData> chips) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => VisibilityPanel(
              chips: chips,
              views: [
                VisibilityViewData(id: 'front', label: 'Front', onTap: () => taps.add('view front')),
                VisibilityViewData(id: 'top', label: 'Top', onTap: () => taps.add('view top')),
              ],
              onClose: () => taps.add('close'),
              renderMode: mode,
              onRenderModeChanged: (value) => setState(() {
                mode = value;
                taps.add('mode ${value.name}');
              }),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    taps = [];
    mode = ViewportRenderMode.shadedWithEdges;
  });

  BoxDecoration boxOf(WidgetTester tester, String id) =>
      tester.widget<Container>(find.byKey(ValueKey('vis-chip-box-$id'))).decoration! as BoxDecoration;

  testWidgets('a chip is filled when all shown, outlined when all hidden and half-filled for a mix', (tester) async {
    await pumpPanel(tester, [
      chip('a', VisibilityChipState.shown),
      chip('b', VisibilityChipState.hidden),
      chip('c', VisibilityChipState.partial),
    ]);
    final shown = boxOf(tester, 'a');
    final hidden = boxOf(tester, 'b');
    final partial = boxOf(tester, 'c');
    expect(shown.color, isNotNull);
    expect(shown.gradient, isNull);
    expect(hidden.color, isNull);
    expect(hidden.gradient, isNull);
    expect(partial.color, isNull);
    expect(partial.gradient, isA<LinearGradient>(), reason: 'half filled');
  });

  testWidgets('a tap on a chip calls its handler; a chip with nothing to hide does nothing', (tester) async {
    await pumpPanel(tester, [
      chip('a', VisibilityChipState.shown),
      chip('b', VisibilityChipState.shown, enabled: false),
    ]);
    await tester.tap(find.byKey(const ValueKey('vis-chip-a')));
    await tester.tap(find.byKey(const ValueKey('vis-chip-b')));
    expect(taps, ['a']);
  });

  testWidgets('a lock badge shows on a chip whose category is being forced visible', (tester) async {
    await pumpPanel(tester, [
      chip('a', VisibilityChipState.hidden, locked: true),
      chip('b', VisibilityChipState.hidden),
    ]);
    expect(find.byKey(const ValueKey('vis-lock-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('vis-lock-b')), findsNothing);
  });

  testWidgets('the close button and the view buttons work, and the View row has no fold chevron', (tester) async {
    await pumpPanel(tester, [chip('a', VisibilityChipState.shown)]);
    await tester.tap(find.byKey(const ValueKey('vis-close')));
    await tester.tap(find.byKey(const ValueKey('vis-view-top')));
    expect(taps, ['close', 'view top']);
    expect(find.byKey(const ValueKey('vis-fold-views')), findsNothing);
    expect(find.byKey(const ValueKey('vis-view-top')), findsOneWidget);
  });

  testWidgets('the Style row sits between Show and View with one button per render mode, the current one selected', (tester) async {
    await pumpPanel(tester, [chip('a', VisibilityChipState.shown)]);
    final show = tester.getTopLeft(find.text('Show')).dy;
    final style = tester.getTopLeft(find.text('Style')).dy;
    final view = tester.getTopLeft(find.text('View')).dy;
    expect(style, greaterThan(show));
    expect(style, lessThan(view));
    // The label column lines up with the other rows' (24 dp leading space kept).
    expect(tester.getTopLeft(find.text('Style')).dx, tester.getTopLeft(find.text('View')).dx);
    for (final m in ViewportRenderMode.values) {
      final button = find.byKey(ValueKey('vis-mode-${m.name}'));
      expect(button, findsOneWidget, reason: m.name);
      expect(find.descendant(of: button, matching: find.text(m.label)), findsOneWidget);
    }
    Color? fill(ViewportRenderMode m) {
      final button = tester.widget<OutlinedButton>(find.byKey(ValueKey('vis-mode-${m.name}')));
      return button.style?.backgroundColor?.resolve(<WidgetState>{});
    }

    expect(fill(ViewportRenderMode.shadedWithEdges), isNotNull, reason: 'the current mode is filled');
    expect(fill(ViewportRenderMode.shaded), isNull);
    expect(fill(ViewportRenderMode.wireframe), isNull);
  });

  testWidgets('tapping a Style button reports that mode, and the panel then shows it selected', (tester) async {
    await pumpPanel(tester, [chip('a', VisibilityChipState.shown)]);
    await tester.tap(find.byKey(const ValueKey('vis-mode-wireframe')));
    await tester.pump();
    expect(taps, ['mode wireframe']);
    final wireframe = tester.widget<OutlinedButton>(find.byKey(const ValueKey('vis-mode-wireframe')));
    expect(wireframe.style?.backgroundColor?.resolve(<WidgetState>{}), isNotNull);
    final edges = tester.widget<OutlinedButton>(find.byKey(const ValueKey('vis-mode-shadedWithEdges')));
    expect(edges.style?.backgroundColor?.resolve(<WidgetState>{}), isNull);
  });

  testWidgets('all three rows scroll sideways instead of overflowing a narrow card', (tester) async {
    tester.view.physicalSize = const Size(300, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPanel(tester, [
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) chip(id, VisibilityChipState.shown),
    ]);
    expect(tester.takeException(), isNull);
  });
}
