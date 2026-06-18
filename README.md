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

**Stage 2b (wire `py-slvs` into the Sketch model) — complete.**

- `backend/app/sketch/constraints.py`: `Constraint` - a generic base type mirroring the `SketchEntity` pattern from Stage 2 (abstract `type`, abstract `point_ids()`) - and `DistanceConstraint` (two Point ids + a target distance), the only concrete type so far. Constraints are independent objects that reference Point ids directly; `Line`/`SketchEntity` have no knowledge of constraints referencing their points. Each concrete type implements `add_to_solver(builder)`, expressing itself via a small `SolverBuilder` protocol rather than importing `py_slvs` directly - this keeps the constraint model itself free of any solver-library dependency, same as `models.py` stays free of OCCT/FastAPI specifics.
- `backend/app/sketch/solver.py`: `solve_sketch(sketch)` builds the py-slvs problem from a Sketch's Points + Constraints (via each Constraint's `add_to_solver`), solves, and writes the result back onto `sketch.points` - even on non-convergence (best effort). Returns a `SolveResult` with `converged`, the raw `result_code` and `dof` (both genuine py-slvs diagnostics), and two distinct id lists: `blamed_constraint_ids` (the most-recently-added constraint, **by convention only** - not a diagnosed root cause) and `solver_reported_failed_constraint_ids` (py-slvs's own `Failed` list, translated back to our constraint ids). Empirically, on an inconsistent system (e.g. a triangle whose three target distances violate the triangle inequality), py-slvs's `Failed` lists **every** constraint in the system, not a single culprit - confirming py-slvs has no precise per-constraint attribution to fall back on, which is why blame is a stated convention rather than dressed up as a diagnosis. A future, more expensive subset-removal diagnosis (retry with one constraint removed at a time) is intentionally not built yet; `blamed_constraint_ids` is already a list so it can grow into that without a response-shape change.
- `Sketch` gained a `constraints: dict[str, Constraint]` field and `add_distance_constraint()`, owned per-sketch exactly like Points/entities - constraints never cross sketch boundaries.
- Solving is explicit and batched: `PATCH .../points/{id}` (and `Line.set_length`) only ever move a Point as the next initial guess - nothing solves automatically. A separate `POST .../solve` is what actually runs py-slvs and commits results, modelling "drag, then release."
- New endpoints: `POST/GET /sketch/sketches/{id}/constraints`, `DELETE /sketch/sketches/{id}/constraints/{constraint_id}`, `POST /sketch/sketches/{id}/solve`.
- `backend/tests/test_stage2b_solver_integration.py`: creating a constraint, solving a simple satisfiable case, solving through an existing Line's Points (the actual Stage 2 <-> Stage 2a wiring check), an intentionally over-constrained triangle (confirms non-convergence is reported rather than crashing or silently returning a wrong answer, the newest constraint is blamed by convention, and genuine py-slvs diagnostics are present), and independent constraints across multiple sketches - plus the equivalent checks over the HTTP API.

**Stage 3 prep (API key authentication) — complete.**

Done ahead of the rest of Stage 3 (dependency graph + Extrude, still pending - see "Next steps") because the API is being put behind a public Cloudflare Tunnel hostname for the first time, and needed its own auth before that happens.

- The API is being put behind a public Cloudflare Tunnel hostname for the first time. Cloudflare Tunnel only makes the container *reachable* - it adds no auth of its own - so `backend/app/auth.py` adds a single static API key check in front of every route.
- `app/main.py` registers `verify_api_key` as an app-level dependency (`FastAPI(dependencies=[Depends(verify_api_key)])`), so it runs for every route including `/health` - deliberately included rather than left open, since there's no separate uptime-monitoring setup that needs unauthenticated access yet, and an open `/health` would still let any internet scanner confirm the server is alive. The one carve-out is FastAPI's auto-generated `/docs` and `/openapi.json` - these are wired up outside the normal dependency system and stay reachable, but they only expose the API schema, not data.
- The key is supplied via an `X-API-Key: <key>` request header and checked with `secrets.compare_digest` against the `CAD_API_KEY` environment variable, read once at import time. If `CAD_API_KEY` isn't set, the app raises at startup rather than coming up unauthenticated.
- A missing or wrong key gets a `401` with `{"detail": "Missing or invalid API key."}` - no stack trace, no 500.
- **Local development**: pass the key when running the container, e.g. `docker run -e CAD_API_KEY=some-local-key -p 8000:8000 didsa-cad-backend` and then call the API with `-H "X-API-Key: some-local-key"`. Tests don't need a real key - `backend/tests/conftest.py` sets `CAD_API_KEY` to a fixed test value before any test module imports `app.main`, and existing `TestClient` instances send it on every request by default.
- **Honest security posture**: this is one shared static key suitable for a personal/hobby deployment - not a multi-user auth system. No rate limiting, no per-client keys/revocation, and no rotation mechanism. Good enough to keep the API off the open internet; not a substitute for Cloudflare Access if/when multiple distinct clients need distinguishing.
- `backend/tests/test_stage3_api_key_auth.py`: confirms a request with no key, and with a wrong key, are both rejected with `401`, and a request with the correct key succeeds - checked against both `/health` and a representative `/sketch` endpoint.

CI (`.github/workflows/backend-verify.yml`) builds the backend image and runs the full test suite on both `linux/amd64` and `linux/arm64`.

**Stage 4 (first Flutter client: chained line sketching with live solving) — implemented, partially verified.**

Brought forward ahead of further backend entity expansion (Circle/Arc) per an explicit decision to get a real sketching experience working first.

- `client/` is a single Flutter codebase (`flutter create --platforms windows,android,ios`, plus `linux` purely as a buildable/testable target in this headless dev environment) implementing the project brief's Section 5 interaction model: a persistent on-screen cursor moved either by relative, sensitivity-scaled touch drag (Android/iOS) or absolute 1:1 real mouse movement (Windows), with a dedicated **Click** button (or real mouse click) as the only way to commit a point.
- Chained line drawing: each Click after the first creates a new end Point and a Line sharing the previous Line's end Point id (a true connected chain, not coincidentally-placed points) - see `client/lib/sketch/sketch_controller.dart`. A **Finish Line** button ends the current chain. Clicking back near the chain's first Point (within a fixed snap radius) closes the loop using that Point's real id, visually indicated by highlighting the start point (orange, green when within snapping range).
- Backend integration: a Sketch is created on the `XY` plane on startup; every completed Line triggers `POST .../solve`, after which every known Point is re-fetched from the backend so rendering reflects the backend's solved positions, never just local state. Base URL and the `X-API-Key` header live in one place (`client/lib/config.dart`); the real key is read from a gitignored `client/lib/secrets.dart` (template: `client/lib/secrets.example.dart`) and is never committed. All requests have a 15s timeout and surface failures as a visible error banner rather than failing silently or freezing the UI.
- **Honest verification status** (no display, no Android/iOS device, no Windows host available in this environment): `flutter analyze` is clean, `flutter test` passes (chaining state machine + a widget smoke test, all against a mocked HTTP client - no test talks to the real deployed backend), and `flutter build linux --debug` compiles to a real binary. Actual interactive rendering and touch/mouse input were never driven by a real finger/mouse/display, and no live run against `https://cad-api.snail-shell.uk` has happened from this client - see `client/README.md` for the full breakdown of verified vs. unverified.

## Layout

```
backend/        FastAPI + pythonocc-core service (Stage 0-3)
  app/auth.py    Single static API key check (X-API-Key header) - Stage 3
  app/sketch/    Sketch module (Point/Line entities, planes, Profile detection, Constraints/solver - Stage 2/2b)
client/         Flutter client (Windows/Android/iOS) - Stage 4
docs/           Project brief and design docs
.github/        CI workflows
```

## Next steps

- Dependency graph (dirty-marking/recompute) + Extrude module, deploy behind Cloudflare Tunnel / Access.
- Possible future enhancement: precise over-constraint diagnosis (e.g. retry-with-one-constraint-removed), as opposed to today's "blame the newest constraint" convention.
- Known gap, not yet built: no rate limiting on the API key check.
- Stage 4 client: real interactive verification (touch/mouse input, live backend run) on an actual device/desktop - see `client/README.md`.
- Stage 5: 3D viewport for the Extrude result, once Extrude exists.
