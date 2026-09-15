import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';

/// Assembly support Phase 5 (`docs/assembly-scope.md` §3): the component
/// gizmo's own version of `section_gizmo_touch_test.dart`'s stuck-touch-
/// state regression test - the exact same bug class
/// (`_sectionDragPointerId`'s own doc comment describes the original
/// report), now guarded against for this second gizmo too via the
/// identical `event.pointer == _componentGizmoDragPointerId` gating this
/// file's own `part_viewport.dart` wiring added.
///
/// Uses `PartViewportState.debugForceComponentGizmoDrag` only to simulate
/// "a gizmo drag is already in progress for pointer 1" (see that method's
/// own doc comment for why this doesn't need a real 3D gizmo hit-test) -
/// everything downstream (the second finger's own down/move/up, and the
/// final single-finger drag) goes through the real, unmodified pointer
/// handlers.
final _boxMesh = MeshDto(
  vertices: [
    [0, 0, 0],
    [10, 0, 0],
    [0, 10, 0],
  ],
  normals: [
    [0, 0, 1],
    [0, 0, 1],
    [0, 0, 1],
  ],
  triangleIndices: [
    [0, 1, 2],
  ],
);
final _boxBody = BodyMeshDto(bodyId: 'body-1', source: 'computed', mesh: _boxMesh);

final _identityTransform = RigidTransformDto(
  translation: const [0, 0, 0],
  rotationAxis: const [0, 0, 1],
  rotationAngleDegrees: 0,
);

Future<bool> _pumpUntilGpuReady(WidgetTester tester, {int maxPumps = 300}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return find.byType(CircularProgressIndicator).evaluate().isEmpty;
}

void main() {
  testWidgets(
    'a second finger lifting before the component-gizmo-drag finger never leaves '
    'an orphaned _activeTouches entry, and a later single-finger drag still orbits',
    (tester) async {
      final key = GlobalKey<PartViewportState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                key: key,
                bodies: [_boxBody],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                selectedOccurrenceTransform: _identityTransform,
              ),
            ),
          ),
        ),
      );
      final gpuReady = await _pumpUntilGpuReady(tester);
      if (!gpuReady) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      await tester.pump();

      final state = key.currentState!;
      expect(state.debugActiveTouchCount, 0);

      // Simulate pointer 1 already mid-gizmo-drag (see
      // debugForceComponentGizmoDrag's own doc comment for why this
      // substitutes for a real hit-test).
      state.debugForceComponentGizmoDrag(1);
      expect(state.debugComponentGizmoDragHandle, isNotNull);

      // A second finger (pointer 2) touches down elsewhere in the viewport,
      // moves a little, then lifts *before* pointer 1 does.
      final secondFinger = await tester.createGesture(pointer: 2, kind: PointerDeviceKind.touch);
      await secondFinger.down(const Offset(300, 300));
      await tester.pump();
      await secondFinger.moveBy(const Offset(5, 5));
      await tester.pump();
      await secondFinger.up();
      await tester.pump();

      // The drag pointer-1 owns must NOT have been ended by pointer 2's own
      // up-event.
      expect(
        state.debugComponentGizmoDragHandle,
        isNotNull,
        reason: 'pointer 2 must not be able to end pointer 1\'s drag',
      );
      // And pointer 2 must have been correctly removed from _activeTouches
      // by the normal fallthrough handling, not orphaned there.
      expect(state.debugActiveTouchCount, 0, reason: 'pointer 2 must not be left as a stale/orphaned touch');

      // Now pointer 1 (the real drag owner) lifts, ending the drag for real.
      final firstFinger = await tester.createGesture(pointer: 1, kind: PointerDeviceKind.touch);
      await firstFinger.up();
      await tester.pump();
      expect(state.debugComponentGizmoDragHandle, isNull);
      expect(state.debugActiveTouchCount, 0);

      // The actual regression: a later, completely ordinary single-finger
      // drag must still orbit (change orientation), not misfire as a
      // two-finger pinch/pan.
      final targetBefore = state.debugCameraTarget.clone();
      final distanceBefore = state.debugCameraDistance;
      final orientationBefore = state.debugCameraOrientation.clone();

      await tester.dragFrom(const Offset(200, 200), const Offset(40, 0));
      await tester.pump();

      expect(state.debugCameraTarget.x, targetBefore.x, reason: 'a single-finger drag must not pan');
      expect(state.debugCameraTarget.y, targetBefore.y, reason: 'a single-finger drag must not pan');
      expect(state.debugCameraTarget.z, targetBefore.z, reason: 'a single-finger drag must not pan');
      expect(state.debugCameraDistance, distanceBefore, reason: 'a single-finger drag must not zoom');
      expect(
        state.debugCameraOrientation != orientationBefore,
        isTrue,
        reason: 'a single-finger drag must orbit (change orientation)',
      );
      expect(state.debugActiveTouchCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a component-gizmo drag never continues or ends for a pointer that did not start it',
    (tester) async {
      final key = GlobalKey<PartViewportState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                key: key,
                bodies: [_boxBody],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                selectedOccurrenceTransform: _identityTransform,
              ),
            ),
          ),
        ),
      );
      final gpuReady = await _pumpUntilGpuReady(tester);
      if (!gpuReady) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      await tester.pump();

      final state = key.currentState!;
      state.debugForceComponentGizmoDrag(1);
      expect(state.debugComponentGizmoDragHandle, isNotNull);

      // Pointer 2's own move/up must never be mistaken for pointer 1's drag.
      final secondFinger = await tester.createGesture(pointer: 2, kind: PointerDeviceKind.touch);
      await secondFinger.down(const Offset(100, 100));
      await tester.pump();
      await secondFinger.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(state.debugComponentGizmoDragHandle, isNotNull, reason: 'still owned by pointer 1');
      await secondFinger.up();
      await tester.pump();
      expect(state.debugComponentGizmoDragHandle, isNotNull, reason: 'pointer 2 up must not end pointer 1\'s drag');

      expect(tester.takeException(), isNull);
    },
  );
}
