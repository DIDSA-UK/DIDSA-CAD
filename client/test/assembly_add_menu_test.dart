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

    testWidgets('tapping Pattern Component resolves patternComponent', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Pattern Component'));
      await tester.pumpAndSettle();
      expect(await pendingResult, AssemblyAddMenuAction.patternComponent);
    });

    // Phase 15 (`docs/assembly-scope.md` §6): Create Component was the last
    // remaining placeholder (needed a multi-file save flow this app didn't
    // have yet) - real as of this phase, the same way Pattern Component
    // became real in Phase 7.
    testWidgets('tapping Create Component resolves createNewComponent', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Create Component…'));
      await tester.pumpAndSettle();
      expect(await pendingResult, AssemblyAddMenuAction.createNewComponent);
    });

    testWidgets('every entry is enabled', (tester) async {
      await openMenu(tester);
      for (final label in ['Add Component', 'Create Component…', 'Add Mate', 'Pattern Component']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isTrue, reason: '$label should be enabled');
      }
    });
  });
}
