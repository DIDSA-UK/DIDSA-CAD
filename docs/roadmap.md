# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## OPEN — C3 residual edge/face-highlight occlusion bug

**Symptom**: edges and highlighted/selected faces on the far side of solid
geometry render through it instead of being occluded, when they shouldn't
be — worse (more visible) the fewer occluding layers of geometry sit in
front of them. Precisely: "when the edges are behind 1 face they're
visible, behind 2 faces they're visible, behind 3 faces they're no longer
visible." Reproduced on a comb/serrated part and a disc-with-square-hole
part, viewed statically (not just mid-orbit).

**Ruled out** (see `docs/status.md`'s 2026-07-01/07-02 entries for the full
investigation):
- Render-graph/pass-structure — `flutter_scene` 0.18.1 builds exactly one
  `RenderTarget`/`SceneEncoder` per frame; traced directly in source.
- MSAA — forcing `AntiAliasingMode.none` in-app was a real, confirmed
  partial improvement (fixed the "gross" bleed-through) but did not fix the
  residual 1–2-face pattern. Android's system-level "Force 4x MSAA" toggle
  makes no difference either way.
- Edge depth-bias direction — confirmed correct (towards camera, not away
  from mesh center).
- Edge depth-bias magnitude — tested across a 40x range (0.05 to a
  deliberately extreme 2.0 diagnostic value) with **zero** change to the
  qualitative pattern. This rules out a depth-precision/z-fighting
  explanation.
- Alpha-mode/depth-write configuration on edges — `buildMeshEdgesNode`
  switched from `AlphaMode.opaque` (depth-writes) to `AlphaMode.blend`
  (depth-tests only) — a real, confirmed fix for a related-but-separate
  depth-corruption bug, but did not resolve this residual pattern either.

**Current leading theory**: a GPU hardware/driver behavior below the level
`flutter_gpu`'s public API exposes — specifically Adreno GPUs'
hierarchical/low-resolution early-Z rejection hardware ("LRZ"), which has a
documented history on Qualcomm hardware of exactly this failure signature:
a single occluding depth write failing to properly populate/be respected by
the coarse Z structure, while several occluding writes converge to the
correct (occluded) result. Test device: Samsung Galaxy S23 Ultra (SM-S918B,
Adreno 740). There is no public API in `flutter_gpu`/`flutter_scene` 0.18.1
to disable or influence this hardware path.

**Next-step options**:
- (a) Test on non-Adreno hardware (e.g. a Mali or Apple-GPU device) to
  confirm or rule out hardware-specificity — if the bug disappears on
  different silicon, that strongly confirms the LRZ theory.
- (b) File a minimal repro upstream against `flutter/flutter` or
  `bdero/flutter_scene` — this needs a live GPU to build a reduced repro
  project, not achievable in the current sandbox.
- (c) Try a cheap double-draw/extra-depth-write experiment on the off
  chance it works around the hardware behavior (e.g. drawing opaque
  geometry twice, or writing a conservative depth pre-pass) — low
  confidence, cheap to try given the mechanism is still not fully
  understood.
- (d) Accept as a known hardware/driver limitation and pursue the
  previously-deferred "hidden lines" view mode (see below) as a
  product-level workaround — dashed/differently-styled hidden-edge
  rendering sidesteps the occlusion problem rather than solving it.

