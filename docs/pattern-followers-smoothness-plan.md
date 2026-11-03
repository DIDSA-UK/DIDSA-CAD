# Pattern followers: smooth dragging and the remaining gaps — investigation & plan

Status: **investigated, not implemented** (hand-off for one session working in `DIDSA-UK/DIDSA-CAD` and
`DIDSA-UK/didsa-vr`). Follows `docs/pattern-followers-and-dissolve-plan.md` (implemented, §2aa) after a review of that
rollout on 2026-11-03.

## Review of the rollout (for the record)

Both branches `ccr-c5027d07-sd8k7a` checked: CAD fa44b7e (6 commits), VR 2a15125 (5 commits). Backend 3,256 passed
client 3,434 passed / 43 skipped, VR `tests/ci.sh` 3,689 SMOKE lines / 0 failures. The follower maths in
`assembly_group.py` (copy pose = pattern step ∘ source pose; seed rotations mapped back by the inverse step rotation),
the pattern-edit re-solve, and VR V1/V2 match the plan. The 4 "broken" mates the session saw on the frame fixture come
from the fixture itself (its `CORNER_GUSSET_001.DIDSAprt` is a different gusset file from the one the assembly was
saved with), not from the code.

## What is still not smooth or not right

| # | Problem | Where | Size |
|---|---------|-------|------|
| S1 | Dragging a group that holds a copy mate is slower and less smooth: no constraint model is sent, so the server Jacobian is by central differences and neither client can solve locally between server answers | backend + Flutter + VR | M |
| S2 | Flutter: a dragged source's **copies stay put during the drag**; a part following a copy visibly drifts away from it, then everything snaps on release | Flutter | S |
| S3 | VR: the same during a live drag (copies only catch up on commit) | VR | S |
| S4 | VR: after a solve **inside a sub-assembly**, copies loaded under another GLB root are not refreshed | VR | S |
| S5 | AI plan `move_component` only PATCHes the pose and never solves (any mate, not only copy mates; pre-existing) | Flutter | S |

Recommended order: **S1** (the real smoothness win), **S2**, **S3**, **S4**, **S5**.

---

## S1. Constraint model version 7: follower sides

### Measured

`POST .../occurrences/src/mate-motion`, a source with 3 coincident mates to a second part, 15 drag steps, backend
in-process (`TestClient`), this container:

| Mates on | median | max | `constraint_model` sent |
|---|---|---|---|
| the source directly | 13.0 ms | 148 ms (first, cold) | yes |
| a copy of the source | 44.2 ms | 56 ms | **no** |

