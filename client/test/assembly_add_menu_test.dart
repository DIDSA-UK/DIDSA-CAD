import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/add_button_menu.dart';

void main() {
  Future<AssemblyAddMenuAction?>? pendingResult;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pendingResult = showAssemblyAddMenu(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showAssemblyAddMenu', () {
    testWidgets('tapping Add Component resolves insertExistingComponent', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Add Component'));
      await tester.pumpAndSettle();
      expect(await pendingResult, AssemblyAddMenuAction.insertExistingComponent);
    });

    testWidgets('tapping Add Mate resolves addMate', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Add Mate'));
      await tester.pumpAndSettle();
      expect(await pendingResult, AssemblyAddMenuAction.addMate);
    });

    // Phase 6 (`docs/assembly-scope.md` §2i): Add Mate was enabled here -
    // Create Component and Pattern Component are the only remaining
    // placeholders (Phase 7, still design-only).
    testWidgets('Create Component and Pattern Component render disabled', (tester) async {
      await openMenu(tester);
      for (final label in ['Create Component…', 'Pattern Component']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse, reason: '$label should be disabled');
      }
      expect(find.textContaining('Coming soon'), findsNWidgets(2));
    });

    testWidgets('tapping a disabled entry does nothing - the sheet stays open', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Pattern Component'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Pattern Component'), findsOneWidget);
    });

    testWidgets('Add Component and Add Mate are the only enabled entries', (tester) async {
      await openMenu(tester);
      for (final label in ['Add Component', 'Add Mate']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isTrue, reason: '$label should be enabled');
      }
    });
  });
}
