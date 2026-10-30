import 'package:didsa_cad_client/viewport3d/start_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Start button and its quick column on their own: tap vs drag vs long press, the X, and the close-after-action rule.
void main() {
  late List<String> events;
  late bool enabled;
  late bool menuOpen;
  late bool showHint;
  late bool columnOpen;

  Widget harness() {
    return MaterialApp(
      home: Scaffold(
        body: const SizedBox.expand(),
        floatingActionButton: StatefulBuilder(
          builder: (context, setState) => StartButton(
            enabled: enabled,
            menuOpen: menuOpen,
            columnOpen: columnOpen,
            showSwipeHint: showHint,
            onStart: () => events.add('start'),
            onColumnOpenChanged: (open) {
              events.add(open ? 'open' : 'close');
              setState(() => columnOpen = open);
            },
            onColumnOpenedByUser: () => events.add('counted'),
            modeBadge: null,
            quickButtons: [
              for (final name in ['menu', 'fit', 'select'])
                QuickColumnButton(
                  key: ValueKey('quick-$name'),
                  tooltip: name,
                  child: Text(name),
                  onPressed: () => events.add('ran $name'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  final startFab = find.byKey(const ValueKey('start-fab'));

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  setUp(() {
    events = [];
    enabled = true;
    menuOpen = false;
    showHint = false;
    columnOpen = false;
  });

  testWidgets('a tap opens the Start menu and not the column', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(startFab);
    await settle(tester);
    expect(events, ['start']);
    expect(find.byKey(const ValueKey('quick-column')), findsNothing);
  });

  testWidgets('a swipe up past 24 dp opens the column, and is not also a tap', (tester) async {
    await tester.pumpWidget(harness());
    await tester.drag(startFab, const Offset(0, -60));
    await settle(tester);
    expect(events, ['counted', 'open']);
    expect(find.byKey(const ValueKey('quick-column')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-fit')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-select')), findsOneWidget);
  });

  testWidgets('a short, slow drag opens nothing and does not start the menu', (tester) async {
    await tester.pumpWidget(harness());
    await tester.drag(startFab, const Offset(0, -20));
    await settle(tester);
    expect(events, isEmpty);
    expect(find.byKey(const ValueKey('quick-column')), findsNothing);
  });

  testWidgets('a fling up opens the column', (tester) async {
    await tester.pumpWidget(harness());
    await tester.fling(startFab, const Offset(0, -30), 1500);
    await settle(tester);
    expect(events, ['counted', 'open']);
  });

  testWidgets('a long press opens the column', (tester) async {
    await tester.pumpWidget(harness());
    await tester.longPress(startFab);
    await settle(tester);
    expect(events, ['counted', 'open']);
    expect(find.byKey(const ValueKey('quick-column')), findsOneWidget);
  });

  testWidgets('a swipe sideways or down opens nothing', (tester) async {
    await tester.pumpWidget(harness());
    await tester.drag(startFab, const Offset(-80, 0));
    await tester.drag(startFab, const Offset(0, 60));
    await settle(tester);
    expect(events, isEmpty);
  });

  testWidgets('while open Start shows an X: a tap closes the column and never opens the menu', (tester) async {
    await tester.pumpWidget(harness());
    await tester.longPress(startFab);
    await settle(tester);
    expect(find.descendant(of: startFab, matching: find.byIcon(Icons.close)), findsOneWidget);
    events.clear();

    await tester.tap(startFab);
    await settle(tester);
    expect(events, ['close']);
    expect(find.byKey(const ValueKey('quick-column')), findsNothing);
    expect(find.descendant(of: startFab, matching: find.byIcon(Icons.close)), findsNothing);
  });

  testWidgets('a swipe down on the X closes the column', (tester) async {
    await tester.pumpWidget(harness());
    await tester.longPress(startFab);
    await settle(tester);
    events.clear();
    await tester.drag(startFab, const Offset(0, 60));
    await settle(tester);
    expect(events, ['close']);
  });

  testWidgets('every quick button runs and then closes the column', (tester) async {
    await tester.pumpWidget(harness());
    for (final name in ['menu', 'fit', 'select']) {
      await tester.longPress(startFab);
      await settle(tester);
      events.clear();
      await tester.tap(find.byKey(ValueKey('quick-$name')));
      await settle(tester);
      expect(events, ['ran $name', 'close'], reason: name);
      expect(find.byKey(const ValueKey('quick-column')), findsNothing, reason: name);
    }
  });

  testWidgets('the quick buttons are stacked with the first nearest the Start button', (tester) async {
    await tester.pumpWidget(harness());
    await tester.longPress(startFab);
    await settle(tester);
    final startTop = tester.getTopLeft(startFab).dy;
    final menuTop = tester.getTopLeft(find.byKey(const ValueKey('quick-menu'))).dy;
    final fitTop = tester.getTopLeft(find.byKey(const ValueKey('quick-fit'))).dy;
    final selectTop = tester.getTopLeft(find.byKey(const ValueKey('quick-select'))).dy;
    expect(menuTop, lessThan(startTop));
    expect(fitTop, lessThan(menuTop));
    expect(selectTop, lessThan(fitTop));
  });

  testWidgets('X also shows while the Start menu is open', (tester) async {
    menuOpen = true;
    await tester.pumpWidget(harness());
    expect(find.descendant(of: startFab, matching: find.byIcon(Icons.close)), findsOneWidget);
  });

  testWidgets('the swipe hint shows only while asked to and while the column is closed', (tester) async {
    showHint = true;
    await tester.pumpWidget(harness());
    expect(find.byKey(const ValueKey('start-swipe-hint')), findsOneWidget);
    await tester.longPress(startFab);
    await settle(tester);
    expect(find.byKey(const ValueKey('start-swipe-hint')), findsNothing);
  });

  testWidgets('a disabled button neither starts nor opens the column', (tester) async {
    enabled = false;
    await tester.pumpWidget(harness());
    await tester.tap(startFab, warnIfMissed: false);
    await tester.longPress(startFab, warnIfMissed: false);
    await tester.drag(startFab, const Offset(0, -60), warnIfMissed: false);
    await settle(tester);
    expect(events, isEmpty);
  });

  testWidgets('a mode glyph is drawn on the button while a mode is on', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          floatingActionButton: StartButton(
            enabled: true,
            menuOpen: false,
            columnOpen: false,
            onStart: () {},
            onColumnOpenChanged: (_) {},
            quickButtons: const [],
            modeBadge: const Icon(Icons.mouse),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('start-mode-badge')), findsOneWidget);
  });
}
