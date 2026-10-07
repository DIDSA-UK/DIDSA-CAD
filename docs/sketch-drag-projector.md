# Sketch drag without a client solver: the bespoke projector (option 1)

Status: implemented on branch `option1-sketch-projector` (not merged, no PR). Builds on `docs/sketch-drag-hybrid.md` (the groundwork)
and the wish > solve design of `docs/constrained-drag-implementation-plan.md`. This file records **what was built, what was
measured, what was decided, and what is left** - including the places where the first idea was wrong.

## Why

Being deployable on the iOS App Store is a goal, and the earlier decision to accept GPL-3 for the SolveSpace solver
(`libdidsa_slvs_ffi`, linked into the Flutter client) forecloses it. The backend keeps py-slvs (a separate program reached over
HTTP); only the **client** has to be GPL-solver-free. Owner decisions carried over unchanged: constraint-limited points slide
along the permitted path while the shape changes in real time, no extra feedback; all shapes; the drop keeps wish > solve (the
client's final positions are sent as a wish, the backend returns the authoritative result and DOF); no CI workflow steps added.

## What changed (summary)

| | before | now |
|---|---|---|
| per-frame constraint step | SolveSpace through `dart:ffi` (Android only; Windows/iOS: backend round trips at ~8 Hz, no guards) | `projectSketch` (`client/lib/sketch/projector/sketch_projector.dart`): pure Dart, **every platform** |
| what is solved | the whole sketch, rebuilt every frame | only the connected group of the dragged point |
| SolveSpace in the client | bundled-by-hand `.so`, `lib/sketch/local_solver/*` | **nowhere in `lib/`**. The FFI port lives under `client/test/support/slvs_reference/` and is a *test reference engine* only |
| drop | PATCH per reflowed point (sequential awaits; the old engine reported *every* sketch point as reflowed) + solve | **one** `solve-and-refresh` request carrying the moved points (`point_updates`, the wish) |
| pre-grab "can this move at all" | structural union-find count (`isPointFullyPinned`) | measured rank of the constraint Jacobian (`analyseSketchMobility`); structural count only as fallback |
| instrumentation | none | `SketchController.dragStats` (frames, accepted / rejected / unsupported, µs, system size, iterations) |

`grep -rn "dart:ffi\|slvs" client/lib` finds nothing (apart from a comment about the backend's py-slvs).

The single seam promised by the groundwork held: `_runHybridDragFrame` / the plain drag paths call `_trySolveDuringDragLocally`,
which calls `_clampDragFrame`, which calls `projectSketch`. The closed-form proposals, structural-id classification, pre-grab
rules, drop protocol and undo did not change; the three frame guards (blow-up, arc chord side, residual) were kept and now
run on the projector's answer.

## The projector

Input per frame: a **wish** (grabbed point at the cursor; for a closed-form shape the shape's proposal for all its points;
everything else where it is), the **last accepted frame** (on the manifold) and the sketch's constraints. Output: the points of
the dragged group placed at the weighted-nearest feasible point to the wish.

* **Residual + exact Jacobian per constraint type**, by forward-mode AD over the 2-D coordinates of the points a constraint
  touches. Supported (all of the sketch constraint types except spline tangency): distance (linear / horizontal / vertical),
  horizontal, vertical, angle, coincident, concentric, parallel, perpendicular, equal length, tangent, curve tangent, equal
  radius, line distance, point-line distance, collinear, at-midpoint, point-on-line, point-on-circle, point-on-ellipse
  (closed form `|(d·m)/a² , (d·n)/b²| = 1` instead of the backend's trammel auxiliary points); fixed points are the caller's
  `pinned` set. Provisional dimensions count only when the hybrid drag switches them on at the proposal's size, like before.
* **Branch choices** the solver makes at the start (an angle's supplement, the side of a horizontal/vertical dimension) are
  taken from the *last accepted frame*, not from the proposal, so a wish that crosses over is clamped instead of silently
  mirroring the dimension.
* **Continuation walk** (not a one-shot projection - see "what failed first"): pull towards the wish with the minimum-norm
  correction `x += y0 − Aᵀ(AAᵀ+λI)⁻¹(A y0 + r)` (`A = J W⁻¹`), cap the displacement to a trust radius, bring the point back onto
  the manifold with damped Newton correctors, revert and halve the radius if that fails. Therefore the answer is **always a
  feasible point**: a wish beyond a wall (arm out of reach, triangle-inequality violations) lands on the wall, where the old
  engine rejected the frame, and the branch cannot flip.
* **Damping**: along a curved constraint the plain pull overshoots by `1 + wish distance / curvature radius` and zigzags; every
  step must bring the wish closer (else its multiplier is halved), and a slow monotone tail is extrapolated (Aitken, ≤ 8×).
* **Stiffness**: grabbed point and the closed-form proposal are stiff (1), every other point in the group a follower (0.01),
  so corrections land on followers first. Points the proposal moves but no constraint touches (a circle's other cardinal points)
  are not in the group; the controller writes them back as proposed (this was a bug the A/B bench found, see below).
* **Unsupported**: a spline tangency in the dragged group → `unsupported`; the hybrid drag then applies the plain closed form,
  the general path keeps its network fallback (what a platform without a local solver always did).
* Constants are at the top of the file (`kProjector*`).

### What failed first (kept for the record)

1. *Project the wish onto the manifold in one non-convex Newton jump*: 24 of 30 frames of a 6-link arm did not converge.
   Replaced by the continuation above (start from the on-manifold last frame).
2. *Trust-limit the pull vector*: most of the pull is blocked by the constraints anyway, so tangential progress per step was tiny and
   answers stopped short of the nearest point (`horizontal` landed at x = 8.55 instead of 8). Pull fully, cap the *displacement*.
3. *Undamped nearest-point steps*: for a wish more than 2 curvature radii from a circle the iteration has multiplier ≈ −1 and
   zigzags forever (`point on circle`, `tangent`, `equal radius`). Added the "must get closer, else halve" rule.
4. *Follower stiffness 0.1*: a follower's pull back to its old position cost the grabbed point 1 % of its tracking (a corner
   dragged to 9 sat at 8.97). 0.01 → 3×10⁻⁴.
5. *Return only the dragged group*: a circle's other cardinal points stayed frozen while its centre moved. Found by running the
   same path through both engines in lock-step (the "hybrid feel" bench), fixed in `_clampDragFrame`, regression test added.
6. *Warm-starting the step multiplier across frames*: no gain (mean iterations 23.7 → 28.9 at 20 links); backed out.

## Measurements (S10)

Host: x86 Linux container. **Timings in the tables are Dart JIT inside `flutter test`** (not release speed); the AOT column in the
chain table is `dart compile exe` of the same projector. No phone, iOS device or Windows machine was available, so nothing here says
how fast a phone is - on-device timing is still unmeasured. SolveSpace = the real solver through the host build of
`client/native/slvs` (patched fork, as the old engine used it).

### Cost vs sketch size - why the group restriction matters

Drag one corner of a rectangle among N unconnected rectangles (60 frames), mean µs per frame:

| rectangles (points) | SolveSpace (whole sketch each frame) | projector (the group) |
|---|---|---|
| 1 (5) | 467 | 71 |
| 10 (41) | 6 514 | 116 |
| 50 (201) | 71 429 | 404 |
| 100 (401) | **270 663** | 818 |

The solve itself is 5 rows; the remaining ~0.4-0.8 ms is O(sketch) overhead: the projector scans all constraints to find the
group (`projectSketch` alone, AOT: 59 µs / 84 µs / 447 µs / 1.4 ms for 5 / 50 / 500 / 2 000 constraints, i.e. ~1 µs per constraint)
plus the controller copying the point map once per frame. Both could be built once per drag instead of once per frame (the
constraint set does not change during a drag) - see next steps.

### Cost vs coupled size - a chain of N distance-dimensioned links anchored at the origin, tip dragged (120 frames)

| links (points) | SolveSpace mean / max | projector mean / max (JIT) | projector, AOT exe mean / max |
|---|---|---|---|
| 5 (6) | 380 µs / 13.3 ms | 350 µs / 1.9 ms | 0.11 ms / 1.0 ms |
| 20 (21) | 644 µs / 3.2 ms | 1.3 ms / 11.8 ms | 0.66 ms / 5.1 ms |
| 50 (51) | 6.4 ms / 23 ms | 3.9 ms / 12 ms | 3.5 ms / 12.4 ms |
| 100 (101) | 138 ms / 187 ms | 17 ms / 48 ms | 19 ms / 48 ms |
| 200 (201) | 1 502 ms (11 of 120 frames **rejected**) / 2.3 s | 33 ms / 82 ms | 44 ms / 108 ms |

Reading: for small coupled groups the two cost about the same; below ~50 coupled points the projector is comfortably inside a
16 ms frame. **Honest limit**: beyond ~100 *coupled* points the projector is not at frame rate either - it factorises a dense
`AAᵀ` (m × m, O(m³)) every iteration and takes 70-100 iterations per frame in this stress scene. It is still 8-45× faster than the
old engine and never rejects, but a 200-point single constraint web will stutter. See "next steps" for the fix.

### Feel (docs/constrained-drag-smoothness-study.md style metrics)

Definitions: *step ratio* = shown step of the grabbed point / the ideal tip's step; *follower jerk* = max over non-grabbed points
of |step_i − step_(i−1)| (sketch units; the hand's own mean step is given); *tip error* = distance of the shown tip from the exact
answer. For the arm the exact answer is analytic (the cursor clamped to the reach disc). Hand = minimum-jerk segments: in to 0.7
reach, a quarter turn, then out past the reach (the wall) and back.

| links | hand step | engine | tip error mean / max | step ratio max | follower jerk max |
|---|---|---|---|---|---|
| 5 | 0.42 | projector | **0.000 / 0.002** | 1.01 | 1.43 |
| | | SolveSpace | 0.009 / 0.197 | 1.22 | 2.19 |
| 20 | 1.84 | projector | **0.005 / 0.33** | 1.54 | 5.0 |
| | | SolveSpace | 0.220 / 2.23 | 1.03 | 9.4 |
| 50 | 5.4 | projector | 0.37 / 8.6 | 4.1 | 9.1 |
| | | SolveSpace | 3.9 / 34.3 | 1.8 | 8.9 |
| 100 | 10.7 | projector | 26 / 96 | 4.9 | 11.2 |
| | | SolveSpace | 114 / 208 | 24.1 | 21.9 |

(≥ 50 links are not a human hand: 5-10 units per frame is 20-40 % of a link per frame; the lag shown is the walk's trust radius.)
Both engines show *some* follower jerk because the arm is a floppy chain that folds when pulled past reach; neither pops.

A **straight** arm is a bifurcation (the tip cannot move inwards at first order). The projector stays put until the cursor leaves the
axis; SolveSpace jumps to the folded branch (25 → 15 in one frame, a 10-unit pop). This is the "wrong root" behaviour
`docs/constrained-drag-investigation.md` B.2 measured. The bench uses a gently curled arm so it measures ordinary dragging.

### The hybrid shapes: same hand path through both engines in lock-step (150 frames, ring sweep around the dimension's anchor)

(`client/test/sketch_controller_test.dart`, group "hybrid drag feel (bench)")

| scene | projector mean / max µs | SolveSpace mean / max µs | rejected frames (PJ / SS) | follower jerk max (PJ / SS) | per-point deviation PJ vs SS (mean / max) |
|---|---|---|---|---|---|
| hexagon, H edge, vertex | 827 / 7 980 | 9 930 / 30 842 | 0 / 0 | 0.064 / 0.109 | 10.7 / 33.7 (*) |
| arc, start dimensioned | 154 / 2 379 | 176 / 1 130 | 0 / 0 | 0.073 / 0.074 | **0.023 / 0.13** |
| slot, centre dimensioned | 281 / 3 935 | 1 583 / 4 692 | 0 / **4** | 0.135 / **73.3** | 20.6 / 91.8 (*) |
| rectangle, corner dimensioned | 91 / 972 | 118 / 1 498 | 0 / 0 | 0.466 / 0.466 | **0.006 / 0.02** |
| circle, centre dimensioned | 43 / 114 | 72 / 176 | 0 / 0 | 0.128 / 0.129 | **0.018 / 0.05** |

(*) Where the engines disagree, SolveSpace is the one off the design, from the traces: on the hexagon it **translates the whole
polygon** with the cursor (its centre follows) although a vertex drag is specified never to move the centre; on the slot it
**flips branch** (the far end jumps to (57, −34), follower jerk 73, 4 rejected frames) - the documented wrong-root behaviour of
the redundant tangent/equal-radius web. The projector keeps the centre and never flips. Where SolveSpace is well behaved (arc,
rectangle, circle) the two agree to ≤ 0.13.

### Golden cases per constraint type (`client/test/sketch_projector_test.dart`)

One grabbed point, everything else pinned, 21 cases (all supported types). Each is checked against an independent hand-written
residual, against the known nearest point, and - when the host library is built - against SolveSpace:

* 17 of the 21 cases agree with SolveSpace to < 10⁻³: distance (linear/horizontal/vertical), horizontal, vertical, coincident,
  concentric, parallel, equal length, tangent, curve tangent, equal radius, line distance, point-line distance, at-midpoint,
  point-on-line, point-on-circle.
* **angle** and **perpendicular**: SolveSpace returns a feasible but *not nearest* point (where its minimum-norm step in parameter
  space ends up, e.g. (5, 10.78) instead of (5, 9)); the projector returns the nearest. The test asserts feasible and at least as near.
* **point-on-ellipse**: both feasible, the projector's point is nearer to the wish (8.60 vs 8.62 squared distance).
* **collinear**: SolveSpace cannot solve the one-point case at all (redundant); the projector does.

## Round trips (fewer)

* **Per frame**: none while the local clamp answers (unchanged in kind, but now true on Windows/iOS too, which used to PATCH
  every pointer move and `POST /solve` at 8 Hz). `_maybeSolveDuringDrag` + per-frame PATCH remain only as the fallback for a
  frame the projector rejects or cannot model.
* **Drop**: was a sequential `PATCH /points/{id}` for every reflowed point and then the solve. By code reading the old engine
  reported *every* point of the sketch as reflowed (SolveSpace returns all registered points), so a drop on a 400-point sketch was
  ~400 requests. Now: **one** `POST …/solve-and-refresh` whose body carries the wish (`anchor_point_ids` + `point_updates`, only
  the points that actually moved). Backend: `SolveRequest.point_updates`, applied atomically (all-or-nothing, origin refused)
  before the solve; pinned by `backend/tests/test_stage2b_solver_integration.py` and, on the client, by "the drop is one request"
  in the hybrid group. The hybrid undo restores all points the same way (one request instead of N PATCHes + a solve).
* Not changed: `_autoCoincideIfNear` (one request only when the drop lands on a point).

## Mobility oracle (S12, client half)

`analyseSketchMobility` row-reduces the constraint Jacobian at the current positions: rank, DOF of the group, and for every
point 0 / 1 / 2 free directions (+ the direction when it is 1). It is a *rank*, not a structural count, so it reproduces the ground
truth the investigation (B.4) found by probing py-slvs, without probing:

| sketch | truth | oracle | structural `dof_analysis.dart` (per the investigation) |
|---|---|---|---|
| rectangle on the origin, width dimensioned | dof 1; bottom-right corner pinned, top corners slide vertically | dof 1; corner rank 0; top corners rank 1, direction (0, ±1) | calls the corner free |
| fully dimensioned rectangle | dof 0 | dof 0, all rank 0 | agrees |
| floating rectangle | dof 4 | dof 4, all rank 2 | agrees |
| + a redundant `Parallel` | dof 1, the same points slide | dof 1, same ranks | "fully constrained" for movable points |
| 2-link arm | dof 2; joint slides, tip free | joint rank 1 (tangent), tip rank 2 | agrees |

It replaces `isPointFullyPinned` / `rigidity.isPointFullyConstrained` in `beginPointDrag` (the "this point cannot move, refuse the
grab" rule; `test/sketch_drag_gate_test.dart`). Over-constrained detection still comes from the existing flags (rank cannot tell a
redundant from a conflicting row; `residualInf` is exposed for that). Cost: one row reduction per *grab* (a 100-point chain
12 ms AOT; component-restricted). The structural count remains the fallback when the group holds a spline tangency.

## Verification

* `client/test/sketch_projector_test.dart` (58 tests incl. the 21 SolveSpace comparisons when the host library is built, pure Dart, ~1 s; the SolveSpace comparison group skips where the host library
  is not built, as on CI): golden cases, component restriction, pinned points, followers, redundancy, conflicts, provisional
  sizes, spline → unsupported, wall landing, cost bound, mobility oracle.
* `client/test/sketch_controller_test.dart` "hybrid drag": the seven shape families now run on **both** engines; on CI only the
  projector half runs. Plus "the drop is one request".
* Whole client suite on this branch: **2 616 passed, 0 failed, 23 skipped** (the env-gated benches and older opt-in skips; the host-library groups ran, the library was built here); `flutter analyze` at the
  baseline count (179, all pre-existing Flutter-master deprecations).
* Backend: `test_stage2b_solver_integration`, `test_stage15_constraints`, `test_stage16_arc`: 130 passed. (The full ~30 minute backend
  suite was not run; only the sketch API files this change touches.)
* Five older controller tests assumed "no local solver ⇒ the drag goes over the network". They were updated, not weakened:
  three prove "the closed form did not run" via `dragStats.frames` instead of "the sibling point stayed put" (the general path now
  legitimately reflows siblings); two force the network fallback with a constraint the projector cannot model (spline tangency).

### Not verified / honest gaps

* **No device**: nothing was run on a phone, an iOS device, Windows, or in the real UI. Timings are x86 JIT/AOT in a container.
* Real-backend end-to-end drag (HTTP, not the fake) was not run; the backend change is covered by TestClient tests.
* Spline-tangent groups are not clamped locally (unchanged from "no local solver" behaviour).
* The first-order mobility oracle says nothing about a configuration that is momentarily singular (e.g. a perfectly straight arm).

## Reproduce

```
# unit + golden + gate + controller (pure Dart; SolveSpace comparisons skip without the host library)
cd client && flutter test test/sketch_projector_test.dart test/sketch_drag_gate_test.dart test/sketch_controller_test.dart

# reference engine (test only): needs cmake + g++
git submodule update --init client/native/slvs/vendor
git -C client/native/slvs/vendor apply ../patches/0001-system-solve-dragged-params.patch
cmake -B /tmp/slvs/vendor -S client/native/slvs/vendor -DBUILD_PYTHON=OFF -DENABLE_GUI=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/slvs/vendor --target slvs_static
cmake -B /tmp/slvs/shim -S client/native/slvs -DSLVS_VENDOR_BUILD_DIR=/tmp/slvs/vendor && cmake --build /tmp/slvs/shim
mkdir -p client/native/slvs/build-host && cp /tmp/slvs/shim/libdidsa_slvs_ffi.so client/native/slvs/build-host/
git -C client/native/slvs/vendor apply -R ../patches/0001-system-solve-dragged-params.patch   # keep the submodule clean

# the tables above
cd client && DIDSA_SKETCH_BENCH=1 flutter test test/sketch_drag_bench_test.dart
DIDSA_SKETCH_BENCH=1 flutter test test/sketch_controller_test.dart --plain-name "hybrid drag feel"
DIDSA_ARM_TRACE=20 DIDSA_SKETCH_BENCH=1 flutter test test/sketch_drag_bench_test.dart --plain-name arm   # per-frame trace
```

## Next steps (proposals, in the order I would do them)

1. **Merge-readiness**: the branch changes the drag gate, the drop protocol and the backend `SolveRequest`; a human should drive a
   few real drags on a device (hexagon with a horizontal edge, slot with a dimension, rectangle, a chain with a wall) before
   merging. Remove `client/android/.gitignore`'s and `client-verify.yml`'s stale `didsa_slvs_ffi` comments and decide whether
   `client/native/slvs` stays in the repo as test tooling (it must not be built into releases; the submodule is GPL).
2. **Scale beyond ~100 coupled points**: (a) factor `AAᵀ` as a sparse/banded Cholesky with reverse Cuthill-McKee (a chain becomes
   O(m)); (b) reuse the factorisation for the correctors of one walking step (chord method, 3-6 factorisations → 1); (c) stop
   building the constraint index and copying the point map once per drag instead of once per frame (the 0.4-0.8 ms floor on the 100-rectangle grid). Together I expect the 100-link case under
   5 ms; not measured.
3. **Smoothing**: nothing measured needs it yet - no pops, follower jerk at or below SolveSpace's everywhere, tip error ≤ 0.33
   up to 20 links. If on-device feel asks for more, the cheap options are (i) a critically-damped low-pass on *followers only*
   (never the grabbed point, so tracking is untouched), (ii) a per-frame cap on follower speed, (iii) carrying the Aitken ratio
   between frames. I would not add any before a human reports a problem. The remaining roughness is lag-then-catch-up at the wall
   when the hand moves > 20 % of a link per frame.
4. **S12, backend half**: expose the rank-based DOF (the oracle's `dof`) as the authoritative per-component number for the padlock
   and colouring instead of py-slvs' `Dof` (+ floors), which the investigation measured as wrong for the slot (1 vs 5); keep the
   existing over-constrained flags. The mobility *direction* is available for an axis-lock cursor if the owner ever wants one
   (he said no extra feedback, so not built).
5. **S11 leftovers**: route frames the projector rejects through the same guards on the network fallback (`_solveDuringDrag`
   still applies unguarded frames); with the projector everywhere that path is now rare (spline groups, non-convergence).
6. **Spline tangency** residual (cubic-segment end tangents) to take the last constraint type off the network path.
7. **Run the SolveSpace reference tests in CI?** Not done (no CI changes, per the owner). They are cheap to run locally with the
   recipe above.
