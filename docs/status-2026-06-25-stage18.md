# Stage 18 status — 2026-06-25

Branch: `claude/new-session-wh9dee`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | Hamburger menu restructure: File/View `ExpansionTile`s | Complete | `part_toolbar.dart` |
| 2 | 3D viewport visual polish (colours, reference planes, triad) | Complete (specular highlight `TODO`) | `part_viewport.dart`, `reference_planes.dart`, `triad.dart` |
| 3 | Splash/connection screen, runtime URL+key config | Complete | `connection_screen.dart`, `config.dart`, `main.dart` |

## What changed, by item

**1 — Menu restructure**: `PartToolbar` now renders two `ExpansionTile`s,
File and View, instead of a flat list. File holds seven disabled
placeholders (New/Open…/Save/Save As…/Import…/Export STEP/Export STL,
`enabled: false`, `Theme.of(context).disabledColor`, no `onTap`) plus one
enabled entry, **Connection Settings**, which pushes `ConnectionScreen`
(`isSettingsRevisit: true`) over the existing `PartScreen` without losing
the open Part. View keeps the two pre-existing entries — Show Feature
Tree, Hide/Show Reference Planes — unchanged, and the project's existing
Shaded/Shaded+Edges/Wireframe render-mode picker moves into it as the
closest analogue to the brief's "View Settled" toggle (which never existed
in this codebase; this interpretation was confirmed with the user before
implementing). Three new entries follow: **Background Colour**, **Body
Colour** (each opens a bottom sheet of five named swatches via
`showColourSwatchSheet`, `view_prefs_sheets.dart`), and **Body
Transparency** (opens a slider sheet, `showBodyOpacitySheet`, 0–100% in 5%
steps, displayed value is the *inverse* of the stored opacity). The
contextual "New Sketch on [plane]" tile stays outside both
`ExpansionTile`s, unchanged from before this stage, since the brief's
static menu structure doesn't mention it.

**2 — Viewport visual polish**:
- New defaults: background `#1E1E2E` (Studio Dark), body `#B0B8C1`
  (Aluminium) at full opacity. Both are persisted (`view_bg_colour`,
  `view_body_colour`, `view_body_opacity`) and applied live —
  `_ScenePainter` now paints the canvas background from
  `colorFromHex(bgColourHex)` instead of the old hardcoded
  `Color(0xFF202020)`; `_syncMeshNode` builds the non-preview
  `UnlitMaterial` from `vector4FromHex(bodyColourHex, opacity:
  bodyOpacity)`, switching `alphaMode` to `blend` whenever opacity < 1.
- Body "subtle specular highlight"/matte-metallic finish: **left as a
  `// TODO`** in `part_viewport.dart` rather than guessed at. This
  codebase's only material type, `flutter_scene`'s `UnlitMaterial`, has no
  roughness/metallic or other lit-shading parameter — there is nothing to
  set. Revisit once/if a PBR material type ships in `flutter_scene`.
