import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/controls_settings_screen.dart';

/// Desktop input D5 (`docs/desktop-input-scope.md` section 4): the Controls
/// settings - what is stored, and the screen that changes it.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ControlsPreferences.reset();
  });

  group('ControlsPreferences', () {
    test('defaults to SOLIDWORKS, wheel not inverted, orbit speed 1', () async {
      await ControlsPreferences.load();
      expect(ControlsPreferences.preset, NavigationPreset.solidworks);
      expect(ControlsPreferences.invertWheel, isFalse);
      expect(ControlsPreferences.orbitSpeed, 1.0);
    });

    test('what is set survives a reload', () async {
      await ControlsPreferences.setPreset(NavigationPreset.fusion360);
      await ControlsPreferences.setInvertWheel(true);
      await ControlsPreferences.setOrbitSpeed(2.5);
      // Forget the in-memory values, as a restart does, and read the store back.
      await ControlsPreferences.setPreset(NavigationPreset.solidworks);
      SharedPreferences.setMockInitialValues({
        ControlsPreferences.presetPrefKey: 'fusion360',
        ControlsPreferences.invertWheelPrefKey: true,
        ControlsPreferences.orbitSpeedPrefKey: 2.5,
      });
      await ControlsPreferences.load();
      expect(ControlsPreferences.preset, NavigationPreset.fusion360);
      expect(ControlsPreferences.invertWheel, isTrue);
      expect(ControlsPreferences.orbitSpeed, 2.5);
    });

    test('an unknown stored preset and an out-of-range speed fall back safely', () async {
      SharedPreferences.setMockInitialValues({
        ControlsPreferences.presetPrefKey: 'catia',
        ControlsPreferences.orbitSpeedPrefKey: 99.0,
      });
      await ControlsPreferences.load();
      expect(ControlsPreferences.preset, NavigationPreset.solidworks);
      expect(ControlsPreferences.orbitSpeed, ControlsPreferences.maxOrbitSpeed);
    });
  });

  group('Performance: hide edges while moving (A3)', () {
    test('defaults: off, 50,000 segments', () async {
      await ControlsPreferences.load();
      expect(ControlsPreferences.hideEdgesWhileMoving, isFalse);
      expect(ControlsPreferences.edgeLimit, 50000);
    });

    test('both survive a reload, and a stray stored limit snaps to a step', () async {
      SharedPreferences.setMockInitialValues({
        ControlsPreferences.hideEdgesWhileMovingPrefKey: true,
        ControlsPreferences.edgeLimitPrefKey: 21000,
      });
      await ControlsPreferences.load();
      expect(ControlsPreferences.hideEdgesWhileMoving, isTrue);
      expect(ControlsPreferences.edgeLimit, 20000);
      await ControlsPreferences.setEdgeLimit(120000);
      expect(ControlsPreferences.edgeLimit, 100000);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(ControlsPreferences.edgeLimitPrefKey), 100000);
    });

    testWidgets('the switch and the slider are saved, the slider is off until the switch is on, the count shows', (tester) async {
      ControlsPreferences.visibleEdgeSegments = 11918;
      addTearDown(() => ControlsPreferences.visibleEdgeSegments = 0);
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ControlsSettingsScreen()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('hide-edges-switch')), 200);
      expect(tester.widget<Slider>(find.byKey(const ValueKey('edge-limit-slider'))).onChanged, isNull);
      expect(find.text('This model: 11,918'), findsOneWidget);
      expect(find.text('Edge limit: 50,000 segments'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('hide-edges-switch')));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.hideEdgesWhileMoving, isTrue);
      expect(tester.widget<Slider>(find.byKey(const ValueKey('edge-limit-slider'))).onChanged, isNotNull);

      await tester.drag(find.byKey(const ValueKey('edge-limit-slider')), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.edgeLimit, 5000);
      expect(find.text('Edge limit: 5,000 segments'), findsOneWidget);
    });
  });

  group('ControlsSettingsScreen', () {
    Future<void> pump(WidgetTester tester, {Size size = const Size(800, 900)}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ControlsSettingsScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the three presets, SOLIDWORKS chosen', (tester) async {
      await pump(tester);
      for (final preset in NavigationPreset.values) {
        expect(find.text(preset.label), findsOneWidget);
      }
      final group = tester.widget<RadioGroup<NavigationPreset>>(find.byType(RadioGroup<NavigationPreset>));
      expect(group.groupValue, NavigationPreset.solidworks);
    });

    testWidgets('choosing a preset, the wheel switch and the speed are applied and saved at once', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Onshape'));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.preset, NavigationPreset.onshape);

      await tester.tap(find.text('Invert wheel zoom'));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.invertWheel, isTrue);

      await tester.drag(find.byType(Slider).first, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.orbitSpeed, greaterThan(1.0));
      expect(find.textContaining('Orbit speed: '), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(ControlsPreferences.presetPrefKey), 'onshape');
      expect(prefs.getBool(ControlsPreferences.invertWheelPrefKey), isTrue);
    });

    testWidgets('Reset to defaults puts everything back', (tester) async {
      await ControlsPreferences.setPreset(NavigationPreset.fusion360);
      await ControlsPreferences.setInvertWheel(true);
      await pump(tester);
      await tester.scrollUntilVisible(find.text('Reset to defaults'), 200);
      await tester.ensureVisible(find.text('Reset to defaults'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to defaults'));
      await tester.pumpAndSettle();
      expect(ControlsPreferences.preset, NavigationPreset.solidworks);
      expect(ControlsPreferences.invertWheel, isFalse);
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
    });

    testWidgets('the shortcut list opens from here', (tester) async {
      await pump(tester);
      await tester.scrollUntilVisible(find.text('Keyboard shortcuts'), 200);
      await tester.tap(find.text('Keyboard shortcuts'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Ctrl+1'), findsOneWidget);
    });

    testWidgets('fits a narrow, short window without overflowing', (tester) async {
      await pump(tester, size: const Size(320, 480));
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Reset to defaults'), 200);
      expect(tester.takeException(), isNull);
    });
  });
}
