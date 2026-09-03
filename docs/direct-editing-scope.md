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
   `test_feature_delete_face.py` pass). **Client implemented** - ambient
   entry only (a single planar face of a solid Body selected), no re-
   picking a different face mid-session (simpler than Fillet's own
   continuous-re-pick Pattern 3 shape from `docs/live-preview-pattern.md` -
   deferred as a fast follow, not risked in this pass); `DeleteFacePanel`
   mirrors `DeleteBodyPanel`'s minimal shape exactly.
5. **Move Face** - `MoveFaceFeature`. Moves a single planar face (offset
   along its normal / explicit delta XYZ / along a picked edge's direction,
   reusing `PatternDirectionRef`) via extrude-the-face-profile +
   `BRepAlgoAPI_Fuse`/`Cut` (see `app.document.move_face`'s own module
   docstring). **Backend implemented in full and verified against a real
   pythonocc-core run** (all 14 tests in `test_feature_move_face.py` pass,
   including all three modes, overshoot rejection, and mode-switching on
   update). **Client v1 scope is offset-along-normal mode only** -
   `MoveFacePanel` has a single numeric field, mirroring `ScaleBodyPanel`'s
   own debounced-live-preview shape; the backend's own `delta`/
   `direction_ref`+`direction_distance` modes have no client entry point
   yet (same "backend-ready, client not wired" treatment `rotation_axis`
   gets on Move Body) - a pure client-side addition when it happens, no
   backend change needed. Also ambient-entry-only, face fixed once picked,
   same reasoning as Delete Face above.

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
(2026 pre-existing tests, gear family included) with zero regressions,
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

### Spike findings (2026-09-03) - throwaway pythonocc-core spike, no shipped code

v1's gate ("v1 implemented and its test suite green") is satisfied, so this
session ran the throwaway OCCT spike V2 was gated on - same methodology as
Delete Face/Move Face v1's own spikes (build real geometry, poke every
boundary condition, don't trust a single hand-picked "it worked" case). No
production code changed; this is resolver-design input only, same as the
Gear Design workstreams' own "investigate/prototype only" spike entries in
`docs/status.md`.

**The headline finding: v1's own technique (extrude-the-face-profile +
`BRepAlgoAPI_Fuse`/`Cut`, see `app.document.move_face`'s own module
docstring) does NOT generalize to V2 and should not be extended - it's a
prism-sweep, which only coincides with a true face offset for a *planar*
face pushed along a straight vector.** V2 instead needs OCCT's own
dedicated variable-offset engine, `BRepOffset_MakeOffset` (the lower-level
class `BRepOffsetAPI_MakeOffsetShape` wraps for the whole-shape case) -
not previously used anywhere in this codebase:

```python
mo = BRepOffset_MakeOffset()
mo.Initialize(shape, 0.0, tol, BRepOffset_Skin, False, False,
              GeomAbs_Intersection, False, False)  # global offset 0.0 - untouched faces stay put
for face, offset in face_offsets:                  # one or many faces
    mo.SetOffsetOnFace(face, offset)                # signed along the face's own outward normal
mo.MakeOffsetShape()
result = mo.Shape()
```

Confirmed working, in one `MakeOffsetShape()` call each:

- **Non-planar faces**: a cylindrical face's own `SetOffsetOnFace` grows/
  shrinks its radius by exactly the offset value (`r=5` -> `r=6` for
  offset `+1.0`, volume matches `π·r²·h` exactly) - the *same* signed-
  along-outward-normal convention v1's planar `offset_distance` already
  uses, so `MoveFaceFeature`'s existing sign convention needs no change
  for V2 to reuse it on a cylindrical `face_ref`. Conical faces weren't
  spiked (no OCCT-level reason to expect different behaviour from
  cylindrical, since both are single-parameter analytic surfaces to this
  algorithm, but not confirmed).
- **Multi-face simultaneous moves**: calling `SetOffsetOnFace` once per
  face before a single `MakeOffsetShape()` naturally does the whole
  `face_refs: list[SubShapeRef]` job in one resolver call - confirmed with
  two unrelated faces of the same Body offset by different amounts in one
  pass, including one offset large enough to fully consume a third
  feature (below). This replaces v1's "one face, one Fuse/Cut" loop shape
  entirely rather than just repeating it per face - a materially simpler
  resolver than the "loop v1's own technique N times" approach the scope
  doc originally implied.
