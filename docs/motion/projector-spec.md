# Free-motion projector — spec (S4)

Normative for the two ports (GDScript in DIDSA-VR, Dart in `client/lib/motion/`). Both must reproduce
[`vectors.json`](vectors.json) to 1e-9. Contract of record: `docs/constrained-drag-implementation-plan.md` §3
(`POST …/occurrences/{grabbed}/mate-motion`). Evidence: `docs/constrained-drag-investigation.md` §E.3–E.6 and
`docs/constrained-drag-investigation/prototypes/{geo,a_screw,e_weighted_retraction}.py`. Where this spec differs from the
investigation text or the prototype it says so (§13).

The projector answers one question per frame, **locally and without a network call**: *the hand wants pose `W`; which pose
of the grabbed occurrence (and of the mated followers) should be drawn?* The backend answers the same question
exactly but takes ≥ 1 round trip, so it only *anchors* the projector (a fresh pose + free-motion basis) every ~150 ms.

## 1. Inputs from one anchor response

| Response field | Use |
|---|---|
| `members[i].transform` | reference pose `ref_i` (grabbed first; **this order is the column order of `basis`**) |
| `basis` (dof × 6k) | rows, raw twists `[vx vy vz wx wy wz]` per member (§2) |
| `chart.lever_arm` | `L`. **Always use the echoed value**, never a local one |
| `quality.{residual_inf, sigma_gap, max_step, jump}` | acceptance (§7), scheduling (§8) |
| `converged` | false ⇒ no model at all (§11) |

`dof`, `grounded`, `members[].mobility` are for UI (gizmo cues); the projector does not need them. The v0 aliases
(`transform`, `free_twists`) must not be read.

## 2. Conventions

* **Pose** = `(t, R)`; wire form `translation` + `rotation_axis` (normalise on read) + `rotation_angle_degrees`; `R` by Rodrigues.
  Vectors output poses as `translation` + row-major 3×3 `rotation`, and must be compared as matrices (axis/angle is ambiguous at π).
