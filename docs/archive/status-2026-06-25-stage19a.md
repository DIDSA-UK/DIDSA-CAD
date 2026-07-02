# Stage 19a status — 2026-06-25

Branch: `claude/new-session-wh9dee`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Edge bleed-through on solid geometry | Complete (approximation, documented) | `mesh_geometry.dart`, `part_viewport.dart` |
| 2 | Body transparency: edges visible through opaque bodies | Complete — confirmed already correct, no separate fix needed | `part_viewport.dart` |
| 3 | Edge line thickness | Complete | `mesh_geometry.dart` |
| 4 | Default background colour → Off-white | Complete | `view_preferences.dart` |
| 5 | Default render mode → Shaded + Edges, persisted | Complete | `view_preferences.dart`, `part_screen.dart` |
| 6 | Initial camera distance (planes ~25% of screen) | Complete | `orbit_camera.dart` |
| 7 | Autofill support on Connection Screen | Complete | `connection_screen.dart` |

## What changed, by item

**1 — Edge bleed-through**: Investigated `flutter_scene`'s real render
pipeline (fetched from the upstream `bdero/flutter_scene` source, since the
package isn't vendored locally). Confirmed the engine's opaque pass already
enables depth write with a `lessEqual` depth-compare, and
`buildMeshEdgesNode`'s material is already `AlphaMode.opaque` — so in
principle GPU depth testing should already occlude a far-side edge behind a
nearer face regardless of node submission order. No concrete app-level bug
was found at that "draw-order/depth-buffer" level (brief option 1), and a
CPU MVP-projection/ray-triangle occlusion test against the real mesh (option
2) was judged too heavy and impossible to verify without a GPU device in
this sandbox. The brief's fallback, option 3 (cull edges whose adjacent
face normals both point away from the camera), can't be implemented
literally either: `mesh.edges` (OCCT edge polylines) and
`mesh.triangleIndices`/`mesh.normals` (triangulated faces) are separate
extraction streams from the backend with no edge-to-face adjacency to test
against.

