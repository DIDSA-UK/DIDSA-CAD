import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/layout/hardware_text_keys.dart';
import 'package:didsa_cad_client/viewport3d/keyboard_shortcuts.dart';

/// Owner's bug report, 12 Nov 2026 (Samsung DeX): text fields took Esc and Backspace but no characters.
/// [HardwareTextKeys] types a character key event that reaches the app unhandled while a field has focus (Android only).
void main() {
  late TextEditingController controller;
  late List<String> changes;

  Future<void> pump(WidgetTester tester, {String text = '25', bool readOnly = false, bool field = true}) async {
    controller = TextEditingController(text: text)..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    changes = [];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => HardwareTextKeys(child: child!),
        home: CadShortcutScope(
          bindings: () => const {},
          child: Scaffold(
            body: field
                ? TextField(controller: controller, autofocus: true, readOnly: readOnly, onChanged: changes.add)
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('on Android a character key event is typed over the selection, handled, and reported as a change', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '2'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.period, character: '.'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.numpad5, character: '5'), isTrue);
    expect(controller.text, '42.5');
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    expect(changes, ['4', '42', '42.', '42.5']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('letters are typed too, at the caret', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, text: 'Brcket');
    controller.selection = const TextSelection.collapsed(offset: 2);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyA, character: 'a'), isTrue);
    expect(controller.text, 'Bracket');
    expect(controller.selection, const TextSelection.collapsed(offset: 3));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Ctrl+key, a key with no character and a read-only field are left alone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1, character: '1'), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.f5), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.f5);
    expect(controller.text, '25');
    await pump(tester, readOnly: true);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4'), isFalse);
    expect(controller.text, '25');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('with no field focused the key is not taken (shortcuts still get it)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, field: false);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyL, character: 'l'), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('off Android the key is not taken (the platform delivers the text itself)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4'), isFalse);
    expect(controller.text, '25');
    debugDefaultTargetPlatformOverride = null;
  });

  test('control characters are not typed', () {
    const enter = KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.enter,
      logicalKey: LogicalKeyboardKey.enter,
      character: '\n',
      timeStamp: Duration.zero,
    );
    expect(HardwareTextKeys.characterFor(enter, modifierHeld: false), isNull);
  });
}
