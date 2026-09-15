import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/action_sheet.dart';

enum _TestAction { first, second }

void main() {
  Future<_TestAction?>? pendingResult;

  Future<void> openSheet(WidgetTester tester, List<ActionSheetEntry<_TestAction>> entries) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pendingResult = showActionSheet<_TestAction>(context, entries),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showActionSheet', () {
    testWidgets('tapping an enabled row resolves its action', (tester) async {
      await openSheet(tester, const [
        ActionSheetEntry(action: _TestAction.first, label: 'First', icon: Icons.add),
        ActionSheetEntry(action: _TestAction.second, label: 'Second', icon: Icons.remove),
      ]);
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(await pendingResult, _TestAction.second);
    });

    testWidgets('a disabled row shows its disabledReason as a subtitle', (tester) async {
      await openSheet(tester, const [
        ActionSheetEntry(
          action: _TestAction.first,
          label: 'First',
          icon: Icons.add,
          enabled: false,
          disabledReason: 'Coming soon',
        ),
      ]);
      expect(find.text('Coming soon'), findsOneWidget);
      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.enabled, isFalse);
    });

    testWidgets('tapping a disabled row does nothing - the sheet stays open', (tester) async {
      await openSheet(tester, const [
        ActionSheetEntry(
          action: _TestAction.first,
          label: 'First',
          icon: Icons.add,
          enabled: false,
          disabledReason: 'Coming soon',
        ),
      ]);
      await tester.tap(find.text('First'), warnIfMissed: false);
      await tester.pumpAndSettle();
      // Still on the sheet - the row itself is still there.
      expect(find.text('First'), findsOneWidget);
    });

    testWidgets('an enabled row with no disabledReason has no subtitle', (tester) async {
      await openSheet(tester, const [
        ActionSheetEntry(action: _TestAction.first, label: 'First', icon: Icons.add),
      ]);
      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.subtitle, isNull);
      expect(tile.enabled, isTrue);
    });
  });
}