The 3.4× server cost is the central-difference Jacobian (`GroupModel.jacobian` falls back when
`export_constraint_model` returns `None`). Worse for feel: with no model, Flutter's `ConstrainedDragSession` and VR fall
back from the per-frame local retraction (`client/lib/motion/local_retraction.dart`, "solved onto the mate manifold
locally") to the projector alone between server anchors, so followers drift off their mates between anchors and snap
at each one — the jerk the local retraction was added to remove (`tools/motion_smoothness/`).

### Design

A follower side's world pose is a constant transform `S = (Rs, ts)` applied after the member pose `(R, t)`:

- `orient_with_rotation = true` (Linear, and Circular by default): `R' = Rs R`, `t' = Rs t + ts`
- `orient_with_rotation = false` (Circular only): `R' = R`, `t' = Rs t + ts`

In `ConstraintModel._world` (`backend/app/document/constraint_model.py` ~306) a local point `l` gives
`w = R l`; today `point = w + t`, `d/dv = I`, `d/dω = -[w]×`, and a direction is `w` with `d/dω = -[w]×`. With a follower:

- orient: point `Rs (w + t) + ts`, `d/dv = Rs`, `d/dω = -Rs [w]×`; direction `Rs w`, `d/dω = -Rs [w]×`;
- keep rotation: point `w + Rs t + ts`, `d/dv = Rs`, `d/dω = -[w]×`; direction `w`, `d/dω = -[w]×`.

Wire format (only emitted when a side has a follower; otherwise versions 3-6 unchanged):

- `MODEL_VERSION_FOLLOW = 7`: a superset of 6 (limits, couplers, pairs allowed alongside). A side (and a `pair`) may carry
  `follow: {"r": Rs, "t": ts, "keep_rotation": bool}`. The `Rs, ts` are `pattern_copy_pose(pattern, identity, index)`
  (for keep-rotation, the translation part of the step and its rotation applied to `t` only — derive both from one helper
  `pattern_step(pattern, index) -> (Rs, ts, keep_rotation)` in `assembly.py`, used by `pattern_copy_pose` too).
- `export_constraint_model` stops returning `None` for followers and emits the field. Coupler/limit mates never have
  followers (still refused on copies), so no anchor/`_motion` changes.

### Three evaluators, one golden set

1. **Backend** `constraint_model.py`: `export_constraint_model` + `_world` as above; `MODEL_VERSION_FOLLOW`.
2. **Golden vectors**: `tools/motion_vectors/generate.py` (numpy reference) gains `local_retract` cases with a follower
   side (Linear, Circular orient, Circular keep-rotation; one with a limit mate in the same model); regenerate
   `docs/motion/vectors.json` and the backend copy `backend/tests/data/local_retract_vectors.json`.
3. **Flutter** `client/lib/motion/local_retraction.dart`: `tryParse` accepts 7; the side world evaluation applies
   `follow`. Must reproduce the new golden vectors to 1e-9 like the existing ones.
4. **VR** `didsa-vr/scripts/motion/local_retraction.gd` (mirrors the Dart "line for line"): same change. VR only reads
   the model for limit mates today (`mates_tool.gd` `_adopt_limit_model`), but `try_parse` rejects unknown versions,
   so **without this a version-7 model would also switch off VR's limit stops** for any group that holds a copy mate.
   VR's golden-vector test must cover version 7 too.

### Tests

- Backend: `export_constraint_model` emits version 7 with `follow` for a follower model; the analytic Jacobian matches
  central differences on follower models (all three pattern kinds) to the existing tolerance; the
  `test_mate_pattern_copy.py` assertion "no constraint model for a follower" flips on purpose (say so); the golden-vector
  test passes with the new cases.
- Re-run the benchmark above: target the copy-mate median within ~1.5× of the direct-mate median, with the model sent.
  Keep the benchmark as `backend/tests/bench_pattern_follower_drag.py` (named `bench_` so pytest's default discovery
  does not run it, like `tests/bench_width_mate.py`).
- Flutter / VR: golden vectors; a `tryParse` / `try_parse` test that version 7 is accepted and that VR keeps its limit
  model when the anchor holds a follower.

---

## S2. Flutter: copies move with their source during a drag

`PartScreen._displayAssemblyInstances` (`part_screen.dart` ~1019) overrides only exact occurrence paths
(`overrideInstanceTransform`, `assembly/occurrence_visibility.dart` ~194): the gizmo target and `_followerLiveWorld`.
Instances `src#pattern:P:i` (and anything nested under a copy) keep their fetched pose.

Fix: after those overrides, for every overridden occurrence `X` (the target and each follower) that is a source of a
non-suppressed pattern in `_componentPatterns` (the focused Part's list), override each live copy instance
`[...focusPath, "X#pattern:P:i", ...]` with `copyWorld = parentWorld ∘ patternCopyPose(P, localOf(X's live world), i)`.
Instances nested under a copy (`.../X#pattern:P:i/inner`) move by the same delta: compose
`newCopyWorld ∘ inverse(oldCopyWorld) ∘ oldInstanceWorld`.

- Add `patternCopyPose(ComponentPatternDto, RigidTransformDto source, int index)` to the client (next to
  `linearPatternPreviewStep`/`circularPatternPreviewStep`, which the Pattern panel preview uses but which skip
  `orient_with_rotation`/`skip_indices`), mirroring `assembly.pattern_copy_pose` exactly. Golden test: a small JSON of
  `(pattern, source pose, index) -> pose` generated from the backend (Linear 1-D and 2-D grid, reverse flags, Circular
  orient true/false, skip indices) checked on both sides (backend test writes nothing; the vectors are a committed
  fixture both tests read).
- Also use it in the Pattern panel's ghost preview so the preview honours `orient_with_rotation` (today it doesn't).
- Tests (`part_screen_test.dart`): with a live gizmo transform on a source, `PartViewport.assemblyInstances` shows the
  copy at `step ∘ newSource`, and a follower mated to the copy at its live pose; no change when the pattern is
  suppressed.

## S3. VR: copies move with their source during a drag

VR moves the dragged node and the followers locally per frame (`mates_tool.gd` drag path, `mate-motion` answers); copy
nodes only catch up in `_copy_pose_changes` after the commit. Fix: when a drag starts on a node whose occurrence is a
source of a pattern (VR already fetches `GET .../component-patterns` in `appearance_tool.gd`; fetch it once per root in
`mates_tool.gd` too and cache it with the occurrence state), find its copy nodes (`instance_path` with that source's
copy segment, same `group_root`), and each frame set `copy.transform = pattern_copy_pose(P, source_local, i)` (a GDScript
mirror of the backend function, checked against the same golden fixture as S2). Nested parts under a copy move by the
same delta. The commit-time `_copy_pose_changes` stays as the authority.

Tests: pure `pattern_copy_pose` SMOKE cases from the shared fixture; a headless drag-path test that moving a source node
moves its copy node by the pattern step.

## S4. VR: copies after a solve inside a sub-assembly

`_copy_pose_changes(owner_part_id)` only looks at copy nodes whose `group_root == owner_part_id`. A solve of a
sub-assembly's own mates (`owner_part_id` = the sub-assembly's Part) moves parts that the world's GLB shows under the
world root, so their copies are skipped (Enforce all covers it with its extra pass; a single solve does not). Fix: after
any solve, refresh copies for every loaded root whose scope contains the solved Part (the world root, plus an open
room of that Part): collect the distinct `group_root`s of copy nodes whose `group_parts` include `owner_part_id`, one
`geometry=false` request per root. Test: a nested solve fixture where the copy lives under the world root.

## S5. AI plan `move_component` solves afterwards

`client/lib/ai/ai_plan_translator.dart` (~915, `case AiMoveComponentStep()`): it only calls
`updateOccurrenceTransform`. After it, always call `solveForOccurrence(partId, id)` (group movement): for an unmated
occurrence the solve trivially converges and changes nothing, so the translator needs no mate bookkeeping of its own
(the backend already folds copy mates to their source). A non-convergence is reported as the step's failure through the
translator's existing error path. Tests in `ai_plan_translator_test.dart` with the fake backend: `move_component`
produces PATCH then `/solve`; a 422 from the solve fails the step with the backend's message.

---

## Verification

```
/opt/sdks/micromamba run -n didsa-backend python -m pytest backend/tests/ -q -n 4
cd client && flutter analyze && flutter test
# didsa-vr (Godot 4.7.2; tools/setup_test_env.sh installs it)
GODOT=/path/to/godot tests/ci.sh
GODOT=/path/to/godot tests/ci_e2e.sh        # with a local backend from the CAD branch (tools/start_backend.sh, CAD_DIR)
```

Say what headless tests can't show: drag feel needs a person, on the flat app and on the headset.
