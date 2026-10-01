#!/bin/bash
# Mouse/keyboard/screenshot helper for the headless GUI harness (needs xdotool + imagemagick, DISPLAY=:99 by default).
#   gui.sh click X Y | drag X1 Y1 X2 Y2 [steps] | longpress X Y | shot NAME [delay_s] | key K | type TEXT
export DISPLAY=${DISPLAY:-:99}
OUT=${GUI_WORK:-/tmp/didsa-gui}
mkdir -p "$OUT"
case $1 in
  click) xdotool mousemove $2 $3; sleep 0.15; xdotool click 1;;
  longpress) xdotool mousemove $2 $3; sleep 0.2; xdotool mousedown 1; sleep 1.2; xdotool mouseup 1;;
  drag) steps=${6:-20}; xdotool mousemove $2 $3; sleep 0.2; xdotool mousedown 1
        for i in $(seq 1 $steps); do xdotool mousemove $(( $2 + ($4-$2)*i/steps )) $(( $3 + ($5-$3)*i/steps )); sleep 0.04; done
        sleep 0.3; xdotool mouseup 1;;
  shot) sleep ${3:-1}; import -window root "$OUT/$2.png"; echo "$OUT/$2.png";;
  key) xdotool key $2;;
  type) xdotool type --delay 40 "$2";;
esac
