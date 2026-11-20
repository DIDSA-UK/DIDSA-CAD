# Sketch drag projector: spec (parity plan S8)

Normative for the GDScript port (DIDSA-VR `scripts/motion/sketch_projector.gd`, parity plan S9). The reference implementation is
`client/lib/sketch/projector/sketch_projector.dart` (`projectSketch`). A port must reproduce [`sketch-vectors.json`](sketch-vectors.json)
within each case's tolerance (section 10). The background (why there is no client solver, what was measured, what failed first) is
[`docs/sketch-drag-projector.md`](../sketch-drag-projector.md); this file only says **what to compute**. VR writes its code from this
text and the vectors, not by translating the Dart (DIDSA-CAD `LICENSING.md`, rule 1, in spirit, as the parity plan's 3.2 asks).

Sections 1-12 are the projector. Section 13 (added in F6) is its caller for closed-form shapes: the shape proposals, the provisional
sizes, the pre-grab rule and the mobility oracle (`analyseSketchMobility`, the "can this point move at all" check before a grab), with
its own vectors ([`sketch-shape-vectors.json`](sketch-shape-vectors.json)). The controller's frame guards (blow-up, arc chord side)
are named there, not specified.

## 1. What one call answers

Once per drag frame, locally: *the hand wants these points here; where should the points of the dragged group be drawn so that every
constraint still holds?* The answer is the feasible configuration nearest to the wish in a stiffness-weighted metric, reached by walking
from the last accepted frame, so it is always feasible, keeps the branch the drag started on, and lands on a wall when the wish is beyond
one. The backend stays the authority: the drop sends the result as a wish (`solve-and-refresh` with `point_updates`) and takes its answer.

| Input | Meaning |
|---|---|
| `points` | id -> (x, y), every point the caller knows. The **wish**: the grabbed point(s) at the cursor, a closed-form shape's proposal for its other points, every other point where it is |
| `reference` | id -> (x, y): the last accepted frame (on the constraint manifold). The walk starts here and the branch choices (section 5) are read from here. Absent: `points` |
| `constraints` | the sketch's constraints, backend wire form (section 2) |
| `lines` | Line id -> (start Point id, end Point id) |
| `anchors` | the grabbed point(s). Stiffness 1; the group grows from them |
| `stiff` | other points the correction should avoid moving (a closed-form proposal). Stiffness 1 |
| `pinned` | never move: the origin, locked reference points, Fix points (the flat app passes `locked ∪ {origin}`) |
| `provisional` | constraint id -> value: a provisional distance switched on at that value for this call only |

| Output | Meaning |
|---|---|
| `unsupported` | the group holds a constraint with no model here (section 8); nothing was computed |
| `converged` | every coordinate finite and the worst residual ≤ the tolerance (section 6) |
| `points` | id -> (x, y) for the points of the group **only** (pinned points and points outside the group are never returned) |
| `residual_inf` | worst absolute residual at `points` (∞ when unsupported) |
| `variable_points`, `rows` | size of the system: free points of the group, residual rows |
| `exit`, `walks`, `rejected_steps`, `iterations` | how the walk ended (`arrived`, `wall` is not used, `limit`, `stalled`, `none`) and its counts: diagnostics |

The caller writes back, unchanged, any proposal point that is not in the group (a circle's other cardinal points when nothing ties them;
the flat app had this as a bug once).

## 2. Conventions

* Points are 2-D in sketch units (mm). Every quantity below is a function of point coordinates only.
* Constraints arrive in the backend's wire form (`type` plus fields), as `GET …/constraints` returns them; the field names are those
  of the table in section 4. `label` and other fields are ignored.
* `|v|` is `sqrt(max(v·v, ε²))` with `ε = 1e-12`, and its derivative is `(v·v)' / (2|v|)`. So a zero vector has length 1e-12 and a
  finite derivative; nothing divides by zero.
* `cross(u, v) = u.x v.y − u.y v.x`, `dot(u, v) = u.x v.x + u.y v.y`.
* **Signed distance of a point from a line** `sd(p, s, e) = cross(p − s, e − s) / |e − s|` (SolveSpace's sign: positive on the
  right of s→e). `point_line_distance`, `line_distance` and the stored signed values use this sign.
* `abs(f)` is `f` when `f ≥ 0`, else `−f` (derivative likewise; at exactly 0 the sign is +).
* Angles in the wire form are degrees.

## 3. The group and the active constraints

Build once per call (the flat app rebuilds every frame; caching per drag is allowed, the answer is the same).

1. **Active constraints**, in input order. For each constraint:
   * `distance` with `provisional: true`: if `provisional` holds its id, use it with that value (and its own orientation); otherwise skip it.
   * `fixed`: skip (pinning is the caller's `pinned` set, never this constraint: the vector `scene-fixed-is-the-callers`).
   * Resolve its **point list** (section 4, the "points" column: the ids it reads, duplicates removed, in that order). If a Line id
     it names is not in `lines`, skip it. If any listed point is not in `points`, skip it (`scene-unknown-ids-skipped`).
   * A type with no model (`spline_tangent`, or any type not in section 4): keep it aside for step 3.
2. **The group**: start from the anchors that are in `points` and not pinned. Repeatedly, for a group point, take every active
   constraint listing it; that constraint is a **group constraint**, and each of its other non-pinned points joins the group. Pinned
   points never join and are never walked through, so a pinned point does not link two groups (`scene-pinned-does-not-link`). A
   group constraint may also list pinned points; they are constants.
3. **Unsupported**: if a kept-aside constraint touches the group (for `spline_tangent`: any of its eight control points
   `segment_{a,b}_p{0..3}`; for an unknown type: always), the whole call is `unsupported` (section 8).
4. **Variables**: the group's points, two variables each (x, y). Rows: the group constraints in input order, each giving the rows of
   section 4 in the order listed. (The Dart orders variables by discovery: anchors first, then a depth-first walk. Any order gives the
   same answer to rounding.)
5. No group points (every anchor pinned or missing): `converged`, no points, 0 rows, exit `none`.

## 4. Residual per constraint type

`P(id)` is the position of a point (variable or constant). Each row is zero exactly when the constraint holds; the Jacobian is the
exact derivative of the row with respect to the variables (forward-mode automatic differentiation over the 2·k coordinates of the
constraint's k points; zero columns for constants). `b(…)` are the branch signs of section 5.

| `type` | Wire fields read | Points (in order) | Rows |
|---|---|---|---|
| `distance`, `orientation: linear` | `point_a_id` A, `point_b_id` B, `distance` | A, B | `|B − A| − |distance|` |
| `distance`, `horizontal` | same | A, B | `σ·(B.x − A.x) − |distance|`, σ = `b_axis` |
| `distance`, `vertical` | same | A, B | `σ·(B.y − A.y) − |distance|`, σ = `b_axis` |
| `vertical` | `point_a_id` A, `point_b_id` B (not `line_id`) | A, B | `A.x − B.x` |
| `horizontal` | `point_a_id` A, `point_b_id` B | A, B | `A.y − B.y` |
| `coincident` | `point_a_id`, `point_b_id` | A, B | `A.x − B.x`, `A.y − B.y` |
| `concentric` | `center1_point_id` C1, `center2_point_id` C2 | C1, C2 | `C1.x − C2.x`, `C1.y − C2.y` |
| `angle` | `line1_id` (s1, e1), `line2_id` (s2, e2), `angle_degrees` | s1, e1, s2, e2 | `dot(u, v) − |u||v| cos θ`, u = e1 − s1, v = e2 − s2; θ = t or 180 − t when `b_angle` (t: `|angle| mod 360`, then `min(t, 360 − t)`). `quadrant` is **not** read |
| `parallel` | `line1_id`, `line2_id` | s1, e1, s2, e2 | `cross(u, v) / (|u||v|)` |
| `perpendicular` | `line1_id`, `line2_id` | s1, e1, s2, e2 | `dot(u, v) / (|u||v|)` |
| `equal_length` | `line1_id`, `line2_id` | s1, e1, s2, e2 | `|u| − |v|` |
| `collinear` | `line1_id`, `line2_id` | s1, e1, s2, e2 | `sd(s2, s1, e1)`, `sd(e2, s1, e1)` |
| `line_distance` | `line1_id` (s1, e1), `line2_id` (s2, ·), `distance` (signed) | s1, e1, s2 (**not** e2) | `sd(s2, s1, e1) − distance` |
| `point_line_distance` | `point_id` P, `line_id` (s, e), `distance` (signed) | P, s, e | `sd(P, s, e) − distance` |
| `point_on_line` | `point_id` P, `line_id` (s, e) | P, s, e | `sd(P, s, e)` |
| `at_midpoint` | `point_id` P, `line_id` (s, e) | P, s, e | `P.x − (s.x + e.x)/2`, `P.y − (s.y + e.y)/2` |
| `tangent` (line and circle) | `center_point_id` C, `radius_point_id` R, `line_id` (s, e) | C, R, s, e | `abs(sd(C, s, e)) − |R − C|` |
| `curve_tangent` | `center1_point_id` C1, `center2_point_id` C2, `shared_point_id` S | C1, C2, S | `sd(S, C1, C2)` (the shared point on the line of centres) |
| `equal_radius` | `center1_point_id` C1, `radius1_point_id` R1, `center2_point_id` C2, `radius2_point_id` R2 | C1, R1, C2, R2 | `|R1 − C1| − |R2 − C2|` |
| `point_on_circle` | `point_id` P, `center_point_id` C, `radius_point_id` R | P, C, R | `|P − C| − |R − C|` |
| `point_on_ellipse` | `point_id` P, `center_point_id` C, `major_point_id` M, `minor_point_id` N | P, C, M, N | `(sqrt(max(f, ε)) − 1)·k`; m = M − C, n = N − C, d = P − C, a = |m|, b = |n|, f = (dot(d, m)/a²)² + (dot(d, n)/b²)²; k = (a + b)/2 is a **constant** in the derivative (its value only); the sqrt's derivative is `f' / (2 sqrt(max(f, ε)))` |
| `arc_length` | `center_point_id` C, `start_point_id` S, `end_point_id` E, `length` | C, S, E | `|S − C| · sweep(S − C, E − C) − length` |
| `horizontal_angle` | `line_start_id` A, `line_end_id` B, `angle_degrees` α, `quadrant` q | A, B | `u.x − |u| cos θ`, u = B − A; θ = 180 − α when supplement, else α. Supplement: q null → `b_hangle`; else `(q & 1 ≠ 0) ≠ (q & 2 ≠ 0)` (q = 1 or 2) |
| `point_angle` | `vertex_point_id` V, `point1_id` P1, `point2_id` P2, `angle_degrees` α, `quadrant` q | V, P1, P2 | `dot(u, w) − |u||w| cos θ`, u = P1 − V, w = P2 − V; θ and the supplement as `horizontal_angle` (q null → `b_pangle`) |
| `point_circle_distance` | `point_id` P, `center_point_id` C, `radius_point_id` R, `distance`, `side` | P, C, R | d = |P − C|, r = |R − C|. `max`: `d + r − distance`; `min`: `ω·(d − r) − distance`, ω = `b_outside` |
| `circle_distance` | `center1_point_id` C1, `radius1_point_id` R1, `center2_point_id` C2, `radius2_point_id` R2, `distance`, `side` | C1, R1, C2, R2 | d = |C2 − C1|, ρ = |R1 − C1| + |R2 − C2|. `max`: `d + ρ − distance`; `min`: `d − ρ − distance` |
| `line_circle_distance` | `line_start_id` A, `line_end_id` B, `center_point_id` C, `radius_point_id` R, `distance`, `side` | A, B, C, R | o = `b_side · sd(C, A, B)`, r = |R − C|. `max`: `o + r − distance`; `min`: `o − r − distance` |
| `fixed` | | | none (section 3) |
| `spline_tangent` | | | no model: `unsupported` |

`sweep(u, w)`: the counter-clockwise angle from u to w in (0, 2π]: `atan2(cross(u, w), dot(u, w))`, plus 2π when that is ≤ 1e-12.
Its derivative is atan2's: with y = cross(u, w), x = dot(u, w), `(x y' − y x') / max(x² + y², ε)` (ε = 1e-12, not squared here).

Part D's types (bug report 2026-11-18) are the six rows from `arc_length` to `line_circle_distance`. Their `min` / `max` side and the `quadrant` come from the
dimension tool; the parity plan's catalogue (`docs/sketch-dimension-catalogue.json`) says which selection creates which.

## 5. Branch rules (read from the reference frame)

A constraint whose zero set has two branches holds the one the **reference** (the last accepted frame) is on. They are decided once per
call from the reference positions (plain numbers, no derivatives), so a wish that crosses to the other branch is clamped instead of
mirroring the dimension (the `branch-*` vectors). Where a reference position is missing, the default given applies.

| Sign | Of | Rule (R = reference positions) |
|---|---|---|
| `b_axis` | horizontal / vertical `distance` | +1 if `R(B) − R(A)` along the axis is ≥ 0, else −1. Missing: +1 |
| `b_angle` | `angle` | c = the angle between the reference rays in [0°, 180°] (`acos` of the normalised dot, clamped to [−1, 1]); t as in section 4. True when `|(180 − t) − c| < |t − c|`. A zero-length reference ray: false. A missing point: c = 0 |
| `b_hangle` | `horizontal_angle`, q null | c = `acos(clamp(dx / length))` of the reference line (0..180°). True when `|(180 − α) − c| < |α − c|`. Missing or zero length: false |
| `b_pangle` | `point_angle`, q null | c = the angle between the reference rays V→P1, V→P2. Same test with α. Missing or zero-length ray: false |
| `b_outside` | `point_circle_distance`, `min` | +1 when `|R(P) − R(C)| ≥ |R(R) − R(C)|` (the Point outside or on the circle), else −1. Missing: +1 |
| `b_side` | `line_circle_distance` | −1 when `cross(R(C) − R(A), R(B) − R(A)) < 0`, else +1 (so o ≥ 0 in the reference). Missing: +1 |

Note: the two-line `angle` never reads its `quadrant`; part D's two angles read it and use `b_*` only when it is null. A `quadrant`
fixes the branch for good; none follows the reference frame by frame.

## 6. Scale, stiffness and tolerance

* **Start** `x`: for each group point, `reference[id]` if present, else `points[id]`. **Wish** `w`: `points[id]`.
* **Stiffness** `s` per coordinate: 1 for anchors and `stiff` points, `FOLLOWER = 0.01` for every other group point.
* **Diagonal** `D`: of the bounding box of the start `x` over the group's points. **Tolerance** `τ = 1e-6 · max(1, D)`.
* `‖r‖∞` = the largest absolute row value, `‖r‖²` = the sum of squares.
* **Wish distance** `δ(x) = sqrt(Σ (s_c (w_c − x_c))²)`.

## 7. The method

### 7.1 The minimum-norm step

`step(rows, y0)`, with J the Jacobian at the current x, r the row values and `y0` a pull in the scaled coordinates:

```
A    = J · S⁻¹                       (column c divided by s_c)
M    = A Aᵀ;   λ = 1e-10 · max_i M_ii + 1e-14;   M += λ I
rhs  = r + A y0
z    = solve(M, rhs)                 (section 9)
y    = y0 − Aᵀ z                     (scaled step; the coordinate step is y_c / s_c)
```

It is the step nearest to `y0` (in the scaled norm) whose linearisation satisfies the rows. Redundant but consistent rows (a slot's
tangent ring, the same distance twice) are harmless: there is no rank decision.

### 7.2 One corrector (constraint-only Newton step, damped)

```
y = step(rows, 0);  before = ‖r‖²;  α = 1
up to 8 times:
    x = saved + α · y / s;  re-evaluate
    if ‖r‖² < before: accept (iterations += 1), return true
    α = α / 2
restore x (and the rows), return false
```

### 7.3 The walk

```
evaluate rows at x
if there are no rows: x = w                       (a point nothing constrains goes where the hand is; exit stays "limit")
polish: up to MAX_POLISH = 10 times, while rows exist and ‖r‖∞ > τ: if the corrector fails, stop
trust = max(TRUST = 2, TRUST_DIAGONAL = 0.1 · D);  radius = trust
omega = 1;  prev = none;  stalled = 0;  exit = "limit"
up to NEAREST_MAX = 24 times, while rows exist and ‖r‖∞ ≤ τ:
    n0 = δ(x);  if n0 < τ: exit = "arrived"; stop
    save x and the rows
    y = step(rows, s ∘ (w − x));  big = max_c |y_c / s_c|
    if big < ARRIVED · max(1, D): exit = "arrived"; stop            (ARRIVED = 1e-5: the constraints block the whole pull)
    boost = 1
    if prev:  ρ = Σ (y_c / s_c) prev_c / Σ prev_c²   (0 when prev is all zero)
              if ρ < −0.3: omega = max(MIN_OMEGA, omega / 2)          (MIN_OMEGA = 1/32: a zigzag)
              if 0.5 < ρ < 0.999: boost = min(MAX_BOOST = 8, 1 / (1 − ρ))   (Aitken, on a slow monotone tail)
    infeasible = false;  accepted = false
    for f in (boost > 1 ? [omega · boost, omega] : [omega]):
        cap = (big · f > radius) ? radius / (big · f) : 1
        x = saved + f · cap · y / s;  re-evaluate;  iterations += 1
        up to CORRECTORS = 4 times while ‖r‖∞ > τ: if the corrector fails, stop
        if ‖r‖∞ ≤ τ and δ(x) < n0 · (1 − 1e-9): accepted = true; stop trying
        if ‖r‖∞ > τ: infeasible = true
        if walks = 0 and rescue(f, n0): accepted = true; stop trying      (7.3.1; F6)
        restore the saved x and rows
    if not accepted:
        prev = none;  rejected += 1
        if infeasible: radius = radius / 2;  stalled += 1;  if stalled > 5: exit = "stalled"; stop
        else:          omega = omega / 2;     if omega < MIN_OMEGA: exit = "arrived"; stop
        next
    walks += 1;  stalled = 0;  radius = min(trust, 2 · radius)
    prev = x − saved;  moved = max_c |prev_c|
    if moved < ARRIVED · max(1, D) or δ(x) < τ: exit = "arrived"; stop
converged = every x finite and ‖r‖∞ ≤ τ (the rows at the final x)
```

#### 7.3.1 The rescue step (a singular start; added in F6)

Until a call has accepted a walking step (`walks = 0`), every rejected attempt is retried once as a rescue step, from the same
saved x and rows, with the same multiplier f and the current `radius`. With `1` the vector of ones (every coordinate stiffness 1):

```
rescue(f, n0):
    u   = step₁(rows at saved, w − saved)          (7.1 with S = I: the pull in the uniform metric)
    big = max_c |u_c|;  if big < ARRIVED · max(1, D): return false
    cap = (big · f > radius) ? radius / (big · f) : 1
    t   = saved + f · cap · u;  r_t = the rows' values at t
    v   = step₁(rows with the SAVED Jacobian and the values r_t, 0)       (a second-order correction)
    x   = t + v;  re-evaluate;  iterations += 1
    up to CORRECTORS = 4 times while ‖r‖∞ > τ: if the corrector (7.2, stiffness-weighted) fails, stop
    return ‖r‖∞ ≤ τ and δ(x) < n0 · (1 − 1e-9)
```

`step₁` is 7.1's step with every `s_c = 1`; `v`'s matrix is built from the saved point's Jacobian (the rows of the last accepted
frame, in the same order) and its right-hand side from the residual values at `t`. A rescue that fails leaves `infeasible` as the
plain attempt set it: the radius / `omega` bookkeeping below reads the plain attempt only. Once a step has been accepted the rescue
is never tried again in that call.

Why: at a singular start (a dimensioned chain at full reach, an arm nearly straight) the stiffness-weighted step either moves the tip
sideways alone (tangent to first order, beyond reach to second order) or sends the cheap followers a long way; the weighted correctors
cannot bring that back and every step was rejected (the stall of 7.4, before F6). In the uniform metric the followers no longer absorb
the pull, and the correction along the normal space at the saved point takes out the step's second-order error (the tip comes back
inside the reach), so the correctors start close to the manifold and the chain swings round its pinned end.

Notes that matter for a port:
* "Stop" leaves the loop with x as it is (accepted steps are kept).
* `omega` never grows back within a call. `rejected` counts both kinds of rejection; `stalled` only the infeasible ones and resets on an
  accepted step.
* The cap limits the **displacement** (`big · f`), never the pull: most of a pull may be blocked by the constraints, and what slides
  along them is the useful part.
* The polish runs only when the start is infeasible (a provisional size just switched on: `scene-provisional-on`, or an infeasible
  start as in `scene-arm-followers`). If it does not reach τ, the walk does not run and the call is not converged.

### 7.4 As built: where the answer is not the exact nearest point

The vectors pin the Dart projector's answers, not the exact nearest points. Where they differ:
* **Stops short on curved constraints.** After rejections the step multiplier only shrinks; at the floor the walk declares "arrived".
  The golden cases measure the gap to the exact nearest point (`nearest` in the file): ≤ 1e-6 for 23 of 32, 1e-5 to 9e-4 for nine
  (equal radius, the no-quadrant horizontal angle and every part D min / max distance; sizes 5-20 mm). The flat app's tests allow 1e-3
  for those. Kept as built (owner, 2026-11-19: under a micron, and the drop's backend solve is exact).
* **A far wish from a singular start ends at the step limit, a little inside the wall.** With the rescue (7.3.1) a nearly straight
  20-link chain follows the hand round its pinned end (`scene-chain-20-nearly-straight`: the tip lands 0.01, 0.09 and 0.38 mm from
  the nearest feasible tip in its three frames; before F6 it did not move at all). Each step near full reach is short, so a wish
  far beyond the reach ends at `NEAREST_MAX` (exit `limit`) with the tip slightly inside the reach circle; the next frame continues
  from there. A curled chain (`scene-chain-20-curled`) follows as before.
* **The two-link arm near full reach.** Fixed as a side effect of the rescue: `scene-arm-followers` ends 0.001 mm off the axis
  (was 0.46) and `scene-arm-wall` 0.05 mm (was 0.2), both at the reach.
* A point with no rows reports exit `limit` (the loop never runs); harmless.

**What F6 changed in the vectors** (all other cases are unchanged to 1e-9): `scene-chain-20-nearly-straight` (moves),
`scene-arm-followers`, `scene-arm-wall` (on the axis), `scene-chain-20-curled` frame 3 (4e-3 mm, a first step rejected then
rescued) and `drag-maximum-distance-point-and-circle` frames 6-7 (the point stalls on the maximum-distance wall 0.2 mm from
where it did, the wall itself unchanged; both converged). The golden cases' answers did not change: their short stops come after
an accepted step, where the rescue never runs.

These are the reference's answers, not port defects: a port reproduces them.

## 8. Unsupported

`unsupported: true`, `converged: false`, no points, `residual_inf` ∞ (null in the file), 0 variables, 0 rows, 0 iterations. Only a
constraint the group touches matters (`scene-spline-elsewhere`). The flat app then applies a closed-form shape's proposal unclamped
(hybrid drag) or falls back to the network (general drag); what VR does is S10's decision.

## 9. Linear algebra

`M` is m × m (m = rows), symmetric positive definite after the λ shift. The Dart solves it by Gaussian elimination with partial pivoting
(for each column, swap in the row below with the largest |entry|; a zero pivot skips that column; back substitution gives 0 for a
zero pivot). A port should do the same; another accurate solver (Cholesky) is allowed if the vectors pass. `M` is dense: O(m³) per
step, which is why the group restriction matters (`docs/sketch-drag-projector.md`, "Cost vs coupled size").

## 10. Golden vectors

`docs/motion/sketch-vectors.json`, written by `client/test/support/sketch_vectors.dart` through `flutter test` (the projector imports
`sketch_api_client.dart`, which pulls in Flutter, so it cannot be a `dart run` script):

```
tools/sketch_vectors/export.sh            # (re)write the file, then check it
tools/sketch_vectors/export.sh --check    # exit 1 if a regeneration differs, or the Dart projector fails its own vectors
```

The check is `client/test/sketch_vectors_test.dart`, which the full client suite runs too. It fails when a regeneration differs from
the committed file (any number by more than `regenerate_tolerance` 1e-9, anything else at all), when the Dart projector does not
reproduce a vector from its JSON alone within the case's tolerance, or when nudging the inputs by 1e-10 moves an answer by more than a
tenth of the tolerance (measured worst: 1.8 %, `scene-chain-20-nearly-straight`, since F6; 0.47 % before; so a port's rounding cannot fail a vector). Deterministic: every float is rounded to
10 decimals; inputs are rounded and read back from JSON before the expected values are computed.

**File.** Top level: `version`, `spec`, `generator`, `regenerate_tolerance`, `points_relative_tolerance`, `constants` (section 11),
`conventions`, `cases`. Each case:

| Field | |
|---|---|
| `id`, `kind`, `description` | `kind`: `golden`, `drag`, `branch`, `scene` |
| `tolerance` | absolute, per coordinate: `1e-5 · max(1, diagonal of input.start)` |
| `input` | `start` (id -> [x, y]), `lines` (id -> [start, end]), `constraints` (wire form), `anchors`, `stiff`, `pinned` (lists of ids), `provisional` (id -> value) |
| `nearest` | golden only, where known: the exact nearest point of `d` (informational, section 7.4) |
| `frames` | list of `{wish, expected}` |

**Replaying frame k** (the procedure every port follows): `prev` = `input.start` with `frames[0..k−1].expected.points` laid over it in
order (the **file's** numbers, not the port's own earlier answers, so errors do not accumulate). Call the projector with
`points = prev` with `frames[k].wish` laid over it, `reference = prev`, and the input's lines, constraints, anchors, stiff, pinned and
provisional. Compare: `unsupported`, `converged`, `variable_points` and `rows` exactly; the set of ids in `points` exactly; each coordinate
within `tolerance`. `residual_inf` (≤ τ when converged), `exit`, `walks`, `rejected_steps` and `iterations` are informational.

**Cases** (90 cases, 358 frames):

| kind | n | what |
|---|---|---|
| `golden` | 32 | every supported type, one grabbed point `d`, every other point pinned, one wish (the flat app's golden cases: 21 from `sketch_projector_test.dart` and 11 part D ones, `client/test/support/sketch_projector_cases.dart`) |
| `drag` | 32 | the same geometries with only the first other point pinned (the rest follow at stiffness 0.01), 8 frames along a path from `d` towards the golden wish and twice as far, bowed to one side |
| `branch` | 7 | a hand path across the other branch: vertical / horizontal distance, two-line angle held at its supplement, horizontal and three-point angle with no quadrant, minimum distance outside a circle, a circle dragged through a line (tangent side) |
| `scene` | 19 | free point; slide along a horizontal to a pinned point; only the group is solved; a pinned point does not link; two-link arm (follower, wall); redundant; conflict (not converged); provisional off / on (polish); spline unsupported / elsewhere; unknown Line and Point ids skipped; Fix is the caller's; rectangle with a stiff proposal; a circle built as the backend builds it (cardinal points pinned by 0 distances); two anchors (a whole line); 20-link chain nearly straight (a singular start: moves through the rescue, 7.3.1) and curled (the timing vector) |

**Timing.** The slowest frame in `flutter test` (Dart JIT, x86 Linux container) is ~3.3 ms (`scene-chain-20-nearly-straight` frame 0,
the rescue's extra solves; ~2.8 ms `scene-chain-20-curled`). Not a device figure.

## 11. Constants

| Name (file) | Dart | Value |
|---|---|---|
| `follower_stiffness` | `kProjectorFollowerStiffness` | 0.01 |
| `nearest_max` | `kProjectorNearestMax` | 24 walking steps |
| `arrived` | `kProjectorArrived` | 1e-5 (times `max(1, D)`) |
| `min_omega` | `kProjectorMinOmega` | 1/32 |
| `max_boost` | `kProjectorMaxBoost` | 8 |
| `correctors` | `kProjectorCorrectors` | 4 per walking step |
| `max_polish` | `kProjectorMaxPolish` | 10 |
| `tolerance` | `kProjectorTolerance` | 1e-6 (times `max(1, D)`) |
| `trust`, `trust_diagonal` | `kProjectorTrust`, `kProjectorTrustDiagonal` | 2 mm, 0.1 · D |
| `eps` | literal | 1e-12 (`|v|` uses ε²; `sweep` and the ellipse use ε) |
| `lambda_relative`, `lambda_absolute` | literal | 1e-10 · max diag, + 1e-14 |
| `corrector_halvings` | literal | 8 |
| `closer_ratio` | literal | 1e-9 (a step must bring δ below `n0 (1 − 1e-9)`) |
| `rho_reverse`, `rho_boost_low`, `rho_boost_high` | literal | −0.3, 0.5, 0.999 |
| `stall_limit` | literal | 5 (the sixth infeasible rejection in a row stops) |

All are in the file's `constants` too.

## 12. Open questions and decisions

1. **Accuracy on curved constraints** (7.4): `omega` never grows back after a rejection, so some walks stop up to ~1e-3 short of the
   nearest point (part D min / max distances, equal radius). **Decided (owner, 2026-11-19, DIDSA-VR parity follow-ups decision 3):
   keep as built.** Invisible at sketch scale; the drop's backend solve is exact.
2. **Nearly straight chains did not move** (7.4). **Decided: fix (decision 3); done in F6** by the rescue step (7.3.1), the Dart
   projector and the vectors first, the VR port after (DIDSA-VR session F7). The arm's 0.2-0.5 mm offset was not a target; the rescue
   removed most of it.
3. **The two-line `angle` ignores `quadrant`** and follows the reference frame. Part D's angles honour theirs. Consistent with the
   backend as far as this spec goes; not checked against the backend's solve.

## 13. Shape proposals: dragging a closed-form shape's point (hybrid drag; added in F6)

Normative for DIDSA-VR's line and shape drags (parity follow-ups F8). The reference is `SketchController` (`client/lib/sketch/sketch_controller.dart`:
`updatePointDrag`, `_closedForm*Geometry`, `_closedFormPolygonVertices`, `_closedFormCircleDragPositions`, `_closedFormArcDragPositions`,
`_hybridStructuralFor`, `_runHybridDragFrame`, `_beginPointDrag`); the background is `docs/sketch-drag-hybrid.md`. A port reproduces
[`sketch-shape-vectors.json`](sketch-shape-vectors.json) (13.7). As with sections 1-11, write the code from this text and the vectors.

**Why.** Without a proposal the projector moves only the grabbed point and spreads the correction over the shape's other points by the
minimum-norm rule, so a circle's rim drag moves its centre and a rectangle's corner drag moves the opposite corner (measured in VR,
investigation C3). The proposal says where *every* point of the shape should go (a rigid, regular shape, one closed-form answer), and
the projector only clamps it to the user's constraints.

### 13.1 Shapes, membership and one frame

Seven families, read from the backend's shape records (the wire keys below; `GET …/circles` etc.). A point belongs to the **first**
family in this order whose record names it in the roles listed; the shape must be **intact** (every point and line the record names
still exists), else the point is dragged as a plain point (sections 1-11 with no proposal).

| Family (`kind` in the file) | Record keys read | Members (grabbable roles) | Intact also needs |
|---|---|---|---|
| polygon | `center_point_id`, `vertex_point_ids` (in order), `line_ids`, `radial_line_ids`, `sides`, `inscribed_circle_id`, `circumscribed_circle_id`, `structural_constraint_ids` | centre, vertices | the lines |
| slot | `center1_point_id`, `center2_point_id`, `a_point_id` … `d_point_id`, `centerline_id`, `line1_id`, `line2_id`, `arc1_id`, `arc2_id`, `structural_constraint_ids` | both centres, the four corners | the lines and both arcs |
| circle (`circles`) | `center_point_id`, `radius_point_id`, `cardinal_point_ids` (N, E, S, W), `structural_constraint_ids` | centre, radius point, cardinals | |
| arc | `center_point_id`, `start_point_id`, `end_point_id`, `structural_constraint_ids` | all three | |
| ellipse | `center_point_id`, `major_point_id`, `major_point_neg_id`, `minor_point_id`, `minor_point_neg_id`, `major_axis_line_id`, `minor_axis_line_id`, `structural_constraint_ids` | all five points | both axis lines |
| ellipse_arc | `center_point_id`, `major_point_id`, `minor_point_id`, `start_point_id`, `end_point_id`, the two axis lines, `structural_constraint_ids` | all five points | both axis lines |
| rectangle | `corner_point_ids` (4, in order round the rectangle), `line_ids`, `axis_aligned`, `center_point_id`, `diagonal_line_id`, `diagonal2_line_id`, `structural_constraint_ids` | corners, centre | `axis_aligned`, a centre point and a diagonal line |

(A slot's two arcs are also arc records: a slot point is a slot member first.)

**One frame.** At the grab, remember the grabbed point's position G and the hand's H₀. Each frame the hand is at H; the grabbed point's
**target** is `T = G + (H − H₀)`. `P(id)` is a point's **current** position: the last frame's written-back answer (the grab's positions
on the first frame). Then:

1. the family's **proposal** (13.2, 13.3) from P, the grabbed id and T: a target for some or all of the shape's points (the grabbed one
   included unless said otherwise), or **none** (a degenerate case: nothing moves this frame);
2. **plain or hybrid** (13.4): with no user constraint touching the shape, write the proposal back as it is; otherwise clamp it with the
   projector and write back the clamp.

`|v|` is the plain Euclidean length here; "< 1e-9" tests guard the degenerate cases; angles in radians; `atan2(y, x)`.

**Confirmed size.** A shape's size dimension is the `distance` constraint with exactly these `point_a_id` → `point_b_id` (first in
constraint order): circle centre → radius point; arc centre → start; ellipse and ellipse arc centre → major, centre → minor; slot
centre 1 → corner a; polygon centre → vertex 0 (a non-provisional one first, else the first). It is **confirmed** when it exists and is not
`provisional: true`; its value is `distance`. A polygon's circumradius is also confirmed through its inscribed circle: when that
circle's size (its centre → radius point) is confirmed with value r, the circumradius is `r / cos(π / sides)`.

### 13.2 The proposals

**Centre drags translate** (every family): with `d = T − P(centre)`, the centre goes to T and every other listed point to `P + d`:
circle: radius point and cardinals; arc: start, end; ellipse: the four tips; ellipse arc: major, minor, start, end; rectangle: the
four corners; polygon: every vertex and, when the inscribed circle exists and its radius point is in the sketch, that radius point.
Slot centres are the exception (below).

**Circle** (C = P(centre)). The drag **mode** first:
* centre: translate (above).
* radius point or cardinal: **resize** when the size is not confirmed; when it is confirmed, **translate** by the hand's delta: the
  proposal is the centre drag with the centre's target `C + (T − P(grabbed))`.

Resize: the grabbed point's index i in `cardinal_point_ids` gives the new radius ρ = `|T.y − C.y|` for N (0) and S (2), `|T.x − C.x|`
for E (1) and W (3); a radius point that is not a cardinal gives ρ = |T − C|. ρ < 1e-9: none. Targets: cardinal i at
`C + ρ (cos a_i, sin a_i)` with a = (π/2, 0, 3π/2, π); the radius point, when it is not a cardinal, at T if it is the grabbed one, else on
its old ray at ρ (`C + (ρ, 0)` if it sat on the centre). The centre is not in the proposal (it stays). (In the file the radius point is
always a cardinal, the fake's construction; the non-cardinal branch is not covered by a vector.)

**Arc** (C, S = start, E = end). Mode: centre → translate; an end → resize when the size (centre → start) is not confirmed, else
translate by the hand's delta (centre target `C + (T − P(grabbed))`). Resize: ρ = |T − C| (< 1e-9: none); the grabbed end at T, the
other end on its old ray at ρ (`C + (ρ, 0)` if it sat on the centre). The centre is not in the proposal.

**Ellipse** (C, M = major, M⁻, N = minor, N⁻). Centre → translate. Otherwise:
* major tip (M or M⁻, σ = −1 for M⁻, else +1): `u = σ (T − C)`; ρ = |u| (< 1e-9: none); angle θ = atan2(u); the major radius is the
  confirmed major size when there is one (the ellipse then only turns), else ρ; the minor radius b = |N − C| (kept).
* minor tip (N or N⁻, σ likewise): a = |M − C| (< 1e-9: none), θ = the angle of M − C; b = `|σ (T − C) · (cos(θ + π/2), sin(θ + π/2))|`.
* b < 1e-9: none. Targets (the centre is not in the proposal): M = C + a (cos θ, sin θ), M⁻ = C − a (cos θ, sin θ),
  N = C + b (cos(θ + π/2), sin(θ + π/2)), N⁻ = C − b (…). The grabbed tip's target is that formula, not T.

**Ellipse arc** (C, M, N, S = start, E = end; a₀ = |M − C|, b₀ = |N − C|). Centre → translate. Otherwise:
* an end (S or E): b₀ < 1e-9: none. The proposal is **that end only**, at the ellipse point of T's parametric angle:
  `t = param(T)`, target `ell(t)`, where for the current ellipse (centre C, major tip M, minor radius b₀) with r = the angle of M − C:
  `param(p)`: q = rotate(p − C, −r); `t = atan2(q.y / b₀, q.x / a₀)`; `ell(t) = C + rotate((a₀ cos t, b₀ sin t), r)`.
* major tip M: ρ = |T − C| (< 1e-9: none); θ = the angle of T − C; new a = the confirmed major size, else `max(ρ, b₀)`; b = b₀.
* minor tip N: a₀ < 1e-9: none; θ = the angle of M − C; a = a₀; b = `min(|(T − C) · (cos(θ + π/2), sin(θ + π/2))|, a₀)`.
* b < 1e-9: none. Targets: M = C + a (cos θ, sin θ), N = C + b (cos(θ + π/2), sin(θ + π/2)), and (when b₀ ≥ 1e-9) S and E keep their
  parametric angles measured on the **old** ellipse: `S = ell'(param(P(S)))`, `E = ell'(param(P(E)))`, ell' being the new ellipse
  (centre C, tip M, minor b). The centre is not in the proposal.

**Rectangle** (corners k0..k3 in record order, centre K). Centre → translate. A corner i: the opposite corner O = P(k_{(i+2) mod 4})
stays (not in the proposal); targets: k_i at T; for even i, k_{(i+1) mod 4} at (O.x, T.y) and k_{(i+3) mod 4} at (T.x, O.y); for odd i
the other way round ((T.x, O.y) and (O.x, T.y)); the centre at (T + O) / 2.

**Polygon** (centre C, vertices v_0..v_{n−1}, n = `sides`). Centre → translate. A vertex v_i: d = T − C, |d| < 1e-9: none; the
circumradius R = the confirmed circumradius when there is one (the polygon then only turns), else |d|; β = atan2(d) − 2πi/n; every
vertex v_j at `C + R (cos(β + 2πj/n), sin(β + 2πj/n))`; when the inscribed circle exists (its radius point in the sketch), its radius
point at `C + ρ_in (cos(β + π/n), sin(β + π/n))` with ρ_in = its confirmed size, else `R cos(π/n)`. The centre is not in the proposal.

**Slot** (centres c1, c2, corners a, b near c1 and c, d near c2, radius point a for the size). Corners are recomputed from the two
centres and a radius ρ: `n = perp((c2 − c1)/|c2 − c1|)` = (−dir.y, dir.x); a = c1 + ρn, b = c1 − ρn, c = c2 − ρn, d = c2 + ρn
(|c2 − c1| < 1e-9 or ρ < 1e-9: none).
* c1 grabbed: c1 = T, ρ = |P(a) − P(c1)| (the old radius). c2 grabbed: c2 = T, ρ the same.
* a corner grabbed: centres stay; ρ = the distance of T from the line through c1 and c2 (|c2 − c1| < 1e-9: none).
* Targets: both centres and all four corners (six points).

### 13.3 Which drags are refused or limited by a confirmed size (summary)

| Family | Confirmed size | Effect |
|---|---|---|
| circle | radius | a rim / cardinal drag translates (refused if the centre is fully pinned, 13.5) |
| arc | radius (centre → start) | an end drag translates (refused if the centre is fully pinned) |
| ellipse | major | a major drag only turns |
| ellipse | minor | a minor drag is **refused** at the grab |
| ellipse arc | major / minor | a major drag only turns / a minor drag is **refused** |
| polygon | circumradius (or the inscribed circle's radius) | a vertex drag only turns |
| slot | radius (centre 1 → a) | a corner drag is **refused** |
| rectangle | none | |

### 13.4 Plain or hybrid, and the provisional sizes

**User constraint.** Any constraint whose id is not in the shape's `structural_constraint_ids` and that names (as a point or, through a
line id, a line) one of the shape's **touch set**:

| Family | Points | Lines |
|---|---|---|
| polygon | the vertices, the inscribed and circumscribed circles' radius and cardinal points; **the centre only for a centre drag** | edges, radial lines |
| slot | the four corners; both centres only for a centre drag | `line1_id`, `line2_id`; the centre line only for a centre drag |
| circle | radius point, cardinals; the centre only for a centre drag | |
| arc | start, end; the centre only for a centre drag | |
| ellipse | the four tips; the centre only for a centre drag | both axis lines |
| ellipse arc | major, minor, start, end; the centre only for a centre drag | both axis lines |
| rectangle | corners and centre | sides and both diagonals |

(A vertex / rim drag never moves the centre, so a constraint on the centre alone cannot be broken by it.) Decided **once at the grab**
for the whole drag.

**Plain** (no user constraint, or the shape's structural ids are unknown): each frame writes the proposal back as it is.

**Hybrid**: each frame calls the projector (sections 1-11) once:

| Input | Value |
|---|---|
| `points` | every point at P, with the proposal laid over it |
| `reference` | P (the last written-back frame; the grab's positions on the first frame) |
| `constraints`, `lines` | the whole sketch's |
| `anchors` | the grabbed point |
| `stiff` | every point the proposal names |
| `pinned` | the locked points and the origin |
| `provisional` | for each constraint in the shape's `structural_constraint_ids` that is a `distance` with `provisional: true`: its id → `|B − A|`, A and B its two points at their proposed positions (P when the proposal does not name them) |

Written back when the projection is converged: its points, plus every proposal point outside the projector's group at its proposal.
Not converged: nothing moves this frame (the shape stays at the last good frame). Unsupported (a spline tangency in the group): the
proposal is written back unclamped and the drop's backend solve settles it. The flat app also drops a frame that moves a non-anchor
point more than `max(10 · D, 100)` from its seed (D the diagonal of every point's seed) or flips any arc's centre to the other side of
its chord; neither fires in the vectors.

The drop is the ordinary point drop (the moved points ride in `solve-and-refresh` as `point_updates`).

### 13.5 The pre-grab rule

In this order; the first that applies refuses the grab:

1. The sketch is busy, or the point is the origin or a locked point.
2. **A point on no intact shape**: refused if it is over-constrained (the rigidity analysis says so, `docs/sketch-rigidity-spec.md`; or a
   constraint the last solve reported failed names it; or it is on a line that is both horizontal and vertical, or on either of two lines
   that are both parallel and perpendicular) or **immobile**: its mobility (13.6) is 0; when the mobility oracle is unsupported, when it is
   *fully pinned*.
3. **A shape point**, by family: circle centre, polygon centre, arc centre: refused when the centre is fully pinned; circle rim /
   cardinal with a confirmed radius, arc end with a confirmed radius: refused when the centre is fully pinned; arc end: also refused when
   the rigidity analysis says the end is fully constrained; slot corner with a confirmed radius, ellipse minor tip (either) with a
   confirmed minor radius, ellipse arc minor tip with a confirmed minor radius: refused.
4. **A hybrid drag** (13.4): also refused when the point is over-constrained (as in 2) or immobile (mobility 0; when the oracle is
   unsupported, when the rigidity analysis says it is fully constrained).

**Fully pinned** (point p): the whole sketch is fully constrained (the backend's last solve converged with `dof ≤ 0`, the sketch has
geometry, and the rigidity analysis grounds at least one point), or the rigidity analysis says p is fully constrained or pinned
(`docs/sketch-rigidity-spec.md`).

### 13.6 The mobility oracle

`analyseSketchMobility` (same file as the projector). From the point's group (section 3, with no provisional sizes and the pinned set
of 13.4) and the current positions: the rows of section 4 at those positions, rows with no variable column dropped. Gauss-Jordan
elimination of the dense row matrix (pivot = the largest |entry| in the column at or below the current row; a column whose best
|entry| ≤ `1e-8 · max(1, max |entry|)` is skipped; the pivot row is scaled to 1 and the column cleared above and below). Each non-pivot
column f gives a null-space vector (1 at f, `−a[i][f]` at pivot column i), orthonormalised against the earlier ones (Gram-Schmidt;
a vector whose norm falls under 1e-12 is dropped). For each group point, the 2 × 2 Gram matrix of its (x, y) entries over the basis;
its mobility is the number of eigenvalues above 1e-9 (0, 1 or 2). A point outside the group has mobility 2; an unsupported group gives
no answer (the caller's fallback, 13.5). First order only: a momentarily singular configuration (a straight arm) is not caught.

### 13.7 Vectors

`docs/motion/sketch-shape-vectors.json` (34 cases, 73 frames), written by the "shape proposal vectors (F6)" group of
`client/test/sketch_controller_test.dart`: each case draws a shape with the app's own tools on the hybrid-drag tests' fake backend,
optionally confirms a size or adds a user constraint (the hybrid-drag tests' own scenes, plus two dimensioned to the pinned origin),
grabs a point and drags it. `tools/sketch_vectors/export_shapes.sh` writes it; `--check` fails when a regeneration differs (1e-9) or
when `client/test/sketch_shape_vectors_test.dart`, reading the file alone, finds a hybrid frame whose written-back positions are not
the projector's answer to 13.4's call, or a plain frame that does not write back exactly its proposal.

| Field | |
|---|---|
| `input` | `points` (every point, the origin included), `lines` (id → [start, end]), `constraints` (wire form, `provisional` flags included), `shapes` (id → the backend record plus `kind`), `grabbed`, `pinned` |
| `grab` | the pre-grab rule's answer; a refused case has no frames |
| `frames[k].target` | T for that frame (the file's hand starts on the grabbed point, so T is the hand) |
| `expected.proposal` | id → target for every point the proposal names (13.2) |
| `expected.provisional` | the provisional sizes (hybrid frames; empty otherwise) |
| `expected.hybrid`, `clamp` | plain or hybrid; `none` / `accepted` / `rejected` |
| `expected.result` | the positions written back for the proposal's points and every point that moved |
| `tolerance` | per coordinate, `1e-5 · max(1, diagonal of input.points)` |

**Replaying frame k:** P = `input.points` with frames 0..k−1's `expected.result` laid over it (the file's numbers). A port computes the
proposal from P, the grabbed id and the target, and compares it with `expected.proposal` (the same ids, each coordinate within the
tolerance); for a hybrid frame it also makes 13.4's call with the file's `expected.provisional` and compares with `expected.result`;
for a plain frame `result` equals the proposal.

**What the vectors do not cover.** The shapes come from the flat app's **test fake**, not the real backend: the circle's radius point is
always its north cardinal, a circle has only its provisional radius as structure (the backend also ties its cardinals to the centre,
`scene-circle-cardinals` in section 10), and the fake's structural ids are its own approximation of the backend's. The proposals do not
depend on that, but a port's clamp answers on a real sketch will differ from these numbers: compare the clamp on the file's own
constraints, not on a sketch made by the backend. Not covered by a vector: the non-cardinal radius point, the inscribed circle of a
polygon, a fully pinned centre (13.5 step 3), a frame dropped by the flat app's guards, an unsupported group, the general points' rule
(13.5 step 2).
