# Scratch prototypes for `docs/constrained-drag-investigation.md`

**Not product code.** Nothing here is imported by `backend/` or `client/`; the scripts *read/import* product code
(backend `Sketch` model / `solve_sketch`, the client's `dof_analysis.dart`) but never modify it. Paths and the
throwaway API key (`testkey`) are hard-coded for the environment the investigation ran in — adjust `h.py`
(`BASE`, key) and `b_sketches.py` (`sys.path.insert`) for yours.

## Setup

```bash
# 1. backend from the branch that has /mate-motion  (origin/ccr-5fcefc91-t2tc6f, commit 159c0f8)
cd backend && CAD_API_KEY=testkey uvicorn app.main:app --host 127.0.0.1 --port 8000
# 2. any python with: fastapi httpx numpy py-slvs==1.0.6 pythonocc-core  (backend/environment.yml)
# 3. (only for b_compare.py) structural DOF from the client's real dof_analysis.dart:
cd prototypes/dart_structural_dof
mkdir -p lib/api lib/sketch
cp ../../../../client/lib/api/sketch_api_client.dart lib/api/
cp ../../../../client/lib/sketch/dof_analysis.dart   lib/sketch/
dart pub get && dart run bin/dof.dart ../sketches_export.json > ../dart_dof.json
# (lib/config.dart is a stub: the real one needs shared_preferences → Flutter)
```

`./run_all.sh` re-runs everything into `../results/`.

## Index

| Script | Section of the report | What it does |
|---|---|---|
| `h.py`, `scen.py`, `geo.py` | – | HTTP harness (request logging), mate scenario builders (face / offset-axis concentric / angle), rigid-transform math and a numpy transcription of VR's `project_motion()` / `weighted_basis()` + a screw-integration variant |
| `a1_current_flow.py` | A.1 | Replays the flat app's gizmo-drag call sequence; shows the stored pose violates the mate |
| `a_latency.py` | A.1 | per-endpoint latency |
| `a_strategies.py`, `a_strategies2.py` | A.5 (i), (ii) | real solve for each of 120 frames × 3 mates; offline network-timeline simulation of 5 strategies; independent violation metric; lever-arm sweep |
| `a_screw.py` | A.5 (iii) | additive vs screw (exponential-map) projection |
| `a_gizmo.py` | A.4 | per-handle free fraction |
| `a_chain.py` | A.3 / E.6 | peg ← B ← C: single-occurrence solve blocks B |
| `a_extreme.py`, `a_angle_singular.py` | A.3 | extreme wishes; `ANGLE` mate from a singular start never converges |
| `b_sketches.py`, `b_export.py` | B.4 | eight real-structure sketches (rect variants, 2-link arm, hexagon, slot, redundant, conflicting) built with the backend model; JSON export for Dart |
| `b_probe.py`, `b_probe2.py`, `b_compare.py` | B.4 | nullspace probe (rank, ε sweep, per-point mobility) vs py-slvs `dof` vs Dart structural verdict |
| `b_slot.py` | B.2 | Slot: wrong-root responses with `converged = true` |
| `b_scale.py`, `b_scale2.py` | B.1 / B.4 | solve/probe cost vs sketch size |
| `b_http_drag.py`, `b_anchor_fail.py` | B.1 | the backend-fallback drag stream, anchor dropped on out-of-reach, singular start |
| `c_sketch3d.py` | C | probe route on toy true-3D sketches (3 params/point, free-3D constraints) |
| `e_weighted_retraction.py` | A.5 (iii) / E | weighted Gauss–Newton retraction (toy concentric residuals) removes re-anchor pops |
| `e_group.py` | A.3 / E.6 | toy multi-body group nullspace + weighted projection |
| `f_frozen_peers.py` | A.3 / §0.3 | real backend: three parts on a plate, `B` side-mated to `C` and `D` — per-occurrence `dof` falls to **0** |
| `f_group_real.py` | E.6 / E.8 | **in-process** (TestClient) with the product's own `_mate_residual_vector`: group DOF **5** vs per-occurrence 0/1/1, mobility, "drag B +6 y" → B and D move, C stays. Needs `BACKEND=<backend dir>` and `CAD_API_KEY` unset |

Everything that talks to the backend uses the **real** running server. Anything marked *toy* in the report uses
hand-written residuals instead (`e_weighted_retraction.py`, `e_group.py`, `c_sketch3d.py`); `f_group_real.py` uses the product's real residual function instead.
