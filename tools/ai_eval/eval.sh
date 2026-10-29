#!/usr/bin/env bash
# AI modelling evaluation: the deterministic half (see README.md). The model's half - reading a sketch and
# replying - is done by a model run by hand (README "Running a round"); this script does everything else
# with the app's own code.
#
#   tools/ai_eval/eval.sh prompts <dir>         write the app's system and image-analysis prompts into <dir>
#   tools/ai_eval/eval.sh build <run_dir>       build <run_dir>/reply.txt; score it against the sketch named by
#                                               the parent folder (runs/<sketch>/<model>-r<n>/)
#   tools/ai_eval/eval.sh verdict <run_dir>     parse <run_dir>/check_reply.txt (render-back check reply)
#   tools/ai_eval/eval.sh table <runs_dir>      pass/fail table for every built run under <runs_dir>
#
# Needs the backend running (DIDSA-VR tools/start_backend.sh), Flutter on PATH, and CAD_PY = the backend's
# conda python (DIDSA-VR tools/setup_test_env.sh sets both up; `source /opt/tools/env.sh`).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLIENT="$HERE/../../client"
CAD_PY="${CAD_PY:-python3}"
HARNESS_IN_CLIENT="$CLIENT/test/_ai_eval_harness_test.dart"

run_harness() { # env assignments... then the test name
  local name="${!#}"
  cp "$HERE/harness/ai_eval_harness_test.dart" "$HARNESS_IN_CLIENT"
  trap 'rm -f "$HARNESS_IN_CLIENT"' RETURN
  (cd "$CLIENT" && env "${@:1:$#-1}" flutter test test/_ai_eval_harness_test.dart --plain-name "$name")
}

case "${1:-}" in
  prompts)
    run_harness "AI_EVAL_DUMP_PROMPTS=$(realpath -m "$2")" 'dump prompts' > /dev/null
    echo "wrote $2/system_prompt.txt and $2/extraction_prompt.txt"
    ;;
  build)
    D="$(realpath "$2")"
    sketch="$(basename "$(dirname "$D")")"
    run_harness "AI_EVAL_REPLY=$D/reply.txt" "AI_EVAL_OUT=$D" 'run plan' > "$D/harness.log" 2>&1 || true
    if [ -f "$D/model.step" ]; then
      "$CAD_PY" -I "$HERE/harness/inspect_step.py" "$D/model.step" "$D/geometry.json" > /dev/null 2>&1
      python3 -I "$HERE/harness/expected.py" "$sketch" "$D/geometry.json" > "$D/score.json"
    fi
    python3 -I -c "import json,sys; r=json.load(open(sys.argv[1])); print(r.get('outcome') or ('no plan' if not r.get('plan_detected') else '?'))" "$D/result.json"
    [ -f "$D/score.json" ] && cat "$D/score.json" && echo
    [ -f "$D/retry_request.txt" ] && echo "validation failed: send retry_request.txt back to the same conversation"
    ;;
  verdict)
    D="$(realpath "$2")"
    run_harness "AI_EVAL_VERDICT=$D/check_reply.txt" "AI_EVAL_OUT=$D" 'parse verdict' > /dev/null
    cat "$D/verdict.json"; echo
    ;;
  table)
    python3 -I "$HERE/harness/table.py" "$(realpath "$2")"
    ;;
  *)
    sed -n '2,13p' "$0"; exit 1
    ;;
esac
