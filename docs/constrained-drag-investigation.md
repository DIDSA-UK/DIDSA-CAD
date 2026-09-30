# Constrained drag across DIDSA-CAD — investigation

*Read-only investigation. No product code was changed. Prototypes live in
[`docs/constrained-drag-investigation/prototypes/`](constrained-drag-investigation/prototypes/)
(scratch code, re-runnable; raw outputs in
[`.../results/`](constrained-drag-investigation/results/)).*

**Question.** VR's "ask the solver once how a part may move, then apply the
user's motion locally, re-anchor occasionally" technique (backend
`mate-motion` + `free_twists`; VR `project_motion()` / `weighted_basis()` /
`_drag_loop()`) — can it push out across the whole tool set, and can our flat
app improve on what it does today?

---

## 0. Answers in one page

1. **Assemblies are the big win, and the flat app is further behind than
   expected.** During a gizmo drag the flat app sends **nothing** and shows
   the **raw gizmo pose**; on release it sends **one PATCH + 4 refresh GETs** —
   and it **never re-solves the mates**. A mated occurrence can be dragged
   straight off its mates and the violating pose is stored (measured: mate
   wants `z = 10`, stored `z = 40`). The code and docs *say* a solve should
   follow the drag (`solve_for_occurrence` docstring, `DocumentApiClient.
   solveForOccurrence` doc comment, original "gizmo clamped by mates" brief) —
   it was never wired. So the flat app has **no** live constraint feedback at all
   today: not "blocked along the constrained direction", not even a snap on release.
