# DIDSA-CAD Flutter Client

Stage 4: the first client milestone - chained line sketching with live
solving against the deployed backend. See
[`docs/project-brief.md`](../docs/project-brief.md) Section 5 for the
canonical interaction design this implements.

## Requirements

**Flutter SDK must be on the `master` channel**, not `stable`. Since Stage
7, `pubspec.yaml` depends on `flutter_scene ^0.18.1` for the 3D viewport,
which relies on Dart Native Assets for its build hook - and Native Assets
only takes effect on the `master` channel. Building on `stable` will fail
once the build reaches that hook. Check with `flutter channel`; switch with
`flutter channel master && flutter upgrade` if needed.

## What this is

A single Flutter codebase (`flutter create --platforms windows,android,ios`,
plus `linux` added purely so this could be built and analyzed in a
headless dev environment - see "What was actually verified" below) that:

- Shows a persistent on-screen cursor in a 2D sketch canvas.
- Moves that cursor either by relative, scaled touch drag (Android/iOS) or
  by absolute, 1:1 real mouse movement (Windows/desktop) - the same cursor
  state either way.
- Commits a point only via the **Click** button (or a real mouse click,
  which does the same thing) - never via tap-to-click gesture detection.
- Chains Lines: each Click after the first places a new end Point and
  creates a Line sharing the previous line's end Point id; a **Finish
  Line** button ends the current chain.
- Closes the loop: clicking back near the chain's start Point (within
  `SketchController.snapRadius` sketch units) reuses that Point's actual
  id as the new Line's end point, rather than creating a coincident point.
  The canvas highlights the start point in orange, and green when close
  enough to snap.
- Creates a Sketch on the `XY` plane on startup, and calls
  `POST /sketch/sketches/{id}/solve` after every completed Line (never on
  intermediate cursor movement), then re-reads every known Point from the
  backend so rendering always reflects the backend's solved positions, not
  just the client's local tracking.

## Configuration: base URL and API key

Both live in one place, [`lib/config.dart`](lib/config.dart). The base URL
defaults to the deployed backend
(`https://cad-api.snail-shell.uk`); the API key has **no default** - it's
read from `lib/secrets.dart`, which is **gitignored and must never be
committed** (verify with `git check-ignore -v lib/secrets.dart`).

To run locally:

```sh
cp lib/secrets.example.dart lib/secrets.dart
# edit lib/secrets.dart: set apiKey to the real key, and optionally
# apiBaseUrlOverride (e.g. 'http://localhost:8000') for local backend dev.
```

`lib/secrets.dart` not existing is a compile error - this is intentional;
there's no silent "runs unauthenticated" fallback path.

## Error handling

Every backend call goes through `SketchApiClient`, which applies a 15s
timeout (`ApiConfig.requestTimeout`) and converts any failure - unreachable
host, timeout, non-2xx response - into a single `ApiException`. The UI
surfaces this as a visible red banner (`SketchController.errorMessage`)
rather than failing silently or freezing; the Click button shows a spinner
and disables itself while a request is in flight
(`SketchController.busy`), rather than queuing up duplicate requests
against a slow connection.

## What was actually verified, vs. implemented-but-unverified

This environment has no display, no Android emulator/iOS simulator, and
no Windows host - so the following is true and stated explicitly rather
than glossed over:

**Verified:**
- `flutter analyze`: zero issues.
- `flutter test`: all tests pass (`flutter test` runs against a headless
  test harness, not a real device/display) - covering the chaining state
  machine directly (`test/sketch_controller_test.dart`: first click starts
  a chain, second click creates a shared-point line and triggers a solve,
  a third segment continues the chain, clicking back near the start closes
  the loop using the real Point id and not a new point,
  `finishChain` ends a chain without closing it, and a failing
  backend request surfaces `errorMessage` rather than failing silently)
  and a widget-level smoke test (`test/widget_test.dart`) that boots the
  real `DidsaCadApp`/`SketchScreen` widget tree and confirms the Click/
  Finish Line buttons render. All of these inject a mocked `http.Client`
  (`package:http/testing.dart`) - **no test talks to the real deployed
  backend.**
- `flutter build linux --debug`: compiles to a real native binary
  (`build/linux/x64/debug/bundle/didsa_cad_client`), confirming the Dart
  code and widget tree are structurally sound beyond just static analysis.

**Implemented but NOT interactively verified** (no display/input device
available in this environment to drive it):
- The actual on-screen rendering (cursor crosshair, point/line drawing,
  the orange/green snap indicator) - implemented in
  `lib/sketch/sketch_canvas.dart`, exercised by the widget test above only
  to the extent of "it builds a frame without throwing," not "it looks
  right."
- Real touch-drag behavior on Android/iOS (relative, scaled, persists
  across lifting and re-touching) and real mouse behavior on
  Windows/desktop (absolute 1:1, click commits) - implemented via
  `Listener.onPointerHover/onPointerMove/onPointerDown` with
  `PointerDeviceKind` checks in `lib/sketch/sketch_canvas.dart`, but never
  driven by an actual finger or mouse in this session.
- A real end-to-end run against the live backend
  (`https://cad-api.snail-shell.uk`) with a real API key - the API
  contract (request/response shapes) was instead verified by re-reading
  `backend/app/sketch/schemas.py` and `router.py` directly, and the
  request-construction logic is covered by the mocked-backend tests above,
  but no live network call was made from this client.
- Android/iOS/Windows builds specifically - only the `linux` desktop
  target could be built here, since this environment has no Android SDK,
  no Xcode, and isn't Windows. The code itself has no platform-specific
  branches that would block any of the three target platforms (the
  touch-vs-mouse distinction is made from `PointerDeviceKind` at runtime,
  not from the host OS).

## Known gaps / deferred

- Snap-to-close uses a fixed `snapRadius` (0.5 sketch units) in
  `SketchController` - not yet exposed as a UI affordance for adjusting
  sensitivity/snap distance.
- No dimension-editing UI, no Circle/Arc tools, no 3D viewport, no file
  save/load, no settings UI for the API key - all explicitly out of scope
  for this milestone per the brief.
- Each chained Click costs three backend round-trips (create point, create
  line, solve) plus one `GET` per previously-placed Point to refresh
  positions after solving, since `POST .../solve` returns no point data
  and there's no batch point-listing endpoint. Acceptable for this
  milestone's point counts; worth revisiting if sketches grow large.

## Running

```sh
flutter pub get
flutter run -d <device>   # e.g. windows, an Android device/emulator, etc.
```
