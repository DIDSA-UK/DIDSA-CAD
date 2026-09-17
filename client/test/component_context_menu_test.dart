import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/component_context_menu.dart';

void main() {
  Future<ComponentContextMenuAction?>? pendingResult;

  Future<void> openMenu(
    WidgetTester tester, {
    required bool isFocused,
    required bool hidden,
    bool fixed = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pendingResult = showComponentContextMenu(
                context,
                isFocused: isFocused,
                hidden: hidden,
                fixed: fixed,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showComponentContextMenu', () {
    testWidgets('not focused: shows Make Focus, tapping resolves makeFocus', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      expect(find.text('Make Focus'), findsOneWidget);
      expect(find.text('Exit Focus'), findsNothing);
      await tester.tap(find.text('Make Focus'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.makeFocus);
    });

    testWidgets('focused: shows Exit Focus instead, tapping resolves exitFocus', (tester) async {
      await openMenu(tester, isFocused: true, hidden: false);
      expect(find.text('Exit Focus'), findsOneWidget);
      expect(find.text('Make Focus'), findsNothing);
      await tester.tap(find.text('Exit Focus'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.exitFocus);
    });

    testWidgets('not hidden: shows Hide, tapping resolves hide', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      expect(find.text('Hide'), findsOneWidget);
      expect(find.text('Show'), findsNothing);
      await tester.tap(find.text('Hide'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.hide);
    });

    testWidgets('hidden: shows Show instead, tapping resolves show', (tester) async {
      await openMenu(tester, isFocused: false, hidden: true);
      expect(find.text('Show'), findsOneWidget);
      expect(find.text('Hide'), findsNothing);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.show);
    });

    testWidgets('tapping Isolate resolves isolate', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      await tester.tap(find.text('Isolate'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.isolate);
    });

    // Appendix item 5 fix (`docs/assembly-scope.md`): Move/Rotate used to
    // render disabled here even after Phase 5's gizmo shipped and already
    // worked via plain tap-selection - a discoverability bug, not a missing
    // feature. Grouped with Make Focus/Hide/Isolate now that it's real too.
    // Mate joined this group once Phase 6's own solver/authoring UI landed
    // (§2i), and Pattern once Phase 7's own authoring UI landed (§2j) -
    // there is no remaining disabled entry left in this menu.
    testWidgets('Make Focus, Mate, Pattern, Move/Rotate, Hide, Isolate, and Fix render enabled (already real)', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      for (final label in ['Make Focus', 'Mate', 'Pattern', 'Move/Rotate', 'Hide', 'Isolate', 'Fix']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isTrue, reason: '$label should be enabled');
      }
    });

    // Bug report (assembly testing): "I can't find a method of applying a
    // fix on a part" - long-pressing a part should offer Fix/Float.
    testWidgets('not fixed: shows Fix, tapping resolves fix', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false, fixed: false);
      expect(find.text('Fix'), findsOneWidget);
      expect(find.text('Float'), findsNothing);
      await tester.tap(find.text('Fix'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.fix);
    });

    testWidgets('fixed: shows Float instead, tapping resolves float', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false, fixed: true);
      expect(find.text('Float'), findsOneWidget);
      expect(find.text('Fix'), findsNothing);
      await tester.tap(find.text('Float'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.float);
    });

    testWidgets('fixed: Move/Rotate renders disabled', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false, fixed: true);
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Move/Rotate'), matching: find.byType(ListTile)),
      );
      expect(tile.enabled, isFalse);
    });

    testWidgets('tapping Move/Rotate resolves moveRotate', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      await tester.tap(find.text('Move/Rotate'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.moveRotate);
    });

    testWidgets('tapping Mate resolves mate', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      await tester.tap(find.text('Mate'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.mate);
    });

    testWidgets('tapping Pattern resolves pattern', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      await tester.tap(find.text('Pattern'));
      await tester.pumpAndSettle();
      expect(await pendingResult, ComponentContextMenuAction.pattern);
    });
  });
}
