#!/usr/bin/env bash
# AI modelling evaluation: the deterministic half (see README.md). The model's half - reading a sketch and
# replying - is done by a model run by hand (README "Running a round"); this script does everything else
# with the app's own code.
#
#   tools/ai_eval/eval.sh prompts <dir>         write the app's system and image-analysis prompts into <dir>
#   tools/ai_eval/eval.sh build <run_dir>       build <run_dir>/reply.txt; score it against the sketch named by
#                                               the folder (runs/<sketch>/<model>-r<n>/, or its retry/ or fixed/)
#   tools/ai_eval/eval.sh verdict <run_dir>     parse <run_dir>/check_reply.txt (render-back check reply)
#   tools/ai_eval/eval.sh table <runs_dir>      pass/fail table for every built run under <runs_dir>
#
# Assembly mode (multi-part sketches, sketches/asm_*; see README "Assembly mode"):
#   tools/ai_eval/eval.sh prompts-assembly <dir> write the Assembly-mode system prompt and the image-analysis prompt
#   tools/ai_eval/eval.sh manifest <run_dir>     read the part_manifest from reply.txt; write the part and assembly
#                                               request turns into <run_dir>/requests/
#   tools/ai_eval/eval.sh corrections <run_dir> <file>   the user's corrections to the manifest's assumptions, as the
#                                               chat turn the app sends (<run_dir>/requests/corrections.txt)
#   tools/ai_eval/eval.sh assemble <run_dir>     build every part and the assembly (and, once mates_reply.txt exists,
#                                               the mates); score against the sketch's key
#
# External route (the hand-off the app gives an external chat, answered with a zip; README "External route"):
#   tools/ai_eval/eval.sh handoff <dir>          write <dir>/handoff.md: the Assembly-mode hand-off package, as the app
#                                               builds it - all an external chat is given besides the sketch images
#   tools/ai_eval/eval.sh import <run_dir>       zip <run_dir>/files/*.json into external.zip, read it with the app's
#                                               importer, build the parts and the assembly (placements, then the zip's
#                                               own mates), check completeness, score
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

# The shared tail of `assemble` and `import`: geometry reports, a render, the score. The score's sketch name is the
# run folder's parent (runs/<sketch>/<run>/).
finish_assembly() {
  local D="$1" sketch f
  sketch="$(basename "$(dirname "$D")")"
  for f in "$D"/part_*.step; do
    [ -f "$f" ] && "$CAD_PY" -I "$HERE/harness/inspect_step.py" "$f" "${f%.step}_geometry.json" > /dev/null 2>&1
  done
  [ -f "$D/assembly.step" ] && "$CAD_PY" -I "$HERE/harness/inspect_step.py" --solids "$D/assembly.step" "$D/assembly_geometry.json" > /dev/null 2>&1
  [ -f "$D/assembly.step" ] && "$CAD_PY" -I "$HERE/harness/render_step.py" "$D/assembly.step" "$D/assembly.png" > /dev/null 2>&1
  python3 -I "$HERE/harness/expected_assembly.py" "$sketch" "$D" > "$D/score.json"
  cat "$D/score.json"; echo
  return 0
}

