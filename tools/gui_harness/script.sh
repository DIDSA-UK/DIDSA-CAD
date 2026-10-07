#!/bin/bash
# usage: tools/gui_harness/script.sh FILE.py   - run FILE.py inside the harness server (see gui_server.py run_scripts), print its output
WORK=${GUI_WORK:-/tmp/didsa-gui}
rm -f "$WORK/script.out"; cp "$1" "$WORK/script.py"
timeout 120 bash -c "until grep -q DONE $WORK/script.out 2>/dev/null; do sleep 0.3; done"; cat "$WORK/script.out"
