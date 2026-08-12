import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/tool_chooser_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';

void main() {
  testWidgets('ToolChooserScreen offers both destinations and navigates to PartScreen on tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolChooserScreen()));

    expect(find.text('3D Part Design'), findsOneWidget);
    expect(find.text('2D Drawing'), findsOneWidget);

    await tester.tap(find.text('3D Part Design'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // lets the push transition finish
    expect(find.byType(PartScreen), findsOneWidget);
  });

  testWidgets('ToolChooserScreen navigates to a standalone SketchScreen on "2D Drawing" tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolChooserScreen()));

    await tester.tap(find.text('2D Drawing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // lets the push transition finish
    expect(find.byType(SketchScreen), findsOneWidget);
    final sketchScreen = tester.widget<SketchScreen>(find.byType(SketchScreen));
    expect(sketchScreen.standalone, isTrue);
  });

  testWidgets('shows a back button once it can pop (e.g. reached, as in the real app, from '
      'ConnectionScreen via push)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolChooserScreen())),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));

    // No back affordance yet - this screen is still the Navigator's root.
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    expect(find.byType(ToolChooserScreen), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets(
      'nav cleanup regression: a tile push()es its destination (not pushReplacement()), so the '
      'automatic back button on the pushed screen returns to ToolChooserScreen rather than '
      'skipping past it to whatever was underneath', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ToolChooserScreen())),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('start'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2D Drawing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(SketchScreen), findsOneWidget);

    // SketchScreen's own AppBar `leading` is a plain logo button (see
    // DidsaLogoButton), not a back arrow - popping directly through the
    // Navigator mirrors how a device's system back gesture would behave,
    // same convention ai_modelling_screen_test.dart already uses for a
    // screen with a custom `leading`.
    Navigator.of(tester.element(find.byType(SketchScreen))).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Lands back on ToolChooserScreen, not the 'start' screen underneath it -
    // if the tile had instead used pushReplacement, ToolChooserScreen would
    // already be gone from the stack and this pop would have skipped
    // straight past it.
    expect(find.byType(ToolChooserScreen), findsOneWidget);
    expect(find.text('What would you like to open?'), findsOneWidget);
  });
}
