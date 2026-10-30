import 'package:didsa_cad_client/viewport3d/visibility_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Visibility panel on its own: three-state chips from the data, tap rules, the lock badge, the View row and its fold.
void main() {
  late List<String> taps;
  late bool folded;

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
              viewsFolded: folded,
              onViewsFoldedChanged: (value) => setState(() => folded = value),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    taps = [];
    folded = false;
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

  testWidgets('the close button, the view buttons and the fold chevron work', (tester) async {
    await pumpPanel(tester, [chip('a', VisibilityChipState.shown)]);
    await tester.tap(find.byKey(const ValueKey('vis-close')));
    await tester.tap(find.byKey(const ValueKey('vis-view-top')));
    expect(taps, ['close', 'view top']);

    await tester.tap(find.byKey(const ValueKey('vis-fold-views')));
    await tester.pump();
    expect(folded, isTrue);
    expect(find.byKey(const ValueKey('vis-view-top')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('vis-fold-views')));
    await tester.pump();
    expect(find.byKey(const ValueKey('vis-view-top')), findsOneWidget);
  });

  testWidgets('both rows scroll sideways instead of overflowing a narrow card', (tester) async {
    tester.view.physicalSize = const Size(300, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpPanel(tester, [
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f']) chip(id, VisibilityChipState.shown),
    ]);
    expect(tester.takeException(), isNull);
  });
}
