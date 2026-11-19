import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_ribbon.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Parity follow-ups F4 / C4: a selected ellipse axis dimension offers "Show semi-axis" / "Show full axis" in the ribbon, beside the value editor, which
/// shows and accepts the value on show: the constraint stores the semi-axis (centre to tip) whichever way it is read ("show full, edit 80" stores 40).
void main() {
  late SketchController controller;

  setUp(() {
    // No backend: the choice is kept in the session here (saving it needs a sketch id; `sketch_controller_test.dart` covers the saved round trip).
    controller = SketchController(api: SketchApiClient(httpClient: null));
    controller.points['c'] = const SketchPointView(id: 'c', x: 0, y: 0);
    controller.points['major'] = const SketchPointView(id: 'major', x: 40, y: 0);
    controller.points['majorNeg'] = const SketchPointView(id: 'majorNeg', x: -40, y: 0);
    controller.points['minor'] = const SketchPointView(id: 'minor', x: 0, y: 20);
    controller.points['minorNeg'] = const SketchPointView(id: 'minorNeg', x: 0, y: -20);
    controller.ellipses['e'] = const SketchEllipseView(
      id: 'e',
      centerPointId: 'c',
      majorPointId: 'major',
      majorPointNegId: 'majorNeg',
      minorPointId: 'minor',
      minorPointNegId: 'minorNeg',
      majorAxisLineId: 'majorLine',
      minorAxisLineId: 'minorLine',
      minorRadius: 20,
    );
    controller.constraints['axis'] = const DistanceConstraintDto(id: 'axis', pointAId: 'c', pointBId: 'major', distance: 40.0);
    controller.selectEntity(const SketchSelection(kind: SelectionKind.constraint, id: 'axis'));
  });

  Future<void> pumpRibbon(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 600, height: 400, child: SketchRibbon(controller: controller)))));
    await tester.pump();
  }

  String editorText(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).first).controller!.text;

  testWidgets('both choices are offered, the full axis is lit and the editor shows 80 for a stored 40', (tester) async {
    await pumpRibbon(tester);

    expect(find.text('Show full axis'), findsOneWidget);
    expect(find.text('Show semi-axis'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Show full axis')).selected, isTrue);
    expect(double.parse(editorText(tester)), 80.0);
    expect(find.text('mm full'), findsOneWidget);
  });

  testWidgets('Show semi-axis switches the editor to the stored value', (tester) async {
    await pumpRibbon(tester);

    await tester.tap(find.text('Show semi-axis'));
    await tester.pump();

    expect(controller.showsFullAxisFor('axis'), isFalse);
    expect(double.parse(editorText(tester)), 40.0);
    expect(find.text('mm semi'), findsOneWidget);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Show semi-axis')).selected, isTrue);
  });

  testWidgets('a circle\'s dimension still shows the Radius / Diameter toggle and no axis toggle', (tester) async {
    controller.points['rim'] = const SketchPointView(id: 'rim', x: 4, y: 0);
    controller.circles['circ'] = const SketchCircleView(id: 'circ', centerPointId: 'c', radiusPointId: 'rim');
    controller.constraints['radius'] = const DistanceConstraintDto(id: 'radius', pointAId: 'c', pointBId: 'rim', distance: 4.0);
    controller.closeRibbon(); // the axis dimension from setUp is no longer the selection
    controller.selectEntity(const SketchSelection(kind: SelectionKind.constraint, id: 'radius'));
    await pumpRibbon(tester);

    expect(find.text('Radius (R)'), findsOneWidget);
    expect(find.text('Show full axis'), findsNothing);
    expect(double.parse(editorText(tester)), 4.0);
  });
}
