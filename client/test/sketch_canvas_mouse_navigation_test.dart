import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/viewport3d/mouse_navigation.dart' show SelectClick;

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

/// Records [selectInRect]'s arguments (desktop input D2: the canvas picks
/// window / crossing from the drag direction and additive from Ctrl).
class _RecordingController extends SketchController {
  _RecordingController() : super(api: SketchApiClient(httpClient: MockClient((request) async => http.Response('not found', 404))));

  final boxes = <(Rect, bool, bool)>[];
  int finishChainCalls = 0;

  @override
  void finishChain() {
    finishChainCalls++;
    super.finishChain();
  }

  @override
  void selectInRect(Rect sketchRect, {bool crossing = false, bool additive = false}) {
    boxes.add((sketchRect, crossing, additive));
    super.selectInRect(sketchRect, crossing: crossing, additive: additive);
  }
}

Future<(_RecordingController, _Viewport)> _pumpCanvas(WidgetTester tester) async {
  final controller = _RecordingController();
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

  group('desktop input D2', () {
    Future<void> leftDrag(WidgetTester tester, Offset from, Offset by) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton);
      await gesture.down(from);
      await tester.pump();
      await gesture.moveBy(by);
      await tester.pump();
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a left mouse drag on blank canvas box-selects at once: left to right is a window', (tester) async {
      final (controller, _) = await _pumpCanvas(tester);
      await leftDrag(tester, const Offset(100, 100), const Offset(120, 80));
      expect(controller.boxes, hasLength(1));
      expect(controller.boxes.single.$2, isFalse, reason: 'left to right is a window select');
      expect(controller.boxes.single.$3, isFalse);
    });

    testWidgets('right to left is a crossing select; Ctrl adds', (tester) async {
      final (controller, _) = await _pumpCanvas(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await leftDrag(tester, const Offset(300, 100), const Offset(-120, 80));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.boxes, hasLength(1));
      expect(controller.boxes.single.$2, isTrue, reason: 'right to left is a crossing select');
      expect(controller.boxes.single.$3, isTrue, reason: 'Ctrl adds');
    });

    testWidgets('a left click that does not drag is no box', (tester) async {
      final (controller, _) = await _pumpCanvas(tester);
      await leftDrag(tester, const Offset(100, 100), const Offset(2, 1));
      expect(controller.boxes, isEmpty);
    });

    testWidgets('each press sets the click rule: mouse replaces, Ctrl+mouse toggles, touch keeps its own', (tester) async {
      final (controller, _) = await _pumpCanvas(tester);
      await tester.tapAt(const Offset(100, 100), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(controller.selectClick, SelectClick.replace);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tapAt(const Offset(100, 100), kind: PointerDeviceKind.mouse);
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.selectClick, SelectClick.toggle);

      await tester.tapAt(const Offset(100, 100));
      await tester.pump();
      expect(controller.selectClick, SelectClick.touch);
    });

    testWidgets('a middle double-click zooms to fit (empty sketch: back to the default view)', (tester) async {
      final (_, viewport) = await _pumpCanvas(tester);
      final defaultPan = viewport.pan;
      await _mouseDrag(tester, kMiddleMouseButton, const Offset(60, 40));
      expect(viewport.pan, isNot(defaultPan));

      for (var i = 0; i < 2; i++) {
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
        await gesture.down(const Offset(200, 200));
        await tester.pump(const Duration(milliseconds: 50));
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();
      expect(viewport.pan, defaultPan);
    });
  });

  testWidgets('desktop input D5: a middle click without a drag ends the chain being drawn; a drag or a select-mode click does not', (
    tester,
  ) async {
    final (controller, _) = await _pumpCanvas(tester);
    Future<void> middleClick({Offset drag = Offset.zero}) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await gesture.down(const Offset(200, 200));
      await tester.pump();
      if (drag != Offset.zero) {
        await gesture.moveBy(drag);
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      // Clear the double-click memory so each press stands alone.
      await tester.pump(const Duration(seconds: 1));
    }

    await middleClick();
    expect(controller.finishChainCalls, 0, reason: 'select mode: nothing to finish');

    controller.selectDrawTool(SketchTool.line);
    await middleClick(drag: const Offset(40, 0));
    expect(controller.finishChainCalls, 0, reason: 'a drag pans');

    await middleClick();
    expect(controller.finishChainCalls, 1);
  });
}
