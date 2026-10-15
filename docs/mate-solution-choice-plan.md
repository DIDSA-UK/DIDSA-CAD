# Mate solution choice ("multiple roots") — investigation and implementation plan

Source: tester report while building `Top_and_frame.didsa`. A 1580 × 780 × 5 table top was meant to sit centred
on an 800 × 1600 frame, 10 mm in from each outer edge. It took many attempts to get it in the right place. The Mate
ghost preview was sometimes wrong or missing. The tester's five files are **not committed**; ask the tester to attach them to the implementation session, and add them as fixtures under `backend/tests/data/table_top_frame/` only with their agreement.

This doc is written for a **follow-up implementation session**. Code pointers were checked against `main` at
`6c11dc5`. Line numbers drift, so search for the named symbol if a line is off. The investigation was
done by replaying the tester's mates, and small scenes for every mate type, through the real backend
(`TestClient`, the full conda env from `backend/environment.yml`).

Suggested order: **Phase 1 → 2 → 2b → 3 → 4**. Phase 2b must land with or right after 2: persisted branches without
it turn F6 from an occasional failure into a common one. Phase 5 is a separate scope. Phase 1 is small, independent and fixes
visible bugs. Phase 2 is the core change: every later phase builds on its data model.

## Progress

The implementation session updates this table as each PR merges.

| Phase | Summary | Status | PR |
|---|---|---|---|
| 1 | Ghost preview fixes (missing ghost, followers, sub-assemblies) | Not started | |
| 2 | Persisted mate *branch* (alignment / side) honoured by every solver | Not started | |
| 2b | A new mate that needs another mate's branch changed: search, preview notice, atomic confirm | Not started | |
| 3 | Mate panel controls: Aligned/Anti-aligned, Flip side, Next solution (Flutter + VR) | Not started | |
| 4 | Better default for "Closest" (optional) | Not started | |
| 5 | Width / Symmetric mate (separate scope) | Not started | |

---

## Background: what a "root" is here

Most mates have several separate placements that satisfy them exactly; the literature calls choosing among them
the *root identification problem*. These choices are discrete (a flip), unlike a remaining degree of freedom
(a slide or spin). Every solver in this repo
(`assembly_solver.py` py-slvs path, `assembly_group.py` Gauss-Newton, `constraint_model.py` and its Dart/GDScript
mirrors) uses **sign-agnostic residuals**:

- `cross(dn, fn)` for "these directions are parallel" is zero for aligned **and** anti-aligned directions.
- `signed² − d²` for a distance is zero at **+d and −d**.

So the solve lands on whichever root is nearest the start pose. Nothing stores which root was chosen, so a later solve or
drag can land on a different one. The only exception is COINCIDENT plane-plane: `flipped` picks the root through a seed
(`_seed_poses` in `assembly_group.py`, `seed_rotation_quaternion` in `assembly_solver._solve_occurrence_against`)
that is re-applied on **every** solve. That is why it is the one mate type that behaves well.

## Findings

### F1. The tester's case: DISTANCE plane-plane has 4 roots and no control

`assembly_solver.py` `_add_mate_constraints` DISTANCE uses `abs(mate.value)` (≈ line 773).
`_mate_residual_vector` uses `signed*signed − target_sq` plus `cross(normals)` (≈ lines 1056-1060). Roots are
{aligned, anti-aligned normals} × {+d, −d}. The Mate panel offers no Flip for distance
(`client/lib/viewport3d/mate_panel.dart` `mateTypeHasFlip`). A negative value is accepted and silently `abs`'d.

The tester's two edge-distance mates plus the coincident top-face mate allow ~8 valid placements, and only one is
centred. Replaying their three mates through `preview-mate-solve` → `POST /mates` → `/solve?movement=auto` from 18
start poses gave the following:

