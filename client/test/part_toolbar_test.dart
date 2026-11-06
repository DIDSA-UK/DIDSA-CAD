import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/didsa_logo_button.dart';
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

  group('Phone anchor (bottomRight)', () {
    const closeKey = ValueKey('toolbar-close');

    Future<void> pump(
      WidgetTester tester, {
      required Size size,
      PartToolbarAnchor anchor = PartToolbarAnchor.bottomRight,
      bool visible = true,
      double bottomInset = 16,
      EdgeInsets padding = EdgeInsets.zero,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, padding: padding),
            child: Scaffold(
              body: PartToolbar(
                visible: visible,
                onClose: () {},
                anchor: anchor,
                bottomInset: bottomInset,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Rect panelRect(WidgetTester tester) =>
        tester.getRect(find.byWidgetPredicate((w) => w is Material && w.elevation == 4));

    testWidgets('the DIDSA logo sits at the top of the panel, left of the close button', (tester) async {
      await pump(tester, size: const Size(400, 800));
      final logo = find.byType(DidsaLogoButton);
      expect(logo, findsOneWidget);
      expect(tester.getRect(logo).right, lessThan(tester.getRect(find.byKey(closeKey)).left));
      expect(tester.getRect(logo).top, lessThan(tester.getRect(find.text('File')).top));
    });

    testWidgets('visible: touches the right edge, bottom at the inset, at most two thirds of the screen',
        (tester) async {
      await pump(tester, size: const Size(400, 800), bottomInset: 40);
      final r = panelRect(tester);
      expect(r.right, 400);
      expect(r.bottom, 800 - 40);
      expect(r.height, lessThanOrEqualTo(800 * 2 / 3 + 0.01));
      expect(r.center.dx, greaterThan(200));
      expect(r.center.dy, greaterThan(400));
      expect(find.byKey(closeKey), findsOneWidget);
    });

    testWidgets('rounds the left corners, not the right ones', (tester) async {
      await pump(tester, size: const Size(400, 800));
      final material = tester.widget<Material>(
        find.byWidgetPredicate((w) => w is Material && w.elevation == 4),
      );
      final radius = (material.shape as RoundedRectangleBorder).borderRadius as BorderRadius;
      expect(radius.topLeft.x, 12);
      expect(radius.bottomLeft.x, 12);
      expect(radius.topRight, Radius.zero);
      expect(radius.bottomRight, Radius.zero);
    });

    testWidgets('short landscape screen: stays below the top safe-area inset', (tester) async {
      await pump(
        tester,
        size: const Size(640, 360),
        padding: const EdgeInsets.only(top: 24),
      );
      final r = panelRect(tester);
      expect(r.top, greaterThanOrEqualTo(24 + 8 - 0.01));
      expect(r.bottom, 360 - 16);
    });

    testWidgets('hidden: off screen to the right', (tester) async {
      await pump(tester, size: const Size(400, 800), visible: false);
      expect(panelRect(tester).left, greaterThanOrEqualTo(400));
    });

    testWidgets('topLeft (desktop default) is unchanged: left edge, under topInset, a third of the height',
        (tester) async {
      await pump(tester, size: const Size(1200, 900), anchor: PartToolbarAnchor.topLeft);
      final r = panelRect(tester);
      expect(r.left, 0);
      expect(r.top, 104);
      expect(r.height, lessThanOrEqualTo(900 / 3 + 0.01));
    });
  });
}
