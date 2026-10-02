# F1a - Client-side nearest-point retraction: design and prototype evaluation

Status: **design + numpy prototype only. No production code changed.** Prototype:
`docs/constrained-drag-investigation/prototypes/g_local_retraction.py` (run from `backend/`:
`python ../docs/constrained-drag-investigation/prototypes/g_local_retraction.py [check|scenes|random|warm|cost|reconcile]`).
Decision requested from the owner: go / no-go for **F1b** (section 9).

## 1. Question

The projector (spec s4-5) moves the displayed pose along the *linearised* free motion; the real mate manifold is curved, so between
anchors (150 ms) the displayed pose drifts off the mates (up to 21 weighted mm on the hinge, 0.6 on the bolt at 120 deg) and each anchor
makes it "pop" back. The backend retraction that produces the anchor is also not the nearest point (spec s13.2). F1 asked: can the
**client** solve the mates itself every frame - an exact, nearest-point retraction - so the display is on the manifold at all times
and anchors only correct for drift/rank changes?

## 2. What was prototyped (RAN)

Everything below was **run**, in numpy, against scenes built with the real backend model (`backend/tests/motion_scenes.py`) and
snapped to the manifold by the real `solve_group`. The Dart/GDScript costs in section 7 are **estimated from flop counts, not measured**.

* **Constraint model** (`export_model`): what the backend would ship per anchor - members (id, pose, fixed), and per mate: type,
  value, `allow_rotation`, and for each side the member index (or a frozen rigid pose for a fixed/outside part) plus the local
  geometry (point, plane origin+normal, axis origin+direction, perpendicular). Types covered: coincident (point/plane/axis), concentric,
  parallel, angle, distance (the five in `_mate_residual_vector`). Sign-agnostic residuals, exactly as the backend.
* **Residual and Jacobian** (`Model.residual`): analytic forward-mode (value + 6 tangent columns per member, left-multiplied twist
  `[v, w]`, same chart as spec s2). No finite differences.
* **Local retraction** (`sqp_nearest`): sequential nearest-point step. With `W` the metric (grabbed 1, followers `LOCAL_FOLLOWER`),
  `A = J W^-1`, `y0 = W (x_wish - x)` (wish = hand for the grabbed part, previous poses for followers, so followers move minimally and
  continuously): `y = y0 - A^T (A A^T + lam I)^-1 (A y0 + r)`, `dx = W^-1 y`, apply with a trust region
  (`TRUST` 6.0 weighted mm of wished displacement per iteration, rotation per iteration capped at `ROT_CAP` 0.6 rad), absolute damping
  `LAM_ABS` 1e-9; fixed `ITERS` = 3 iterations + `POLISH` = 1 pure-Newton step onto the mates (min-norm). Fixed iteration count => bounded
  latency, deterministic, golden-vector testable.
* Compared per frame with: (a) the current projector + blender + anchors (every 9 frames, real backend solves), (b) the true weighted
  nearest point (60-iteration reference).

## 3. Results

### 3.1 Path replay (90 frames, anchors every 9, 3 iterations/frame, warm start from the previous displayed pose)

Metric legend: `jerkG`/`jerkF` = max per-frame change of the grabbed/follower pose beyond the hand's own step (weighted mm);
`resid_max` = worst mate residual of any displayed frame; `cost-excess` = distance to the wish above the true nearest point.

| scene / variant | path | jerkF current > local | resid_max current > local | cost-excess current > local |
|---|---|---|---|---|
| bolt floating | rot_xy_60 | 1.575 > 0.778 | 6.3e-1 > 1.4e-12 | 0.000 > 0.016 |
| bolt floating | circle_xy_25 | 2.588 > 0.333 | 5.9 > 8e-13 | -0.000 > 0.000 |
| hinge floating | rot_xy_60 | 13.383 > 1.111 | 21.0 > 6e-11 | 0.000 > 0.164 |
| hinge floating | rot_y_120 | 3.671 > 0.046 | 1.5 > 6e-13 | 0 > 0 |
| hinge fixed | rot_z_120 | jerkG 1.482 > 0.005 | 7.2e-2 > 2.9e-13 | 5.703 > 0.000 |
| hinge fixed | circle_xy_25 | jerkG 2.800 > 0.230 | 2.9e-1 > 5e-12 | 3.589 > 0.009 |
| hinge fixed | rot_xy_60 | jerkG 21.964 > 0.000 | 15 > 2e-14 | 28.546 > 0.000 |
| swing | rot_z_120 | jerkG 0.793 > 0.009 | 3.1e-2 > 1.3e-13 | 1.893 > 0.000 |
| swing | swing_z_90 | jerkG 0.212 > 0.006 | 4.1e-3 > 8e-13 | 0.316 > 0.000 |
| bolt fixed / angle / bcd | most paths | equal (already exact or flat) | 1e-8 > 1e-13 | 0 > 0 |

