import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/keyboard_shortcuts.dart';
import 'package:didsa_cad_client/viewport3d/select_other_sheet.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

const _face = SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'b1', id: 3);
const _body = SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b2');
final _candidates = [
  const HoverHit(entity: _face, rayT: 1),
  const HoverHit(entity: _body, rayT: 2),
];

final registry = ToolPanelKeyRegistry();

Widget _host({
  required void Function(SelectionEntityRef) onSelect,
  required void Function(SelectionEntityRef?) onHighlight,
  required VoidCallback onClose,
  bool desktop = true,
  Offset anchor = const Offset(100, 100),
  Size size = const Size(800, 600),
}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: ToolPanelKeyScope(
              registry: registry,
              child: SelectOtherPanel(
                candidates: _candidates,
                bodyNames: const {'b2': 'Housing'},
                onSelect: onSelect,
                onHighlight: onHighlight,
                onClose: onClose,
                anchor: anchor,
                desktop: desktop,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('rows render names from bodyNames; tap selects and closes', (tester) async {
    SelectionEntityRef? picked;
    var closed = 0;
    await tester.pumpWidget(_host(onSelect: (e) => picked = e, onHighlight: (_) {}, onClose: () => closed++));
    expect(find.text('Face #3'), findsOneWidget);
    expect(find.text('Housing'), findsOneWidget);
    await tester.tap(find.text('Housing'));
    expect(picked, _body);
    expect(closed, 1);
  });

  testWidgets('long-press previews the entity and clears on release; the X closes', (tester) async {
    final highlights = <SelectionEntityRef?>[];
    var closed = 0;
    await tester.pumpWidget(_host(onSelect: (_) {}, onHighlight: highlights.add, onClose: () => closed++));
    final gesture = await tester.startGesture(tester.getCenter(find.text('Face #3')));
    await tester.pump(const Duration(milliseconds: 700));
    expect(highlights, contains(_face));
    await gesture.up();
    await tester.pump();
    expect(highlights.last, isNull);
    await tester.tap(find.byKey(const ValueKey('select-other-close')));
    expect(closed, 1);
  });

  testWidgets('mouse hover previews, and leaving the whole panel clears the preview', (tester) async {
    final highlights = <SelectionEntityRef?>[];
    await tester.pumpWidget(_host(onSelect: (_) {}, onHighlight: highlights.add, onClose: () {}));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(700, 500));
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.text('Housing')));
    await tester.pump();
    expect(highlights.last, _body);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pump();
    expect(highlights.last, isNull);
  });

  testWidgets('Esc closes', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_host(onSelect: (_) {}, onHighlight: (_) {}, onClose: () => closed++));
    // The screen's Esc handler runs the registry's top panel cancel.
    expect(registry.cancel, isNotNull);
    registry.cancel!();
    expect(closed, 1);
  });

  testWidgets('desktop popup sits near the anchor inside the viewport and is at most 320 tall', (tester) async {
    await tester.pumpWidget(_host(onSelect: (_) {}, onHighlight: (_) {}, onClose: () {}));
    final rect = tester.getRect(find.byKey(const ValueKey('select-other-panel')));
    final viewport = tester.getRect(find.byType(SizedBox).first);
    expect(rect.height, lessThanOrEqualTo(320));
    expect(rect.width, lessThanOrEqualTo(280));
    expect(rect.left, greaterThanOrEqualTo(viewport.left));
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect((rect.topLeft - (viewport.topLeft + const Offset(100, 100))).distance, lessThan(40));
  });

  testWidgets('desktop popup is clamped inside the viewport for an anchor at the far corner', (tester) async {
    await tester.pumpWidget(_host(
      onSelect: (_) {},
      onHighlight: (_) {},
      onClose: () {},
      anchor: const Offset(790, 590),
    ));
    final rect = tester.getRect(find.byKey(const ValueKey('select-other-panel')));
    final viewport = tester.getRect(find.byType(SizedBox).first);
    expect(viewport.contains(rect.bottomRight - const Offset(1, 1)), isTrue);
  });

  testWidgets('phone layout: a short bottom panel', (tester) async {
    await tester.pumpWidget(_host(onSelect: (_) {}, onHighlight: (_) {}, onClose: () {}, desktop: false));
    final rect = tester.getRect(find.byKey(const ValueKey('select-other-panel')));
    expect(rect.bottom, closeTo(tester.getRect(find.byType(SizedBox).first).bottom, 1));
    expect(rect.height, lessThanOrEqualTo(600 * 0.4 + 1));
  });
}
