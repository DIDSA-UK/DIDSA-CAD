import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// Desktop input D1 (`docs/desktop-input-scope.md`): the 2D sketch canvas's
/// mouse bindings - middle drag (and Ctrl+middle, and right drag) pans,
/// Shift+middle drag zooms, the wheel zooms in proportion to the scroll,
/// and the system cursor follows the mode. Driven through real synthetic
/// mouse gestures; the view is read back through
/// [SketchCanvas.onViewportChanged].
class _Viewport {
  Offset pan = Offset.zero;
  double zoom = 1;
}

Future<(SketchController, _Viewport)> _pumpCanvas(WidgetTester tester) async {
  final controller = SketchController(
    api: SketchApiClient(httpClient: MockClient((request) async => http.Response('not found', 404))),
  );
  final viewport = _Viewport();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: SketchCanvas(
            controller: controller,
            onViewportChanged: (pan, zoom, _) {
              viewport.pan = pan;
              viewport.zoom = zoom;
            },
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return (controller, viewport);
}

Future<void> _mouseDrag(WidgetTester tester, int buttons, Offset by) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons);
  await gesture.down(const Offset(200, 200));
  await tester.pump();
  await gesture.moveBy(by);
  await tester.pump();
  await gesture.up();
  await tester.pump();
  await tester.pump();
}

MouseCursor _canvasCursor(WidgetTester tester) => tester
    .widget<MouseRegion>(find.descendant(of: find.byType(SketchCanvas), matching: find.byType(MouseRegion)).first)
    .cursor;

void main() {
  testWidgets('a middle drag pans and leaves the sketch cursor where it was', (tester) async {
    final (controller, viewport) = await _pumpCanvas(tester);
    final panBefore = viewport.pan;
    final zoomBefore = viewport.zoom;
    final cursorBefore = (controller.cursorX, controller.cursorY);

    await _mouseDrag(tester, kMiddleMouseButton, const Offset(40, 0));

    expect(viewport.pan, isNot(panBefore));
    expect(viewport.zoom, zoomBefore);
    expect((controller.cursorX, controller.cursorY), cursorBefore, reason: 'a view drag must not move the cursor');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a right drag still pans', (tester) async {
    final (_, viewport) = await _pumpCanvas(tester);
    final panBefore = viewport.pan;

    await _mouseDrag(tester, kSecondaryMouseButton, const Offset(0, 40));

    expect(viewport.pan, isNot(panBefore));
  });

  testWidgets('Ctrl+middle drag pans; Shift+middle drag zooms', (tester) async {
    final (_, viewport) = await _pumpCanvas(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final panBefore = viewport.pan;
    final zoomBefore = viewport.zoom;
    await _mouseDrag(tester, kMiddleMouseButton, const Offset(40, 0));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(viewport.pan, isNot(panBefore));
    expect(viewport.zoom, zoomBefore);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _mouseDrag(tester, kMiddleMouseButton, const Offset(0, -40));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(viewport.zoom, greaterThan(zoomBefore), reason: 'dragging up zooms in');
  });

  testWidgets('a small trackpad scroll zooms less than a wheel notch', (tester) async {
    final (_, viewport) = await _pumpCanvas(tester);

    final zoomStart = viewport.zoom;
    tester.binding.handlePointerEvent(
      const PointerScrollEvent(position: Offset(200, 200), scrollDelta: Offset(0, -5)),
    );
    await tester.pump();
    await tester.pump();
    final smallStep = viewport.zoom / zoomStart;

    final zoomMid = viewport.zoom;
    tester.binding.handlePointerEvent(
      const PointerScrollEvent(position: Offset(200, 200), scrollDelta: Offset(0, -100)),
    );
    await tester.pump();
    await tester.pump();
    final notchStep = viewport.zoom / zoomMid;

    expect(smallStep, greaterThan(1), reason: 'scrolling up zooms in');
    expect(notchStep, closeTo(1 / 0.9, 1e-6), reason: 'a full notch keeps the old 10 %');
    expect(smallStep, lessThan(notchStep));
  });

  testWidgets('the system cursor follows the mode and the view drag', (tester) async {
    final (controller, _) = await _pumpCanvas(tester);
    expect(controller.mode, SketchMode.select);
    expect(_canvasCursor(tester), SystemMouseCursors.basic);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await gesture.down(const Offset(200, 200));
    await tester.pump();
    await gesture.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(_canvasCursor(tester), SystemMouseCursors.grabbing);
    await gesture.up();
    await tester.pump();
    expect(_canvasCursor(tester), SystemMouseCursors.basic);

    controller.selectDrawTool(SketchTool.line);
    await tester.pump();
    expect(controller.mode, SketchMode.draw);
    expect(_canvasCursor(tester), SystemMouseCursors.precise);
  });
}
