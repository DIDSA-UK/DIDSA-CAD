
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/screen_projection.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';
import 'package:didsa_cad_client/viewport3d/touch_pivot.dart';

// Touch rotation pivot (`docs/flutter-testing-feedback-2026-11-05-plan.md` item 2): a tap on the model in orbit mode
// sets a persistent pivot, a tap on empty space clears it, a plane in front keeps its tap.
void main() {
  group('resolveOrbitTap (the decision, as a pure function)', () {
    test('a model hit with no plane sets the pivot', () {
      expect(resolveOrbitTap(pivotDistance: 100), OrbitTapOutcome.setPivot);
    });

    test('a model hit nearer than a plane sets the pivot', () {
      expect(resolveOrbitTap(pivotDistance: 100, planeDistance: 400), OrbitTapOutcome.setPivot);
    });

    test('a plane in front of the model keeps the tap (the plane sheet)', () {
      expect(resolveOrbitTap(pivotDistance: 400, planeDistance: 100), OrbitTapOutcome.plane);
    });

    test('a plane alone is a plane tap', () {
      expect(resolveOrbitTap(planeDistance: 100), OrbitTapOutcome.plane);
    });

    test('nothing hit is the background tap', () {
      expect(resolveOrbitTap(), OrbitTapOutcome.background);
    });
  });

  group('pivot picking and orbiting', () {
    const size = Size(800, 600);
    const tap = Offset(520, 230);
    // A 400 mm square face in the z = 0 plane, as two triangles.
    final face = [
      (vm.Vector3(-200, -200, 0), vm.Vector3(200, -200, 0), vm.Vector3(200, 200, 0)),
      (vm.Vector3(-200, -200, 0), vm.Vector3(200, 200, 0), vm.Vector3(-200, 200, 0)),
    ];

    for (final perspective in [false, true]) {
      group(perspective ? 'perspective' : 'orthographic', () {
        OrbitCamera makeCamera() => OrbitCamera()
          ..isPerspective = perspective
          ..setZoomBoundsForRadius(150, center: vm.Vector3.zero());

        test('nearestPivotHit returns the point and distance of the nearest hit, under the tap', () {
          final camera = makeCamera().cameraFor(size);
          final ray = camera.screenPointToRay(tap, size);
          final hit = hitTestFaces(ray, face, const [1, 1])!;
          final pivot = nearestPivotHit(ray, [hit.rayT + 50, hit.rayT, hit.rayT + 200])!;
          expect(pivot.distance, hit.rayT);
          expect(pivot.point.z, closeTo(0, 1e-2));
          expect((worldToScreen(camera, size, pivot.point)! - tap).distance, lessThan(0.5));
        });

        test('no hits, no pivot', () {
          final ray = makeCamera().cameraFor(size).screenPointToRay(tap, size);
          expect(nearestPivotHit(ray, const []), isNull);
        });

        test('the pivot stays at the same screen position through a whole drag, several drags apart', () {
          final orbit = makeCamera();
          final ray = orbit.cameraFor(size).screenPointToRay(tap, size);
          final pivot = nearestPivotHit(ray, [hitTestFaces(ray, face, const [1, 1])!.rayT])!.point;
          for (final delta in [const Offset(30, -10), const Offset(-80, 25), const Offset(5, 60)]) {
            orbit.orbitAboutPointByScreenDelta(delta.dx, delta.dy, pivot);
            expect((worldToScreen(orbit.cameraFor(size), size, pivot)! - tap).distance, lessThan(0.5));
          }
        });
      });
    }
  });

  group('PartViewport (needs a GPU backend, skips without one)', () {
    final triangle = BodyMeshDto(
      bodyId: 'body-1',
      source: 'computed',
      mesh: MeshDto(
        vertices: [
          [-200, -200, 0],
          [200, -200, 0],
          [0, 200, 0],
        ],
        normals: [
          [0, 0, 1],
          [0, 0, 1],
          [0, 0, 1],
        ],
        triangleIndices: [
          [0, 1, 2],
        ],
      ),
    );

    Future<bool> gpuReady(WidgetTester tester) async {
      for (var i = 0; i < 300; i++) {
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return true;
        await tester.pump(const Duration(milliseconds: 100));
      }
      return find.byType(CircularProgressIndicator).evaluate().isEmpty;
    }

    Future<GlobalKey<PartViewportState>?> pump(
      WidgetTester tester, {
      bool selectionMode = false,
      List<int>? backgroundTaps,
      bool hidePlanes = true,
    }) async {
      final key = GlobalKey<PartViewportState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                key: key,
                bodies: [triangle],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () => backgroundTaps?.add(1),
                selectionMode: selectionMode,
                onSelectionToggle: (_) {},
                hiddenReferencePlanes: hidePlanes ? kAllReferencePlanes : const {},
              ),
            ),
          ),
        ),
      );
      if (!await gpuReady(tester)) return null;
      await tester.pump();
      return key;
    }

    Future<void> tapAt(WidgetTester tester, Offset p) async {
      final gesture = await tester.startGesture(p, kind: PointerDeviceKind.touch);
      await gesture.up();
      await tester.pump();
    }

    testWidgets('a tap on the body sets the pivot (no background tap); a tap on empty space clears it', (tester) async {
      final backgroundTaps = <int>[];
      final key = await pump(tester, backgroundTaps: backgroundTaps);
      if (key == null) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      final center = tester.getCenter(find.byType(PartViewport));
      await tapAt(tester, center);
      expect(key.currentState!.rotationPivot, isNotNull);
      expect(backgroundTaps, isEmpty);
      expect(find.byKey(const ValueKey('rotation-pivot-marker')), findsOneWidget);

      await tapAt(tester, tester.getTopLeft(find.byType(PartViewport)) + const Offset(5, 5));
      expect(key.currentState!.rotationPivot, isNull);
      expect(backgroundTaps, hasLength(1));
      expect(find.byKey(const ValueKey('rotation-pivot-marker')), findsNothing);
    });

    testWidgets('selection mode: a tap leaves the pivot alone', (tester) async {
      final key = await pump(tester, selectionMode: true);
      if (key == null) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      key.currentState!.setRotationPivot(vm.Vector3(1, 2, 3));
      await tester.pump();
      await tapAt(tester, tester.getCenter(find.byType(PartViewport)));
      expect(key.currentState!.rotationPivot, vm.Vector3(1, 2, 3));
    });

    testWidgets('Reset view clears the pivot', (tester) async {
      final key = await pump(tester);
      if (key == null) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      key.currentState!.setRotationPivot(vm.Vector3(1, 2, 3));
      key.currentState!.resetView();
      await tester.pump();
      expect(key.currentState!.rotationPivot, isNull);
    });
  });
}
