#!/usr/bin/env bash
# Re-runs every scratch experiment and stores stdout in results/.  Needs: the backend from the mate-motion branch listening on :8000
# (CAD_API_KEY=testkey uvicorn app.main:app --port 8000, run from backend/ of branch ccr-5fcefc91-t2tc6f), the micromamba env's python,
# and (only for b_compare.py) the Dart output dart_dof.json produced by dartproj/bin/dof.dart.
set -e
PY=${PY:-/opt/sdks/micromamba_root/envs/didsa-backend/bin/python}
mkdir -p results
for s in a1_current_flow a_latency a_strategies a_strategies2 a_screw a_gizmo a_chain a_extreme a_angle_singular b_export b_probe2 b_compare b_scale b_scale2 b_http_drag b_anchor_fail b_slot c_sketch3d e_weighted_retraction e_group; do
  echo "== $s"; $PY $s.py > results/$s.txt 2>&1 || echo "   (nonzero exit; see results/$s.txt)"
done
