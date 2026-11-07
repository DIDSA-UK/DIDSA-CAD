import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/viewport3d/component_selection_toolbar.dart';

void main() {
  Future<void> pump(WidgetTester tester, {VoidCallback? onEdit}) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ComponentSelectionToolbar(fixed: false, onEdit: onEdit, onMove: () {}, onFixFloat: () {}, onDelete: () {}),
          ),
        ),
      );

  testWidgets('Edit Alone is the first button and calls back', (tester) async {
    var edits = 0;
    await pump(tester, onEdit: () => edits++);
    final edit = find.byKey(const ValueKey('component-toolbar-edit-alone'));
    expect(edit, findsOneWidget);
    expect(tester.getTopLeft(edit).dx, lessThan(tester.getTopLeft(find.text('Move')).dx));
    await tester.tap(edit);
    expect(edits, 1);
  });

  testWidgets('without onEdit there is no Edit Alone button', (tester) async {
    await pump(tester);
    expect(find.text('Edit Alone'), findsNothing);
  });
}