Reading: on every scene with a curved mate (offset hinge, swing, floating followers) the local retraction **holds the mates to
1e-11 or better on every frame** (the current display is off by up to 21), the "pop" disappears on the grabbed part
(jerkG 0.8-22 > <0.25) and on followers (jerkF 0.16-13 > 0.03-1.1), and the displayed pose is *at or near the true nearest point*
(excess <= 0.16 weighted mm; the projector's excess reaches 28.5). Flat/free scenes are unchanged (they were already exact).
The residual gap `0.000 > 0.016/0.164` on the 60 deg flick paths is the cost of 3 iterations on a far wish: still on the manifold,
slightly farther from the wish than the true nearest.

### 3.2 Robustness: one frame, from a pose ON the manifold, wish `s` away (random direction, 60 draws each)

Cell = frames converging to residual < 1e-6 after 3 iterations + 1 polish (cost vs 40-iteration reference, median).

| scene | 3 mm / 0.05 rad | 20 mm / 0.3 rad | 60 mm / 1 rad |
|---|---|---|---|
| bolt fixed | 60/60 (1.000) | 60/60 (1.000) | 60/60 (1.001) |
| hinge fixed | 60/60 (1.000) | 52/60 (1.004) | 41/60 (1.017) |
| swing | 60/60 (1.000) | 51/60 (1.008) | 33/60 (1.114) |
| angle cone | 60/60 (1.000) | 57/60 (1.001) | 42/60 (11.8) |
| hinge floating | 60/60 (1.967) | **17/60** (434) | **10/60** (147) |
| bcd (3-part chain) | 60/60 (1.000) | 60/60 (1.017) | 60/60 (1.379) |

A real hand moves 0.2-3 mm / <0.05 rad per frame, i.e. the first column: **100 % convergence on all six scenes**. The 20-60 mm
columns are 10-300 frames of motion in one step (an unrealistic hitch) and show where a **guard** is mandatory. Cold start from the
projector output at large random wishes (up to 2 rad / 120 mm): converged 60/46/37/48/26 of 60 after 3 its (bolt fixed / hinge fixed /
swing / angle / hinge floating) - the floating hinge needs the fallback below.

### 3.3 Backend vs local agreement (`reference` = the client's poses)

When the backend is warm-started at the client's displayed pose (the S7 `reference` contract) its retraction lands *beside* the
local one on curved fixed mates: grabbed part up to 29 weighted mm away (hinge fixed, rot_z_120), followers up to 181 (circle path);
backend cost minus local cost up to +14.5 (the backend answer is farther from the wish). On floating scenes they agree to 0.001-0.003.
So with the local solver authoritative on the display, the **anchor must be upgraded to the same nearest-point retraction**, or the
anchor correction would drag the display *away from* the nearest point (the very pop F1 wanted to remove).

### 3.4 Cost (flop counts exact for the prototype's algorithm; time = numpy, indicative only)

| scene | k members | rows x cols | per iteration | numpy |
|---|---|---|---|---|
| bolt floating | 2 | 10 x 12 | ~2.7 kflop | 0.58 ms |
| hinge floating | 3 | 16 x 18 | ~8.0 kflop | 0.79 ms |
| hinge fixed | 2 | 16 x 12 | ~6.3 kflop | 0.69 ms |
| bcd | 3 | 20 x 18 | ~13.0 kflop | 1.09 ms |

Per frame = (3 + 1) iterations => 11-52 kflop. In Dart (JIT/AOT, scalar doubles on a `Float64List`) that is **estimated** at 0.05-0.3 ms; in
GDScript (VR) 20-100x slower => 3-15 ms, only acceptable for k <= 3 and ~2 rows/mate; not measured. Cost grows ~ rows^3 for the
`A A^T` solve; k = 6+ groups should fall back to the projector (section 6).

## 4. Where it should live - decision

| option | verdict |
|---|---|
| **Client only** | No: the backend is the authority on *which* constraint structure exists (suppression, redundancy, rank/DOF, singular seeds) and must still validate the commit; the client cannot detect angle-aligned or flipped-coincident singular seeds. |
| **Backend only** (upgrade its retraction, keep the projector) | Helps anchors (removes the 1-14 mm backend-vs-nearest gap) but not the 150 ms drift between anchors, which is the felt roughness. |
| **Both (recommended)** | Backend ships a constraint model + a nearest-point-retracted anchor and stays authoritative (commit, DOF, basis for cues/gizmo S8). Client runs the local retraction per frame, falling back to the projector when its guard trips. The projector (s4-5) stays: it is the predictor, the fallback, and the only thing the VR GDScript port must keep for k > 3. |

## 5. Wire format (proposed addition to the `mate-motion` response, optional, absent => client uses the projector as today)

```json
"constraint_model": {
  "version": 1,
  "members": [ {"occurrence_id": "occ_a", "fixed": false}, {"occurrence_id": "occ_b", "fixed": false} ],
  "mates": [
    {"id": "m1", "type": "concentric", "value": 0.0, "allow_rotation": true,
     "a": {"member": 0, "axis_origin": [0,0,0], "direction": [0,0,1]},
     "b": {"member": null, "frozen": {"r": [[1,0,0],[0,1,0],[0,0,1]], "t": [10,0,0]},
           "axis_origin": [0,0,0], "direction": [0,0,1]}},
    {"id": "m2", "type": "coincident", "subtype": "plane", "value": 0.0,
     "a": {"member": 0, "plane_origin": [0,0,12], "normal": [0,0,1]},
     "b": {"member": null, "frozen": {"r": [[1,0,0],[0,1,0],[0,0,1]], "t": [10,0,0]},
           "plane_origin": [0,0,0], "normal": [0,0,1]}}
  ]
}
```
Geometry is in each occurrence's local frame (the same frame the backend uses in `_mate_residual_vector`); poses use the existing
member `transform` field. Size: ~150-250 bytes per mate. Only mates whose members include a group member are shipped; mates to
outside parts carry the frozen pose. Backend work: `export_model(GroupModel)` (prototype already does this; ~40 lines).

## 6. Per-frame algorithm and guards ("never worse than the projector")

1. Predict: projector output `p` (unchanged spec s4-5), wish = hand pose.
2. If a `constraint_model` is present and `k <= K_MAX` (Dart 8, GDScript 3) and rows <= 32: run `sqp_nearest` from the previous
   *displayed* pose (warm) with the constants of section 8; followers' wish = their previous displayed poses.
3. Accept the local result only if `max|residual| <= 1e-6` after the polish **and** its weighted distance to the wish is not more than
   `1 + 1e-3` x the projector's distance to the wish + `L*1e-3` (no worse than the projector's own answer on the wish metric); else
   keep the projector output `p` (current behaviour) and count `local_fallback`.
