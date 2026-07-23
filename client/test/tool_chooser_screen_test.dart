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
    await tester.pump(const Duration(milliseconds: 300)); // lets the push-replacement transition finish
    expect(find.byType(PartScreen), findsOneWidget);
  });

  testWidgets('ToolChooserScreen navigates to a standalone SketchScreen on "2D Drawing" tap',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ToolChooserScreen()));

    await tester.tap(find.text('2D Drawing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // lets the push-replacement transition finish
    expect(find.byType(SketchScreen), findsOneWidget);
    final sketchScreen = tester.widget<SketchScreen>(find.byType(SketchScreen));
    expect(sketchScreen.standalone, isTrue);
  });
}
