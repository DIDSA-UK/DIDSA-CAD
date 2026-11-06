import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/layout/layout_mode.dart';
import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/presentation_mode.dart';
import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/share_screen.dart';

// Presentation mode and Share screen (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 3), the parts that need no
// PartScreen: the turntable, the system UI calls, the Android intent actions, the dialog text, and the layout rule.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  double angleBetween(vm.Quaternion a, vm.Quaternion b) {
    final d = (a.conjugated() * b).normalized();
    return 2 * math.acos(d.w.abs().clamp(0.0, 1.0).toDouble());
  }

  group('Turntable', () {
    test('advances the camera by the same angle every tick, about the target', () {
      final camera = OrbitCamera();
      final turntable = Turntable()..start();
      var before = camera.orientation.clone();
      final steps = <double>[];
      for (var i = 0; i < 5; i++) {
        turntable.tick(camera);
        steps.add(angleBetween(before, camera.orientation));
        before = camera.orientation.clone();
      }
      expect(steps.first, greaterThan(0));
      for (final step in steps) {
        expect(step, closeTo(steps.first, 1e-4));
      }
      // Quaternions are single precision, so an angle this small is only good to about 1e-4.
      expect(steps.first, closeTo(Turntable.pixelsPerTick * OrbitCamera.orbitSensitivity, 1e-4));
    });

    test('does nothing until started, and stops when a pointer goes down', () {
      final camera = OrbitCamera();
      final turntable = Turntable();
      final start = camera.orientation.clone();
      turntable.tick(camera);
      expect(angleBetween(start, camera.orientation), 0);

      turntable.start();
      turntable.tick(camera);
      expect(angleBetween(start, camera.orientation), greaterThan(0));

      turntable.onPointerDown();
      expect(turntable.running, isFalse);
      final stopped = camera.orientation.clone();
      turntable.tick(camera);
      expect(angleBetween(stopped, camera.orientation), 0, reason: 'it does not resume by itself');
    });

    test('about a pivot, the pivot stays where it is on screen', () {
      final camera = OrbitCamera()..setZoomBoundsForRadius(150, center: vm.Vector3.zero());
      final pivot = vm.Vector3(40, 10, 0);
      final turntable = Turntable()..start();
      const size = Size(800, 600);
      final before = worldToScreen(camera.cameraFor(size), size, pivot)!;
      for (var i = 0; i < 30; i++) {
        turntable.tick(camera, pivot: pivot);
      }
      final after = worldToScreen(camera.cameraFor(size), size, pivot)!;
      expect((after - before).distance, lessThan(0.5), reason: 'the view turns about the pivot');
    });
  });

  group('PresentationSystemUi', () {
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    test('enter: immersive and landscape; exit: undone', () async {
      const ui = PresentationSystemUi(enabled: true);
      await ui.enter();
      expect(calls.map((c) => c.method), ['SystemChrome.setEnabledSystemUIMode', 'SystemChrome.setPreferredOrientations']);
      expect(calls[0].arguments, 'SystemUiMode.immersiveSticky');
      expect(calls[1].arguments, ['DeviceOrientation.landscapeLeft', 'DeviceOrientation.landscapeRight']);

      calls.clear();
      await ui.exit();
      expect(calls[0].method, 'SystemChrome.setPreferredOrientations');
      expect(calls[0].arguments, isEmpty, reason: 'an empty list lifts the lock');
      expect(calls[1].method, 'SystemChrome.setEnabledSystemUIMode');
      expect(calls[1].arguments, 'SystemUiMode.edgeToEdge');
    });

    test('disabled (a desktop window): touches nothing', () async {
      const ui = PresentationSystemUi(enabled: false);
      await ui.enter();
      await ui.exit();
      expect(calls, isEmpty);
    });

    test('by default only Android and iOS are touched', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await const PresentationSystemUi().enter();
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await const PresentationSystemUi().enter();
      expect(calls, isNotEmpty);
    });
  });

  group('ScreenShare', () {
    test('the Android intent actions: cast settings first, display settings as the fallback', () {
      expect(ScreenShare.androidSettingsActions, ['android.settings.CAST_SETTINGS', 'android.settings.DISPLAY_SETTINGS']);
    });

    test('asks the activity to open those actions, in order', () async {
      MethodCall? seen;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ScreenShare.channel, (
        call,
      ) async {
        seen = call;
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ScreenShare.channel, null));
      expect(await ScreenShare.openAndroidCastSettings(), isTrue);
      expect(seen!.method, 'openSettingsScreen');
      expect(seen!.arguments, {
        'actions': ['android.settings.CAST_SETTINGS', 'android.settings.DISPLAY_SETTINGS'],
      });
    });

    test('no activity on this platform: false, not an error', () async {
      expect(await ScreenShare.openAndroidCastSettings(), isFalse);
    });

    test('instructions per platform', () {
      expect(ScreenShare.mirroringInstructions(TargetPlatform.windows), contains('Win+K'));
      expect(ScreenShare.mirroringInstructions(TargetPlatform.iOS), contains('Screen Mirroring'));
      expect(ScreenShare.mirroringInstructions(TargetPlatform.android), contains('cast settings'));
      expect(ScreenShare.mirroringInstructions(TargetPlatform.linux), isNull);
    });
  });

  group('Share screen dialog', () {
    Future<ShareScreenChoice?> open(WidgetTester tester, TargetPlatform platform, {required void Function(ShareScreenChoice?) onResult}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onResult(await showShareScreenDialog(context, platform: platform)),
              child: const Text('go'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return null;
    }

    testWidgets('has the two sections and the file picker warning', (tester) async {
      await open(tester, TargetPlatform.android, onResult: (_) {});
      expect(find.text('Present to a room or TV'), findsOneWidget);
      expect(find.text('Work on a monitor'), findsOneWidget);
      expect(find.textContaining('DeX'), findsOneWidget);
      expect(find.textContaining('Bluetooth mouse'), findsOneWidget);
      expect(find.textContaining('file picker'), findsOneWidget);
    });

    testWidgets('Android offers the cast settings; other platforms do not', (tester) async {
      await open(tester, TargetPlatform.android, onResult: (_) {});
      expect(find.byKey(const ValueKey('share-open-cast-settings')), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await open(tester, TargetPlatform.iOS, onResult: (_) {});
      expect(find.byKey(const ValueKey('share-open-cast-settings')), findsNothing);
      expect(find.textContaining('Control Centre'), findsOneWidget);
    });

    testWidgets('Present and Open cast settings resolve to their choices', (tester) async {
      ShareScreenChoice? result;
      await open(tester, TargetPlatform.android, onResult: (r) => result = r);
      await tester.tap(find.byKey(const ValueKey('share-present')));
      await tester.pumpAndSettle();
      expect(result, ShareScreenChoice.present);
      await open(tester, TargetPlatform.android, onResult: (r) => result = r);
      await tester.tap(find.byKey(const ValueKey('share-open-cast-settings')));
      await tester.pumpAndSettle();
      expect(result, ShareScreenChoice.openCastSettings);
    });
  });

  group('use case A (desktop windowing) is not changed', () {
    test('a large window with a mouse as the last pointer is the desktop layout, on Android too', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final controller = LayoutModeController(
        preference: LayoutPreference.automatic,
        windowSize: const Size(1920, 1080),
        mouseActive: false,
      );
      expect(controller.mode, LayoutMode.phone, reason: 'touch first');
      controller.notePointer(PointerDeviceKind.mouse);
      expect(controller.mode, LayoutMode.desktop);
      controller.noteWindowSize(const Size(400, 800));
      expect(controller.mode, LayoutMode.phone, reason: 'back to the phone layout when the window is small');
    });
  });
}
