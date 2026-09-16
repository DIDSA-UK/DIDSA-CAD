import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/viewport3d/part_toolbar.dart';

void main() {
  Future<void> pumpToolbar(
    WidgetTester tester, {
    required ColorScheme colorScheme,
    AssemblyLens lens = AssemblyLens.part,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: colorScheme),
        home: Scaffold(
          body: PartToolbar(
            visible: true,
            lens: lens,
          ),
        ),
      ),
    );
  }

  group('Phase 3b lens theming', () {
    testWidgets('Part lens (default): no border accent, File/View/Selection Filters unchanged', (
      tester,
    ) async {
      final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      await pumpToolbar(tester, colorScheme: colorScheme);

      final material = tester.widget<Material>(
        find.byWidgetPredicate((widget) => widget is Material && widget.elevation == 4),
      );
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.side, BorderSide.none);

      expect(find.text('File'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);
      expect(find.text('Selection Filters'), findsOneWidget);
      expect(find.text('Assembly'), findsNothing);
    });

    testWidgets('Assembly lens: border is tinted with the tertiary accent color', (tester) async {
      final colorScheme = ColorScheme.fromSeed(seedColor: Colors.blue);
      await pumpToolbar(tester, colorScheme: colorScheme, lens: AssemblyLens.assembly);

      final material = tester.widget<Material>(
        find.byWidgetPredicate((widget) => widget is Material && widget.elevation == 4),
      );
      final shape = material.shape as RoundedRectangleBorder;
      expect(shape.side.color, colorScheme.tertiary);
      expect(shape.side.width, greaterThan(0));
    });

    // Bug fix: this hamburger-menu "Assembly" section (`_buildAssemblyMenu`)
    // used to duplicate the Assembly-lens "Add" FAB's own flyout
    // (`add_button_menu.dart`'s `showAssemblyAddMenu`) - same actions, same
    // labels - and had already drifted stale on top of that (still showing
    // Add Mate/Pattern Component as "Coming soon" after both became real in
    // the FAB's own menu). Removed rather than kept in sync; the FAB flyout
    // remains the one place to reach these actions.
    testWidgets('Assembly lens: no separate Assembly menu section - Add Component only reachable via the FAB', (
      tester,
    ) async {
      await pumpToolbar(
        tester,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        lens: AssemblyLens.assembly,
      );

      expect(find.text('Assembly'), findsNothing);
      expect(find.text('Add Component'), findsNothing);
      expect(find.text('Create Component…'), findsNothing);
      expect(find.text('Add Mate'), findsNothing);
      expect(find.text('Pattern Component'), findsNothing);
    });
  });
}
