import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/layout/adaptive_sheet.dart';
import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/controls_settings_screen.dart';

/// Desktop layout D6 (`docs/desktop-layout-scope.md` section 1): when the app
/// switches layout.
void main() {
  const wide = Size(1280, 800);

  LayoutMode resolve({
    LayoutPreference preference = LayoutPreference.automatic,
    Size size = wide,
    bool mouse = true,
    LayoutMode current = LayoutMode.phone,
  }) =>
      resolveLayoutMode(preference: preference, windowSize: size, mouseActive: mouse, current: current);

  group('resolveLayoutMode', () {
    test('automatic: a big window used with a mouse is desktop', () {
      expect(resolve(), LayoutMode.desktop);
    });

    test('automatic: a touch, or a small window, is phone', () {
      expect(resolve(mouse: false), LayoutMode.phone);
      expect(resolve(size: const Size(800, 600)), LayoutMode.phone);
      expect(resolve(size: const Size(1200, 500)), LayoutMode.phone);
    });

    test('automatic: the line is 1000 x 600', () {
      expect(resolve(size: const Size(999, 700)), LayoutMode.phone);
      expect(resolve(size: const Size(1000, 600)), LayoutMode.desktop);
    });

    test('hysteresis: once desktop it stays desktop down to 900 x 520', () {
      expect(resolve(size: const Size(950, 560), current: LayoutMode.desktop), LayoutMode.desktop);
      expect(resolve(size: const Size(950, 560), current: LayoutMode.phone), LayoutMode.phone);
      expect(resolve(size: const Size(899, 700), current: LayoutMode.desktop), LayoutMode.phone);
      expect(resolve(size: const Size(1200, 519), current: LayoutMode.desktop), LayoutMode.phone);
    });

    test('hysteresis never keeps desktop once a touch is used', () {
      expect(resolve(mouse: false, current: LayoutMode.desktop), LayoutMode.phone);
    });

    test('the override ignores the window and the pointer', () {
      expect(resolve(preference: LayoutPreference.desktop, size: const Size(400, 700), mouse: false), LayoutMode.desktop);
      expect(resolve(preference: LayoutPreference.phone), LayoutMode.phone);
    });
  });

  group('LayoutModeController', () {
    test('follows the window size and the pointer kind', () {
      final controller = LayoutModeController(preference: LayoutPreference.automatic, windowSize: wide, mouseActive: true);
      var notified = 0;
      controller.addListener(() => notified++);
      expect(controller.mode, LayoutMode.desktop);

      controller.notePointer(PointerDeviceKind.touch);
      expect(controller.mode, LayoutMode.phone);
      controller.notePointer(PointerDeviceKind.mouse);
      expect(controller.mode, LayoutMode.desktop);
      expect(notified, 2);

      controller.noteWindowSize(const Size(700, 900));
      expect(controller.mode, LayoutMode.phone);
      controller.noteWindowSize(const Size(700, 900));
      expect(notified, 3, reason: 'the same size again changes nothing');
    });

    test('a pen counts as touch, a trackpad as a mouse', () {
      final controller = LayoutModeController(preference: LayoutPreference.automatic, windowSize: wide, mouseActive: true);
      controller.notePointer(PointerDeviceKind.stylus);
      expect(controller.mode, LayoutMode.phone);
      controller.notePointer(PointerDeviceKind.trackpad);
      expect(controller.mode, LayoutMode.desktop);
    });

    test('changing the preference re-decides at once', () {
      final controller = LayoutModeController(preference: LayoutPreference.automatic, windowSize: wide, mouseActive: true);
      controller.preference = LayoutPreference.phone;
      expect(controller.mode, LayoutMode.phone);
      controller.preference = LayoutPreference.automatic;
      expect(controller.mode, LayoutMode.desktop);
    });
  });

  group('LayoutModeHost', () {
    testWidgets('a touch in a big window drops the layout to phone, and a mouse hover brings it back', (tester) async {
      tester.view.physicalSize = wide;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = LayoutModeController(preference: LayoutPreference.automatic, mouseActive: true);
      LayoutMode? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: LayoutModeHost(
            controller: controller,
            child: Builder(
              builder: (context) {
                seen = LayoutModeScope.modeOf(context);
                return const Scaffold(body: Center(child: Text('screen')));
              },
            ),
          ),
        ),
      );
      expect(seen, LayoutMode.desktop);

      final touch = await tester.startGesture(const Offset(100, 100), kind: PointerDeviceKind.touch);
      await touch.up();
      await tester.pump();
      expect(seen, LayoutMode.phone);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(10, 10));
      await mouse.moveTo(const Offset(200, 200));
      await tester.pump();
      expect(seen, LayoutMode.desktop);
    });

    testWidgets('without a host every screen is phone', (tester) async {
      LayoutMode? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = LayoutModeScope.modeOf(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, LayoutMode.phone);
    });
  });

  group('showAdaptiveSheet', () {
    Future<void> pumpOpener(WidgetTester tester, LayoutModeController? controller) async {
      tester.view.physicalSize = wide;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget home = Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAdaptiveSheet<void>(context: context, builder: (_) => const Text('sheet content')),
            child: const Text('open'),
          ),
        ),
      );
      if (controller != null) home = LayoutModeScope(controller: controller, child: home);
      await tester.pumpWidget(MaterialApp(home: home));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('a bottom sheet on the phone layout', (tester) async {
      await pumpOpener(tester, null);
      expect(find.text('sheet content'), findsOneWidget);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byKey(const ValueKey('adaptive-sheet-dialog')), findsNothing);
    });

    testWidgets('a centred dialog on the desktop layout', (tester) async {
      await pumpOpener(
        tester,
        LayoutModeController(preference: LayoutPreference.desktop, windowSize: wide, mouseActive: true),
      );
      expect(find.text('sheet content'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      final dialog = tester.getRect(find.byKey(const ValueKey('adaptive-sheet-dialog')));
      expect(dialog.width, lessThanOrEqualTo(560));
      expect(dialog.center.dx, closeTo(640, 1));
    });
  });

  group('the Controls setting', () {
    testWidgets('choosing Always desktop is saved and applied', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = LayoutModeController(preference: LayoutPreference.automatic, windowSize: const Size(900, 1400), mouseActive: true);
      await tester.pumpWidget(
        MaterialApp(
          home: LayoutModeHost(controller: controller, child: const ControlsSettingsScreen()),
        ),
      );
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(controller.mode, LayoutMode.phone);

      await tester.ensureVisible(find.text('Always desktop'));
      await tester.tap(find.text('Always desktop'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(controller.preference, LayoutPreference.desktop);
      expect(controller.mode, LayoutMode.desktop);
      expect(ControlsPreferences.layoutPreference, LayoutPreference.desktop);

      await tester.runAsync(() async {
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(ControlsPreferences.layoutPrefKey), 'desktop');
      });
    });
  });
}
