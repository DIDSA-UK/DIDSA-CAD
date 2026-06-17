# DIDSA-CAD

Self-hosted, containerized parametric CAD tool built on the OpenCascade (OCCT) geometry kernel. See [docs/project-brief.md](docs/project-brief.md) for full architecture and roadmap.

## Status

**Stage 0 (environment de-risking) — complete.**

- `pythonocc-core` 7.9.3 (`novtk` build) builds and runs on conda-forge for both `linux-64` and `linux-aarch64`, so the Pi 5 (arm64) target is viable.
- Verified both in CI (amd64 + emulated arm64) and natively on a Raspberry Pi 5.
- OCCT smoke test: `backend/tests/test_stage0_occt.py`.

**Stage 1 (Sketch module: Line entity) — complete.**

- `backend/app/sketch/models.py`: a `Line` dataclass (two endpoints + derived `length`), with `set_endpoints()` and `set_length()` (recalculates the second endpoint, preserving direction). No knowledge of Profile/Extrude, per the brief's modularity principle.
- `backend/app/sketch/router.py`: REST API mounted under `/sketch/lines` — `POST` (from endpoints, or start+length+angle), `GET /{id}`, `PATCH /{id}` (update length or endpoints). Backed by a temporary in-memory dict, to be replaced by the Stage 2 dependency graph.
- Tests: `backend/tests/test_stage1_sketch.py`.

CI (`.github/workflows/backend-verify.yml`) builds the backend image and runs the full test suite on both `linux/amd64` and `linux/arm64`.

## Layout

```
backend/        FastAPI + pythonocc-core service (Stage 0-3)
  app/sketch/    Sketch module (Line entity, Stage 1)
docs/           Project brief and design docs
.github/        CI workflows
```

## Next steps

- Stage 2: Profile detection (closed-loop) + dependency graph.
- Stage 3: Extrude module + API layer, deploy behind Cloudflare Tunnel / Access.
