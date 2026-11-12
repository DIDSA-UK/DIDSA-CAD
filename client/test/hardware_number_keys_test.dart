import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/layout/hardware_number_keys.dart';
import 'package:didsa_cad_client/viewport3d/keyboard_shortcuts.dart';

/// Owner's bug report, 12 Nov 2026 (Samsung DeX): a dimension's value box took Backspace but no digits.
/// [HardwareNumberKeys] types a digit key event that reaches a number field unhandled (Android only).
void main() {
  late TextEditingController controller;

  Future<void> pump(WidgetTester tester, {String text = '25'}) async {
    controller = TextEditingController(text: text)..selection = TextSelection(baseOffset: 0, extentOffset: text.length);
    await tester.pumpWidget(
      MaterialApp(
        home: CadShortcutScope(
          bindings: () => const {},
          child: Scaffold(
            body: HardwareNumberKeys(
              controller: controller,
              child: TextField(controller: controller, autofocus: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('on Android a digit key event replaces the selected value and is reported handled', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '2'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.period, character: '.'), isTrue);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.numpad5, character: '5'), isTrue);
    expect(controller.text, '42.5');
    expect(controller.selection, const TextSelection.collapsed(offset: 4));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a decimal comma is typed as a point; letters and Ctrl+digit are left alone', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, text: '');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
    await tester.sendKeyEvent(LogicalKeyboardKey.comma, character: ',');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5, character: '5');
    expect(controller.text, '1.5');
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyL, character: 'l'), isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(await tester.sendKeyDownEvent(LogicalKeyboardKey.digit1, character: '1'), isFalse);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(controller.text, '1.5');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('typing goes in at the caret', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester, text: '15');
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '2');
    expect(controller.text, '125');
    expect(controller.selection, const TextSelection.collapsed(offset: 2));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('off Android the key is not taken (the platform delivers the text itself)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pump(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit4, character: '4'), isFalse);
    expect(controller.text, '25');
    debugDefaultTargetPlatformOverride = null;
  });
}
