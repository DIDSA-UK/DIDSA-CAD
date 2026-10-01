#!/bin/bash
# Starts everything for a headless GUI session: backend (shared session), Xvfb, the Linux release build of the app.
# Prereqs (once):  apt-get install libgtk-3-dev mesa-vulkan-drivers xdotool imagemagick;  flutter build linux --release
# usage: tools/gui_harness/run.sh   (from the repo root; WORK dir via GUI_WORK, default /tmp/didsa-gui)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${GUI_WORK:-/tmp/didsa-gui}; mkdir -p "$WORK"; rm -f "$WORK/injected" "$WORK/inject"
PY=${BACKEND_PYTHON:-/opt/sdks/micromamba_root/envs/didsa-backend/bin/python}
# free port 8000 whatever is on it (a previous harness/backend), then any leftover X server / app
fuser -k 8000/tcp > /dev/null 2>&1 || true
for p in $(pgrep -x Xvfb); do kill $p; done
for p in $(pgrep -x didsa_cad_clien); do kill $p; done
sleep 1
(cd "$ROOT/backend" && LIVE_ONE_SESSION=1 nohup "$PY" ../tools/gui_harness/gui_server.py "$WORK" > "$WORK/server.log" 2>&1 &)
nohup Xvfb :99 -screen 0 1280x800x24 > /dev/null 2>&1 &
timeout 240 bash -c "until grep -q READY $WORK/server.log 2>/dev/null; do sleep 2; done"
# Seed the connection screen (shared_preferences) so the app starts with the harness backend filled in.
PREFS=$HOME/.local/share/uk.snail_shell.didsa_cad_client; mkdir -p "$PREFS"
echo '{"flutter.server_url":"http://127.0.0.1:8000","flutter.api_key":"test-api-key"}' > "$PREFS/shared_preferences.json"
cd "$ROOT/client/build/linux/x64/release/bundle"
DISPLAY=:99 VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json FLUTTER_ENGINE_SWITCHES=1 FLUTTER_ENGINE_SWITCH_1=enable-impeller=true \
  nohup ./didsa_cad_client > "$WORK/app.log" 2>&1 &
sleep 8
echo "up: work dir $WORK (app.log has the '[PartScreen] constrained drag: ...' lines)"
