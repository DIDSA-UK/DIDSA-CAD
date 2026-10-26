import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// What a mouse drag does to the view - see [mouseNavActionFor].
enum MouseNavAction { orbit, pan, zoom }

/// The mouse bindings every canvas shares (3D viewport, 2D sketch canvas,
/// mesh viewer), SOLIDWORKS-style - see `docs/desktop-input-scope.md` R1:
///
/// - middle drag: orbit (a 2D canvas pans instead - it has nothing to orbit)
/// - Ctrl+middle drag: pan
/// - Shift+middle drag: zoom
/// - right drag: pan (the owner's choice over SOLIDWORKS' mouse gestures -
///   pan with no keyboard attached)
///
/// Null for anything else (left button, or no button): those stay with the
/// canvas's own select/draw/orbit handling. Middle wins over right when
/// both are held. Modifiers are read live on every move by the callers
/// (pressing Ctrl mid-drag switches to pan, as SOLIDWORKS does).
MouseNavAction? mouseNavActionFor(int buttons, {required bool control, required bool shift}) {
  if (buttons & kMiddleMouseButton != 0) {
    if (control) return MouseNavAction.pan;
    if (shift) return MouseNavAction.zoom;
    return MouseNavAction.orbit;
  }
  if (buttons & kSecondaryMouseButton != 0) return MouseNavAction.pan;
  return null;
}

/// [mouseNavActionFor] with the modifiers read off the live keyboard state.
MouseNavAction? mouseNavActionForEvent(PointerEvent event) {
  if (event.kind != PointerDeviceKind.mouse) return null;
  final keyboard = HardwareKeyboard.instance;
  return mouseNavActionFor(event.buttons, control: keyboard.isControlPressed, shift: keyboard.isShiftPressed);
}

/// Whether a mouse press starts a view drag ([mouseNavActionFor] non-null
/// for its buttons, whatever the modifiers) rather than a click.
bool isMouseNavPress(PointerDownEvent event) =>
    event.kind == PointerDeviceKind.mouse && event.buttons & (kMiddleMouseButton | kSecondaryMouseButton) != 0;

/// Scroll distance (logical pixels) treated as one wheel notch. Flutter
/// reports a notch as roughly 50-120 px depending on the platform (Android
/// uses the system scroll factor, about 64), so one notch keeps the full
/// per-notch zoom it always had, while a trackpad's or smooth-scroll
/// wheel's stream of small deltas zooms in proportion instead of a full
/// notch per event.
const double kWheelNotchPixels = 50;

/// Zoom factor for one scroll event, for canvases where a factor above 1
/// means zoomed *out* (the 3D lens zoom and the mesh viewer's distance):
/// scrolling down (positive [scrollDy]) zooms out by up to [perNotch] per
/// event, scaled down for deltas smaller than a notch. Never more than one
/// notch per event, so a platform that reports big notches doesn't zoom
/// faster than it used to.
double wheelZoomFactor(double scrollDy, {double perNotch = 1.1}) {
  if (scrollDy == 0) return 1;
  final notches = (scrollDy.abs() / kWheelNotchPixels).clamp(0.0, 1.0);
  final factor = math.pow(perNotch, notches).toDouble();
  return scrollDy > 0 ? factor : 1 / factor;
}

/// Zoom factor for a Shift+middle drag of [dyPixels] (same "above 1 is
/// zoomed out" sense as [wheelZoomFactor]): dragging up zooms in, down
/// zooms out, about 10 % per 20 px.
double dragZoomFactor(double dyPixels) => math.pow(1.005, dyPixels).toDouble();

/// The system cursor shown while [action] is dragging the view.
MouseCursor mouseNavCursor(MouseNavAction action) => switch (action) {
      MouseNavAction.orbit => SystemMouseCursors.allScroll,
      MouseNavAction.pan => SystemMouseCursors.grabbing,
      MouseNavAction.zoom => SystemMouseCursors.zoomIn,
    };
