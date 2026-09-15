import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/assembly_lens.dart';
import 'package:didsa_cad_client/viewport3d/part_toolbar.dart';

void main() {
  Future<void> pumpToolbar(
    WidgetTester tester, {
    required ColorScheme colorScheme,
    AssemblyLens lens = AssemblyLens.part,
    VoidCallback? onInsertExistingComponent,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: colorScheme),
        home: Scaffold(
          body: PartToolbar(
            visible: true,
            lens: lens,
            onInsertExistingComponent: onInsertExistingComponent,
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

    testWidgets('Assembly lens: shows the Assembly menu with Add Component enabled', (tester) async {
      var tapped = false;
      await pumpToolbar(
        tester,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        lens: AssemblyLens.assembly,
        onInsertExistingComponent: () => tapped = true,
      );

      expect(find.text('Assembly'), findsOneWidget);
      expect(find.text('Add Component'), findsOneWidget);

      final addComponentTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Add Component'), matching: find.byType(ListTile)),
      );
      expect(addComponentTile.enabled, isTrue);

      await tester.tap(find.text('Add Component'));
      expect(tapped, isTrue);
    });

    testWidgets('Assembly lens: Create Component, Add Mate, Pattern Component render disabled', (
      tester,
    ) async {
      await pumpToolbar(
        tester,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        lens: AssemblyLens.assembly,
      );

      for (final label in ['Create Component…', 'Add Mate', 'Pattern Component']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse, reason: '$label should be disabled');
      }
      expect(find.textContaining('Coming soon'), findsNWidgets(3));
    });

    testWidgets('Assembly lens: Add Component is disabled when no callback is supplied', (
      tester,
    ) async {
      await pumpToolbar(
        tester,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        lens: AssemblyLens.assembly,
      );

      final addComponentTile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Add Component'), matching: find.byType(ListTile)),
      );
      expect(addComponentTile.enabled, isFalse);
    });
  });
}
