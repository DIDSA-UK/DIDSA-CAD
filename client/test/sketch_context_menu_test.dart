import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_context_menu.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): the 2D sketch
/// canvas's right click (it reports a click, not a drag, and never a touch),
/// and the two sketch menus it leads to.
SketchController _controller() =>
    SketchController(api: SketchApiClient(httpClient: MockClient((request) async => http.Response('not found', 404))));

void main() {
  group('SketchCanvas right click', () {
    Future<List<(SketchSelection?, Offset)>> pumpCanvas(WidgetTester tester, SketchController controller) async {
      final requests = <(SketchSelection?, Offset)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                height: 400,
                child: SketchCanvas(
                  controller: controller,
                  onContextMenuRequested: (hit, at) => requests.add((hit, at)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return requests;
    }

    testWidgets('a right click without a drag reports a null hit over empty canvas, at the click', (tester) async {
      final requests = await pumpCanvas(tester, _controller());
      final at = tester.getCenter(find.byType(SketchCanvas));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await gesture.down(at);
      await gesture.up();
      await tester.pump();
      expect(requests, [(null, at)]);
    });

    testWidgets('a right drag pans and asks for no menu', (tester) async {
      final requests = await pumpCanvas(tester, _controller());
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await gesture.down(tester.getCenter(find.byType(SketchCanvas)));
      await gesture.moveBy(const Offset(60, 40));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(requests, isEmpty);
    });

    testWidgets('a middle click, a left click and a touch long-press ask for no menu', (tester) async {
      final requests = await pumpCanvas(tester, _controller());
      final at = tester.getCenter(find.byType(SketchCanvas));
      for (final buttons in [kMiddleMouseButton, kPrimaryMouseButton]) {
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons);
        await gesture.down(at);
        await gesture.up();
        await tester.pump();
      }
      await tester.longPressAt(at);
      await tester.pump();
      expect(requests, isEmpty);
    });
  });

  group('sketch menus', () {
    Future<void> open(WidgetTester tester, SketchController controller, {bool entity = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => entity
                    ? showSketchEntityContextMenu(context, controller, at: const Offset(200, 150))
                    : showSketchBackgroundContextMenu(context, controller, at: const Offset(200, 150), onZoomToFit: () {}),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('the empty-canvas menu lists the tools with their keys, and Line starts the line tool', (tester) async {
      final controller = _controller();
      await open(tester, controller);
      for (final label in ['Line', 'Circle', 'Arc', 'Rectangle', 'Dimension', 'Trim', 'Select All', 'Zoom to Fit']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('L'), findsOneWidget, reason: "Line's key");
      await tester.tap(find.text('Line'));
      await tester.pumpAndSettle();
      expect(controller.mode, SketchMode.draw);
      expect(controller.activeTool, SketchTool.line);
    });

    testWidgets('Zoom to Fit calls the screen\'s own fit', (tester) async {
      var fitted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showSketchBackgroundContextMenu(context, _controller(), at: const Offset(200, 150), onZoomToFit: () => fitted++),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zoom to Fit'));
      await tester.pumpAndSettle();
      expect(fitted, 1);
    });

    testWidgets('the entity menu for a selection offers Delete, with its key hint', (tester) async {
      final controller = _controller();
      controller.selectEntity(SketchSelection(kind: SelectionKind.line, id: 'no-such-line'));
      await open(tester, controller, entity: true);
      expect(find.byType(PopupMenuItem<VoidCallback>), findsWidgets);
      expect(find.text('Delete'), findsNWidgets(2), reason: 'the label and its key hint');
    });

    testWidgets('the entity menu with nothing selected shows nothing', (tester) async {
      await open(tester, _controller(), entity: true);
      expect(find.byType(PopupMenuItem<VoidCallback>), findsNothing);
    });
  });
}