2. **The technique works, with real numbers.** Replaying identical 2-second hand
   paths on real mated occurrences against a real backend (every frame solved for
   real; network timeline simulated): flat mates (face-to-face) are followed
   **exactly** with **1–14 requests instead of 120–240**, zero constraint violation,
   no jerk — at any RTT. Curved mates need care (§A.5): with VR's current
   projector (additive first-order step, fixed 100 mm lever arm, backend re-anchor
   in the solver's own metric) a large wish on an offset-axis concentric mate leaves
   up to **5 mm** of visible mate violation and a **2 mm pop** at each re-anchor.
   Three small changes remove that (all prototyped): **screw (exponential-map)
   integration** on the client (violation → 0.000 mm even with *no* re-anchoring for
   screw-type freedoms), **lever arm = the part's bounding radius** instead of 100 mm,
   and a **weighted retraction on the backend** so the client and server agree on
   what "nearest" means (max frame step ≤ hand step, i.e. no pops).
3. **It does NOT solve multi-body.** Measured: with `C` resting on `B` and `B`
   concentric on a peg, dragging `B` along the peg is **blocked** (DOF 1: spin only)
   because the solver drives one occurrence against *frozen* peers; `C` never
   follows. A group model (variables = several occurrences, stacked Jacobian,
   grabbed body weighted 1, followers ≈ 0) fixes it in a toy check (§A.5, §E.6) —
   this needs a backend `driven_ids` extension, not just client work.
4. **2D sketch: the technique is mostly redundant where the local solver exists,
   and valuable where it doesn't.** Solving is in-process (py-slvs via FFI) **only on
   Android arm64** (prebuilt `.so`, manually built, `loadSlvsBindings()` only knows the
   Android library name). Windows/iOS (inferred, §1) fall back to the backend: **1 unawaited PATCH per
   pointer-move + a throttled (120 ms) POST /solve + GET /points** (measured: 115 requests
   for a 1.5 s drag, un-dragged geometry reflows at 8 Hz — visible steps of up to 6–13
   sketch units). A nullspace basis is *not* useful as a per-frame smoother where the
   local solver runs; it **is** useful as (a) a **mobility oracle** (exact per-point
   "pinned / slides along a line / free", drag-axis direction) that fixes real
   disagreements between the structural `dof_analysis.dart` count and the truth, and
   (b) a **drag-map** (2 probe solves at grab time → linear reflow of the whole sketch)
   for platforms with no local solver or sketches too big to solve per frame.
5. **A nullspace can be computed for sketches with the *public* py-slvs API.**
   Prototype (perturb one coordinate, re-solve with everything free, read the response;
   SolveSpace takes minimum-norm Newton steps so the response is the first-order projector
   onto the tangent space): the probe's rank equals py-slvs' `Dof` **and** the hand-derived truth on all five
   well-posed sketches, and it is **right where py-slvs is wrong**: the Slot (py-slvs `dof = 1`,
   from the provisional floor; probe and truth 5). It also exposes the redundant-`Parallel` case
   the structural analysis calls "fully constrained" (probe rank 1, Dart says "fully"). **Cost:**
   2 solves per coordinate (full nullspace) — fine to ~50 points (≈ 0.1 s), impractical
   beyond (≈ 68 s extrapolated at 500 points); the *drag-map* needs only 2. **Limit:**
   redundant Tangent/EqualRadius webs (Slot) make individual probes land on a *different
   root* while reporting `converged` — the same failure class the client's guards
   (blow-up / arc chord-side / residual) exist for; a black-box probe cannot be trusted
   there without those guards, or an analytic Jacobian.
6. **3D sketch: there is no true 3D sketch.** "Plane-embedded 3D sketching" (Orbit
   View) is the same 2D `SketchController` + 2D solver; the 3D viewport only maps a ray
   to the sketch plane. So sketch findings (§B) apply 1:1 to it. A true 3D sketch would
   need 3-param points and free-3D constraints — py-slvs supports both (the assembly
   solver already uses free-3D) and the probe route worked on toy 3D sketches — but
   nothing in the app models it.
7. **Recommendation** (§G): (0) wire the missing post-drag solve + merge `mate-motion`;
   (1) client projector upgrades (screw integration, adaptive lever arm, pop blending) in
   *both* Dart and GDScript from one spec; (2) live constrained component drag in the flat
   app with gizmo handles greyed by their measured freedom; (3) backend weighted
   retraction + group (`driven_ids`) `mate-motion`; (4) sketch mobility oracle, and a
   decision on shipping the local solver to Windows before building a sketch drag-map.

---

## 1. What was verified by running vs inferred

| Claim class | How established |
|---|---|
| Flat-app request counts / what is stored / latency | **Ran**: a real backend (branch `ccr-5fcefc91-t2tc6f` in a micromamba-equivalent env at `/opt/sdks/micromamba_root/envs/didsa-backend`, py-slvs 1.0.6, pythonocc 7.9.3), real HTTP replay of the exact call sequence the Dart code issues (call sequence itself **read from code**). |
| "During a gizmo drag nothing is sent / raw pose is shown" | **Read from code** (`_updateComponentGizmoDrag` → `onComponentGizmoDragUpdate` → `setState(_gizmoLiveTransform)`); no Flutter runtime. |
| Strategy comparison (per-frame solve vs local projection) | **Ran**: real `mate-motion` solve for **every one of 120 frames × 3 mate types** against the real backend; the *network timeline* (RTT 0/50/150/400 ms, one request in flight, frame-quantised) is **simulated** offline on top of those real answers. The projector is a numpy transcription of `project_motion()`/`weighted_basis()`. |
| Backend `mate-motion` correctness | **Ran** `backend/tests/test_assembly_solver.py` on the motion branch: **33 passed**. |
| Sketch DOF/nullspace | **Ran** on 8 sketches built with the backend's own `Sketch` model (library import, unmodified); py-slvs `dof` from `solve_sketch`; structural verdict from the **real `dof_analysis.dart`** run under Dart 3.14 (`SketchRigidity.analyze`). |
| Sketch backend-fallback drag stream | **Ran** over HTTP on a 3-point arm (call pattern read from `updatePointDrag`/`_maybeSolveDuringDrag`). |
| Solve cost vs size | **Ran** (x86 Xeon 2.1 GHz, pure py-slvs, no Dart/FFI). |
| Local FFI solver behaviour (`solveDragged` soft drag), Android timings, Windows/iOS solver availability | **Not run.** The vendored SolveSpace fork (`client/native/slvs/vendor`) is an empty submodule here and the pip wheel's `System.solve()` does not expose `dragged[]`. Windows/iOS unavailability is **inferred** from `loadSlvsBindings()` + no CMake/Gradle/Pods reference. |
| VR code paths, `project_motion` behaviour | **Read** on branch `ccr-5fcefc91-t2tc6f`; Godot is not installed so VR tests were **not run** (the projector math was ported to numpy and exercised instead). |
| Multi-body, 3D sketch, weighted retraction, group projection | **Toy prototypes** with hand-written residuals (flagged where used); not validated against a real backend implementation. |
| On-device / real-network timings | **Not measurable here** — see §H for how to measure. |

All timings are localhost on a 4-vCPU x86 box: they are *relative* evidence and
lower bounds, not phone numbers.

---

## A. Assemblies (flat app)

### A.0 Current path — map

```
pointer-down on a gizmo handle
  part_viewport.dart:3418  _tryBeginComponentGizmoDrag   (ray vs 3 arrows + 3 rings; freezes axis/start ray/start transform)
pointer-move
  part_viewport.dart:3501  _updateComponentGizmoDrag     (translate: closestPointOnLineToRay delta; rotate: angleOnRotationPlane delta,
                                                          composeRotation(q_delta * q_current); ALWAYS absolute-from-drag-start)
  → widget.onComponentGizmoDragUpdate(RigidTransformDto)
  part_screen.dart:10251   _onComponentGizmoDragUpdate   setState(() => _gizmoLiveTransform = liveTransform)   ← NO network
  part_screen.dart:767     _gizmoDisplayTransform        = _gizmoLiveTransform ?? _gizmoTargetWorldTransform  (drives render + gizmo)
pointer-up
  part_screen.dart:10296   _onComponentGizmoDragEnd      world→local (localRigidTransformRelativeTo) →
      api.updateOccurrenceTransform          PATCH  /parts/{p}/occurrences/{o}     (document_api_client.dart:4799)
      _refreshAssemblyTree                   GET occurrences + GET mates + GET component-patterns   (part_screen.dart:10182)
      _refreshAssemblyMesh                   GET assembly-mesh                                     (part_screen.dart:10234)
      _componentTransformUndoStack.add(previous)
typed Move/Rotate panel "Apply"
  part_screen.dart:10387   _applyGizmoWorldTransform     same PATCH + 4 GETs
backend
  router.py:3503  update_occurrence_transform            whole-value replace; 422 if fixed; NO solve, NO mate check
  router.py:4056  solve_for_occurrence                   solve_occurrence(): occurrence's transform is the seed; 422 if not converged
callers of solveForOccurrence in the flat client:  _confirmMate (part_screen.dart:3680), edit-mate save (:20960), AI plan translator.  NOT the gizmo.
```

* The **gizmo is a pure pose manipulator** (`component_gizmo.dart`): 3 translate arrows
  + 3 rotate rings, axes = the occurrence's *current* local frame, sized from
  `kComponentGizmoSizeFraction × boundingRadius`. It knows nothing about mates.
* There is **no direct body drag** for components: the only pointer-drag handlers in
  `PartViewport` are `_tryBeginSectionGizmoDrag` (3253) and `_tryBeginComponentGizmoDrag` (3418).
* The mate **ghost preview** (`_scheduleMatePreview`, part_screen.dart:3595) already uses a
  *"wanted → nearest solution, store nothing"* endpoint (`preview-mate-solve`), request-token
  guarded — but only on discrete UI changes, never per frame.
* **Doc/code drift found.** `router.py` `solve_for_occurrence`'s docstring says the client
  calls it "immediately afterward *only* when that Occurrence actually has Mates — giving the
  'move/rotate triad gizmo clamped by mates' behavior from the original brief";
  `document_api_client.dart:5017` says the same. `git log -S solveForOccurrence` shows it was
  added with mate authoring (c78d52a) and never for the gizmo. `docs/assembly-scope.md:7`
  still lists "gizmo clamped by mates" as scope.

### A.1 What is sent, how often, what the user sees — measured

Replay (real backend, localhost) of one gizmo drag on a face-mated bracket, lifted 30 units along
its local Z (`a1_current_flow.py`):

| Phase | Requests | Notes |
|---|---|---|
| During the drag (60 pointer-moves in 1 s) | **0** | display = raw gizmo pose |
| On release | **5**: PATCH (1.9–3.2 ms) + GET occurrences (1.5–1.8) + GET mates (1.6–1.9) + GET component-patterns (1.6) + GET assembly-mesh (9.0–9.3 ms, 4.7 kB) | 16–17 ms total on localhost (tiny scene) |
| Stored transform afterwards | `z = 40.0` | mate demands `z = 10.0`; `mate-motion(from stored)` says nearest satisfying pose is `z = 10.0`. **Nothing re-solves.** |

Per-endpoint cost on this box (`a_latency.py`, n = 60 each, 3 mate types): PATCH ≈ 2 ms,
PATCH + POST /solve pair ≈ 5.3–5.8 ms, **POST /mate-motion ≈ 3.5–3.8 ms**, GET occurrences
≈ 1.7 ms, GET assembly-mesh 8–11 ms. (Boxes/cylinders only: solve cost on real face geometry
was not measured.)

### A.2 Partially constrained parts today

**No.** A user cannot feel a free direction vs a blocked one, live or after release. Every
handle drags freely (all 6 always drawn at full colour), the raw pose is shown, the raw pose is
saved, and the mates are silently violated until the user edits a mate (which triggers a solve)
or the AI pipeline solves. Undo restores the *previous raw* pose.

### A.3 Would the approach help? Where it would / would not

**Where it helps (measured, §A.5):** live constrained drag (free directions 1:1, forbidden
directions dropped) with one request at grab time plus re-anchors; and the minimum fix — one
`/solve` (or `mate-motion` + PATCH) at drag end — which at least stops storing violating poses.

**Where it does not, or needs more:**

| Case | Finding |
|---|---|
| **Rotation gizmo** | Rings rotate about the occurrence *origin*; a mated freedom is often a screw about an axis *elsewhere* (concentric with an offset axis: free twist = slide + spin about the axis). Projecting a pure origin-rotation onto the free subspace works to first order but the true motion also translates. The gizmo pivot should move to the free axis (or the drag should be defined on the free twist, not the ring). |
| **Large moves on curved manifolds** | First-order error grows with the step. Measured in §A.5. Fixable client-side (screw integration) + re-anchor. |
| **Several mated occurrences dragging each other** | **Not fixable client-side.** The solver drives ONE occurrence against peers frozen at their stored transforms. Measured: peg ← `B` (concentric) ← `C` (face on `B`): `mate-motion(B, wish +12 along peg)` returns `dof = 1`, free twist = spin only, `B` stays at `z = 5`; `PATCH+solve` likewise; `C` never follows (`a_chain.py`). |
| **Angle mate from a singular start** | `ANGLE` never converged from an identity orientation (normals exactly (anti)parallel — derivative of cos(angle) is zero) for any of 30/60/90/150° (`a_angle_singular.py`); from a 45° tilt it converges (dof 5). `mate-motion` then returns `converged:false, dof:6, free_twists:[]` — a client must treat that as "keep the last model", not "6 free". |
| **`flip`/branch** | For a face mate, `flip 179°` and `181°` about X both snap to the unflipped solution; a spin of 190° is kept (`a_extreme.py`). The seed fix (keep current rotation) works as intended. |
| **Inequality/limit mates** | None exist (`MateType` = coincident, concentric, parallel, distance, angle; "limit" out of scope), so there is no active-set discontinuity today. |

### A.4 Gizmo from the DOF basis (Q A.4)

Yes, cheaply. For each gizmo handle compute its **free fraction** =
‖P·twist‖/‖twist‖ where P projects onto the (L-weighted) free subspace at the current pose. Measured
(`a_gizmo.py`, L = 100 mm):

| Mate | dof | move X | move Y | move Z | rot X | rot Y | rot Z |
|---|---|---|---|---|---|---|---|
| face-to-face coincident | 3 | **1.00** | **1.00** | 0.00 | 0.00 | 0.00 | **1.00** |
| concentric, offset axis | 2 | 0.00 | 0.15 | **1.00** | 0.00 | 0.00 | 0.99* |
| angle 60° | 5 | 1.00 | 1.00 | 1.00 | 0.00 | **1.00** | **1.00** |

\* rot-Z is "0.99 free" but *not actually free about the origin* — the free motion is a screw
about the axis at x = 15. So a fraction alone is insufficient for offset axes: the gizmo should
also **re-pivot** onto the screw axis (derivable from the twist: for a rotation-dominant twist
`(v, w)`, pivot = `w × v / |w|²` in the spatial form).

UI consequences: draw locked handles greyed/short (fraction < ~0.1), partial ones dimmed; snap a
translate drag onto the free subspace (projection, not a hard clamp); for `dof = 0` hide the
gizmo and say why; for `dof = 2/3` in-plane, offer a **2-D plane handle** (the free plane) rather
than three axis arrows. The free basis is metric-dependent (translation vs rotation), so this
needs the same lever-arm decision as the projector (§E.4).

### A.5 Measured comparison of drag strategies (real solves, simulated network)

Setup (`a_strategies.py`, `a_strategies2.py`): 120-frame (2 s @ 60 fps) hand paths that
deliberately include out-of-plane wobble/tilt (the "hand tremor" a constraint should remove).
"Violation" = an **independent geometric residual of the *displayed* pose** (plane distance/normal
for the face mate, axis offset/angle for the concentric mate, normal-angle for the angle mate) — not
the solver's opinion.

**(i) Requests and smoothness** (face mate; other mates identical in request count):

| Strategy | RTT 0 | RTT 50 ms | RTT 150 ms | RTT 400 ms |
|---|---|---|---|---|
| Flat app **today** (raw, no solve) | 0 req, **violation mean 1.84 mm / 1.94°, max 5.6 mm / 5.5°** | same | same | same |
| PATCH + solve per round trip (VR v1) | 240 req | 36 req, frozen 103/120 frames, largest display step 3.2 mm / 5.3° | 14 req, frozen 114/120, step 8.4 mm / 14° | 6 req, frozen 118/120, step 13 mm / 22° |
| `mate-motion` per round trip | 120 req | 30 req, frozen 91/120 | 12 req, frozen 109/120, step 4.5 mm / 7.5° | 5 req, frozen 116/120, step 11 mm / 19° |
| **Local projection, anchor once** | **1 req** | 1 req, frozen 3 | 1 req, frozen 9 | 1 req, frozen 24 (the initial round trip) |
| **Local projection + 150 ms re-anchor** (VR) | 14 req | 14 req | 12 req | 5 req |

("Frozen" = frames where the display did not change although the hand did. The residual 3/9/24
frozen frames for the local model are exactly the first round trip, which every model pays once
at grab time.) For flat mates (exact model) the re-anchor buys nothing: **one request per drag**
gives zero violation at every RTT.

**(ii) Curved mates** — constraint violation of what is shown, real solver answers, RTT ≈ 0, re-anchor every 9 frames:

| Mate / wish | Today (raw) | Local, anchor once | Local + 150 ms re-anchor (VR) | Solver per frame |
|---|---|---|---|---|
| Concentric, axis 15 mm off origin; **90°** spin wish, L = 100 | mean 11.3 mm, max 21.2 mm | mean 6.3, **max 16.6 mm** | mean 2.4, **max 5.3 mm; 2.1 mm pop per re-anchor** (wish step 0.8) | 0 |
| same, **30°** spin wish | mean 4.4, max 7.8 mm | mean 0.73, max 1.95 mm | mean 0.63, max 1.56 mm | 0 |
| Angle-60° cone; 35° about Y + 50° about Z | 4.35° mean / 8.97° max | 3.28° mean / **8.68° max** | **0.02° mean / 0.11° max** | 0 |
| Face-to-face | see (i) | 0 | 0 | 0 |

So VR's claim "corrects curvature drift without a visible jump" holds for planar and cone-type
mates but **not** for a screw about an off-origin axis under a large wish: there the anchor error
is bounded only by the re-anchor rate and each re-anchor pops (the solver's "nearest" is measured
in its own parameter metric, the projector's in a 100 mm lever-arm metric — see the sweep below).

**(iii) Three client/backend changes, all prototyped** (`a_screw.py`, `e_weighted_retraction.py`):

| Variant (offset-axis concentric, 90° wish) | L | Violation mean / max | Max frame step (hand step 0.81) |
|---|---|---|---|
| VR today: additive twist, solver-nearest re-anchor | 100 | 2.33 / 5.12 mm | 2.10 mm |
| VR today, no re-anchor | 100 | 6.29 / 16.57 mm | 0.36 |
| additive, **L = 10** | 10 | 0.15 / 0.64 mm | 0.69 |
| **screw (exponential-map) integration**, solver-nearest re-anchor | 100 or 10 | **0.000 / 0.000 mm** | 0.35 / 0.59 |
| **screw, no re-anchor at all** | 100 or 10 | **0.000 / 0.001 mm** | 0.36 |
| additive + **weighted backend retraction** (toy) | 100 / 10 | 0.03 / 0.18 mm; 0.23 / 1.04 mm | **0.41 / 0.91** (≈ hand step; no pops) |
| screw + weighted backend retraction (toy) | 100 / 10 | **0.000 / 0.000** | 0.36 / 0.70 (≤ hand step) |
| Angle cone, either integrator | – | 0.017° / 0.084° (with re-anchor); 3.28° / 8.68° (without) | – |

* **Screw integration** treats the allowed twist as a constant *spatial* screw (`t' = exp(w)·t + V(w)·(v − w×t)`,
  `R' = exp(w)·R`) instead of "add `v`, compose `exp(w)`". It is exact for every group-orbit
  freedom (slide + spin about any axis, hinge, in-plane translate + spin) — which is most mates.
  It does *not* fix genuinely non-group manifolds (the angle cone): there re-anchoring stays
  necessary, and the 0.084° residual is what a 150 ms re-anchor leaves.
* **Lever arm sweep** (mean distance from solver's nearest pose, then violation): L = 1 →
  4.3 mm/16.6°, **L = 10 → 1.7 mm/6.6° (best)**, L = 100 → 6.9 mm/26.4°, L = 1000 → 7.2 mm/27.3°. The
  metric mismatch between "solver-nearest" and the projector is what produces the pops; a
  constant 100 mm is right only for ~100 mm parts. **Use the moving part's bounding radius**
  (the flat app already has it: `_gizmoTargetBoundingRadius`; VR can take it from the mesh AABB).
* **Weighted retraction on the backend** (Gauss–Newton with `W = diag(1,1,1,L,L,L)`, using the same
  residual vector `_mate_residual_vector` that `_free_motion` already differentiates) makes the
  server's "nearest" the client's "nearest": no pops (frame step ≈ hand step), and it converges to machine-exact
  feasibility instead of py-slvs' tolerance. (Prototype uses hand-written concentric residuals;
  the real function exists at `assembly_solver._mate_residual_vector` — porting is a small step.)

---

## B. 2D sketch

### B.0 Current path — map

```
sketch_canvas.dart:608  _handleDragModeTap / sketch_screen.dart:~1790 _handleEmbeddedDrawOrDragCommit    (tap-to-grab, cursor moves, tap-to-drop)
   → dragGrabTargetAt (5094) → beginPointDrag (6524) | beginLineDrag (7181) | textResizeHandle… | label drag (7964 _draggingLabelId)
per cursor move:  updatePointDrag (6664)
   ├─ INTACT closed-form shape? polygon/slot/circle/arc/ellipse/ellipse-arc/rectangle  → _closedFormXGeometry (5447…6253)
   │     → _applyClosedFormPositions(sync:false): local, no solver, no network; settled once in endPointDrag via _settleClosedFormShapeDrag (6369)
   └─ else:  points[p] = raw cursor;   _trySolveDuringDragLocally([p]) (6820)
          → solveSketchLocally (local_sketch_solver.dart:635)  py-slvs via FFI, builds a fresh System EVERY frame,
            dragged point SOFT-dragged via SolveSpace's dragged[] (slvs_ffi_shim.cpp:225 slvs_solve_dragged), origin+locked pinned,
            retry once with no dragged params, redundancy overrides (_isRedundancySafe / _residualVerifiedConvergence) ported from solver.py
          → frame guards, each "never partially applied → return false": blow-up (>10× diagonal), Arc chord-side flip, EqualLength/EqualRadius/
            confirmed-Distance residual > 2 % diagonal
          → on success: write ALL solved points back (dragged one possibly clamped), remember them in _dragReflowedPointIds
     on failure / no native lib:  notifyListeners();  _maybeSolveDuringDrag (7008; 120 ms throttle, one in flight, dropped not queued)
          → api.solve(anchor_point_ids:[p]) + api.listPoints, applied to every non-anchor point (NO guards)
          AND  unawaited(api.updatePoint(p, x, y))   ← one PATCH per pointer-move, unsequenced
endPointDrag (7053):  auto-coincide-if-near; PATCH every reflowed point; solveAndTrackDof(anchorPointIds:[p]) (solve-and-refresh) ; undo = updatePoint(origin)
DOF for the padlock/colouring:  backend SolveResult.dof = py-slvs System.Dof (+ floors/overrides, solver.py:1211) authoritative;
                                client dof_analysis.dart SketchRigidity.analyze = structural union-find, advisory only
gates:  beginPointDrag refuses over-constrained (isPointForcedOverConstrained 2698) and fully pinned (isPointFullyPinned 2726) unless it is
        an intact closed-form shape; refuses Circle/Arc CircleDragMode/ArcDragMode.blocked
```

* **Where the solver lives.** `loadSlvsBindings()` (`local_sketch_solver.dart:668`) opens
  `libdidsa_slvs_ffi.so` on Android and throws `UnsupportedError` elsewhere; `_trySolveDuringDragLocally`
  catches that and sets `_localSolverUnavailable`. The `.so` is prebuilt for `arm64-v8a`, gitignored, hand-placed
  in `jniLibs` ("Not yet automated into any build graph", `docs/status.md:1367`); no Windows/iOS
  CMake/Gradle/Pods reference exists. **Inferred:** Windows and iOS drag on the backend path; the README
  names Android and Windows as the tested clients.
* **Backend py-slvs cannot soft-drag.** The pip wheel's `System.solve(group, reportFailed, findFreeParams)` has
  3 arguments (4-arg call raises `TypeError`); `dragged[]` exists only in the vendored fork the shim links.
  The backend's anchors are hard pins in the fixed group (`_PySlvsBuilder`, solver.py:616).
* **Guards live only in the local path.** The three frame guards above are in
  `_trySolveDuringDragLocally`; the network fallback it hands rejected frames to has none.

### B.1 Where drag latency / jerk / "flying off" still occurs — measured

*Local path (Android):* not measurable here. Cost model from the pure-py-slvs solve times (x86;
Dart/FFI system-building adds to this): connected staircase sketch, H/V on every segment
(`b_scale2.py`):

| points | solve | | points | solve |
|---|---|---|---|---|
| 11 | 0.10 ms | | 201 | 4.5 ms |
| 41 | 0.41 ms | | 401 | **21.7 ms** |
| 101 | 1.3 ms | | 501 (10×10 disjoint rectangles) | **54 ms** |

The solver builds and solves **the whole sketch every frame** (a 10×10 grid of *unconnected* rectangles
costs 54 ms although dragging one rectangle needs 0.05 ms) — at a 16 ms frame budget that is ≈ 300–350 connected points
on this CPU; if a phone core is 3–10× slower (an **assumption**, unmeasured) that is on the order of 30–100 points, and the Dart
FFI system-building adds to it: **big sketches are where local drag is most likely to stutter** (§H for how to measure). Restricting the solve to the connected component containing the dragged point
is a free 10–1000× win on such sketches, independent of any motion model.

*Backend fallback (Windows/iOS, Android rejected frames)* — replay of the exact stream, 3-point arm (origin,
L1 = 30, L2 = 25), P2 dragged over 1.5 s (`b_http_drag.py`):

| Path | Requests | Notes |
|---|---|---|
| reachable sweep (r = 45, 20°→160°) | **115** (90 PATCH + 12 POST /solve + 13 GET points); localhost mean 1.6 ms | un-dragged joint `P1` reflows at **8 Hz**; jumps of **6.3–6.6 units** per update while the dragged point tracks the cursor at 60 Hz |
| out-of-reach excursion (r 45→75→45) | 115 | the anchored solve fails and the **no-anchor retry silently drops the anchor in 10 of 12 solves** (dragged point up to **18 units** from the cursor) though `converged` is `true`; `P1` jumps up to **13.6 units** between updates; **after coming back into reach the drag-end solve still fails and P2 snaps by ~9.9 units** (`(28.9, 34.5)` → `(35.4, 42.1)`), because the excursion left the arm fully extended (singular Jacobian) and Newton cannot leave it (`b_anchor_fail.py`). |

(The Android soft-drag path is designed precisely to clamp the dragged point at the reach limit instead;
I could not run it.)

### B.2 Partially constrained drag today — nearest solution? free directions? flips?

* **Nearest solution from the dragged position**: yes by construction — the raw cursor position is
  seeded and the solve is Newton from there; `docs/status.md:1784` records the finding that
  `System::NewtonSolve` has "no pick-the-correct-root logic … decided entirely by proximity to the seed" and that
  the reference implementation gets robustness from re-solving every pixel (continuation).
* **Free directions are kept** because nothing moves unless a constraint forces it: the local solve
  soft-drags the point (it follows the cursor along free directions, is clamped along constrained ones);
  the closed-form constructs sidestep the solver for 7 shape kinds.
* **Known branch flips and how they are handled:** (1) redundant Tangent/EqualRadius webs (Slot; Polygon chain)
  land on wrong roots while `converged` — measured below; answered by the **closed-form drag constructs**
  (Polygon/Slot/Circle/Arc/Ellipse/EllipseArc/Rectangle), the **blow-up guard**, the **Arc chord-side guard**, the
  **residual guard**, and the residual-based convergence override (`_residualVerifiedConvergence`); (2) a rejected
  frame falls to the *unguarded* network path; (3) an over-constrained/fully-pinned start refuses the grab.
* **Measured wrong-root evidence** (`b_slot.py`): perturbing one coordinate of a Slot by 1×10⁻³ produced
  responses of **|Δ|/ε ≈ 2.6×10⁴** (a 25-unit jump) with `converged = true, result_code = 5`.

### B.3 Is a free-motion basis useful in 2D?

| Use | Verdict |
|---|---|
| **Per-frame smoothing where a local solver runs (Android)** | **Redundant.** A solve costs ~0.05–2 ms for typical sketches and follows curvature exactly; a first-order model is strictly worse there. |
| **Where solving is remote (Windows/iOS fallback)** | **Useful**: replaces "PATCH every move + solve every 120 ms" (115 requests, 8 Hz reflow) with 2 probe solves at grab (a **drag-map**: response of every point to unit motion of the dragged point in x and y → linear reflow of the whole sketch each frame, exact for rigid/H-V-type systems, first-order otherwise) + occasional re-anchor. Only worth building if there is no plan to ship the local solver on those platforms. |
| **Mobility oracle / cursor feedback** | **Useful and cheap** (2 probe solves on grab, or a full nullspace on idle for ≤ ~50 points): per-point rank of the reachable motion (0 pinned / 1 slides along a direction / 2 free) with the direction → axis-lock cursor, "can't move" cue *before* the user drags, correct refuse-grab, and a mobility-coloured overlay that is exact where `dof_analysis.dart` is structural. See B.4. |
| **Preventing branch flips** | **Partly.** A basis at the grab point lets the client *predict* the frame (`x_pred = x + B·Bᵀ·Δcursor`) and reject a solved frame that jumps far from the prediction — a generalisation of the blow-up/chord-side guards into one continuity test that also covers the network fallback. It cannot pick the right root on its own. |
| **Big sketches** | The dominant win there is **component-restricted solving** (free) plus the drag-map; the basis is secondary. |

### B.4 Prototype: nullspace of sketch systems (`b_probe.py`, `b_probe2.py`, `b_compare.py`)

**Method** (public py-slvs only; the pip wheel exposes no Jacobian or residuals, and `Dof` is
params − equations): settle the sketch; for each free coordinate perturb by ε, re-solve with everything
free (origin and locked points pinned), read the response `Δ/ε`; stacking gives `P`. SolveSpace's Newton step
is minimum-norm, so the response is the first-order orthogonal projection onto the tangent space `T` of the
solution set: `range(P) = T`, `trace(P) = rank(P) = dof`, the basis = the left singular vectors with σ > 0.5,
and a point's own 2×d row-block of the basis gives its **mobility** (rank 0/1/2 + direction).
(The measured `P` is often *not* symmetric — SolveSpace substitutes equated parameters before solving, so
it is an oblique projector — which does not affect rank or range; I therefore derive mobility from the basis, not from the
diagonal blocks of `P`, whose eigenvalues were misleading.)

**Results** — eight sketches built with the backend's own `Sketch` API (real app structures):

| Sketch | py-slvs `dof` (backend) | **probe rank** | truth | structural `dof_analysis.dart` vs probe (per free point) |
|---|---|---|---|---|
| Rectangle, corner on origin, width dimensioned (height free) | 1 | **1** | 1 | 4/5 agree — Dart calls the bottom-right corner "free/under" where the probe shows it is **pinned** (x by dimension, y by H) |
| Rectangle fully dimensioned | 0 | **0** | 0 | 5/5 |
| Rectangle, floating | 4 | **4** | 4 | 5/5 |
| 2-link arm (L1 = 30, L2 = 25) | 2 | **2** | 2 | 2/2 (P1 slides on a circle: rank 1; P2 free: rank 2) |
| Hexagon (provisional radius) | 4 | **4** | 4 | 7/7 |
| **Slot** (provisional radius) | **1** | **5** (stable for ε = 10⁻¹, 10⁻²; noisy at 10⁻³) | **5** (2+2+1) | 6/6 — but *py-slvs' 1 is the provisional floor, not a measurement* |
| Rectangle + redundant `Parallel` (one width dimensioned) | 0, **not converged** | **1** (10 of 10 probes non-converged, still right) | 1 | **2/5 — Dart says "fully constrained" for 3 points that can still move** (double-counted redundant constraint) |
| Rectangle, conflicting widths | 0, not converged | garbage (10 non-converged) | n/a | – |

* Stable across ε = 10⁻¹…10⁻⁴ for the well-posed sketches (idempotency error ≤ 4×10⁻⁴; singular-value gap ≈ 1.0 vs ≤ 0.003).
* The dragged corner of the partially-constrained rectangle comes out as **mobility rank 1, direction (0, −1)** — "this corner can only move
  vertically" — exactly the axis-lock cue a cursor would need.
* **Cost** (`b_scale.py`): one probe = one solve. Full nullspace = 2 solves per coordinate: 2 ms (6 pts), 118 ms (46 pts), **1.2 s (126 pts)**,
  ≈ 68 s extrapolated (501 pts) — so a *full* nullspace is an idle-time, small-sketch tool. The **drag-map = 2 solves** (≈ 2× a solve: 0.1–110 ms
  in the table above). Numbers are pure py-slvs on x86 (my harness also deep-copies the sketch per probe, so the printed "drag-map" wall time
  over-states it).
* **Limits found**: (1) redundant Tangent/EqualRadius webs (Slot) return wrong-root responses for some probes with `converged = true` (B.2);
  filter columns with `‖Δ‖/ε ≫ 1` and treat those sketches with a closed-form model instead (which is what the client already does);
  (2) non-converged systems can still yield the right rank (redundant Parallel) or nonsense (conflict) — do not trust without checking
  `converged`; (3) real py-slvs residuals/Jacobian are not exposed, so an exact, cheap analytic route would need either the vendored
  fork's internals (`System::EvalJacobian`) through the FFI shim or Python-side residuals per constraint type (the assembly solver
  already does the latter for mates).

**Bonus finding:** the structural `dof_analysis.dart` count is *advisory by design*, but it feeds
`isPointFullyPinned` (a **drag gate**) — for the two rectangle cases above it would (a) miss a pinned corner and (b) claim
"fully constrained" for movable points. A mobility oracle would replace a guess with a measurement.

---

## C. 3D sketch / plane-embedded sketching

* **What exists.** "Plane-embedded 3D sketching" (Orbit View, `docs/sketcher-restructure-plan.md` §3, `docs/status.md`
  2026-07-17 P1–P10+, `docs/roadmap.md:233`) is **shipped and near-complete**, but it is a **2D sketch on a plane rendered in the 3D
  viewport**: sketch coordinates are still flat local `(x, y)`; the embedded drag path is `_handleEmbeddedDrawOrDragCommit`
  (sketch_screen.dart ≈ 1790) → `worldPointToSketch(basis, worldPoint)` (ray ∩ plane) → the **same** `beginPointDrag`/
  `updatePointDrag`/`endPointDrag` and the same 2D solver. Camera-relative drag planes are already handled by the ray–plane
  intersection; nothing else is 3D. Phase 7 of `docs/sketcher-overhaul-scope.md` (unify 2D/3D environments) is a pan/zoom sync
  problem, not a constraint one.
* **True 3D sketch: does not exist**, is not in the roadmap, and the restructure plan (§3 Phase 2 item 4) only flags that
  plane-embedded coordinates have "not-yet-worked-out implications" for profile detection, OCCT wires and how the solver's 2D workplane
  maps.
* **What the technique would need for a true 3D sketch:** 3 parameters per point; free-3D constraints (py-slvs supports them — the
  assembly solver already uses `addPointsDistance`/`addPointInPlane` without a workplane); a **camera-relative drag manifold** chosen from the
  tangent space at the grabbed point (dimension 1 → a line, 2 → the tangent plane, 3 → the camera-facing plane); a chart of `3N` coordinates.
  **Prototype** (`c_sketch3d.py`, toy 3D sketches directly on py-slvs, not app models): a 3D 2-link arm gives probe rank **4** = py-slvs `Dof` **4** = truth,
  P1's reachable-motion subspace is **2-D** (drag = its tangent plane), P2's **3-D**; a triangle pinned to `z = 0` by point-in-plane gives rank **1**
  (= expected). 0.05 ms/solve.
* **Blocking?** Not the solver or the technique. Blocking is *product* scope: no 3D entity model, no 3D profile/wire pipeline, no 3D
  constraint UI. Everything in §B carries over unchanged to the embedded 2D-on-plane sketcher today.

---

## D. Whole tool set — inventory and ranking

Legend: **Solver?** what constrains the motion. **Where** local/remote. **Fit** for "learn allowed motion once, apply locally, re-anchor".

### D.1 Flat app (`client/lib`)

| # | Interaction | Refs | Solver / constraint | Where solved | What the user sees while dragging | Fit |
|---|---|---|---|---|---|---|
| F1 | **Component gizmo** (3 arrows + 3 rings) | `component_gizmo.dart`, `part_viewport.dart:3418/3501`, `part_screen.dart:10251/10296` | **Mates** (`assembly_solver`) exist but are **not applied** | none (PATCH on release, no solve) | raw pose; violation saved | **High** |
| F2 | Move/Rotate panel typed apply | `part_screen.dart:10387`, `move_rotate_component_panel.dart` | same | none | (typed) | High — one-shot `mate-motion`/solve |
| F3 | Section plane gizmo (1 move + 2 rotate) | `section_gizmo.dart`, `part_viewport.dart:3253`, `part_screen.dart:1322` | none (free plane) | plane drawn locally; section *preview geometry* = backend OCCT boolean, **200 ms debounce** | plane moves live, cut caps update ~5 Hz | Not this technique (no constraint). Analogue: VR's client-side clip shader (see V3). |
| F4 | Sketch point / line (rigid) drag | `sketch_controller.dart:6524–7370` | 2D sketch constraints | Android: local FFI per frame; else backend (§B.1) | dragged point under cursor, rest reflows (local 60 Hz / backend 8 Hz) | Medium (§B.3) |
| F5 | Circle/Arc/Ellipse/EllipseArc/Polygon/Slot/Rectangle handle drags | `_closedForm*` 5447–6253 | closed-form formulas (avoid solver) | local, no solver | instant, exact | Already local; nothing to add |
| F6 | Dimension label / constraint label / leader drag | `beginLabelDrag`, `updateLabelDrag` (7964…) | none (cosmetic offset/angle) | local | label follows | N/A |
| F7 | Text resize/centre handles | `textResizeHandleGrabTargetAt` | none | local + PATCH | live | N/A |
| F8 | Spline through-points | sketch points | ordinary points (curve follows) | as F4 | — | as F4 |
| F9 | Feature panels: extrude, revolve, fillet, chamfer, shell, thicken, loft, sweep, pattern, mirror, move body/face, scale body, create-plane offset / curve parameter | `part_screen.dart` `_*Debounce` (500 ms), `docs/live-preview-pattern.md` | none (OCCT validity only) | **remote OCCT rebuild** per edit (500 ms debounce) | typed value; preview mesh after ≥ 0.5 s + rebuild | Not this technique; **there are no viewport distance/spacing handles** to drag. A *validity-interval* query would be the analogue. |
| F10 | Gear designer fields | `gear_design_screen.dart:277` | none | backend `/gear/preview` on **500 ms** debounce; `pointsPerFlank` slider is local | 2D preview canvas | N/A |
| F11 | Component pattern count/spacing | `component_pattern_panel`, `_patternDebounce` | none | backend re-expansion (`assembly-mesh`) | after debounce | N/A |
| F12 | Camera orbit/pan/zoom, panel/tree resize, sliders (far-clip, opacity, resolution) | `orbit_camera.dart`, `feature_tree_panel.dart` | none | local | live | N/A |
| F13 | Measurement, selection, mate authoring | picks, `preview-mate-solve` ghost | mate solve | remote, per UI change (token-guarded) | ghost after one round trip | Already the "wanted → nearest, store nothing" pattern |

### D.2 VR client (`DIDSA-VR/scripts`, branch `ccr-5fcefc91-t2tc6f`)

| # | Interaction | Refs | Solver | Where | What the user sees | Fit |
|---|---|---|---|---|---|---|
| V1 | Grip-grab part (hand-tracked 6-DOF, One-Euro filtered) | `controller.gd:397` `_update_held_part` → `mates_tool.constrain_drag` (`mates_tool.gd:491`) | Mates | free part: local; mated: **local projection** + 150 ms `mate-motion` | smooth (VR notes: 7 requests per 60-frame drag; my 120-frame replay: 14) | Adopted; improvable (§A.5, §E) |
| V2 | Laser: thumbstick rotate about hit pivot; A/B nudge along aim | `controller.gd:_nudge_along_aim`, `_rotate_about_pivot` | Mates | accumulated *wish* (`desired_global`) then same projection | as V1 | Adopted |
| V3 | **Section plane** grab (disc + arrow) | `section_tool.gd` `try_grab`/`update_held` | none | **fully client-side clip shader; never calls the backend** (backend section is an OCCT boolean, too slow at 90 Hz) | live | The *pattern* "local approximate model, exact remote on demand" — already used; no constraint to learn |
| V4 | Whole-model one/two-hand move/rotate/scale | `two_hand_model.gd` | none | local, gain + One-Euro | live | N/A |
| V5 | Floating window move (handle) / corner resize | `diegetic_panel.gd:295–485` | none (min size only) | local | live | N/A |
| V6 | Wrist-tablet sliders / scale presets | `wrist_tablet.gd:901…` | none | local | live | N/A |
| V7 | Locomotion (smooth/snap turn/teleport) | `locomotion.gd` | none | local | – | N/A |
| V8 | Measure / colour / mate-pick (point-picks) | `measure_tool.gd`, `colour_tool.gd` | – | – | – | N/A |

### D.3 Ranking — (user-visible benefit 1–5) × (ease 1–5)

| Rank | Change | Benefit | Ease | Score | Why |
|---|---|---|---|---|---|
| 1 | **F1/F2: solve after gizmo/panel move** (merge `mate-motion`, PATCH the *solved* pose, or `solve` after PATCH) | 4 | 5 | **20** | Fixes a *correctness* gap (violating poses saved). One request; both endpoints exist. |
| 2 | **Projector upgrades for both clients**: screw integration, lever arm = bounding radius, pop blending | 3 | 5 | **15** | Client-only, ~40 lines each; removes measured 5 mm / 2 mm artefacts on curved mates; benefits VR immediately. |
| 3 | **F1 live constrained drag** (Dart projector, grab-time `mate-motion`, 150 ms re-anchor) | 5 | 3 | **15** | The real feature; needs the Dart projector and gizmo hooks. |
| 4 | **F1 gizmo shows freedom** (grey/hide locked, plane handle, re-pivot on screw axis) | 3 | 4 | **12** | Free once the basis is on the client; large clarity gain. |
| 5 | **F4 on Windows/iOS: drag-map or ship the local solver** | 4 | 2–3 | **8–12** | Only matters if those are used for sketching; shipping the Windows DLL (harness exists) gives exact local solving. |
| 6 | **F4 mobility oracle** (cursor axis-lock, "can't move" cue, replaces the structural gate) | 3 | 3 | **9** | Measured disagreement with `dof_analysis.dart`; cheap for the grabbed point. |
| 7 | **Multi-body group `mate-motion`** (`driven_ids`) + VR/Flat use | 4 | 2 | **8** | Removes the measured "blocked by frozen peer" failure; backend work. |
| 8 | Big-sketch component-restricted solve (F4) | 3 | 3 | **9** | Free 10–1000× on disjoint parts; independent of the motion model. |
| 9 | F9 validity-interval query for panels | 2 | 2 | 4 | Different problem (OCCT, not a solver). |
| 10 | 3D-sketch groundwork | 1 | 1 | 1 | Product-scope, not technique-limited. |

---

## E. Design — one shared abstraction

### E.1 Shape of the idea

Everything above is one problem: a **configuration** `x ∈ ℝⁿ` (occurrence poses, sketch point coordinates, a
scalar feature parameter…) constrained to a solution set `M = {x : F(x) = 0}`. The client wants, per frame, the point of
`M` nearest the user's *wanted* configuration `w`. Learn the tangent space `T_x M` (a basis `B`, `d × n`) plus an anchor
`x̂ ∈ M` once; then `x_shown = retract(x̂ + B·Bᵀ W (w − x̂))` locally; re-anchor every so often. Different tools differ only in
the **chart** (how `x` is parametrised and how a tangent step is integrated) and the **weights**.

### E.2 Backend contract (`FreeMotion`)

One response shape; per-domain endpoints (or one generic `POST /motion`) return it.

```jsonc
// request
{ "subject": { "kind": "occurrence" | "occurrence_group" | "sketch_points" | "scalar", "ids": ["…"], "grabbed": "…" },
  "wanted":   { /* configuration in the subject's chart — same JSON as the store endpoint (RigidTransform, {point_id:[x,y]}, number) */ },
  "weights":  { "lever_arm": 41.2 },          // optional; default derived server-side from bounding radius
  "want_basis": true, "schema": 2 }

// response
{ "schema": 2,
  "converged": true,
  "config":   { /* nearest satisfying configuration to `wanted` in the weighted metric — NEVER stored */ },
  "dof": 3,                                    // authoritative: rank-based (mates: _independent_dof; sketch: probe/analytic), NOT System.Dof
  "chart": { "kind": "se3_owner_frame", "coords": ["dx","dy","dz","rx","ry","rz"], "integrator": "screw", "weights": [1,1,1,41.2,41.2,41.2] },
  "basis": [[…],[…]],                          // dof rows, orthonormal in the weighted metric
  "mobility": { "<id>": { "rank": 1, "dir": [0,-1] } },   // optional, per subject (sketch: per point; occurrence: per body)
  "quality": { "residual_inf": 3e-10, "sigma_min": 0.31, "sigma_gap": 40.0,      // conditioning: how close to a rank change
               "curvature": [0.002, 0.0], "max_step": 12.0,                      // 2nd-order: step length for < tol error
               "jump": 0.7 },                                                    // |config − predicted-from-previous-anchor|
  "diagnostics": { "solve_ms": 3.4, "code": 0, "branch_hint": "…" } }
```

* `dof`/`basis` come from **rank of a Jacobian of residuals**, not py-slvs `Dof`: proven better for mates
  (`_independent_dof`) and for sketches (Slot: probe 5 vs `Dof` 1).
* `config` from a **weighted Gauss–Newton retraction** in the same metric as the client's projector (prototype: no pops), falling back to
  py-slvs' Newton for constraint types without Python residuals.
* Unknown-`schema`/older backend: 404/405 or missing `basis` → client degrades (E.5).

### E.3 Client projector — one spec, two ports (Dart, GDScript)

```text
class FreeMotionProjector:
  anchor(resp):        ref ← resp.config;  B ← weighted_gram_schmidt(resp.basis, chart.weights);  t_anchor ← now;  quality ← resp.quality
  project(wanted):     δ ← chart.log(ref, wanted)                     // se3: rotvec of R_w·R_refᵀ, translation diff; xy: subtraction
                       a ← Σ_i (B_i · W δ) B_i                        // weighted projection onto free subspace (grabbed weight 1, followers ≈ 0)
                       return chart.exp(ref, a)                       // se3: SCREW exponential; xy/scalar: additive (exact/linear)
  needs_reanchor():    |Δ_since_anchor| > quality.max_step  OR  (now − t_anchor) > 150 ms  OR  σ_gap small (near rank change)  [one in flight]
  accept(resp):        reject if !converged OR residual_inf > tol OR resp.jump ≫ predicted  → keep old model, count a miss
  blend(resp):         on accepted anchor, apply the displayed-vs-new offset as a decaying correction (τ ≈ 2 frames) so no pop is visible
```

Charts to ship first: **`se3_owner_frame`** (assemblies; existing VR/Dart pose type), **`points_xy`** (sketch), **`scalar`**
(feature parameter with interval). A group chart is a product of charts.

### E.4 Weighting between translation and rotation

Metric `diag(1,1,1,L,L,L)`. **`L` = the moving thing's bounding radius** (flat app has `_gizmoTargetBoundingRadius`; VR from the mesh AABB), not a
constant 100 mm: one radian then moves the farthest point about as far as one unit of translation moves anything. Sweep on the offset-axis
concentric mate: L = 10 best matches the solver (1.7 mm / 6.6°); VR's constant L = 100 is ≈ 4× worse (6.9 mm / 26°). Send `L` to the backend so
its retraction uses the same metric; the client must not use a different one.

### E.5 Degradation

| Situation | Behaviour |
|---|---|
| Backend without the endpoint (404/405) | existing per-round-trip PATCH+solve loop (VR already does this); flat app: solve on release |
| `converged:false` (measured for `ANGLE` at a singular start; unreachable sketch cursor) | keep the last model **and** last shown pose; surface "can't follow that move" (throttled); do **not** read `dof:6, basis:[]` as "all free" |
| Unreachable / slow network | project locally from the last anchor; stop trusting it past `max_step` / a wall-clock budget (grey the part, freeze); on reconnect, re-anchor (blended) |
| Response reordering | request token; drop stale (VR: one in flight; flat: token like `_scheduleMatePreview`) |
| Release | one final anchored solve; **persist the solved pose once** (VR does this via `persist_pose`; flat app: PATCH the solved pose, not the raw one); undo entry = previous stored pose |

### E.6 First-order error, DOF changes, branch flips, multi-body

* **Curvature.** (1) client screw integration (exact for group-orbit freedoms); (2) `quality.max_step` from a backend finite-difference second-order estimate
  → re-anchor by *distance*, not just time; (3) time cap 150 ms. Measured: with screw integration a
  90° off-axis spin needs no re-anchor at all; the angle cone needs 150 ms → 0.08°.
* **DOF changes mid-drag** (singular pose, rank change, a locked/fixed flag flips): each response carries `dof`, `sigma_gap`; on a rank *drop*
  project onto the new basis immediately (motion into the lost direction is dropped — the user feels a wall); on a rank *rise*
  wait until the wish has a component in the new direction for ≥ N frames (hysteresis) before expanding, to avoid flicker at a singularity; near
  `sigma_gap` small, halve the re-anchor interval. There are no inequality/limit mates today (so no active-set jumps); when they arrive, `quality.active_set` +
  the same hysteresis applies. Measured singular cases: `ANGLE` from an aligned start and the fully-stretched 2-link arm.
* **Branch flips.** The backend keeps the Newton seed = *wanted* (nearest-solution behaviour; already fixed for face mates: current spin
  kept), and reports `jump`; the client treats an anchor whose `config` is far from its own predicted pose as a rejected frame (generalising the local
  sketch guards: blow-up, arc chord-side, residual). Redundant tangent webs stay on closed-form models.
* **Multi-body.** `subject.kind = "occurrence_group"`: variables = all listed occurrences, stacked Jacobian (peers outside the group stay frozen),
  grabbed body weight 1, followers weight ε. Toy check (`e_group.py`): peg ← B ← C, group DOF = **5** (vs B-alone **1**); a "B +12 along the peg" wish
  yields B +11.999 **and C +11.999** with C's in-plane/spin untouched. Needs the backend to expose group solving; the client projector is unchanged
  (chart = product of `se3` charts).

### E.7 Where each tool plugs in

| Tool | subject.kind | chart | notes |
|---|---|---|---|
| Flat F1/F2, VR V1/V2 | `occurrence` → `occurrence_group` | `se3_owner_frame` | same code both clients |
| Sketch F4 (no local solver) | `sketch_points` (grabbed point + its component) | `points_xy` | 2-probe drag-map + mobility; weights: grabbed 1, rest 1 (soft drag) |
| Sketch F4 (Android) | none | – | keep local FFI; optionally use `mobility` for cues |
| 3D sketch (future) | `sketch_points_3d` | `points_xyz` | drag manifold from `mobility.rank` |
| Feature parameters (future) | `scalar` | `scalar` + interval | `basis:[1]`, `interval:[lo,hi]`, `max_step` |

---

## F. Comparison summary — current vs proposed

| | Flat assembly (today) | Flat (proposed) | VR (today) | VR (proposed) |
|---|---|---|---|---|
| Requests / drag | 0 during, 5 on release | 1 at grab + ≈ 1 / 150 ms + 1 final + save | 1 at grab + ≈ 1 / 150 ms + 1 final + save | same, fewer re-anchors (distance-triggered) |
| Mate violation shown | up to any, **saved** | ≈ 0 | ≤ 5 mm curved / 0 flat | 0 (screw) |
| Pops at re-anchor | n/a | none (blend + weighted retraction) | 2 mm (curved, big wish) | none |
| Multi-body chain | blocked (silently violated) | group drag | blocked | group drag |
| Gizmo/handles | all 6 always | greyed by measured freedom, re-pivot | (no gizmo) | – |

---

## G. Ranked recommendation and phased plan

**Phase 0 — close the gap (≈ days).**
1. Merge the CAD `mate-motion` branch (`ccr-5fcefc91-t2tc6f`; backend tests 33 pass here) to `main` (it is *not* on `main`).
2. Flat app: after `_onComponentGizmoDragEnd` and `_applyGizmoWorldTransform`, when the occurrence has mates, call `mate-motion` with the wanted pose and PATCH the **solved** pose
   (or PATCH + `solve`), guard `converged:false` (keep raw + tell the user), keep undo. Add a regression test that a mated occurrence's stored pose satisfies its mate after a drag.
3. Add the per-frame **request counters** (flat + VR) and the on-device timers in §H so the owner can measure.

**Phase 1 — accuracy + live drag (≈ 1–2 weeks).**
4. Projector v2 in Dart and GDScript from the §E.3 spec: screw integration, `L` = bounding radius, blended re-anchors, anchor acceptance test. Unit tests port the numpy cases in `prototypes/geo.py`.
5. Flat app live constrained drag: fetch basis at grab, project every frame (`_gizmoLiveTransform = project(...)`), 150 ms re-anchor; gizmo handles greyed by free fraction, re-pivot on the screw axis.
6. Backend: weighted retraction (`weights.lever_arm`) using `_mate_residual_vector`; `quality` block (`residual_inf`, `sigma_*`, `max_step`).

**Phase 2 — multi-body (≈ 2–3 weeks).** `driven_ids` group `mate-motion`; VR and flat use it; decide follower weighting; tests for chains and for "grounded peer in the group".

**Phase 3 — sketch (independent decision).**
7. Decide **ship the local solver on Windows** (DLL harness exists) vs build a drag-map. If Windows sketching is a real workflow, the DLL gives exact local drag and makes the drag-map unnecessary; the drag-map is only worthwhile for iOS-without-FFI or huge sketches.
8. **Component-restricted local solve** (free win, independent).
9. **Mobility oracle** for the grabbed point (2 probe solves at grab or a backend `/sketches/{id}/mobility`); axis-lock cursor; replace `isPointFullyPinned` structural gate with the measurement; keep `dof_analysis.dart` as instant advisory.
10. Guard the fallback path with the same three frame guards (blow-up / chord-side / residual) and stop `_solveDuringDrag` from applying unguarded frames.

**Phase 4 (optional).** Scalar chart for feature parameters (validity intervals); 3D sketch groundwork.

### Risks

| Risk | Mitigation |
|---|---|
| First-order model wrong for large steps on curved manifolds | screw integration + `max_step` + time cap; acceptance test |
| Solver metric ≠ client metric → pops | weighted retraction on backend; blend on client |
| Rank changes / singular poses (measured: `ANGLE` aligned start, extended arm) | `sigma_gap` in response, hysteresis, halve re-anchor interval |
| Redundant tangent webs give wrong roots while `converged` (measured Slot) | keep closed-form drags; guard responses (`‖Δ‖/ε`, residual, continuity); do not offer a probe-based basis for those shapes |
| Backend/client version skew | `schema` field + 404/405 fallback (VR already tested) |
| Group solve scope creep | ship single-occurrence first; group behind `driven_ids` |
| On-device performance unknown (Dart/FFI system rebuild per frame; big sketches) | measure first (§H); restrict solves to the component |
| GPL/licensing for shipping the solver on more platforms | separate legal question — already flagged in `docs/sketcher-spikes-ffi-and-plane-sketch.md` (iOS especially) |
| Flat-app behavioural change: pose no longer equals gizmo pose | show raw ghost or "blocked" cue; keep an explicit "unconstrained move" escape hatch |

---

## H. What I could not measure, and how the owner can

| Unmeasured | How to measure |
|---|---|
| Real drag frame time on a phone (Android FFI path) | wrap `_trySolveDuringDragLocally` (`sketch_controller.dart:6820`) in a `Stopwatch`, log `ms` and `points.length`/`constraints.length` per frame in a profile build (`flutter run --profile`, DevTools timeline); also log how often it returns `false` (guard rejections → network fallback). |
| Windows/iOS actually using the backend for drag | log once whether `loadSlvsBindings()` threw; count `_api.updatePoint` and `_api.solve` calls per drag (both are single call sites: `updatePointDrag`, `_solveDuringDrag`). |
| Real RTT/jitter to a Pi/phone-hosted backend | time `updateOccurrenceTransform`/`solveForOccurrence`/`getAssemblyMesh` in `DocumentApiClient._send` (`document_api_client.dart:1603`); the sim in `a_strategies.py` takes `rtt_ms` and `proc_ms` as inputs — feed real values. |
| Mate solve cost on real, multi-face assemblies | `mate-motion` p50/p95 on a real document (my numbers are two boxes/cylinders; `_free_motion` does 12 residual evaluations per solve). |
| Soft-drag (`dragged[]`) behaviour vs nearest-solution | build `client/native/slvs` (`git submodule update --init`), run `client/test/local_solver_test.dart` against it; compare a drag replayed through `solveSketchLocally` with the prototype's `b_http_drag.py` stream. |
| VR frame stability | run `tests/e2e_mates_motion.gd` in Godot against the motion backend; add the screw/L changes behind a flag and diff. |

---

## I. Open questions for the owner

1. **Is "gizmo clamped by mates" still a requirement?** (It is in the original brief and `assembly-scope.md:7`, documented as implemented, but never wired.) Should a user be able to *deliberately* break a mate by dragging (Fusion-style "drag to unmate") or should mated parts always be constrained?
2. **Flat-app UX:** live constrained drag (part follows the projected pose, raw ghost optional), or "move freely, snap on release"? Direct body drag (like VR) in addition to the gizmo?
3. **Multi-body priority:** do real assemblies you care about chain mates (B on A, C on B)? That decides whether the group solve is Phase 2 or later.
4. **Windows/iOS sketching:** is sketching on Windows/iOS a real workflow? If yes, ship the local solver there before building a sketch drag-map. Is iOS licensing/FFI still blocked?
5. **Sketch mobility:** are you willing to make a *measured* mobility the drag gate (replacing `isPointFullyPinned`'s structural guess), given that black-box probing is unreliable on redundant tangent webs (Slot/Polygon chains)?
6. **Weights:** accept `L` = bounding radius (and a `weights` field in the API) or keep a fixed lever arm per client?
7. **`ANGLE` mate from an aligned start never converges** — treat as a solver bug to fix (better seed / rotate-away start), or document?
8. **Backend `dof` for sketches:** py-slvs `System.Dof` + floors is wrong for the Slot (1 vs 5) and the structural analysis is wrong for redundant constraints — should the rank-based count become the authoritative `SolveResultDto.dof`?
9. **Branch hygiene:** `mate-motion` (CAD) and the smooth-drag round (VR, `c56dd3b`) are on `ccr-5fcefc91-t2tc6f` branches, not `main` — merge together (VR falls back if the backend lacks the endpoint, but the smooth path needs both).

---

## Appendix — files, numbers, reproduction

* **Prototypes:** `docs/constrained-drag-investigation/prototypes/` — see its `README.md`. `run_all.sh` re-runs every experiment into `../results/`.
* **Key result files:** `results/a1_current_flow.txt` (A.1), `a_latency.txt`, `a_strategies.txt` + `a_strategies2.txt` (A.5 i/ii), `a_screw.txt` + `e_weighted_retraction.txt` (A.5 iii), `a_gizmo.txt` (A.4), `a_chain.txt` (multi-body), `a_extreme.txt`, `a_angle_singular.txt`, `b_probe2.txt` + `b_compare.txt` (B.4), `b_scale.txt`/`b_scale2.txt` (cost), `b_http_drag.txt` + `b_anchor_fail.txt` (B.1), `b_slot.txt` (wrong roots), `c_sketch3d.txt` (C), `e_group.txt`.
* **Environment:** Python 3.11.16, py-slvs 1.0.6, pythonocc-core 7.9.3, numpy 2.4.6, Dart 3.14 (dev) for `dof_analysis.dart`; backend from `ccr-5fcefc91-t2tc6f` (commit `159c0f8`), started with `CAD_API_KEY=testkey uvicorn app.main:app --port 8000`.
* **Reference commits/branches read:** CAD `main` `93d5ca3`; CAD `origin/ccr-5fcefc91-t2tc6f` `159c0f8` (adds `_free_motion`, `solve_occurrence_from_guess`, `/mate-motion`, spin-preserving seed); VR `origin/ccr-5fcefc91-t2tc6f` `c56dd3b` (adds `project_motion`, `weighted_basis`, `_sync_with_motion_model`; **not** on VR `main` `4630b07`).
