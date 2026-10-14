import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/selection_list_drawer.dart';

Widget _hostedDrawer(Widget drawer) => MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 600, child: drawer),
      ),
    );

void main() {
  testWidgets('Fix 5: an empty selection renders nothing', (tester) async {
    await tester.pumpWidget(
      _hostedDrawer(
        SelectionListDrawer(selectedEntities: const {}, onRemove: (_) {}),
      ),
    );

    expect(find.byType(DraggableScrollableSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fix 5: a non-empty selection renders the header above the entity list, and removal fires onRemove', (
    tester,
  ) async {
    SelectionEntityRef? removed;
    const entity = SelectionEntityRef(kind: SelectionEntityKind.face, id: 1);

    await tester.pumpWidget(
      _hostedDrawer(
        SelectionListDrawer(
          selectedEntities: {entity},
          onRemove: (e) => removed = e,
          header: const Text('header-marker'),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    expect(find.text('header-marker'), findsOneWidget);
    expect(find.text('Face #1'), findsOneWidget);

    // The header must appear above the list item in the sheet's Column.
    final headerY = tester.getTopLeft(find.text('header-marker')).dy;
    final entryY = tester.getTopLeft(find.text('Face #1')).dy;
    expect(headerY, lessThan(entryY));

    await tester.tap(find.widgetWithIcon(IconButton, Icons.close));
    expect(removed, entity);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Fix 5: the sheet content clears the FAB column with right padding', (tester) async {
    const entity = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 2);
    await tester.pumpWidget(
      _hostedDrawer(
        SelectionListDrawer(selectedEntities: {entity}, onRemove: (_) {}),
      ),
    );
    await tester.pump();

    // A plain `.first` would actually hit SafeArea's own internal Padding
    // (its EdgeInsets mirror the device's safe-area insets, zero in a test
    // environment) - it wraps our own explicit right-padding Padding as its
    // child, so this matches on the actual inset instead of positional
    // order.
    final padding = tester.widget<Padding>(
      find.descendant(
        of: find.byType(DraggableScrollableSheet),
        matching: find.byWidgetPredicate(
          (widget) => widget is Padding && (widget.padding as EdgeInsets).right == 72,
        ),
      ),
    );
    expect((padding.padding as EdgeInsets).right, 72);
    expect(tester.takeException(), isNull);
  });

  testWidgets('item 6: no clear-all button unless onClearAll is given', (tester) async {
    await tester.pumpWidget(
      _hostedDrawer(
        SelectionListDrawer(
          selectedEntities: {const SelectionEntityRef(kind: SelectionEntityKind.face, id: 1)},
          onRemove: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Clear selection'), findsNothing);
  });

  testWidgets('item 6: the clear-all X sits next to the drag handle and fires onClearAll', (tester) async {
    var cleared = 0;
    await tester.pumpWidget(
      _hostedDrawer(
        SelectionListDrawer(
          selectedEntities: {
            const SelectionEntityRef(kind: SelectionEntityKind.face, id: 1),
            const SelectionEntityRef(kind: SelectionEntityKind.face, id: 2),
          },
          onRemove: (_) {},
          onClearAll: () => cleared++,
        ),
      ),
    );
    await tester.pump();

    expect(find.byTooltip('Clear selection'), findsOneWidget);
    // Clearing all is distinct from the per-row "Remove from selection" X.
    expect(find.byTooltip('Remove from selection'), findsNWidgets(2));
    await tester.tap(find.byTooltip('Clear selection'));
    await tester.pump();
    expect(cleared, 1);
  });
}
