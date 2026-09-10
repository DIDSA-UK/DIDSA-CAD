import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/section_plane.dart';

/// Regression test for the section-tool stuck-touch-state bug (on-device
/// feedback: "orbit stopped working and single finger drag started doing a
/// strange combination of pan and zoom instead... This persisted after
/// exiting the section tool and also the orbit/cursor stopped working.
/// Starting a new part resolved the issue").
///
/// Root cause (see `part_viewport.dart`'s `_sectionDragPointerId` doc
/// comment): `_onPointerMove`/`_onPointerEnd` used to gate purely on
/// `_sectionDragHandle != null`, with no check of *which* pointer started
/// the drag. A second finger touching down mid-drag got added to
/// `_activeTouches` normally, but if it lifted before the drag-owning
/// finger, its up-event was swallowed by the section-drag-end branch -
/// which cleared the drag state but never removed that finger from
/// `_activeTouches`, permanently orphaning it (that pointer id fires no
/// further events, so nothing ever calls `_activeTouches.remove` for it
/// again). From then on `_handlePointerMove` always saw
/// `_activeTouches.length >= 2` and routed every subsequent single-finger
/// drag into two-finger pinch/pan instead of orbit.
///
/// This test drives the real pointer-dispatch code (`_onPointerDown`/
/// `_onPointerMove`/`_onPointerEnd`) via genuine synthetic multi-pointer
/// gestures (`WidgetController.createGesture`), using
/// `PartViewportState.debugForceSectionDrag` only to simulate "a gizmo
/// drag is already in progress for pointer 1" (see that method's own doc
/// comment for why this doesn't need a real 3D gizmo hit-test) - everything
/// downstream of that (the second finger's own down/move/up, and the final
/// single-finger drag) goes through the real, unmodified pointer handlers.
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

final _sectionPlane = SectionPlane(
  id: 'section-1',
  origin: vm.Vector3(0, 0, 5),
  normal: vm.Vector3(0, 0, 1),
  anchorOrigin: vm.Vector3(0, 0, 5),
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
    'a second finger lifting before the section-gizmo-drag finger never leaves '
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
                sectionPlanes: [_sectionPlane],
                activeSectionId: _sectionPlane.id,
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

      // Simulate pointer 1 already mid-gizmo-drag (see debugForceSectionDrag's
      // own doc comment for why this substitutes for a real hit-test).
      state.debugForceSectionDrag(_sectionPlane.id, 1);
      expect(state.debugSectionDragHandle, isNotNull);

      // A second finger (pointer 2) touches down elsewhere in the viewport,
      // moves a little, then lifts *before* pointer 1 does - the exact
      // sequence the bug report describes.
      final secondFinger = await tester.createGesture(pointer: 2, kind: PointerDeviceKind.touch);
      await secondFinger.down(const Offset(300, 300));
      await tester.pump();
      await secondFinger.moveBy(const Offset(5, 5));
      await tester.pump();
      await secondFinger.up();
      await tester.pump();

      // The drag pointer-1 owns must NOT have been ended by pointer 2's own
      // up-event - the old, buggy gate matched *any* pointer.
      expect(state.debugSectionDragHandle, isNotNull, reason: 'pointer 2 must not be able to end pointer 1\'s drag');
      // And pointer 2 must have been correctly removed from _activeTouches
      // by the normal fallthrough handling, not orphaned there.
      expect(state.debugActiveTouchCount, 0, reason: 'pointer 2 must not be left as a stale/orphaned touch');

      // Now pointer 1 (the real drag owner) lifts, ending the drag for real.
      final firstFinger = await tester.createGesture(pointer: 1, kind: PointerDeviceKind.touch);
      await firstFinger.up();
      await tester.pump();
      expect(state.debugSectionDragHandle, isNull);
      expect(state.debugActiveTouchCount, 0);

      // The actual regression: a later, completely ordinary single-finger
      // drag must still orbit (change orientation), not misfire as a
      // two-finger pinch/pan (which would instead change target/distance -
      // see `_applyPinchPan`, `part_viewport.dart`). On the old, buggy code
      // an orphaned _activeTouches entry from the sequence above would have
      // made `_handlePointerMove` see `_activeTouches.length >= 2` here and
      // route this into `_applyPinchPan` instead.
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
}