case "${1:-}" in
  prompts)
    run_harness "AI_EVAL_DUMP_PROMPTS=$(realpath -m "$2")" 'dump prompts' > /dev/null
    echo "wrote $2/system_prompt.txt and $2/extraction_prompt.txt"
    ;;
  build)
    D="$(realpath "$2")"
    run="$D"
    case "$(basename "$D")" in retry|fixed) run="$(dirname "$D")" ;; esac
    sketch="$(basename "$(dirname "$run")")"
    run_harness "AI_EVAL_REPLY=$D/reply.txt" "AI_EVAL_OUT=$D" 'run plan' > "$D/harness.log" 2>&1 || true
    if [ -f "$D/model.step" ]; then
      "$CAD_PY" -I "$HERE/harness/inspect_step.py" "$D/model.step" "$D/geometry.json" > /dev/null 2>&1
      python3 -I "$HERE/harness/expected.py" "$sketch" "$D/geometry.json" > "$D/score.json"
    fi
    python3 -I -c "import json,sys; r=json.load(open(sys.argv[1])); print(r.get('outcome') or ('no plan' if not r.get('plan_detected') else '?'))" "$D/result.json"
    [ -f "$D/score.json" ] && cat "$D/score.json" && echo
    [ -f "$D/retry_request.txt" ] && echo "validation failed: send retry_request.txt back to the same conversation"
    ;;
  prompts-assembly)
    run_harness "AI_EVAL_DUMP_PROMPTS=$(realpath -m "$2")" AI_EVAL_MODE=assembly 'dump prompts' > /dev/null
    echo "wrote $2/system_prompt.txt and $2/extraction_prompt.txt (Assembly mode)"
    ;;
  manifest)
    D="$(realpath "$2")"
    run_harness "AI_EVAL_MANIFEST=$D/reply.txt" "AI_EVAL_OUT=$D" 'manifest' > "$D/harness.log" 2>&1 || true
    cat "$D/manifest.json"; echo
    ;;
  corrections)
    D="$(realpath "$2")"
    run_harness "AI_EVAL_CORRECTIONS=$(realpath "$3")" "AI_EVAL_OUT=$D" 'corrections' > "$D/harness.log" 2>&1 || true
    cat "$D/requests/corrections.txt"; echo
    ;;
  assemble)
    D="$(realpath "$2")"
    rm -f "$D"/part_*.step "$D"/assembly.step "$D"/*geometry.json "$D"/completeness.*
    run_harness "AI_EVAL_ASSEMBLY=$D" 'run assembly' > "$D/harness.log" 2>&1 || true
    finish_assembly "$D"
    ls "$D"/*retry_request.txt "$D"/requests/mates_retry.txt 2>/dev/null | sed 's/^/retry needed: /'
    [ -f "$D/requests/mates.txt" ] && [ ! -f "$D/mates_reply.txt" ] && echo "mates turn: send requests/mates.txt, reply to mates_reply.txt"
    ;;
  handoff)
    run_harness "AI_EVAL_DUMP_HANDOFF=$(realpath -m "$2")" 'dump handoff' > /dev/null
    echo "wrote $2/handoff.md (the Assembly-mode hand-off package)"
    ;;
  import)
    D="$(realpath "$2")"
    if [ ! -d "$D/files" ] && [ -f "$D/final_reply.txt" ]; then
      # The chat app could not create files: the model gave each file in a fenced block headed by its name, and the user
      # saves them (README "External route"). Do the same.
      python3 -I - "$D" <<'PY'
import os, re, sys
d = sys.argv[1]
text = open(os.path.join(d, "final_reply.txt")).read()
os.makedirs(os.path.join(d, "files"), exist_ok=True)
name = re.compile(r"(\d\d_[A-Za-z0-9_]+\.json)")
pos, count = 0, 0
for m in re.finditer(r"```(?:json)?[ \t]*\n(.*?)```", text, re.S):
    heads = name.findall(text[pos:m.start()])
    pos = m.end()
    if heads:
        open(os.path.join(d, "files", heads[-1]), "w").write(m.group(1))
        count += 1
print(f"extracted {count} file(s) from final_reply.txt")
PY
    fi
    [ -d "$D/files" ] || { echo "no $D/files: the model writes the zip's JSON files there"; exit 1; }
    rm -f "$D"/part_*.step "$D"/assembly.step "$D"/*geometry.json "$D"/completeness.* "$D/external.zip"
    # What the user would do with the files an external chat gave them: zip them, flat.
    python3 -I - "$D" <<'PY'
import glob, os, sys, zipfile
d = sys.argv[1]
with zipfile.ZipFile(os.path.join(d, "external.zip"), "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(glob.glob(os.path.join(d, "files", "*.json"))):
        z.write(f, os.path.basename(f))
PY
    run_harness "AI_EVAL_IMPORT=$D" 'run import' > "$D/harness.log" 2>&1 || true
    finish_assembly "$D"
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
    sed -n '2,24p' "$0"; exit 1
    ;;
esac
