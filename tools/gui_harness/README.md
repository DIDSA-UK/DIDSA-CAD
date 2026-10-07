# Headless GUI harness

Drives the REAL Flutter app (Linux release build, Impeller + Flutter GPU on a software GL/Vulkan driver) inside Xvfb
against the REAL backend (OCCT + py-slvs), with xdotool for mouse input and ImageMagick `import` for screenshots.
A web build is not possible (`flutter_gpu` / `flutter_scene` are `dart:ffi`), this is the substitute. No GPU or display
needed. First used for the constrained-drag S7/S8 work (plan: `docs/constrained-drag-implementation-plan.md`).

One-off setup: `apt-get install -y libgtk-3-dev mesa-vulkan-drivers xdotool imagemagick`, `flutter config --enable-linux-desktop`,
`cd client && flutter build linux --release`. (The Linux runner enables Flutter GPU itself, `linux/runner/my_application.cc`.)

```
tools/gui_harness/run.sh                      # backend + Xvfb + app (1280x800); log lines in $GUI_WORK/app.log
G=tools/gui_harness/gui.sh
$G click 608 449                              # connection screen -> Connect
$G click 640 194                              # 3D Part Design (creates "Part 1")
touch /tmp/didsa-gui/inject                   # server builds plate-with-hole + floating bolt onto Part 1 -> .../injected
$G click 28 180                               # assembly lens (lens button) - toggle twice to refresh after inject
$G click 28 132; $G click 200 236; $G click 488 80    # tree -> select 2nd row (bolt) -> close tree
$G click 57 680                               # drawer: Move  (then drag the panel handle down: $G drag 640 397 640 620)
$G shot name                                  # -> /tmp/didsa-gui/name.png (read it with an image viewer)
```
Coordinates are for 1280x800; the app uses the top 720 px. To drag a gizmo ring use raw `xdotool mousedown/mousemove/mouseup`
along the ring's pixels (zoom a screenshot with `convert in.png -crop WxH+X+Y -filter point -resize 400% out.png` to find them).
The "Fix"/Float state of the plate can be set with `curl -X PATCH -H 'X-API-Key: test-api-key' -H 'Content-Type: application/json'
-d '{"fixed": true}' http://127.0.0.1:8000/document/parts/$(cat /tmp/didsa-gui/injected)/occurrences/occ-plate`, then refresh the tree
(lens toggle twice). Not covered: touch input, real GPU rendering, text input beyond `xdotool type`.


## Sketch drag scenarios (option 1, `docs/sketch-drag-projector.md`)
`fresh.sh` restarts backend + app with `DIDSA_DRAG_LOG=1` and opens "2D Drawing"; `script.sh FILE.py` runs a Python file *inside* the
server (globals `client` = REST test client, `all_sketches`, `get_document`; output printed) to add constraints / read back state;
`ring.sh` sweeps the cursor on a ring (drag mode = click, hover, click). `run_all.sh` runs `scenario_{hexagon,circle,slot,shape,arm}.sh`
(shapes drawn through the UI, dimensions over REST) and prints per-scenario frame / rejected / exception counts; screenshots and
`app.log` land in `$GUI_WORK` (default `/tmp/didsa-gui`). Coordinates are for 1280x800 and the default fit; scenarios that change
the view (selection panel) use the shifted coordinates they were recorded with.
