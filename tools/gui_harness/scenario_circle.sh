#!/bin/bash
# Circle whose centre is dimensioned to a point (15 units); the centre is dragged on a ring beyond the dimension, so it must
# slide along the permitted circle. Drawn through the real UI, the dimension added over REST. Output: frame log summary + shots.
cd "$(dirname "$0")/../.."; G=tools/gui_harness/gui.sh; LOG=${GUI_WORK:-/tmp/didsa-gui}/app.log
tools/gui_harness/fresh.sh
$G click 1236 676; sleep .6; $G click 1243 572; sleep .6; $G click 1147 524; sleep .6; $G click 940 380; sleep .8; $G click 1226 676; sleep .8
$G click 1236 676; sleep .6; $G click 1243 572; sleep .6; $G click 1003 524; sleep .8; $G click 640 380; sleep .8; $G click 720 380; sleep 1.2; $G click 1226 676; sleep .8
tools/gui_harness/script.sh tools/gui_harness/scenarios/circle_dim.py
$G click 1180 27; sleep 1.5; $G click 36 628; sleep .5; $G shot circle_before .3
N0=$(grep -c "\[SketchDrag\]" $LOG)
tools/gui_harness/ring.sh 640 380 940 380 360 50 60 0.04; sleep 2; $G shot circle_after 1
echo "frames: $(( $(grep -c "\[SketchDrag\]" $LOG) - N0 ))  rejected/unsupported: $(grep -c "REJECTED\|UNSUPPORTED" $LOG)  exceptions: $(grep -c "Null check\|Exception" $LOG)"
grep "\[SketchDrag\]" $LOG | tail -n +$((N0+1)) | awk 'NR%8==1' | cut -c1-175
