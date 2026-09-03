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
2. **Scale Body** - `ScaleBodyFeature`. Uniform scale of a single Body about
   its own bounding-box centre (non-uniform X/Y/Z deferred - see
   `app.document.scale_body`'s own module docstring). **Implemented.**
3. **Move/Copy Body** - `MoveBodyFeature`. Translate (delta X/Y/Z) and/or
   rotate (about a picked-edge/face/axis reference, reusing
   `PatternAxisRef`) a single Body; a `copy: bool` toggle mints a new Body
   instead of modifying in place - SolidWorks/Fusion 360 both name this one
   command "Move/Copy Body", not two. **Backend implemented in full**
   (translate + rotate + copy, all wired through `resolve_move_body`/the
   REST endpoints). **Client v1 scope is translate + copy only** -
   `MoveBodyPanel` has no rotation-axis-picking UI yet. Picking a rotation
   axis in the viewport needs its own mid-panel picking-step (the same
   shape Mirror's plane-picking stage already has: swap the selection
   filter mid-session, add a dedicated "tap an edge/face/line to define the
   axis" moment) - deliberately deferred as a fast follow rather than
   risked in the same pass as the panel's first ship. The backend accepting
   `rotation_axis`/`rotation_angle_degrees` already, and the client simply
   never setting them (and never sending them on PATCH, which the router's
   own "omitted keeps current" convention already preserves correctly),
   means this is a pure client-side addition when it happens - no backend
   change needed.
4. **Delete Face** - `DeleteFaceFeature`. Removes a single planar face from
   a Body and heals the opening closed, via OCCT `BRepAlgoAPI_Defeaturing`
   (see `app.document.delete_face`'s own module docstring for the real
   spike findings, including a serious "succeeds with no warning but
   produces the wrong geometry" case only found by testing every face of a
   real chamfered box, not just one). **Backend implemented in full and
   verified against a real pythonocc-core run** (all 7 tests in
   `test_feature_delete_face.py` pass). Client not yet wired.
5. **Move Face** - `MoveFaceFeature`. Moves a single planar face (offset
   along its normal / explicit delta XYZ / along a picked edge's direction,
   reusing `PatternDirectionRef`) via extrude-the-face-profile +
   `BRepAlgoAPI_Fuse`/`Cut` (see `app.document.move_face`'s own module
   docstring). **Backend implemented in full and verified against a real
   pythonocc-core run** (all 14 tests in `test_feature_move_face.py` pass,
   including all three modes, overshoot rejection, and mode-switching on
   update). Client not yet wired.

Build order: Delete Body -> Scale Body -> Move Body -> Delete Face -> Move
Face (cheapest/most-precedented first) - followed exactly; Delete Face's
spike (and the real bug it caught) directly informed Move Face's own
validation.

### How the backend was actually verified

This sandbox has no pythonocc-core/fastapi by default (see every resolver
module's own "needs a real pythonocc-core environment" docstring note) -
but for this feature family, a real conda-forge environment (pythonocc-core
7.9.3 novtk + fastapi/pytest/httpx/py-slvs, matching `environment.yml`
exactly) was bootstrapped via `micromamba` to spike, implement, and run the
*actual* test suite before shipping, not just pattern-match against
precedent. This caught two real bugs pattern-matching alone would have
missed:
- `MoveBodyFeature`/`MoveBodyFeatureCreate`'s `copy` field collided with
  `pydantic.BaseModel.copy()` (a runtime `UserWarning`, silently shadowing
  the inherited method) - renamed to `make_copy` everywhere (dataclass,
  schemas, router, native_format, client wire key).
- `BRepAlgoAPI_Defeaturing` (Delete Face's own OCCT tool) reports
  `IsDone=True, HasWarnings=False` - genuinely no warning - for removing
  the *wrong* face of a chamfered box, yet silently returns a Body
  stretched several units past its own original bounding box, not healed
  back correctly. Only found by testing every face of a real chamfered box
  in turn, not one hand-picked "it worked" case. `delete_face.py` now adds
  its own bounding-box-growth sanity check on top of `HasWarnings()` - see
  that module's own docstring for the full reasoning and the real numbers.

All 5 backends were run against the full existing backend test suite
(1469+ pre-existing tests, non-gear-family subset) with zero regressions,
plus each new feature's own dedicated test file, all passing for real.

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

## Move Face / Delete Face technical risk (resolved)

OCCT/pythonocc-core has no single high-level "synchronous move-face-and-
heal-neighbors" solver the way SolidWorks' Direct Editing tab does - this
was the real risk this section originally flagged before either resolver
was written. A real pythonocc-core spike (see "How the backend was
actually verified" above) found two different, working techniques rather
than one shared one:

- **Delete Face**: `BRepAlgoAPI_Defeaturing` - not this codebase's own
  invention, OCCT's own dedicated tool for removing a feature face and
  healing the surrounding topology (originally built for defeaturing
  imported/dumb-solid CAD models, which is the same problem). The
  originally-guessed "oversized block, boolean it in" idiom
  (`BRepOffsetAPI_MakeOffsetShape`/`split.py`'s own technique) turned out
  not to fit - it has no natural way to *heal* a Body after removing one of
  its faces, only to divide a Body along a cutting tool. See
  `app.document.delete_face`'s own module docstring for the fail-closed
  contract this required (`HasWarnings()` plus a bounding-box sanity check
  - `IsDone()` alone is not enough, confirmed by real testing).
- **Move Face**: the originally-guessed "oversized block, boolean it in"
  idiom *does* fit here - extrude the target face's own profile along the
  movement vector into a prism (`BRepPrimAPI_MakePrism`, the same
  primitive `split.py` already uses), then `BRepAlgoAPI_Fuse`/`Cut` it into
  the Body depending on the movement vector's sign relative to the face's
  own outward normal. Confirmed working for offset-along-normal, arbitrary
  delta (including a sheared/tangential component), and direction-of-edge
  modes, plus a degenerate-direction rejection and an overshoot-past-the-
  Body's-own-extent rejection - see `app.document.move_face`'s own module
  docstring.
