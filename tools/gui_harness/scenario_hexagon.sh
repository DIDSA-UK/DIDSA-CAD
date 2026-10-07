#!/bin/bash
# Regular hexagon drawn in the UI, a Horizontal constraint applied on its top edge through the UI flyout, a vertex swept on a ring.
cd "$(dirname "$0")/../.."; G=tools/gui_harness/gui.sh; LOG=${GUI_WORK:-/tmp/didsa-gui}/app.log
tools/gui_harness/fresh.sh
$G click 1236 676; sleep .6; $G click 1243 572; sleep .6; $G click 1243 524; sleep .8; $G click 640 340; sleep .8; $G click 800 340; sleep 1.5; $G click 1226 667; sleep 1
$G click 600 201; sleep 1; $G click 279 137; sleep 1.5; $G click 295 85; sleep .5; $G click 36 628; sleep .5; $G shot hexagon_before .3
N0=$(grep -c "\[SketchDrag\]" $LOG)
tools/gui_harness/ring.sh 800 377 640 377 224 270 60 0.04; sleep 2; $G shot hexagon_after 1
echo "frames: $(( $(grep -c "\[SketchDrag\]" $LOG) - N0 ))  rejected/unsupported: $(grep -c "REJECTED\|UNSUPPORTED" $LOG)  exceptions: $(grep -c "Null check\|Exception" $LOG)"
grep "\[SketchDrag\]" $LOG | tail -n +$((N0+1)) | awk 'NR%10==1' | cut -c1-175
