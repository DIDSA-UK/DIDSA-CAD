import 'dart:convert';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_dimension_bar.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/sketch_geometry_3d.dart';

/// Part A of docs/bug-report-2026-11-18-plan.md, as a person meets it: the dimension tool previews one dimension at the cursor, lists
/// the kinds that fit in a drawer, and drops the chosen one with a click that opens the value editor. One test per view (the flat canvas
/// with a mouse, the 3D sketch view through the callbacks its viewport fires) plus the drawer. The maths and the constraint writes are in
/// `sketch_controller_test.dart`; what a pointer feels like is not something a headless test can judge.
http.Response _handle(http.Request request) {
  if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
    return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
  }
  if (request.url.path == '/sketch/sketches/sketch-1/orientation' && request.method == 'PATCH') {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    return http.Response(
      jsonEncode({
        'id': 'sketch-1',
        'plane': 'XY',
        'origin_point_id': 'origin-1',
        'flip': body['flip'],
        'rotation_quarter_turns': body['rotation_quarter_turns'],
      }),
      200,
    );
  }
  return http.Response('not found: ${request.method} ${request.url.path}', 404);
}

/// A controller with two free Points, (2, 2) and (12, 7).
Future<SketchController> _controllerWithTwoPoints() async {
  final controller = SketchController(api: SketchApiClient(httpClient: MockClient((request) async => _handle(request))));
  await controller.ensureSketch();
  controller.points['pa'] = const SketchPointView(id: 'pa', x: 2, y: 2);
  controller.points['pb'] = const SketchPointView(id: 'pb', x: 12, y: 7);
  return controller;
}

