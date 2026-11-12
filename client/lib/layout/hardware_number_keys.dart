import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Owner's bug report, 12 Nov 2026 (Samsung DeX, external monitor): in a
/// dimension's value box Backspace deleted text but no number could be typed,
/// from a hardware keyboard or the on-screen one; the phone screen was fine.
///
/// On Android a typed character normally reaches a text field through the
/// keyboard app's input connection, never as a key event the framework acts
/// on, while Backspace is also handled by the framework's own text shortcuts.
/// "Backspace works, digits do not" is what a field looks like when key
/// events arrive but the input connection delivers nothing. Why the
/// connection is dead on DeX is NOT known (not reproduced off the device).
///
/// This wraps a number field and types the digit itself when a digit, `.`,
/// `,` or `-` key event reaches the field unhandled. It cannot double up: a
/// key the keyboard app consumed never gets here, and a key reported handled
/// here is not passed on to the input connection by the Android embedding.
/// Android only; elsewhere it does nothing.
class HardwareNumberKeys extends StatelessWidget {
  const HardwareNumberKeys({super.key, required this.controller, required this.child});

  /// The wrapped field's controller.
  final TextEditingController controller;

  /// The text field (it keeps its own focus node).
  final Widget child;

  /// The character [event] types into a number field, or null when it is not
  /// one this widget handles. A decimal comma becomes a point (the value is
  /// read with `double.tryParse`).
  @visibleForTesting
  static String? characterFor(KeyEvent event, {required bool modifierHeld}) {
    if (event is KeyUpEvent || modifierHeld) return null;
    final character = event.character;
    if (character == null || character.length != 1) return null;
    if (character == ',') return '.';
    return '0123456789.-'.contains(character) ? character : null;
  }

  /// [value] with [character] typed at the caret, replacing any selection.
  @visibleForTesting
  static TextEditingValue typed(TextEditingValue value, String character) {
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start.clamp(0, text.length) : text.length;
    final end = selection.isValid ? selection.end.clamp(0, text.length) : text.length;
    return TextEditingValue(
      text: text.replaceRange(start, end, character),
      selection: TextSelection.collapsed(offset: start + character.length),
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.android) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final character = characterFor(
      event,
      modifierHeld: keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed,
    );
    if (character == null) return KeyEventResult.ignored;
    controller.value = typed(controller.value, character);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        child: child,
      );
}
