import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/resizable_tool_panel.dart';

/// On-device feedback ("the tooltip at the top of the screen blocks the
/// FABs to recentre and to switch between select/orbit"): [ResizableToolPanel]
/// is the shared shell every tool panel (Extrude, Revolve, Sweep, Fillet,
/// Chamfer, Mirror, Pattern) now uses instead of each floating its own
/// separate full-width `top: 8` banner - this covers the shell itself
/// (title/tooltip row, drag-to-resize, scrollability), independent of any
/// one tool's own fields.
void main() {
  Widget harness({String? tooltip, Key? dragHandleKey, Key? resizableAreaKey}) => MaterialApp(
        home: Scaffold(
          body: ResizableToolPanel(
            title: 'Extrude',
            tooltip: tooltip,
            dragHandleKey: dragHandleKey,
            resizableAreaKey: resizableAreaKey,
            child: const Text('field content'),
          ),
        ),
      );

  testWidgets('shows only the title when tooltip is null', (tester) async {
    await tester.pumpWidget(harness());

    expect(find.text('Extrude'), findsOneWidget);
    expect(find.byType(VerticalDivider), findsNothing);
  });

  testWidgets('shows the tooltip to the right of the title, separated by a divider, when non-null', (tester) async {
    await tester.pumpWidget(harness(tooltip: 'Select bodies to cut'));

    expect(find.text('Extrude'), findsOneWidget);
    expect(find.text('Select bodies to cut'), findsOneWidget);
    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  testWidgets('the child content is always present', (tester) async {
    await tester.pumpWidget(harness(tooltip: 'Select bodies to cut'));

    expect(find.text('field content'), findsOneWidget);
  });

  testWidgets('a drag handle is present at the given key, and can resize the panel', (tester) async {
    await tester.pumpWidget(
      harness(
        dragHandleKey: const Key('testDragHandle'),
        resizableAreaKey: const Key('testResizableArea'),
      ),
    );

    expect(find.byKey(const Key('testDragHandle')), findsOneWidget);
    final before = tester.getSize(find.byKey(const Key('testResizableArea')));

    await tester.drag(find.byKey(const Key('testDragHandle')), const Offset(0, -100));
    await tester.pump();

    final after = tester.getSize(find.byKey(const Key('testResizableArea')));
    expect(after.height, greaterThan(before.height));
  });
}
