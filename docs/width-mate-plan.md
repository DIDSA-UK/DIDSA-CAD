# Width mate (and Symmetric, later) — plan

Follows `docs/mate-solution-choice-plan.md` (Phases 1–4 and the hinge swing sense are shipped, PR #300 / VR #46). That plan's Phase 5
named this as a separate scope; this document is that scope. Read the "Constraint model", "branch" and "Phase 4" parts of that plan
first — this plan reuses all of it and deliberately changes none of it.

## Progress

| Phase | Summary | Status | PR |
|---|---|---|---|
| W1 | Backend: mid-plane mate reference, validation, solve/preview/branches, export/import | Done (PR open, awaiting review; not merged) | CAD (this branch) |
| W2 | Flutter: four-pick Width flow in the mate panel, highlighting, edit | Done (same PR; not merged; not tried by a human) | CAD #302 |
| W3 | VR: the same flow on the tablet / wheel | Done (tablet; wheel = type entry only; headless-tested, no headset) | DIDSA-VR (this branch) |
| W4 | AI plan schema + docs + measurement on the tester's table top | Done (same PR; not merged) | CAD #302 |
| W5 | Symmetric mate (faces/points on two *moving* occurrences about a plane) | Not started — scoped below, needs its own go-ahead | |

Update this table with every PR, the same as the parent plan.

## W1 implementation notes (what was built, and where it differs from the text)

- **One deviation from §2, needed by the tester's file:** the Frame is a *sub-assembly of four bars*, so its two gap faces sit on two
  different leaf occurrences (`Frame/<bar y0>` and `Frame/<bar y800>`), not on one. `MidplaneRef` is therefore `(a, b, b_occurrence_id)`:
  `b` may name another occurrence **under the same top-level occurrence** (null = the same occurrence as the reference). Face `b` is
  carried into `a`'s frame through the sub-assembly's own transforms (`assembly_solver._resolve_midplane_plane`, `invert_transform`),
  the maths is `create_plane.midplane_of_resolved` (the old `resolve_midplane_from_bodies` body, now shared). Faces under *different
  top-level* occurrences stay out of scope: 422 `midplane_faces_on_different_occurrences`. The mate is still a two-reference mate.
- **Untouched, as required:** every `len(references) == 2` check, `build_group_model` sides and the constraint model
  (`MODEL_VERSION` unchanged; `test_the_constraint_model_of_a_width_mate_is_a_plain_plane_plane_model`). The only solver edit is the
  new `midplane` branch in `_resolve_local_geometry` (plus two optional arguments, `document` and `root_part`, passed by its 5 callers).
- **Consumer audit** (every reader of a mate reference's geometry; `rg "\.references|MateEntityRef" backend/app`, plus `plane_ref` /
  `subshape_ref` on the Dart/GDScript side):
  - handled: `assembly_solver._resolve_local_geometry` (the only place a mate reference becomes geometry) and its 5 call sites:
    `assembly_group.build_group_model.side`, `mate_world_geometries`, `_with_world_hinge` (2), `assembly_solver._solve_occurrence_against`
    (driven + fixed); `router._mate_entity_ref_response` / `_mate_entity_ref_to_domain` / `_validate_mate_entity_ref` (+ the
    plane-plane type check) in create and `preview-mate-solve`; `schemas.MateEntityRefResponse`; `native_format._mate_entity_ref_to/from_dict`
    (written only when set, so mate-less-of-midplane files are byte-identical).
  - not touched, no change needed: `constraint_model.export_constraint_model` (reads resolved geometry only), `_applicable_mates`/
    `_live_mates`/`discover_component` (read `occurrence_id` only), `delete_occurrence` (reads `occurrence_id`; `b_occurrence_id` is under the
    same top-level one by validation), `subshape_identity` (documents that mate refs are out of its scope), `measure`/`mesh_data`.
  - **not yet handled (later phases):** `ai_plan._mate_entity_ref_from_step` and `MateEntityRefStep` (W4: today an AI plan cannot carry a
    `midplane`; the "exactly one of" check there is still three-way); Dart `MateEntityRefDto` (W2) and `mates_tool.gd` / `mate_health.gd` (W3).
    A Width mate in a file opened by an older Flutter/VR client shows its mid-plane reference as an empty one.
  - There is **no backend mate-health endpoint** today; drift surfaces when a mate is next solved or previewed. A lost face is the existing
    422 `missing_reference`, faces that stopped being parallel are 422 `faces_not_parallel` (distinct types, tested). The named "faces no
    longer parallel" *state* in the UI is a client job (W2/W3) reading that error.
- **Environment note:** `tools/motion_vectors/generate.py --check` passes on the plain system python (numpy there) and **fails in the
  backend micromamba env on unmodified `main` too** (float rounding of that numpy); it is clean before and after this change under the
  system python, and no vector or constant changed.
- **Measurement** (`backend/tests/bench_width_mate.py`, 60 trials per start class, ground truth = the fixture's true plate pose, nothing named):

  | start | scenario | picks / typed | first-time-correct | extra clicks per trial | centred after | backend ms per trial |
  |---|---|---|---|---|---|---|
  | near | 2 distance mates | 4 / 2 | 71.7% | 0.57 | 100% | 288 |
  | near | 1 Width mate | 4 / 0 | 100% | 0.00 | 100% | 163 |
  | medium | 2 distance mates | 4 / 2 | 64.2% | 0.72 | 100% | 279 |
  | medium | 1 Width mate | 4 / 0 | 100% | 0.00 | 100% | 168 |
  | far | 2 distance mates | 4 / 2 | 56.7% | 1.23 | 100% | 317 |
  | far | 1 Width mate | 4 / 0 | 100% | 0.00 | 100% | 176 |

  Read plainly: Width is right first time because its only branch (plate right way up or flipped) is invisible on a symmetric plate and
  the centring has no inset/overhang root; the two distances each have an inset/overhang choice. Width needs the same *number* of picks
  (4) but no typed value, and fewer clicks. Caveats: "time" here is backend solve time, not human time; Width does not set the gap
  size and leaves the in-plane position free (needs the usual other mates); the Width pick UX (a four-pick flow) is untested with a human
  until W2/W3. "Centred after" is 100% for both because the benchmark confirms the correct alternative after a wrong preview.

## W2 implementation notes (Flutter)

- **Built:** `width_pick.dart` (`WidthPick`, the panel-owned four-pick state; `kWidthMateType`; `isWidthMate`), `MidplaneRefDto` +
  `MateEntityRefDto.midplane`, a "Width" entry in the new-mate type list, a panel with "N of 4 - <step>", four labelled slots (gap
  pair / tab pair in two colours), Back, an optional "Offset from centre" field, and "Width N" in the assembly tree. The two-pick
  behaviour of the other types is unchanged (`_toggleSelectedEntity` only branches to `WidthPick` when the type is Width).
- **Wire:** centred = `coincident`, offset = `distance` (+ the usual branch controls: Orientation, Flip side, Next solution). The gap is
  reference 1, the part to centre reference 2, so the solve drives the tab, as with other mates.
- **Picking rules** (refused with a reason in the panel): faces only; the second face of a pair under the same top-level part; the tab
  pair under a different part from the gap; a toggled-off pick removes the picks after it. The parallel check runs the moment a pair is
  complete, via the existing Measure endpoint (`facesParallel`), and `faces_not_parallel` from the backend still surfaces on Confirm.
- **Not built, said plainly:**
  - the four faces are highlighted with the viewport's existing single selection colour while picking; the *two colours* (gap / tab)
    appear in the panel list only. A second 3D colour needs a new highlight set in `part_viewport.dart` (6000+ lines of rendering that
    I cannot see here);
  - **edit does not re-pick faces.** `PATCH /mates/{id}` deliberately never changes references (a mate's references are a new mate), so
    editing a Width mate edits its offset and branch (labelled "Offset from centre"), exactly like any mate; re-picking a pair means
    delete + new Width mate. Showing the four stored faces in the edit dialog is not done;
  - no mid-plane marker is drawn (the default of §4a), so there is nothing to clean up on confirm or cancel.
- **Checked:** `flutter test` (2740 passed, 33 skipped, includes `test/width_mate_test.dart`), `flutter analyze` (only the 182
  pre-existing `deprecated_member_use` infos plus one in the new test, the same as every other test file). **Not tried:** the flow in a
  running app with a human; the widget tests cover the state machine, wire shape and panel, not `PartScreen` end to end.

## Multi-part Width (2, 3 or 4 parts) - what changed, and the one thing it gave up

This did touch the group model (the user chose it knowing so). Still true: a Width mate has exactly two references and the
plane-plane residuals are the ordinary ones.

- **Model:** `MidplaneRef.b_occurrence_id` may now name any occurrence (any top level). `assembly.mate_ref_tops` / `mate_tops` give the
  top-level occurrences a reference / mate involves; discovery, orientation, branch search, `_mate_solve_target`, occurrence deletion
  and the "different occurrences" check use them instead of `references[i].occurrence_id` alone.
- **Group model:** `_Side.partner`. A cross-part Width side is its first face's plane with the second face as `partner`; its world plane
  is recomputed at every evaluated pose (average of the two origins, the first's normal) and the mate also holds the two faces
  parallel (3 extra residual rows, the cross product of the unit normals). If neither part is a member of the solved component (e.g.
  both bars fixed) the mid-plane never moves and collapses to ONE fixed world plane.
- **Constraint model, honestly:** with the collapse (fixed bars) the exported model is still a plain plane-plane one (`member: -1`
  plane), no version bump. When a part of a cross-part side moves (free bars, or a tab of two moving parts) the mid-plane depends on
  two poses, which the clients' retraction cannot evaluate: `export_constraint_model` returns `None` for that component and the
  clients keep projecting (the existing fallback). So **live drag of such a component has no local retraction** (looser than for
  other mates); the backend solve, create, preview, alternatives and mate-motion are exact. A constraint model v4 with a two-pose plane
  (Dart + GDScript + vectors) would fix that - not done.
- **Strictness:** at creation the two faces of a pair must be parallel at the stored poses (422 `faces_not_parallel`), as before; after
  that the residual keeps them parallel. The legacy single-occurrence solve (`POST .../solve`) handles a cross-part reference only on the fixed side.
- **Tests:** `backend/tests/test_width_mate_parts.py` (3 parts fixed/free bars, offset, 4 parts near/medium/far, preview, drag,
  export/import, delete cascade, non-parallel, missing occurrence). Backend `not gears`: 2484 passed. Flutter: pick rules for 2/3/4 parts.
- **Not measured:** the earlier benchmark (frame as ONE sub-assembly) is unchanged; there is no human-time measurement for 3/4 parts.

## W3 implementation notes (VR, DIDSA-VR branch `claude/width-mate-w1-w4`)

- **Built:** `Width` mate type in `mates_tool.gd` (`WIDTH_TYPE`, `pick_target()` 4, `width_references`, `width_wire_type`, Undo pick, a pair is checked for
  parallelism the moment it is complete via the backend's Measure `faces_parallel`, the part(s) to centre are driven first); the tablet's type row,
  an "Undo pick" button, the existing Set value button doubling as "Offset from centre" for Width; mates listed as "Width"; the pairs highlight in
  two colours (`face_highlight.gd` `colour_slot`: the gap cyan, the part to centre orange - VR has the two-colour highlight the flat app lacks);
  `mate_health.gd` follows the faces of a mid-plane reference (capture, drift, remake in place) and reports "faces no longer parallel" as its own
  list (`unparallel_pairs`), shown in the design table's status. Either pair may be two parts (2, 3 or 4 parts), same rules as the flat app.
- **Not built / not verified:** the wheel has the Width entry in its type ring only (no four-pick flow, Undo pick or offset on the wheel - tablet first,
  as planned); no live ghost beyond the usual preview; **no headset run, no live-backend e2e for Width**; the render and e2e suites were not run here.
  The live drag of a component whose Width mate has moving parts on a side gets no constraint model from the backend and keeps projecting (no local
  retraction) - `local_retraction.gd` already treats "no model" that way, and nothing in the GDScript solver changed.
- **Tests:** `tests/width_mate.gd` (38 SMOKE lines), `tests/tool_wheel.gd` updated for the sixth type entry; `tests/ci.sh` green (see the PR).

## W4 implementation notes (AI plan, docs, measurement)

- **AI plan:** `MateEntityRefStep.midplane` (`MidplaneRefStep`: `a`, `b` plane refs, optional `b_occurrence_id` in the plan's own `""` / `existing:<id>` /
  local_id forms). The validator's "exactly one of" is now four-way, a midplane reference is refused for any mate type but coincident / distance /
  parallel, the "different occurrences" check compares the sets of top-level occurrences each reference involves, and a missing `b_occurrence_id` is a
  step error. Dart: `AiMidplaneRef`, the translator maps it (resolving `b_occurrence_id` like any occurrence id) and creates a Width mate **atomically
  with the group solve** (`solve=auto`) instead of the single-occurrence solve that cannot move a part whose mid-plane depends on another part. The
  scoping prompt (`assemblyVocabularyText`) describes Width to the model, including that it still needs another mate for the position along the gap.
- **Found and fixed while measuring 4 parts:** with Minimal movement ("auto") a 4-part tab turned away from the gap returned a misleading 422
  (`midplane_faces_on_different_occurrences`) because the group solve's py-slvs fallback ran on a model it cannot express. That fallback is now skipped for
  Width sides that depend on a second part; "auto" then falls back to the group solve, "minimal" alone reports an ordinary non-convergence
  (`test_four_parts_turned_away_still_centre_...`).
- **Measurement, all of it** (`backend/tests/bench_width_mate.py`; backend solve time, not human time; 60 trials per start class):
  - the tester's table top (frame = one sub-assembly), nothing named: first-time-correct **two distance mates 71.7 / 64.2 / 56.7 %** (near / medium / far) vs
    **one Width mate 100 %**; extra clicks per trial 0.57 / 0.72 / 1.23 vs 0; both end 100 % centred once the user confirms the right alternative;
    backend 280-320 ms vs 160-180 ms per scenario. Both need 4 picks; Width needs no typed value. Width is not better at everything: it leaves the
    in-plane position free (the other mates still have to say it), it does not set a gap size, and its only branch (right way up or flipped) is invisible
    on a symmetric plate, which is *why* it is right first time - a part with a visible orientation would have the same Orientation choice as any coincident mate;
  - synthetic loose parts, one unnamed Width mate, start turned up to 170 degrees and moved up to 110 mm: **3 parts with fixed bars, 3 parts with free bars,
    4 parts with fixed bars: 100 % centred in every start class** (9-14 ms for 3 parts; 40-57 ms for 4 parts from the medium and far starts, which need
    the group solve). Precondition, by design: the two faces of a pair must already be parallel when the mate is made (else 422 `faces_not_parallel`), so
    the two parts of a pair are turned together in this benchmark;
  - **not measured:** any human time or first-time-correct with a person picking four faces (the four-pick UX is untested with a tester, §10); the
    4-part case with free bars; a headset.
- **Checked:** backend `not gears` 2490 passed, `flutter test` 2742 passed (33 skipped), `flutter analyze` only the existing deprecation infos, `generate.py --check` clean
  under the system python (it also fails in the backend micromamba env on unmodified `main`). Not run: the gears / bevel_pair suites.
- W5 (Symmetric) is untouched.

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
- **Added after W2 (user decision): Width works over 2, 3 or 4 parts.** Either pair may be made of two parts: the gap of two loose bars
  (3 parts) and/or a tab made of two parts (4 parts). The part(s) of the tab must differ from the part(s) of the gap. See
  "Multi-part Width" below. Not in W1–W4: Symmetric (W5).

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
  picked faces in two colours during the pick. **No mid-plane is drawn in the scene** (see §4a). `preview-mate-solve` returns no
  mid-plane geometry; add an optional `midplanes` list (origin, normal, size hint) only if the panel-only marker below is built.

### 4a. No clutter, no orphans (binding rule for every phase)

A Width mate never creates or persists a plane, feature, sketch or any other object. The mid-plane is computed on the fly, on every
solve, from the two stored face references and thrown away; the mate stores nothing but those references.

- **Delete / undo / redo.** Deleting a Width mate removes everything it made, because it made nothing else. Occurrence deletion
  removes the mates that reference it by the existing path. A Plane the user made themselves and referenced via `plane_feature_id`
  is not owned by the mate and survives deleting it.
- **Display.** Nothing is drawn in the viewport, the VR scene, the feature tree or any plane list by default. During the pick the
  four chosen faces are highlighted (two colours, one per pair). While previewing, only the moved part's ghost shows. An optional
  mid-plane marker (one fine outline) may exist only while the mate panel is open, disappears on confirm or cancel, is never saved,
  and is off unless a tester asks for it.
- **Part edits.** A lost face or non-parallel faces put the mate in a named broken state; they never create or leave a plane behind.
- **Tests (§8):** create then delete a Width mate and assert the document's parts, features, planes, sketches and occurrences are
  identical to before; export/import a document with a Width mate and find no extra objects; deleting the mate does not remove a
  user-made Plane it referenced.

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
- No-orphans: the §4a tests above (create/delete leaves the document identical; export/import adds no objects; a referenced user Plane survives).
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