4. Blender, anchor acceptance, rank hysteresis, hold on `converged:false`: unchanged. The anchor is now only a *correction*
   (drift = 0 on a healthy model); acceptance `jump > L` keeps rejecting wild answers.
5. A model whose `version` is unknown or whose mate type is unsupported => ignore it (projector).
6. Singular seeds (angle aligned, flipped coincident, rank change) still come from the backend anchor; the local solver never
   tries to cross a rank change - on `rank_changed` it re-anchors immediately and holds the projector until the new model arrives.

## 7. Risks

* **Large hitches** (section 3.2, last two columns) - mitigated by the guard + trust region; costs a count, never a worse frame.
* **Floating hinge under big jumps** converges 10-17 of 60 in one frame: the guard falls back to the projector; the backend
  anchor re-seats it. Hitches > 20 mm/frame are not realistic for a pointer/touch, but a lost-frame stall can produce them.
* **Follower weight is not the contract's 1e-4** in the local solve (1e-2): the metric of the *projection* (spec s2) is unchanged,
  but the local solve is a second metric; the documented consequence is that the grabbed part sits <0.01 % off the nearest point.
* **Two solvers can disagree** (section 3.3) unless the backend retraction is upgraded as well - this is part of F1b, not optional.
* **Cost in GDScript** (VR): see section 3.4; k <= 3 only, behind a benchmark in F1b before enabling.
* **Wire/maintenance surface**: a second implementation of the five residuals + Jacobians in Dart (and GDScript) that must match
  the backend's `_mate_residual_vector`; mitigated by golden vectors computed from the backend itself.
