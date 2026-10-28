import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/resizable_tool_panel.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` R6): Tab moves through a
/// tool panel's fields in reading order and stays inside the panel's group,
/// not out to the buttons around the viewport.
void main() {
  testWidgets('Tab stays inside the panel: first field, second field, then its button - never a control outside', (tester) async {
    final first = FocusNode(), second = FocusNode(), outside = FocusNode();
    addTearDown(() {
      first.dispose();
      second.dispose();
      outside.dispose();
    });
    final outsideTop = ValueNotifier<double>(0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<double>(
            valueListenable: outsideTop,
            builder: (context, top, _) => Stack(
              children: [
                ResizableToolPanel(
                  title: 'Test tool',
                  child: Column(
                    children: [
                      TextField(focusNode: first),
                      TextField(focusNode: second),
                      TextButton(onPressed: () {}, child: const Text('Confirm')),
                    ],
                  ),
                ),
                // A control outside the panel, sitting between its two fields in reading order.
                Positioned(left: 0, top: top, child: SizedBox(width: 100, child: TextField(focusNode: outside))),
              ],
            ),
          ),
        ),
      ),
    );
    outsideTop.value = tester.getRect(find.byWidgetPredicate((w) => w is TextField && w.focusNode == second)).top - 1;
    await tester.pump();

    first.requestFocus();
    await tester.pump();
    expect(first.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(second.hasFocus, isTrue, reason: 'the control outside the panel is skipped');
    expect(outside.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>(), isNotNull);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(second.hasFocus, isTrue);
  });
}