| Start | Result |
|---|---|
| Inserted at origin (identity) | turned 180° **and** entirely outside the frame (y −770…10, z −3160…−1580) |
| Correct pose ±5 mm, −8 mm, +30 mm (inward) | centred |
| Correct pose −12 / −30 mm (outward) | 10 mm outside instead of inside |
| 8 random | 1 centred |

The rule users must currently discover is that whichever side of the frame face the plate edge is on when the mate is
added, it stays there (`_seed_poses` DISTANCE keeps `sign(current)`, `assembly_group.py` ≈ line 528).
The plate's spin about the top-face normal is whatever it was before.

### F2. Every other mate type (single-mate scenes, 10 starts each, `flipped` False/True; rows marked *code reading* were not run)

| Mate / geometry | Roots | What happens today | Flip control |
|---|---|---|---|
| COINCIDENT plane-plane | normals opposed / same | 10/10 opposed (unflipped), 10/10 same (flipped) | **works** (the reference behaviour) |
| COINCIDENT point-plane, point-point | none | — | — |
| COINCIDENT edge-edge (becomes CONCENTRIC, `_effective_mate`) | axis direction ± | nearest *(code reading; same path as CONCENTRIC)* | **inert** |
| CONCENTRIC, rotation free | axis direction same / opposite | 7/3 split unflipped, 6/4 flipped | **shown in UI, ignored by every solver** |
| CONCENTRIC, rotation locked | axis ± × spin 0/180° | all four combinations occur | **inert** (seed ignores `flipped`) |
| PARALLEL | aligned / anti-aligned | 8/2 and 6/4 split | none offered |
| ANGLE (free) | angle vs supplement; plus a cone (a DOF, not a root) | 60° / 120° exactly per `flipped` | **works** (group model rewrites value to 180−v, `build_group_model`) |
| ANGLE on a hinge (concentric edge + angle) | ±θ about the hinge × supplement | unflipped: lid up 3, hanging outside 8; flipped: up 6, **inside the base** 4; 1/12 failed to converge each way | supplement only; ±θ not controllable |
| DISTANCE point-plane | ±d side | nearest *(code reading)* | none |
| DISTANCE plane-plane | alignment × side (F1) | all four occur | none |
| DISTANCE axis-axis | axis direction ± | nearest *(code reading)* | none |
| DISTANCE point-point | none (a sphere is a DOF) | — | — |

Confirmed by grep: `flipped` is read only for COINCIDENT plane-plane (both solvers) and ANGLE. CONCENTRIC's
`flipped` is stored, sent and shown but never used.
`constraint_model.export_constraint_model` does not export `flipped` at all. The client-side live-drag projectors
(`client/lib/motion/local_retraction.dart`, VR `scripts/motion/local_retraction.gd`) therefore cannot honour a
root either.

### F3. Dragging a mated part can jump to the other root, and `commit` stores it

- DISTANCE 15 mm (bracket above a base): drag wish z = 5 → the bracket jumps to **15 mm below** the face (inside the
  base), and stays there.
- CONCENTRIC pin: drag wish tilted 100° → the pin **turns over** (axis z-component 1 → −1).

COINCIDENT plane-plane does not jump, because its seed re-applies `flipped` every solve.

### F4. Ghost preview bugs

1. **Missing ghost when Gauss-Newton needs the py-slvs fallback.** `solve_group` retries a single-member group from
   `solve_occurrence_from_guess` (`assembly_group.py` ≈ line 703). That function gathers mates through
   `_applicable_mates(part, …)` (stored mates only), so **the hypothetical preview mate (`extra_mates`) is
   dropped**. The retraction from that seed stalls, `preview-mate-solve` reports `converged: false`, and no ghost is
   shown. Confirm then works, because the mate is real by then. Reproduced on the tester's first distance mate.
2. **Gauss-Newton stalls just short of tolerance on large distance moves.** Starting 1560 mm away, GN reached
   residual 7.7e-6 (≈4e-7 mm) and could not go further. The squared residual is in mm² against an absolute
   `_SOLVE_TOL = 1e-7`, and spurious ~1e-3 singular values from the finite-difference Jacobian pass through
   `pinv`. This is why the fallback in F4.1 is hit so often.
