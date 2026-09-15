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

    testWidgets('Create Component, Add Mate, and Pattern Component render disabled', (tester) async {
      await openMenu(tester);
      for (final label in ['Create Component…', 'Add Mate', 'Pattern Component']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse, reason: '$label should be disabled');
      }
      expect(find.textContaining('Coming soon'), findsNWidgets(3));
    });

    testWidgets('tapping a disabled entry does nothing - the sheet stays open', (tester) async {
      await openMenu(tester);
      await tester.tap(find.text('Add Mate'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Add Mate'), findsOneWidget);
    });

    testWidgets('Add Component is the only enabled entry', (tester) async {
      await openMenu(tester);
      final addComponentTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Add Component'), matching: find.byType(ListTile)),
      );
      expect(addComponentTile.enabled, isTrue);
    });
  });
}
