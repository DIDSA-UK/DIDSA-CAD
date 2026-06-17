# DIDSA-CAD

Self-hosted, containerized parametric CAD tool built on the OpenCascade (OCCT) geometry kernel. See [docs/project-brief.md](docs/project-brief.md) for full architecture and roadmap.

## Status

**Stage 0 (environment de-risking) — complete.**

- `pythonocc-core` 7.9.3 (`novtk` build) builds and runs on conda-forge for both `linux-64` and `linux-aarch64`, so the Pi 5 (arm64) target is viable.
- Verified both in CI (amd64 + emulated arm64) and natively on a Raspberry Pi 5.
- OCCT smoke test: `backend/tests/test_stage0_occt.py`.

**Stage 1 (Sketch module: Line entity) — superseded by Stage 2.**

Lines originally owned their endpoint coordinates directly. Stage 2 replaced this with a Point-based model (see below) - kept here for history.

**Stage 2 (Sketcher foundation: Points, generic entities, planes, multiple sketches, closed-loop detection) — complete.**

- `backend/app/sketch/models.py`:
  - `Point`: an (x, y) coordinate with its own id, owned by a `Sketch`. Point sharing between Lines is always explicit (by id) - there is no coordinate-matching/auto-merge.
  - `SketchEntity`: an abstract base that `Line` implements, so future entity types (Circle, Arc) slot in without restructuring Sketch, Profile detection, or the API layer.
  - `Line`: references a `start_point_id`/`end_point_id` rather than owning coordinates. `set_length()` moves the end Point in place, preserving direction - since Points are shared objects, this also moves every other Line referencing that Point (e.g. a connected rectangle corner).
  - `Plane`: the three fixed reference planes (`XY`, `XZ`, `YZ`), all through the origin. No arbitrary/custom planes or 3D embedding yet.
  - `Sketch`: an independent collection of Points + entities on one Plane. Multiple Sketches do not share Points or entities.
- `backend/app/sketch/profile.py`: closed-loop detection (`detect_profile`). Operates only through `SketchEntity.endpoint_point_ids()`, so it knows nothing about how the entities were created. Distinguishes four outcomes: `closed_loop` (produces an ordered `Profile`), `no_loop` (open chain or no connectable entities), `branch` (a point used by 3+ entities), and `multiple_loops` (disjoint closed loops in one sketch).
- `backend/app/sketch/router.py`: REST API mounted under `/sketch` - `sketches`, nested `points`, nested `lines`, and a `GET .../profile` endpoint. Backed by a temporary in-memory dict, to be replaced by the dependency graph.
- Tests: `backend/tests/test_stage2_sketch.py` (Points, Lines, shared-point editing, multiple sketches, plane assignment), `backend/tests/test_stage2_profile.py` (closed-loop detection cases).

**Stage 2a (de-risk `py-slvs` constraint solver on arm64) — complete: works.**

- `py-slvs` (Python SWIG bindings to a SolveSpace fork) is not on conda-forge - it's pip-only. Added via the `pip:` subsection of `backend/environment.yml` (`py-slvs==1.0.6`), installed by micromamba alongside the conda-forge packages. Pre-built `manylinux_2_17` wheels exist for both `x86_64` and `aarch64` (cp311), so no source build was needed on either architecture.
- The installed module is `py_slvs.slvs` (not `slvs` as the PyPI name might suggest), and its high-level `System` class (`addPoint2d`, `addPointsDistance`, `addWorkplane`, `solve`, etc.) is what's usable directly - the lower-level module-level `make*` functions take raw entity/param handles and aren't meant to be called directly.
- Gotcha: `System.addPoint2d(workplane, u, v)` expects `u`/`v` to be **parameter handles** (from `addParamV`), not raw floats, despite what the type signature suggests at first glance.
- `backend/tests/test_stage2a_solver.py`: defines two 2D points on a workplane, a single distance constraint between them, calls `solve()`, and asserts the solved points are exactly that distance apart - plus a parametrized variant that re-solves from three different initial guesses for the second point, confirming the solver converges to a valid solution each time, not just once by luck.
- Does **not** touch the Sketch/Point/Line/Profile model - this is purely a de-risking spike, same as Stage 0 was for OCCT. How constraints attach to the existing Sketch entities is a separate, not-yet-started planning step.

CI (`.github/workflows/backend-verify.yml`) builds the backend image and runs the full test suite on both `linux/amd64` and `linux/arm64`.

## Layout

```
backend/        FastAPI + pythonocc-core service (Stage 0-3)
  app/sketch/    Sketch module (Point/Line entities, planes, Profile detection - Stage 2)
docs/           Project brief and design docs
.github/        CI workflows
```

## Next steps

- Stage 3: dependency graph (dirty-marking/recompute) + Extrude module + API layer, deploy behind Cloudflare Tunnel / Access.
- Plan how `py-slvs` constraints attach to the Sketch/Point/Line model (not started - separate piece of work from the Stage 2a spike above).
