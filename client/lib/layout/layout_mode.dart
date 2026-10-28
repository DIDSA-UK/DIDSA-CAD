import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../viewport3d/controls_preferences.dart';

/// Desktop layout (D6, `docs/desktop-layout-scope.md` section 1): whether the
/// app lays itself out for a phone (touch, one panel at a time) or a desktop
/// (a ribbon, a docked tree and a status bar around the viewport).
enum LayoutMode { phone, desktop }

/// The Controls setting: follow the window and the pointer, or force a layout.
enum LayoutPreference {
  automatic('Automatic', 'Desktop layout in a large window used with a mouse, phone layout otherwise.'),
  desktop('Always desktop', 'The ribbon and docked panels at any window size.'),
  phone('Always phone', 'The touch layout, even in a large window.');

  const LayoutPreference(this.label, this.description);

  final String label;
  final String description;
}

/// Window size at which the automatic layout becomes desktop.
const Size kDesktopLayoutEnterSize = Size(1000, 600);

/// Once desktop, the layout stays desktop until the window is narrower than
/// this (so dragging a window across the line doesn't flip back and forth).
const double kDesktopLayoutLeaveWidth = 900;
const double kDesktopLayoutLeaveHeight = 520;

/// Picks the layout. Pure, so the rules are unit tested.
///
/// [mouseActive] is true while the last pointer used was a mouse (or, with no
/// pointer seen yet, on a platform that is a desktop). [current] is the layout
/// in force now, for the hysteresis.
LayoutMode resolveLayoutMode({
  required LayoutPreference preference,
  required Size windowSize,
  required bool mouseActive,
  required LayoutMode current,
}) {
  switch (preference) {
    case LayoutPreference.desktop:
      return LayoutMode.desktop;
    case LayoutPreference.phone:
      return LayoutMode.phone;
    case LayoutPreference.automatic:
      if (!mouseActive) return LayoutMode.phone;
      if (current == LayoutMode.desktop) {
        return windowSize.width >= kDesktopLayoutLeaveWidth && windowSize.height >= kDesktopLayoutLeaveHeight
            ? LayoutMode.desktop
            : LayoutMode.phone;
      }
      return windowSize.width >= kDesktopLayoutEnterSize.width && windowSize.height >= kDesktopLayoutEnterSize.height
          ? LayoutMode.desktop
          : LayoutMode.phone;
  }
}

/// Tracks the window size, the kind of the last pointer and the Controls
/// preference, and works out the [mode].
class LayoutModeController extends ChangeNotifier {
  LayoutModeController({
    LayoutPreference? preference,
    Size windowSize = Size.zero,
    bool? mouseActive,
  })  : _preference = preference ?? ControlsPreferences.layoutPreference,
        _windowSize = windowSize,
        _mouseActive = mouseActive ?? _platformIsDesktop {
    _mode = resolveLayoutMode(
      preference: _preference,
      windowSize: _windowSize,
      mouseActive: _mouseActive,
      current: LayoutMode.phone,
    );
  }

  static bool get _platformIsDesktop => switch (defaultTargetPlatform) {
        TargetPlatform.linux || TargetPlatform.windows || TargetPlatform.macOS => true,
        _ => false,
      };

  LayoutPreference _preference;
  Size _windowSize;
  bool _mouseActive;
  late LayoutMode _mode;

  LayoutMode get mode => _mode;
  LayoutPreference get preference => _preference;
  bool get isDesktop => _mode == LayoutMode.desktop;

  /// True while the last pointer used was a mouse or trackpad.
  bool get mouseActive => _mouseActive;

  set preference(LayoutPreference value) {
    if (_preference == value) return;
    _preference = value;
    _recompute();
  }

  void noteWindowSize(Size size) {
    if (size == _windowSize) return;
    _windowSize = size;
    _recompute();
  }

  /// A pointer was seen: a mouse (or trackpad) means mouse use, a touch or a
  /// pen means touch use. A stylus counts as touch, as it has no hover
  /// buttons to speak of.
  void notePointer(PointerDeviceKind kind) {
    final mouse = kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;
    if (mouse == _mouseActive) return;
    _mouseActive = mouse;
    final before = _mode;
    _recompute();
    // The mode may be unchanged (a forced layout), but what a screen does with a mouse differs from a touch.
    if (_mode == before) notifyListeners();
  }

  void _recompute() {
    final next = resolveLayoutMode(
      preference: _preference,
      windowSize: _windowSize,
      mouseActive: _mouseActive,
      current: _mode,
    );
    if (next == _mode) return;
    _mode = next;
    notifyListeners();
  }
}

/// Makes the [LayoutModeController] available below it. Without one (a widget
/// test that pumps a screen on its own) every screen is the phone layout, so
/// the existing tests are unaffected.
class LayoutModeScope extends InheritedNotifier<LayoutModeController> {
  const LayoutModeScope({super.key, required LayoutModeController controller, required super.child})
      : super(notifier: controller);

  static LayoutMode modeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutModeScope>()?.notifier?.mode ?? LayoutMode.phone;

  static LayoutModeController? controllerOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<LayoutModeScope>()?.notifier;

  /// Whether the last pointer was a mouse, rebuilding the caller when that changes. False with no host.
  static bool mouseActiveOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutModeScope>()?.notifier?.mouseActive ?? false;

  static bool isDesktop(BuildContext context) => modeOf(context) == LayoutMode.desktop;
}

/// Goes in `MaterialApp.builder`: watches the window and the pointers, owns
/// the controller, and gives a desktop layout compact controls.
class LayoutModeHost extends StatefulWidget {
  const LayoutModeHost({super.key, required this.child, this.controller});

  final Widget child;

  /// For tests; the app lets the host make its own.
  final LayoutModeController? controller;

  @override
  State<LayoutModeHost> createState() => _LayoutModeHostState();
}

class _LayoutModeHostState extends State<LayoutModeHost> {
  late final LayoutModeController _controller = widget.controller ?? LayoutModeController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _controller.noteWindowSize(MediaQuery.sizeOf(context));
    return LayoutModeScope(
      controller: _controller,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) => _controller.notePointer(event.kind),
        onPointerHover: (event) => _controller.notePointer(event.kind),
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, child) {
            if (!_controller.isDesktop) return child!;
            return Theme(
              data: Theme.of(context).copyWith(visualDensity: VisualDensity.compact),
              child: child!,
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}
