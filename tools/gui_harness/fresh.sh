#!/bin/bash
# usage: fresh.sh   - restart backend+app (drag logging on), Connect, open "2D Drawing"; leaves an empty sketch on screen
cd "$(dirname "$0")/../.."
G=tools/gui_harness/gui.sh
for p in $(pgrep -x didsa_cad_clien); do kill $p; done
(DIDSA_DRAG_LOG=1 setsid nohup tools/gui_harness/run.sh > /tmp/claude-0-run.out 2>&1 &)
timeout 120 bash -c 'until grep -q "^up:" /tmp/claude-0-run.out 2>/dev/null; do sleep 2; done'
sleep 3; $G click 608 449; sleep 3; $G click 640 302; sleep 3
