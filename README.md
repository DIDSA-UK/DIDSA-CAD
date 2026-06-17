# DIDSA-CAD

Self-hosted, containerized parametric CAD tool built on the OpenCascade (OCCT) geometry kernel. See [docs/project-brief.md](docs/project-brief.md) for full architecture and roadmap.

## Status

**Stage 0 (environment de-risking) — complete.**

- `pythonocc-core` 7.9.3 (`novtk` build) builds and runs on conda-forge for both `linux-64` and `linux-aarch64`, so the Pi 5 (arm64) target is viable.
- `backend/` contains a minimal Dockerfile (micromamba + conda-forge) and an OCCT smoke test (`backend/tests/test_stage0_occt.py`) that builds a box and runs it through `BRepMesh_IncrementalMesh`.
- `.github/workflows/stage0-verify.yml` builds the backend image for `linux/amd64` and `linux/arm64` (via QEMU) and runs the smoke tests on both — both pass (verified in CI since arm64 hardware isn't available in this dev environment).

## Layout

```
backend/        FastAPI + pythonocc-core service (Stage 0-3)
docs/           Project brief and design docs
.github/        CI workflows
```

## Next steps

- Stage 1: Sketch module (Line entity, length dimension).
- Stage 2: Profile detection + dependency graph.
- Stage 3: Extrude module + API layer, deploy behind Cloudflare Tunnel / Access.
