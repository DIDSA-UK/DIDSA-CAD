#!/bin/bash
# usage: ring.sh GRAB_X GRAB_Y CX CY RADIUS_PX SWEEP_DEG [STEPS] [DELAY_S]
# Press at the grab point, approach the ring around (CX,CY) at RADIUS_PX (angle of the grab point), sweep SWEEP_DEG degrees
# along it hover-moving, then click to drop. Pixel coordinates; DISPLAY=:99. Prints nothing - read $GUI_WORK/app.log.
export DISPLAY=${DISPLAY:-:99}
GX=$1; GY=$2; CX=$3; CY=$4; R=$5; SW=$6; N=${7:-60}; D=${8:-0.03}
pts=$(awk -v gx=$GX -v gy=$GY -v cx=$CX -v cy=$CY -v r=$R -v sw=$SW -v n=$N 'BEGIN{
  pi=3.14159265358979; a0=atan2(gy-cy, gx-cx);
  m=10; for(i=1;i<=m;i++){t=i/m; k=t*t*t*(10-15*t+6*t*t); printf "%d %d\n", gx+(cx+r*cos(a0)-gx)*k, gy+(cy+r*sin(a0)-gy)*k}
  for(i=1;i<=n;i++){t=i/n; k=t*t*t*(10-15*t+6*t*t); a=a0+sw*pi/180*k; printf "%d %d\n", cx+r*cos(a), cy+r*sin(a)}}')
xdotool mousemove $GX $GY; sleep 0.3; xdotool click 1; sleep 0.3  # drag mode: click = grab, hover = move, click = drop
echo "$pts" | while read x y; do xdotool mousemove $x $y; sleep $D; done
sleep 0.3; xdotool click 1
