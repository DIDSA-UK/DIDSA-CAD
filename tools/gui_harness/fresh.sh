#!/bin/bash
# usage: [SKETCHER=3d] fresh.sh   - restart backend+app (drag logging on), Connect, open "2D Drawing" (or, with SKETCHER=3d, the 3D Part Design sketcher); leaves an empty sketch on screen
cd "$(dirname "$0")/../.."
G=tools/gui_harness/gui.sh
for p in $(pgrep -x didsa_cad_clien); do kill $p; done
(DIDSA_DRAG_LOG=1 setsid nohup tools/gui_harness/run.sh > /tmp/claude-0-run.out 2>&1 &)
timeout 120 bash -c 'until grep -q "^up:" /tmp/claude-0-run.out 2>/dev/null; do sleep 2; done'
sleep 3; $G click 608 449; sleep 3
if [ "$SKETCHER" = 3d ]; then   # 3D Part Design -> New Sketch -> XY plane -> Continue (the embedded sketcher)
  $G click 640 194; sleep 6; $G click 1236 676; sleep 1.5; $G click 416 647; sleep 2; $G click 530 388; sleep 5; $G click 737 688; sleep 6
else $G click 640 302; sleep 3; fi
