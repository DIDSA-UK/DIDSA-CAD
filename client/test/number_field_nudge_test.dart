import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/keyboard_shortcuts.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` R6): Up / Down and the
/// wheel over a focused number field nudge its value; Shift = 10, Ctrl = 0.1.
void main() {
  late TextEditingController controller;
  late List<String> changes;
  var field = const Key('field');

  Future<void> pump(WidgetTester tester, {String text = '10', int? maxLines = 1}) async {
    controller = TextEditingController(text: text);
    changes = [];
    await tester.pumpWidget(
      MaterialApp(
        home: CadShortcutScope(
          bindings: () => const {},
          child: Scaffold(
            body: Column(
              children: [
                TextField(key: field, controller: controller, onChanged: changes.add, maxLines: maxLines),
                const SizedBox(height: 200),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(field));
    await tester.pump();
  }

  testWidgets('Up and Down step the number by 1 and report it as typed text', (tester) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(controller.text, '11');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(controller.text, '9');
    expect(changes, ['11', '10', '9'], reason: 'onChanged hears every step, as if it were typed');
  });

  testWidgets('Shift steps by 10, Ctrl by 0.1; decimals typed are kept', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.text, '20');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, '20.1');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(controller.text, '19.1', reason: 'the typed decimal place is kept');
  });

  testWidgets('a field that is not a number, or is multi-line, is left alone', (tester) async {
    await pump(tester, text: '12 mm');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(controller.text, '12 mm');
    expect(changes, isEmpty);

    await pump(tester, text: '5', maxLines: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(controller.text, '5');
  });

  testWidgets('the wheel over the focused field nudges it: up raises, down lowers, one notch is one step', (tester) async {
    await pump(tester);
    final centre = tester.getCenter(find.byKey(field));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(centre));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
    expect(controller.text, '11');
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 50)));
    expect(controller.text, '9');
    // Small trackpad deltas add up to a step rather than one step each.
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    expect(controller.text, '9');
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -20)));
    expect(controller.text, '10');
  });

  testWidgets('the wheel elsewhere on the screen leaves the field alone', (tester) async {
    await pump(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(400, 500)));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -50)));
    expect(controller.text, '10');
  });
}
