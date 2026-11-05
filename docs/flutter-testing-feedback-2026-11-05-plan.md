# Flutter testing feedback 2026-11-05: plan

Source: the owner's bug and feature report from testing the Flutter client.
This doc is for the implementation session. Code pointers were checked against `main` at `6affbc2`.
Line numbers drift, so search for the named symbol if a line is off.

| Item | Summary | Kind | Size |
|---|---|---|---|
| 1 | Default Gemini model is `gemini-2.5-flash`, which no longer works | Bug | Small |
| 2 | Touch: hard to inspect the far ends of a large model because orbit turns about the view target | Feature | Medium |
| 3 | Screen sharing: (A) working on a monitor, (B) showing to a group | Feature | Small (A is mostly advice; B is Presentation mode) |
| 4 | Reference planes (XY, XZ, YZ) listed in the build tree under Planes; hide/show, no delete | Feature | Medium (needs a backend change) |
| 5 | Phone: the Menu opens from the quick column (bottom right) but the panel appears top left | Bug (UX) | Small |
| 4 | Backend: per-plane `Part.hidden_reference_planes`; `PATCH /visibility` takes `reference_plane_ids` (`reference_planes: true` still means all three); responses and `PartDto` carry `hidden_reference_planes` and keep `reference_planes_hidden` as "all three"; native files write the list (and the old bool when all three are hidden) and load an old bool as all three. Client: `PartDto` / `PartVisibilityDto` read the list with the old-bool fallback; `PartViewport.hiddenReferencePlanes` (a set; `referencePlanesHidden` is now a getter for "all three") and `hitTestReferencePlanes(hidden:)` work per plane; `PartScreen._hiddenReferencePlanes`; the build tree's Planes section is always shown with XY / XZ / YZ rows (eye button, tap = plane sheet, long-press / right-click = Hide / Show only, disabled in multi-select). The chip hides all when any is shown, reads "partial" when some are hidden. The keyboard Delete shortcut already ignores a selected plane (it only acts on multi-select, mates and occurrences), so nothing was needed there. Tapping a hidden plane's row opens its sheet (New Sketch works) | Backend `tests/test_part_visibility.py`: 7 new tests (single plane, `reference_planes: true`, unknown id 422, native round trip, old-bool load, list wins over bool). **Run here with a stub for `OCC`** because pythonocc is not installable in this session, so only the tests that need no geometry ran; the existing geometry-based tests in that file were not run here and should be run in CI. Client: `test/feature_tree_reference_planes_test.dart` (new), `test/document_api_client_test.dart`, `test/part_screen_test.dart` (tree eye, chip partial / hidden, show one after hide all). Whole client suite: 3536 passed, 43 skipped |

Suggested order: **1 → 5 → 4 → 2 → 3**. 1 is a one-line fix plus a migration. 5 is small and on its own. 4 and 2 are
independent. 3 is small, and Presentation mode (3B) needs 2's pivot.

## Progress

Branch `claude/flutter-testing-bugs-features-cbio35`. Nothing here has been looked at on a device. `flutter analyze` here
runs on a newer Flutter master than CI's, so it reports ~230 `deprecated_member_use` infos for `material.dart` that are
not from this work; there are no other findings.

