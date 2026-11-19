# Sketch drag projector: spec (parity plan S8)

Normative for the GDScript port (DIDSA-VR `scripts/motion/sketch_projector.gd`, parity plan S9). The reference implementation is
`client/lib/sketch/projector/sketch_projector.dart` (`projectSketch`). A port must reproduce [`sketch-vectors.json`](sketch-vectors.json)
within each case's tolerance (section 10). The background (why there is no client solver, what was measured, what failed first) is
[`docs/sketch-drag-projector.md`](../sketch-drag-projector.md); this file only says **what to compute**. VR writes its code from this
text and the vectors, not by translating the Dart (DIDSA-CAD `LICENSING.md`, rule 1, in spirit, as the parity plan's 3.2 asks).

Not covered here: the mobility oracle (`analyseSketchMobility`, the "can this point move at all" check before a grab) and the
controller's frame guards (blow-up, arc chord side, residual). They are callers' concerns (S10).

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
  for those.
* **A nearly straight chain does not move.** A 20-link chain whose start is almost straight (`scene-chain-20-nearly-straight`) stalls:
  every walking step is infeasible after the correctors, and the tip stays put even when the wish is 8 mm to the side. The two-link
  arm near full reach behaves alike (`scene-arm-followers` ends at the step limit 0.46 mm off the axis, `scene-arm-wall` at 0.2 mm). A
  curled chain (`scene-chain-20-curled`) follows. `docs/sketch-drag-projector.md` describes the straight arm as a bifurcation.
* A point with no rows reports exit `limit` (the loop never runs); harmless.

These are open questions for the owner (section 12), not port defects: a port reproduces them.

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
tenth of the tolerance (measured worst: 0.47 %, so a port's rounding cannot fail a vector). Deterministic: every float is rounded to
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
| `scene` | 19 | free point; slide along a horizontal to a pinned point; only the group is solved; a pinned point does not link; two-link arm (follower, wall); redundant; conflict (not converged); provisional off / on (polish); spline unsupported / elsewhere; unknown Line and Point ids skipped; Fix is the caller's; rectangle with a stiff proposal; a circle built as the backend builds it (cardinal points pinned by 0 distances); two anchors (a whole line); 20-link chain nearly straight (stalls) and curled (the timing vector) |

**Timing.** The slowest frame in `flutter test` (Dart JIT, x86 Linux container) is ~2 ms (`scene-chain-20-curled`). Not a device figure.

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

## 12. Open questions (for the owner; none blocks S9)

1. **Accuracy on curved constraints** (7.4): `omega` never grows back after a rejection, so some walks stop up to ~1e-3 short of the
   nearest point (part D min / max distances, equal radius). Invisible on screen at sketch scale; the drop's backend solve is exact.
   Fixing it (for example resetting `omega` after an accepted step) changes the Dart projector, the vectors and the port together.
2. **Nearly straight chains do not move** (7.4). The flat app has the same behaviour; worth a look before S10 if a straight dimensioned
   polyline is a common thing to drag on the headset.
3. **The two-line `angle` ignores `quadrant`** and follows the reference frame. Part D's angles honour theirs. Consistent with the
   backend as far as this spec goes; not checked against the backend's solve.
