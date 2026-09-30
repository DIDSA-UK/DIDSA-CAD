# Constrained drag — implementation plan (multi-session)

Companion to [`constrained-drag-investigation.md`](constrained-drag-investigation.md) (evidence, prototypes,
rationale). **That report's §G.2 rollout matrix and its "schema / legacy-shape / 404 fallback" material are
superseded by this document**: the software is pre-release and the only consumers are the flat app and the VR
app (both owned by the same team), so there is no compatibility to preserve. Change contracts in place.

This file is the **tracker**: every session reads it first and updates its own row/checklist last.

**Baseline (verified):** the single-occurrence `mate-motion` endpoint and the VR smooth-drag round are **already merged** —
CAD `main` at `003254a` (PR #264), VR `main` at `8933f53` (PR #16). So "v0" is live on `main` and VR depends on its exact
shape (`transform`, `dof`, `free_twists`).

## 1. What pre-release changes (delta from the investigation)

| Investigation said | Now |
|---|---|
| Versioned `FreeMotion` (`schema: 2` opt-in, legacy v0/v1a shape, additive-only, echo `schema`) | **One contract, changed in place.** No `schema` field, no legacy request path, no dual meaning of `dof`. |
| Merge `mate-motion` (v0) to `main` first, then evolve | **Done already** (CAD #264, VR #16). S3 changes the endpoint's semantics *in place*. Because the repos merge separately, S3 keeps the v0 fields (`transform`, `free_twists`, computed the old single-occurrence way) as **temporary aliases** so VR on `main` keeps working until S5 merges; S9 deletes them. This is the only compatibility shim in the plan. |
| VR keeps a 404/405 fallback to PATCH+solve per round trip | **Delete it** (`_sync_with_solve`, `_motion_supported`). One code path to test. |
| Phase 1a "group `dof`/`mobility` only, additive, so nothing breaks" as a separate release | Fold 1a–1c into one backend sequence (sessions S1–S3); intermediate states are never released, so no need to make each one compatible. |
| Client capability discovery | Not needed. |
| Keep `System.Dof`-based `dof` for sketches, add a new field | Change `SolveResultDto.dof` semantics directly if/when the sketch work happens; the structural analysis stops being a drag gate. |
| Several separate endpoints (`PATCH` transform, `solve`, `mate-motion`, `preview-mate-solve`) | Collapse to **one motion endpoint family** (§3), keeping the raw `PATCH` for unconstrained/fixed edits only. |

Unchanged (not compatibility-driven): group-aware solving is the prerequisite; screw-integration projector; lever arm =
bounding radius; weighted retraction; one shared projector *spec* with golden vectors for GDScript + Dart; flat-app
live constrained drag and gizmo freedom cues; sketch work is a separate, optional consumer.

**New risk created by pre-release:** because nothing is versioned, the two apps and the backend must change *together*.
Mitigation: a single contract-of-record (§3), golden vectors shared by both clients (S4), and an e2e test in each client
repo that talks to the real backend (already the VR convention).

## 2. Defaults that unblock sessions — **confirmed by default, 2026-09-30** (S0)

1. **Followers follow.** Dragging `B` moves mated neighbours only as the mates *require* (measured: `D` follows, `C` stays). A user who wants a part
   to stay put marks it `fixed`.
2. **Ungrounded assembly.** If nothing in a mate-graph component is `fixed` and it has no mate to the focused part's own geometry, the component is a free rigid group
   (6 DOF): dragging moves it as a whole; the UI says "not grounded" instead of "0 DOF".
3. **Scope** = connected component of the mate graph within the focused part (nested sub-assemblies out of scope, as today).
4. **`ANGLE` mate from an aligned start** is fixed in-place in S2 by seeding (nudge off the singular orientation), not documented away.
5. **Sketch** work (Windows local solver vs drag-map, mobility oracle) is *not* on the critical path; decide in S0 whether to schedule S10+ at all.

## 3. Contract of record (implemented in S3; VR and Dart code to it) — **confirmed by default, 2026-09-30** (S0)

`POST /document/parts/{part_id}/occurrences/{occurrence_id}/mate-motion` — `occurrence_id` is the **grabbed** occurrence.

```jsonc
// request
{ "transform": { … RigidTransform … } | null,   // wanted pose of the grabbed occurrence (null = its stored pose)
  "lever_arm": 41.2,                            // optional, mm; default = grabbed occurrence's bounding radius
  "commit": false }                              // true = also persist the solved group atomically (one undo unit)

// response
{ "converged": true,
  "dof": 5,                                      // GROUP dof = 6k − rank(J); authoritative (rank-based, never System.Dof)
  "grounded": true,                              // false ⇒ component has no fixed occurrence / no link to the focused part's geometry
  "members": [ { "occurrence_id": "occ-B", "transform": { … },       // nearest satisfying configuration, weighted metric
                 "mobility": 3 },                                     // rank of this member's 6-row block of the basis
               … ],                                                   // order defines the basis column order
  "basis": [ [ /* 6·k floats, member order, [dx dy dz rx ry rz]×k, orthonormal in the weighted metric */ ], … ],
  "chart": { "kind": "se3_owner_frame", "lever_arm": 41.2 },
  "quality": { "residual_inf": 3e-10, "sigma_min": 0.31, "sigma_gap": 40.0, "max_step": 12.0, "jump": 0.7 },
  "diagnostics": { "solve_ms": 3.4 } }
```

Rules: nothing stored unless `commit`; a `fixed` grabbed occurrence → 422 (as today); non-convergence → `converged:false`, **no basis**
(clients must not read it as "all free"); `commit:true` with `converged:false` stores nothing. `solve_for_occurrence`,
`preview-mate-solve` and the post-`create_mate` snap are re-implemented on the group solver; the plain `PATCH …/occurrences/{id}` remains for raw edits
(hide/colour/name/fixed and unconstrained moves).

## 4. Session rules (keep every session small)

* **One repo per session, one branch, one PR** (≈ ≤ 1 500 changed lines including tests; if a session's task list overflows, stop at the last green checkpoint and
  split — record the split here).
* **Start:** read this file, the section of the investigation report named in the brief, and only the source files the brief lists. Don't re-derive findings.
* **Definition of done:** the brief's *Exit criteria* all pass, tests added/updated, `docs/status.md` gets a short dated entry, this file's tracker row is ticked with
  the branch/PR and any *handoff notes* the next session needs (decisions, gotchas, numbers).
* **Never** widen scope into the next session; leave a note instead.
* Backend sessions run the real solver (micromamba env, `backend/environment.yml`); client sessions run `flutter test`/`flutter analyze` or Godot tests as the repo already does.
  If the toolchain is missing (recorded in earlier sessions), say so and list what was verified only by reading.
* Prototypes to port from: `docs/constrained-drag-investigation/prototypes/` (`f_group_real.py` group model, `geo.py` projector, `e_weighted_retraction.py`, `a_screw.py`).

## 5. Dependency graph

```
S0 decisions ─► S1 group core ─► S2 group solve ─► S3 endpoint + commit ─┬─► S5 VR adopts
                     │                 │                                 ├─► S7 flat live drag ─► S8 flat cues ─► S9 cleanup
                     └────────► S4 projector spec + golden vectors ──────┴─► S6 Dart projector ─┘
Optional, independent:  S10 sketch measurements/decisions ─► S11 …
```

S5 and S6 can run in parallel once S3 and S4 are merged. S7 needs S3 and S6.

## 6. Sessions

Legend — **Repo**: CAD = `DIDSA-UK/DIDSA-CAD`, VR = `DIDSA-UK/DIDSA-VR`. Size: S ≈ half-day, M ≈ 1 day, L ≈ 2 days of agent work.

### S0 — Decisions + tracker (CAD, docs only, S)
* **Tasks:** owner confirms/overrides §2 defaults and the §3 contract (edit this file); decide whether S10+ is scheduled; create branch naming convention; move the
  two prototype-derived numbers we depend on (B/C/D scene, expected group DOF 5) into the S1 test spec below.
* **Exit:** §2 and §3 marked *confirmed* (date, initials).

### S1 — Group model core (CAD backend, M)
* **Read:** investigation §E.8; `prototypes/f_group_real.py`; `backend/app/document/assembly_solver.py` (`_free_motion`, `_applicable_mates`, `_mate_residual_vector`, `_resolve_local_geometry`, `_place_in_world`).
* **Tasks:** new module `app/document/assembly_group.py` (pure functions, no HTTP): component discovery from `part.mates`/`part.occurrences` (frozen = `fixed` + `""`
  refs); variable layout; stacked residual + central-difference Jacobian; `dof`, `grounded`, orthonormal weighted `basis` (lever-arm metric), per-member `mobility`,
  `quality` (σ_min, σ_gap). Numerically robust rank (relative tolerance). Reuse existing residual/geometry helpers; **do not modify** py-slvs solve paths.
* **Tests:** B/C/D plate scene → per-occurrence-alone DOF 0/1/1 (existing behaviour) and **group DOF 5**, mobility 3 each, all-translate-together-in-x/y in the nullspace; peg←B←C
  chain (group 5, B +12 drags C); `fixed` peer never a variable; suppressed mate ignored; no mates → 6 free; ungrounded component → `grounded:false`; conflicting/redundant mates → rank correct.
* **Exit:** unit tests green; timing note for k = 1, 3, 8 occurrences on the test scenes recorded in the handoff (real-geometry cost is unmeasured today).

### S2 — Group solve / weighted retraction (CAD backend, M–L)
* **Read:** investigation §A.5 (iii), §E.4, `prototypes/e_weighted_retraction.py`; S1 module.
* **Tasks:** `solve_group(document, part, grabbed_id, wanted_pose, lever_arm)` — residual-verified weighted Gauss–Newton over all group variables, seeded from the wish (grabbed member)
  and current poses (others), retraction metric `diag(1,1,1,L,L,L)` per member, follower weights ≈ 0 for rotation/translation cost of non-grabbed members; convergence
  by `residual_inf`; `jump` vs prediction; **py-slvs kept** as fallback seed/verify for a single-member group (its warm-start fixes: spin-preserving coincident seed, concentric warm start).
  Fix `ANGLE` singular-start (nudge off the aligned orientation before Newton). Return `quality`.
* **Tests:** all five mate types reach `residual_inf < 1e-6`; nearest-solution behaviour equals or beats the current single-occurrence solve on the existing `test_assembly_solver.py` cases (parity suite);
  concentric-offset 90° wish: max frame step ≤ hand step (no pops) when re-anchoring every 9 frames (port `e_weighted_retraction.py` check); B/C/D "drag B +6 y" → B, D +6, C 0; non-convergence reports no basis.
* **Exit:** parity suite + new tests green; decision recorded on whether py-slvs remains in the loop.
* **Split point if too big:** S2a = solver, S2b = parity/ANGLE fix.

### S3 — Endpoint, commit, rewire (CAD backend, M)
* **Read:** this file §3; `router.py` (`mate_motion`, `solve_for_occurrence`, `preview_mate_solve_endpoint`, `create_mate`, `update_mate`, `update_occurrence_transform`); `schemas.py`.
* **Tasks:** implement §3 exactly (replacing the merged single-occurrence `mate-motion`; keep its v0 fields as temporary aliases per §1); `commit:true` persists all moved members atomically (single store transaction); re-implement `solve_for_occurrence`,
  `preview-mate-solve` and the post-mate snap on the group solver; remove `System.Dof` use for assemblies; update `docs/backend-api-notes.md` (VR's copy of the API notes lives in the VR repo — list what to update there in the handoff).
* **Tests:** HTTP tests for the whole contract incl. 422 fixed, `converged:false`, `commit` atomicity (all-or-nothing), `grounded:false`; the full existing assembly test modules stay green.
* **Exit:** backend suite green; VR at `main` (v0 client) still passes its e2e against this backend via the aliases; handoff lists the exact JSON examples for the two clients and the alias fields to delete in S9.

### S4 — Projector spec + golden vectors (CAD docs/tools, S–M)
* **Tasks:** `docs/motion/projector-spec.md`: weighted Gram–Schmidt, projection, **screw exponential-map integration**, lever arm rule, re-anchor policy (150 ms cap + `max_step` + `sigma_gap`),
  anchor acceptance test (`converged`, `residual_inf`, `jump`), blending of displayed-vs-anchor offset (τ ≈ 2 frames), rank-change hysteresis, `converged:false` behaviour, release/commit flow.
  `tools/motion_vectors/generate.py` (numpy, from `prototypes/geo.py`) → `docs/motion/vectors.json`: ≥ 40 cases (flat face, offset-axis concentric incl. 90° wish, angle cone, group B/C/D, rank change, blend) with inputs and expected outputs to 1e-9.
* **Exit:** vectors regenerate deterministically; spec reviewed by owner.

### S5 — VR adopts the contract (VR, M)  *(needs S3, S4; parallel with S6)*
* **Read:** `scripts/mates_tool.gd` (`constrain_drag`, `project_motion`, `weighted_basis`, `_drag_loop`, `_sync_with_motion_model`, `persist_pose`), spec + vectors, contract §3.
* **Tasks:** consume `members`/`basis`/`quality`; projector v2 in GDScript (screw integration, lever arm from mesh AABB radius, blend, acceptance test, rank-change hysteresis); persist via `commit:true` on release (one undo entry for all members); **delete** `_sync_with_solve` / `_motion_supported` legacy path and stop reading the v0 alias fields; per-frame apply to *all* group members (followers move).
* **Tests:** golden-vector unit test in Godot; `tests/e2e_mates_motion.gd` updated (real backend: requests per drag, group follow, commit atomicity, non-convergence hold); existing VR test suite green.
* **Exit:** VR e2e green against S3 backend; note request counts per 60-frame drag.

### S6 — Dart projector (CAD client, M)  *(needs S4)*
* **Tasks:** pure-Dart `client/lib/motion/free_motion_projector.dart` (+ `se3` chart, weighted basis, screw integration, blender, acceptance test, re-anchor scheduler as a testable class with an injected clock); `MateMotionDto` in `document_api_client.dart` per §3 (+ `mateMotion(...)` call, `commit`); instrumentation hooks (request counters, per-frame timing) for §H of the investigation.
* **Tests:** `flutter test` golden vectors (same JSON as S5) to 1e-9; scheduler tests; DTO round-trip.
* **Exit:** no UI change yet; analyzer clean.

### S7 — Flat app live constrained drag (CAD client, L)  *(needs S3, S6)*
* **Read:** investigation §A.0, §A.3; `part_viewport.dart` (`_tryBeginComponentGizmoDrag`, `_updateComponentGizmoDrag`), `part_screen.dart` (`_onComponentGizmoDragUpdate/End`, `_gizmoLiveTransform`, `_applyGizmoWorldTransform`, `_refreshAssembly*`), `component_gizmo.dart`.
* **Tasks:** at grab: `mate-motion` (anchor); each pointer-move: wanted pose from the gizmo math → projector → live pose for the grabbed **and follower** occurrences (render all); scheduler re-anchors; release: `commit:true`, replace the raw PATCH + 4 refresh calls with the response (+ one refresh), undo = one group entry (extend `_TransformUndoEntry`); typed Move/Rotate panel Apply → same endpoint; `converged:false` → hold pose + throttled "can't follow that move"; `dof == 0`/`mobility == 0` → gizmo says why.
* **Tests:** widget/unit tests with a fake API; regression: after a drag the stored pose of a mated occurrence satisfies its mate; unmated occurrences behave exactly as before (no extra requests).
* **Exit:** on a device or emulator the owner can drag a face-mated part in-plane and be blocked off-plane; request counters show ≈ 1 + 1/150 ms + 1.

### S8 — Flat app gizmo cues + DOF display (CAD client, M)  *(needs S7)*
* **Tasks:** per-handle free fraction from `basis`; grey/short locked handles, dim partial ones, hide gizmo at `mobility 0` with reason; in-plane **plane handle** for 2-DOF/3-DOF-in-plane cases; **re-pivot** rings on the screw axis; show group DOF / "not grounded" in the assembly panel; optional direct body drag (only if S0 chose it).
* **Exit:** owner walkthrough on the three reference mates (face, concentric offset axis, angle).

### S9 — Cleanup + docs (CAD + VR, S each)
* Remove the S3 **v0 alias fields** (`transform`, `free_twists`) once S5 has merged; remove superseded code paths (old `solve` call sites that re-solved single occurrences, dead DTOs), fix the doc/code drift (`assembly-scope.md` "gizmo clamped by mates" now true; docstrings in `router.py` / `document_api_client.dart`), update `docs/status.md`/`roadmap.md`, update VR `docs/backend-api-notes.md`/`status.md`. Regenerate `investigation` numbers only if behaviour changed materially.

### Optional sketch track (independent; schedule only if S0 says so)
* **S10 — Measure & decide (CAD client, S):** add the §H timers/counters to the sketch drag path (Android + Windows), record numbers in the tracker; owner decides Windows local solver vs drag-map.
* **S11 — Local-solver quick wins (CAD client, M):** solve only the connected component containing the dragged point (`_trySolveDuringDragLocally`); route rejected frames through the same guards on the network fallback; stop `_solveDuringDrag` applying unguarded frames.
* **S12 — Mobility oracle + authoritative sketch DOF (CAD backend + client, M–L):** rank/probe-based `dof` replacing `System.Dof` + floors in `SolveResultDto` (changed in place), per-point mobility for the grabbed point, axis-lock cursor, replace `isPointFullyPinned` structural gate; keep closed-form drags for redundant tangent webs (probe unreliable there).
* **S13 — Windows local solver (CAD build, M):** wire `didsa_slvs_ffi` into the Windows build (harness exists) *or* drag-map, per S10.

## 7. Tracker

| ID | Title | Repo | Depends | Status | Branch / PR | Handoff notes |
|---|---|---|---|---|---|---|
| S0 | Decisions + tracker | CAD | – | ☑ | (this PR) | Confirmed by default, 2026-09-30: §2 defaults as written (followers follow; ungrounded component = free rigid group, `grounded:false`; scope = mate-graph component within the focused part; `ANGLE` singular start is fixed in S2) and §3 as the contract of record. S10+ (sketch track) not scheduled. |
| S1 | Group model core | CAD | S0 | ☑ | `ccr-e026bd6a-4ql2g8` / PR (see status.md 2026-09-30) | `backend/app/document/assembly_group.py` (+ `tests/test_assembly_group.py`, 11 tests, real OCCT + py-slvs env). API for S2/S3: `discover_component`, `build_group_model(document, part, grabbed_id, also_frozen=)` → `GroupModel` (`.residual(x, poses=)`, `.jacobian(poses=)`, `.member_ids`, `.base_transforms`), `analyze_group(document, part, grabbed_id, lever_arm=None)` → `GroupAnalysis` (`dof`, `rank`, `grounded`, `basis` (dof×6k rows), `mobility{id:int}`, `quality`), `apply_delta(transform, delta)`, `bounding_radius`. **Decisions:** members ordered grabbed-first then `part.occurrences` order (= basis column order); frozen = `fixed` + `""`, a frozen occurrence never joins components; `grounded` = some mate in the component touches a frozen ref (a mate to a fixed part counts even if DOF stays >0); rank = SVD of the lever-arm-weighted Jacobian with relative tol 1e-6·σ_max (rank was identical for tol 1e-9…1e-3 and lever 0.5…500 on B/C/D); `mobility` = rank of the member's block of the weighted basis (tol 1e-6); `sigma_min` = smallest retained σ, `sigma_gap` = σ_min / largest dropped σ (floored at eps·σ_max, so finite); both are `None` at rank 0 — S3 must serialise as null or pick a sentinel; `residual_inf` at stored poses is what flags conflicting mates (rank alone cannot: redundant and conflicting rows both leave rank unchanged); default lever arm = half-diagonal of the occurrence's local bbox (S3 may override). Mates are oriented like `_applicable_mates` (movable side = "driven" when the other side is frozen). The perturbation convention duplicates `_free_motion`'s closure (`apply_delta`) rather than refactoring it — no solve path touched. Errors: `GroupError` (unknown/frozen grabbed); unresolvable refs raise `assembly_solver`'s existing HTTPException. Suppressed *occurrences* are not special-cased (only suppressed mates are ignored). Scenes: B/C/D → group DOF 5, alone-DOF 0/1/1 (HTTP `mate-motion` and module with peers frozen agree), mobility 3 each; peg←B←C group 5, B+12 in nullspace only with C riding along; row of k boxes → DOF k+2. **Timing** (best of 5, this sandbox, box parts, lever given, includes geometry resolve): k=1: 0.8 ms (6 vars; model build 0.3); k=3: 6.2 ms (18 vars; build 1.1); k=8: 38 ms (48 vars, 15 mates; build 3.0) — cost is dominated by the 2·6k residual evaluations of the Jacobian and grows ~k²; 38 ms at k=8 is above the ~3.5 ms single-occurrence figure, so S2/S3 should not re-differentiate every frame (analytic/cached Jacobian or per-anchor only). Real-geometry (non-box) cost still unmeasured. |
| S2 | Group solve / weighted retraction | CAD | S1 | ☑ | `ccr-e026bd6a-4ql2g8` (same branch/PR #266 as S1 — only one designated branch) | `assembly_group.solve_group(document, part, grabbed_id, wanted_pose=None, lever_arm=None, also_frozen=frozenset())` → `GroupSolveResult(converged, poses{id: RigidTransform}, analysis: GroupAnalysis|None, quality: GroupSolveQuality(residual_inf, jump, iterations, seeded_by), .dof)`. Nothing stored. Not converged ⇒ `analysis is None` (no basis). Also public: `pose_delta(new, old)` (inverse of `apply_delta`). **Algorithm:** grabbed member seeded at the wish, others at stored poses; `_seed_poses` (below); then weighted minimum-norm Gauss–Newton `dx = −W⁻¹·pinv(J W⁻¹)·r` on the S1 stacked residual, metric `diag(1,1,1,L,L,L)` for the grabbed member and 1e-4× that for followers (`_FOLLOWER_WEIGHT`; 1e-3 leaked ~1e-6 of a move back onto the grabbed body), step cap 0.6 rad, backtracking on ‖r‖₂; converged ⇔ `residual_inf ≤ 1e-7` (verified by residual, never a solver code). **Seeds (only where plain GN on the residual can't work):** COINCIDENT plane–plane fully aligned by minimal rotation when the partner is frozen (= py-slvs' spin-preserving seed; residual is sign-agnostic so `flipped` is invisible to it), only un-flipped when the partner is a member; ANGLE at an (anti)aligned start rotated onto the target angle about a perpendicular axis (**this is the ANGLE singular-start fix — the aligned start now converges, py-slvs still does not**); DISTANCE within ¼·value of zero separation slid out to exactly the value (squared residual has zero gradient at 0). `flipped` ANGLE is solved as the supplement (`build_group_model` swaps `value` → 180−value; S1 residual otherwise ignores `flipped`). **Parity** (13 single-occurrence scenes, all five mate types, flipped, wrong-way start, singular ANGLE/DISTANCE starts, same wish for both solvers): group residual_inf < 1e-7 on every scene; distance from the wish is identical to py-slvs to 4 decimals on all 10 scenes py-slvs shares an answer on, better on both DISTANCE scenes (27.0 vs 30.2, 3.06 vs 3.52); py-slvs fails `angle_60_from_aligned`, group converges. **py-slvs decision:** stays only as a fallback seed for a single-member group when GN fails (`seeded_by:"slvs-fallback"`); it was never needed in any test scene. Recommend keeping it until S3 has rewired the endpoints, then deleting the fallback if production never reports it (S3 can log `seeded_by`). **No-pop check:** solver half only — off-axis pin, 90° swing, re-anchor every 9 frames from the persisted anchor: consecutive-anchor step max 4.07 (weighted mm) vs py-slvs 4.46; both exceed the hand's own 3.10 per interval, so the prototype's "≤ hand step" did NOT reproduce for this scene (manifold curvature; the toy used a different path) — the display-side pop needs the S4/S6 screw projector. `quality.jump` = weighted distance (grabbed block) between the solved pose and the additive first-order prediction from the stored pose's basis: ~0 on flat mates (B/C/D: < 1e-6), grows with curvature × wish distance (up to 6.6 on the swing scene) — S3 should still expose it; `max_step` (contract §3) is NOT computed yet (S4 decides its rule). **B/C/D:** drag B +6 y → B, D +6, C 0 (exact); drag B +4 x → C follows +4. Peg←B←C: B +12 z ⇒ C +12 z; with C frozen the move is refused. Conflicting mates ⇒ `converged:false`, `analysis None`, residual_inf > 1. **Timing** (box parts, best of 5, includes geometry resolve, 2 GN iterations for a small y move + 2 analyses for basis and jump): k=1 1.8 ms, k=3 26 ms, k=8 175 ms. Jacobian evaluations dominate (each GN iteration + analysis-at-solution + analysis-at-rest for `jump`); S3 should add a `with_jump` flag / reuse the anchor Jacobian, and a per-frame path must never call this — only the ~150 ms anchor. Split point S2a/S2b was not needed. |
| S3 | Endpoint, commit, rewire | CAD | S2 | ☑ | `ccr-e026bd6a-4ql2g8` (PR #266, with S1–S2) | `POST …/occurrences/{grabbed}/mate-motion` implements §3 as written (`router.mate_motion`, schemas `MateMotion*`): request `{transform|null, lever_arm?(>0), commit}`; response `{converged, dof (GROUP), grounded, members[{occurrence_id, transform, mobility}], basis (dof×6k, member order), chart{kind:"se3_owner_frame", lever_arm}, quality{residual_inf, sigma_min, sigma_gap, max_step, jump}, diagnostics{solve_ms}, committed}`. **Deviations from §3, all nullable:** `quality.max_step` is always `null` (S4 defines the rule); `sigma_min`/`sigma_gap` are `null` at rank 0; `converged:false` returns `dof/grounded/basis/chart/members = null/[]` and only `quality.residual_inf` + diagnostics (clients must treat missing basis as "hold", never "free"); extra field `committed`. Fixed grabbed → 422 `occurrence_is_fixed`. `commit:true` writes every member's pose in one in-memory pass after the whole group was solved and residual-verified (all-or-nothing; `converged:false` never writes). **Rewired on the group solver:** `POST …/solve` (was single-occurrence py-slvs; now the whole component, stores the group, so followers move; 422 `mate_solve_did_not_converge` unchanged but its `dof` is now `null`), `preview-mate-solve` (hypothetical mate joins the graph via `extra_mates`, nothing stored). The post-`create_mate` snap is the client calling `/solve`, so it is covered; `create_mate` itself never solved. Unsupported mate geometry (e.g. CONCENTRIC on two planar faces) is still a 422 `unsupported_mate_geometry`, now raised by `build_group_model`. `System.Dof` was already unused in `assembly_solver` (rank-based since Fix 4B) — nothing to remove; `solve_occurrence`/`preview_mate_solve` are no longer called by the router but stay in `assembly_solver` (py-slvs path, used by the alias and the S2 fallback seed). **v0 aliases (delete in S9):** response `transform` and `free_twists` = the old single-occurrence answer from `solve_occurrence_from_guess` (present only if that converged). NOTE `dof` semantics changed in place (now group dof); VR on `main` never reads `dof` (checked `mates_tool.gd`: uses `transform`, `free_twists`, `converged`). **Cost:** each request runs the group solve AND the legacy solve for the aliases (extra py-slvs solve, ~ms); `solve_ms` covers the group solve only. `with_jump=False` is used by `/solve` and preview. **JSON example (B/C/D scene, grab B, `lever_arm` 12.5, abridged):** `{"converged":true,"dof":5,"grounded":true,"members":[{"occurrence_id":"occ-B","transform":{"translation":[20,20,10],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"mobility":3},{"occurrence_id":"occ-C",…,"mobility":3},{"occurrence_id":"occ-D",…,"mobility":3}],"basis":[[…18 floats…]×5],"chart":{"kind":"se3_owner_frame","lever_arm":12.5},"quality":{"residual_inf":1e-15,"sigma_min":…,"sigma_gap":…,"max_step":null,"jump":0.0},"diagnostics":{"solve_ms":…},"committed":false,"transform":{…},"free_twists":[]}`; non-converged: `{"converged":false,"dof":null,"grounded":null,"members":[],"basis":null,"quality":{"residual_inf":5.0,…},"diagnostics":{…},"committed":false}`. **Docs:** `docs/backend-api-notes.md` does not exist in this CAD repo — the contract lives in the `MateMotion*` docstrings and here; VR's `docs/backend-api-notes.md` (exists, NOT edited — VR is a separate repo/session) needs: `mate-motion` request `lever_arm`/`commit`, group response, `/solve` now moves followers. **Verification gap:** the VR e2e (`tests/e2e_mates_motion.gd`) was NOT run — no Godot in this sandbox; the alias fields it reads are covered by HTTP tests only. |
| S4 | Projector spec + golden vectors | CAD | S2 | ☐ | | |
| S5 | VR adopts contract | VR | S3, S4 | ☐ | | |
| S6 | Dart projector | CAD | S4 | ☐ | | |
| S7 | Flat live constrained drag | CAD | S3, S6 | ☐ | | |
| S8 | Flat gizmo cues + DOF display | CAD | S7 | ☐ | | |
| S9 | Cleanup + docs | CAD, VR | S5, S8 | ☐ | | |
| S10–S13 | Sketch track (optional) | CAD | S0 | ☐ | | |

## 8. Prompt template for each session

> Repo: `<CAD|VR>`. Implement **Sn** of `docs/constrained-drag-implementation-plan.md` (attach DIDSA-CAD for the doc if the session is on VR).
> Read §1–§4 and the Sn brief first, then only the files it lists. Follow the contract in §3 exactly. Stop when the brief's exit criteria pass;
> don't start the next session's work. Finish by updating the tracker row (branch/PR, handoff notes) and adding a dated `docs/status.md` entry.
> Constraints: no unrelated refactors; run the tests the brief names against the real solver / real backend where the brief says so; report anything
> you could only verify by reading.
