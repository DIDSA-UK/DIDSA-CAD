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
- **Chamfer, Fillet, Create Plane context actions.** Scaffolded end-to-end
  (selection composition rules, disabled buttons with per-action
  `// TODO: wire up <action>` comments) since the 3D-viewport
  selection-mode work, but never implemented. Needs actual OCCT operations
  behind each action.
- **Revolve, Sweep.** Disabled placeholders in the Feature picker sheet
  since Stage 19b. Not implemented.
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
  pre-C2 tree that no previously-passing file was newly broken. **Current
  gate**: on-device confirmation (both plane types create/render correctly,
  including offset direction; a curved-face attempt is cleanly rejected,
  not a crash; the Planes tree section works; edit-via-rollback and Cancel
  both behave correctly) is what Prompt D (Fillet) now waits on - same
  gating discipline as every prior prompt group.
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
  regression-free via `git worktree` diff against the pre-C3 commit. **Not
  yet on-device confirmed** - same gating discipline before Prompt D
  (Fillet) starts.
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
  18/13-file OCCT/GPU-blocked sets, respectively, as before). **Not yet
  on-device confirmed** - same gating discipline before Prompt D (Fillet)
  starts.
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
  genuinely executed. **Not yet on-device confirmed** - per the brief's own
  stop condition, do not start Prompt E (Chamfer) until this comes back
  positive.
- **Pre-existing, unrelated test failures flagged but not fixed** across
  several status entries (e.g. `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing the selection set in one specific test scenario, and
  `dragTargetPointIdAt` offering the origin as a drag target in
  `sketch_controller_test.dart`) — flagged in Prompt B's status doc as
  newly *visible* (not newly introduced) once a missing import let that
  test file load for the first time in a sandbox. Still open as of the
  last time it was checked.