3. **Ghost shows only the driven occurrence.** `preview_mate_solve_endpoint` returns
   `result.poses[occurrence_id]` only (`router.py` ≈ line 4289). With `movement=group`, or `auto` falling back to group,
   followers move on Confirm but not in the ghost. The VR client never sends `movement`, so it always gets group.
4. **No ghost for a sub-assembly.** `_syncMatePreviewNode` (`client/lib/viewport3d/part_viewport.dart` ≈ line 2762)
   draws only `assemblyGeometry` entries whose `partId` equals the driven occurrence's part. A sub-assembly part
   (e.g. `Frame`) has no bodies of its own. Seen in code, not yet reproduced in the app.
5. **Edit Mate has no preview at all** (`_openMateEdit`, an `AlertDialog`). It also picks the driven occurrence
   first-reference-first, while create prefers the second reference.

"Minimal movement" (`_solve_with_movement`) is consistent between preview and commit. It is not a cause of
F1-F4, but it does keep the "nearest root" behaviour.

### F5. Stale docs

`assembly_solver.py`'s module docstring says COINCIDENT plane-plane uses `addSameOrientation` (3 DOF). The code uses
`_direction_lock` (`addParallel`, 2 DOF, spin free). The `Mate` docstring in `models.py` says `flipped` serves
CONCENTRIC, which it does not.

### F6. A new mate that needs an EARLIER mate on its other root is refused, and stays stored anyway

Scene: base box 20 × 20 × 10, bracket 8 × 8 × 4.
1. Add DISTANCE 14 mm between the bracket bottom and the base top. It is solved from above, so the bracket bottom
   sits at z = 24.
2. Add COINCIDENT between the bracket top and the base bottom. This can only hold if the bracket bottom is at
   z = −4, i.e. with mate 1 on its other side.

Today:
- The preview reports `converged: false`, so no ghost shows.
- `/solve` returns 422 with "The mates on this part can't all be satisfied together.". That is wrong: a valid
  placement exists. `solve_group` seeded from z = −4.5 converges to exactly z = −4. Gauss-Newton just cannot cross
  from one root of mate 1 to the other.
- **The refused mate is still stored.** `_confirmMate` (`part_screen.dart`) calls `createMate` then
  `solveForOccurrence`, and nothing rolls back on failure. The assembly is left over-constrained, and a second
  Confirm adds a duplicate.

Phase 2 makes this case more common, because every branch becomes persisted. Phase 2b handles it.

## How other CAD systems handle this

None solves root choice automatically in general (adding constraints to force a root is NP-complete). They all use the
same pattern: a proximity default, the choice **stored with the mate**, and explicit controls to change it while
previewing:

- **SolidWorks:** *Mate alignment* (Aligned / Anti-aligned) for every direction-carrying mate, plus *Flip dimension* on
  Distance/Angle. DriveWorks exposes a third alignment, *Closest*.
- **Inventor:** Mate vs Flush solution buttons with a signed offset; "Predict offset and orientation" reads both from
  the current pose.
- **Onshape:** mates between oriented mate connectors, with *Flip primary axis*, *Reorient secondary axis* (90° steps)
  and signed offsets. The orientation is part of the mate, so it cannot jump.
- **NX:** an alternate-solution / reverse control in the constraint dialog (from memory; not confirmed in this investigation).
- **Existing mates are never flipped silently.** SolidWorks marks the mates in error. Its *MateXpert* diagnostic
  lists the subsets of mates that conflict, shows how far each unsatisfied mate is off, and offers *Toggle
  alignment*, *Suppress* or *Edit* on each one. Phase 2b does the same search *before* the mate is stored, and
  shows the result in the preview.

This plan follows SolidWorks' model: two binary choices per mate, starting as "Closest" and then persisted, plus a
"Next solution" convenience.

