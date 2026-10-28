import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` R6): Up / Down, and the
/// mouse wheel while the pointer is over the field, nudge the value in a
/// focused text field that holds a number - Fusion 360's habit, and what a
/// desktop user expects of a number field. One step is 1; Shift makes it 10
/// and Ctrl 0.1. It works through the focused field's own
/// `userUpdateTextEditingValue`, so the panel's `onChanged` hears about it
/// exactly as if the number had been typed - no panel needs to know.
class NumberFieldNudge {
  NumberFieldNudge._();

  /// Scroll distance (logical pixels) per step, so a trackpad's stream of
  /// small deltas steps once per [wheelStepPixels] rather than once per event.
  static const double wheelStepPixels = 50;

  static int _installs = 0;
  static double _wheelRemainder = 0;

  /// Starts listening for the wheel (counted: each [install] needs an
  /// [uninstall]). The key side is called by `CadShortcutScope`.
  static void install() {
    if (_installs++ == 0) GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointerEvent);
  }

  static void uninstall() {
    if (--_installs == 0) GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointerEvent);
  }

  static EditableTextState? _focusedField() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return null;
    if (context is StatefulElement && context.state is EditableTextState) return context.state as EditableTextState;
    return context.findAncestorStateOfType<EditableTextState>();
  }

  /// Steps the focused number field by [steps] (negative = down), scaled by
  /// the held modifiers. Returns whether a field took it - false when no
  /// field has focus, or its text is not a number.
  static bool nudge(double steps) {
    final state = _focusedField();
    if (state == null || state.widget.maxLines != 1) return false;
    final text = state.textEditingValue.text.trim();
    final value = double.tryParse(text);
    if (value == null || !value.isFinite) return false;
    final keyboard = HardwareKeyboard.instance;
    final scale = keyboard.isShiftPressed ? 10.0 : (keyboard.isControlPressed ? 0.1 : 1.0);
    final next = value + steps * scale;
    final point = text.indexOf('.');
    final typedDecimals = point < 0 ? 0 : text.length - point - 1;
    final decimals = math.max(typedDecimals, scale < 1 ? 1 : 0).clamp(0, 8);
    final nextText = next.toStringAsFixed(decimals);
    state.userUpdateTextEditingValue(
      TextEditingValue(text: nextText, selection: TextSelection.collapsed(offset: nextText.length)),
      SelectionChangedCause.keyboard,
    );
    return true;
  }

  static void _onPointerEvent(PointerEvent event) {
    if (event is! PointerScrollEvent) return;
    final state = _focusedField();
    if (state == null) return;
    final box = state.context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    if (!(box.localToGlobal(Offset.zero) & box.size).contains(event.position)) return;
    _wheelRemainder += event.scrollDelta.dy;
    while (_wheelRemainder.abs() >= wheelStepPixels) {
      // Scrolling up (negative dy) raises the value.
      final up = _wheelRemainder < 0;
      _wheelRemainder += up ? wheelStepPixels : -wheelStepPixels;
      if (!nudge(up ? 1 : -1)) {
        _wheelRemainder = 0;
        return;
      }
    }
  }
}
