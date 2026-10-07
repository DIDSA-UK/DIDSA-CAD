#!/bin/bash
# Two lines from the origin (chain), both lengths dimensioned; the tip is dragged on a ring beyond the reach (the wall).
cd "$(dirname "$0")/../.."; G=tools/gui_harness/gui.sh; LOG=${GUI_WORK:-/tmp/didsa-gui}/app.log
tools/gui_harness/fresh.sh
$G click 1236 676; sleep .6; $G click 1243 572; sleep .6; $G click 1099 524; sleep .8
$G click 640 388; sleep .8; $G click 720 330; sleep .8; $G click 800 380; sleep .8; $G click 1226 676; sleep 1
tools/gui_harness/script.sh tools/gui_harness/scenarios/line_lengths.py
$G click 1180 27; sleep 1.5; $G click 36 628; sleep .5; $G shot arm_before .3
N0=$(grep -c "\[SketchDrag\]" $LOG)
tools/gui_harness/ring.sh 800 380 640 388 250 -200 80 0.04; sleep 2; $G shot arm_after 1
echo "frames: $(( $(grep -c "\[SketchDrag\]" $LOG) - N0 ))  rejected/unsupported: $(grep -c "REJECTED\|UNSUPPORTED" $LOG)  exceptions: $(grep -c "Null check\|Exception" $LOG)"
grep "\[SketchDrag\]" $LOG | tail -n +$((N0+1)) | awk 'NR%10==1' | cut -c1-175
