# Direct Editing feature family - scope and design

Reference doc for the "Direct Editing" feature family: operations that edit
already-existing solid geometry directly (move a face, move/copy a body,
delete a body, scale a body, delete a face) rather than deriving it from a
Sketch. Named explicitly in `ImportFeature`'s own docstring
(`backend/app/document/models.py`) as a promised future capability ("future
features will be able to edit existing bodies (scale, move face, delete
face, move body)") and in `docs/didsa-longterm-vision-and-model.md` §2 as one
of four first-class workflow modes. This doc is the "what's the shape of
this family, and what's been built so far" lookup - `docs/status.md` is the
dated narrative log if you want the "why" behind a specific decision.

## Scope (5 features)

1. **Delete Body** - `DeleteBodyFeature` (`app.document.delete_body`).
   Removes 1+ named Bodies entirely. No "keep" mode - selecting the Bodies
   to delete IS the interaction (a client-side "select inverse" convenience
   is a UI affordance, not a second Feature type). **Implemented.**
2. **Scale Body** - `ScaleBodyFeature`. Uniform (and optionally non-uniform
   X/Y/Z) scale of a single Body about a point (default: its own
   bounding-box centre). Not yet implemented.
3. **Move/Copy Body** - `MoveBodyFeature`. Translate (delta X/Y/Z) and/or
   rotate (about a picked-edge/face/axis reference, reusing
   `PatternAxisRef`) a single Body; a `copy: bool` toggle mints a new Body
   instead of modifying in place - SolidWorks/Fusion 360 both name this one
   command "Move/Copy Body", not two. Not yet implemented.
4. **Delete Face** - `DeleteFaceFeature`. Removes a single planar face from
   a Body and heals the opening closed. Not yet implemented - needs an OCCT
   healing-approach spike (see "Move Face / Delete Face technical risk"
   below) before it can be built for real.
5. **Move Face** - `MoveFaceFeature`. Moves a single planar face (offset
   along its normal / explicit delta XYZ / along a picked edge's direction
   with a flip toggle, reusing `PatternDirectionRef`) and heals adjacent
   faces. Highest technical risk in the family - ships last, benefiting from
   Delete Face's healing spike. Not yet implemented.

Build order: Delete Body -> Scale Body -> Move Body -> Delete Face -> Move
Face (cheapest/most-precedented first).

### Move Face V2 (gated on v1 shipping and passing)

v1 scope for Move Face/Delete Face is deliberately narrow: planar faces
only, single face per Feature instance, fail closed with a structured 422
(mirroring `fillet_failed`'s convention) rather than producing bad geometry.
Do not start V2 work until v1 is implemented and its full test suite is
green. V2 expands to non-planar (cylindrical/conical) faces, multi-face
simultaneous moves (`face_refs: list[SubShapeRef]` instead of a single
`face_ref`), and neighbor-consuming offsets - reusing v1's resolver
approach and panel, not starting over.

## Architecture this family reuses (no new mechanism needed)

- **In-place modify pattern** (Fillet/Chamfer, `fillet.py`/`chamfer.py`):
  `resolve_xxx_from_bodies(bodies, feature) -> (body_id, new_shape)`
  operates on `compute_part_bodies`'s in-progress accumulator;
  `resolve_xxx(part, feature, excluded_feature_ids)` self-excludes
  `feature.id` so edit-validation isn't double-applying the Feature's own
  prior effect. Scale, Move Body (non-copy), Delete Face, Move Face all
  follow this exactly.
- **Consume/replace pattern** (`boolean.py`): `del bodies[target_id]` /
  `_register_solids(bodies, id, shape)` for minting new Bodies. Delete Body
  and Move Body's `copy=True` branch follow this.
- **Persistent references** (`SubShapeRef`, resolved via
  `resolve_subshape_from_bodies`): reused verbatim for Move Face/Delete
  Face's `face_ref`.
- **Direction/axis references** (`PatternDirectionRef`, `PatternAxisRef`):
  reused verbatim for Move Face's "direction of picked edge" and Move
  Body's rotation axis - no new reference type needed.
- **Dependency graph** (`graph.py`'s `build_feature_graph`): each Feature's
  `depends_on` is `base_feature_id(...)` over its `body_id`/`body_ids`/
  `face_ref.body_id` (+ direction/axis ref dependency if set) - mechanically
  identical to Merge's `body_ids`/Boolean's `target_body_ids` handling
  already there.
- **Client live-preview pattern** (`docs/live-preview-pattern.md`):
  - Pattern 2 (whole-body pick only, the live "bodies" list/mesh refresh IS
    the preview): **Delete Body** (eager-create on open, same shape as
    Merge's own eager-create-once-2+-Bodies-confirmed), **Scale Body**,
    **Move Body**.
  - Pattern 3 (stable-pick-body + preview-overlay, self-exclusion
    load-bearing): **Delete Face**, **Move Face** - re-pick a face of the
    same Body being modified, exactly the case that doc's own decision tree
    predicts.
- **No drag gizmo exists in this codebase anywhere.** All direction/
  position input is numeric fields + tap-to-pick geometry in the viewport,
  e.g. Extrude's distance field + `IconButton(Icons.swap_vert)` flip
  button. Move Face's "direction of edge" control follows this idiom
  exactly; do not build new drag-gizmo machinery for this family.
- **Ambient-selection entry only** (no guided "Add > Feature" FAB flow):
  every member of this family is reachable via `selection_actions.dart`'s
  `contextActionsFor` (a Body-only or single-planar-face selection) plus
  feature-tree tap-to-edit for an already-existing instance. Unlike
  Merge/Boolean/Split, none of these five have a target-vs-tool ambiguity
  (see `selection_actions.dart`'s own removed-Boolean-family comment for why
  those *don't* appear in the ambient table) - every one is safe to offer
  directly from `contextActionsFor`.

## Move Face / Delete Face technical risk

OCCT/pythonocc-core has no single high-level "synchronous move-face-and-
heal-neighbors" solver the way SolidWorks' Direct Editing tab does. Before
writing `move_face.py`/`delete_face.py` for real, run a short throwaway
pythonocc-core spike on a simple test solid (a box) to confirm the actual
working approach. The most promising candidate - because it reuses an API
family (`BRepAlgoAPI_Cut`/`BRepAlgoAPI_Fuse`) already used heavily in this
codebase and has a direct precedent (`split.py`'s own documented "build an
oversized block, boolean it in" technique, not `BRepAlgoAPI_Splitter`) - is:
build a solid representing the material added/removed by the face's
movement (or removal) and boolean it into the target Body.
`BRepOffsetAPI_MakeOffsetShape`'s per-face-offset/remove-face modes are a
secondary candidate to check. Do not commit to exact OCCT class/method
names until the spike confirms them - do Delete Face's spike first (it's
the simpler of the two: pure removal, no directional offset to reason
about), and let its findings inform Move Face's own implementation.