/// [_controllerWithTwoPoints], both picked in the Dimension tool.
Future<SketchController> _controllerWithTwoPointsPicked() async {
  final controller = await _controllerWithTwoPoints();
  controller.enterDimensionMode();
  await controller.handleCanvasTap(2, 2);
  await controller.handleCanvasTap(12, 7);
  expect(controller.pendingDimensionOptions, isNotEmpty);
  return controller;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('flat canvas: the preview follows the mouse, a click on empty canvas drops it and opens a focused editor with the value selected',
      (tester) async {
    final controller = await _controllerWithTwoPointsPicked();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, height: 600, child: SketchCanvas(controller: controller))),
      ),
    );
    await tester.pump();
    expect(find.byType(GhostValueEditor), findsNothing); // previewed, not dropped

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    addTearDown(mouse.removePointer);

    // Far from both Points whatever the default view is: the top-left corner is empty canvas.
    await mouse.moveTo(const Offset(40, 40));
    await tester.pump();
    final first = controller.pendingPlacementFromCursor();
    await mouse.moveTo(const Offset(300, 520));
    await tester.pump();
    expect(controller.pendingPlacementFromCursor(), isNot(first)); // it follows the pointer
    expect(controller.activeGhostKey, isNull);

    await mouse.down(const Offset(300, 520));
    await mouse.up();
    await tester.pump();

    expect(controller.activeGhostKey, isNotNull);
    final atDrop = controller.ghostPlacement(controller.pendingDimensionGhost!);
    expect(atDrop, isNotNull);
    expect(find.byType(GhostValueEditor), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue, reason: 'the editor takes keyboard focus at once, so typing replaces the value');
    expect(field.controller!.selection, TextSelection(baseOffset: 0, extentOffset: field.controller!.text.length));

    // Moving the pointer on does not move a dropped dimension.
    await mouse.moveTo(const Offset(100, 100));
    await tester.pump();
    expect(controller.ghostPlacement(controller.pendingDimensionGhost!), atDrop);
    expect(tester.takeException(), isNull);
  });

  testWidgets('flat canvas: a click away from a dropped dimension\'s editor goes back to the live preview', (tester) async {
    final controller = await _controllerWithTwoPointsPicked();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SizedBox(width: 600, height: 600, child: SketchCanvas(controller: controller))),
      ),
    );
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(20, 20));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(const Offset(300, 520));
    await mouse.down(const Offset(300, 520));
    await mouse.up();
    await tester.pump();
    expect(controller.activeGhostKey, isNotNull);

    await mouse.moveTo(const Offset(60, 500));
    await mouse.down(const Offset(60, 500));
    await mouse.up();
    await tester.pump();

    expect(controller.activeGhostKey, isNull);
    expect(controller.pendingDimensionGhost, isNotNull); // the preview is back, the pick is kept
    expect(find.byType(GhostValueEditor), findsNothing);
  });

  testWidgets('the drawer lists the kinds that fit, highlights the previewed one, and a click on a chip switches the preview',
      (tester) async {
    final controller = await _controllerWithTwoPointsPicked();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: SketchDimensionBar(controller: controller)))));
    await tester.pump();

    expect(find.byKey(const ValueKey('dimension-option-linear')), findsOneWidget);
    expect(find.byKey(const ValueKey('dimension-option-h')), findsOneWidget);
    expect(find.byKey(const ValueKey('dimension-option-v')), findsOneWidget);
    expect(find.text('Aligned'), findsOneWidget);
    expect(find.text('Horizontal'), findsOneWidget);
    expect(find.text('Vertical'), findsOneWidget);
    ChoiceChip chip(String key) => tester.widget<ChoiceChip>(find.byKey(ValueKey('dimension-option-$key')));

    controller.moveCursorToSketchPoint(7, 30); // above the pair's box: the cursor rule previews Horizontal
    await tester.pump();
    expect(chip('h').selected, isTrue);
    expect(chip('linear').selected, isFalse);

    await tester.tap(find.byKey(const ValueKey('dimension-option-v')));
    await tester.pump();
    expect(controller.pendingDimensionKey, 'v');
    expect(chip('v').selected, isTrue);
    controller.moveCursorToSketchPoint(7, 30);
    await tester.pump();
    expect(controller.pendingDimensionKey, 'v', reason: 'a kind clicked in the drawer stays');
  });

  testWidgets('the drawer shows no kinds when nothing fits the pick, and keeps its prompt when nothing is picked', (tester) async {
    final controller = SketchController(api: SketchApiClient(httpClient: MockClient((request) async => _handle(request))));
    await controller.ensureSketch();
    controller.enterDimensionMode();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: SketchDimensionBar(controller: controller)))));
    await tester.pump();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Tap one or two entities to dimension'), findsOneWidget);
  });

  testWidgets('3D sketch view: the preview follows the cursor, a commit on empty plane drops it and opens the editor', (tester) async {
    final controller = await _controllerWithTwoPoints();

    await tester.pumpWidget(MaterialApp(home: SketchScreen(controller: controller)));
    for (var i = 0; i < 50; i++) {
      if (find.byType(PartViewport).evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 100; i++) {
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    // (Opening the 3D view starts in Select mode, so the tool is entered and the two Points picked once it is up.)
    controller.enterDimensionMode();
    await controller.handleCanvasTap(2, 2);
    await controller.handleCanvasTap(12, 7);
    await tester.pump();
    expect(controller.pendingDimensionOptions, isNotEmpty);

    var viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    final basis = viewport.sketchPlaneBasis!;
    // Before the drop the label sits at the cursor and must not catch the click, so the viewport is not asked for an overlay hit.
    expect(viewport.preferConstraintOverlayHitOnCommit, isFalse);
    expect(viewport.activeConstraintOverlayItemId, isNull);

    // The cursor moves over empty plane: the preview (one item, "?") follows it.
    viewport.onDrawCursorMoved!(sketchPointToWorld(basis, 7, 30), null);
    await tester.pump();
    var items = tester.widget<PartViewport>(find.byType(PartViewport)).constraintOverlayItems;
    expect(items.whereType<ConstraintLinearDimensionItem>().where((i) => i.text == '?'), hasLength(1));
    final placementAbove = controller.pendingPlacementFromCursor();
    viewport.onDrawCursorMoved!(sketchPointToWorld(basis, 30, 4), null);
    await tester.pump();
    expect(controller.pendingPlacementFromCursor(), isNot(placementAbove));
    expect(controller.pendingDimensionKind, GhostKind.vertical); // right of the pair's box

    // A commit on empty plane drops it.
    viewport.onDrawCursorCommit!(sketchPointToWorld(basis, 30, 4), null);
    await tester.pump();
    expect(controller.activeGhostKey, 'v');
    viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    expect(viewport.activeConstraintOverlayItemId, 'v');
    // From now on a click away from the editor is routed to cancel it.
    expect(viewport.preferConstraintOverlayHitOnCommit, isTrue);
    expect(viewport.onConstraintOverlayItemTap!(null, null, null), isTrue);
    expect(controller.activeGhostKey, isNull);
    expect(controller.pendingDimensionGhost, isNotNull);
    expect(tester.takeException(), isNull);
  });

  // Every kind of dimension the drawer offers is drawn on the flat canvas by the painter a confirmed dimension uses and, once dropped,
  // anchors the editor at its label - so a kind whose preview cannot be laid out (a null label centre) would show no editor at all.
  group('flat canvas draws and anchors every kind', () {
    Future<SketchController> fresh() async {
      final controller = SketchController(api: SketchApiClient(httpClient: MockClient((request) async => _handle(request))));
      await controller.ensureSketch();
      return controller;
    }

    Future<void> previewThenDrop(
      WidgetTester tester,
      SketchController controller, {
      required (double, double) cursor,
      String? kind,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SizedBox(width: 600, height: 600, child: SketchCanvas(controller: controller))),
        ),
      );
      await tester.pump();
      if (kind != null) controller.selectPendingDimensionKind(kind);
      controller.moveCursorToSketchPoint(cursor.$1, cursor.$2);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'the preview paints');
      expect(controller.pendingDimensionGhost, isNotNull);
      expect(controller.dropPendingDimension(), isTrue);
      await tester.pump();
      expect(find.byType(GhostValueEditor), findsOneWidget, reason: 'the editor is anchored at the label');
      expect(tester.takeException(), isNull);
    }

    testWidgets('line length, horizontal and vertical', (tester) async {
      for (final kind in ['length', 'h', 'v']) {
        final controller = await fresh();
        controller.points['a'] = const SketchPointView(id: 'a', x: 1, y: 1);
        controller.points['b'] = const SketchPointView(id: 'b', x: 9, y: 5);
        controller.lines['l'] = const SketchLineView(id: 'l', startPointId: 'a', endPointId: 'b');
        controller.enterDimensionMode();
        await controller.handleCanvasTap(2.5, 1.75); // on the line, off its ends and midpoint
        await previewThenDrop(tester, controller, cursor: (5, 9), kind: kind);
      }
    });

    testWidgets('circle diameter and radius', (tester) async {
      for (final kind in ['diameter', 'radius']) {
        final controller = await fresh();
        controller.points['c'] = const SketchPointView(id: 'c', x: 0, y: 0);
        controller.points['r'] = const SketchPointView(id: 'r', x: 4, y: 0);
        controller.circles['k'] = const SketchCircleView(id: 'k', centerPointId: 'c', radiusPointId: 'r');
        controller.enterDimensionMode();
        await controller.handleCanvasTap(4 * 0.70710678, 4 * 0.70710678);
        await previewThenDrop(tester, controller, cursor: (-9, 6), kind: kind);
      }
    });

    testWidgets('point to line, perpendicular and by cursor kinds', (tester) async {
      for (final kind in ['perpendicular', 'h', 'v', 'linear']) {
        final controller = await fresh();
        controller.points['a'] = const SketchPointView(id: 'a', x: 0, y: 8);
        controller.points['b'] = const SketchPointView(id: 'b', x: 20, y: 8);
        controller.points['p'] = const SketchPointView(id: 'p', x: 8, y: 2);
        controller.lines['l'] = const SketchLineView(id: 'l', startPointId: 'a', endPointId: 'b');
        controller.enterDimensionMode();
        await controller.handleCanvasTap(8, 2);
        await controller.handleCanvasTap(4, 8);
        await previewThenDrop(tester, controller, cursor: (14, 5), kind: kind);
      }
    });

    testWidgets('two parallel lines (distance) and two other lines (angle)', (tester) async {
      final parallel = await fresh();
      parallel.points['a'] = const SketchPointView(id: 'a', x: 0, y: 0);
      parallel.points['b'] = const SketchPointView(id: 'b', x: 10, y: 0);
      parallel.points['c'] = const SketchPointView(id: 'c', x: 0, y: 6);
      parallel.points['d'] = const SketchPointView(id: 'd', x: 10, y: 6);
      parallel.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'a', endPointId: 'b');
      parallel.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'c', endPointId: 'd');
      parallel.enterDimensionMode();
      await parallel.handleCanvasTap(3, 0);
      await parallel.handleCanvasTap(3, 6);
      expect(parallel.pendingDimensionKind, GhostKind.lineDistance);
      await previewThenDrop(tester, parallel, cursor: (5, 3));

      final angled = await fresh();
      angled.points['a'] = const SketchPointView(id: 'a', x: 0, y: 0);
      angled.points['b'] = const SketchPointView(id: 'b', x: 10, y: 0);
      angled.points['c'] = const SketchPointView(id: 'c', x: 5, y: 10);
      angled.lines['l1'] = const SketchLineView(id: 'l1', startPointId: 'a', endPointId: 'b');
      angled.lines['l2'] = const SketchLineView(id: 'l2', startPointId: 'a', endPointId: 'c');
      angled.enterDimensionMode();
      await angled.handleCanvasTap(8, 0);
      await angled.handleCanvasTap(4, 8);
      expect(angled.pendingDimensionKind, GhostKind.angle);
      await previewThenDrop(tester, angled, cursor: (-3, 4));
    });
  });

}
