import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/mouse_navigation.dart';

/// Desktop input D1 (`docs/desktop-input-scope.md`): the SOLIDWORKS-style
/// mouse bindings and the wheel/drag zoom factors every canvas shares.
void main() {
  group('mouseNavActionFor', () {
    test('middle drag orbits; Ctrl+middle pans; Shift+middle zooms', () {
      expect(mouseNavActionFor(kMiddleMouseButton, control: false, shift: false), MouseNavAction.orbit);
      expect(mouseNavActionFor(kMiddleMouseButton, control: true, shift: false), MouseNavAction.pan);
      expect(mouseNavActionFor(kMiddleMouseButton, control: false, shift: true), MouseNavAction.zoom);
    });

    test('right drag pans, with or without modifiers', () {
      expect(mouseNavActionFor(kSecondaryMouseButton, control: false, shift: false), MouseNavAction.pan);
      expect(mouseNavActionFor(kSecondaryMouseButton, control: true, shift: true), MouseNavAction.pan);
    });

    test('middle wins over right when both are held', () {
      expect(
        mouseNavActionFor(kMiddleMouseButton | kSecondaryMouseButton, control: false, shift: false),
        MouseNavAction.orbit,
      );
    });

    test('left button and no button stay with the canvas', () {
      expect(mouseNavActionFor(kPrimaryMouseButton, control: false, shift: false), isNull);
      expect(mouseNavActionFor(kPrimaryMouseButton, control: true, shift: true), isNull);
      expect(mouseNavActionFor(0, control: false, shift: false), isNull);
    });
  });

  testWidgets('mouseNavActionForEvent ignores touch and reads the live modifiers', (tester) async {
    const touch = PointerMoveEvent(kind: PointerDeviceKind.touch, buttons: kMiddleMouseButton);
    expect(mouseNavActionForEvent(touch), isNull);

    const mouse = PointerMoveEvent(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    expect(mouseNavActionForEvent(mouse), MouseNavAction.orbit);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(mouseNavActionForEvent(mouse), MouseNavAction.pan);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(mouseNavActionForEvent(mouse), MouseNavAction.orbit);
  });

  test('isMouseNavPress: middle or right mouse press only', () {
    expect(isMouseNavPress(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton)), isTrue);
    expect(
      isMouseNavPress(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton)),
      isTrue,
    );
    expect(isMouseNavPress(const PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kPrimaryMouseButton)), isFalse);
    expect(isMouseNavPress(const PointerDownEvent(kind: PointerDeviceKind.touch, buttons: kPrimaryButton)), isFalse);
  });

  group('wheelZoomFactor', () {
    test('one notch (or more) keeps the old 10 % per event', () {
      expect(wheelZoomFactor(kWheelNotchPixels), closeTo(1.1, 1e-9));
      expect(wheelZoomFactor(-kWheelNotchPixels), closeTo(1 / 1.1, 1e-9));
      expect(wheelZoomFactor(120), closeTo(1.1, 1e-9), reason: 'never more than one notch per event');
    });

    test('a small trackpad delta zooms in proportion', () {
      final small = wheelZoomFactor(kWheelNotchPixels / 10);
      expect(small, greaterThan(1));
      expect(small, lessThan(1.011));
      // Ten tenth-notch events add up to one notch.
      var total = 1.0;
      for (var i = 0; i < 10; i++) {
        total *= wheelZoomFactor(kWheelNotchPixels / 10);
      }
      expect(total, closeTo(1.1, 1e-9));
    });

    test('no scroll, no zoom', () {
      expect(wheelZoomFactor(0), 1);
    });
  });

  test('dragZoomFactor: up zooms in, down zooms out, and they cancel', () {
    expect(dragZoomFactor(-20), lessThan(1));
    expect(dragZoomFactor(20), greaterThan(1));
    expect(dragZoomFactor(20) * dragZoomFactor(-20), closeTo(1, 1e-9));
  });

  test('cursor per action', () {
    expect(mouseNavCursor(MouseNavAction.orbit), SystemMouseCursors.allScroll);
    expect(mouseNavCursor(MouseNavAction.pan), SystemMouseCursors.grabbing);
    expect(mouseNavCursor(MouseNavAction.zoom), SystemMouseCursors.zoomIn);
  });
}
