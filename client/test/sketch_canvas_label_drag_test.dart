import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/view_transform.dart';

/// Dimension labels in the flat canvas (docs/dimension-labels-scope.md): a mouse press on a label that drags past the tap threshold picks it
/// up, the label follows the pointer, and the release drops it; touch keeps drag mode's tap-to-grab / tap-to-drop. Both go through the same
/// routine, which sets a placement in sketch units.
///
/// The canvas here is 400 x 400 at the default zoom: the sketch origin is at screen (200, 200) and one unit is 20 px (y up).
const _transform = ViewTransform(pixelsPerUnit: 20, originScreen: Offset(200, 200));

Future<SketchController> _pump(WidgetTester tester) async {
  final controller = SketchController(
    api: SketchApiClient(httpClient: MockClient((request) async => http.Response('not found', 404))),
  );
  controller.points['a'] = const SketchPointView(id: 'a', x: 0, y: 0);
  controller.points['b'] = const SketchPointView(id: 'b', x: 5, y: 0);
  controller.constraints['dim'] = const DistanceConstraintDto(id: 'dim', pointAId: 'a', pointBId: 'b', distance: 5);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: SketchCanvas(controller: controller))),
    ),
  );
  await tester.pump();
  return controller;
}

Offset _labelCentre(SketchController controller) => dimensionLabelCenterScreen(controller, _transform, 'dim')!;

void main() {
  testWidgets('a mouse press-drag-release on a dimension label moves it and saves where it was dropped', (tester) async {
    final controller = await _pump(tester);
    final start = _labelCentre(controller);
    expect(start, const Offset(250, 182), reason: 'the default: 18 px off the segment, at its middle');

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await tester.pump();
    expect(controller.draggingLabelId, isNull, reason: 'a bare press is a select click, not a grab');

    await gesture.moveTo(const Offset(270, 150));
    await tester.pump();
    expect(controller.draggingLabelId, 'dim');

    await gesture.moveTo(const Offset(300, 140));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(controller.draggingLabelId, isNull);
    final placement = controller.labelPlacementFor('dim')!;
    // (300, 140) is sketch (5, 3): 3 above the segment and 2.5 right of its middle.
    expect(placement.offset, closeTo(3.0, 1e-9));
    expect(placement.along, closeTo(2.5, 1e-9));
    expect(_labelCentre(controller), const Offset(300, 140));
  });

  testWidgets('the label keeps its place under the pointer: grabbing it off-centre does not make it jump', (tester) async {
    final controller = await _pump(tester);
    final centre = _labelCentre(controller);
    final grab = centre + const Offset(8, 3); // still on the label chip

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: grab);
    await gesture.down(grab);
    await gesture.moveBy(const Offset(40, -20));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // The pointer moved by (40, -20) and the label moved by exactly the same.
    expect(_labelCentre(controller).dx, closeTo(centre.dx + 40, 1e-6));
    expect(_labelCentre(controller).dy, closeTo(centre.dy - 20, 1e-6));
  });

  testWidgets('a mouse click on a label without moving does not move it', (tester) async {
    final controller = await _pump(tester);
    final start = _labelCentre(controller);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: start);
    await gesture.down(start);
    await gesture.moveBy(const Offset(2, 1));
    await gesture.up();
    await tester.pump();

    expect(controller.labelPlacementFor('dim'), isNull);
    expect(_labelCentre(controller), start);
  });

  testWidgets('touch drag mode still grabs with a tap, moves the label with the finger and drops with a tap', (tester) async {
    final controller = await _pump(tester);
    controller.toggleDragMode();
    // Touch is trackpad-style: a tap acts at the on-canvas cursor, so put the cursor on the label first.
    final start = _labelCentre(controller);
    final cursorStart = _transform.screenToSketch(start.dx, start.dy);
    controller.moveCursorToSketchPoint(cursorStart.x, cursorStart.y);

    final tap = await tester.startGesture(const Offset(100, 350), kind: PointerDeviceKind.touch);
    await tap.up();
    await tester.pump();
    expect(controller.draggingLabelId, 'dim', reason: 'the tap grabbed the label under the cursor');

    final finger = await tester.startGesture(const Offset(100, 350), kind: PointerDeviceKind.touch);
    await finger.moveBy(const Offset(30, -30));
    await finger.up();
    await tester.pump();

    // The label follows the cursor, which the swipe moved.
    final cursorNow = _transform.sketchToScreen(controller.cursorX, controller.cursorY);
    expect(cursorNow, isNot(start));
    expect(_labelCentre(controller).dx, closeTo(cursorNow.dx, 1e-6));
    expect(_labelCentre(controller).dy, closeTo(cursorNow.dy, 1e-6));

    final drop = await tester.startGesture(const Offset(100, 350), kind: PointerDeviceKind.touch);
    await drop.up();
    await tester.pump();
    expect(controller.draggingLabelId, isNull);
    expect(controller.labelPlacementFor('dim'), isNotNull);
  });
}
