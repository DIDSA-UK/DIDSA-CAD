#!/bin/bash
# usage: scenario_shape.sh rectangle|arc|ellipse|ellipse_arc   - shape drawn in the UI, one of its points dimensioned to a free point, dragged on a ring
cd "$(dirname "$0")/../.."; G=tools/gui_harness/gui.sh; LOG=${GUI_WORK:-/tmp/didsa-gui}/app.log; KIND=$1
tools/gui_harness/fresh.sh
tool() { $G click 1236 676; sleep .6; $G click 1243 572; sleep .6; $G click $1 $2; sleep .8; }
tool 1147 524; $G click 1000 520; sleep .8; $G click 1226 676; sleep .8          # the free anchor point
if [ "$KIND" = rectangle ]; then
  tool 1195 524; $G click 420 300; sleep .8; $G click 620 420; sleep 1.2; $G click 1226 676; sleep .8
  GX=620; GY=420; CX=1000; CY=520; R=480; SW=-40
elif [ "$KIND" = ellipse ]; then
  tool 1099 572; $G click 520 400; sleep .8; $G click 620 400; sleep .8; $G click 520 350; sleep 1.2; $G click 1226 676; sleep .8
  GX=620; GY=400; CX=1000; CY=520; R=440; SW=-40
elif [ "$KIND" = ellipse_arc ]; then
  tool 1147 572; $G click 520 400; sleep .8; $G click 620 400; sleep .8; $G click 520 350; sleep .8; $G click 560 330; sleep .8; $G click 480 370; sleep 1.2; $G click 1226 676; sleep .8
  GX=620; GY=400; CX=1000; CY=520; R=440; SW=-40
else
  tool 1051 524; $G click 520 400; sleep .8; $G click 620 400; sleep .8; $G click 520 300; sleep 1.2; $G click 1226 676; sleep .8
  GX=620; GY=400; CX=1000; CY=520; R=440; SW=-40
fi
(echo "KIND='$KIND'"; cat tools/gui_harness/scenarios/pt_dim.py) > /tmp/claude-0-pt.py; tools/gui_harness/script.sh /tmp/claude-0-pt.py
$G click 1180 27; sleep 1.5; $G click 36 628; sleep .5; $G shot ${KIND}_before .3
N0=$(grep -c "\[SketchDrag\]" $LOG)
tools/gui_harness/ring.sh $GX $GY $CX $CY $R $SW 60 0.04; sleep 2; $G shot ${KIND}_after 1
echo "frames: $(( $(grep -c "\[SketchDrag\]" $LOG) - N0 ))  rejected/unsupported: $(grep -c "REJECTED\|UNSUPPORTED" $LOG)  exceptions: $(grep -c "Null check\|Exception" $LOG)"
grep "\[SketchDrag\]" $LOG | tail -n +$((N0+1)) | awk 'NR%8==1' | cut -c1-175
