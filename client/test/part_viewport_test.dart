import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';

/// A small box-like mesh carrying real face/edge/topology-vertex ids, so
/// hover/selection hit-testing in selection mode has something non-trivial
/// to resolve - mirrors the box reasoning already used in
/// `mesh_geometry_test.dart`'s bounds test (a 10x10x10
/// `BRepPrimAPI_MakeBox`), but kept to a single triangle/edge/vertex per id
/// since these tests only assert *that* a hit-test fires, not its exact
/// geometry.
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
  faceIds: [1],
  edges: [0, 0, 0, 10, 0, 0],
  edgeIds: [1],
  topologyVertices: [
    [0, 0, 0],
  ],
  topologyVertexIds: [1],
);

/// Prompt A3: [PartViewport] now takes `bodies` (a list) rather than a
/// single `mesh` - one [BodyMeshDto] wrapping [_boxMesh] is the standard
/// fixture these tests pass wherever the old suite passed `mesh: _boxMesh`.
final _boxBody = BodyMeshDto(bodyId: 'body-1', source: 'computed', mesh: _boxMesh);

Future<void> _pumpUntil(WidgetTester tester, bool Function() done, {int maxPumps = 100}) async {
  for (var i = 0; i < maxPumps; i++) {
    if (done()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'Stage 23 Item 7: a drag gesture in Orbit mode triggers no selection/cursor logic',
    (tester) async {
      var selectionToggled = false;
      var selectionCleared = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                bodies: [_boxBody],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                // selectionMode defaults to false (Orbit mode) - left
                // unspecified here deliberately, so this test exercises the
                // real default rather than an explicitly-passed false.
                onSelectionToggle: (_) => selectionToggled = true,
                onClearSelection: () => selectionCleared = true,
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.pump();

      // A drag is exactly the gesture the existing orbit handler reads -
      // Item 7 requires this to keep driving the camera, not the new
      // cursor/hover dispatch, and to never fire either selection callback.
      await tester.dragFrom(const Offset(200, 200), const Offset(40, 0));
      await tester.pump();

      expect(selectionToggled, isFalse);
      expect(selectionCleared, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Stage 23 Items 2/3: entering selection mode resets the cursor to the viewport centre',
    (tester) async {
      Widget buildViewport(bool selectionMode) {
        return MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                bodies: [_boxBody],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                selectionMode: selectionMode,
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(buildViewport(false));
      await _pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.pump();

      await tester.pumpWidget(buildViewport(true));
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Fix 4: tapping the viewport in selection mode over empty space (no mesh) clears the selection, not toggles an entity',
    (tester) async {
      var cleared = false;
      var toggled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                bodies: const [],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                selectionMode: true,
                onSelectionToggle: (_) => toggled = true,
                onClearSelection: () => cleared = true,
              ),
            ),
          ),
        ),
      );
      // A plain "spinner gone" wait is ambiguous here: PartViewport's build()
      // also stops showing the spinner if Scene setup itself failed (no real
      // Impeller/GPU backend in this CI sandbox sets `_error`, per its
      // catchError handler), rendering a plain error Text with no Listener
      // wired up at all - a tap would then silently hit nothing rather than
      // ever reaching _onPointerDown/_onPointerEnd. Waiting for PartViewport's
      // *own* Listener (not a bare find.byType(Listener), which matches any
      // ambient Listener elsewhere in the tree - e.g. from Scaffold/
      // GestureDetector internals - and would return true immediately,
      // before Scene setup has actually finished) confirms the real
      // interactive tree is what's being tapped.
      await _pumpUntil(
        tester,
        () => find.descendant(of: find.byType(PartViewport), matching: find.byType(Listener)).evaluate().isNotEmpty,
        maxPumps: 300,
      );
      await tester.pump();

      // Fix 4: a tap (no drag) directly on the viewport commits the current
      // hover - here, nothing's under the cursor (no mesh), so it clears
      // the selection rather than toggling an entity.
      await tester.tap(find.byType(PartViewport));
      await tester.pump();

      expect(cleared, isTrue);
      expect(toggled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Fix 4: a drag past the tap threshold in selection mode moves the cursor and commits no selection',
    (tester) async {
      var cleared = false;
      var toggled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: PartViewport(
                bodies: [_boxBody],
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                selectionMode: true,
                onSelectionToggle: (_) => toggled = true,
                onClearSelection: () => cleared = true,
              ),
            ),
          ),
        ),
      );
      await _pumpUntil(tester, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
      await tester.pump();

      // A drag well past the tap-travel threshold (10.0 logical pixels) must
      // move the cursor only - not commit a selection - per Fix 4's
      // tap-vs-drag disambiguation.
      await tester.dragFrom(const Offset(200, 200), const Offset(60, 0));
      await tester.pump();

      expect(cleared, isFalse);
      expect(toggled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

}
