import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/action_sheet.dart';

enum _Pick { first, second }

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): the shared
/// right-click menu helper - a popup at the cursor for a mouse, the
/// unchanged bottom sheet without a position - and the right-click region.
void main() {
  Future<_Pick?>? pending;

  Future<void> open(WidgetTester tester, List<ActionSheetEntry<_Pick>> entries, {Offset? at}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pending = showContextMenu<_Pick>(context, entries, at: at),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('showContextMenu', () {
    testWidgets('with a position it shows a popup menu there, not the bottom sheet', (tester) async {
      await open(tester, const [
        ActionSheetEntry(action: _Pick.first, label: 'First', icon: Icons.add, shortcut: 'Ctrl+1'),
        ActionSheetEntry(action: _Pick.second, label: 'Second', icon: Icons.remove, dividerBefore: true),
      ], at: const Offset(300, 200));
      expect(find.byType(PopupMenuItem<_Pick>), findsNWidgets(2));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Ctrl+1'), findsOneWidget, reason: 'the shortcut hint');
      expect(find.byType(PopupMenuDivider), findsOneWidget);
      final topLeft = tester.getTopLeft(find.byType(PopupMenuItem<_Pick>).first);
      expect((topLeft - const Offset(300, 200)).distance, lessThan(40));
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(await pending, _Pick.second);
    });

    testWidgets('without a position it is the bottom sheet, as before', (tester) async {
      await open(tester, const [
        ActionSheetEntry(action: _Pick.first, label: 'First', icon: Icons.add, shortcut: 'Ctrl+1'),
      ]);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(PopupMenuItem<_Pick>), findsNothing);
      expect(find.text('Ctrl+1'), findsNothing, reason: 'touch has no key hints');
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(await pending, _Pick.first);
    });

    testWidgets('a disabled popup row does nothing when clicked and carries its reason as a tooltip', (tester) async {
      await open(tester, const [
        ActionSheetEntry(
          action: _Pick.first,
          label: 'First',
          icon: Icons.add,
          enabled: false,
          disabledReason: 'Coming soon',
        ),
        ActionSheetEntry(action: _Pick.second, label: 'Second', icon: Icons.remove),
      ], at: const Offset(300, 200));
      expect(find.byTooltip('Coming soon'), findsOneWidget);
      await tester.tap(find.text('First'));
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<_Pick>), findsNWidgets(2), reason: 'still open');
      await tester.tap(find.text('Second'));
      await tester.pumpAndSettle();
      expect(await pending, _Pick.second);
    });

    testWidgets('a leading widget and colours are used in both presentations', (tester) async {
      const marker = Key('leading');
      for (final at in <Offset?>[null, const Offset(300, 200)]) {
        await open(tester, const [
          ActionSheetEntry(
            action: _Pick.first,
            label: 'First',
            leading: SizedBox(key: marker, width: 24, height: 24),
            labelColor: Colors.red,
          ),
        ], at: at);
        expect(find.byKey(marker), findsOneWidget);
        expect(tester.widget<Text>(find.text('First')).style?.color, Colors.red);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
    });
  });

  group('MouseContextMenuRegion', () {
    Future<List<Offset>> pumpRegion(WidgetTester tester) async {
      final opened = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: MouseContextMenuRegion(
                onOpen: opened.add,
                child: const SizedBox(width: 100, height: 100, child: ColoredBox(color: Colors.blue)),
              ),
            ),
          ),
        ),
      );
      return opened;
    }

    testWidgets('a mouse right click calls onOpen with the global position', (tester) async {
      final opened = await pumpRegion(tester);
      final target = tester.getCenter(find.byType(ColoredBox).last);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await gesture.down(target);
      await gesture.up();
      await tester.pump();
      expect(opened, [target]);
    });

    testWidgets('a mouse left click and a touch long-press do not', (tester) async {
      final opened = await pumpRegion(tester);
      final target = tester.getCenter(find.byType(ColoredBox).last);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.down(target);
      await mouse.up();
      await tester.pump();
      await tester.longPressAt(target);
      await tester.pump();
      expect(opened, isEmpty);
    });
  });
}
