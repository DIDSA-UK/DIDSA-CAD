# Prompt C — on-device bug-fix round 2 — 2026-07-01

Round 1 (`docs/status-2026-07-01-prompt-c-bugfixes.md`) confirmed multi-body
extrude working. This round covers the two follow-up reports: the 2D
sketch canvas not highlighting multiple closed profiles, and a rendering
question about internal faces/hidden edges showing through solid bodies.

## 1 — Sketch canvas doesn't highlight multiple closed profiles

### Report
A sketch with several disjoint closed loops (and a nested hole) shows the
green "ready to extrude" fill for a single profile, but not when the
sketch has multiple closed profiles.

### Root cause
`SketchController.closedProfilePointIds` (and the `/profile` response
parsing behind it) only ever exposed the backend's single `profile` field,
which is `null` for `multiple_loops` (C2's MultiProfile) - `loops` (the
actual per-sub-profile data) was explicitly left unparsed, per the DTO's
own doc comment: *"the backend's `branch_point_ids`/`loops` (multi-loop
detail) aren't needed by either consumer"*. That was true when written
(before C1/C2 existed), and became false the moment C2 added a status
where the canvas fill *should* show something but the DTO gave it nothing
to show. This is the same category of gap as round 1's item 2 (client-side
code written before C1/C2 not being revisited once they landed).

### Fix
- `ProfileDetectionDto` (`sketch_api_client.dart`) now parses every outer
  loop into a new `ProfileLoopDto` (point ids + recursively-parsed
  `innerLoops`), from either `profile` (the `closed_loop` case, one loop)
  or `loops` (the `multiple_loops` case, 2+), exposed as
  `fillableLoops: List<ProfileLoopDto>`.
- `SketchController.closedProfilePointIds` (a single nullable
  `List<String>`) became `closedProfileFills: List<ProfileLoopDto>`.
- `SketchCanvas._paintClosedProfileFill` now fills *every* loop in
  `closedProfileFills` independently, and - new capability, not just a
  multi-profile fix - punches out each loop's holes via an even-odd
  sub-path (`Path.fillType = PathFillType.evenOdd`), so a C1 hole-in-a-plate
  sketch now correctly shows the hole as unfilled too, not just solid green
  over the whole outer boundary.

### Test coverage
- New `test/sketch_api_client_test.dart`: `ProfileDetectionDto.fromJson`
  correctly builds `fillableLoops` for a single loop with a hole, for a
  MultiProfile with 2 outer loops (one with its own hole), and returns
  none for a non-extrudable status. Runs and passes in this sandbox (no
  `flutter_scene` dependency).
- `sketch_controller_test.dart`: the two existing single-loop
  `closedProfilePointIds` tests renamed/updated for the new
  `closedProfileFills` shape - both still pass for real (`flutter test`),
  alongside the pre-existing, already-documented 4 unrelated failures in
  that file.

---

## 2 — Internal faces/hidden edges showing through solid bodies

### Report
Selected/highlighted faces on the far side of a part show through the
body, and hidden edges remain visible even at 0% body transparency (fully
opaque). Asked directly: is this a renderer limitation, and what are the
options?

### What this is and isn't
Read `flutter_scene` 0.18.1's actual render pipeline source
(`scene_encoder.dart`, `unlit_material.dart`, `polyline_geometry.dart` -
available locally in this sandbox's pub cache) rather than guessing:

- The engine **does** implement standard, correct two-phase rendering: an
  opaque pass (depth write **and** test, `lessEqual`) followed by a
  translucent pass sharing the *same* depth buffer (test only, no write,
  sorted back-to-front for correct blending). This is architecturally
  sufficient for a translucent highlight or an edge to be properly
  occluded by opaque geometry in front of it. **This is not an inherent
  flutter_scene limitation** - proper occlusion is supported.
- `PolylineGeometry` (what edges/highlights are built from) expands each
  point into a screen-facing quad at that *same point's own depth* - the
  width expansion itself doesn't corrupt depth.

### What was found and fixed
`buildMeshEdgesNode` rendered edges with `AlphaMode.opaque`, which -
confirmed via `UnlitMaterial`'s own doc comment - depth-*writes*. Combined
with round 1's towards-camera bias, an edge writes a depth value slightly
closer than its true position. That's normally harmless, but if anything
else is later depth-tested at those same pixels (another edge, or a
translucent face-highlight drawn in the same frame), it now compares
against an artificially-close value instead of the edge's real one - a
plausible contributor to exactly the reported symptom, though not
something provable without a live GPU (not available in this sandbox -
see Prompt C's own status doc).

Fixed: `buildMeshEdgesNode` now uses `AlphaMode.blend` instead of
`AlphaMode.opaque`. At the alpha values already in use (`1.0` for regular
edges, a deliberately-partial value for e.g. `_selectedEdgeColor`), this
renders pixel-identical to before for full-alpha edges while removing the
depth-write - edges are still fully depth-*tested* (so still properly
hidden behind opaque geometry), they just can no longer skew what
anything drawn afterwards tests against. This also fixes a latent,
separate bug: `AlphaMode.opaque` "ignores alpha" per `UnlitMaterial`'s own
doc comment, so `_selectedEdgeColor`'s intentionally-partial alpha
(`0.85`) was silently rendered fully opaque instead of translucent.

### Still needs on-device verification
This closes off one concrete, identified mechanism, but it was not
possible to confirm in this sandbox that it's the *only* one - there is
no GPU/display available here, and `flutter test` cannot even load any
`flutter_scene`-dependent file (the same pre-existing limitation
documented throughout this project). If internal faces/hidden edges are
still visible at 0% transparency after this fix, the next useful
diagnostic (not yet done, would need on-device iteration) is to
temporarily set `kEdgeDepthBias = 0.0` in `mesh_geometry.dart` and
retest: if hidden edges are still visible with **zero** bias, edges are
not the cause at all, and the remaining investigation should focus on the
selection/hover highlight path (`buildHighlightFacesNode`,
`_syncHoverNode`, `_syncSelectedEntityNodes` in `part_viewport.dart`) or
the main mesh material itself - none of which this round's changes
touched.

## Test/analyze results

- Client: `flutter analyze` (whole project) - no new issues (the same 2
  pre-existing, unrelated errors in `test/selection_list_drawer_test.dart`
  as every prior round). `flutter test` (whole suite) - 151 passed (+3 new,
  from `sketch_api_client_test.dart`), 17 failed - the same pre-existing
  `flutter_scene`/`flutter_gpu` file set as every prior round, unaffected
  by this one.
- Backend: unaffected by this round (no backend files changed); `pytest
  tests/` still 252 passed against the real `pythonocc-core`/`py-slvs`
  environment.
