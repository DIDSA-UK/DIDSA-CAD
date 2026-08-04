# Workstream 7 — DXF import with block semantics

Read `00-conventions.md` first. No dependency on other gear workstreams —
this extends `ImportFeature`, which already exists.

## Grounding: why this is mostly reuse, not a new mechanism

A direct audit of the client's selection architecture found: `SketchSelection`
(`{kind, id}`, `client/lib/sketch/sketch_controller.dart`) is a flat list
with no compound/grouped-selection container anywhere. Rectangle/Polygon/
Slot are deliberately *not* selected as a unit (tapping one selects a
single constituent Line/Point — `SketchRectangleView`'s own doc comment
confirms this). Pattern/Mirror's `ownerInstanceId` grouping
(`_patternMirrorEntityAt`, `hitTestSketchPatternMirrorInstances` in
`client/lib/viewport3d/selection_hit_test.dart`) is the one real "many hit
regions → one id" precedent, but only works because those instances are
pure ghost geometry with no independent underlying primitives — not
applicable here, since a DXF block's curves need to be real, individually
addressable entities for Convert Entities to reach.

What *does* fit: `SelectionEntityKind.body` (`selection_hit_test.dart`)
already exists and already is "select the whole thing as one unit" —
normally a tap resolves to a specific face/edge/vertex, but with
`SelectionFilterState.body` engaged, it resolves to the whole owning Body
instead (already used for e.g. Boss/Cut target-body picking). Convert
Entities (`convert_body_edge`/`convert_body_vertex`,
`backend/app/document/router.py`) is already Body-edge-to-Sketch, one
edge per tap, structurally separate from ordinary viewport tap-selection
(`SketchMode.convert` is its own dedicated picking mode). Both halves of
the "block" requirement already exist — they just aren't wired to the
same object yet.

## Resolved design, four pieces

1. DXF import is a new `ImportSourceFormat.DXF` value on the *existing*
   `ImportFeature` (no new Feature type) — a lightweight, non-solid
   reference `Body` (a wireframe/compound of real OCCT edges, no volume —
   `ImportFeature` already round-trips STEP/glTF/OBJ/STL into a `Body`
   the same way).
2. **`ImportFeature` gains placement fields** (translation, rotation,
   uniform scale — matching `TextEntity`'s own "uniform-scale-about-
   center" convention, since non-uniform scale would distort a
   mechanical drawing's proportions), applied to the parsed shape before
   it registers as a Body. General-purpose — benefits STEP/mesh imports
   too, not just DXF; fulfils `ImportFeature`'s own docstring, which
   already names "move body" as an anticipated capability. **This is
   what "moved, rotated, scaled as a block" means** — editing this
   Feature's own placement via a small dedicated panel, not dragging
   loose sketch points (which would hit this app's known "associative
   point drag snaps back on next solve" gap — deliberately avoided by
   never treating a block's rendered geometry as directly draggable).
3. **"Selects as one"**: one small, targeted rule — a Body whose
   originating Feature is a DXF `ImportFeature` always resolves as
   `SelectionEntityKind.body` on an ordinary tap, regardless of the
   general `SelectionFilterState`. Necessary because a DXF-sourced Body
   is wireframe-only (no faces to hit-test against), so without this
   override, ordinary tapping falls through to individual-edge picking
   by default instead. Applies everywhere the Body is visible, no
   context restriction needed.
4. **"Individually elsewhere, via Convert Entities"** — completely
   unmodified. Pick one edge of the DXF Body at a time, exactly like
   picking an edge from any other Body today. Zero new scope.

## Complexity/risk

Medium — the DXF parsing itself (`ezdxf`'s reader, comparatively
straightforward), `ImportFeature`'s new placement fields (small,
additive), and the one targeted whole-body-selection override (item 3).
None of this carries the "nothing like this exists anywhere in this
codebase" risk profile `10-bevel-gear.md`'s construction does.