- Reference plane colours: XY=`#3A7BD5` (blue), XZ=`#E8364A` (red),
  YZ=`#27AE60` (green), each at 20% fill alpha / 45% when tap-selected
  (previously 25%/55% with colours derived from each plane's zero axis).
  The old "derive from zero axis" rule is **dropped** for `_baseColor`: it
  agreed with the brief's table only for XY, not XZ/YZ, so `_baseColor` is
  now a fixed per-`ReferencePlaneKind` literal instead, documented as a
  deliberate departure in `reference_planes.dart`.
- Triad axis colours: X=`#E8364A` (red), Y=`#27AE60` (green), Z=`#3A7BD5`
  (blue) — previously `Colors.red`/`Colors.green`/`Colors.blue`. Exposed as
  named constants `triadColorX`/`Y`/`Z` in `triad.dart` so
  `triad_test.dart` could keep asserting on them by name instead of losing
  that coverage.

**3 — Splash/connection screen**: `ApiConfig` (`lib/config.dart`) was
already rewritten in this session to read/write `server_url`/`api_key` via
`shared_preferences` instead of compile-time constants (this predates the
portion of the session covered by this doc, but is the dependency item 3
sits on). `ConnectionScreen` is now `main.dart`'s `home`: it loads any
existing `ApiConfig` values after the first frame (pre-filling both fields
and enabling Connect only once both are non-empty), and on Connect runs
`GET <url>/health` with an `X-API-Key` header, 15s timeout
(`ApiConfig.requestTimeout`). Success persists via `ApiConfig.save` and
navigates to `PartScreen` (`pushReplacement`) on cold launch, or pops back
to the existing `PartScreen` when reached via File → Connection Settings
(`isSettingsRevisit: true`). Failure (non-2xx, timeout, unreachable host —
all already collapse to one path since `_handleConnect` only branches on
whether the `try` throws) shows an inline red error and persists nothing.
Layout matches the brief: centered `assets/images/didsa_logo.png` (falls
back to a bold white "DIDSA" `Text` via `errorBuilder` if the asset is
ever missing), "DIDSA-CAD" subtitle, Server URL field (URL keyboard), API
Key field (obscured, eye-icon toggle), full-width Connect button (shows a
small spinner and disables while `_busy`), error text below. Background
`#1E1E2E`, white/white70 text.

## Persisted `shared_preferences` keys

| Key | Type | Default | Written by |
|---|---|---|---|
| `server_url` | String | — (empty until first save) | `ApiConfig.save` |
| `api_key` | String | — (empty until first save) | `ApiConfig.save` |
| `view_bg_colour` | String (`"#RRGGBB"`) | `#1E1E2E` | `ViewPreferences.setBgColourHex` |
| `view_body_colour` | String (`"#RRGGBB"`) | `#B0B8C1` | `ViewPreferences.setBodyColourHex` |
| `view_body_opacity` | double | `1.0` | `ViewPreferences.setBodyOpacity` |

Colours are always stored/passed around as `"#RRGGBB"` strings, converted
forward-only into a Flutter `Color` (`colorFromHex`) or a `flutter_scene`
`vm.Vector4` (`vector4FromHex`) in `view_preferences.dart` — never
decomposed back out of an existing `Color`'s channels, so this stays
correct regardless of which Flutter version's `Color` channel-accessor API
ends up in the lockfile.

## Test/analyze results

Same sandbox limitation as every prior stage: no Flutter/Dart SDK on
`PATH` in this environment, so nothing below was executed — verified by
manual reading only.

- `test/part_screen_test.dart`: added `SharedPreferences.setMockInitialValues({})`
  in a new top-level `setUp`, since `PartScreen.initState` now also calls
  `ViewPreferences.load()` (a `shared_preferences` read) — without the
  mock, every existing test in this file would throw
  `MissingPluginException` the moment that call ran.
- `test/triad_test.dart`: updated to assert against the new
  `triadColorX`/`Y`/`Z` constants instead of `Colors.red`/`green`/`blue`,
  preserving the same assertions (label order, exact colour identity) under
  the new colour values.
- `test/widget_test.dart`: unaffected — it builds its own `MaterialApp`/
  `Scaffold`/`SketchScreen` trees directly rather than instantiating
  `DidsaCadApp` or `PartScreen`, so routing `main.dart`'s `home` through
  `ConnectionScreen` doesn't touch it.
- `test/reference_planes_test.dart`: unaffected — no test asserts on the
  specific alpha/colour values that changed, only on geometry (rotation,
  hit-testing).
- No test exists for `connection_screen.dart`, `view_preferences.dart`, or
  `view_prefs_sheets.dart` themselves (no test talks to a real backend in
  this codebase's convention, and these are net-new screens/widgets with
  no prior controller-level test target to extend) — this is the same gap
  every other purely-widget-level addition in this project has shipped
  with (e.g. `extrude_panel.dart`, `feature_context_menu.dart`).

## Known gaps / deferred

- Body "subtle specular highlight" / matte-metallic finish: not
  implementable with `flutter_scene`'s current `UnlitMaterial` (no
  roughness/metallic parameter exists to set) — flagged with a `// TODO`
  in `part_viewport.dart`, not implemented.
- No automated test directly drives `ConnectionScreen`'s widget tree (field
  pre-fill, Connect button enable/disable, health-check success/failure
  paths) or `view_prefs_sheets.dart`'s bottom sheets — consistent with this
  project's existing convention of not widget-testing screens/dialogs
  beyond the one pre-existing smoke test in `widget_test.dart`, but worth
  closing if a future stage wants stronger regression coverage here.
- As before this stage: no real end-to-end run against the live backend
  (`https://cad-api.snail-shell.uk`) was made — `ConnectionScreen`'s
  `GET /health` call, `ApiConfig`'s persistence, and every other backend
  call in this app are covered only by mocked-`http.Client` tests, never a
  live network request, in this sandbox.
- Snap-to-close radius, dimension-editing UI, Circle/Arc tools, file
  save/load — all still out of scope, unchanged from prior stages.

## Branch / commits

Branch: `claude/new-session-wh9dee`. Commit pending as of this doc's
writing — see the branch's actual commit log for the final message.
