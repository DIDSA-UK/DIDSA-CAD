import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_screen.dart';

/// Bug report 2026-11-18, part B: the feature tree inside the sketcher (`SketchScreen.featureTreeBuilder`).
Future<void> _pump(
  WidgetTester tester, {
  required bool desktop,
  Widget Function(BuildContext, VoidCallback)? builder,
  SketchReferenceSource? source,
  bool standalone = false,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final mockClient = MockClient((request) async {
    if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
      return http.Response(jsonEncode({'id': 'sketch-1', 'plane': 'XY', 'origin_point_id': 'origin-1'}), 201);
    }
    return http.Response('not found: ${request.method} ${request.url.path}', 404);
  });
  final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
  await controller.ensureSketch();
  Widget home = SketchScreen(
    controller: controller,
    featureTreeBuilder: builder,
    referenceSource: source,
    standalone: standalone,
  );
  if (desktop) {
    home = LayoutModeScope(
      controller: LayoutModeController(
        preference: LayoutPreference.desktop,
        windowSize: const Size(1280, 800),
        mouseActive: true,
      ),
      child: home,
    );
  }
  await tester.pumpWidget(MaterialApp(home: home));
  await tester.pump();
}

// The sketcher animates continuously (orbit view), so pumpAndSettle never settles: pump past the 200 ms slide instead.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Widget _fakeTree(BuildContext context, VoidCallback onClose) => Material(
      key: const ValueKey('fake-tree'),
      child: Align(
        alignment: Alignment.topLeft,
        child: TextButton(onPressed: onClose, child: const Text('Close the tree')),
      ),
    );

void main() {
  testWidgets('no builder, no tree button (the standalone 2D Drawing keeps its File button)', (tester) async {
    await _pump(tester, desktop: false, standalone: true);
    expect(find.byKey(const ValueKey('sketch-tree-fab')), findsNothing);
    expect(find.byKey(const ValueKey('sketch-file-fab')), findsOneWidget);
  });

  testWidgets('a builder gives the sketcher a tree button, and the tree is closed until it is tapped', (tester) async {
    await _pump(tester, desktop: false, builder: _fakeTree);
    expect(find.byKey(const ValueKey('sketch-tree-fab')), findsOneWidget);
    expect(find.byTooltip('Feature tree'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-tree')), findsNothing);
    // A Part-anchored sketch has no File button; the tree button takes the top-left corner.
    expect(find.byKey(const ValueKey('sketch-file-fab')), findsNothing);
  });

  testWidgets('phone: the tree button slides the tree over the viewport, and its own close and the button put it away',
      (tester) async {
    await _pump(tester, desktop: false, builder: _fakeTree);
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('fake-tree')), findsOneWidget);
    expect(find.byKey(const ValueKey('desktop-left-pane')), findsNothing, reason: 'the phone has no left pane');

    await tester.tap(find.text('Close the tree'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('fake-tree')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('fake-tree')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('fake-tree')), findsNothing);
  });

  testWidgets('desktop: the tree is a left pane beside the viewport, and the viewport keeps the rest of the width',
      (tester) async {
    await _pump(tester, desktop: true, builder: _fakeTree);
    expect(find.byKey(const ValueKey('desktop-left-pane')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    final pane = find.byKey(const ValueKey('desktop-left-pane'));
    expect(pane, findsOneWidget);
    expect(find.descendant(of: pane, matching: find.byKey(const ValueKey('fake-tree'))), findsOneWidget);
    // The button is still reachable, and puts the pane away.
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    expect(pane, findsNothing);
  });

  testWidgets('a change pushed through the reference source rebuilds the tree', (tester) async {
    final source = SketchReferenceSource();
    addTearDown(source.dispose);
    var hidden = false;
    await _pump(
      tester,
      desktop: false,
      source: source,
      builder: (context, onClose) => Material(child: Text(hidden ? 'sees hidden' : 'sees shown')),
    );
    await tester.tap(find.byKey(const ValueKey('sketch-tree-fab')));
    await _settle(tester);
    expect(find.text('sees shown'), findsOneWidget);

    hidden = true;
    source.update(bodies: const [], otherSketchGeometries: const {});
    await tester.pump();
    expect(find.text('sees hidden'), findsOneWidget);
  });
}