Implemented an **adapted** option 3 instead: a new
`cullBackFacingSegments(segments, center, cameraPosition)` in
`mesh_geometry.dart` treats the direction from the mesh's bounding-sphere
center to each edge segment's midpoint as a stand-in for that edge's local
"outward normal" (the same approximation `nudgeSegmentsOutward` already
uses for this identical data/limitation), and keeps only segments whose
stand-in normal points at least partway towards the camera. Applied only in
`shadedWithEdges` mode (`part_viewport.dart`'s `_syncEdgesNode`), right
before the existing outward nudge. A new `_resyncEdgesAfterOrbit()` helper
re-runs `_syncEdgesNode()` after every camera-facing change — mouse-drag
orbit, touch-drag orbit, `animateToPlane`'s slerp tick, and the "Reset view"
button — so the cull tracks the live view angle, not just whatever angle
was active when the mesh last changed; it's a no-op outside
`shadedWithEdges` mode to avoid wasted rebuilds in `shaded`/`wireframe`.
Pan-only, zoom-only, and pinch-pan call sites are deliberately left alone
(no facing change, nothing to resync). The approximation is exact for a
sphere and reasonable for any roughly convex/star-shaped-from-center solid
(the only shapes this project's Sketch+Extrude pipeline currently
produces), but — like the brief itself acknowledges of back-face heuristics
in general — won't perfectly handle self-occlusion on a concave body. Fully
documented in `cullBackFacingSegments`'s doc comment per the brief's
"document whichever approach taken" instruction. New `OrbitCamera.position`
getter exposes the camera's world position for this cull without needing a
full `Size`-scoped `PerspectiveCamera`.

**2 — Body transparency**: Confirmed `_syncMeshNode` already sets
`alphaMode: AlphaMode.opaque` whenever `bodyOpacity >= 1.0`, and
`AlphaMode.blend` only below that — this was already correct from Stage 18,
no separate fix needed. To the extent edges were visible through a fully
opaque body, that's the same root cause as Item 1, and Item 1's fix
addresses it.

**3 — Edge line thickness**: `meshEdgeLineWidth` (was `2.0`) renamed to
`kEdgeStrokeWidth` and narrowed to `1.1` logical pixels, a more typical CAD
wireframe weight. Single source of truth for both `shadedWithEdges` and
`wireframe` modes' edge width.

**4 — Default background colour**: `ViewPreferences.defaultBgColourHex`
changed from `#1E1E2E` (Studio Dark) to `#F5F5F0` (Off-white) — this only
changes the fallback applied when no `view_bg_colour` is stored yet
(new installs, or cleared preferences); anyone with `#1E1E2E` already saved
keeps it, since `load()` only falls back to the default when the
`shared_preferences` key is absent. No other hardcoded pre-load background
constant exists for the 3D viewport — `part_screen.dart`'s `_bgColourHex`
field already initialized from this same constant.
(`connection_screen.dart`'s dark splash-screen background is a separate,
deliberately-styled screen with white text, not the 3D viewport's
background, and was left unchanged.)

**5 — Default render mode**: `ViewPreferences.defaultRenderMode` changed
from `ViewportRenderMode.shaded` to `ViewportRenderMode.shadedWithEdges` —
the most common default in professional CAD tools (Fusion 360, SolidWorks,
Onshape). Added persistence: a new `view_render_mode` shared_preferences
key, serialized via the enum's own `.name` and deserialized via
`ViewportRenderMode.values.firstWhere(...)` with a safe `orElse` fallback to
the default (forward-compatible against an unrecognized/corrupt stored
value, e.g. from a future enum entry an older client doesn't know). Wired
into `PartScreen`: `_renderMode`'s field default, `_loadViewPreferences()`'s
load-and-override, and `_onRenderModeChanged`'s persist-on-change, all
mirroring the existing `_bgColourHex`/`_onBgColourChanged` pattern.
`_onRenderModeChanged` became `Future<void>`-returning and `async`/`await`s
the persistence call internally rather than firing it unawaited from a
synchronous body — `PartToolbar.onRenderModeChanged` is typed
`void Function(ViewportRenderMode)`, and Dart's `void`-context covariance
already lets a `Future<void> Function(...)` satisfy that (the same pattern
the pre-existing `_onBgColourChanged`/`_onBodyColourChanged`/
`_onBodyOpacityChanged` already use), so this stays consistent with the
rest of the file and gives the analyzer's `unawaited_futures` lint nothing
to flag.

**6 — Initial camera distance**: `OrbitCamera._defaultDistance` changed
from `30` to `48`. With `flutter_scene`'s real default vertical FOV (45°,
confirmed from the upstream `camera.dart` source) and the fixed reference
planes' real full-width size (`referencePlaneSize = 20` world units, from
`reference_planes.dart`), distance 30 left the planes filling close to 80%
of the viewport's linear extent on a cold launch (matching the reported
"fills nearly full screen" bug). Distance 48 (rounded from the computed
~48.28) puts the planes at roughly half the linear extent, i.e. ~25% of the
screen's *area* — the brief's target. `OrbitCamera.reset()` ("Reset view")
shares this same constant, so it now also returns to the wider framing.

**7 — Autofill support**: `ConnectionScreen`'s two `TextField`s are now
wrapped in a single `AutofillGroup` (so the platform autofill service —
Bitwarden, Android autofill, etc. — treats the URL/API-key pair as one
related save/fill set), with `autofillHints: [AutofillHints.url]` on the
Server URL field and `autofillHints: [AutofillHints.password]` on the API
Key field. `TextInput.finishAutofillContext()` is called right after
`ApiConfig.save` succeeds in `_handleConnect`, so a successful Connect
prompts the platform to offer saving the just-entered credentials. Standard
Flutter autofill API, no plugin or platform code needed.

## Persisted `shared_preferences` keys

| Key | Type | Default | Written by |
|---|---|---|---|
| `server_url` | String | — (empty until first save) | `ApiConfig.save` |
| `api_key` | String | — (empty until first save) | `ApiConfig.save` |
| `view_bg_colour` | String (`"#RRGGBB"`) | `#F5F5F0` (was `#1E1E2E`) | `ViewPreferences.setBgColourHex` |
| `view_body_colour` | String (`"#RRGGBB"`) | `#B0B8C1` | `ViewPreferences.setBodyColourHex` |
| `view_body_opacity` | double | `1.0` | `ViewPreferences.setBodyOpacity` |
| `view_render_mode` | String (enum `.name`) | `shadedWithEdges` (new key) | `ViewPreferences.setRenderMode` |

