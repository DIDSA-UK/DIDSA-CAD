# Constrained drag: smoothness on multi-part assemblies with variable DOF

Companion to `constrained-drag-implementation-plan.md` (F1 gate). Measured against the REAL backend (OCCT + py-slvs) through the
real `ConstrainedDragSession`; reproduce with `tools/motion_smoothness/` + `client/test/constrained_drag_smoothness_test.dart`
(env-gated, see its header). Numbers are weighted mm (`[1,1,1,L,L,L]`, L≈10) per 60 Hz frame unless stated.

## Method
* **Scenes** (`backend/tests/motion_scenes.py`), each in two variants — *floating* (nothing fixed) and *fixed* (the `base` part fixed):
  * `bolt`: plate with a hole + bolt (concentric + coincident). Floating DOF 7, plate fixed → 1 (spin).
  * `hinge`: two leaves (plates with holes) + a pin through both (3 parts: pin concentric to each hole, leaf faces coincident).
    Floating DOF 9, leaf A fixed → 3 (leaf B swings about the pin, the pin spins/slides).
* **Hand**: minimum-jerk paths, 90 frames, real clock: rotations 120° about x/y/z, a 60° diagonal, translations 40 mm, a
  12 mm out-and-back radial pull, a 25 mm circle, and a 180° flick in a third of the time. The mover is the second part
  (bolt / leaf B); nothing is committed, every path starts from the same state.