* **Chart `se3_owner_frame` (= the backend's `apply_delta`)**: a twist `d = [v, w]` per member; `v` is the *displacement of the
  occurrence origin* (added to `t`), `w` a rotation vector in radians composed on the *left*: `R' = exp(w)·R`, i.e. rotation about the
  occurrence origin in world axes.
  * `log(ref, P) = [t_P − t_ref, rotvec(R_P · R_refᵀ)]` (`pose_delta(P, ref)`);
  * `apply_delta(ref, d) = (t_ref + v, exp(w)·R_ref)`.
* **Metric.** For a stacked vector over `k` members the inner product is `⟨a,b⟩ = Σ (s_j a_j)(s_j b_j)` with per-member scale
  `s = [1,1,1,L,L,L]` for the grabbed member and `FOLLOWER_WEIGHT · [1,1,1,L,L,L]` for followers, `FOLLOWER_WEIGHT = 1e-4`
  (the backend's `_FOLLOWER_WEIGHT`; **it is part of the contract, not sent on the wire**). One radian costs as much as `L` mm.
  Rows of `basis` are orthonormal in the *equal-weight* metric (all members `[1,1,1,L,L,L]`, ε = 1), **not** in this projection
  metric, so the client must re-orthonormalise (§3).
* Only the grabbed member has a wish; followers' wish is `0` (they move only as the mates require).

## 3. Weighted Gram–Schmidt

Input: rows `r_1…r_n`, scale `s`. Output: rows `u_1…u_m` (m ≤ n), `⟨u_i,u_j⟩ = δ_ij`, spanning the same space.

```
for each row r:
    n0 = |s∘r|;  if n0 < 1e-12: skip
    v = r
    repeat twice:  for u in out:  v -= ⟨v,u⟩ u        # modified GS + one re-orthogonalisation pass
    n = |s∘v|;    if n < 1e-6 · n0: skip              # dependent (relative drop)
    out.append(v / n)
```

Row order = response order; results are invariant (up to rounding) to the choice of spanning rows, so a different SVD basis
does not change the projection. Do it once per accepted anchor, not per frame.

## 4. Projection (per frame, no network)

```
want            = zeros(6k);  want[0:6] = log(ref_0, W)          # grabbed block only
c_i             = ⟨u_i, want⟩
d               = Σ c_i u_i                                       # 6k twist, followers included
pose_m          = screw_exp(ref_m, d[6m : 6m+6])                  # every member, §5
```

This is the weighted least-squares fit of the wish onto the free subspace; blocked components (off-plane, tilt about a locked
axis) vanish, and followers ride along exactly as the mates demand (B/C/D: B +4 x ⇒ C +4 x; B +6 y ⇒ B, D +6, C 0).
If `m = 0` (rank-0 group: `dof = 0`) the result is `ref` — the part cannot move.

## 5. Screw exponential-map integration

Integrating `d` additively ("add `v`, compose `exp(w)`", the v0 `project_motion`) leaves the manifold for any freedom that is a
rotation about an axis not through the origin (measured on the off-axis pin swing: up to 0.03 mm off the axis with true-nearest anchors and 0.81 mm with the real backend anchors, vs. exactly 0 for the screw).
Integrate `(v, w)` as a constant spatial screw instead:

```
th = |w|;  K = skew(w)
E  = I + sin(th)/th · K + (1−cos(th))/th² · K²              # = exp(w) (series below th < 1e-4: 1 − th²/6, 1/2 − th²/24)
V  = I + a·K + b·K²,  a = (1−cos th)/th²,  b = (th − sin th)/th³      # series below th < 1e-4: a = 1/2 − th²/24, b = 1/6 − th²/120
R' = E · R
t' = E · t + V · (v − w × t)
```

(`v − w × t` is the twist's world-frame translational part.) Exact for group orbits (flat face slide + spin, hinge, concentric
about **any** axis), still second-order wrong on non-orbit manifolds (the `ANGLE` cone about anything but the world axis) — those
are covered by `max_step` and re-anchoring (§6, §8).

`rotvec(R)` must be `atan2(|a|, (tr R − 1)/2)` with `a = (R − Rᵀ)_axial / 2` (the prototype's `acos` loses ~1e-8 rad at small
angles and breaks the 1e-9 vectors), scaled by `θ/sin θ` (series `1 + θ²/6` below 1e-4), and near π (`π − θ < 1e-3`) take the
axis from the largest column of `(R + I)/2`, sign from `a`.

## 6. Lever arm and `quality.max_step`

**Lever arm `L`** = the grabbed occurrence's *bounding radius*: half the diagonal of its bounding box in the occurrence's own
frame (backend `bounding_radius`; Dart `_gizmoTargetBoundingRadius`; VR: mesh AABB). Clients send it as `lever_arm` on every
request and thereafter use `chart.lever_arm` from the response. It is one `L` for the whole group (followers use the grabbed
member's), and constant during a drag (re-sent, not recomputed). Not a constant 100 mm: sweep on the offset-axis concentric mate
gave L = 10 ≈ solver behaviour (1.7 mm/6.6°) vs. 6.9 mm/26° at L = 100 (investigation §E.4).

**`quality.max_step`** (weighted mm; backend, `assembly_group._jump`): how far the client's own screw prediction may travel before
it leaves the mate manifold by more than `TOL = 0.25` weighted mm. Definition: `d` = weighted length of the wish projected onto
the *stored* pose's basis; apply the screw prediction to every member; `e = ‖mate residual‖₂ / σ_min` (upper bound on the distance
from the manifold); the error grows like `d²`, so `max_step = d·√(TOL / e)`. `null` when there is nothing to guard:
wish == stored (`d < 1e-3`), rank 0, or `e < 1e-4` (flat mates and every screw orbit, incl. the off-axis concentric — measured null
or > 150 there). Measured: `ANGLE` cone, rotation about the cone's axis of symmetry ⇒ `null`; tilt ⇒ 2.94–2.97 weighted mm
for 0.05 rad and 0.5 rad wishes (a curvature property, independent of wish length). `null` means "time cap only" (§8), never
"unlimited forever". It deliberately ignores where the backend *lands* (see §13.2).

Client-side travel since the anchor: `travel = ‖g ∘ log(ref_0, P_shown)‖` with `g = [1,1,1,L,L,L]`, grabbed member.

## 7. Anchor acceptance test

Run on every response before it replaces the model. **Request token** first: drop any response that is not the latest
request's (VR: one in flight; flat app: token like `_scheduleMatePreview`).

```
accept(resp, own):        # own = pose the CURRENT model projects the same wish to (grabbed); None for the very first anchor
    if not resp.converged                      -> reject "not_converged"
    if resp.quality.residual_inf > 1e-6        -> reject "residual"
    if own is not None:
        jump = ‖g ∘ log(own, resp.members[0].transform)‖
        if jump > 1.0 · L                      -> reject "jump"       # a branch flip / different solution, not curvature
    -> accept
```

The client-measured `jump` (anchor vs. own projection of the *same wish*) is the acceptance quantity. `resp.quality.jump` is
**telemetry only**: it is measured against the *additive* first-order prediction from the *stored* pose, so it grows with the whole
drag length (~0 on flat mates, up to ~6.6 weighted mm on the off-axis swing scene where the screw is exact) and would reject honest
corrections. A rejected anchor counts as a miss (§11), keeps the old model and the shown pose, and does not restart the timer for
the next request.

## 8. Re-anchor policy

One request in flight, ever. `reanchor?` is evaluated each frame:

```
if in_flight:                           no
interval = 75 ms if (sigma_gap != null and sigma_gap < 100) else 150 ms       # near a rank change: halve
if now − t_anchor ≥ interval:           yes ("time")
if max_step != null and travel ≥ max_step:  yes ("distance")
else no
```

`t_anchor` = send time of the request whose response was last *accepted*. The first anchor is requested at grab with
`transform: null` (stored pose ⇒ `max_step` null, `jump` 0). `SIGMA_GAP_LOW = 100` is a placeholder: healthy scenes measured
`sigma_gap > 1e3` (B/C/D, `test_assembly_group.py`); no near-singular value has been measured, tune with the S6/S7 counters.
Expected load: ≈ 1 request / 150 ms plus one on release (7 requests for a 60-frame VR drag incl. release + save, S3 e2e), more only on
curved non-orbit mates.

## 9. Blending displayed vs. anchor pose

A newly accepted anchor changes the model, so the projection of the *same wish* jumps by the anchor step (measured on the swing
scene with the real backend anchors: 0.89 weighted mm per frame at a re-anchor vs. 0.34 for the hand). Hide it: keep, per member, an
offset `o` in the `log` chart and decay it by `exp(−1/τ)` per frame, `τ = 2` frames (τ ≈ 33 ms at 60 Hz; use `exp(−dt/33 ms)` if the
frame time varies).

```
on accept (frame f):   old_shown = apply_delta(P_old(W_f), o)                 # what the old model would show now
                       o        = log(P_new(W_f), old_shown) = pose_delta(old_shown, P_new(W_f))        # per member, so apply_delta(P_new, o) == old_shown
each frame:            shown = apply_delta(P(W), o);  o *= exp(−1/τ)
```

Same swing scene: blended per-frame step 0.37 vs. 0.89 unblended (hand 0.34) with real anchors; with true-nearest anchors 0.29 vs.
0.33. The blend is display-only: never feed `shown` back into `log(ref, W)`, never persist it. Drop `o` when `‖g∘o‖ < 1e-6`.

The prototype's "anchor step ≤ hand step" did **not** reproduce with the real solver (anchor-to-anchor per 9 frames: group 4.06,
py-slvs 4.46, hand 3.10 weighted mm); the display pop is handled by screw integration + this blend, not by the solver.

## 10. Rank/dof-change hysteresis

Terms: *dof drop* = a new wall (the free space shrank); *dof rise* = a direction opens. State: the active model `(ref, rows)`, an
optional candidate `rows'` and a counter.

* dof drop or equal dof in an accepted anchor ⇒ **adopt immediately** (motion into the lost direction is dropped; the user feels a wall).
* dof rise ⇒ the anchor's `ref` replaces the active `ref`, but the active `rows` are **kept**; the new rows become the candidate.
  Each frame compute `gain = ‖s ∘ (P_cand(want) − P_active(want))‖` (weighted mm the wish would gain from the new directions). `gain > 0.05`
  increments the counter, otherwise it resets to 0; at 3 consecutive frames adopt the candidate. A later anchor replaces the candidate
  (and re-applies these rules).
* `sigma_gap` small halves the re-anchor interval (§8). There are no inequality mates yet; `quality.active_set` would use the same rule.

## 11. `converged:false` behaviour

The response carries no basis/dof/members. **Never read it as "all free".** Keep the last model *and hold the last shown pose*
(stop moving the part), keep requesting anchors at the normal cadence with the current wish (a moving wish may become reachable),
count consecutive misses, show "can't follow that move" after 3 (throttle to ≤ 1/s), and resume with a normal blend when an anchor is
accepted. The same applies to a rejected anchor (§7) and to a network error/timeout of an anchor request. There is no local
extrapolation past a hold.

## 12. Release / commit flow

1. Stop the per-frame loop; invalidate the in-flight token (its response is ignored).
2. Send **one** final request: `transform` = the release-time *wish* (not the shown pose), `lever_arm`, `commit: true`.
3. `converged:true, committed:true`: the response `members[].transform` are the stored poses — set them for every member, drop the
   blend offset (or blend once from `shown`), one undo entry covering all members, no further refresh needed for those occurrences.
4. `converged:false` (nothing stored, by contract) or an error: restore every member to its stored pose from before the grab
   (the flat app / VR still have it), tell the user, no undo entry. One retry only for a transport error.
5. `fixed` grabbed ⇒ 422 at grab; never start a drag.

## 13. What changed vs. the investigation / prototype, and open findings

1. **Projection metric with followers** (§2, §4): the prototype/E.3 projected with weights on one body; with a group the follower
   weight must be in the metric or the wish is smeared over the members (B +4 x would move each of B, C, D by 4/3).
2. **The backend retraction is not always the nearest point on curved mates.** Gauss–Newton min-norm landing on the off-axis swing
   scene: spin angle 51.0° at the 90° wish vs. the true weighted-nearest 28.5° (cost 213 vs 170); the screw projection of the
   linearised wish lands near the true nearest (~28°). Consequence: at a re-anchor the model jumps toward the overshoot (that is the
   4.06 anchor step and `quality.jump` up to 6.6). Handled here by screw + blend + acceptance; a solver-side fix (sequential
   nearest-point retraction) is a **S2 follow-up**, not done. Vectors: `swing-offset-axis-90deg`, `nearest_anchors` vs. `backend_anchors`.
3. **The prototype's `geo._skew` has a wrong third row** (`[-w0, w1, 0]` instead of `[-w1, w0, 0]`): `geo._V`, hence `project_motion_screw`'s translation, is wrong for any twist with an x or y rotation component (the investigation's z-axis scenes were unaffected; the cone/tilted cases are not). The vectors use the correct skew and `generate.py` asserts screw exactness about arbitrary axes; with `_skew` patched the prototype agrees with all 21 single-member `project` vectors to 5e-13. `acos` → `atan2` rotation vector (§5); follower-weighted GS (§3); hysteresis/blend/scheduler/acceptance are specified as
   state machines with vectors (the investigation had one-liners).
4. **Uncalibrated constants**: `SIGMA_GAP_LOW`, `GAIN_MIN`, `JUMP_REJECT_FACTOR`, `TOL` — first guesses, tune with S6/S7 instrumentation.

## 14. Constants

`FOLLOWER_WEIGHT 1e-4` · GS drop `1e-6` relative / `1e-12` absolute · `τ = 2` frames · `residual_tol 1e-6` · `jump_reject 1.0·L` ·
re-anchor `150 ms` (`75 ms` if `sigma_gap < 100`) · hysteresis `gain 0.05`, `3` frames · series switch `1e-4` rad · `max_step` `TOL 0.25`.
All are also in `vectors.json → constants`.

## 15. Golden vectors

`tools/motion_vectors/generate.py` (numpy only) writes `docs/motion/vectors.json`; `--check` verifies the committed file byte for
byte (identical across the two numpy 2.4.6 builds tried; rounding to 10 decimals absorbs ~1e-12 BLAS noise, far below the 1e-9 tolerance). 61 cases; each has `id`, `kind`, `input`, `expected`; every float is rounded to 10 decimals and every input is rounded
*before* the expectation is computed, so a client that reads the JSON reproduces `expected` from `input` alone (tolerance 1e-9,
poses compared as matrices).

| kind | n | checks |
|---|---|---|
| `gram_schmidt` | 6 | §3: weighting, dependent/zero/near-dependent rows, follower coordinates |
| `project` | 29 | §4–5: flat face (6 + L100 + tilted plane), offset-axis concentric incl. the 90° wish and L = 100 (8), angle cone (5), group B/C/D grabbing B, D, C (8). `additive_members` is informational (v0 integrator), not normative |
| `hysteresis` | 4 | §10: rise adopted at frame 3, flicker reset, drop immediate, equal-dof refresh |
| `blend`, `blend_anchor` | 4 + 1 | §9: decay of translation/rotation offsets, moving projection, followers, continuity at an anchor |
| `scheduler` | 8 | §8 |
| `accept_anchor` | 8 | §7 |
| `swing_sequence` | 1 | 64 frames of the off-axis swing with anchors every 9 frames, once with analytic nearest anchors and once with the real backend anchors (captured from `solve_group`; not recomputed by the script), per-frame `screw`, `screw_blended`, `additive` poses and a `summary` |

Bases are analytic (no SVD) so regeneration does not depend on LAPACK. The B/C/D basis was checked against the real backend
(`analyze_group`, S1 scene): principal-angle cosines all 1 for member orders BCD/DBC/CBD. Backend solver answers are pinned by
`backend/tests/test_assembly_group*.py`, not by the vectors.