## Test/analyze results

Same sandbox limitation as every prior stage: no Flutter/Dart SDK on `PATH`
in this environment, so nothing below was executed — verified by manual
reading only.

- `test/mesh_geometry_test.dart`: added four new tests for
  `cullBackFacingSegments` (keeps a camera-facing edge, drops a far-side
  edge, keeps an exactly-perpendicular silhouette edge, keeps a segment
  whose midpoint sits exactly at center) alongside the pre-existing
  `nudgeSegmentsOutward` tests.
- `test/orbit_camera_test.dart`: updated every assertion/comment that
  depended on the old `_defaultDistance` of `30` to the new `48` —
  `zoomByFactor`'s `2.0`-scaled expectation (`60` → `96`),
  `setZoomBoundsForRadius`'s pre-shrink distance check, and `reset`'s
  returned distance. `reset clamps the default distance into a body-scaled
  zoom range smaller than it` needed no numeric change (its assertion is
  relative to `camera.maxDistance`), only a stale comment fix.
- `test/part_screen_test.dart`: updated the render-mode toolbar test — the
  initial active entry is now `Shaded + Edges` (was `Shaded`), so the test
  asserts that first, then exercises Wireframe and Shaded (rather than
  cycling back to Shaded + Edges, which would now be a same-state no-op
  given the new default).
- No test exists for `view_preferences.dart`'s new `view_render_mode`
  key/persistence, `connection_screen.dart`'s new autofill wiring, or
  `cullBackFacingSegments`'s integration inside `part_viewport.dart`
  (`_syncEdgesNode`, `_resyncEdgesAfterOrbit`) — consistent with this
  project's existing convention of not adding controller-level tests for
  `shared_preferences`-backed singletons or for GPU-bound `flutter_scene`
  node-building code (see Stage 18's status doc for the same gap re:
  `view_preferences.dart` itself).
- `flutter analyze`/`flutter test` were not run (no SDK in this sandbox);
  the `_onRenderModeChanged` persistence call was specifically restructured
  (made `async`/`await`-internal rather than fire-and-forget) to avoid
  triggering `flutter_lints`' `unawaited_futures` rule, matching the
  pre-existing `_onBgColourChanged`-style call sites exactly — this is the
  one item in this stage with a real (if small) risk of an analyzer
  surprise that couldn't be confirmed without the toolchain.

## Known gaps / deferred

- Item 1's edge-bleed-through fix is a documented approximation
  (bounding-sphere-center-outward direction as a face-normal stand-in), not
  a true depth-buffer or face-adjacency-based fix — `flutter_scene` 0.18.1
  exposes no read-back of its depth attachment, and the backend's edge data
  has no real adjacency to a triangulated face to test against. It will not
  perfectly handle self-occlusion on a concave body; revisit if a future
  `flutter_scene` version exposes either of those.
- No real on-device verification: every visual claim above (edge culling
  behaviour, line thickness, off-white background, default render mode,
  camera framing, autofill prompts appearing) is based on manual code
  reading only, since this sandbox has no Flutter/Dart SDK, no GPU, and no
  real autofill service to exercise. Worth a real-device pass next session,
  particularly for Item 1 (does the cull look right at glancing/grazing
  angles?) and Item 6 (does ~25% area framing feel right in practice, not
  just by the FOV/plane-size math?).
- Body "subtle specular highlight"/matte-metallic finish (Stage 18's
  carried-over gap): still not implementable — `flutter_scene`'s only
  material type, `UnlitMaterial`, has no roughness/metallic parameter.
  Unchanged `// TODO` in `part_viewport.dart`.
- Sketch and Extrude behaviour: untouched this stage, per the brief's
  explicit constraint.
- Snap-to-close radius, dimension-editing UI, Circle/Arc tools, file
  save/load — all still out of scope, unchanged from prior stages.

## Branch / commits

Branch: `claude/new-session-wh9dee`. Commit pending as of this doc's
writing — see the branch's actual commit log for the final message.