| Item | What landed | Tests |
|---|---|---|
| 1 | **On hold, nothing changed.** Google's docs were unreachable (`ai.google.dev` is not on the session's allowed hosts). Third-party pages give `gemini-3.5-flash` as the id, but some say it is superseded by 3.7 Flash, and they say the free tier is not offered in the UK/EU. The owner has to decide the default | None |
| 5 | `PartToolbarAnchor { topLeft, bottomRight }` and `bottomInset` on `PartToolbar`; the phone layout anchors bottom right, slides in from the right, rounds the left corners, caps at two thirds of the screen height clamped below the top safe area + 8. `PartScreen._startButtonBottomInset` (also used by the Start button's padding via `_startButtonLift`) keeps the panel and the Start button aligned. Android Back / Esc closes the phone Menu panel first (`_cancelActiveMode`). The desktop layout is unchanged | `test/part_toolbar_test.dart` (anchor group: right edge, bottom inset, two-thirds cap, short landscape below the safe area, hidden off right, `topLeft` unchanged); `test/part_screen_test.dart` (phone Menu panel in the bottom-right quadrant, Back closes it) |

The owner has accepted every recommended answer in **Decisions** at the end (2026-11-05).

---

## 1. Default Gemini model: 2.5 to 3.5

**Where.** `client/lib/ai/ai_provider_settings_screen.dart`:

- `_geminiDefaultModel = 'gemini-2.5-flash'` (around line 42).
- It is used in two places: the fresh-install pre-fill in `_load()` (only when nothing was ever saved for the local
  slot) and `_applyGeminiPreset()` (the Gemini preset button).

**Fix.**

1. Change `_geminiDefaultModel` to `'gemini-3.5-flash'`. That is the id for Google's direct Gemini API, which is what the
   preset's base URL (`https://generativelanguage.googleapis.com/v1beta/openai`) points to. The `google/gemini-3.5-flash`
   form is for Vertex / aggregators, not this endpoint. **Check the id against Google's own model list before merging**:
   the planning session only found it in third-party write-ups. The quick check is `GET {base}/models` with an AI
   Studio key, which the OpenAI-compatible endpoint supports.
2. **Migrate users who already saved 2.5.** Changing the constant only helps fresh installs and people who tap the preset
   again. Anyone who saved the old preset has `ai_local_model = gemini-2.5-flash` in their prefs and will stay
   broken. In `AiProviderPreferences.load()` (`client/lib/ai/ai_provider_preferences.dart`): if the saved local base URL
   is the Gemini preset URL **and** the saved model is exactly `gemini-2.5-flash`, rewrite it to the new default and
   save it. Do not touch any other model string, because the user typed it. To share the strings, move the two Gemini
   constants into `AiProviderPreferences` (public) and have the settings screen read them from there.
3. Update the tests that assert the old id: `client/test/ai_provider_settings_screen_test.dart` lines 96 and 199. Add a
   test for the migration (prefs seeded with the preset URL + `gemini-2.5-flash` → loads as the new id. Prefs with
   the preset URL + some other model → unchanged).
4. Docs: `docs/ai-modelling/01-provider-abstraction.md` lines 195 and 214 name the old id.

**Check.** Is 3.5 Flash on the free tier? The screen's doc comment sells the preset as "genuinely free". If 3.5 Flash
is paid-only or has a very small free quota, say so in the PR and ask the owner whether the default should be a
`flash-lite` variant instead.

**Optional, worth it.** Model ids will go stale again. The screen already fetches Ollama's `/api/tags` to fill a model
dropdown (`_ollamaModels`). A sibling fetch of the OpenAI-compatible `GET {base}/models` (with the key as Bearer) would
give Gemini, Groq and OpenAI users a picker of what really exists. It falls back to free text on failure, as now. Only
do this if item 1 is otherwise done and it stays small.

---

## 2. Touch: setting the centre of rotation

**Problem.** On touch, one-finger drag calls `_camera.orbitByScreenDelta` (`part_viewport.dart`, `_handlePointerMove`
around line 4436), which orbits about `OrbitCamera.target`. After fit-to-view that is the centre of the model. On a
large model, zooming in on one end and then orbiting swings that end off screen. The mouse already avoids this:
middle-drag orbits about the point under the cursor (`_orbitPivotAt` → `orbitAboutPointByScreenDelta`, Desktop input
D2). Touch has nothing equivalent.

### Options considered

| Option | For | Against |
|---|---|---|
| **A. Tap to set a pivot (the owner's idea)**: tap on the model sets the pivot there, tap on empty space clears it | Explicit, predictable, persists across several drags, view does not jump | A tap in orbit mode needs a new meaning (it currently does nothing on a body) |
| B. Pivot under the finger at the start of every drag (what middle-drag does) | No extra gesture | The finger hides the point. Every small adjustment picks a new pivot, so it feels jumpy. Starting a drag in empty space orbits about the centre again |
| C. Double-tap to focus: animate the camera target to the tapped point | Classic (Onshape/Fusion "look at"). Also recentres zoom | Moves the view, which the user may not want. Double-tap detection delays every single tap by ~300 ms |
| D. Pivot at the screen centre's depth | Nothing to tap | Guessing depth over empty space. Not obvious to the user |

**Recommendation: A**, plus one small part of C as a follow-up only if the owner wants it. A fits how the app already
treats taps in orbit mode, and it reuses the mouse code that has been tested.

### Design (option A)

**Scope.** `PartViewport` in **orbit mode** (`selectionMode == false`, `drawCursorMode == false`) on the part and
assembly screens. Not the sketcher's Orbit View: there a tap means sketch (`onSketchPlaneTap`). Gate it on
`sketchPlaneBasis == null`.

**State.** `vm.Vector3? _touchPivot` on `PartViewportState` (world space), separate from the per-drag `_orbitPivot`
the middle mouse button uses.

**Setting it.** In `_handleTap` (around line 4566), after the section-placement branch and before the
reference-plane / create-plane / background branches:

- Compute `pivot = _orbitPivotAt(localPosition)`. It already returns the nearest body, component or component
  edge/vertex hit, uses `pointAtRayDistance` (the fixed, distance-correct version) and skips reference planes.
- If `pivot != null` **and** it is nearer than any reference plane or created plane hit on the same ray: set
  `_touchPivot = pivot` and return. For the comparison, `_orbitPivotAt` needs to also return the hit's `rayT`. Split
  it into a helper that returns `(point, rayT)`. Without this check, a tap on a big body is always taken by the 20 mm
  reference planes in front of it.
- Otherwise fall through to the existing branches. If the tap reaches `widget.onBackgroundTap()` (empty space), clear
  `_touchPivot` there too. A tap on a reference plane or a created plane keeps its current meaning (it opens the plane
  sheet) and leaves the pivot alone.

**Using it.** In the one-finger orbit branch of `_handlePointerMove` (`_activeTouches.length < 2`) and in the mouse
left-drag orbit branch just above it: if `_touchPivot != null`, call
`_camera.orbitAboutPointByScreenDelta(dx, dy, _touchPivot!)`, else `orbitByScreenDelta` as now. The middle-drag pivot
keeps priority while a middle drag is active. The tap only fires on pointer-up with travel below
`_tapTravelThreshold`, so drags never set a pivot by accident.

**Showing it.** A pivot you can't see is confusing. Draw a small marker (an 8 to 10 px ring with a dot, in the theme's
accent colour) at the projected pivot. Use the same screen-projection path the other camera-dependent overlays use
(`screen_projection.dart`, refreshed in `_resyncCameraDependentOverlays`). Hide it when the point is behind the camera.
A one-line snackbar or hint the first time ("Rotating about this point. Tap empty space to reset") is optional.

**Clearing it.** On a background tap, on Reset view / Zoom to Fit (`_doRecentre`), when the viewport's bodies or
components change identity (the part is switched, the body is deleted), and on entering sketch mode. Keep it across
selection-mode toggles.

**Selection mode.** There a tap selects, and that must not change. The pivot set in orbit mode still applies to
orbits made from selection mode (two-finger gestures there already go to `_applyPinchPan`; check whether one-finger
orbit exists in selection mode before wiring it). If the owner wants to set a pivot while in selection mode, add
"Rotate about here" to the long-press / context menu (`viewport_context_menus.dart`). Do **not** use double-tap,
because it would delay every selection tap.

**Mouse.** It is harmless and consistent for a left click in orbit mode to set the pivot too. The middle-drag
behaviour is unchanged.

**Tests.**

- Unit: a `(point, rayT)` helper for the pivot, against a known body (orthographic and perspective), like
  `test/orbit_pivot_ray_test.dart`.
- Unit: when `orbitAboutPointByScreenDelta` is called with a pivot, the pivot's screen position stays the same before
  and after a drag. `test/orbit_camera_test.dart` already covers the camera call, so add a test for the new viewport state.
- Widget: tap over a body in orbit mode → pivot set, `onBackgroundTap` not called. Tap over empty space → pivot null,
  `onBackgroundTap` called. Tap in selection mode → pivot unchanged. These need the 3D view and may skip without a
  GPU like the other viewport tests (see `docs/flutter-widget-test-lessons.md`). If they do, test the decision logic
  as a pure function: given hit distances, return pivot / plane / background.

**Not verifiable headless.** Whether it *feels* right on a phone or tablet. Say so in the PR.

---

## 3. Screen sharing: two use cases

The owner's answer (2026-11-05): screen sharing has **two separate use cases**, and they need different things.

- **A. Working on a bigger screen**: share wirelessly to a desktop monitor and keep working on the model.
- **B. Showing and reviewing with a group**: a meeting room screen or TV, where people watch and the presenter drives.

The client runs on Android, iOS, Windows and Linux (no web build). The 3D view is `flutter_scene` (Flutter GPU). A
second rendering surface would need a second GPU context, which is why second-screen rendering is out of scope here.

### A. Working on a bigger screen

Plain mirroring is the wrong tool for this. It sends the phone's own picture, at the phone's resolution and aspect
ratio, to the monitor. The app still thinks it is on a phone, so it keeps the phone layout. The monitor only makes
it bigger.

What does fit is a **desktop windowing mode** on the device. On Android that is Samsung DeX (wired, or wirelessly to a
Miracast monitor / TV), or Android's own desktop windowing on newer Android versions. On iPad it is Stage Manager on
an external display. There, the app gets a real large window and the monitor's resolution, and the user can attach a
Bluetooth mouse and keyboard. **The client already handles this:** `client/lib/layout/layout_mode.dart`
(`resolveLayoutMode`) switches to the desktop layout (ribbon, docked tree, status bar) when the window is at least
1000 x 600 and the last pointer was a mouse. Controls also has an "Always desktop" setting. The desktop input work
(right-drag / middle-drag navigation, context menus, shortcuts) then applies too.

And if a PC is already at the desk, the Windows / Linux build of the client against the same backend is the simplest
option of all.

**The owner reports that wired DeX already works well (2026-11-05)**, so this use case stays as it is. Wireless DeX
and iPad Stage Manager have not been tried.

**Work for the implementation session (small):**

1. **Don't break it.** Presentation mode's landscape lock and immersive mode (B, below) must only apply while
   presenting and must be fully undone on exit, or they would fight DeX's window. Don't lock orientation globally.
2. **Help text** (the same dialog as B's "Share screen" menu item, see below) with a "Working on a monitor" section:
   use DeX / desktop mode or Stage Manager rather than mirroring, add a Bluetooth mouse to get the desktop layout,
   or use the desktop app on a PC.
3. Nothing else. No new layout is needed.

### B. Showing and reviewing with a group

Here **mirroring is the right transport**: Cast / Smart View on Android (Chromecast and Miracast TVs, most meeting
room screens), AirPlay mirroring on iOS (Apple TV, AirPlay 2 TVs), and Win+K (Miracast) on Windows. Room systems with
their own share dongles (ClickShare-style) also mirror. The work in the app is about making what is mirrored look like
a presentation rather than an editing UI.

**Presentation mode** on the part and assembly screens:

- A toggle in the Start menu / View ribbon: "Present".
- Hides: the feature tree, tool panels, FAB columns, ribbon, breadcrumbs and status chips. Keeps the 3D view, and
  optionally the view cube.
- `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` and a landscape lock while it is on, so a
  phone's mirror fills a 16:9 screen instead of a portrait strip with black bars. Restore both on exit. On desktop,
  go full screen in the window instead.
- **Getting the controls back while presenting** (the owner's requirement: the presenter must be able to open
  other models etc. without leaving the room's view in a mess). Design:
  - A **presenter button** is always in one corner (top right). It is semi-transparent and fades to a faint ghost
    after a few seconds of no touch, but it **never disappears and stays tappable** even when faded. Fading only
    on the TV matters, the presenter can always find it. A tap anywhere does *not* bring it back, because a tap in
    Presentation mode sets the pivot (item 2).
  - Tapping it opens a **presenter menu** (a compact sheet or popup, not the full editing UI):
    - **Open model…**: calls the part screen's existing `_onOpenPressed` (`part_screen.dart`, around line 12116),
      which already runs `_confirmExitPart` for unsaved changes and then the platform's file or project-folder picker.
      The newly opened model **stays in Presentation mode** and is fitted to the view (`_doRecentre`). The pivot is
      cleared.
    - **Recent files**, if the app already keeps a recent list. Check before adding one. If there isn't one, Open is
      enough for now.
    - **Scenes**: next / previous, if they are reachable (see the Scenes bullet below).
    - **Turntable** on / off. **Reset view**. **Clear pivot**.
    - **Show all controls**: brings the normal UI back (tree, ribbon, FABs) **without** leaving Presentation mode's
      immersive / landscape state, so the presenter can do anything (open a sub-assembly, toggle visibility, change
      appearance) and then tap the presenter button again to hide them. This is the escape hatch for anything the
      menu doesn't list, so the menu can stay short.
    - **Stop presenting**: restores the system UI, orientation and the normal layout.
  - Back (Android) closes the menu if it is open. Otherwise it hides the controls if they are shown. Otherwise it asks
    "Stop presenting?". Esc on desktop does the same in one step. Never leave Presentation mode on a single
    accidental Back with no prompt.
  - Dialogs opened while presenting (file picker, unsaved-changes prompt) are shown on the mirrored screen too.
    That's unavoidable with mirroring. Say so in the help text ("the audience will see the file picker").
- Navigation: orbit, pinch and pan, plus item 2's tap-to-set pivot (which is exactly what pointing out a detail to a
  room needs). No selection or editing.
- **Turntable**: a toggle for a slow constant orbit about the pivot (or the target) for an unattended display. It is
  cheap with a ticker driving `orbitByScreenDelta` / `orbitAboutPointByScreenDelta`. It stops on touch and resumes on
  the toggle.
- **Keep the pivot marker visible here**. It doubles as a pointer for the audience.
- Optional, only if small: **Saved views / Scenes**. If `docs/scenes-scope.md`'s scenes are reachable from the part
  screen, a simple next / previous scene control in Presentation mode turns it into a walkthrough. Check what exists
  before building anything. If it is not already there, leave it out.

**"Share screen" menu item** (serves A and B):

- On Android, open the system cast settings directly (intent action `android.settings.CAST_SETTINGS`, with a fallback
  to `android.settings.DISPLAY_SETTINGS` because some OEMs remove it). Then offer to enter Presentation mode.
- On iOS there is no public way to open the AirPlay picker without a native `AVRoutePickerView`, so show
  instructions: "Control Centre → Screen Mirroring".
- On Windows: "Press Win+K".
- The dialog has the two short sections: "Present to a room or TV" (mirror, then Present) and "Work on a monitor"
  (A's help text).

### Not now

| Option | Why not |
|---|---|
| Second-screen render (Android `Presentation` API / iOS external `UIScreen`): a clean view on the TV while the phone keeps the full UI | Large: a second Flutter view / engine and a second `flutter_scene` GPU context, with native code on two platforms. Revisit only if Presentation mode isn't enough for B |
| Viewer web page served to the TV's browser, driven from the phone | Medium to large, and TV browsers are weak and inconsistent |
| Google Cast SDK / DLNA | Needs a Cast receiver app and registration. Too complex, as the owner said |

### Tests

- Widget: toggling Presentation mode removes the tree / FAB / ribbon widgets and puts them back on exit.
- Widget: in Presentation mode the presenter button is present and hit-testable after the fade timer has run (pump
  past it). Its menu has Open, Show all controls and Stop presenting. Show all controls brings the tree / ribbon back
  while `presenting` stays true, and tapping the button again hides them. Back with the menu closed and controls
  hidden shows the "Stop presenting?" prompt rather than exiting.
- Widget: Open from the presenter menu calls the open flow (inject or fake `_onOpenPressed`'s picker as other
  open-flow tests do). After a model loads, Presentation mode is still on. The system UI
  mode and orientation calls can be checked with the `SystemChannels.platform` mock.
- Unit: the turntable advances the camera by a fixed angle per tick and stops when a pointer goes down.
- The Android intent: test that the right action string is built. The launch itself can't be tested headless.
- A (desktop windowing): `resolveLayoutMode` already has unit tests. Add a case for a large window with a mouse as
  the last pointer on Android if there isn't one.

---

## 4. Reference planes in the build tree

**Today.**

- The three default planes are drawn and hit-tested in `reference_planes.dart` (`ReferencePlaneKind { xy, xz, yz }`,
  `apiValue` 'XY' / 'XZ' / 'YZ').
- Hiding is **all three or none**: `PartScreen._referencePlanesHidden`, toggled by a visibility chip
  (`part_screen.dart` around line 2100) via `_setReferencePlanesHidden` → `PATCH /document/parts/{id}/visibility`
  with `reference_planes: true`. The backend keeps one bool, `Part.reference_planes_hidden`
  (`backend/app/document/models.py`, `schemas.py` `PartVisibilityUpdate` / `PartVisibilityResponse`, `router.py`
  around line 3570). It is saved in the native format only when true (`native_format.py` around line 2334 / 2450).
- `_referencePlanesForcedVisible` shows them anyway while a flow needs one to be picked (New Sketch plane pick,
  orientation confirm, Mirror plane pick).
- The tree's **Planes** section (`feature_tree_panel.dart`, `_buildPlanesSection`, around line 838) lists only
  created planes (`create_plane` features) and is left out when there are none.

### Recommended design: per-plane hide/show

The owner asked for the planes to appear *under Planes* with hide/show, which reads as three rows, each with its own
visibility. That needs per-plane state, so it is a small backend change.

**Backend** (`backend/app/document/`):

- `Part.hidden_reference_planes: set[str]` (values from `"XY"`, `"XZ"`, `"YZ"`) replaces the bool as the source of
  truth.
- `PartVisibilityUpdate` gains `reference_plane_ids: list[Literal["XY","XZ","YZ"]] = []`. Keep `reference_planes: bool`
  working as "all three", so the current client and DIDSA-VR keep working. The "at least one target" check accepts
  either.
- `PartDto` / `PartVisibilityResponse` gain `hidden_reference_planes: list[str]` (sorted). **Keep** `reference_planes_hidden`
  in both, derived as "all three hidden", for older clients.
- Native format: write `hidden_reference_planes` when it is not empty. On load, read it, and if only the old
  `reference_planes_hidden: true` is present, load it as all three. The existing round-trip tests in
  `backend/tests/test_part_visibility.py` must still pass. Add cases for a single plane, the old-bool load, and
  `reference_planes: true` → all three.
- Mention it in `docs` where the visibility endpoint is described, if it is described (search for `visibility`).

**Client.**

- `document_api_client.dart`: parse `hidden_reference_planes` (fall back to the old bool → all three when it is missing,
  so a new client still works against an old backend). Add the new field to the visibility PATCH.
- `PartScreen`: `_referencePlanesHidden` (bool) becomes `Set<ReferencePlaneKind> _hiddenReferencePlanes`. The chip
  keeps its all-or-nothing meaning: hide all if any are shown, show all if all are hidden. Its icon state is
  "hidden" only when all three are. `_referencePlanesForcedVisible` still overrides everything.
- `PartViewport.referencePlanesHidden` (bool) becomes `hiddenReferencePlanes` (set). Both the renderer and
  `hitTestReferencePlanes` must skip hidden planes, **per plane**. Today `_handleTap` and the section-placement branch
  check a single bool. Search `referencePlanesHidden` in `part_viewport.dart` and in `sketch_screen.dart` (around line
  422, which has its own flag and passes it down) and update every use.
- `FeatureTreePanel`:
  - New props: `hiddenReferencePlanes`, `onReferencePlaneTap(ReferencePlaneKind)`,
    `onReferencePlaneVisibility(ReferencePlaneKind, bool hidden)`.
  - The Planes section is **always shown** now. Three fixed rows first, in the order XY, XZ, YZ, titled
    "XY Plane", "XZ Plane", "YZ Plane". Use the same `feature_plane.svg` icon, perhaps at a muted tint, so they read
    as built-in. Then the created plane rows as now.
  - Row trailing: the same `visibility_off` icon `_simpleRowTrailing` shows for hidden rows. Since there is no other
    action, also give these rows a tappable eye `IconButton` as the trailing, so hide/show is one tap. (Created plane
    rows hide via long-press; making those match is a separate tidy-up, not this item.)
  - Tap: same as tapping the plane in the viewport (`PartScreen._onPlaneTap`, which selects it and opens the plane
    sheet with New Sketch on XY, etc.). This also gives a way to pick a hidden plane for New Sketch: check that
    `_onPlaneTap` works for a hidden plane, or show the plane while its sheet is open.
  - Long-press / right-click: a menu with **Hide/Show only**. Do not route through `onFeatureLongPress`, because these
    are not features. A small dedicated sheet / `MouseContextMenuRegion` menu is enough.
  - **No delete anywhere**: no delete in the menu. In multi-select mode the reference rows are not selectable (no
    check, tap does nothing, or they are drawn disabled), so a multi-select Delete can never include them. Also make
    sure the keyboard Delete shortcut (`keyboard_shortcuts.dart`) does nothing when a reference plane is the selection
    (`_selectedPlane`). Check what it does today.
- Assemblies: `_visibilityTargetPartIds()` already fans the PATCH out. Keep that path.

**DIDSA-VR.** Check whether the VR client reads `reference_planes_hidden` (a quick grep in its `scripts/` found
nothing). Keeping the derived bool means nothing breaks either way.

**Tests.**

- Backend: as above.
- Client unit: DTO parsing (new field, old-bool fallback).
- Widget: `FeatureTreePanel` with no created planes still shows a Planes section with three rows. Tapping the eye on
  XZ calls `onReferencePlaneVisibility(xz, true)`. A hidden row is dimmed. Long-press shows Hide/Show and no Delete.
  In multi-select mode the rows are not selectable.
- Widget: `PartScreen` chip hides all three. Then showing one from the tree turns the chip back to "shown"
  (any-shown state).

### Cheaper alternative (if the owner prefers no backend change)

One "Default planes" row under Planes that toggles all three together, which is the same flag as the chip. It needs no
backend change, and it is a 1-hour job. It is less useful, and it doesn't match "show the reference planes" (plural).
Recommend against unless time is short.

---

## 5. Phone: the Menu panel opens far from the button that opened it

**Problem.** On a phone, the File / View / Selection Filters menu (`PartToolbar`) is opened from the **Menu** button in
the Start button's quick column (bottom right; `PartScreen._quickColumnButtons`, key `quick-menu-fab`, which sets
`_toolbarOpen = true`). But the panel still appears in the **top left** and slides in from the left edge. That was
right when it was opened from the old top-left hamburger FAB, which the touch viewport work removed. Now the menu
appears on the opposite side of the screen from your thumb.

**Cause.** `PartToolbar.build` (`client/lib/viewport3d/part_toolbar.dart`, around line 272) hard-codes
`Align(alignment: Alignment.topLeft)`, `AnimatedSlide(offset: Offset(-1.05, 0))` (off to the left), rounded **right**
corners only, and a `topInset` padding (`8` on a phone, `104` under the desktop ribbon; `part_screen.dart` around
line 26357). The class doc comment still says it is "opened via PartScreen's persistent top-left toggle button".

**Fix: anchor it bottom right on the phone layout, growing up from where the Start button was.**

- Add an anchor to `PartToolbar`, for example `enum PartToolbarAnchor { topLeft, bottomRight }`. The default stays
  `topLeft`, which the desktop layout keeps unchanged (it opens from the ribbon). `PartScreen` passes `bottomRight`
  when `!_desktopLayout`.
- `bottomRight`:
  - `Align(alignment: Alignment.bottomRight)`, sliding in from the right (`Offset(1.05, 0)`), or sliding up and
    fading. Either is fine. From the right matches the left version and is simplest.
  - Rounded **left** corners (`topLeft`, `bottomLeft`) instead of right ones.
  - Bottom padding that puts the panel's bottom edge where the Start button's bottom edge is (the same `bottom:`
    padding the FAB column computes in `PartScreen.build`, around line 27778, plus Scaffold's FAB margin and
    `SafeArea` bottom). The Start button and quick column are already hidden while `_toolbarOpen` (the
    `floatingActionButton: _toolbarOpen || ... ? null` line), so the panel can take exactly that spot and reads as
    "the button turned into the menu". Pull that bottom offset into one getter so the FAB column and the panel can't
    drift apart.
  - `SafeArea(top: false, bottom: true)` instead of the current `bottom: false`.
  - The close (X) button stays in the panel's header row. On the right edge it is now nearest the thumb, which is fine.
  - **Height cap: two thirds of the screen height on the phone layout** (owner's decision, 2026-11-05: the menu has a
    lot in it). Today it is a third, because at the top it had to clear the FABs below. Measure the two thirds of the
    full screen height (`MediaQuery.sizeOf`), then also clamp it to the space between the panel's bottom inset and
    the top safe-area inset plus 8 px. That way it can never run under the status bar in landscape or on a short
    phone. Keep it scrollable. The desktop layout's cap is unchanged.
- Rename `topInset` to something neutral (`edgeInset`), or keep it and add `bottomInset`. Update the doc comments that
  describe the top-left button stack.
- Other phone overlays at the bottom right while the menu is open: check that nothing else is drawn there (the
  selection drawer / multi-select bar, the view cube / triad, tool panels). Tool panels hide the Start button
  anyway, and the menu can't be opened during a tool session because the Start button is gone. If anything overlaps,
  the menu wins while it is open, because it is a short-lived panel.
- **Back / tap outside**: if a tap on the viewport doesn't close the panel today, leave it that way (out of scope).
  Android Back should close it if it doesn't already. Check.
- Presentation mode (item 3B) should reuse this position for its presenter menu if it is in the same corner, so both
  menus open the same way.
- The sketcher (`sketch_screen.dart`) has its own ribbon and no hamburger in the quick column. Not in scope.

**Tests** (`client/test/part_toolbar_test.dart` exists, so extend it):

- `anchor: bottomRight`, visible: the panel's rect touches the right edge (minus margin), its bottom is at the given
  bottom inset, and its height is at most two thirds of the screen. On a short screen (e.g. a 640 x 360 landscape) it
  stays below the top safe-area inset.
- Hidden: it is off screen to the right.
- `topLeft` stays where it is (a regression test for the desktop layout).
- `PartScreen` phone layout: tap `quick-menu-fab` → the toolbar is visible and its rect is in the bottom-right
  quadrant. If `PartScreen` widget tests can't build here, test the anchor through `PartToolbar` alone.

**Not verifiable headless**: whether it feels right in the hand.

---

## Decisions (owner accepted all, 2026-11-05)

1. **Gemini default**: `gemini-3.5-flash`, or a `flash-lite` variant if 3.5 Flash has no free tier? → *3.5 Flash*,
   unless the free-tier check fails.
2. **Touch pivot in selection mode**: leave selection taps alone and add "Rotate about here" to the long-press menu?
   → *Yes.*
3. **Screen sharing**: ship the mirroring help and Presentation mode now, and leave second-screen rendering for later?
   → *Yes.* Turntable toggle in Presentation mode? → *Yes if it stays small.* Use case A is met by desktop windowing
   (DeX / Stage Manager) and the existing desktop layout, not a new layout. → *Owner confirmed the two use cases.*
4. **Reference planes**: per-plane hide/show with the backend change, rather than one row for all three? → *Per-plane.*

## What the implementation session must say it could not verify

- Item 1: that `gemini-3.5-flash` answers through the OpenAI-compatible endpoint with a real key. That needs the
  owner's key.
- Item 2: the feel on a touch device. The marker and tap only on GPU-backed runs.
- Item 3: real mirroring to a TV or room screen. The Android settings intent on the owner's phone model. How the app
  and its 3D view behave in DeX / desktop windowing / Stage Manager (resizing, moving between displays).
- Item 5: the feel on a phone. Any overlap with bottom-right overlays not covered by the tests.
- Item 4: nothing beyond the usual: the viewport rendering of a single hidden plane needs a GPU run.
