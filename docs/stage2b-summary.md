# Stage 2b Summary: Wiring the Constraint Solver into the Sketch Model

## What this stage did

Connected two previously-separate, independently-verified pieces:

- **Stage 2** — the Sketch data model: `Point`, `SketchEntity`/`Line`, `Plane`, `Sketch`, and closed-loop `Profile` detection.
- **Stage 2a** — a de-risking spike confirming `py-slvs` (Python bindings to a SolveSpace-derived 2D/3D geometric constraint solver) installs and solves correctly on both `amd64` and `arm64`.

Stage 2b is where those two pieces actually connect: Sketches can now own geometric constraints, and an explicit solve action runs `py-slvs` against them and writes the result back onto the Sketch's Points.

## What was built

- **`backend/app/sketch/constraints.py`** — `Constraint`, a generic base type mirroring the `SketchEntity` ABC pattern (abstract `type`, abstract `point_ids()`), plus `DistanceConstraint` (two Point ids + a target distance), the only concrete type so far. Constraints are independent objects that reference Point ids directly — `Line`/`SketchEntity` have no knowledge of constraints that reference their points. Each concrete type implements `add_to_solver(builder)` against a small `SolverBuilder` protocol, so this module has no dependency on `py_slvs` itself.
- **`backend/app/sketch/solver.py`** — `solve_sketch(sketch)` builds the `py-slvs` problem from a Sketch's Points + Constraints, solves it, and writes the result back onto `sketch.points` (best-effort, even when it doesn't fully converge). Returns a `SolveResult` with:
  - `converged`, `result_code`, `dof` — genuine `py-slvs` outputs.
  - `blamed_constraint_ids` — the most-recently-added constraint, **by convention only**, not a diagnosed root cause.
  - `solver_reported_failed_constraint_ids` — `py-slvs`'s own `Failed` list, translated back to our constraint ids, kept clearly separate from the convention above.
- **`Sketch.constraints: dict[str, Constraint]`** + `add_distance_constraint()` on the model, owned per-sketch exactly like Points/entities — constraints never cross sketch boundaries. Rejects a constraint between a point and itself (mirroring `add_line`'s existing same-point check).
- **Four new endpoints**: `POST`/`GET /sketch/sketches/{id}/constraints`, `DELETE /sketch/sketches/{id}/constraints/{constraint_id}`, `POST /sketch/sketches/{id}/solve`.
- **`backend/tests/test_stage2b_solver_integration.py`** — 21 new tests, both at the domain-model level and over the HTTP API.
- Docs (`README.md`, `docs/project-brief.md`) updated to describe the constraint model and the over-constraint diagnostic limitation.

## Key design decisions (carried through from the brief, not improvised)

- **Constraints are decoupled from entities.** No `constraints` field was added to `Line`/`SketchEntity`.
- **Solving is explicit and batched.** `PATCH .../points/{id}` and `Line.set_length()` only ever move a Point as the next initial guess — nothing solves automatically. Only `POST .../solve` runs `py-slvs` and commits results. This models "drag, then release."
- **Over-constrained systems are solved and reported, never rejected.** The most-recently-added constraint is flagged as "blamed" purely as a UX heuristic, explicitly documented (in code comments, README, and project brief) as a convention rather than a diagnosis.

## What `py-slvs` itself actually exposes for diagnostics

Empirically confirmed (via an intentionally over-constrained triangle: AB=10, BC=10, AC=100, violating the triangle inequality):

- `solve()` returns a nonzero result code (`2` in this case) on failure.
- `system.Failed` returns **every constraint handle in the inconsistent system**, not a single culprit — i.e. `py-slvs` cannot do precise per-constraint root-cause attribution for this kind of failure. This is surfaced as-is in `solver_reported_failed_constraint_ids`, distinct from the newest-constraint blame convention, so the limitation is visible rather than papered over.
- `system.Dof` (degrees of freedom) is available and also surfaced.

This confirms the brief's instinct that a "blame the newest constraint" convention is a reasonable, honest choice — there's no better signal from the solver to fall back on at this stage. A future, more expensive subset-removal diagnosis (retry with one constraint removed at a time) remains a possible enhancement, not built now; the response shape (`blamed_constraint_ids` as a list) was kept open to it.

## Results

- **Independent code review** (via a separate read-only review pass) caught one gap: `add_distance_constraint` was missing the same-point validation that `add_line` already has. Fixed and covered by a new test before merging.
- **CI** (`.github/workflows/backend-verify.yml`, no changes needed): real itemized pytest output pulled from job logs, not just the green checkmark —
  - `linux/amd64`: **59 passed in 0.88s**
  - `linux/arm64`: **59 passed in 13.34s**
- **Process**: branched off a `main` confirmed (via `git log`) to already include Stage 2a, committed incrementally, pushed to `claude/stage2b-constraint-solver-integration`, opened PR #4, and waited for explicit confirmation before merging (rather than merging it directly).
- **Merged**: PR [#4](https://github.com/DIDSA-UK/DIDSA-CAD/pull/4) into `main`.

## Explicitly not done this stage

- No constraint types beyond `DistanceConstraint` (no Angle, Coincident, Parallel, etc.).
- No subset-removal/precise over-constraint diagnosis.
- No automatic/implicit solving on point edits.
- No Extrude/Revolve, Flutter client work, or UI-level drag semantics — API-only.
