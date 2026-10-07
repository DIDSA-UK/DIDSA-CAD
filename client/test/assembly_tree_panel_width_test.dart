import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/assembly_tree_panel.dart';

Widget _panel() => MaterialApp(
      home: Scaffold(
        body: AssemblyTreePanel(
          visible: true,
          occurrences: const [],
          mates: const [],
          selectedOccurrenceId: null,
          onOccurrenceTap: (_) {},
          onOccurrenceLongPress: (_) {},
          onClose: () {},
        ),
      ),
    );

/// The panel's own visible width: [AssemblyTreePanel]'s `SafeArea` wraps the width-constrained
/// `SizedBox`, which is the panel plus a 12px gutter on its right that hosts the outer half of the
/// resize handle (see `_handleOverhang`), so subtract that gutter.
double _panelWidth(WidgetTester tester) =>
    tester
        .getSize(find.descendant(
          of: find.byType(AssemblyTreePanel),
          matching: find.byType(SafeArea),
        ))
        .width -
    12;

void _setScreen(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

void main() {
  group('assemblyTreeDefaultWidthFraction', () {
    test('portrait phone gets 66%', () {
      expect(assemblyTreeDefaultWidthFraction(const Size(400, 800)), 0.66);
    });

    test('landscape phone, tablet and desktop get 40%', () {
      expect(assemblyTreeDefaultWidthFraction(const Size(800, 400)), 0.4);
      expect(assemblyTreeDefaultWidthFraction(const Size(800, 1200)), 0.4);
      expect(assemblyTreeDefaultWidthFraction(const Size(1400, 900)), 0.4);
    });
  });

  group('AssemblyTreePanel default width', () {
    testWidgets('is 66% of the screen on a portrait phone', (tester) async {
      _setScreen(tester, const Size(400, 800));
      await tester.pumpWidget(_panel());
      await tester.pumpAndSettle();

      expect(_panelWidth(tester), closeTo(400 * 0.66, 0.5));
    });

    testWidgets('is 40% of the screen on desktop', (tester) async {
      _setScreen(tester, const Size(1400, 900));
      await tester.pumpWidget(_panel());
      await tester.pumpAndSettle();

      expect(_panelWidth(tester), closeTo(1400 * 0.4, 0.5));
    });

    testWidgets('re-defaults when the device rotates, if the user has not resized it', (tester) async {
      _setScreen(tester, const Size(400, 800));
      await tester.pumpWidget(_panel());
      await tester.pumpAndSettle();
      expect(_panelWidth(tester), closeTo(400 * 0.66, 0.5));

      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(_panelWidth(tester), closeTo(800 * 0.4, 0.5));
    });

    testWidgets('the resize handle works on both sides of the visible panel edge', (tester) async {
      _setScreen(tester, const Size(1000, 800));
      await tester.pumpWidget(_panel());
      await tester.pumpAndSettle();

      // Inside the panel, then in the gutter just outside its visible edge - the half of the handle
      // that used to be clipped away and never received a pointer.
      for (final offset in const [-6.0, 6.0]) {
        final before = _panelWidth(tester);
        await tester.dragFrom(Offset(before + offset, 300), const Offset(40, 0));
        await tester.pumpAndSettle();
        expect(_panelWidth(tester), greaterThan(before + 20), reason: 'drag from edge $offset');
      }
    });

    testWidgets('a width the user dragged to survives rotation instead of being reset', (tester) async {
      _setScreen(tester, const Size(1000, 800));
      await tester.pumpWidget(_panel());
      await tester.pumpAndSettle();
      final before = _panelWidth(tester);

      // Grab the resize handle straddling the panel's right edge and drag.
      await tester.dragFrom(Offset(before - 4, 300), const Offset(150, 0));
      await tester.pumpAndSettle();
      final dragged = _panelWidth(tester);
      expect(dragged, greaterThan(before + 50));

      // Resize to a portrait phone, whose *default* would be 66% (264px).
      // The user's dragged fraction must win, not be reset to that default.
      final draggedFraction = dragged / 1000;
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(_panelWidth(tester), closeTo(draggedFraction * 400, 0.5));
      expect(_panelWidth(tester), isNot(closeTo(400 * 0.66, 1)));
    });
  });
}
