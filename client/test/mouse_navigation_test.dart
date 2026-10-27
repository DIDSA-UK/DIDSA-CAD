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

  group('MiddleDoubleClickDetector (desktop input D2)', () {
    PointerDownEvent press(int ms, {Offset at = const Offset(10, 10), int buttons = kMiddleMouseButton}) =>
        PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: buttons, position: at, timeStamp: Duration(milliseconds: ms));

    test('two quick middle presses in the same spot are a double-click', () {
      final detector = MiddleDoubleClickDetector();
      expect(detector.registerPress(press(0)), isFalse);
      expect(detector.registerPress(press(150)), isTrue);
      expect(detector.registerPress(press(200)), isFalse, reason: 'a third press starts again');
    });

    test('too slow, too far apart, or another button in between is not', () {
      final detector = MiddleDoubleClickDetector();
      detector.registerPress(press(0));
      expect(detector.registerPress(press(1000)), isFalse);
      expect(detector.registerPress(press(1100, at: const Offset(400, 400))), isFalse);
      detector.registerPress(press(2000));
      detector.registerPress(press(2050, buttons: kPrimaryMouseButton));
      expect(detector.registerPress(press(2100)), isFalse);
    });
  });

  test('selectClickFor: mouse replaces, Ctrl+mouse toggles, anything else is touch', () {
    expect(selectClickFor(PointerDeviceKind.touch), SelectClick.touch);
    expect(selectClickFor(PointerDeviceKind.stylus), SelectClick.touch);
    expect(selectClickFor(null), SelectClick.touch);
  });

  testWidgets('selectClickFor reads Ctrl live', (tester) async {
    expect(selectClickFor(PointerDeviceKind.mouse), SelectClick.replace);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    expect(selectClickFor(PointerDeviceKind.mouse), SelectClick.toggle);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  });

  group('selectionAfterClick (desktop input D2/D3: the part screen click rule)', () {
    test('a plain mouse click with no tool open replaces', () {
      expect(selectionAfterClick({'a', 'b'}, 'c', SelectClick.replace, collecting: false), {'c'});
      expect(selectionAfterClick({'a', 'b'}, 'a', SelectClick.replace, collecting: false), {'a'});
    });

    test('inside a tool a plain mouse click keeps collecting (toggles)', () {
      expect(selectionAfterClick({'a'}, 'b', SelectClick.replace, collecting: true), {'a', 'b'});
      expect(selectionAfterClick({'a', 'b'}, 'b', SelectClick.replace, collecting: true), {'a'});
    });

    test('Ctrl+click and touch toggle, tool or not', () {
      for (final click in [SelectClick.toggle, SelectClick.touch]) {
        for (final collecting in [false, true]) {
          expect(selectionAfterClick({'a'}, 'b', click, collecting: collecting), {'a', 'b'});
          expect(selectionAfterClick({'a', 'b'}, 'a', click, collecting: collecting), {'b'});
        }
      }
    });

    test('never changes the set it was given', () {
      final current = {'a'};
      selectionAfterClick(current, 'b', SelectClick.toggle, collecting: false);
      expect(current, {'a'});
    });
  });
}

