# Sketch-line contrast and see-through interior shading: plan

Source: the owner's device check after the `flutter_scene` 0.24.3 upgrade (PR #335, `docs/flutter-scene-0.24-and-stable-plan.md`).
This doc is for the implementation session. Written 2026-11-06 against `main` at `51a4382`.
Line numbers drift, so search for the named symbol if a line is off. Paths are under `client/` unless they say otherwise.

## The two reports

1. **Sketch lines are hard to see through a see-through body** (50% opacity, default light grey `#B0B8C1`). The constraint flags stay clear (they are Flutter widgets on top of the 3D view, not scene geometry).
   - Contrast: sketch lines are a fixed light grey (`sketchLineColor`, 0.85) so they read on the dark default background (`#2C2C2C`). On a light body there is almost no contrast. No single colour reads on both.
   - Possibly also draw order: 0.24 sorts see-through draws by the centre of their geometry along the view direction, where 0.18 effectively tied the body and the sketch (both nodes at the identity transform). If the sketch's centre is farther than the body's, the sketch now draws first and the 50% body is blended over it. Owner's decision: **treat it as contrast first**, then test. The draw-order fix is Phase 3 and runs only if that test says so.
2. **A see-through body's inside faces look lit.** Every see-through triangle is built twice (`meshBuffersFromMesh(..., doubleSidedWinding: true)`): the outside copy, and an inside copy with reversed winding and flipped normals. Looking through the near wall you see the far wall's inside copy, whose normal points back at you, so the lighting treats it as a lit surface. That is inherent to the two-copy build, not the upgrade (it also proves the winding swap is right: with it wrong, the near face would look dark). Owner's decision: try darkening the inside copy.

## Rules for the implementing session

- Branch: the one you were given. One commit per phase. Push after each phase, wait for the `Client - build and test` workflow, then **stop and ask the owner to do that phase's device check**, and wait for the answer.
- Change only what a phase lists. Never skip or weaken tests.
- Tests have no GPU (`flutter test` cannot render). Put the logic in pure functions that tests can reach, and say what could only be checked on a device.
- Fill in the Progress table as you go; at the end, add a dated `docs/status.md` entry (format: its recent entries), including what was not verified.
- Reports are for the owner, who is not a software developer: plain words, checklists for the device checks.

---

## Phase 1: outlined sketch lines

A light line with a thin dark edge reads on a dark background and on a light body (the same trick map labels use).

1. `lib/viewport3d/sketch_geometry_3d.dart`, next to `sketchLineColor`: add `final vm.Vector4 sketchOutlineColor = vm.Vector4(0.08, 0.08, 0.08, 1.0);` and `const double sketchOutlinePixels = 1.25;` (per side; `PolylineGeometry` widths are screen pixels by default, `PolylineWidthMode.screenPixels`). Doc-comment both with the reason above.
2. `buildSketchGeometryNode`: for **every** primitive it builds (entity outlines, construction dashes, text handle lines and markers, Point markers), build a matching outline primitive: the same points and cap, width `+ 2 * sketchOutlinePixels`, material `materialFor(sketchOutlineColor)` (the same `AlwaysOnTopMaterial`, blend). Do it in one place: make the code that creates each `MeshPrimitive` produce a (points, width, cap, colour) description first, then build the core and outline primitives from the same list, so the two can never drift apart.
3. Put all outline primitives in **one child node** of the returned node, named `'sketch-$featureId-outline'`, with `renderOrder = -1`. The returned node keeps the core primitives and `renderOrder` 0, so `part_viewport.dart`'s callers are unchanged.
   - Why a child node: `renderOrder` is per node and not inherited (`Node.renderOrder` doc in flutter_scene 0.24), and draws inside one node have no defined order, so the outline could otherwise draw over its own core.
   - Why `-1` and not higher: the outline is then always before its core, while the core keeps today's order against bodies (0). That keeps the owner's draw-order test below meaningful. Do not change any other node's `renderOrder` in this phase.
4. `buildDrawIndicatorsNode` (the in-progress drawing markers, same file): same treatment, so drawing and committed geometry look alike.
5. A switch: `ViewPreferences.sketchLineOutline` (bool, default **true**, key `view_sketch_line_outline`), following `debugShowCameraOrientation`'s pattern in `lib/viewport3d/view_preferences.dart`, shown as a `SwitchListTile` "Outline sketch lines" in `lib/sketch/sketcher_settings_screen.dart` (the "CAD Settings" screen). When it is off, no outline node is built. The viewport must pick the change up the next time it rebuilds the sketch nodes; say in the report if it needs leaving and reopening the part.
6. Tests: the description function (core and outline lists the same length, outline width = core + 2.5, same points and caps, outline colour), the `renderOrder` value if a `Node` can be built without a GPU (if not, say so), and the preference default and round trip.

