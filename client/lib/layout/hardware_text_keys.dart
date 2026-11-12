import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Owner's bug report, 12 Nov 2026 (Samsung DeX, external monitor): in every
/// text field tried (a sketch dimension's value, the Extrude depth) Esc and
/// Backspace worked but no character could be typed, from a hardware keyboard
/// or the on-screen one; the phone screen was fine.
///
/// On Android a typed character normally reaches a text field through the
/// keyboard app's input connection, never as a key event the framework acts
/// on, while Esc and Backspace are handled by the framework itself. "Those
/// work, characters do not" is what a field looks like when key events arrive
/// but the input connection delivers nothing. Why the connection is dead on
/// DeX is NOT known (not reproduced off the device).
///
/// This sits above the whole app (`MaterialApp.builder`). When a key event
/// that carries a printable character reaches it unhandled while a text field
/// has focus, it types the character into that field, through the field's own
/// `userUpdateTextEditingValue` so formatters and `onChanged` run as for any
/// typed text. That is what the Android embedding does itself with a key the
/// keyboard app did not take, when its input connection is alive, so on a
/// healthy device the result is the same and it cannot double up: a key the
/// keyboard app consumed never gets here, and a key reported handled here is
/// not passed on to the input connection. Android only; elsewhere it does
/// nothing.
class HardwareTextKeys extends StatelessWidget {
  const HardwareTextKeys({super.key, required this.child});

  final Widget child;

  /// How many characters this has typed since the app started (for the input
  /// debug overlay and `adb logcat`: it says whether this path is in use).
  static final ValueNotifier<int> typedCount = ValueNotifier<int>(0);

  /// The text [event] types, or null when it is not a plain character press:
  /// a key up, a press with Ctrl / Alt / Meta held, or a control character
  /// (Enter, Tab, Esc, Backspace, Delete).
  @visibleForTesting
  static String? characterFor(KeyEvent event, {required bool modifierHeld}) {
    if (event is KeyUpEvent || modifierHeld) return null;
    final character = event.character;
    if (character == null || character.isEmpty) return null;
    for (final unit in character.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return null;
    }
    return character;
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

  static EditableTextState? _focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
    return context.findAncestorStateOfType<EditableTextState>();
  }

  static KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (defaultTargetPlatform != TargetPlatform.android) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final character = characterFor(
      event,
      modifierHeld: keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed,
    );
    if (character == null) return KeyEventResult.ignored;
    final field = _focusedField();
    if (field == null || field.widget.readOnly) return KeyEventResult.ignored;
    field.userUpdateTextEditingValue(typed(field.textEditingValue, character), SelectionChangedCause.keyboard);
    typedCount.value++;
    debugPrint('DIDSA key: typed from a key event (${typedCount.value})');
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