Current shipped state (deliberately left as-is, not reverted): `kEdgeDepthBias = 0.05`
(`client/lib/viewport3d/mesh_geometry.dart`) and
`Scene()..antiAliasingMode = AntiAliasingMode.none`
(`client/lib/viewport3d/part_viewport.dart`'s `initState`) — both are net
improvements over earlier states even though neither fixes this residual
bug; reverting either would only reintroduce previously-fixed regressions.

---

## Other open items

- **"Hidden lines" view mode.** Mentioned by the user as a wanted future
  addition, and now also a candidate product-level workaround for the C3
  bug above (option (d)). Not implemented. Would need its own render-mode
  entry (alongside Shaded / Shaded+Edges / Wireframe) that renders
  occluded edges distinctly (e.g. dashed) rather than hiding or bleeding
  them through.
- **Prompt F: Revolve — confirmed working on-device.** Closest of
  the three new C/D/E-successor prompts (Revolve → Sweep → Boolean) to
  Extrude: consumes a closed Profile the same way, produces a solid the same
  way, full Boss/Cut parity from day one (`mode: BOSS | CUT`,
  `target_body_ids`, identical validation shape to `ExtrudeFeature`) - the
  only new concept is the axis, a Sketch **Line** reference
  (`SketchEntityRef`, restricted to Line; Point/Circle rejected as
  `invalid_axis_ref`). Two flagged design decisions were resolved by asking
  directly rather than assumed: the axis Line is **not** required to belong
  to the same Sketch as the Profile (cross-sketch allowed, resolved via its
  own owning SketchFeature's basis independently of the Profile's), and the
  axis Line **is** allowed to be one of the Profile's own entities (no
  self-reference rejection). The third flagged question (does Cut-mode need
  Fillet/Chamfer's dual-mesh preview overlay?) was resolved by re-reading
  `docs/live-preview-pattern.md`'s own decision tree, not by asking: Revolve's
  Cut only ever does Body-level `target_body_ids` picks (never sub-shape
  picks of the body being cut), so it uses Extrude's simple `isPreviewMesh`
  pattern, not the dual-mesh overlay - the prompt text's own suggestion that
  it "likely needs" the overlay didn't hold up against the documented
  criterion. Backend: new `RevolveFeature`/`RevolveMode` (`app/document/
  models.py`); new `app/document/revolve.py` (`BRepPrimAPI_MakeRevol`,
  `invalid_axis_ref`/`revolve_failed` structured errors - the prompt's own
  third error type, `mixed_body_selection`, was skipped as inapplicable:
  Boss/Cut `target_body_ids` has no per-edge same-body constraint the way
  Fillet/Chamfer's `edge_refs` does, and Extrude's own Cut has no such
  concept either); `app/document/extrude.py` gained a shared
  `_apply_boss_or_cut` helper (extracted from its own `compute_part_bodies`
  ExtrudeFeature branch) so Revolve's identical Boss/Cut fuse/cut/
  merge-tiebreak/body-split dispatch isn't duplicated, plus `face_for_profile`/
  `EXTRUDABLE_STATUSES` made public for Revolve's own reuse; `graph.py` gained
  `RevolveFeature` dependency edges (profile Sketch **and** axis Sketch,
  separately, deduplicated - not the same edge every time, since cross-Sketch
  axis is allowed); `router.py`/`schemas.py` gained
  `RevolveFeatureCreate/Update/Response` and `POST/PATCH .../revolve-features
  [/{id}]`, unlocked from the start, eagerly validating via `resolve_revolve`
  before persisting (mirrors Fillet/Chamfer's fail-closed convention, stricter
  than Extrude's own lazy-only validation, since the axis is genuinely new
  and error-prone); `_validate_target_body_ids` generalized to accept a Body
  from either an `ExtrudeFeature` or a `RevolveFeature`. 7 new pure-Python
  graph tests (`test_stage_f_graph.py`) genuinely executed (47/47 passing
  alongside every other pure-Python graph/geometry test file in this
  sandbox); `test_stage_f_revolve.py` (real-OCCT HTTP surface) `ast.parse`/
  `pyflakes`-verified only, per the standing sandbox caveat. Client:
  `FeatureDto` gained `axisRef`/`angle`/`mode`; `createRevolveFeature`/
  `updateRevolveFeature` mirror Extrude's own methods; new `RevolvePanel`
  (Boss/Cut toggle + angle field + axis/target-body status lines, mirrors
  `ExtrudePanel`'s session shape); `part_screen.dart` gained a full separate
  Revolve state/method block (mirrors Extrude's, not shared) - notably a new
  combined selection filter (`_revolveSelectionFilter`, allows both
  `sketchLine` and `body` hits at once, unlike Extrude's bodies-only
  override) since a Revolve session picks one axis Line *and* zero-or-more
  target Bodies simultaneously, with `_toggleSelectedEntity`'s new
  Revolve special-case routing a `sketchLine` tap to axis-replacement
  (single reference, not accumulated) while a `body` tap falls through to
  the ordinary toggle-add/remove Extrude's own target-body picking already
  uses. Entry points: enabled via the same mechanism Extrude's own
  "Extrude" action already uses (the Feature-tree long-press context menu,
  `showFeatureContextMenu`'s new `showRevolve`/`canRevolve` params, same
  closed-profile eligibility check reused directly) and the "Add" FAB's
  Feature picker (previously a disabled placeholder); **note**: the prompt's
  own text framed this as "`contextActionsFor`: enable Revolve from a Sketch
  selection" - but `contextActionsFor` (`selection_actions.dart`) only ever
  gates Body-sub-shape/plane/sketch-entity *viewport* selections, and
  Extrude's real enabling condition was never there in the first place (it's
  the tree long-press), so Revolve's own enabling mirrors Extrude's *actual*
  mechanism instead of literally touching that function. **Confirmed working
  on-device** by the user directly.
- **Bug fix (on-device feedback, post-Revolve): mesh display could go stale
  after Fillet/Chamfer/Extrude/Revolve/Sketch operations.** Reported
  scenario: creating a Fillet on a Body that already had a Chamfer left the
  viewport showing the pre-Fillet shape until an unrelated later action
  (adding a second Chamfer) happened to trigger a repaint - hover
  hit-testing already reflected the new Fillet's topology correctly (it
  reads `_bodies` directly, not through the last-painted frame), proving
  the fetch itself succeeded; only the repaint never happened. Root cause:
  `_refreshMesh`/`_refreshFeatures`/`_refreshSketchGeometries`/
  `_refreshFilletPreviewMesh`/`_refreshChamferPreviewMesh` all mutated
  their target state fields directly, with no `setState` of their own -
  relying entirely on whichever caller happened to `setState` afterward
  (usually `_runGuarded`'s own `_busy` bookkeeping) to trigger a repaint by
  accident. Fixed by wrapping each one's own field mutation in its own
  `setState` (with a `mounted` guard for the async gap) so a repaint is
  never left to chance - a pre-existing pattern across the whole file, not
  something Revolve introduced, so this also makes Revolve's own live
  preview more reliable.
- **Prompt G: multi-profile Sketch selection for Extrude/Revolve.** Two
  related gaps closed together, scoped via an explicit back-and-forth
  rather than assumed: (1) a Sketch with a mix of open and closed profiles
  used to fail the *entire* Sketch as `NO_LOOP`/`BRANCH`, even past a
  genuinely usable closed loop, since `detect_profile` walked the whole
  sketch as one connectivity graph rather than classifying each connected
  component independently; (2) a Sketch with 2+ closed profiles always
  used *all* of them (an implicit MultiProfile compound), with no way to
  pick a subset. Backend: `detect_profile` (`app/sketch/profile.py`)
  relaxed to per-connected-component classification - a component is a
  usable closed loop exactly when every point in it has degree 2, anything
  else (an open end, a branch) is simply excluded rather than erroring the
  whole sketch; `NO_LOOP`/`BRANCH` now only fire when zero usable loops
  exist anywhere (`BRANCH` still takes detail-message priority in that
  fully-unusable case, matching the old behaviour's own precedent). New
  `profile_refs: list[SketchEntityRef]` on both `ExtrudeFeature` and
  `RevolveFeature` - empty means every outer profile currently detected
  (the old default, unchanged), non-empty names anchor Line/Circle entities
  identifying which outer profile(s) to use, resolved via a new
  `app.document.extrude.select_profiles` (shared by both Feature types) and
  a new `invalid_profile_ref` structured error. Client: `RevolvePanel`'s
  own decisions carried over (create-time-only picking, chosen over
  edit-time re-picking per explicit instruction); a new profile-picking
  mode entered automatically whenever the chosen Sketch has 2+ usable
  closed loops (skipped entirely for the common single-loop case) -
  designed via explicit user answers rather than assumed: cursor-based
  selection directly in the 3D viewport (not a list picker, not the 2D
  sketch canvas), hovering any Line highlights its whole containing loop
  (`PartViewport.sketchLineLoopGroup`, a new callback generalizing the
  existing single-entity hover highlight), click toggles a whole loop
  in/out of the pick set (mirrors Fillet's own "tap a face, select its
  whole edge loop" convenience), and a checkmark FAB confirms and opens the
  target panel. 7 new pure-Python `detect_profile` tests
  (`test_stage_g_profile.py`) genuinely executed (68/68 passing across
  every pure-Python graph/geometry/profile test file in this sandbox); the
  real-OCCT HTTP surface tests (`test_stage_g_profile_refs.py`)
  `ast.parse`/`pyflakes`-verified only, per the standing sandbox caveat.
  On-device testing surfaced three follow-up bugs, all fixed in the same
  round - see the entry directly below.
- **Bug fixes (on-device feedback, post-Prompt-G): viewport camera jump,
  profile picker not appearing, Sketch Circles not selectable.** Three
  issues reported from the same on-device test pass, all fixed:
  (1) *Viewport jumped when switching Orbit/Selection mode, and after
  selecting an entity.* Root cause: `PartScreen._visibleBodies` was a plain
  `_bodies.where(...).toList()` getter, allocating a brand-new `List`
  instance on every access - since `PartViewport.bodies`'s own contract
  requires a new instance only when the content actually changes (so
  `didUpdateWidget` can tell "unrelated rebuild" from "the mesh changed"),
  *every* unrelated `setState` in `PartScreen` (mode toggle, entity
  selection, anything) looked like a Body change to `PartViewport`, which
  re-ran `_syncMeshNode` and unconditionally snapped `OrbitCamera.target`
  back to the mesh bounds' centre, discarding any pan the user had done.
  Fixed by memoizing `_visibleBodies` against `_bodies`' own identity (only
  reassigned on a genuine mesh refetch), restoring the documented contract.
  (2) *Revolve's profile picker never appeared for a multi-closed-profile
  Sketch.* Traced to (3) below in the common case (a test sketch mixing a
  Line-chain profile with a Circle profile) - the picker itself entered
  correctly (`detect_profile`/`select_profiles` already handled this case
  server-side, confirmed via a synthetic pure-Python repro), but a
  Circle-only loop had nothing tappable to toggle it with, reading as "no
  option to pick" even though the banner/confirm-FAB were showing.
  (3) *Sketch Circles weren't a selectable/tappable entity in the 3D
  viewport*, despite being drawable there since C1 and just as valid a
  closed Profile as a Line-chain loop (`app.sketch.profile._circle_profile`).
  Fixed by adding a full `SelectionEntityKind.sketchCircle` kind end to end:
  `SketchGeometry3D` gained a `circleIds` array parallel to `circlePolygons`
  (previously absent - a deliberately deferred C1 gap); new
  `hitTestSketchCircles` (tests every segment of a Circle's tessellated
  outline, same convention as `hitTestSketchLines`) wired into
  `hitTestBodies`; new `SelectionFilterState.sketchCircle` field (mirrors
  `sketchLine`, on by default; explicitly off for Revolve's axis filter -
  a Circle is never a valid axis - and for the body-only/Fillet/Chamfer
  filters, on for the profile picker's own filter); `PartViewport`'s
  hover/selected-entity highlight rendering gained matching
  `sketchCircle` cases. This also surfaced (and fixed) a latent bug in
  `PartScreen._confirmProfilePicker`: it hardcoded `SketchEntityRefDto.
  entityType: 'line'` for every picked loop's anchor id, which would have
  422'd (`resolve_sketch_entity` validates the declared type against the
  real entity via `isinstance`) the first time a Circle-only loop's anchor
  was actually confirmed - now resolved per-anchor via a new
  `_isProfileCircleEntity` helper. No backend changes were needed for any
  of the three; `_toggleProfileLoop`/`_confirmProfilePicker` now build the
  correct `SelectionEntityKind`/`entityType` per member id instead of
  assuming every loop member is a Line. No Dart SDK available in this
  sandbox to compile/run - verified via brace-balance checks and manual
  review only, which missed one real build break a subsequent user build
  caught: `selection_list_drawer.dart`'s `_iconFor`/`_labelFor` switch
  statements weren't exhaustive over the new `sketchCircle` variant (fixed
  in a same-day follow-up commit). **Confirmed working on-device** by the
  user after that follow-up fix.
- **Sweep, the third of the Revolve → Sweep → Boolean sequence.** Scoped via
  an explicit back-and-forth (mirroring Prompt F/G's own scoping rounds)
  rather than assumed, since the project brief never detailed this module:
  the path is built from *explicit, ordered, individually-tapped* Sketch
  Line picks (not "the whole open chain of one Sketch," which was the
  simpler recommended default) - each pick may name a Line in a *different*
  Sketch, chained by 3D world-space endpoint position rather than a shared
  Point id (which cross-Sketch entries never have); a closed (looping) path
  is explicitly in scope alongside an open one, distinguished structurally
  (first/last picked points coincide) rather than by a separate flag.
  Boss/Cut parity with Extrude/Revolve throughout. Backend: new
  `SweepFeature`/`SweepMode` (`app/document/models.py`) with an ordered
  `path_refs: list[SketchEntityRef]`; new `app/document/sweep.py`
  (`BRepOffsetAPI_MakePipe` swept along the picked-path wire, built via the
  same `face_for_profile` Extrude/Revolve already share) - `_resolve_path_
  wire` traces `path_refs` into an ordered world-space point chain by
  resolving each entry's own Sketch/basis independently (mirrors
  `app.document.revolve._resolve_axis`) then chaining consecutive entries
  by coincident-endpoint-position (a `_PATH_POINT_TOLERANCE` world-space
  check, since cross-Sketch entries have no shared Point id to chain by
  instead) - `invalid_path_ref`/`disconnected_path`/`sweep_failed`
  structured errors mirror Revolve's own `invalid_axis_ref`/`revolve_failed`
  shape. `graph.py` gained `SweepFeature` dependency edges (the profile's
  own SketchFeature plus *every* distinct SketchFeature named across
  `path_refs`, deduplicated - generalizes Revolve's single axis-Sketch edge
  to N path Sketches). `schemas.py`/`router.py` gained `SweepFeatureCreate/
  Update/Response` and `POST/PATCH .../sweep-features[/{id}]`, eagerly
  validated via `resolve_sweep` before persisting; `_validate_target_body_
  ids` generalized once more to accept a Body from any of Extrude/Revolve/
  Sweep. `compute_part_bodies` gained a `SweepFeature` branch reusing
  `_apply_boss_or_cut`. 7 new pure-Python `test_stage_h_graph.py` tests
  genuinely executed (103/103 passing across every pure-Python graph/
  geometry/profile test file in this sandbox); `test_stage_h_sweep.py` (the
  real-OCCT HTTP surface) `ast.parse`/`pyflakes`-verified only, per the
  standing sandbox caveat - its own header note flags one real open
  question that couldn't be checked without a real OCCT build: whether
  `BRepOffsetAPI_MakePipe` auto-translates a profile positioned away from
  its spine's start point, or requires the caller to. Client: `FeatureDto`
  gained an ordered `pathRefs`; `createSweepFeature`/`updateSweepFeature`
  API client methods; new `SweepPanel` (Boss/Cut + target-body status +
  read-only path summary - no live path re-picking inside the panel, since
  the path is fixed before it ever opens, unlike Revolve's live axis pick).
  New path-picking mode in `part_screen.dart` (entered automatically right
  after the profile-picking step, since a Sweep's path is mandatory unlike
  Revolve's optional-until-panel-closes axis): tap a Line anywhere to
  extend the chain (client-side connectivity pre-check against the same
  world-space segment endpoints already used for rendering, mirroring the
  backend's own trace logic so the two never disagree), tap the most
  recently picked Line again to undo it, checkmark FAB confirms once 1+
  segments are picked and opens `SweepPanel`. Entry points: Feature-tree
  long-press context menu (`showFeatureContextMenu`'s new `showSweep`/
  `canSweep` params) and the "Add" FAB's Feature picker (previously a
  disabled placeholder, per the original Stage 19b brief). Explicitly
  deferred, none requested for this pass: twist/roll control along the
  path, multiple profiles swept along one path simultaneously, guide
  curves, re-picking the path/profile when editing an existing Sweep,
  non-Line path segments (only Lines exist as Sketch entities today). No
  Dart SDK available in this sandbox to compile/run - verified via
  brace-balance checks and manual review only.
- **Bug fix (on-device feedback, post-Sweep): couldn't extend a path pick
  past its first segment when the next tap connected to that segment's
  *other* end.** Root cause: both `_resolve_path_wire` (backend) and
  `_tracePathPoints`/`_togglePathPick` (client) tracked only a single
  running "chain end," seeded from the first segment's own arbitrary
  `(start, end)` order (whichever way its owning Line happened to store
  its two endpoints) - once one segment was picked, only a tap connecting
  to that one fixed endpoint could extend the path; a tap connecting to
  the *other* endpoint of that same first segment (nothing fixes which end
  is "the start" until a second segment actually commits to a direction -
  a perfectly ordinary way to build a path) was wrongly rejected as
  disconnected. Fixed in both places by tracking the chain's *two* open
  ends (front and back) and extending from whichever one a new pick
  actually touches (appending at the back, or inserting at the front) -
  confirmed via a pure-Python re-implementation of the trace algorithm and
  a new `test_stage_h_sweep.py` regression case (middle segment picked
  first, then one extending its front, then one extending its back) that
  would have failed `disconnected_path` under the old logic. Also caught,
  in hindsight, that an *existing* test in the same file
  (`test_path_segments_given_out_of_geometric_order_are_still_connected_
  correctly`) had actually been asserting success against geometry that
  the pre-fix algorithm would genuinely have rejected - never caught
  because this whole test file is `ast.parse`-verified only in this
  sandbox (no real OCCT to execute it against), a concrete reminder of
  that verification gap's real cost. **Confirmed working on-device** -
  user rebuilt and picked a multi-segment path successfully.
- **Bug fix (on-device feedback): Sweep's profile wasn't staying normal to
  the path.** Reported/screenshotted symptom: a non-circular (rectangular)
  profile swept along a bent path pinched to a wedge at the sharp corner
  instead of keeping its cross-section shape throughout; a circular
  profile looked fine (radially symmetric, so it visually hides the same
  underlying issue). Root cause: `resolve_sweep_from_bodies` used the
  simpler `BRepOffsetAPI_MakePipe(spine, profile)` - which does not
  reorient the profile's cross-section to stay normal to the spine's
  local tangent as its direction changes, and has no explicit handling for
  a polyline spine's sharp (non-tangent-continuous) corners - instead of
  `BRepOffsetAPI_MakePipeShell`, OCCT's more general "generalized sweep"
  API built specifically for both of those (its default trihedron mode
  already reorients the profile; `SetTransitionMode(BRepBuilderAPI_
  RightCorner)` now explicitly cuts each sharp corner with a flat planar
  face instead of leaving the transition undefined). `.Build()` +
  `.MakeSolid()` replace the old single-constructor-call shape. Design
  question this raised - resolved by asking directly rather than guessed:
  should Sweep expose a user-facing mitre-vs-round corner choice (OCCT
  supports both, `BRepBuilderAPI_RightCorner`/`RoundCorner`)? Answer: no -
  corner style should follow the path's own geometry (a sharp path vertex
  mitres, a rounded/curved path corner would produce a smooth elbow with
  no sharp transition at all, needing no special-casing), and since only
  straight Line path segments exist today (no Arc/curved Sketch entity to
  pick as a path segment yet), every path corner is necessarily sharp -
  `RightCorner` is the only correct choice given current scope, not a
  placeholder pending a toggle; a real "elbow" choice only becomes
  meaningful once a curved path-segment entity exists.
- **Bug fix (on-device feedback, second round on the fix directly above):
  the corner fix itself 500'd instead of sweeping.** Real traceback this
  time (`RuntimeError: OpenCASCADE Error [Standard_Failure]: BRepFill_
  Section: bad shape type of section (in BRepOffsetAPI_MakePipeShell::
  Add)`) - an uncaught crash, not a graceful `sweep_failed`, confirming a
  genuine API-usage mistake rather than a geometric failure. Root cause:
  `BRepOffsetAPI_MakePipeShell.Add` rejects a `TopoDS_Face` outright - it
  only accepts a Wire (or Edge/Vertex) as one swept "section"; the fix
  above was passing `face_for_profile`'s Face, not a bare Wire. Fixed by
  making `app.document.extrude._wire_for_profile` public
  (`wire_for_profile`, mirroring how `face_for_profile` was already made
  public for Revolve's own reuse) and passing its outer-wire-only result
  to `.Add()` instead. Not verifiable against real OCCT in this sandbox
  (same standing caveat, now hit twice in a row for this one feature) -
  implemented from OCCT API documentation/knowledge and the real traceback
  the user retrieved from the backend's own container logs.

  First-pass fix (above) also explicitly rejected a Profile with holes
  (`inner_loops`) rather than risk silently sweeping without one - flagged
  as a real, currently-known limitation. On follow-up, the user correctly
  pushed back: a hollow swept profile (a pipe's annular wall) is a
  completely ordinary, common Sweep use case, not an edge case worth
  punting on. Revisited rather than left as a rejection: `BRepOffsetAPI_
  MakePipeShell.Add` may well support a single compound outer+hole
  section directly (a real OCCT capability), but that specific call
  shape couldn't be verified without a real kernel, and guessing wrong a
  third time in a row wasn't worth the risk. Instead, `resolve_sweep_
  from_bodies` now sweeps the outer wire and each hole's own wire
  *independently* (`_sweep_wire`, both are plain single-wire sweeps - the
  exact case already proven working) and boolean-cuts the hole solid(s)
  out of the outer one (`BRepAlgoAPI_Cut`, the same operation `app.
  document.extrude._apply_boss_or_cut` already relies on for every
  Cut-mode Boss/Cut in this codebase) - a hollow pipe is exactly "outer
  tube minus inner tube," built from two already-independently-correct
  building blocks rather than one untested one. New
  `test_boss_sweep_of_an_annular_pipe_wall_profile_succeeds` (two
  concentric circles, the common pipe-wall case) added to
  `test_stage_h_sweep.py`. Same standing caveat - not verifiable against
  real OCCT in this sandbox.

  **CI actually runs these against real OCCT** (a Docker-based backend
  build+test workflow this whole Sweep implementation round didn't realize
  existed/was checking every push) - asked to check it directly, and every
  one of the 21 new Sweep tests genuinely passed against a real kernel,
  confirming the corner-orientation fix, the wire-not-face fix, and the
  annular-profile (pipe-wall) support all actually work, not just
  "implemented from documentation." One unrelated failure surfaced:
  `test_bugfix_hide_vs_rollback_exclusion.py::test_rollback_excluded_
  feature_ids_still_breaks_a_downstream_plane_as_intended` regressed
  (200 instead of the expected 422) - a real bug introduced back in the
  Prompt G round, not by Sweep. Root cause: Prompt G's own `compute_part_
  bodies` fix (wrapping `_solid_for_extrude_feature` in a blanket `except
  HTTPException` so a stale `invalid_profile_ref` pick doesn't take down
  the whole `/mesh` response) was too broad - it also swallowed a
  `missing_reference` raised by `resolve_sketch_basis` when B4's true
  rollback deliberately excludes an upstream Feature a Sketch's custom
  plane depends on, which must still propagate and fail the whole request
  (that is the entire point of true rollback, and was the pre-Prompt-G
  behavior this test guards). Fixed by narrowing the catch to only
  `invalid_profile_ref` specifically, re-raising anything else - applied
  to both the `ExtrudeFeature` branch (the one CI actually caught) and the
  brand-new `SweepFeature` branch (identical latent risk, caught
  proactively since it was written in this same session and not yet
  "shipped" anywhere). `RevolveFeature`'s own branch has the identical
  latent risk too (its blanket catch predates Prompt G, from Prompt F,
  and is by its own doc comment *deliberately* broad enough to tolerate
  an unresolvable axis or geometry failure) - left untouched since no
  test currently exercises it and it's an established, working, Prompt-F-
  era decision, not something this pass introduced or was asked to
  revisit; flagged here as a known parallel risk if it's ever picked up.
  CI green (526/526) after this fix, and **confirmed working on-device**
  by the user - closes out Sweep. Per the roadmap's own framing at the top
  of this entry, this completes Revolve → Sweep of the three-module
  sequence; Boolean operations (union/subtract/intersect) remain the one
  piece of that sequence not yet started.
- **No redo in the sketcher.** Undo (Stage 19b) is a command/inverse-action
  stack with an explicit `// TODO: redo` left in `sketch_controller.dart`.
- **Sketcher constraint options still unwired for creation beyond what
  exists today**: confirm there's no remaining gap — as of Stage 16,
  Coincident/Parallel/Perpendicular/EqualLength/Collinear are wired; check
  `sketch_controller.dart`'s `availableConstraintOptions` before assuming
  anything further is missing (this list has shrunk stage over stage; only
  verify if picking this up).
- **Kotlin Gradle Plugin / Java 8 deprecation warnings in the Android
  build.** Noted in passing during client bootstrap sessions as low-priority
  cleanup; not tracked with a specific fix plan. Worth a pass when next
  touching the Android build config, not urgent.
- **No Flutter CI job.** `.github/workflows/backend-verify.yml` only builds/
  tests the Python backend; there is still no automated `flutter analyze`/
  `flutter test` run in CI. Every client-side change in this project's
  history has been verified either manually, via a hand-bootstrapped SDK in
  a sandbox session, or by the user on a real device — never by an
  automated gate. Setting one up (pinned to a `flutter_scene`-compatible
  Flutter version) would have caught several of the regressions documented
  in `docs/status.md` earlier.
- **DAG refactor / multi-body phase (Prompts A1–A4, distinct from the
  older lettered "Prompts A–D" bullet above).** A1 (backend: Feature
  dependency graph + multi-body identity) landed and its stop condition is
  now fully satisfied — see `docs/status.md`'s 2026-07-03 entries. CI is
  green on both architectures (`278 passed`, verified from actual job
  logs) and a manual curl pass against a live server independently
  confirmed the same endpoints (placeholder/computed `/mesh` array shape,
  Boss/Cut `target_body_ids` 422/400 validation, body-id derivation and
  the earliest-target merge tie-break, hidden-body → empty array). Note:
  the curl pass used a minimal fake-OCCT shim since this sandbox has no
  path to real `pythonocc-core` (Docker Hub, `micro.mamba.pm`, and
  out-of-scope GitHub assets are all policy-blocked here) — it proves the
  API contract, not geometric correctness, which is what CI's real-OCCT
  run already covers. A2 (client selection filter framework + push/pop
  override mechanism) landed next — see `docs/status.md`'s 2026-07-03
  entry. Bootstrapped a real Flutter 3.44.4 stable SDK this session
  (`storage.googleapis.com` was reachable): `flutter analyze` is clean
  (zero new issues) and the framework's pure-Dart pieces
  (`OverrideStack<T>`, `SelectionFilterState`) have real passing tests
  (15/15). **The on-device check** — confirming the View submenu's four
  toggles actually appear and that hit-testing visibly respects them (this
  was originally the gate before A3 could start, but on-device testing
  surfaced a blocking bug that made A3 the more urgent next step - see
  below - so this check is now folded into A3's own still-outstanding
  on-device confirmation) — since `PartToolbar`/`PartScreen`
  transitively pull in `flutter_scene` (via `orbit_camera.dart`), which
  can't even load under this stable SDK due to the pre-existing
  `flutter_gpu` mismatch tracked above ("No Flutter CI job"/the C3 bug) —
  the same constraint that blocked 17 test files pre-A2 blocks widget-level
  verification of A2's own UI wiring too, not something A2 introduced.
  **A3 (client body-as-selectable-entity) landed next**, started early
  (before A2's on-device check came back) because on-device testing
  surfaced a real bug — "can't create a body, Extrude Confirm does
  nothing" — that turned out to be exactly A1's deferred `/mesh`
  array-parsing gap; A3 was the actual fix, not a patch on the side. See
  `docs/status.md`'s 2026-07-03 A3 entry for the root-cause trace. `flutter
  analyze` is clean (zero new issues); a new `document_api_client_test.dart`
  (7 tests, no `flutter_scene` dependency) exercises the actual array
  parsing for real. **Still outstanding before A4 begins: on-device
  confirmation that the original bug is fixed** (Extrude Confirm works
  again), that multi-body rendering looks correct, and that tapping a face
  in body-filter mode selects/highlights the whole body — none of this is
  verifiable in this sandbox for the same pre-existing `flutter_scene`
  reason as A2's toggle check above. **A backend amendment landed next**
  (still 2026-07-03): on-device A3 testing showed two disjoint solids from
  one multi-profile Boss rendering/selecting as a single Body, which
  turned out to be exactly what A1 shipped and tested — asked the user
  directly, who chose to match mainstream CAD tools instead (each
  disjoint solid is its own Body, even from one Extrude operation). See
  `docs/status.md`'s second 2026-07-03 entry. Also caught and fixed, by
  design review rather than a bug report, a real validation bug this
  change would otherwise have introduced: a composite split-body id
  (`"featid#0"`) round-tripped from `/mesh` would have 400'd against
  `_validate_target_body_ids`'s plain `part.get_feature(target_id)`
  lookup — fixed via `base_feature_id()`, confirmed over live HTTP with
  the same fake-OCCT-shim technique as A1 (extended this round so
  `TopExp_Explorer(..., TopAbs_SOLID)` doesn't crash, since every
  Boss/Cut result is now exploded through it). The client (A3) needed
  zero changes — body ids were already treated as fully opaque strings.
  **CI (real OCCT, both architectures) has since confirmed a disjoint
  Cut/Boss actually produces N separate solids** — verified from actual
  job logs (not just the `conclusion` field): amd64 `281 passed in 4.41s`,
  arm64 `281 passed in 66.66s`, all 6 new/renamed Body-splitting tests
  individually `PASSED` on both. See `docs/status.md`'s second 2026-07-03
  entry for the full list. **On-device confirmation has since landed**:
  the user confirmed the Body-exclusivity behaviour works — which led to
  two more small client changes, both `docs/status.md`-documented: the
  four selection-filter toggles were split out of the View sub-menu into
  their own "Selection Filters" top-level menu, and then **Prompt A4
  (client Boss/Cut target-body picking) itself landed**, wiring A2's
  filter override and A3's body selection into actually populating
  `target_body_ids` on Boss/Cut create/PATCH calls — until this, the
  client never sent that field at all, so every Boss silently started a
  brand-new Body and every Cut unconditionally 400'd. See
  `docs/status.md`'s A4 entry for the full design (`_selectedEntities` is
  reused directly as the picker's own selection while the Extrude panel
  is open, rather than a parallel field) and for two genuinely real
  (non-`flutter_scene`) test suites: `extrude_panel_test.dart` (6/6,
  Confirm-enablement) and new `document_api_client_test.dart` cases (4/4,
  `target_body_ids` wire format including the None-vs-`[]` distinction).
  **This closes out the DAG/multi-body phase (A1–A4)** - on-device
  confirmation of the full picking flow (enter picking mode, multi-select
  accumulate, Cancel mid-pick, a zero-pick Boss, a real multi-body Cut) came
  back positive, which is what let Prompt B begin.
- **Prompt B (sub-shape refs, tree categories, cascade delete,
  earlier-feature editing) — B1–B4 all landed, in order.** See
  `docs/status.md`'s dated 2026-07-03 entries for full detail; summary here:
  - **B1** (backend `SubShapeRef`/`resolve_subshape` + the `produces` tag):
    landed, CI-confirmed green on both architectures after one fix-up round
    (a wrong OCCT import in the test file itself, not production code).
  - **B2** (backend graph-aware cascade delete): landed, replacing a real
    bug — cascade delete was still walking list position rather than the
    actual dependency graph, so an unrelated sibling Feature could get
    deleted alongside a targeted one. CI-confirmed green on both
    architectures after one fix-up round (a wrong test assertion, not a
    cascade-delete defect).
  - **B3** (client feature-tree categorization) **shipped, then revised
    off real on-device feedback** (two screenshots): the original "group
    Feature rows by `produces`" design was replaced with a "Build Tree"
    panel — a top-level **Bodies** section listing real produced Body
    objects (one row per Body, not per Feature — a split Extrude now shows
    multiple Body rows) plus a **Features** section (the full, unfiltered
    Sketch/Extrude history). Also fixed a genuine duplicate-naming bug in
    `SelectionListDrawer` (two split Bodies both read "Body 8adb4187") by
    sharing one naming scheme (`bodyDisplayNames`) everywhere. User
    confirmed this revision on-device ("ok, looking good").
  - **B4** (earlier-feature editing) **implemented as true SolidWorks-style
    rollback**, not the original prompt text's "in-place edit, no
    rollback" — an explicit reversal, confirmed directly with the user
    rather than assumed. Tapping any Feature (locked or not) now opens it
    for editing, suppressing everything after it in the viewport for the
    edit's duration (reusing the existing `hidden_feature_ids` mechanism)
    and rolling forward on Confirm/Cancel. **Required a real backend
    change B4's own "Client" framing didn't anticipate**: the "only the
    last Feature is editable" lock was actively enforced server-side
    (`PATCH .../extrude-features`, every Sketch-mutation endpoint) and had
    to be removed for tapping an earlier Feature to do anything but 400 —
    deletion-gating (`locked` field, single-`DELETE` vs. cascade-delete)
    is untouched. CI-confirmed green on both architectures on the first
    push (no fix-up round needed, unlike B1/B2).
  - **Superseded gate**: this bullet's own on-device confirmation of B1–B4
    was still pending when Prompt C1 (below) started, on the user's
    explicit instruction to proceed - if that confirmation is still
    outstanding, fold it into C1's own on-device pass rather than treating
    it as a separate blocking step.
- **Prompt C1 (sketch Point/Line selection in the 3D viewport) — built,
  pending on-device confirmation.** Inserted ahead of the original Prompt C
  (renamed C2, content unaffected) since Create Plane's "Normal to Line at
  Point" reference type needs the user to pick a Sketch's Line/Point
  directly in the 3D viewport. See `docs/status.md`'s 2026-07-04 entry for
  full detail. Backend: `SketchEntityRef`/`SketchEntityType` (Point/Line/
  Circle) + `resolve_sketch_entity`, mirroring B1's `SubShapeRef` pattern -
  6/6 new pure-Python tests genuinely passed (no OCCT needed at all, a
  first for this project's backend prompts). Client: Sketch Lines/Circles
  turned out to already render in the 3D viewport pre-this-prompt (a stale
  assumption in the prompt's own scope doc) - the real gaps closed were
  Point rendering (new marker primitives), keeping a just-consumed Sketch
  visible-but-dimmed rather than fully hidden (`_autoHiddenSketchFeatureIds`,
  correctly suspended during an active B4 rollback), hit-testing (Sketch
  Point ties with Body Vertex, Sketch Line ties with Body Edge, both new
  `SelectionFilterState`/`SelectionEntityKind` values), and the Selection
  Filters menu/drawer/context-actions wiring. `flutter analyze` clean;
  207/224 client tests passed for real (the 17 loading-failures are the
  same pre-existing `flutter_scene`/`flutter_gpu` mismatch set as every
  prior client prompt, confirmed unchanged via `git stash` against the
  pre-C1 tree). Left out of scope, per the prompt's own boundary: Circle
  picking (backend ref type supports it, no client wiring), any specific
  Point+Line picking-mode combination (C2's job), custom/arbitrary sketch
  planes. **C1's on-device confirmation came back positive** (user-confirmed
  directly) - this closed C1 out and let Prompt C2 begin next.
- **Prompt C2 (Create Plane) — built, pending on-device confirmation.** See
  `docs/status.md`'s second 2026-07-04 entry for full detail. Two v1 plane
  types: OFFSET_FACE (one planar Body face + a signed offset) and
  NORMAL_TO_LINE_AT_POINT (a Sketch Line + the Point that's its own
  endpoint) - both reference-only, matching the brief's custom-plane
  deferral. Backend split by OCCT dependency same as B1/C1:
  `app/document/plane_geometry.py` (new, OCCT-free) resolves the line/point
  case via pure 2D vector math; `app/document/create_plane.py` (new, real
  OCCT) resolves the offset-face case via a `BRepAdaptor_Surface` planarity
  check. **Caught and closed a real gap before it could bite**:
  `build_feature_graph` only built dependency edges for `ExtrudeFeature` -
  extended it for `CreatePlaneFeature` too (a new
  `_sketch_feature_id_for_sketch` helper resolves a Sketch id back to its
  wrapping SketchFeature id), otherwise cascade-deleting a Plane's
  referenced Body/Sketch would have silently left it dangling, the exact
  bug class B2 fixed for `target_body_ids` - verified directly with a real
  `transitive_dependents` test, not just by inspection. 11/11 new
  pure-Python tests (`test_stage_c2_plane_geometry.py`) genuinely passed, no
  OCCT needed; 14 new real-OCCT tests (`test_stage_c2_create_plane.py`,
  full HTTP surface) need real CI to confirm, same constraint every
  OCCT-touching backend prompt hits in this sandbox. Client: new
  `create_plane_geometry_3d.dart` (arbitrary-orientation quad rendering,
  reusing `reference_planes.dart`'s existing local geometry with a
  `Quaternion.fromTwoVectors`-based transform) and `create_plane_panel.dart`
  (`CreatePlanePanel`, mirrors `ExtrudePanel`'s session shape);
  `selection_actions.dart`'s `contextActionsFor` gained its two real
  enabling rules (a lone Body Face; a Sketch Line + its own endpoint Point,
  via a new `PointOnLineChecker` callback `part_screen.dart` backs with a
  new `_linesByFeatureId` map) alongside its still-scaffolded Chamfer/Fillet
  ones. `part_screen.dart`'s flow mirrors Extrude's "create eagerly, PATCH
  live, Confirm closes, Cancel deletes-or-reverts" pattern, including B4
  rollback wiring, and closes the panel back out automatically if creation
  fails (the one thing client-side selection-shape validation can't catch
  ahead of time - a lone face turning out to be curved). `feature_tree_panel.dart`
  gained a **Planes** section, shown only when non-empty. `flutter analyze`
  clean; new pure-Dart/widget test files pass 100% standalone
  (`create_plane_panel_test.dart` 8/8, `document_api_client_test.dart`'s new
  cases 8/8, `selection_actions_test.dart`'s new cases) - flagged honestly
  that a full-suite batch run intermittently (twice, reproducibly) reports
  `create_plane_panel_test.dart` as failing to load with a generic "Dart
  compiler exited unexpectedly" error while the same file passes cleanly
  every time it's run in isolation, read as this sandbox's compiler
  struggling under the full ~30-file batch's resource pressure rather than
  a real defect - confirmed via a fresh `git worktree` diff against the
  pre-C2 tree that no previously-passing file was newly broken. **This gate
  has since passed**: Prompt D (Fillet) and Prompt E (Chamfer) have both
  since been built and confirmed working on-device (see the Chamfer entry
  below), which presupposes this stage's own on-device gate (both plane
  types create/render correctly including offset direction, a curved-face
  attempt is cleanly rejected not a crash, the Planes tree section works,
  edit-via-rollback and Cancel both behave correctly) was satisfied too.
- **Prompt C3 (informal, user feedback expanding C2's scope before its own
  on-device confirmation came back)**: "Plane" added as a Feature-picker
  entry; a third plane type, `PlaneType.MIDPLANE` (equidistant between two
  parallel Body faces); created Planes made tappable/selectable with a
  context menu ("Create Sketch on Plane"/"Delete Plane"); and, per the
  user's explicit "Full support now" answer to how far to take the last
  item, **full generalized Sketch-on-custom-plane support** - a
  `CreatePlaneFeature` is now a real anchor a Sketch can embed onto and an
  Extrude can build solid geometry on top of, not just a reference-only
  rendered object. Backend: `ResolvedPlane` gained a full orthonormal basis
  (`x_axis`/`y_axis`, hand-verified against - not formula-derived from - the
  three fixed planes' already-shipped conventions); `SketchFeature.
  plane_feature_id` anchors a Sketch to a custom Plane (mutually exclusive
  with a fixed `Plane`); `app.document.extrude`/`app.document.create_plane`
  generalized to build on any resolved basis via a `_from_bodies`-core/
  fresh-wrapper split (needed to avoid a circular-import/infinite-recursion
  trap resolving a custom plane's own basis from inside `compute_part_
  bodies`'s topological-order loop). Client: `sketchPointToWorld` generalized
  from a fixed `ReferencePlaneKind` to a new `SketchPlaneBasis` (closing a
  real gap - without it a custom-plane Sketch would render/pick as nothing);
  `createPlaneTransform` rebuilt on the backend's real basis instead of a
  `Quaternion.fromTwoVectors` guess; new `hitTestCreatePlanes`/
  `create_plane_context_sheet.dart` for the tap/context-menu flow. 80/80
  OCCT-free backend tests, 231 client tests passed, both confirmed
  regression-free via `git worktree` diff against the pre-C3 commit.
  **Superseded** - Prompt D (Fillet) and Prompt E (Chamfer) have both since
  been built and confirmed working on-device, presupposing this stage's own
  gate passed too.
- **Prompt C4 (user feedback: "wire up other common methods of creating
  planes", scoped via explicit choice to "the two scaffolded ones + 3-point
  plane")**: three more `PlaneType`s - `NORMAL_TO_EDGE_THROUGH_VERTEX` (a
  plane normal to a selected straight Body edge, through a selected Vertex),
  `PARALLEL_TO_FACE_THROUGH_VERTEX` (parallel to a selected planar Body face,
  through a selected Vertex), and `THREE_POINTS` (through three selected
  points, each independently a Body Vertex or a Sketch Point). Backend:
  `SubShapeType` gained `VERTEX` (resolved via the same 0-based
  `topexp.MapShapes` scheme the mesh's own `topology_vertex_ids` already
  uses); new `PointRef` value type holds *either* a `vertex_ref` or a
  `sketch_point_ref` (never both), letting a single `THREE_POINTS` Feature
  mix Body vertices and Sketch points freely; `plane_geometry.
  resolve_three_points` is pure-Python (origin = first point, `x_axis` =
  first-to-second direction, normal = cross product, rejecting collinear/
  coincident points with a new `collinear_points` 422) while the edge/face+
  vertex resolvers live in `create_plane.py` (need OCCT for the linearity/
  planarity checks); `_validate_create_plane_payload`'s per-type "every
  other field must be empty" check factored into one shared
  `_all_other_create_plane_fields_empty` helper as the field count grew from
  four to seven. Client: `CreatePlaneMode` gained the three new cases (no
  numeric field, same as `normalToLineAtPoint`); `contextActionsFor` gained
  real enabled rules for exactly-1-edge+1-vertex, exactly-1-face+1-vertex,
  and exactly-3-points (mixed vertex/sketch-point pool), each checked before
  their own pre-existing disabled-placeholder buckets; `part_screen.dart`
  wired end-to-end (create/edit/cancel-restore) for all three. 86/86 OCCT-
  free backend tests (new `test_stage_c4_plane_basis.py`/
  `test_stage_c4_create_plane.py`, the latter `ast.parse`-only per the usual
  OCCT-in-sandbox caveat), 242 client tests passed, both confirmed
  regression-free via `git worktree` diff against the pre-C4 commit (same
  18/13-file OCCT/GPU-blocked sets, respectively, as before). **Superseded**
  - Prompt D (Fillet) and Prompt E (Chamfer) have both since been built and
  confirmed working on-device, presupposing this stage's own gate passed
  too.
- **Bug fix (on-device report, post-C4)**: hiding a Body via plain Hide/Show
  and B4 true-rollback's own "pretend this Feature doesn't exist yet"
  exclusion were the same underlying mechanism (`hidden_feature_ids`) -
  correct for rollback, but it meant hiding a Body that a still-visible
  Plane depended on (and anything built on that Plane) broke the *entire*
  `/mesh` response with `missing_reference`, including unrelated Bodies.
  Split into two separate concepts end to end: `rollback_excluded_feature_ids`
  (still genuinely excludes a Feature from recompute, B4-only) and
  `hidden_feature_ids` (now purely cosmetic - every Body is always fully
  computed, then filtered out of the response only). Accepted trade-off:
  hiding a Cut (which owns no standalone Body) no longer "un-subtracts" it.
  New end-to-end regression test reproduces the exact reported scenario.
  Also: Build Tree text no longer wraps (smaller, single-line, ellipsized),
  gained a drag handle to resize the panel, and Bodies/Planes now start
  collapsed while Features stays expanded.
- **On-device follow-ups (same report thread)**: the Orbit/Selection
  mode-toggle FAB is now reachable while the Extrude/Create Plane panel is
  open (it used to hide for the panel's whole lifetime, purely to dodge a
  layout collision - now only the toolbar-open case hides it, and a bottom
  padding clears the panel instead); Extrude's forced-Selection-mode
  override is gone too, replaced by a one-time default the FAB can still
  toggle away from. Hidden Bodies now keep their row in the Build Tree
  (`BodyMeshResponse.hidden` replaces the old drop-the-entry behavior -
  free, since tessellation already happened before that filter ever ran),
  dimmed with an eye-slash icon, long-press-toggleable directly from the
  tree instead of only from the Feature that produced it.
- **Prompt C5 (previously "deferred pending scoping", now built)**: Create
  Plane's OFFSET_FACE/MIDPLANE/PARALLEL_TO_FACE_THROUGH_VERTEX now accept a
  Plane (a fixed reference plane, or an existing custom Plane) as a valid
  reference alongside a Body face - "offset from XY plane", "midplane
  between a Plane and a Face". New `PlaneRef` union type (backend
  `app.document.models`, mirroring C4's `PointRef`) and a `_resolve_plane_ref`
  dispatcher in `create_plane.py`; `graph.py`'s dependency edges and the
  router's validation generalized to match. Client: reference-plane/created-
  Plane taps now toggle into the same selection set every other entity kind
  uses while in Selection mode (new `SelectionEntityKind.referencePlane`/
  `.createPlane`), instead of always opening their own single-plane context
  sheet; `contextActionsFor`'s single/two/plus-vertex Create Plane combos
  generalized from "Body face" to "plane-like" (face, fixed plane, or
  existing Plane) accordingly. 90 OCCT-free backend tests passed (new
  `test_stage_c5_graph.py`, `test_stage_c5_create_plane.py` the latter
  `ast.parse`-only per the usual OCCT-in-sandbox caveat), `flutter analyze`
  clean, 39/39 `document_api_client_test.dart` cases genuinely executed
  (DTO round-trips + wire format).
- **Bug fix (same-day follow-up)**: a user question caught that C5's own
  Selection-mode plane-picking was dead code - `PartViewport`'s pointer
  dispatch routes every tap in Selection mode to `_commitSelection()`, never
  to `_handleTap` (the only place `onPlaneTap`/`onCreatePlaneTap` fire), so
  the `if (_selectionMode)` branches added above could never run; planes had
  no dynamic hover highlight either. Fixed by routing planes through the
  same cursor/hover/commit pipeline every mesh entity already uses -
  `ReferencePlaneHit`/`CreatePlaneHit` gained a `rayT` for depth-comparison,
  `_recomputeHover` now competes a plane hit against the mesh hit by `rayT`,
  and `_buildEntityHighlightNode` builds a real amber hover quad for a
  plane instead of returning null. Also fixed: the "Add > Plane" guided
  picker never switched to Selection mode, and its hint text predated both
  C4's and C5's new combos. Confirmed working on-device.
- **Prompt D: Fillet**. Multi-edge Fillet, one shared radius across all
  selected edges (v1 scope, no per-edge radii/variable fillets, matching
  the project's established conservative-scoping convention). Keeps the
  target Body's existing `body_id` (an in-place shape replacement in
  `compute_part_bodies`) rather than minting a new one, per the brief's own
  body-identity decision - preserves A1's guarantee that a later
  `target_body_ids`/`edge_refs` entry naming this Body keeps resolving to
  it. New `FilletFeature` model + `app/document/fillet.py` (OCCT
  `BRepFilletAPI_MakeFillet`, `mixed_body_selection`/`fillet_failed`
  structured errors), `graph.py` dependency edges, `POST/PATCH /parts/{id}/
  fillet-features[/{id}]`. Client: `contextActionsFor` enables Fillet (and,
  per Prompt E's own shared-condition instruction, Chamfer) for a 1+-edges-
  same-Body selection, disabled with a new `SelectionContextAction.
  disabledReason` tooltip otherwise; new `FilletPanel` (mirrors
  `CreatePlanePanel`'s Confirm/Cancel/live-preview shape); full part_screen
  create/edit/confirm/cancel wiring. 95 OCCT-free backend tests passed (new
  `test_stage_d_graph.py`, `test_stage_d_fillet.py` the latter `ast.parse`-
  only per the usual OCCT-in-sandbox caveat), `flutter analyze` clean, 44/44
  `document_api_client_test.dart` + 9/9 new `fillet_panel_test.dart` cases
  genuinely executed. **Confirmed working on-device** (see the Chamfer
  entry below for the final consolidated confirmation) - this Feature went
  through several more rounds of on-device bug fixes before that
  confirmation, all captured in the entries immediately below.
- **Bug fixes from on-device feedback on the above**: live preview/post-
  confirm mesh never appeared (Fillet's create/edit/cancel flow only
  refetched Features, never the mesh - `_ensureExtrudeFeatureExists`'s
  `_refreshMesh()` call was missing from all four Fillet call sites, now
  added); editing an existing Fillet showed the already-filleted body
  instead of the rolled-back one (`_openFilletPanelForEdit` now also
  excludes its own Feature id via `_beginRollback`, same mechanism B4
  already uses for downstream Features); Body row long-press now opens a
  context menu (new `showBodyContextMenu`) instead of directly toggling
  Hide/Show, matching the Feature long-press pattern. **Flagged back as a
  v2-scope design question rather than guessed at**: corner treatment when
  2+ selected edges share a vertex - OCCT blends a shared vertex smooth
  when all edges go through one builder call (today's behavior); user
  wanted this exposed as a selectable option in the FilletPanel, which the
  original brief didn't specify. **Resolved, not as a UI toggle**: a later
  investigation (see the "Follow-up" entry two below) found no kernel-level
  "corner type" switch exists that could do this - `ChFi3d_FilletShape`
  only affects cross-section profile, not vertex blending. The practical
  answer shipped instead is reliable full-loop *selection* (tap a face to
  select its whole boundary loop), not a corner-treatment option. **Confirmed
  working on-device** (see the Chamfer entry below).
- **Follow-up: Fillet selection filter, "Add" FAB entry, live edge editing,
  corner-treatment investigation**. Asked (per explicit permission) before
  guessing at two genuinely open questions: whether a Face-tap should select
  its edge loop (yes, confirmed - needed new backend face→edge adjacency
  data, `MeshData.face_edge_ids`) and whether the corner-rounding difference
  needs an auto-expansion fix or is correct kernel behavior (user chose
  "investigate first"). **Investigation conclusion**: the resolver already
  uses the correct one-builder/all-edges-together OCCT approach; there is no
  `BRepFilletAPI_MakeFillet` "corner type" switch that makes a 2-of-3-edges
  selection look like the 3-edge case - `ChFi3d_FilletShape` only controls
  cross-section profile, not vertex blending, and a still-sharp unfilleted
  edge unavoidably meets the fillet surfaces differently. Not a bug; not
  re-verified against real OCCT output (unavailable in this sandbox), a
  reasoned conclusion from the API's documented behavior instead. The
  practical fix is reliable full-loop *selection*, which the new Face-tap
  feature provides. Also: new `_filletSelectionFilter` (edge+face only)
  locked in for the whole Fillet flow via `_selectionFilterOverrides`; new
  `FeaturePickerAction.fillet` "Add" FAB entry (`_startFilletPicker`,
  mirrors `_startPlanePicker`'s guided-mode shape); Fillet's edge selection
  is now genuinely live for the panel's whole session (previously
  eager-create-once with no live-editing wiring at all, despite the prior
  round's rollback fix implying it) - mirrors Extrude's live target-body
  picking exactly, generalizing `_ensureFilletRadiusUpdated` into
  `_ensureFilletFeatureExists(radius, edgeRefs)`. 95 OCCT-free backend tests
  still passing (5 new `face_edge_ids` cases `ast.parse`-only per the usual
  caveat), `flutter analyze` clean, 46/46 `document_api_client_test.dart` +
  4/4 `feature_picker_sheet_test.dart` genuinely executed. **Confirmed
  working on-device** (see the Chamfer entry below).
- **Follow-up bug fixes on the above**: reference/created Planes stayed
  selectable while picking edges for Fillet, since `SelectionFilterState`
  had no `plane` field at all - `_hoverHitTestPlanes` (`part_viewport.dart`)
  had no filter check to gate on. New `SelectionFilterState.plane` (default
  `true`) fixes this; `_filletSelectionFilter` sets it `false`. Also: the
  "Add" FAB's Fillet entry only opened a picker banner, requiring an extra
  tap on the ambient Fillet button before `FilletPanel` itself appeared -
  unified both Fillet entry points into `_openFilletPanel`, which now opens
  the panel immediately either way (mirrors `_openExtrudePanel` showing
  `ExtrudePanel` immediately with no target Bodies picked yet), removing
  the separate `_filletPickerActive` picker-only phase entirely.
  `_ensureFilletFeatureExists` generalized to create-or-update (mirrors
  `_ensureExtrudeFeatureExists`) since a Feature can't exist with zero edges
  yet. `flutter analyze` clean, `selection_filter_test.dart` +4 (now
  10/10), same 46/46 + 9/9 + 4/4 + 12/12 other Dart suites still passing.
  **Confirmed working on-device** (see the Chamfer entry below).
- **Bug fix: live-editing a Fillet's edges after the first preview update
  crashed with `missing_reference`**. User's own diagnosis was correct: the
  create branch of `_ensureFilletFeatureExists` never excluded the newly-
  created Fillet's own effect from the shown mesh, so the very first
  successful create flipped the interactive body to the *post*-fillet
  topology - new edge ids replacing the pre-fillet ones the backend's own
  self-exclusion still validated `edge_refs` against. Fixed by adding the
  new Feature's id to `_rollbackExcludedFeatureIds` right after creating it
  (same mechanism `_openFilletPanelForEdit` already used for editing an
  *existing* Fillet), so the shown/interactive body stays the stable
  pre-fillet shape for the whole live-edit session, create or edit alike -
  at the cost of no longer showing a live rounded-corner visual while
  editing (the two asks were in direct tension; correctness of the edge
  selection won per the user's own explicit preference). **Confirmed
  working on-device** (see the Chamfer entry below).
- **Live rounded-corner visual preview, built generically for Chamfer reuse
  later**. Reinstates the visual the previous fix traded away, without
  reintroducing the `missing_reference` bug - two meshes now, fetched
  separately, never conflated: `_bodies` stays the stable pre-Fillet body
  driving all hit-testing/picking (unchanged from the previous fix); a new
  `_filletPreviewMesh`/`_filletPreviewBodyId` (fetched via
  `_refreshFilletPreviewMesh`, the same `/mesh` endpoint with this
  Feature's id *not* excluded) is purely visual. New `PartViewport.
  previewOverlayBodyId`/`previewOverlayMesh` - a per-Body alternative to
  the existing global-only `isPreviewMesh` flag - substitute the preview
  mesh (same translucent-orange tint) into `_syncMeshNode`/`_syncEdgesNode`'s
  rendering for just the one Body it targets; `bodies` itself, and every
  hit-test/selection path reading from it, is untouched. `_refreshMesh()`
  and `_refreshFilletPreviewMesh()` now run concurrently (`Future.wait`) so
  the extra backend recompute doesn't double the round-trip latency, only
  the backend's CPU cost per edit - flagged as a real trade-off, now
  actually in effect for both Fillet and Chamfer (each doubles its own
  backend recompute per edit) since Chamfer's own rollout reused this exact
  mechanism rather than inventing a second one; worth revisiting only if
  on-device performance actually suffers, not preemptively.
  Backend unchanged (reuses the existing `rollback_excluded_feature_ids`
  param with a different exclusion set). `flutter analyze` clean, same 81
  Dart tests passing (unaffected - this touches `PartViewport`'s rendering
  internals, which no test file in this sandbox can exercise regardless).
  **Confirmed working on-device** (see the Chamfer entry below).
- **Audit: brought every existing "preview" mechanism in line with the
  above, or documented why not**. Extrude (Boss/Cut) and Create Plane both
  audited and left unchanged - Extrude picks Body-level ids, which stay
  stable across its own re-solves (unlike Fillet's edge ids), so its
  existing single global `isPreviewMesh` tint is already correct; Create
  Plane never modifies Body geometry and doesn't even support re-picking
  its reference once its panel is open, so there's nothing to retrofit.
  New `docs/live-preview-pattern.md` - a decision tree + exact mirror-list
  for the next Feature type that needs a live mesh preview (Chamfer will) -
  cross-linked from `PartViewport.previewOverlayBodyId`,
  `PartScreen._ensureFilletFeatureExists`, and
  `app.document.fillet.resolve_fillet` so a future agent building the next
  one actually finds it while reading the reference implementation, not
  just the other way around.
- **Prompt E: Chamfer, rolled out as a full mirror of Fillet** (per explicit
  instruction: use Fillet as the template, including every on-device fix
  layered onto it since Prompt D, not just the original brief). Same design
  decisions as Fillet throughout (per Prompt E's own brief): `ChamferFeature`
  model + `app/document/chamfer.py` (`BRepFilletAPI_MakeChamfer`,
  `mixed_body_selection`/`chamfer_failed` structured errors, identical
  self-exclusion convention in `resolve_chamfer`), `graph.py` dependency
  edges, `POST/PATCH /parts/{id}/chamfer-features[/{id}]`. Client: new
  `ChamferPanel` (structurally identical to `FilletPanel`); `part_screen.dart`
  gained Chamfer's own complete, separate state/method set - a full
  method-for-method mirror of Fillet's, not a shared abstraction (matches
  this codebase's convention of separate-but-structurally-identical Feature
  flows) - including the self-exclusion-on-create fix and the dual-mesh
  preview overlay from day one, so Chamfer never has to earn these the hard
  way the way Fillet did. `contextActionsFor`'s same-body enabling rule
  already covered both buttons from Prompt D's own work (the one place the
  brief calls for sharing code) - only `onChamfer`'s actual callback needed
  wiring. 100 OCCT-free backend tests passed (new `test_stage_e_graph.py`
  genuinely executed, `test_stage_e_chamfer.py` `ast.parse`-only per the
  usual caveat, plus a new case for Prompt E's own on-device gate: a Body
  with both a Fillet and a Chamfer recomputes correctly), `flutter analyze`
  clean, 96 Dart tests genuinely executed across every touched/new
  no-`flutter_scene`-dependency file. **Confirmed working on-device
  (2026-07-06)** - user tested Chamfer directly and reported it "working
  well on device." Per Prompt E's own stop condition, this closes out the
  entire C/D/E sequence: Create Plane (C2-C5), Fillet (Prompt D, including
  every on-device bug-fix round layered onto it), and Chamfer (Prompt E).
  No CAD-feature work remains blocked on an on-device confirmation gate as
  of this entry - see `docs/status.md`'s matching 2026-07-06 entry for the
  consolidated closing note, and the "Other open items" section at the top
  of this file for what's still genuinely open (Revolve/Sweep, the C3
  rendering bug, etc.) now that this sequence is done.
- **Native Save/Load (first slice of the Save/Load/Import/Export phase,
  "native first" per explicit user instruction deferring STEP/STL/OBJ/glTF
  export to a later pass).** Scoped via 4 rounds of AskUserQuestion, all
  "Recommended" except STEP's own schema: client-owned files (backend has
  no project storage of its own - the client owns the actual file on disk);
  pure parametric tree (no cached mesh/geometry in the file - reopening
  recomputes Bodies via the existing `compute_part_bodies`, same as any
  other recompute); STEP deferred to AP242 later; mesh-export formats
  deferred to reusing existing `MeshData` later. Backend: new
  `app/document/native_format.py` - `export_native(document, sketches) ->
  dict`/`import_native(data) -> (Document, sketches)`, a standalone dict
  mapping (not a reuse of the HTTP API's own pydantic response schemas,
  which carry API-only fields like `locked`/`produces`/resolved plane
  geometry that have no place in a save file) covering every Feature type
  (Sketch/Extrude/CreatePlane/Fillet/Chamfer/Revolve/Sweep) and every
  Sketch entity/constraint kind, keyed by a `schema_version` that rejects
  anything unrecognized outright rather than guessing. New `GET
  /document/export/native`/`POST /document/import/native` endpoints; new
  `replace_document`/`all_sketches`/`replace_all_sketches` store functions
  for the "full replace, not merge" import semantics client-owned files
  calls for. 8 new genuinely-executable pure-Python round-trip tests (this
  is the first Feature-adjacent work this session where the serialization
  logic itself needs no OCCT at all, unlike almost everything else in this
  codebase) plus one CI-only HTTP smoke test that saves/restores the
  process-global Document/Sketch store around itself, since this test
  suite otherwise shares that global state across every test module in one
  pytest session and a native import is a deliberate full replace. Client:
  new `file_picker` dependency (the first file-system-access dependency
  this app has needed); `DocumentApiClient.exportNative`/`importNative`;
  wired into the File menu's pre-existing "Open…"/"Save" placeholder
  entries (left "Save As…"/"New"/"Import…"/"Export STEP"/"Export STL"
  disabled, matching what's still out of scope). `PartScreen` gained an
  `initialPartId` constructor param - Open pushes a brand-new `PartScreen`
  instance pointed at the imported Part rather than mutating the current
  screen's state in place, deliberately sidestepping the need to manually
  reset this screen's many transient fields (selection, hidden/rollback
  sets, in-progress picker/panel state) against Feature/Body ids that
  belong to a different Part after a full-document-replace import. Not yet
  confirmed on-device - the client changes (new dependency, file-picker
  wiring) could not be compiled/run in this sandbox (no Flutter SDK), only
  manually reviewed plus a brace-balance check against the pre-edit file.
  **On-device follow-up round (three fixes, all confirmed working except
  the last, still pending re-test):** (1) CI's real run caught the one new
  HTTP test asserting `part_ids == [part_id]` - too strict against the
  process-global Document this suite shares across every test module in
  one pytest session, which by that point legitimately held Parts from
  earlier-run files too; fixed to assert containment instead, verified via
  a second green CI run. (2) On-device: the in-app Open picker
  (`FilePicker.platform.pickFiles`) greyed out a just-saved file entirely -
  `FileType.custom` + `allowedExtensions` filters by OS-guessed MIME type,
  and Android has no MIME mapping for a made-up extension, so a save
  written under it couldn't be confirmed as a match; switched to
  `FileType.any`, since content is already validated right after (JSON
  decode, then the backend's own `schema_version` check) regardless. (3)
  On-device: Hide/Show state (`_hiddenFeatureIds`) is purely client-side
  and was never included in the exported file at all, so it was silently
  dropped by every Save/Load round-trip - fixed by having the client stash
  it directly into the same JSON object under a `hidden_feature_ids` key
  the backend's own `export_native`/`import_native` know nothing about and
  simply pass through unexamined, restored via a new `PartScreen.
  initialHiddenFeatureIds` constructor param on the fresh screen Open
  pushes. Also renamed the saved file's extension from `.didsacad` to
  `.DIDSAprt` per explicit user request. Fixes (1)/(2) confirmed working
  on-device; (3) and the extension rename not yet re-tested as of this
  entry.
- **Export: STEP/STL/OBJ/glTF (second slice of the Save/Load/Import/Export
  phase).** Per-Part `GET /document/parts/{id}/export/{step|stl|obj|glb}`.
  STL/OBJ/glb (locked-in scope: reuse existing `MeshData`, not OCCT's own
  writers) are hand-rolled in new `app/document/mesh_export.py`
  (`encode_stl`/`encode_obj`/`encode_glb`) - binary STL, ASCII OBJ, and a
  minimal valid glTF 2.0 `.glb` container (one mesh/primitive,
  POSITION+NORMAL only, no index buffer since `MeshData`'s flat triangle
  soup is already unindexed). `MeshQuality`/`Triangle`/`MeshData` themselves
  had zero OCCT dependency but lived in `app.document.mesh` alongside
  `tessellate_shape`, which does - split into a new OCCT-free
  `app/document/mesh_data.py` (re-exported unchanged from `mesh.py`) so
  `mesh_export.py`'s own encoders, and their tests, can import just the data
  shape without OCC.Core, which has no install in this sandbox. STEP export
  (new `app/document/step_export.py`) writes AP242 (locked-in scope, even
  with no PMI/MBD populated yet) via `STEPControl_Writer`, one `Transfer`
  per current Body so each stays its own distinct STEP product rather than
  one fused compound; round-trips through a temp file since pythonocc-core's
  writer only writes to a real path. All four formats combine every Body's
  tessellation into one merged mesh per Part (`_merged_body_mesh_data`,
  offsetting each Body's own triangle indices) - unlike `/mesh`, which keeps
  Bodies separate for the viewport's own per-Body hit-testing, export has no
  such need. A Part with no solid geometry yet 400s up front rather than
  emitting an empty/invalid file. 9 new genuinely-executable pure-Python
  encoder tests (synthetic `MeshData`, no OCCT at all) plus a new CI-only
  HTTP test file covering all four formats against a real extruded box and
  the no-solid-geometry 400 case. Client: `DocumentApiClient.exportPart`
  (a new `_sendBytes` helper, since raw STEP/STL/glb bytes aren't JSON the
  way every other endpoint's response is); File menu gained real "Export
  STEP"/"Export STL"/"Export OBJ"/"Export glTF" entries (previously two
  disabled placeholders, now four real ones) calling `PartScreen._exportPart`,
  which hands the bytes to the same `file_picker` save-file dialog Native
  Save already uses. **Confirmed green in CI** after one real bug fix
  (`Interface_Static.SetCVal("write.step.schema", ...)` was called before
  `STEPControl_Writer()` existed, so it was a silent no-op and the file was
  actually AP214, not the requested AP242 - CI's own STEP-export test caught
  this by asserting on the file's real `FILE_SCHEMA`, not just a 200 status;
  fixed by constructing the writer first).
- **Import: STEP/STL/OBJ/glTF as a fixed, non-parametric Body (third slice
  of the Save/Load/Import/Export phase).** Locked in via AskUserQuestion:
  STL/OBJ/glTF are export-only formats (no parametric history to
  reconstruct from a mesh), so import only ever means a file becoming a
  fixed reference Body - "import as a dumb body, future features will be
  able to edit existing bodies (scale, move face, delete face, move
  body)... also import mesh bodies (STL, obj, gltf) to view, measure,
  model around" (user's own answer). Backend: new `ImportFeature`/
  `ImportSourceFormat` (`app/document/models.py`) - no Boss/Cut `mode`, no
  `target_body_ids` of its own (importing always starts a brand-new Body,
  mirroring a fresh Boss with an empty target list), no dependency edges
  (`app/document/graph.py` needed no change at all - it already falls
  through to the default `depends_on = ()` for any unmatched Feature
  type) - but *is* now a valid `target_body_ids` entry for a later Extrude/
  Revolve/Sweep's own Boss/Cut (`_validate_target_body_ids` widened). New
  OCCT-free `app/document/mesh_import.py` (`decode_stl`/`decode_obj`/
  `decode_glb`, the inverse of `mesh_export`'s encoders - binary+ASCII STL,
  OBJ with fan-triangulation and optional normals, glTF with or without an
  index buffer) and OCCT-dependent `app/document/import_geometry.py`
  (`resolve_import`): STEP goes through `STEPControl_Reader` into a real
  B-rep solid, usable everywhere a Body already is; STL/OBJ/glTF get
  rebuilt into a single surface-less, triangulation-only `TopoDS_Face` (the
  same convention OCCT's own STL import uses - `tessellate_shape` already
  reads a face's triangulation directly when present, so this needs no
  separate meshing step) - sufficient for "view, measure, model around",
  explicitly *not* guaranteed to survive a Boolean operation the way a real
  solid does, flagged as a known limitation rather than silently assumed
  away. New `POST /document/parts/{id}/import-features` (base64-in-JSON,
  not multipart - no other endpoint here uses multipart and there's no
  `python-multipart` dependency, so this matches the native file format's
  own "binary data as a plain JSON string" convention instead of adding
  one). `native_format.py` gained ImportFeature (de)serialization the same
  way (`source_data` is the Feature's own true source of truth - re-parsed
  every recompute, "re-derive, don't cache" - persisted as base64). 25 new
  genuinely-executable pure-Python tests (12 mesh_import decoder round-
  trips against mesh_export's own encoders, needing zero OCCT; 4 graph
  dependency/cascade-delete cases; 1 native-format base64 round-trip - by
  far the best sandbox-test coverage any Feature type has had all session,
  since decode/encode and dependency-graph logic are both genuinely
  OCCT-free here) plus a new CI-only HTTP test file (STEP import round-
  tripped through the export endpoint just built; STL import via
  mesh_export's own `encode_stl`; malformed-file rejection; an Extrude Cut
  successfully targeting an imported Body). Client: `DocumentApiClient.
  createImportFeature`; File menu's "Import…" placeholder now real, wired
  to a new `PartScreen._importGeometry` (`FileType.any`, same Android MIME-
  filtering-bug workaround as native Open, mapping the picked file's own
  extension to a source_format); `feature_tree_panel.dart` gained an
  "Import" display name/icon. **CI caught a real bug on the first push, as
  predicted**: STEP import worked first try, but STL import's new Body
  vanished from `/mesh` entirely (`assert 0 == 1`) - `compute_part_bodies`
  had routed ImportFeature through `_apply_boss_or_cut`/`_register_solids`,
  which splits a Boss result by walking its `TopAbs_SOLID` count; a mesh
  import's own shape (a bare, surface-less face) has zero `TopoDS_Solid`s,
  so that path silently registered zero Bodies for it. Fixed by not routing
  ImportFeature through that path at all - it has no Boss/Cut merge concept
  of its own anyway, so it now always registers as exactly one Body keyed
  by its own Feature id directly, whatever `resolve_import` returned (real
  solid or bare face alike), never split even if a STEP import happens to
  contain multiple disjoint solids. Confirmed green in CI.
- **On-device feedback round: five fixes after real device testing of the
  whole Save/Load/Import/Export phase.**
  1. **"Editable" wrongly shown for `ImportFeature`.** The Build Tree's
     locked/unlocked subtitle was a blanket `feature.locked ? 'Locked' :
     'Editable'`, predating any Feature type without a real edit panel -
     `ImportFeature` has none (a fixed, non-parametric Body, see its own
     docstring), so tapping it while unlocked did nothing despite the row
     claiming otherwise. `feature_tree_panel.dart` gained a `_hasEditPanel`
     check (a negative check against `'import'`, not an allow-list, so it
     doesn't need updating for every future Feature type that keeps
     following the same "real edit panel" pattern) - shows "Imported"
     instead when there isn't one.
  2. **Cascade-delete confirmation named the wrong Features.** `_cascade
     DeleteFeature` assumed "every Feature at and after this index in the
     list" - true only in the pre-B2 world where list order and dependency
     order always coincided; a Sketch feeding two independent Extrudes (or
     any Feature with no real dependents) could already show the wrong
     warning. The backend's `CascadeDeleteResponse`'s own docstring carried
     the identical stale description. New read-only `GET .../cascade-
     preview` endpoint (`CascadeDeletePreviewResponse`) runs the exact same
     `transitive_dependents` computation the real delete does, mutating
     nothing; the client now calls it instead of assuming.
  3. **Mesh-imported Bodies had no visible wireframe in any render mode.**
     An `ImportFeature`'s own mesh-format shape (STL/OBJ/glTF) is a bare,
     surface-less triangulated face with zero real `TopoDS_Edge`s -
     `_extract_edges` (which only ever samples real OCCT curves) came back
     empty, so the existing edge-rendering pipeline had nothing to draw
     regardless of render mode. New `synthesize_wireframe_edges_from_
     triangles` (OCCT-free, in `mesh_data.py`) - each triangle's own 3
     sides become one segment apiece - `tessellate_shape` falls back to it
     whenever real-edge extraction comes back empty (only reachable for
     exactly this shape; every other Feature's own OCCT geometry always
     has real edges). No new client toggle needed - the existing render-
     mode picker (View menu) already provides "hide/show the mesh
     [wireframe]" once edges are populated.
  4. **glTF import didn't work for real-world `.gltf` files.** `decode_glb`
     only understood the binary `.glb` container; the far more common
     form most authoring tools default to is plain-JSON `.gltf` with
     buffers referenced by URI. Renamed to `decode_gltf` and widened to
     also accept the JSON form - buffers with an embedded `data:` URI (the
     "self-contained export" option most tools also offer) are decoded
     inline; a buffer referencing an external `.bin` file is rejected with
     a clear, actionable error rather than silently producing an
     incomplete mesh (a single picked file has no access to a sibling file
     on disk).
  5. **Save As/New wired up.** Both were disabled File-menu placeholders.
     `New` confirms, then pushes a fresh blank `PartScreen` (no
     `initialPartId`/`initialHiddenFeatureIds`/`initialFileName`) - the
     same "always start fresh" pattern this app already uses at first
     launch. `Save`/`Save As` share one `_exportAndSaveNativeFile` helper;
     Android's Storage Access Framework has no true silent-overwrite
     without deeper persisted-URI-permission integration (out of scope
     here, flagged rather than faked), so both still go through the same
     platform save dialog - the real, honest distinction is which filename
     each suggests: Save reuses `_lastSavedFileName` (whatever this session
     last Opened-from or Saved-to, threaded through a fresh screen via a
     new `PartScreen.initialFileName` the same way `initialPartId` already
     is), Save As always resets to a fresh generic name.

  17 new genuinely-executable pure-Python tests across items 2-4 (2
  cascade-preview HTTP tests, CI-only; 3 wireframe-synthesis tests, no
  OCCT; 2 new glTF-JSON tests, no OCCT) plus one existing CI-only import
  test extended to also assert the synthesized wireframe is present. Items
  1 and 5 are client-only Dart, unverifiable in this sandbox (no Flutter
  SDK) - manually reviewed plus brace-balance checks only.
- **Pre-existing, unrelated test failures flagged but not fixed** across
  several status entries (e.g. `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing the selection set in one specific test scenario, and
  `dragTargetPointIdAt` offering the origin as a drag target in
  `sketch_controller_test.dart`) — flagged in Prompt B's status doc as
  newly *visible* (not newly introduced) once a missing import let that
  test file load for the first time in a sandbox. Still open as of the
  last time it was checked.
- **"View Complex Mesh" - a fully on-device, backend-free viewer for
  photogrammetry-scale meshes.** Root cause of the trigger: real on-device
  testing hit a client-side `TimeoutException after 0:00:15` importing a
  large mesh through the normal `ImportFeature` pipeline. Rather than just
  raising the timeout, the actual fix is architectural: a mesh this large
  (millions of triangles, hundreds of MB) has no business surviving a
  base64-JSON HTTP round-trip or an OCCT `Poly_Triangulation` Python-loop
  construction at all when all the user wants is to *look* at it, not add
  it to the Feature/Body graph. `client/lib/mesh_viewer/` is a second,
  parallel path that never talks to the server:
  - `mesh_data.dart` (OCCT-free, GPU-free, pure Dart): `decodeStl`/
    `decodeObj`/`decodeGltf` re-implement the same STL/OBJ/glTF formats
    `backend/app/document/mesh_import.py` already decodes server-side, but
    entirely client-side, and `decimateToTriangleBudget` (stride/skip -
    drops whole triangles rather than clustering vertices, so it never
    merges vertices with different UVs and so never distorts/seams a
    texture) caps the viewed mesh at `kMaxViewerTriangles`. Every decoder
    de-indexes straight into a flat "triangle soup" - one convention
    shared with `backend/app/document/mesh.py`'s own `MeshDto` - which
    makes both decimation and GPU batching (below) trivial.
  - `mesh_viewer_render.dart` (GPU-touching): `flutter_scene` 0.18.1 only
    takes 16-bit vertex indices (see `mesh_geometry.dart`'s own
    `MeshBuffers` doc comment) - far below a photogrammetry mesh's vertex
    count - so `buildMeshViewerNodes` splits the decimated mesh into
    multiple `MeshPrimitive`s, each an independent ≤65535-vertex range
    (a few hundred draw calls is cheap on the Adreno-740-class hardware
    this was tuned for; vertex/fragment throughput, not draw-call count,
    is the real ceiling at this triangle scale). A base-color texture (if
    the file has one) is downsampled *during* decode via
    `ui.ImageDescriptor.instantiateCodec(targetWidth/targetHeight)` -
    never fully materializing a 4K-16K source atlas - then uploaded to a
    `flutter_gpu` `Texture` and bound to a shared `UnlitMaterial`.
  - `mesh_viewer_screen.dart`: a standalone screen with its own minimal
    `OrbitCamera` viewport (not `PartViewport` - that widget is built
    entirely around `MeshDto`/the Feature/Body selection model, neither of
    which apply here), reachable straight from `ConnectionScreen`'s cold-
    launch screen via a new "View a mesh file (no server needed)" button -
    deliberately *not* gated behind a successful Connect, since this path
    never needs one. Decode runs via `compute()` on a background isolate
    so a large file never blocks the UI thread; only the already-
    decimated (bounded-size) result crosses back over the isolate
    boundary, not the full raw mesh.

  Scope cuts, documented rather than silently assumed away: GLB was built
  and tested first (self-contained - geometry, UVs, and an embedded
  texture image can all live in one file), then binary/ASCII STL
  (geometry only - STL has no standard UV/texture concept); OBJ decodes
  geometry (+ UV passthrough) but does not yet resolve a `.mtl`'s
  `map_Kd` texture image, since that's normally a *separate* file next to
  the `.obj`, and a single file picked through a mobile SAF-style picker
  has no reliable path back to a sibling file - the same constraint
  `decode_gltf` already documents for a JSON `.gltf`'s external buffer
  references. A GLB/glTF's node transforms/scene graph are not walked -
  every mesh primitive is concatenated as if untransformed at the origin,
  true for the common single-mesh photogrammetry export this targets.
  Only the first material's texture is used, applied to the whole
  concatenated mesh. `kMaxViewerTriangles` (3,000,000) and
  `kMaxTextureDimension` (4096px) in `mesh_viewer_render.dart` are starting
  points tuned for the originally-specified target device (a Snapdragon 8
  Gen 2 / Adreno 740 flagship), not benchmarked results - this sandbox has
  no on-device Flutter test capability, so these need real-device tuning,
  not just a one-time guess.

  **Fixed after a real first on-device build** (this sandbox has no
  Flutter SDK, so this was always going to need a real compile to catch):
  `Texture.overwrite` takes the `ByteData` from `toByteData` directly, not
  a `Uint8List` view of it, and returns `void`, not a success flag; and
  `UnlitMaterial`'s real texture slot (confirmed against the actual
  installed `flutter_scene` 0.18.1 source) is `baseColorTexture`, not the
  originally-guessed `colorTexture`. A second real-device crash surfaced a
  genuine ordering bug, not a wrong-guess one: `UnlitMaterial`'s
  constructor touches the base shader library immediately, which throws
  until `Scene.initializeStaticResources()` has completed at least once -
  but `buildMeshViewerMaterial` ran from `MeshViewerScreen` as soon as a
  file was picked, before `_MeshViewerViewport` (whose `initState` is what
  actually calls `initializeStaticResources`) had ever been mounted. Fixed
  with `ensureSceneResourcesLoaded()` - a single memoized `Future` both
  `MeshViewerScreen` (before building the material) and
  `_MeshViewerViewport` (before building the Scene) now await, so the real
  call happens exactly once regardless of which one gets there first.

  New pure-Dart tests in `client/test/mesh_data_test.dart` (STL binary/
  ASCII, OBJ incl. quad fan-triangulation and unknown-vertex rejection,
  GLB binary container, JSON `.gltf` incl. external-buffer rejection,
  decimation) - all logic-only, no GPU/Flutter SDK needed to reason about
  correctness, but not actually run in this sandbox either (no Flutter
  SDK installed here at all - same caveat as every other Dart change this
  session).

## OPEN — Real lighting/shading across the whole app (next active work)

**Trigger**: user loaded a real STL in "View Complex Mesh" and reported it's
"impossible to make out features as it's single colour, no shading,
textures or lighting." Root cause: every rendered Body in this app
(`PartViewport` and the new mesh viewer alike) uses `flutter_scene`'s
`UnlitMaterial`, which - per its own doc comment - "draws geometry with a
flat color or texture, ignoring scene lighting" entirely. This isn't a bug
introduced by the mesh viewer; it's a standing limitation already flagged
in `mesh_geometry.dart`'s own `TODO` on `buildMeshEdgesNode`'s neighboring
code ("`UnlitMaterial` has no roughness/metallic... revisit if/when a PBR
material type ships"). Confirmed via a fresh web search that a PBR
material type has, in fact, already shipped in `flutter_scene`: the
installed 0.18.1 already includes `PhysicallyBasedMaterial` plus
environment-map/image-based-lighting support (referenced directly inside
the real `unlit_material.dart` source pulled from this project's own
`flutter_scene` install this session). This is being scoped as a
whole-app upgrade, not a mesh-viewer-only patch, since `PartViewport` has
the identical limitation and would benefit from the same fix.

**Important constraint surfaced by research, not yet reconciled with this
project's setup**: per `flutter_scene`'s own package description, its
newest features (current prefiltered-radiance IBL improvements, certain
web-backend fixes) require the Flutter **master** channel, not stable -
"Flutter Scene requires the Flutter master channel, rather than the
stable channel" for some recent capability. This project's current
Flutter channel/toolchain has not yet been checked against that
requirement - needs confirming before committing to "pull in the latest
flutter_scene build," since master-channel Flutter is a materially bigger
commitment (pre-release, less stable) than staying on 0.18.1/stable.

**Plan**: work happens on a new branch off `main` (`claude/lighting-shading-upgrade`,
branched after `claude/docs-folder-context-yzj5r7` merged via PR #93,
closing out the whole Save/Load/Export/Import + View Complex Mesh phase).
No `flutter_scene` version upgrade needed after all - 0.18.1 (already
pinned) is confirmed to be the current latest pub.dev release, and it
already includes everything this needed (`PhysicallyBasedMaterial`,
`Scene.directionalLight`, `EnvironmentMap.studio()`, SSAO). The "requires
Flutter master channel" line above turned out to be moot - the user's
`flutter pub get`/`flutter run` already succeeded against 0.18.1, so their
toolchain already satisfies whatever that constraint was about.

**Built so far** (not yet on-device confirmed):
- Both `PartViewport` (`part_viewport.dart`'s `_syncMeshNode`) and the
  mesh viewer (`mesh_viewer_render.dart`'s `buildMeshViewerMaterial`) now
  build a real `PhysicallyBasedMaterial` for a confirmed Body/mesh instead
  of `UnlitMaterial` - `alphaMode`/`baseColorFactor` carried over unchanged,
  plus new `roughnessFactor`/`emissiveFactor`; `metallicFactor` is fixed at
  `ScenePreferences.fixedMetallic` (non-metal/plastic), not user-adjustable.
  Live-operation preview overlays (Extrude/Fillet/Chamfer's translucent
  orange tint) deliberately stay on `UnlitMaterial` - they're meant to read
  as a flat "in-progress" indicator, not real lit geometry.
- Both viewports now set `Scene.environment = EnvironmentMap.studio()`
  (a procedural, no-asset-required ambient/IBL fill, always on,
  unconditional - not a user control) and `Scene.directionalLight` (a
  single fixed-direction "sun" light, intensity driven by the new "mid
  lighting" control) - see `PartViewport._applyLighting`/
  `mesh_viewer_render.dart`'s `applySceneLighting`.
- New `ScenePreferences` (`viewport3d/scene_preferences.dart`,
  `shared_preferences`-backed, mirrors `ViewPreferences`'s own pattern):
  `roughness` (default 0.35, "light roughness" per the user's requested
  default), `lightIntensity` (default 1.5 of a 0-3 range, "mid lighting"),
  `emissiveIntensity` (default 0, "luminescence" - named as an available
  control, not one of the three explicit defaults). Base colour
  deliberately isn't duplicated here - it reuses the pre-existing
  `ViewPreferences.bodyColourHex`/"Body Colour" picker, whose own default
  was changed from `#B0B8C1` ("Aluminium", kept as its own named swatch)
  to mid-grey `#808080` per the user's explicit requested default.
- New `SceneControlsPanel`/`showScenePrefsSheet`
  (`viewport3d/scene_controls_panel.dart`) - shared UI, embedded live
  (drag-and-see, no Apply step) two different ways: `PartToolbar` nests it
  as a new "Scene" `ExpansionTile` under the existing View menu (colour
  omitted there - "Body Colour" is already a separate entry right above
  it); `MeshViewerScreen` (which had no colour picker at all before this)
  wraps it in a modal sheet, reached via a brand-new File/View `AppBar`
  menu (`File > Open/Exit`, `View > Scene`) - the mesh viewer previously
  had no menu structure at all, just a single folder-open icon button.
- Fixed, unrelated to lighting: the mesh viewer's file picker was greying
  out every format but `.stl` on-device - Android's SAF filters by MIME
  type, and none of STL/OBJ/glTF/GLB map to a standard registered MIME
  type, so `file_picker`'s extension-to-MIME lookup only reliably enabled
  the first extension in the list. Switched from `FileType.custom` +
  `allowedExtensions` to `FileType.any` with the extension validated after
  picking instead (the decoder already rejected an unsupported one with a
  clear error).

**Deliberately not built this pass**: SSAO and the post-processing chain
(bloom/tone-mapping/color grading) - real shading/lighting first, polish
later, per the original scoping conversation.

**Flagged, not yet on-device-confirmed** (same "no Flutter SDK in this
sandbox" caveat as every Dart change all session): `PhysicallyBasedMaterial`/
`DirectionalLight`/`EnvironmentMap` are all genuinely new `flutter_scene`
API surface in this codebase (every prior use was `UnlitMaterial` only).
Their field/constructor shapes were confirmed against real `flutter_scene`
0.18.1 source, but whether they're all reachable through the
`package:flutter_scene/scene.dart` barrel import already used throughout
`part_viewport.dart`/`mesh_viewer_render.dart` (as opposed to needing a
more specific import path) was not directly confirmed - see
`part_viewport.dart`'s own doc comment on `_applyLighting` for the full
note. If either file fails to compile on the next on-device build, it's
very likely the same fix needed in both places.

## Bug fixes: real on-device feedback on the lighting/shading upgrade

Two issues reported after the first on-device build of the PBR/lighting
work above (both fixed, neither yet re-confirmed on-device):

- **Scene sheet's sliders/colour tick didn't visually move while
  dragging/tapping - only updated after closing and reopening the menu.**
  The mesh viewer's `showScenePrefsSheet` (`scene_controls_panel.dart`)
  used a `StatefulBuilder` with `var currentX = x;` declared *inside* the
  builder callback - which looked reasonable but silently resets every
  time `setSheetState` runs (the callback re-executes from scratch on each
  rebuild), snapping the displayed value straight back to the sheet's
  original opening value before the next frame painted the just-changed
  one. The underlying persisted state was actually updating correctly the
  whole time (via the `onXChanged` callbacks, called unconditionally
  either way) - only the sheet's own *visual* reflection of it was broken.
  Fixed by converting to a real `StatefulWidget`/`State` class
  (`_ScenePrefsSheet`/`_ScenePrefsSheetState`), whose fields persist across
  its own `setState` calls - the same shape `view_prefs_sheets.dart`'s
  pre-existing `_BodyOpacitySheet` already uses, for exactly this reason.
  `PartToolbar`'s own embedded Scene submenu (plain props from real
  `PartScreen` state, no `StatefulBuilder` involved) was never affected.
- **Some meshes rendered with one side opaque and the other see-through -
  internal faces visible, an external face missing, flipping depending on
  view angle.** The textbook symptom of backface culling combined with
  inconsistent triangle winding - `mesh_geometry.dart`'s own
  `triangleHighlightBuffers` doc comment already confirms `flutter_scene`/
  Impeller does cull backfaces, worked around there (for highlight
  overlays only) by emitting every triangle with both windings. A real
  OCCT-tessellated Body's winding is reliably consistent (`geometryFromMesh`
  has never needed that workaround), but an arbitrary external STL/OBJ/glTF
  file - especially photogrammetry output - has no such guarantee, and this
  viewer has no way to detect or repair bad winding in someone else's file.
  Fixed by setting `PhysicallyBasedMaterial.doubleSided = true` in
  `buildMeshViewerMaterial` - disables culling entirely for the mesh
  viewer specifically (not touched in `part_viewport.dart`/the main Part
  viewport, which has never shown this symptom), so every triangle renders
  from both sides regardless of the source file's own winding correctness.
  `doubleSided` itself is inferred from a real `flutter_scene` changelog
  line ("Fixed material.doubleSided being ignored by runtime importer")
  rather than confirmed directly against this project's installed source -
  flagged in `mesh_viewer_render.dart`'s own top-of-file doc comment.
