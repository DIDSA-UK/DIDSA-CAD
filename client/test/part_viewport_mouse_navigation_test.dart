import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/controls_preferences.dart';
import 'package:didsa_cad_client/viewport3d/mouse_navigation.dart' show SelectClick;
import 'package:didsa_cad_client/viewport3d/orbit_camera.dart';
import 'package:didsa_cad_client/viewport3d/view_cube.dart' show viewCubeEyeAndUp;
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

/// Desktop input D1 (`docs/desktop-input-scope.md`): in selection mode (the
/// mode most tools switch to) a mouse used to be unable to orbit or pan at
/// all - every drag only moved the cursor. A middle drag now orbits and a
/// right drag pans in every mode, and neither commits a selection. Needs
/// the real viewport, so it skips without a GPU backend, as the other
/// `PartViewport` pointer tests do.
final _triangle = BodyMeshDto(
  bodyId: 'body-1',
  source: 'computed',
  mesh: MeshDto(
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
  ),
);

Future<bool> _pumpUntilGpuReady(WidgetTester tester, {int maxPumps = 300}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return true;
    await tester.pump(const Duration(milliseconds: 100));
  }
  return find.byType(CircularProgressIndicator).evaluate().isEmpty;
}

void main() {
  testWidgets('selection mode: middle drag orbits, right drag pans, neither selects', (tester) async {
    final key = GlobalKey<PartViewportState>();
    final toggled = <SelectionEntityRef>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PartViewport(
              key: key,
              bodies: [_triangle],
              selectedPlane: null,
              onPlaneTap: (_) {},
              onBackgroundTap: () {},
              selectionMode: true,
              onSelectionToggle: toggled.add,
            ),
          ),
        ),
      ),
    );
    if (!await _pumpUntilGpuReady(tester)) {
      markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
      return;
    }
    await tester.pump();
    final state = key.currentState!;

    final orientationBefore = state.debugCameraOrientation.clone();
    final targetBefore = state.debugCameraTarget.clone();
    final middle = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
    await middle.down(const Offset(200, 200));
    await tester.pump();
    await middle.moveBy(const Offset(40, 0));
    await tester.pump();
    await middle.up();
    await tester.pump();
    expect(state.debugCameraOrientation != orientationBefore, isTrue, reason: 'a middle drag orbits');
    expect(state.debugCameraTarget, targetBefore, reason: 'a middle drag does not pan');
    expect(state.debugMouseDriven, isTrue);

    final right = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await right.down(const Offset(100, 100));
    await tester.pump();
    await right.moveBy(const Offset(0, 40));
    await tester.pump();
    await right.up();
    await tester.pump();
    expect(state.debugCameraTarget != targetBefore, isTrue, reason: 'a right drag pans');

    // A right click (no drag) over the body commits nothing.
    final click = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await click.down(const Offset(120, 220));
    await tester.pump();
    await click.up();
    await tester.pump();
    expect(toggled, isEmpty, reason: 'no middle or right drag or click may commit a selection');
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop input D2: each click reports its rule; Ctrl+click on empty space keeps the selection', (tester) async {
    final clicks = <SelectClick>[];
    var clears = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PartViewport(
              bodies: [_triangle],
              selectedPlane: null,
              onPlaneTap: (_) {},
              onBackgroundTap: () {},
              selectionMode: true,
              onSelectClick: clicks.add,
              onClearSelection: () => clears++,
            ),
          ),
        ),
      ),
    );
    if (!await _pumpUntilGpuReady(tester)) {
      markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
      return;
    }
    await tester.pump();

    // Far corner: empty space.
    await tester.tapAt(const Offset(390, 10), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(clicks.last, SelectClick.replace);
    expect(clears, 1, reason: 'a plain click on empty space clears');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tapAt(const Offset(390, 10), kind: PointerDeviceKind.mouse);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(clicks.last, SelectClick.toggle);
    expect(clears, 1, reason: 'a Ctrl+click on empty space keeps the selection');

    await tester.tapAt(const Offset(390, 10));
    await tester.pump();
    expect(clicks.last, SelectClick.touch);
  });

  testWidgets(
    'desktop input D4: a right click without a drag asks for a context menu with what is under it; a drag, a middle click and a touch do not',
    (tester) async {
      final key = GlobalKey<PartViewportState>();
      final requests = <(HoverHit?, Offset)>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                key: key,
                bodies: [_triangle],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                onContextMenuRequested: (hit, at) => requests.add((hit, at)),
              ),
            ),
          ),
        ),
      );
      if (!await _pumpUntilGpuReady(tester)) {
        markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
        return;
      }
      await tester.pump();

      Future<void> click(Offset at, {int buttons = kSecondaryMouseButton, Offset drag = Offset.zero}) async {
        final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: buttons);
        await gesture.down(at);
        await tester.pump();
        if (drag != Offset.zero) {
          await gesture.moveBy(drag);
          await tester.pump();
        }
        await gesture.up();
        await tester.pump();
      }

      // Over the body: the hit names it; far from it: null.
      final origin = tester.getTopLeft(find.byType(PartViewport));
      await click(origin + const Offset(200, 200));
      await click(origin + const Offset(5, 5));
      expect(requests.length, 2);
      expect(requests[0].$2, origin + const Offset(200, 200), reason: 'the position is global, where the menu goes');
      expect(requests[1].$1, isNull, reason: 'empty space has no hit');

      requests.clear();
      await click(origin + const Offset(200, 200), drag: const Offset(40, 0));
      await click(origin + const Offset(200, 200), buttons: kMiddleMouseButton);
      await tester.longPressAt(origin + const Offset(200, 200));
      await tester.pump();
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop input D4: zoom to selection frames a face, and Normal To only works for a flat face', (tester) async {
    final key = GlobalKey<PartViewportState>();
    final flat = BodyMeshDto(
      bodyId: 'body-1',
      source: 'computed',
      mesh: MeshDto(
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
        faceIds: [0],
        faceIsPlanar: [true],
      ),
    );
    final curved = BodyMeshDto(
      bodyId: 'body-2',
      source: 'computed',
      mesh: MeshDto(
        vertices: flat.mesh.vertices,
        normals: flat.mesh.normals,
        triangleIndices: flat.mesh.triangleIndices,
        faceIds: [0],
        faceIsPlanar: [false],
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PartViewport(
              key: key,
              bodies: [flat, curved],
              selectedPlane: null,
              onPlaneTap: (_) {},
              onBackgroundTap: () {},
            ),
          ),
        ),
      ),
    );
    if (!await _pumpUntilGpuReady(tester)) {
      markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
      return;
    }
    await tester.pump();
    final state = key.currentState!;
    const flatFace = SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-1', id: 0);
    const curvedFace = SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'body-2', id: 0);

    expect(state.planarFaceNormal(flatFace)!.z.abs(), closeTo(1, 1e-6));
    expect(state.planarFaceNormal(curvedFace), isNull);

    expect(state.zoomToEntities({flatFace}), isTrue);
    expect(state.debugCameraTarget.x, closeTo(5, 1e-6), reason: 'centred on the face');
    expect(state.zoomToEntities({const SelectionEntityRef(kind: SelectionEntityKind.sketchPoint)}), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop input D5: the Onshape preset orbits with a right drag, and a view cube pick turns the view', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final key = GlobalKey<PartViewportState>();
    final requests = <Offset>[];
    await tester.runAsync(() => ControlsPreferences.setPreset(NavigationPreset.onshape));
    addTearDown(() => ControlsPreferences.setPreset(NavigationPreset.solidworks));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 400,
            child: PartViewport(
              key: key,
              bodies: [_triangle],
              selectedPlane: null,
              onPlaneTap: (_) {},
              onBackgroundTap: () {},
              selectionMode: true,
              onContextMenuRequested: (hit, at) => requests.add(at),
            ),
          ),
        ),
      ),
    );
    if (!await _pumpUntilGpuReady(tester)) {
      markTestSkipped('PartViewport GPU/Impeller setup did not complete - no real GPU backend in this sandbox');
      return;
    }
    await tester.pump();
    final state = key.currentState!;

    final orientationBefore = state.debugCameraOrientation.clone();
    final targetBefore = state.debugCameraTarget.clone();
    final right = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await right.down(const Offset(200, 200));
    await tester.pump();
    await right.moveBy(const Offset(40, 0));
    await tester.pump();
    await right.up();
    await tester.pump();
    expect(state.debugCameraOrientation != orientationBefore, isTrue, reason: 'Onshape: a right drag orbits');
    expect(state.debugCameraTarget, targetBefore, reason: 'and does not pan');
    expect(requests, isEmpty, reason: 'a drag is not a click');

    final click = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
    await click.down(const Offset(120, 220));
    await click.up();
    await tester.pump();
    expect(requests.length, 1, reason: 'a right click still asks for the menu');

    await state.animateToViewCubeTarget(vm.Vector3(0, 1, 0));
    await tester.pump(const Duration(seconds: 1));
    final (eye, up) = viewCubeEyeAndUp(vm.Vector3(0, 1, 0));
    final expected = OrbitCamera.orientationLookingFrom(eye, vm.Vector3.zero(), up);
    final actual = state.debugCameraOrientation;
    final dot = (expected.x * actual.x + expected.y * actual.y + expected.z * actual.z + expected.w * actual.w).abs();
    expect(dot, closeTo(1, 1e-4), reason: 'the view now looks down from above (Top)');
    expect(tester.takeException(), isNull);
  });
}

