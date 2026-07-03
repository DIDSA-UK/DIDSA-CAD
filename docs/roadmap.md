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
  **This closes out the DAG/multi-body phase (A1–A4) pending on-device
  confirmation of the full picking flow** (enter picking mode, multi-select
  accumulate, Cancel mid-pick, a zero-pick Boss, a real multi-body Cut) —
  see `docs/status.md`'s A4 entry for the exact on-device checklist.
  Prompt B (sub-shape refs, tree categories, cascade delete, earlier-feature
  editing) waits on that.
- **Pre-existing, unrelated test failures flagged but not fixed** across
  several status entries (e.g. `addCollinearConstraint`/
  `addEqualLengthConstraint`/`applyConstraintOption(collinear)` not
  clearing the selection set in one specific test scenario, and
  `dragTargetPointIdAt` offering the origin as a drag target in
  `sketch_controller_test.dart`) — flagged in Prompt B's status doc as
  newly *visible* (not newly introduced) once a missing import let that
  test file load for the first time in a sandbox. Still open as of the
  last time it was checked.