* Not yet exercised: sketch-based mates other than the five types, patterns, mates to suppressed parts mid-drag, > 3 mates on one
  occurrence pair, scenes with k > 3.

## 8. Proposed spec text (new s4b "Local retraction", constants appended to s14)

> **4b. Local retraction (optional).** If the anchor carries `constraint_model`, after s4-5 the client MAY refine the displayed
> poses `x` with `ITERS` sequential nearest-point steps, `x <- x + trust(W^-1 y)`, `y = y0 - A^T (A A^T + LAM_ABS I)^-1 (A y0 + r)`,
> `y0 = W (x_wish - x)`, `A = J W^-1`, `W = diag(1 on the grabbed member, LOCAL_FOLLOWER on the others)`, `r` the stacked mate
> residuals (s4b.1) and `J` their analytic twist Jacobian; the per-iteration step is scaled to `TRUST` weighted mm and `ROT_CAP`
> rad; then `POLISH` min-norm Newton steps `y = -A^T (A A^T + LAM_ABS I)^-1 r`. The result replaces the projection only if the
> acceptance rule of s6 of this section holds, else the projection is used. Constants: `ITERS 3`, `POLISH 1`, `TRUST 6.0`,
> `ROT_CAP 0.6`, `LAM_ABS 1e-9`, `LOCAL_FOLLOWER 1e-2`, `accept_residual 1e-6`, `accept_cost_slack 1.001`.

## 9. Candidate golden vectors (new kind `local_retract`; input = model + poses + wish + constants, expected = poses after one frame, tol 1e-9)

Generated by the backend-side reference (`sqp_nearest` ported into `tools/motion_vectors/generate.py`, numpy only):
1. bolt fixed, wish on the manifold (slide) - exact reproduction
2. bolt fixed, off-axis wish (pull-off) - nearest on the axis
3. bolt floating, rot_x 3 deg step - both members move, mates exact
4. hinge fixed, trans_x 3 mm (curved mate) - grabbed lands within 1e-9 of 40-iteration reference after 3+1
5. hinge fixed, rot_z 20 deg wish - guard test (residual after 3+1 recorded; expect fallback flag)
6. swing, swing_z 5 deg - the s13.2 case; expected nearest cost
7. angle cone, tilt 3 deg
8. bcd chain, trans_x 3 mm, followers carried continuously
9. hinge floating, large wish - expects `accepted:false`
10. rank-0 (fully fixed) - result = input
11. unsupported mate type - `accepted:false`, projector used
12. unknown `version` - ignored

## 10. Go / no-go

**Recommendation: GO for F1b**, in this order, each independently shippable:

1. **Backend**: replace the min-norm Gauss-Newton retraction by the same weighted nearest-point SQP (removes the 1-14 mm anchor
   bias, spec s13.2) and emit `constraint_model` (optional field, `version: 1`). Re-run the backend group tests and the smoothness study.
2. **Spec + vectors**: s4b, constants, `local_retract` vectors (section 9), regenerate with `generate.py` (a deliberate vector change).
3. **Flutter client (Dart)**: `local_retraction.dart` + wiring in `constrained_drag_session.dart` behind a flag, counters
   `local_accepted/local_fallback`, run the vectors, the live and smoothness tests.
4. **VR (GDScript)**: only after a measured benchmark on the headset for k <= 3; otherwise keep the projector.

Numbers behind the call: residual 1e-11 vs up to 21 on every frame; follower jerk 0.16-13 -> 0.03-1.1; grabbed jerk up to 22 -> 0 on
curved fixed mates; 100 % one-frame convergence at realistic hand steps on all six scenes; at most ~50 kflop/frame.
Known unknowns that make "no-go" cases: if the owner would rather not maintain a second constraint implementation, **no-go is
reasonable** - the current projector + blender is acceptable for flat/pin/free mates, and the pop is on curved mates only.

What was RAN: all numpy prototype sections (check, scenes, random, warm, reconcile, cost) against real-backend-built scenes.
What was only READ/ESTIMATED: Dart and GDScript speed, VR behaviour, GUI feel, scenes beyond the six, any production code.
