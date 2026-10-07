#!/bin/bash
# Runs every scenario against the current release build and prints one summary line each (details: $GUI_WORK/*.png, app.log).
cd "$(dirname "$0")/../.."
for s in hexagon circle slot "shape rectangle" "shape arc" arm; do
  set -- $s; script=tools/gui_harness/scenario_$1.sh; shift
  echo "=== $s"; $script "$@" 2>&1 | grep -E "^frames:|^\[SketchDrag\]" | awk '/^frames:/{print} /^\[SketchDrag\]/{n++; if(n<=1) print}' | cut -c1-170
done
