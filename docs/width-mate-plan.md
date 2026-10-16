# Width mate (and Symmetric, later) — plan

Follows `docs/mate-solution-choice-plan.md` (Phases 1–4 and the hinge swing sense are shipped, PR #300 / VR #46). That plan's Phase 5
named this as a separate scope; this document is that scope. Read the "Constraint model", "branch" and "Phase 4" parts of that plan
first — this plan reuses all of it and deliberately changes none of it.

## Progress

| Phase | Summary | Status | PR |
|---|---|---|---|
| W1 | Backend: mid-plane mate reference, validation, solve/preview/branches, export/import | Not started | |
| W2 | Flutter: four-pick Width flow in the mate panel, highlighting, edit | Not started | |
| W3 | VR: the same flow on the tablet / wheel | Not started | |
| W4 | AI plan schema + docs + measurement on the tester's table top | Not started | |
| W5 | Symmetric mate (faces/points on two *moving* occurrences about a plane) | Not started — scoped below, needs its own go-ahead | |

Update this table with every PR, the same as the parent plan.

## 1. The problem

The tester's real intent for the table top was *"centre this plate between those two frame faces"*. Today they express it with two
distance mates (inset from each face), and each distance has two roots (inset or overhang; Phase 4 and the branch controls
helped, but the benchmark still has the table top at 6 of 17 centred with nothing named). A **Width** mate says it in one
unambiguous mate: the plate sits midway between two parallel faces of another part. SolidWorks calls it *Width*; Inventor's
nearest is *Symmetry*.

Scope of Width, precisely:

- **Two faces on one occurrence** (the "frame": two parallel planar faces, the gap) and **two faces on another occurrence** (the
  "tab": the plate's two parallel faces, or its mid-plane). The tab is centred between the gap faces.
- Variants the same mate must cover without new machinery: centred (offset 0), centred with a signed offset from centre
  (`DISTANCE` between the two mid-planes), and "tab parallel but not centred" is *not* Width (that is two distances).
- Not in W1–W4: the two faces on *different* occurrences (a gap formed by two parts), and Symmetric (W5).

## 2. Design decision: a mate between two synthetic mid-planes

Every layer assumes `len(mate.references) == 2` (see the list in §9). Rather than make a mate hold four references, a Width mate
**stays a two-reference mate**; each reference is a *mid-plane of two faces*:

```
Mate(type=COINCIDENT | DISTANCE | PARALLEL, references=[
    MateEntityRef(occurrence_id=frame, midplane=(PlaneRef(face_ref=A), PlaneRef(face_ref=B))),
    MateEntityRef(occurrence_id=plate, midplane=(PlaneRef(face_ref=C), PlaneRef(face_ref=D))),
])
```

- A mid-plane reference resolves to an ordinary plane (`_ResolvedGeometry.plane`), exactly what a face reference already resolves
  to. Therefore the existing plane–plane residuals (`COINCIDENT` = centred, `DISTANCE` = offset from centre, `PARALLEL`), the
  group model, local retraction, ghost/preview/alternatives, the branch machinery (`alignment`, `secondary_flip`, Closest) and the
  **constraint model JSON sent to clients all work unchanged** — the model sees a plane. No constraint-model version bump, no new
  vectors, no Dart/GDScript retraction change. (Verify this claim first thing in W1 — it is the plan's load-bearing assumption;
  see Risks.)
- A **new mate type is not needed**: "Width" is a UI/authoring concept. The stored mate is `COINCIDENT` (centred) with mid-plane
  references; the panel shows it as "Width". `DISTANCE` with the mid-plane references gives "offset from centre".
- The mid-plane is computed by the existing `create_plane.resolve_midplane_from_bodies(part, bodies, plane_ref_a, plane_ref_b,
  frozenset())`: origin = average of the two origins, normal from the first. It already fails closed with a 422
  `faces_not_parallel` when the faces are not parallel; reuse that error and its message for the mate-create validation.

Why not the alternatives:

| Option | Why not |
|---|---|
| A four-reference mate | Touches every `len == 2` check, `build_group_model` sides, the constraint model (and so four implementations and the vectors), both panels' two-pick flows. Large and risky for one mate. |
| Auto-create a `CreatePlaneFeature` MIDPLANE in the frame *part* and mate to it | Mutates the part definition from the assembly (which may be a shared external part), and the plane has to be kept in sync as the part is edited. The existing `plane_feature_id` ref still works if a user *has* made such a plane; this plan does not require it. |
| A new `MateType.WIDTH` | A `MateType` ripples through the solver dispatch, schemas, native format, both clients. Not needed: the type adds nothing the mid-plane reference does not already express. |

## 3. Data model

`MateEntityRef` gains a fourth "exactly one of" field:

```python
midplane: tuple[PlaneRef, PlaneRef] | None = None   # two parallel plane-like refs on occurrence_id's part
```

(or a small `MidplaneRef(a: PlaneRef, b: PlaneRef)` dataclass, matching `PlaneRef`/`PointRef` style — prefer the dataclass.)

Touch list (backend):

- `models.py` — `MidplaneRef`, `MateEntityRef.midplane`; update the docstring ("exactly one of the *four*").
- `schemas.py` — `MateEntityRefResponse` and the create/update request models; the response must round-trip it.
- `router.py` — `_validate_mate_entity_ref` ("exactly one of subshape_ref, plane_ref, point_ref, or midplane") and, for a mid-plane,
  validate each `PlaneRef` with `_validate_plane_ref`; the `A Mate must have exactly 2 references` checks stay as they are.
  Mid-plane refs are only valid for plane-plane mate types (`COINCIDENT`, `DISTANCE`, `PARALLEL`); reject `CONCENTRIC`/`ANGLE`/etc.
  with a clear 422 (an `ANGLE` between mid-planes is mathematically fine but pointless — keep it out of W1 to keep the branch
  surface small).
- `assembly_solver._resolve_local_geometry` — a `midplane` branch calling `resolve_midplane_from_bodies`; returns
  `_ResolvedGeometry(point=plane.origin, plane=plane, direction=plane.normal)` like the face branch. **Check the py-slvs path:**
  it needs the plane's x/y axes (`ResolvedPlane` has them: `x_axis`/`y_axis` from the first reference), and the second face of a
  gap may be the anti-parallel one — normal is "corrected" to the first's, so orientation/branch is defined by the *first* face.
  Document that explicitly for the user-facing alignment label.
- `native_format.py` (~2063, `references` serialization) — write/read `midplane`; old files without it load unchanged; files with
  it must round-trip through export/import (add a regression test in the style of the numpy-bool one: build, export, import, equal).
- `ai_plan.py` / `ai_plan_schemas.py` — accept `midplane` in mate refs (W4), including the plan validator's "exactly one of" check.
- Drift/health: `mate_health` (VR) and the backend equivalent that re-resolve `subshape_ref` after a part edit must also re-resolve
  the two `PlaneRef`s of a mid-plane; if either face is lost the mate reports the same "reference lost" state as a lost face today.
  A mid-plane whose faces stop being parallel after a part edit must report a **distinct** state ("faces no longer parallel"), not
  a generic solve failure.

## 4. Solve, preview, branches

- `_mate_solve_target`, `_solve_new_mate`, `_preview_alternatives`, `search_branch_changes`: unchanged by construction — they see a
  plane-plane mate. Add tests proving it rather than assuming it (§8).
- Phase 4's `_phase4_default` applies to *facing* plane distance defaults; for a centred Width (`COINCIDENT`) `alignment` has two
  roots (plate right way up or flipped) — Closest picks the nearer, and the Aligned/Anti-aligned control already exists. For a
  symmetric tab the flip is geometrically invisible (the plate looks identical) — that is fine and should be called out in the
  UI copy only if testers trip on it.
- **Degrees of freedom.** One mid-plane–mid-plane `COINCIDENT` removes 1 translation + 2 rotations, exactly like any plane–plane
  coincident; the user still needs one more mate for the in-plane DOF. Do not try to be clever and add implicit mates.
- A signed offset from centre is `DISTANCE` with `value >= 0` plus `secondary_flip` for which side — the existing convention;
  the panel labels it "Offset from centre".
- Ghost/preview for a Width mate: the preview already ghosts the moving occurrence; additionally highlight (client-side) the four
  picked faces and, optionally, draw the computed mid-plane. The mid-plane geometry is not returned today — `preview-mate-solve`
  gets an optional `midplanes` list (origin, normal, size hint) in W1 only if W2 needs it; otherwise compute client-side.

## 5. Flutter (W2)

Files: `client/lib/viewport3d/mate_panel.dart`, `part_screen.dart`, `client/lib/api/document_api_client.dart`.

- `MateEntityRefDto` gains `midplane` (two plane refs); `MateSolvePreviewDto` unchanged unless the mid-plane geometry is returned.
- Pick flow: a **"Width"** entry in the mate-type picker (so the user never sees "COINCIDENT of mid-planes"). The panel then runs
  a four-step pick: gap face 1, gap face 2 (same occurrence — enforce by greying out other occurrences after the first pick),
  tab face 1, tab face 2 (same occurrence, different from the gap's). Show "1 of 4 … 4 of 4" in the panel header, allow
  back/undo of the last pick, and live-validate parallelism the moment the second face of each pair is picked (the angle between
  normals is available client-side from the picked faces' plane data, or call the preview and surface `faces_not_parallel`).
- `_selectedEntities` today holds two picks; generalise to "pairs of picks" for the Width type only — do **not** change the
  two-pick behaviour of the other types. Keep the change local: a `WidthPick` state object owned by the panel.
- Branch controls (`MateBranchControls`, `mateBranchNotice`): reuse. Add the "Offset from centre" field for the offset variant.
- Edit (`_openMateEdit`): re-open a Width mate showing the four faces, re-pick allowed per pair.
- Highlighting: the four faces in two colours (gap pair / tab pair), the same highlight mechanism the existing two-pick flow uses.
- Tests: widget tests for the pick-count flow, the parallel error, and the edit round-trip; DTO round-trip test.
- Do **not** run `dart format` on these files (it reflows whole files); format only new files or apply edits by hand.

## 6. VR (W3)

Files: `scripts/mates_tool.gd` (`_picks`, `parse_value`, branch controls), `scripts/ui/tablet_pages.gd`, `scripts/ui/wheel_flows.gd`,
`scripts/design_table/mate_health.gd`.

- `mates_tool.gd`: a Width mode with `_picks` of four; same occurrence-pair constraints as Flutter; payload builder emits `midplane`.
- Tablet page: Width type, "1 of 4" progress, offset-from-centre field using `parse_value` (negative guard already in).
- Wheel flow: the wheel's mate flow picks two entities today; Width goes through the tablet first, wheel parity is a stretch item.
- `mate_health.gd`: drift/remake over `ref.subshape_ref` must learn `midplane` (§3).
- Known VR parity gaps from the parent plan still apply and are *not* part of this plan: live ghost when editing, a wheel wedge
  for Next solution, sub-assembly leaf ghosts, no headset run. Say so in the PR rather than silently inheriting them.
- Tests: `tests/mates_tool.gd` SMOKE lines for the four-pick state machine and payload shape; run `tests/ci.sh` with
  `DIDSA_CAD_DIR` set.

## 7. Symmetric mate (W5 — later, own go-ahead)

Symmetric = two *different moving occurrences'* faces/points mirror each other about a plane (a left and right bracket either
side of a centre plane). It cannot be a mid-plane trick: both entities move, and the residual is "point A and point B are
reflections of each other in plane P", which needs **three** references per side group.

What it needs, so the W1 design leaves room for it:

- A mate with three references — the first real break of `len(references) == 2`. That means the checks listed in §9, a
  three-entity side in `build_group_model`, a new residual family in `assembly_solver`/py-slvs and — because local retraction
  must stay in parity — the constraint model (version 4), `local_retraction.dart`, `local_retraction.gd`, and regenerated vectors
  via `tools/motion_vectors/generate.py` (the same four-places rule as the hinge change).
- Branch semantics: a reflection has an alignment (mirror vs. rotated-mirror) but no distance side; decide in the W5 scope.
- A cheaper first slice: *mirror one occurrence's pose about a plane relative to another fixed occurrence* is already expressible
  as Width with an offset when the geometry is a pair of parallel faces on one occurrence. Measure how many tester cases that
  covers before committing to W5.

## 8. Tests and measurement

Backend (`backend/tests/`, conda env from `backend/environment.yml`):

- Unit: `resolve_midplane_from_bodies` through `_resolve_local_geometry`; non-parallel faces → 422 `faces_not_parallel`; faces on
  different occurrences → 422; wrong mate type for a mid-plane → 422; native export/import round trip; old file loads.
- Pose tests on the tester's table top (`backend/tests/data/table_top_frame/`, `tests/table_top_fixture.py`): the `Frame`'s two
  facing inner bar faces (the gap the plate sits in; find them in the fixture, outer extent is y 0…800) and `Table_Top`'s two y faces → after `COINCIDENT` the plate is centred in y to 1e-6, for each
  of the unnamed/aligned/anti-aligned cases and from near/medium/far starts; offset ±5 mm lands the plate off-centre by exactly
  that on the named side.
- Preview/alternatives/branch search: the Width mate previews like any plane mate; changing another mate's branch (Phase 2b) still
  works with a Width mate present; `controls`/`alternatives` shapes unchanged.
- Drift: remove one of the four faces → "reference lost"; skew one so faces are not parallel → "faces no longer parallel".
- Parity: confirm that the constraint-model JSON for a Width mate is a plain plane–plane model (no new fields) and that
  `docs/motion/vectors.json` needs no regeneration (a test that regenerating produces an identical file).

Measurement (same methodology as the parent plan: ground truth by construction, near/medium/far starts, clicks = min(toggles,
Next-solution presses)): compare **time-to-centred** and **first-time-correct** for the table top with (a) two distance mates
(today) and (b) one Width mate. Report both plainly, including if Width is not better for some scenario.

## 9. Where "exactly two references" lives (for W5, and to prove W1 touches none of it)

- `len(mate.references) != 2` in `_applicable_mates`, `_live_mates`, `discover_component`, `preview_mate_solve_endpoint`, and the
  create-path checks in `router.py` (~3727, ~4588);
- `build_group_model` sides and the constraint model;
- Flutter `MatePanel`'s two-pick selection; VR `mates_tool.gd`.

W1 must leave every one of these untouched; if implementing it requires touching any, stop and revisit the design.

## 10. Risks

- **The load-bearing assumption** (mid-plane behaves as a plane everywhere): `_resolve_local_geometry` is not the only resolver.
  `mate_world_geometries`, the group model's per-side geometry, drift/health and the AI-plan checker each resolve references
  separately — grep every `subshape_ref`/`plane_ref` consumer (`rg "plane_ref|subshape_ref" backend/app client/lib scripts`)
  and list them in the W1 PR. A missed consumer is the most likely bug.
- Mid-plane origin on a *curved gap* (non-planar faces): not supported; planar faces only, same as `resolve_plane_ref`.
- Reference stability: subshape identity after part edits is the same fragility as any face-based mate; no new mechanism.
- Anti-parallel pair on the tab (plate faces point opposite ways): `resolve_midplane_from_bodies` corrects the normal to the first
  reference's; verify the corrected normal is what Aligned/Anti-aligned labels mean, and show it in the preview.
- Four-pick UX is the real usability risk — prototype it in W2 behind the mate-type picker and get a tester on it before W3.

## 11. Order of work

1. W1 backend end to end with tests, no client change (create a Width mate through the API; export/import; benchmark script).
2. W2 Flutter. 3. W3 VR (mirror W2). 4. W4 AI plan, docs, measurement write-up in this file.
5. Stop and report before W5.

Ground rules carried over: keep legacy files' stored poses exact; never change a mate's stored branch during drag/mate-motion;
`flipped` stays a deprecated alias; say plainly which suites could not be run; before each push run the suites, re-read the diff,
fix what CI would reject; update this Progress table with every PR.