Cost: twice the polylines for sketch geometry. Construction geometry is capped at 120 dashes an entity (`sketchConstructionMaxDashes`), so the worst case doubles a bounded number. Hit-testing is the app's own code, so it is unaffected.

**(commit)**. Gate: analyze clean, tests pass, CI green including the APK.

Owner device check (checklist for the report):
1. Default colours, body at 50% opacity. Sketch on the face nearest you: lines readable? Sketch on a plane behind the body's middle: readable?
2. Orbit slowly around each. Do the lines stay readable all the way round, or go faint at some angles and come back? (Faint-and-back means draw order: Phase 3.)
3. Body at 100% opacity, and with no body (sketch on its own against the dark background): still look right?
4. Colours still mean the same: fully constrained green, over-constrained red, construction blue dashes, the grabbed point orange.
5. Turn "Outline sketch lines" off in CAD Settings and back on, to compare.

## Phase 2: darker inside faces for see-through bodies

1. `writeUnskinnedVertex` (`lib/viewport3d/mesh_geometry.dart`): add optional colour parameters (default 1, 1, 1, 1) so callers can set the vertex colour.
2. `meshBuffersFromMesh`: the second (inside) copy written when `doubleSidedWinding` is true gets colour `(s, s, s, 1)`, `s = kSeeThroughInteriorShade`, a new constant **0.55**, doc-commented. The outside copy stays 1, 1, 1, 1, and alpha stays 1 for both (the material's own alpha does the transparency). Body materials multiply the vertex colour in (`PhysicallyBasedMaterial.vertexColorWeight`, default 1, in flutter_scene 0.24), so this darkens only what is seen through the near wall.
3. A switch: `ViewPreferences.darkenSeeThroughInterior` (bool, default **true**, key `view_darken_see_through_interior`), "Darker inside of see-through bodies" in CAD Settings, same pattern as Phase 1. Off writes 1, 1, 1, 1 as today. Bodies rebuild their geometry when it changes, or on the next part load; say which in the report.
4. Grep every caller that passes `doubleSidedWinding: true` (at least the Part viewport's body sync, `appearance_look.dart`'s translucent pieces and `buildAssemblyInstanceNode`) and list them in the report, with any whose material is unlit (`UnlitMaterial` also multiplies vertex colour, so a tinted see-through preview would darken inside too). That is acceptable; just record it.
5. Tests: the inside copy's colour floats are `s` and the outside copy's are 1, alpha 1, the 72-byte layout unchanged; with the switch off, all 1. Expected values in `test/mesh_geometry_test.dart` change on purpose only where the colour is checked.

Limits to state in the report: faces that genuinely face you through the near wall (for example the walls of a hole) are outside copies and stay lit; this is a shading cue, not real light blocking.

**(commit)**. Gate: analyze clean, tests pass, CI green including the APK.

Owner device check:
1. A body with holes or pockets at 50% opacity: does the inside read as darker, and is the shape easier to understand?
2. Is 0.55 right, too dark or too light? (The value is one constant; the owner may ask for another value, and that is a one-line follow-up commit.)
3. Opaque bodies unchanged; Appearance colours unchanged on the outside.
4. Turn "Darker inside of see-through bodies" off and on, to compare.

## Phase 3: only if Phase 1 check 2 showed lines fading with the angle

Overlays draw after bodies, whatever their position. Set `renderOrder` on the nodes (they all start at 0):

| Node (builder) | renderOrder |
|---|---|
| bodies and assembly instances | 0 (unchanged) |
| sketch-plane surface (`buildSketchPlaneSurfaceNode`) | 1 |
| sketch grid (`buildSketchGridNode`) | 2 |
| body edges and vertex markers (`buildMeshEdgesNode`, `buildVertexMarkersNode`) | 3 |
| sketch outline (Phase 1 child node) | 4 |
| sketch geometry core, face highlights, draw indicators (`buildSketchGeometryNode`, `buildHighlightFacesNode`, `buildDrawIndicatorsNode`) | 5 |

Each value is a named constant in one place (for example `kRenderOrder*` in `mesh_geometry.dart`) with a comment pointing here. Opaque draws also sort by `renderOrder` first, so check that no opaque node gets a non-zero value by accident, except the always-on-top overlays above.

**(commit)**. Gate: CI green. Owner device check: repeat Phase 1 checks 1 and 2 (no fading as you orbit), plus the grid over the sketch-plane surface from both sides, and selected-face highlights over a see-through body.

If Phase 1 check 2 showed no fading, do not do this phase. Record "not needed" in the Progress table.

---

## Progress

| Phase | Commit | CI run | What landed / what failed | Not verified |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
