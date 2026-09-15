import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/component_context_menu.dart';

void main() {
  Future<ComponentContextMenuAction?>? pendingResult;

  Future<void> openMenu(
    WidgetTester tester, {
    required bool isFocused,
    required bool hidden,
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

    testWidgets('Move/Rotate, Mate, and Pattern render disabled with a reason', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      for (final label in ['Move/Rotate', 'Mate', 'Pattern']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse, reason: '$label should be disabled');
      }
      expect(find.textContaining('Coming soon'), findsNWidgets(3));
    });

    testWidgets('Make Focus, Hide, and Isolate render enabled (already real)', (tester) async {
      await openMenu(tester, isFocused: false, hidden: false);
      for (final label in ['Make Focus', 'Hide', 'Isolate']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isTrue, reason: '$label should be enabled');
      }
    });
  });
}
