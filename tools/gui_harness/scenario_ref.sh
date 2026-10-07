#!/bin/bash
# Reference geometry: Part = box + fillet; Sketch 2 (after the fillet) holds a reference to the far corner, a line from it to a free
# point and an 8.00 dimension. The sketch is opened from the build tree, the free end dragged round the reference, and a grab of the
# (locked) reference point itself is attempted. Optional step 2 (REF_EDIT=1): the fillet is moved to another edge upstream.
cd "$(dirname "$0")/../.."; G=tools/gui_harness/gui.sh; LOG=${GUI_WORK:-/tmp/didsa-gui}/app.log
SKETCHER=part tools/gui_harness/fresh.sh
tools/gui_harness/script.sh tools/gui_harness/scenarios/ref_part.py
# make the app re-read the part: enter and leave an empty sketch
$G click 1236 676; sleep 1.5; $G click 416 647; sleep 2; $G click 530 388; sleep 4; $G click 737 688; sleep 6; $G click 1252 84; sleep 5
$G click 28 132; sleep 2.5; $G click 80 366; sleep 8; $G click 900 600; sleep .6; $G click 36 628; sleep .5; $G shot ref_open .3
N0=$(grep -c "\[SketchDrag\]" $LOG)
tools/gui_harness/ring.sh 623 294 690 338 110 270 60 0.04; sleep 2; $G shot ref_after_drag 1
echo "free-end drag: frames $(( $(grep -c "\[SketchDrag\] frame" $LOG) - N0 ))  refusals: $(grep -c "refused" $LOG)  rejected: $(grep -c REJECTED $LOG)  exceptions: $(grep -c "Null check\|Exception" $LOG)"
grep "\[SketchDrag\]" $LOG | tail -n +$((N0+1)) | awk 'NR%10==1' | cut -c1-165
tools/gui_harness/script.sh tools/gui_harness/scenarios/ref_check.py | head -2
