# Flutter testing feedback 2026-11-05: plan

Source: the owner's bug and feature report from testing the Flutter client.
This doc is for the implementation session. Code pointers were checked against `main` at `6affbc2`.
Line numbers drift, so search for the named symbol if a line is off.

| Item | Summary | Kind | Size |
|---|---|---|---|
| 1 | Default Gemini model is `gemini-2.5-flash`, which no longer works | Bug | Small |
| 2 | Touch: hard to inspect the far ends of a large model because orbit turns about the view target | Feature | Medium |
| 3 | Cast to TV | Feature (advice, then a small first step) | Small for step 1 |
| 4 | Reference planes (XY, XZ, YZ) listed in the build tree under Planes; hide/show, no delete | Feature | Medium (needs a backend change) |

Suggested order: **1 → 4 → 2 → 3**. 1 is a one-line fix plus a migration. 4 and 2 are independent. 3 step 1 is small,
but step 2 is optional and should wait for the owner.

The **Open questions** at the end have a recommended answer each. Go with the recommendation unless the owner says otherwise.

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

## 3. Cast to TV: advice

**The client's platforms** are Android, iOS, Windows and Linux (no web build). The 3D view is `flutter_scene` (Flutter
GPU), which matters for anything that needs a second rendering surface.

### Options

| Option | What the user does | Work | Verdict |
|---|---|---|---|
| **OS screen mirroring** (Android Quick Settings → Cast / Smart View, works with Chromecast and Miracast TVs. iOS / iPadOS AirPlay mirroring to Apple TV or AirPlay 2 TVs. Windows Win+K to a Miracast TV) | Mirrors the whole screen | **None. Works today** | Use it. It is the answer for now |
| **Presentation mode** in the app: one button that hides the chrome (panels, FABs, tree, ribbon, triad optional), goes full screen and landscape, and leaves only the 3D view and simple touch navigation | Turn on mirroring, then tap Present | Small | **Recommended first step.** It makes mirroring look like a real "cast" |
| Second-screen render (Android `Presentation` API / iOS external `UIScreen`): the TV shows a clean 3D view while the phone keeps the full UI | Turn on mirroring. The app detects the external display | Large: a second Flutter view / engine, and a second `flutter_scene` GPU context, on two platforms with native code | Not now. Revisit if Presentation mode isn't enough |
| Viewer web page: the backend (or the phone) serves a read-only viewer (glTF in a browser) that the TV's browser opens, and the phone drives the camera over a WebSocket | Open a URL or scan a QR code on the TV | Medium to large, and TV browsers are weak and inconsistent | No |
| Google Cast SDK / DLNA | | Large, needs a Cast receiver app and registration | No, as the owner suspected |

### Recommendation

1. **Tell the user how to mirror** (a short help page or a dialog behind a "Cast to TV" menu item). On Android, the
   item can open the system cast settings directly (intent action `android.settings.CAST_SETTINGS`, with a fallback to
   `android.settings.DISPLAY_SETTINGS` because some OEMs remove it). On iOS there is no public way to open the AirPlay
   picker without a native `AVRoutePickerView`, so show instructions: "Control Centre → Screen Mirroring". On
   Windows: "Press Win+K".
2. **Add Presentation mode** on the part / assembly screen:
   - A toggle in the Start menu / View ribbon: "Present (full screen)".
   - Hides: feature tree, tool panels, FAB columns, ribbon, breadcrumbs, status chips. Keeps: the 3D view, and
     optionally the view cube.
   - `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` and a landscape lock while it is on. Restore on exit.
   - Exit: a small semi-transparent close button in a corner that fades after a few seconds and comes back on tap, and
     Back / Esc.
   - Navigation: orbit / pinch / pan, plus item 2's pivot. No selection or editing.
   - Optional: a "slow turntable" toggle (a constant small orbit about the pivot or target) for showing a model on a
     TV with no one touching it. This is cheap to build on `orbitByScreenDelta` with a ticker.
3. Only if the owner later wants "phone as remote, TV shows clean view", scope the second-screen option as its own
   spike.

**Tests.** Widget test: toggling Presentation mode removes the tree / FAB / ribbon widgets and restores them on exit.
The system UI mode calls can be checked with the `SystemChannels.platform` mock. Cast settings intent: test that the
right action string is built. The launch itself can't be tested headless.

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

## Open questions (with recommended answers)

1. **Gemini default**: `gemini-3.5-flash`, or a `flash-lite` variant if 3.5 Flash has no free tier? → *3.5 Flash*,
   unless the free-tier check fails.
2. **Touch pivot in selection mode**: leave selection taps alone and add "Rotate about here" to the long-press menu?
   → *Yes.*
3. **Cast**: ship the mirroring help and Presentation mode now, and leave second-screen rendering for later? → *Yes.*
   Turntable toggle in Presentation mode? → *Yes if it stays small.*
4. **Reference planes**: per-plane hide/show with the backend change, rather than one row for all three? → *Per-plane.*

## What the implementation session must say it could not verify

- Item 1: that `gemini-3.5-flash` answers through the OpenAI-compatible endpoint with a real key. That needs the
  owner's key.
- Item 2: the feel on a touch device. The marker and tap only on GPU-backed runs.
- Item 3: real casting to a TV. The Android settings intent on the owner's phone model.
- Item 4: nothing beyond the usual: the viewport rendering of a single hidden plane needs a GPU run.
