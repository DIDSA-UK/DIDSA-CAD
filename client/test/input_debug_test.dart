import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/input_debug.dart';
import 'package:didsa_cad_client/viewport3d/mouse_navigation.dart';

// F-1 step 0: the input debug overlay and its setting. Observation only: no navigation behaviour is tested here
// because none changed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('format names kind, buttons as bits, Ctrl / Shift, the action and the nav pointer', () {
    final line = InputDebug.format(
      phase: 'down',
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
      control: true,
      shift: false,
      action: MouseNavAction.pan,
      navPointer: 3,
      pointer: 3,
    );
    expect(line, 'down mouse p=3 buttons=0b100 ctrl=true shift=false -> pan nav=3');
  });

  test('format with no action and no nav pointer says none / -', () {
    final line = InputDebug.format(
      phase: 'move',
      kind: PointerDeviceKind.touch,
      buttons: 0,
      control: false,
      shift: false,
      action: null,
      navPointer: null,
    );
    expect(line, 'move touch p=- buttons=0b000 ctrl=false shift=false -> none nav=-');
  });

  test('the setting is off by default, saves, loads and resets', () async {
    SharedPreferences.setMockInitialValues({});
    await ControlsPreferences.load();
    expect(ControlsPreferences.showInputDebug, isFalse);
    await ControlsPreferences.setShowInputDebug(true);
    await ControlsPreferences.load();
    expect(ControlsPreferences.showInputDebug, isTrue);
    await ControlsPreferences.reset();
    expect(ControlsPreferences.showInputDebug, isFalse);
  });

  test('note records nothing while the setting is off, and the live line (with the keyboard state) while on', () async {
    SharedPreferences.setMockInitialValues({});
    await ControlsPreferences.load();
    InputDebug.last.value = null;
    const event = PointerDownEvent(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton, pointer: 7);
    InputDebug.note('down', event, navPointer: null);
    expect(InputDebug.last.value, isNull);

    await ControlsPreferences.setShowInputDebug(true);
    InputDebug.note('down', event, navPointer: 7);
    expect(InputDebug.last.value, 'down mouse p=7 buttons=0b100 ctrl=false shift=false -> orbit nav=7');

    // A held Ctrl (a real key event through the binding) shows up as ctrl=true and pan.
    await simulateKeyDownEvent(LogicalKeyboardKey.controlLeft);
    InputDebug.note('down', event, navPointer: 7);
    expect(InputDebug.last.value, 'down mouse p=7 buttons=0b100 ctrl=true shift=false -> pan nav=7');
    await simulateKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await ControlsPreferences.reset();
  });

  testWidgets('the overlay shows a hint, then the latest line, and takes no pointer', (tester) async {
    InputDebug.last.value = null;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Stack(children: [Positioned(left: 8, bottom: 8, child: InputDebugOverlay())]))));
    expect(find.textContaining('input debug'), findsOneWidget);
    InputDebug.last.value = 'down mouse p=1 buttons=0b100 ctrl=false shift=false -> orbit nav=1';
    await tester.pump();
    expect(find.text('down mouse p=1 buttons=0b100 ctrl=false shift=false -> orbit nav=1'), findsOneWidget);
    expect(find.descendant(of: find.byType(InputDebugOverlay), matching: find.byType(IgnorePointer)), findsWidgets);
  });
}