- **Neighbor-consuming offsets**: pushing a small boss's own top face
  inward by *exactly* its own height produces a valid, correctly-healed
  result indistinguishable from the boss never having existed (confirmed
  via bounding box and face count) - genuinely "consuming" the neighbor
  feature, not just failing safely. Pushing further still (past zero,
  i.e. asking for negative remaining material) fails closed correctly.

**Two gotchas, both required reading before implementing, mirroring the
fail-closed rigor v1's own spike already established:**

1. **`IsDone() == True` and `Error() == BRepOffset_NoError` are NOT
   sufficient success signals - `Shape()` can silently return `None` even
   when both report success.** Confirmed reproducibly: an offset large
   enough to fully consume *and overshoot past* a neighboring feature
   reports `IsDone=True, Error=0` (no exception, no warning value) yet
   `Shape()` is `None`. `resolve_move_face_v2_from_bodies` (or whatever
   V2's resolver is named) must fail closed on
   `shape is None or shape.IsNull()` in addition to `IsDone()`, the same
   "don't trust the obvious success signal alone" shape `delete_face.py`'s
   own bounding-box-growth check already established for a different
   reason.
2. **The technique reliably fails - same silent-`None`-`Shape()` signature
   as above - on a coincident-plane boss/step joint built via
   `BRepAlgoAPI_Fuse`, even for a trivially small, nowhere-near-consuming
   offset - *unless* the input shape is first run through
   `ShapeUpgrade_UnifySameDomain` to merge the coincident/coplanar faces
   the Fuse left behind.** This is not an edge case: every Boss feature in
   this codebase (`extrude.py`'s own `_apply_feature_to_bodies`) builds
   exactly this kind of coincident-plane joint via `BRepAlgoAPI_Fuse`
   whenever a boss lands flush on an existing face, so most real multi-
   feature Parts would hit this without the unify step. With
   `ShapeUpgrade_UnifySameDomain` run first, every case above (including
   the full-consumption case) works correctly.

   This surfaces a real, **unresolved** resolver-design question, not a
   detail to paper over during implementation: `SubShapeRef.index` is a
   `topexp.MapShapes` enumeration index captured at reference-creation
   time against a Body's shape as `compute_part_bodies` currently produces
   it (see `SubShapeRef`'s own docstring in `models.py`) - unifying same-
   domain faces changes both the face *count* and *order* (11 faces -> 9
   in the spike's own boss/base test), so resolving a `face_ref` captured
   pre-unify against a post-unify shape is not guaranteed to hit the same
   face, or any face at all. Running the unify lazily inside V2's own
   resolver (only when it needs to offset a face) would desync V2's own
   `face_ref`s from the indices the client captured them against. Making
   `compute_part_bodies` unify same-domain faces unconditionally for every
   Feature (not just V2's) would fix that desync going forward, but is a
   change to the shared accumulator every existing Feature type
   (Fillet's `edge_refs`, Create Plane's `face_ref`, Pattern's axis refs,
   v1 Delete Face/Move Face's own `face_ref`) resolves sub-shapes against
   - any `SubShapeRef` already stored in an existing saved Part was
   captured against the *current*, non-unified numbering, and unifying by
   default could silently invalidate it. This needs a real design pass
   (most likely: unify once, at Body-creation/mesh-generation time, before
   any `SubShapeRef` is ever captured against a Body - not as a
   V2-resolver-local step) before V2 implementation starts, not something
   to improvise mid-implementation.

**Not spiked / still genuinely open**: conical faces specifically (see
above); the exact structured-422 failure-type names/messages V2 should use
for its two new failure modes; whether `GeomAbs_Intersection` (required -
the default `GeomAbs_Arc` join type failed outright on a plain box in this
same spike) has its own failure modes on more complex real Part topology
than the box/boss/cylinder primitives tested here.

### Spike findings addendum (2026-09-03) - follow-up spike: FACE-order equivalence and conical faces

Same-session follow-up, closing the two questions the spike above left
open before any go/no-go decision on the unify-related compat break. Still
throwaway/no shipped code - a second confirmatory pass, not implementation.

**FACE-order equivalence - confirmed safe.** The open risk was whether
`TopExp_Explorer(shape, TopAbs_FACE)` iteration order (`mesh.py`'s
`tessellate_shape`, which assigns the client's own `face_id`) still
coincides with `topexp.MapShapes(shape, TopAbs_FACE, ...)` order
(`resolve_subshape_from_bodies`'s own `SubShapeRef.index` resolution)
*after* a `ShapeUpgrade_UnifySameDomain` pass, not just before. Tested
against four representative multi-feature bodies - a single boss on a
box (the original spike's own case, 11 faces -> 9 post-unify), two bosses
at different heights on one box (16 faces, unchanged by unify - no
coincident planes between the two bosses themselves), a box with a
through-hole *and* a boss (12 faces, likewise unchanged), and an
asymmetric three-level staircase (16 faces -> 10 post-unify) - by directly
diffing the two orderings face-by-face (via `TopoDS_Face.IsSame`, not just
comparing counts) both before and after unify. **The two orderings matched
exactly in all four cases, both pre- and post-unify, with zero exceptions**
- unify does not introduce any new divergence between what the client's
`face_id` numbering means and what `SubShapeRef.index` resolves to. This
directly de-risks the `_apply_feature_to_bodies` unify insertion point the
first spike's own backend exploration identified: gating it with a
`unify: bool` parameter (`False` from `compute_part_bodies_coarse`) remains
the right shape, and this addendum finds no additional numbering hazard
beyond the already-known `SubShapeRef`-index compat-break question itself
(still open - see above, this addendum doesn't resolve *that*, only rules
out a second, distinct risk stacking on top of it).

**Conical faces - confirmed working, with one real UX nuance for a future
client to account for (not a blocker).** Repeated the first spike's
cylindrical-face `SetOffsetOnFace` test against a real truncated cone
(`BRepPrimAPI_MakeCone`, base radius 5, top radius 2, height 10) - every
offset tried (`+0.5`, `+1.0`, `-0.5`, `-1.0`) produced a valid result,
still a genuine cone (confirmed via `BRepAdaptor_Surface.GetType() ==
GeomAbs_Cone` on the result's own side face, not just "some curved face"),
volume changing correctly in the expected direction (positive = grows,
negative = shrinks) for both. The nuance: **a cone's radius growth is not
equal to the offset value**, unlike a cylinder's exact 1:1 relationship
(confirmed again here as a direct side-by-side reference: cylinder r=5,
offset `+1.0` -> r=6 exactly, volume 1130.97 matching `π·6²·10` to 4
decimal places). A cone's own surface normal has both a radial and an
axial component (it's not purely radial the way a cylinder's is), so
offsetting *along the true surface normal* - the geometrically correct
operation `BRepOffset_MakeOffset` actually performs - moves the base
radius by `offset / cos(θ)`, where `θ = atan(Δr / Δh)` is the cone's own
half-angle from its axis (confirmed numerically: `offset=+0.5` grew the
base radius from `5.0` to `5.522`, and `0.5 / cos(atan(0.3)) = 0.522`
exactly, matching `θ = atan((5-2)/10) = atan(0.3)` for this cone). This is
correct, expected OCCT behaviour for a *true* face offset, not a bug - but
it means a future client "offset a conical face by X" UI cannot promise
"the radius grows by exactly X" the way it legitimately can for a
cylindrical face, and should either say "offset along the surface normal"
generically or compute/display the resulting radius change separately if
a radius-specific readout is wanted. No change to V1's own client scope
(planar-only) is implied by this - purely a V2 client-UI note for
whenever that work starts.

### Delete Face V2 spike findings (2026-09-03) - multi-face and non-planar removal

Delete Face had no V2 spike at all before this - v1's own spike (this
module's own docstring, `app.document.delete_face`) only ever called
`BRepAlgoAPI_Defeaturing.AddFaceToRemove` once per `Build()`, and only
ever removed a Fillet-generated blend face or a Chamfer's own planar
face, never two faces at once and never an arbitrary primitive non-planar
face. This throwaway spike (real pythonocc-core, same bootstrapped env)
closes those two gaps plus the first V2 spike's own flagged-but-untested
unify-vs-Fillet/Chamfer risk, before any Delete Face V2 code is written.

**Multi-face removal in one `Build()` call - confirmed working.**
`AddFaceToRemove`'s own name (not `SetFaceToRemove`) turned out to mean
exactly what it implies: calling it twice before one `Build()` removes
both faces in a single, correctly-healed pass. Removing both of a box's
two independently-filleted edges' own blend faces at once restored the
*exact* original sharp box (`IsDone=True, HasWarnings=False`, 6 faces,
volume 1000.0000 - bit-for-bit the same numbers a single-face removal
already produced). The "no natural heal" case - removing both top faces
of two independent bosses on the same box, with nothing for OCCT to heal
into - correctly reports `HasWarnings=True` (the same documented signal
v1's own single-face silent-no-op case uses), with the returned shape's
own volume unchanged from before removal (2066.0000, the pre-removal
volume exactly) - i.e. the existing `not IsDone() or HasWarnings()`
fail-closed check already in `delete_face.py` catches the multi-face
no-heal case with zero changes needed to that check itself.

**Arbitrary (non-fillet-blend) non-planar face removal - confirmed
working, with the same documented fail-closed signal.** Removing a plain
box's own through-hole cylindrical wall (not a fillet blend) restored the
exact original solid box (`HasWarnings=False`, 6 faces, volume 1000.0000)
- the technique isn't fillet-blend-specific, a genuinely arbitrary
primitive cylindrical face works too. A conical boss's own side wall, with
no natural heal available (same "nothing to heal into" shape as the
multi-boss case above), correctly reports `HasWarnings=True` with the
volume unchanged from the pre-removal shape (1054.4543, matching the
original box-plus-cone-frustum volume exactly) - the existing
`HasWarnings()` signal generalizes to non-planar faces without any new
detection logic.

**Unify vs. Fillet/Chamfer tangent surfaces - confirmed safe, but only
once tested against the actual combined-risk topology.** A first attempt
(a boss placed fully *inside* a box's own top face, away from its edges)
was inconclusive - that topology's own Boolean output never fragmented
the box's own top face into separate coincident pieces in the first
place, so unify was correctly a no-op there but proved nothing about the
real risk. Rebuilding with the *actual* risk topology (a boss flush with
the box's own corner/edges - the same shape the first V2 spike's own
coincident-plane finding used) plus a Fillet on one of the boss's own top
edges, right next to the fragmented coincident-plane joint, gave a
conclusive answer: pre-unify, 12 faces (1 cylindrical fillet blend + 11
planar, matching the un-filleted case's own 11); post-unify, 10 faces (the
same 2-face reduction the pure boss/base case already showed, 11 -> 9,
plus the fillet blend carried through unchanged) - **still exactly 1
cylindrical face, unchanged volume, still valid, and `TopExp_Explorer`
still matches `topexp.MapShapes` face-for-face** both before and after.
`ShapeUpgrade_UnifySameDomain` correctly distinguishes the curved fillet
surface from the coincident planar patches it's tangent to and merges
only the latter - it does not incorrectly fold a Fillet/Chamfer's own
blend face into an adjacent planar one.

**Conclusion**: nothing found in this spike narrows Delete Face V2's
scope below the full "multi-face + non-planar" the user asked for - both
confirmed working with the existing fail-closed contract (`HasWarnings()`)
generalizing cleanly, and the shared `unify` step confirmed safe against
the specific tangent-surface risk the first V2 spike flagged but never
tested. Delete Face V2 can proceed on the same technique (`BRepAlgoAPI_
Defeaturing`, one `AddFaceToRemove` call per face in `face_refs`, one
`Build()`) v1 already uses, just without the single-face/planar-only
restrictions.

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
    load-bearing) is what that doc's own decision tree predicts for
    **Delete Face**/**Move Face** (re-picking a sub-shape of the same Body
    being modified) - but the *shipped* v1 client deliberately doesn't
    build that full continuous-re-pick machinery: the face is fixed once
    picked, with no mid-session re-pick loop at all, so there's no "stable
    pick body" to keep stable. Both instead follow the simpler Pattern-2-
    shaped lifecycle (`DeleteFacePanel` mirrors `DeleteBodyPanel`'s eager-
    create shape, `MoveFacePanel` mirrors `ScaleBodyPanel`'s debounced-
    single-field shape) keyed on a `SubShapeRef` instead of a body id. The
    backend's own self-exclusion (`resolve_delete_face`/`resolve_move_face`
    excluding their own feature id) still matters for correct PATCH re-
    validation regardless of what the client does. A continuous re-pick
    loop (the real Pattern 3 shape) is a fast-follow if ever needed, not a
    gap in this pass - deliberately deferred rather than risked in the
    same pass as these two panels' first ship.
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