* **Ground truth**: the exact backend answer to the same wish each frame. **Metrics**: step ratio (shown step / hand step),
  **jerk** (|step_i − step_(i−1)|, pops show up here; the hand's own is ≈ 0.015–0.2), rejected anchors / holds.

## Findings
1. **The grabbed part is perfectly smooth whenever its wish is a free motion** — every free rotation/translation, floating or
   fixed: step ratio 1.00, tracking error 0, jerk = the hand's own. Blocked directions give exactly 0 motion (the wall is clean).
   Request budget: ≈ 1 per 150 ms as designed.
2. **Followers in floating groups popped** (the multi-part, variable-DOF problem). Follower jerk up to **40.7** (hinge, 120° about
   x) and 2–3 on the bolt, against a hand jerk of 0.015: at every re-anchor the plate/pin jumped. Cause: the backend always solved
   "nearest to the STORED (grab-time) pose", while the client re-bases its projection at every accepted anchor; the freedoms
   nothing pins down (a follower's spin about the hole axis, a pin's slide) were therefore re-chosen at each anchor.
   **Fix (contract field `reference`, client default on):** the request carries the poses the client last accepted and the solve
   measures "nearest" from them — the standard incremental/warm-started solve. Follower jerk **40.7 → 0.07**, 19.1 → 0.05,
   bolt 2.1 → 0.06, 2.8 → 0.05; flick 3.0 → 0.85–1.3; grabbed part unchanged. (The follower "error vs truth" column of the raw
   rows is not meaningful for followers: the truth is solved from the stored pose, a different but equally valid choice of the free freedoms.)
3. **Off-manifold wishes on CURVED mates with one part fixed are still the weak spot** (hinge leaf B, leaf A fixed): turning the
   leaf about its own origin 120° (the mate only allows turning about the pin axis) gave step ratio 1.86, 11 of 30 anchors
   rejected (`jump`) and a hold; a 40 mm translation gave ratio 1.5 and 9 mm off the exact nearest point; a 25 mm circle
   ratio 1.0 but 11 mm error and a reject. This is F1: the tangent-space projection + screw exponential is a first-order
   model, so a wish far from the manifold is projected to a different point than the true nearest one, and the anchor then
   disagrees. Warm start does not change it (the gap is within one anchor interval). Ring drags are immune (S8 re-pivots
   the ring onto the screw axis: the wish is on the manifold, 0.472 = 0.472); translate handles on a hinged part are not.
4. **Walls with a huge wish are noisy**: a 180° flick against a fully constrained bolt (or hinge leaf) shows 11–16 rejected anchors
   and a "can't follow that move" cue although the part correctly stays put — the backend's nearest solution is another branch
   far from the (zero-motion) projection, which the jump test rejects.

## What the industry does, and are we on the right track?
Public descriptions of how mainstream assembly CAD does direct manipulation (SolidWorks / Inventor / NX / Solid Edge / Onshape
via the Siemens D-Cubed 3D DCM, Parasolid-based kernels, Fusion, Creo) and the robotics / real-time-physics literature agree on
the shape (vendor internals are not published in detail, so treat the specifics as the commonly documented approach):
* a **nonlinear geometric-constraint solve every pointer move, in-process**, Newton-type with damping (Levenberg–Marquardt /
  damped least squares) on the rigid-body variables, the pointer target treated as a **soft, minimal-motion objective** on
  the dragged body; **warm-started from the previous frame's solution** (continuity, branch tracking, no re-picking of free freedoms);
* **decomposition**: rigidly connected parts merged into clusters, independent sub-systems solved separately, only the
  connected component of the dragged part solved; DOF/rank analysis by Jacobian SVD (or graph analysis) with tolerance;
* **velocity/tangent-space projection** (pseudo-inverse, null-space projection) as the predictor, then re-projection onto the
  constraint manifold (retraction) — what robotics calls constrained motion / IK with null-space; physics modes use
  constraint-force/impulse solvers (PGS/LCP) or position-based dynamics instead;
* for **networked / remote** simulation: client-side prediction with server reconciliation and error smoothing.

Our design is the last two lines of that list built on the first: tangent projection (S6) + backend retraction (S2/S3), min-motion
weights with followers following, component-wise group solve (S1/S2), rank-based DOF with hysteresis (spec §10), prediction
+ reconciliation + blend (spec §9). **Yes — the architecture is the standard one. Two gaps against the standard**:
1. *Warm start* — was missing, is now added (`reference`), and it was the larger of the two smoothness problems.
2. *No in-process solve* — the industry runs the solver locally every frame; we run it remotely every ~150 ms and extrapolate
   with a first-order projection in between. That extrapolation is what limits curved mates (finding 3) and is what F1 would
   patch with a damped nearest-point refinement.

## Recommendation for the F1 gate
* Keep warm start (done). Keep S8's re-pivoted rings (they remove the curved-mate problem for the rotate handles).
* **Do not spend F1a on refining the projection.** Finding 3/4 are the symptoms of extrapolating with a first-order model;
  the standard remedy is to make the in-between solve exact. Instead make F1a evaluate a **client-side constraint model**: the
  anchor response already has the member poses and the free-motion basis; add the resolved mate geometry (per mate: type,
  value, flipped, and the two sides' plane/axis/point in the owning occurrence's local frame — a few floats), and run the same
  damped Gauss–Newton retraction in Dart/GDScript each frame for the ≤ 8-body groups (analytic Jacobians for plane/axis/point
  residuals; cost ≈ 0.1–1 ms, the backend measured 1.8 ms at k = 1 and is dominated by finite-difference Jacobians). The
  backend stays the authority (anchors, commit, DOF), the local solve replaces projection+blend between anchors. This removes
  the F1 refinement, most of the F2 re-anchor cost and the "can't follow" noise at walls, and is how the desktop products behave.
  Cost: a second implementation of the mate residuals in two client languages, pinned by golden vectors like the projector.
* Cheap, independent: soften the wall noise (don't count a `jump` rejection as a miss when the projection says the wish is blocked).

## F1b addendum: local nearest-point retraction (2026-10-01)

Same scenes, paths and real backend as above, `reference` on, 90 frames, drag through the real `ConstrainedDragSession`; **off** = projector only,
**on** = the F1b local retraction (`DIDSA_SMOOTH_LOCAL=0|1`). Weighted mm; `errG` = max distance of the shown grabbed pose from the exact answer.

| scene / variant / path | step ratio off > on | jerk grabbed off > on | errG max off > on |
|---|---|---|---|
| hinge fixed, translate x 40 mm | 1.37 > 1.26 | 0.104 > 0.038 | **4.34 > 0.29** |
| hinge fixed, radial out/back 12 mm | 0.98 > 1.08 | 0.021 > 0.016 | **1.15 > 0.007** |
| hinge fixed, rot z 120 deg (off-manifold turn) | 1.14 > 0.36 | 0.029 > 0.005 | 1.80 > 1.27 |
| hinge fixed, circle 25 mm (re-run after the guard fix) | 1.05 > 1.08 | 2.39 > 2.74 | **12.78 > 2.73** |
| bolt / hinge floating, all 9 paths | 1.0 > 1.0 | unchanged (0.007-0.2 = the hand's own) | ~0 > <= 0.17 |
| walls (rot x flick 180 against a fully fixed part) | 0 > 0 | 0 > 0 | unchanged, still 12-23 rejected anchors |

Reading: the curved-mate weak spot of finding 3 is largely gone (tracking error 4.3 > 0.29, 1.15 > 0.007, 12.8 > 2.7; the 120 deg off-manifold
turn no longer outruns the hand: ratio 1.14 > 0.36). Everything that was already smooth is unchanged. NOT fixed: the circle path's
jerk (still two rejected anchors and a hold: the backend's anchor and the displayed pose disagree about a far wish) and the wall noise of finding 4 (12-23
rejected anchors on a 180 deg flick against a fully fixed part - the local solve is not involved there). The first run of the circle path was WORSE (ratio 2.59,
jerk 7.1, 12 local fallbacks): the guard compared the local answer with the projector's within 0.5 L, but on a curved mate with a far wish the projector is the
one that is off; the guard now scales with the hand's distance (spec s4b.1) and the fallbacks are 0.
