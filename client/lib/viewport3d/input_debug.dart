import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controls_preferences.dart';
import 'mouse_navigation.dart';

/// F-1 step 0 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): a one-line input debug overlay for the 3D viewport,
/// behind Controls > "Show input debug" (off by default). It exists to NAME the cause of "Ctrl/Shift + middle drag
/// sometimes orbits": for the last pointer event it shows the device kind, the buttons as bits, what [HardwareKeyboard]
/// says about Ctrl and Shift, the [MouseNavAction] the table picks from them and the viewport's active nav pointer.
/// The same line goes to `debugPrint` (read it with `adb logcat`). No behaviour changes: this only observes.
class InputDebug {
  InputDebug._();

  /// The latest line, or null before any event (the overlay shows a hint then).
  static final ValueNotifier<String?> last = ValueNotifier<String?>(null);

  /// One line for [event]: `down mouse buttons=0b100 ctrl=true shift=false -> pan nav=3`.
  /// Pure apart from the [control] / [shift] / [action] it is handed, so it is unit tested.
  static String format({
    required String phase,
    required PointerDeviceKind kind,
    required int buttons,
    required bool control,
    required bool shift,
    required MouseNavAction? action,
    required int? navPointer,
    int? pointer,
  }) =>
      '$phase ${kind.name} p=${pointer ?? '-'} buttons=0b${buttons.toRadixString(2).padLeft(3, '0')} '
      'ctrl=$control shift=$shift -> ${action?.name ?? 'none'} nav=${navPointer ?? '-'}';

  /// The key side of the same question ("ctrl always said false"): does Flutter receive the key events at all? `keys=N last=KEY
  /// pressed=[LABELS]`. If Ctrl is held and `keys` does not move, the key events never reach the app (Android window / view focus), which
  /// no pointer-handling change can fix; if they arrive, the problem is in how they are read.
  static final ValueNotifier<String> keyLine = ValueNotifier<String>('keys=0 (press a key here)');
  static int _keyCount = 0;
  static String _lastKey = '-';
  static bool _watching = false;

  static bool _onKey(KeyEvent event) {
    _keyCount++;
    _lastKey = '${event.logicalKey.keyLabel.isEmpty ? event.logicalKey.debugName : event.logicalKey.keyLabel} ${event.runtimeType.toString().replaceAll('Key', '').replaceAll('Event', '').toLowerCase()}';
    final pressed = HardwareKeyboard.instance.logicalKeysPressed.map((k) => k.debugName ?? k.keyLabel).join('+');
    keyLine.value = 'keys=$_keyCount last=$_lastKey pressed=[$pressed]';
    debugPrint('DIDSA key: ${keyLine.value}');
    return false; // observe only
  }

  /// Starts counting key events (idempotent). Called by the overlay.
  static void startKeyWatch() {
    if (_watching) return;
    _watching = true;
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// For tests: forget the counters.
  static void resetKeyWatch() {
    if (_watching) HardwareKeyboard.instance.removeHandler(_onKey);
    _watching = false;
    _keyCount = 0;
    _lastKey = '-';
    keyLine.value = 'keys=0 (press a key here)';
  }

  /// Records [event] when the setting is on. [navPointer] is the viewport's `_mouseNavPointer`.
  static void note(String phase, PointerEvent event, {required int? navPointer}) {
    if (!ControlsPreferences.showInputDebug) return;
    final keyboard = HardwareKeyboard.instance;
    final line = format(
      phase: phase,
      kind: event.kind,
      buttons: event.buttons,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      action: mouseNavActionForEvent(event),
      navPointer: navPointer,
      pointer: event.pointer,
    );
    last.value = line;
    debugPrint('DIDSA input: $line');
  }
}

/// The overlay: small monospace text, bottom left, never takes a pointer.
class InputDebugOverlay extends StatefulWidget {
  const InputDebugOverlay({super.key});

  @override
  State<InputDebugOverlay> createState() => _InputDebugOverlayState();
}

class _InputDebugOverlayState extends State<InputDebugOverlay> {
  @override
  void initState() {
    super.initState();
    InputDebug.startKeyWatch();
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Color(0xFFFFFFFF), fontSize: 11, fontFamily: 'monospace');
    return IgnorePointer(
      child: Container(
        key: const ValueKey('input-debug-overlay'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        color: const Color(0xCC000000),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: InputDebug.last,
              builder: (context, line, _) => Text(line ?? 'input debug: move or press the mouse here', style: style),
            ),
            ValueListenableBuilder<String>(
              valueListenable: InputDebug.keyLine,
              builder: (context, line, _) => Text(line, style: style),
            ),
          ],
        ),
      ),
    );
  }
}
