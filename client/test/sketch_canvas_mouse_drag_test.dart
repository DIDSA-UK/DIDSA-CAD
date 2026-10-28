import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// Desktop input (`docs/desktop-input-scope.md`): with a mouse, pressing on a
/// sketch entity and dragging moves it and releasing drops it - no Drag
/// toggle, no click-move-click. A touch keeps the toggle.
class _DragRecorder extends SketchController {
  _DragRecorder() : super(api: SketchApiClient(httpClient: MockClient((request) async => http.Response('not found', 404))));

  bool grabbed = false;
  final grabs = <String>[];
  final moves = <(double, double)>[];
  int drops = 0;

  @override
  bool get isEntityGrabbed => grabbed;

  @override
  SketchSelection? dragGrabTargetAt(double x, double y, double radius) =>
      mode == SketchMode.select ? const SketchSelection(kind: SelectionKind.point, id: 'p0') : null;

  @override
  bool beginPointDrag(String pointId) {
    grabs.add(pointId);
    grabbed = true;
    return true;
  }

  @override
  Future<void> updateGrabbedPosition(double x, double y) async => moves.add((x, y));

  @override
  Future<void> dropGrabbedEntity() async {
    drops++;
    grabbed = false;
  }
}

Future<_DragRecorder> _pump(WidgetTester tester) async {
  final controller = _DragRecorder();
  controller.points['p0'] = const SketchPointView(id: 'p0', x: 0, y: 0);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, height: 400, child: SketchCanvas(controller: controller))),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('a mouse press-and-drag picks the entity up, moves it, and the release drops it', (tester) async {
    final controller = await _pump(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(200, 200));
    await gesture.down(const Offset(200, 200));
    await tester.pump();
    expect(controller.grabs, isEmpty, reason: 'a bare press is a select click, not a grab');

    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(controller.grabs, ['p0']);
    expect(controller.moves, isNotEmpty);
    expect(controller.grabbed, isTrue);

    await gesture.up();
    await tester.pump();
    expect(controller.drops, 1);
    expect(controller.grabbed, isFalse);
  });

  testWidgets('a mouse click without movement grabs nothing', (tester) async {
    final controller = await _pump(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(200, 200));
    await gesture.down(const Offset(200, 200));
    await gesture.moveBy(const Offset(2, 1));
    await gesture.up();
    await tester.pump();
    expect(controller.grabs, isEmpty);
    expect(controller.drops, 0);
  });

  testWidgets('with drag mode on, a mouse click does not pick up (click-move-click is touch only)', (tester) async {
    final controller = await _pump(tester);
    controller.toggleDragMode();
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(200, 200));
    await gesture.down(const Offset(200, 200));
    await gesture.up();
    await tester.pump();
    expect(controller.grabs, isEmpty);
    expect(controller.grabbed, isFalse);
  });

  testWidgets('with drag mode on, a touch tap still picks up', (tester) async {
    final controller = await _pump(tester);
    controller.toggleDragMode();
    final gesture = await tester.startGesture(const Offset(200, 200), kind: PointerDeviceKind.touch);
    await gesture.up();
    await tester.pump();
    expect(controller.grabs, ['p0']);
    expect(controller.grabbed, isTrue);
  });
}
