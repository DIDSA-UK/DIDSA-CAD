import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';
import 'package:didsa_cad_client/sketch/sketch_text_bar.dart';

/// 3D-viewport Text tool round (`docs/text-tool-3d-viewport-scope.md`
/// §2.3): [TextValueBar] replaces the old "Edit Text" `AlertDialog` - this
/// covers the widget itself (shown/hidden by [SketchController.
/// textBarTextId], field seeding, the font picker's expand/collapse), the
/// same "layout/rendering, not full network round-trips" scope
/// `resizable_tool_panel_test.dart` already covers for the shared shell -
/// see `sketch_controller_test.dart`'s own "Text resize/position handles"
/// group for the network-backed `setTextProperties` behavior this widget
/// calls into.
void main() {
  SketchController buildController() {
    final mockClient = MockClient((request) async => http.Response('not found', 404));
    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));
    controller.points['anchor-1'] = const SketchPointView(id: 'anchor-1', x: 0, y: 0);
    controller.texts['text-1'] = const SketchTextView(
      id: 'text-1',
      content: 'Hi',
      font: 'Open Sans',
      size: 12.0,
      anchorPointId: 'anchor-1',
      previewContoursRelative: [
        SketchTextContourOffsets(outer: [(0, 0), (24, 0), (24, 12), (0, 12)]),
      ],
    );
    return controller;
  }

  Widget harness(SketchController controller) => MaterialApp(
        home: Scaffold(body: TextValueBar(controller: controller)),
      );

  testWidgets('hidden while textBarTextId is null', (tester) async {
    final controller = buildController();
    await tester.pumpWidget(harness(controller));

    expect(find.byKey(const Key('textValueBarResizableArea')), findsNothing);
  });

  testWidgets('shows the panel seeded with the Text\'s own content/font/size once opened', (tester) async {
    final controller = buildController();
    controller.openTextBar('text-1');

    await tester.pumpWidget(harness(controller));
    await tester.pump();

    expect(find.byKey(const Key('textValueBarResizableArea')), findsOneWidget);
    // Panel title, and separately the content field's own "Text" label -
    // two distinct widgets that happen to render the same string.
    expect(find.text('Text'), findsNWidgets(2));
    expect(find.text('Hi'), findsOneWidget); // content field
    expect(find.text('12.0'), findsOneWidget); // height field, seeded from size
    expect(find.text('Open Sans'), findsOneWidget); // collapsed font picker
  });

  testWidgets('tapping the collapsed font picker expands it to every allowlisted font, each '
      'rendered in its own face', (tester) async {
    final controller = buildController();
    controller.openTextBar('text-1');
    await tester.pumpWidget(harness(controller));
    await tester.pump();

    await tester.tap(find.byKey(const Key('textValueBarFontCollapsed')));
    await tester.pump();

    expect(find.byKey(const Key('textValueBarFontExpanded')), findsOneWidget);
    for (final font in textFontOptions) {
      expect(find.text(font), findsOneWidget);
    }
  });

  testWidgets('re-tapping the current font row collapses the picker again without changing font '
      '(no PATCH needed - a real network call would fail this test\'s always-404 mock)', (tester) async {
    final controller = buildController();
    controller.openTextBar('text-1');
    await tester.pumpWidget(harness(controller));
    await tester.pump();
    await tester.tap(find.byKey(const Key('textValueBarFontCollapsed')));
    await tester.pump();

    await tester.tap(find.widgetWithText(InkWell, 'Open Sans').first);
    await tester.pump();

    expect(find.byKey(const Key('textValueBarFontExpanded')), findsNothing);
    expect(find.byKey(const Key('textValueBarFontCollapsed')), findsOneWidget);
    expect(controller.texts['text-1']!.font, 'Open Sans');
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Done closes the bar', (tester) async {
    final controller = buildController();
    controller.openTextBar('text-1');
    await tester.pumpWidget(harness(controller));
    await tester.pump();

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.pump(); // the postFrameCallback deferral _close uses

    expect(controller.textBarTextId, isNull);
  });
}