---

## Phase 1 — Ghost preview fixes (backend + Flutter + VR, small)

1. **Pass the preview mate into the py-slvs fallback.** Add `extra_mates: tuple[Mate, ...] = ()` to
   `solve_occurrence_from_guess`, and have `_applicable_mates` accept and append them. Pass `extra_mates` from
   `solve_group`'s single-member fallback.
2. **Return every moved member from the preview.** Add `members: list[{occurrence_id, transform}]` to
   `MateSolvePreviewResponse` (`schemas.py`), holding every member whose pose changed. Keep `transform` for
   the driven occurrence, since VR reads it.
3. **Flutter ghost for all members and sub-assemblies.** Replace `matePreviewPartId`/`matePreviewTransform` with a list
   of `(occurrenceId, transform)`. In `_syncMatePreviewNode`, ghost every `assemblyInstances` entry whose
   `occurrencePath` starts with a previewed occurrence id. Use `T_ghost = T_new · T_old⁻¹ · instanceWorld`, so nested
   instances (a sub-assembly's leaf bodies) render.
4. **VR ghost.** `scripts/mates_tool.gd` `_run_preview`: build ghosts from `members`. Send `movement` like the flat
   client (add a `mate_minimal_movement` toggle mirroring Flutter's `_mateMinimalMovement`, default `auto`).
5. **Edit Mate preview.** Give `_openMateEdit` the same live preview, either by reusing `MatePanel` in an edit mode
   or by calling `previewMateSolve` from the dialog's change handlers. Use `_drivableOccurrenceId` with the same
   reference order as create.
6. **Atomic create (F6).** Add an optional `solve` query parameter (`group|minimal|auto`) to `POST /mates`. Run
   the same solve the preview runs, with the new mate as `extra_mates`. Store the mate and every member's pose
   together **only if it converges**; otherwise return the 422 and store nothing. Switch Flutter `_confirmMate` and
   VR `mates_tool.gd` to it. The edit flow gets the same treatment via `PATCH /mates/{id}?solve=…`, keeping the old
   values on failure.

Tests:
- Backend: the tester's table top replayed from the identity pose. `preview-mate-solve` for the first distance mate
  must converge and equal the post-`/solve` pose (fails today).
- Backend: a group-mode preview with a follower returns that follower in `members`.
- Flutter widget test: the ghost renders for a driven sub-assembly occurrence.
- Backend (F6 scene): `POST /mates?solve=auto` with the conflicting COINCIDENT returns 422 and `GET /mates` still
  lists only the DISTANCE mate.

## Phase 2 — Persisted mate branch (backend core + constraint model v2 + Dart/GD mirrors)

### Data model

Add two optional fields to `Mate` (`models.py`), `MateCreate`/`MateUpdate`/`MateResponse` (`schemas.py`),
`_mate_to_dict`/`_mate_from_dict` (`native_format.py`, additive `.get` convention), and the Dart `MateDto`:

- `alignment: "aligned" | "anti_aligned" | None` is the primary direction pair: whether the driven direction points
  the same way as the fixed one.
- `secondary_flip: bool | None` is the second binary choice. Its meaning per type is in the table below.

`None` means **Closest**: at the first solve it is resolved from the pose the solve starts from. The resolved value is
**written back** on create (`POST /mates` + `/solve`) and on any committed solve, so a mate is fully deterministic
afterwards. Legacy files lack the keys. Resolving them from the *stored* pose at the first solve reproduces their
current placement exactly, because a stored pose already sits on one root.

| Mate / geometry | `alignment` means | `secondary_flip` means |
|---|---|---|
| COINCIDENT plane-plane | normals same / opposed (**migrate**: `flipped=True` ⇔ `aligned`, `False` ⇔ `anti_aligned`) | — |
| CONCENTRIC (incl. edge-edge COINCIDENT) | axis directions same / opposite | rotation locked only: perp half-turn (spin 0° vs 180°) |
| PARALLEL | same / opposite | — |
| DISTANCE plane-plane | normals same / opposite | side: offset along +fixed normal (false) or −fixed normal (true) |
| DISTANCE point-plane | — | side, as above, relative to the plane's normal |
| DISTANCE axis-axis | axis directions same / opposite | — |
| DISTANCE point-point, COINCIDENT point-* | — | — |
| ANGLE | — | supplement (**migrate** from `flipped`; keep `build_group_model`'s 180−v rewrite) |

Keep `flipped` on the wire and in files for one release as a deprecated alias: read it into the new fields when
they are absent, and write both. Reject `value < 0` for DISTANCE with a 422 ("use Flip side"). On load, map a legacy
negative value to `abs(value)` plus `secondary_flip` derived from the stored pose.

A helper `resolve_branch(mate, driven_world, fixed_world) -> Mate` (in `assembly_solver.py`, beside `_effective_mate`)
fills `None` fields from the current geometry: alignment from `sign(dot(dn, fn))`, side from `sign(signed offset)`,
perp from `sign(dot(dperp, fperp))`. Apply it in `build_group_model` (from `base_transforms`) and in
`_solve_occurrence_against`. Persist the resolved values in `_commit_group` callers (`solve_for_occurrence`,
`mate_motion` with `commit`, `create_mate`'s client flow). Preview resolves but never stores.

### Branch-specific residuals (the key change)

Replace each sign-agnostic residual with one that is zero **only** on the chosen branch and well-conditioned there.
Change it in all four places: `assembly_solver._mate_residual_vector`, `_mate_residual_satisfied`,
`constraint_model.ConstraintModel.residual` (analytic Jacobian), and the Dart/GD `local_retraction` mirrors.

- Direction with alignment `s = ±1`: `dn − s·fn` (3 rows, rank 2; non-degenerate at the target, unlike `cross`
  near the wrong root or a dot product at its extremum).
- Plane/point DISTANCE with side `k = ±1`: `signed − k·d` (linear; this also removes the F4.2 stall).
- Remaining squared forms (point-point, axis-axis radius): scale to mm as `(x² − d²) / (2d)`, so `_SOLVE_TOL` means
  the same thing as elsewhere (F4.2).
- ANGLE: unchanged (`dot − cos θ`); `secondary_flip` feeds the existing supplement rewrite.

py-slvs path (`_add_mate_constraints`): pass `k·distance` to `addPointPlaneDistance` (it is signed). Extend the
`seed_rotation_quaternion` logic so any mate with an `alignment` seeds the minimal rotation onto its target; this
fixes CONCENTRIC/PARALLEL flip. `_seed_poses` (`assembly_group.py`): generalise the COINCIDENT rule to every
alignment-carrying mate. For DISTANCE, slide to `k·d` when on the wrong side **or** near zero (today only near
zero).

Constraint model: bump `MODEL_VERSION` to 2. Export `alignment` (as ±1) and `side`/`perp` signs per mate.
Clients already return `null` (keep projecting) for an unknown version, so old clients degrade safely. Update
`docs/motion/vectors.json` and regenerate `backend/tests/data/local_retract_vectors.json` with
`tools/motion_vectors/generate.py`. Bump `kLocalModelVersion` (Dart) and `MODEL_VERSION` (GD) together.

DOF analysis (`_free_motion`, `analyze_model`) needs no change: the new residuals have the same rank at a solution.
Confirm this with the existing DOF tests.

Tests (backend):
- The tester's assembly: with explicit branches (`anti_aligned`/`aligned` as the file needs, side "inside"), it lands
  centred from **every** start used in this investigation (identity, ±12/±30 mm shifts, 8 random). Gauss-Newton must
  converge without the py-slvs fallback (`quality.seeded_by` has no `slvs-fallback`).
- Each row of the F2 table: both values of each control give exactly the matching root, from 10 starts.
- F3 regressions: dragging a DISTANCE bracket to z = 5 and a CONCENTRIC pin to 100° stays on the stored branch.
- Closest + persistence: create a mate with `None` fields, then `/solve`. The response and `GET /mates` show the
  resolved values.
- Legacy file round-trip: a mate without the new keys keeps its stored pose bit-for-bit after `/solve`. The tester's
  saved `Top_and_frame.didsa` is a good fixture.
- Native format: old → new → old round-trip; negative legacy distance migration.
- `test_constraint_model.py` parity vectors pass. Dart `local_retraction_test.dart` and VR equivalents pass.

## Phase 2b — When a new mate needs another mate's branch to change (backend + panel notice)

Rules:
1. **Who may change a branch.** Add `branch_source: "auto" | "user"` to `Mate`, persisted the same way as the
   branch fields. It is `auto` when Closest resolved the branch, and `user` once the user sets Aligned/Flip
   explicitly (Phase 3 controls, or the edit dialog). Only `auto` branches are candidates for an automatic
   change, and only with the user's confirmation.
2. **When.** Branch search runs only in the create/edit flow: `preview-mate-solve`, `POST /mates?solve=…`, and the
   matching `PATCH`. It **never** runs in `mate-motion`, a drag, or a plain `/solve` re-snap. A drag that would need
   another branch simply stops at the limit, which also prevents F3's jumping.
3. **Never silently.** The preview returns the needed changes. The user sees them before Confirm. Confirm applies
   the new mate, the branch changes and the poses together, as one undo step.

Search (`assembly_group.py`, new `search_branch_changes(model, new_mate, budget)`):
1. Solve with every persisted branch (the new mate at Closest, or at its Phase 3 alternatives). If it converges,
   stop; no changes are needed.
2. Candidates are the `auto` mates in the same mate-graph component. Order them by:
   - graph distance from the new mate's occurrences (mates on the same occurrence first);
   - then by each mate's residual at the failed solve's end point.
3. Try one changed field on one candidate at a time. Seed each trial with `_seed_poses`, which moves the member
   onto the trial branch; that seed is what gets Gauss-Newton across, as the F6 seeded solve showed. Then try
   pairs. Stop at a budget (constants, e.g. 24 solves or 1.5 s).
4. Rank the converged results by fewest changes, then by weighted movement (`pose_delta` · `_metric`).

Preview response additions:
- `branch_changes: [{mate_id, field, from, to}]` next to `members`. The ghost shows that placement. The Mate panel
  shows a notice naming the mate, e.g. "To fit, this also moves *Distance 1* to the other side", and Next solution
  (Phase 3) steps through further results.
- If only `user` mates stand in the way: `converged: false` plus `blocked_by: [mate_id]`. The panel says which mate
  to change, e.g. "Distance 1 is set to this side — flip it to allow this mate".
- If no branch combination works (a genuine conflict): `conflicting: [mate_id]`, the smallest set found by
  re-solving with one existing mate suppressed at a time, within the same budget (MateXpert-style).

Replace the misleading 422 text "can't all be satisfied together" with whichever of the three cases above applies.

Tests (F6 scene, plus the tester's assembly):
- The DISTANCE mate is `auto`. The preview of the COINCIDENT converges at bracket bottom z = −4, with
  `branch_changes` = [DISTANCE side +→−]. Confirm stores both mates, the flipped side and the pose.
- The DISTANCE mate is `user`: `converged: false`, `blocked_by` = [DISTANCE], and nothing is stored.
- A truly impossible third mate: `conflicting` names the mate it fights with.
- `mate-motion` with a wish across the boundary never changes any stored branch.
- Table top: the plate starts outside the frame, and both distance mates resolve `auto` to "outside". A later mate
  that needs "inside" (e.g. a 0 mm distance from the plate's far edge to a sketch plane at the inner position)
  offers the flip of both.

## Phase 3 — Mate panel controls and "Next solution" (Flutter + VR)

Backend:
- `preview-mate-solve` returns:
  - `resolved: {alignment, secondary_flip}`, the branch the ghost shows;
  - `controls: ["alignment", "secondary_flip"]`, the ones meaningful for the picked geometry (the client must not
    re-derive geometry kinds);
  - `alternatives`, a list of `{alignment, secondary_flip, members, movement_cost}`.

  Build `alternatives` by enumerating the ≤4 branch combinations of the **new** mate only, solving each from the same
  start (existing mates keep their persisted branches) and keeping the converged ones. Sort by weighted pose distance
  from the start (`pose_delta` · `_metric`). This costs at most 4 solves per preview.

Flutter (`mate_panel.dart`, `part_screen.dart`):
- Replace `mateTypeHasFlip` with controls driven by `controls`:
  - `alignment`: an *Aligned / Anti-aligned* segmented button; Closest is the initial state and shows the resolved
    value.
  - `secondary_flip`: labelled per type: *Flip side* (DISTANCE), *Flip spin* (CONCENTRIC locked), *Supplement*
    (ANGLE).
- **Next solution** button: steps through `alternatives` in order and sets the explicit fields, showing
  "2 of 4". This also covers ANGLE ±θ on a hinge, which has no field of its own.
- Distance input: minimum 0.
- The same controls in the Edit Mate flow (Phase 1.5 gives it a preview).

VR (`scripts/mates_tool.gd`, `scripts/ui/tablet_pages.gd`, `scripts/ui/wheel_flows.gd`): replace `mate_flipped` with
the two fields plus a Next-solution action, and send them in `build_create_payload`.

Tests: Flutter widget tests for the controls shown per `controls`, and for Next solution cycling and sending the
fields. A backend test that `alternatives` for the tester's first distance mate contains the centred-side root.

## Phase 4 — A better "Closest" default (optional, after 2-3)

Nearest-root is the industry default and stays the default. Two cheap tie-breakers can be considered when the nearest
roots are about equally far away (within 10% movement):
- prefer the root where the two bodies' bounding boxes do not overlap, i.e. no interference (`bounding_radius` /
  `Bnd_Box` already used in `assembly_group.py`);
- for DISTANCE plane-plane between same-facing faces (the tester's "inset from an edge" case), prefer the side that
  puts the driven face *behind* the fixed face.

Each is a heuristic and should be measured against a set of fixtures before landing. Skip this phase if Phase 3's
controls prove sufficient in testing.

## Phase 5 — Width / Symmetric mate (separate scope)

The tester's real intent was "centre this plate between those two frame faces". SolidWorks' *Width* and Inventor's
*Symmetry* express that in one unambiguous mate. It needs **four** references (two faces on each side). Every layer
assumes exactly two:
- `len(mate.references) != 2` checks in `_applicable_mates`, `_live_mates`, `discover_component`, `preview_mate_solve_endpoint`;
- `build_group_model` sides;
- the constraint model;
- `MatePanel`'s two-pick selection;
- VR `mates_tool.gd`.

Scope it as its own plan.

---

## Reproduction notes

- The tester's files (`Top_and_frame.didsa`, `Frame.didsa`, `Frame_A.didsa`, `Frame_B.didsa`, `Table_Top.didsa`)
  are not in the repo; see the note at the top. Compose them for `POST /document/import/native` the way the
  client composer does: walk `occurrences[].external_ref`, set each occurrence's `resolved_part_id` to the referenced
  file's `root_part_id`, then concatenate `parts` and `sketches`.
- Plate occurrence `8caca0b2-7da1-4082-931a-be065ce55456`; frame occurrence `32947d4e-…` (fixed). Correct plate box:
  x 30…35, y 10…790, z −1560…20 (frame outer y 0…800, z −1570…30).
- The backend tests need the conda env from `backend/environment.yml` (pythonocc-core is conda-only).
